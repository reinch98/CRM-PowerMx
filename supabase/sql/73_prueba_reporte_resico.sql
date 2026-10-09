-- Prueba de 73_reporte_resico.sql. Correr DESPUÉS del 73, el bloque COMPLETO. begin/rollback.
-- SQL plano (sin bloques plpgsql). Usa marzo de 2027 para no mezclarse con datos reales.
--
-- El caso: cotización de 116,000 (IVA 16,000) con su factura emitida; cobro de 58,000 (IVA 8,000,
-- base 50,000 → tramo de 1.10 % → ISR 550). Gastos: 1,160 con CFDI (IVA 160) y 500 sin CFDI; un retiro
-- de 1,000 que NO cuenta. IVA a cargo = 8,000 − 160 = 7,840.
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

select set_config('app.cli', gen_random_uuid()::text, true),
       set_config('app.cot', gen_random_uuid()::text, true),
       set_config('app.cf_e', gen_random_uuid()::text, true),
       set_config('app.cf_r', gen_random_uuid()::text, true);

insert into clientes (id, nombre, telefono) values (current_setting('app.cli')::uuid, 'PRUEBA-73', '9990000073');
insert into cotizaciones (id, cliente_id, tipo, estado, partidas, subtotal, descuento, iva, total)
values (current_setting('app.cot')::uuid, current_setting('app.cli')::uuid, 'venta', 'aceptada', '[]'::jsonb, 100000, 0, 16000, 116000);
insert into cfdi (id, uuid_fiscal, sentido, tipo_comprobante, fecha, rfc_emisor, rfc_receptor, subtotal, total, iva_trasladado, cotizacion_id)
values (current_setting('app.cf_e')::uuid, 'eeeeeeee-0000-4000-8000-000000000073', 'emitido', 'I', '2027-03-05T10:00:00-06:00',
        'CALP9806096WA', 'XEXX010101000', 100000, 116000, 16000, current_setting('app.cot')::uuid);
insert into cfdi (id, uuid_fiscal, sentido, tipo_comprobante, fecha, rfc_emisor, rfc_receptor, subtotal, total, iva_trasladado, nombre_emisor)
values (current_setting('app.cf_r')::uuid, 'ffffffff-0000-4000-8000-000000000073', 'recibido', 'I', '2027-03-06T10:00:00-06:00',
        'REF010101BBB', 'CALP9806096WA', 1000, 1160, 160, 'PROVEEDOR 73');
insert into expediente_movimientos (cotizacion_id, tipo, categoria, fecha, monto, concepto) values
  (current_setting('app.cot')::uuid, 'ingreso', 'cobro', '2027-03-10', 58000, 'Anticipo PRUEBA-73');
insert into expediente_movimientos (tipo, categoria, fecha, monto, iva, cfdi_id, concepto) values
  ('egreso', 'material', '2027-03-11', 1160, 160, current_setting('app.cf_r')::uuid, 'Material PRUEBA-73'),
  ('egreso', 'gasolina', '2027-03-12', 500, 69, null, 'Gasolina sin factura PRUEBA-73'),
  ('egreso', 'retiro_dueno', '2027-03-13', 1000, 0, null, 'Retiro PRUEBA-73');

select set_config('app.r', reporte_resico('2027-03-15')::text, true);

-- 1) Ingresos: cobrado 58,000, IVA 8,000, base 50,000, con factura.
select set_config('app.p1', concat(
  case when (current_setting('app.r')::jsonb #>> '{ingresos,cobrado}')::numeric = 58000
        and (current_setting('app.r')::jsonb #>> '{ingresos,iva}')::numeric = 8000
        and (current_setting('app.r')::jsonb #>> '{ingresos,base}')::numeric = 50000
        and (current_setting('app.r')::jsonb #>> '{ingresos,sin_factura}')::int = 0
       then 'ok' else 'FALLO' end, ' — ingresos: ', (current_setting('app.r')::jsonb -> 'ingresos') - 'detalle'), true);

-- 2) ISR: tramo 1.10 % sobre 50,000 = 550, sin retención.
select set_config('app.p2', concat(
  case when (current_setting('app.r')::jsonb #>> '{isr,tasa}')::numeric = 0.011
        and (current_setting('app.r')::jsonb #>> '{isr,a_pagar}')::numeric = 550
       then 'ok' else 'FALLO' end, ' — ISR: ', current_setting('app.r')::jsonb -> 'isr'), true);

-- 3) IVA: 8,000 − 160 = 7,840 a cargo (el gasto sin CFDI no acredita).
select set_config('app.p3', concat(
  case when (current_setting('app.r')::jsonb #>> '{iva,acreditable}')::numeric = 160
        and (current_setting('app.r')::jsonb #>> '{iva,a_cargo}')::numeric = 7840
        and (current_setting('app.r')::jsonb #>> '{iva,a_favor}')::numeric = 0
       then 'ok' else 'FALLO' end, ' — IVA: ', current_setting('app.r')::jsonb -> 'iva'), true);

-- 4) Gastos: 1,660 (el retiro no cuenta), 500 sin CFDI con su aviso; pago a más tardar el 17 de abril.
select set_config('app.p4', concat(
  case when (current_setting('app.r')::jsonb #>> '{gastos,total}')::numeric = 1660
        and (current_setting('app.r')::jsonb #>> '{gastos,sin_cfdi}')::numeric = 500
        and current_setting('app.r')::jsonb #>> '{periodo,limite_pago}' = '2027-04-17'
        and exists (select 1 from jsonb_array_elements_text(current_setting('app.r')::jsonb -> 'avisos') a where a like '%sin CFDI%')
       then 'ok' else 'FALLO' end, ' — gastos 1,660, aviso sin CFDI, límite 17/04'), true);

-- 5) Una retención de ISR de 1,250 en la factura se reparte por lo cobrado (625) y deja el ISR en 0.
update cfdi set isr_retenido = 1250 where id = current_setting('app.cf_e')::uuid;
select set_config('app.r5', reporte_resico('2027-03-15')::text, true);
select set_config('app.p5', concat(
  case when (current_setting('app.r5')::jsonb #>> '{isr,retenido}')::numeric = 625
        and (current_setting('app.r5')::jsonb #>> '{isr,a_pagar}')::numeric = 0
       then 'ok' else 'FALLO' end, ' — retención proporcional 625, ISR a pagar 0'), true);

-- 6) Septiembre de 2026 es parcial (desde el alta en RESICO); agosto no aplica.
select set_config('app.p6', concat(
  case when reporte_resico('2026-09-10') #>> '{periodo,desde}' = '2026-09-22'
        and (reporte_resico('2026-08-10') ->> 'ok')::boolean = false
       then 'ok' else 'FALLO' end, ' — septiembre desde el 22; agosto fuera de RESICO'), true);

-- 7) Quien no es admin no ve las tasas.
select set_config('request.jwt.claims',
  json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
set local role authenticated;
select set_config('app.p7', concat(
  case when (select count(*) from resico_tasas_isr) = 0 then 'ok' else 'FALLO' end, ' — sin ser admin, no ve las tasas'), true);
reset role;

select current_setting('app.p1') as resultado
union all select current_setting('app.p2')
union all select current_setting('app.p3')
union all select current_setting('app.p4')
union all select current_setting('app.p5')
union all select current_setting('app.p6')
union all select current_setting('app.p7');

rollback;
