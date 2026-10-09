-- Prueba de 72_cuentas_por_pagar.sql. Correr DESPUÉS del 72, el bloque COMPLETO. begin/rollback.
-- SQL plano (sin bloques plpgsql); cada llamada que escribe va en su propia sentencia y su
-- comprobación en la siguiente.
--
-- El caso: una factura PPD de 1,160 (IVA 160) aprobada como "aún no la pago", que vence ayer.
-- Se paga en dos partes: 580 (IVA 80) y luego 580 (IVA 80).
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

select set_config('app.rfc', (select rfc from empresa_fiscal where id), true);

-- Documento + CFDI recibido de prueba.
select set_config('app.r0', registrar_documento('cfdi_xml', 'documentos/prueba72.xml', 'ppd.xml', 'text/xml',
  encode(sha256('prueba-72'::bytea), 'hex'), 'xml', null, '[]'::jsonb)::text, true);
select set_config('app.doc', current_setting('app.r0')::jsonb ->> 'documento_id', true);
select set_config('app.r0b', registrar_cfdi(jsonb_build_object(
  'uuid_fiscal', 'dddddddd-0000-4000-8000-000000000072', 'fecha', '2026-09-01T10:00:00-06:00',
  'rfc_emisor', 'REF010101BBB', 'nombre_emisor', 'PROVEEDOR PRUEBA 72', 'rfc_receptor', current_setting('app.rfc'),
  'subtotal', 1000, 'total', 1160, 'iva_trasladado', 160, 'metodo_pago', 'PPD'),
  'documentos/prueba72.xml', current_setting('app.doc')::uuid)::text, true);
select set_config('app.cfdi', current_setting('app.r0b')::jsonb ->> 'cfdi_id', true);

-- 1) "Aún no la pago" deja la factura por pagar, con su categoría y el vencimiento capturado.
select set_config('app.r1', aprobar_documento(current_setting('app.doc')::uuid, jsonb_build_object(
  'accion', 'gasto', 'categoria', 'material', 'pagado', false, 'vence', (current_date - 1)::text))::text, true);
select set_config('app.p1', concat(
  case when (select por_pagar and categoria = 'material' and vence = current_date - 1
               from cfdi where id = current_setting('app.cfdi')::uuid)
        and (select count(*) from expediente_movimientos where cfdi_id = current_setting('app.cfdi')::uuid) = 0
       then 'ok' else 'FALLO' end, ' — por pagar, material, vence ayer, sin movimiento'), true);

-- 2) Aparece en cuentas por pagar con saldo 1,160 y como vencida.
select set_config('app.r2', cuentas_por_pagar()::text, true);
select set_config('app.p2', concat(
  case when (select (e ->> 'saldo')::numeric = 1160 and (e ->> 'dias')::int = -1
               from jsonb_array_elements(current_setting('app.r2')::jsonb -> 'cuentas') e
              where e ->> 'cfdi_id' = current_setting('app.cfdi'))
        and (current_setting('app.r2')::jsonb ->> 'vencido')::numeric >= 1160
       then 'ok' else 'FALLO' end, ' — en la lista: saldo 1,160, vencida hace 1 día'), true);

-- 3) Vencida: aviso alto en el Inicio y cuenta en el globo de Finanzas.
select set_config('app.p3', concat(
  case when exists (select 1 from jsonb_array_elements(inicio_admin() -> 'urgente') e
                     where e ->> 'clave' = 'cxp_vencidas' and e ->> 'nivel' = 'alto')
        and (pendientes_admin() ->> 'finanzas')::int >= 1
       then 'ok' else 'FALLO' end, ' — vencida: aviso en Inicio y globo'), true);

-- 4) Pago parcial de 580: egreso con IVA proporcional (80), saldo 580.
select set_config('app.r4', pagar_cfdi(current_setting('app.cfdi')::uuid, 580, current_date, null, 'transferencia', null)::text, true);
select set_config('app.p4', concat(
  case when (current_setting('app.r4')::jsonb ->> 'saldo')::numeric = 580
        and (select count(*) from expediente_movimientos
              where cfdi_id = current_setting('app.cfdi')::uuid and monto = 580 and iva = 80
                and categoria = 'material' and cotizacion_id is null and notas = 'Pago parcial') = 1
       then 'ok' else 'FALLO' end, ' — pago parcial: IVA 80, saldo 580'), true);

-- 5) Pagar el resto la liquida y desaparece de la lista.
select set_config('app.r5', pagar_cfdi(current_setting('app.cfdi')::uuid, 580, current_date, null, 'transferencia', null)::text, true);
select set_config('app.p5', concat(
  case when (current_setting('app.r5')::jsonb ->> 'saldo')::numeric = 0
        and not exists (select 1 from jsonb_array_elements(cuentas_por_pagar() -> 'cuentas') e
                         where e ->> 'cfdi_id' = current_setting('app.cfdi'))
        and (select sum(iva) from expediente_movimientos where cfdi_id = current_setting('app.cfdi')::uuid) = 160
       then 'ok' else 'FALLO' end, ' — liquidada: fuera de la lista, IVA total 160'), true);

-- 6) Programar el pago cambia el vencimiento y la categoría.
select set_config('app.r6', programar_pago_cfdi(current_setting('app.cfdi')::uuid, current_date + 15, 'herramienta')::text, true);
select set_config('app.p6', concat(
  case when (select vence = current_date + 15 and categoria = 'herramienta'
               from cfdi where id = current_setting('app.cfdi')::uuid)
       then 'ok' else 'FALLO' end, ' — programar: cambia vencimiento y categoría'), true);

-- 7) Quien no es admin no ve las facturas.
select set_config('request.jwt.claims',
  json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
set local role authenticated;
select set_config('app.p7', concat(
  case when (select count(*) from cfdi) = 0 then 'ok' else 'FALLO' end, ' — sin ser admin, no ve facturas'), true);
reset role;

select current_setting('app.p1') as resultado
union all select current_setting('app.p2')
union all select current_setting('app.p3')
union all select current_setting('app.p4')
union all select current_setting('app.p5')
union all select current_setting('app.p6')
union all select current_setting('app.p7');

-- No se prueba aquí porque lanza excepción: pagar más que el saldo («El pago (…) es mayor que lo que
-- falta…»), pagar una factura que no está por pagar, y cualquier llamada de quien no es admin.

rollback;
