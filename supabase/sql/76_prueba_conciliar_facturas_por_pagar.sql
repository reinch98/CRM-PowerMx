-- Prueba de 76_conciliar_facturas_por_pagar.sql. Correr DESPUÉS del 76, el bloque COMPLETO. begin/rollback.
-- SQL plano (sin bloques plpgsql). Usa junio de 2027 para no mezclarse con datos reales.
--
-- Facturas por pagar: A 1,160 (debe 1,160) · B 2,320 con un pago parcial de 1,160 en mayo (debe 1,160)
-- · C 700 cancelada en el SAT · D 3,480.
-- Banco: cargo 1,160 (A o B: dos candidatos) · cargo 3,480 (solo D: seguro) · cargo 700 (C cancelada:
-- nada) · abono 1,160 (una entrada nunca paga una factura).
begin;

select set_config('request.jwt.claims',
  json_build_object('sub', (select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1),
                    'role', 'authenticated')::text, true);

select set_config('app.cuenta', (select id::text from cuentas_financieras where lower(nombre) = 'banorte negocio'), true),
       set_config('app.a', gen_random_uuid()::text, true),
       set_config('app.b', gen_random_uuid()::text, true),
       set_config('app.c', gen_random_uuid()::text, true),
       set_config('app.d', gen_random_uuid()::text, true);

insert into cfdi (id, uuid_fiscal, sentido, fecha, rfc_emisor, nombre_emisor, rfc_receptor, subtotal, total, iva_trasladado,
                  metodo_pago, por_pagar, vence, categoria, estado_sat) values
  (current_setting('app.a')::uuid, gen_random_uuid()::text, 'recibido', '2027-06-01 12:00-06', 'AAA010101AAA', 'PRUEBA-76 A', 'XAXX010101000', 1000, 1160, 160, 'PPD', true, '2027-06-30', 'material', 'vigente'),
  (current_setting('app.b')::uuid, gen_random_uuid()::text, 'recibido', '2027-04-20 12:00-06', 'BBB010101BBB', 'PRUEBA-76 B', 'XAXX010101000', 2000, 2320, 320, 'PPD', true, '2027-06-20', 'servicios', 'vigente'),
  (current_setting('app.c')::uuid, gen_random_uuid()::text, 'recibido', '2027-06-01 12:00-06', 'CCC010101CCC', 'PRUEBA-76 C', 'XAXX010101000', 603.45, 700, 96.55, 'PPD', true, '2027-06-30', 'otro', 'cancelado'),
  (current_setting('app.d')::uuid, gen_random_uuid()::text, 'recibido', '2027-06-02 12:00-06', 'DDD010101DDD', 'PRUEBA-76 D', 'XAXX010101000', 3000, 3480, 480, 'PPD', true, '2027-07-02', 'herramienta', 'vigente');

-- B ya lleva un pago parcial en mayo (fuera de los ±7 días: no es candidato del libro).
select set_config('app.pb', pagar_cfdi(current_setting('app.b')::uuid, 1160, '2027-05-01', null, 'transferencia', null)::text, true);

select set_config('app.r1', registrar_estado_cuenta(current_setting('app.cuenta')::uuid, jsonb_build_object(
  'periodo_desde', '2027-06-01', 'periodo_hasta', '2027-06-30',
  'movimientos', jsonb_build_array(
    jsonb_build_object('fecha', '2027-06-10', 'descripcion', 'SPEI ENVIADO PRUEBA-76 UNO', 'cargo', 1160),
    jsonb_build_object('fecha', '2027-06-12', 'descripcion', 'SPEI ENVIADO PRUEBA-76 DOS', 'cargo', 3480, 'referencia', 'RASTREO76'),
    jsonb_build_object('fecha', '2027-06-12', 'descripcion', 'SPEI ENVIADO PRUEBA-76 TRES', 'cargo', 700),
    jsonb_build_object('fecha', '2027-06-15', 'descripcion', 'SPEI RECIBIDO PRUEBA-76', 'abono', 1160))), null)::text, true);
select set_config('app.estado', current_setting('app.r1')::jsonb ->> 'estado_id', true);
select set_config('app.m1', (select id::text from movimientos_banco where estado_id = current_setting('app.estado')::uuid and descripcion like '%UNO'), true),
       set_config('app.m2', (select id::text from movimientos_banco where estado_id = current_setting('app.estado')::uuid and descripcion like '%DOS'), true),
       set_config('app.m3', (select id::text from movimientos_banco where estado_id = current_setting('app.estado')::uuid and descripcion like '%TRES'), true),
       set_config('app.m4', (select id::text from movimientos_banco where estado_id = current_setting('app.estado')::uuid and abono = 1160), true);

-- 1) Propuesta: 3,480 → solo D y seguro; 1,160 → A y B, no seguro; 700 (C cancelada) y el abono, nada.
select set_config('app.r2', proponer_conciliacion(current_setting('app.estado')::uuid)::text, true);
select set_config('app.p1', concat(
  case when (select (e ->> 'seguro')::boolean and jsonb_array_length(e -> 'candidatos') = 1
                    and e -> 'candidatos' -> 0 ->> 'clase' = 'factura' and e -> 'candidatos' -> 0 ->> 'cfdi_id' = current_setting('app.d')
               from jsonb_array_elements(current_setting('app.r2')::jsonb) e where e ->> 'mov_banco_id' = current_setting('app.m2'))
   and (select not (e ->> 'seguro')::boolean and jsonb_array_length(e -> 'candidatos') = 2
               from jsonb_array_elements(current_setting('app.r2')::jsonb) e where e ->> 'mov_banco_id' = current_setting('app.m1'))
   and (select jsonb_array_length(e -> 'candidatos') = 0
               from jsonb_array_elements(current_setting('app.r2')::jsonb) e where e ->> 'mov_banco_id' = current_setting('app.m3'))
   and (select jsonb_array_length(e -> 'candidatos') = 0
               from jsonb_array_elements(current_setting('app.r2')::jsonb) e where e ->> 'mov_banco_id' = current_setting('app.m4'))
  then 'ok' else 'FALLO' end, ' — D seguro; A o B a elegir; cancelada y abono sin candidatos'), true);

-- 2) Conciliar los seguros: paga D con fecha, cuenta y referencia del banco, y el IVA completo.
select set_config('app.r3', conciliar_seguros(current_setting('app.estado')::uuid)::text, true);
select set_config('app.p2', concat(
  case when (current_setting('app.r3')::jsonb ->> 'conciliados')::int = 1
        and (select count(*) = 1 and min(monto) = 3480 and min(iva) = 480 and min(fecha) = '2027-06-12'
                    and min(categoria) = 'herramienta' and min(referencia) = 'RASTREO76'
                    and min(cuenta_id::text) = current_setting('app.cuenta')
               from expediente_movimientos where cfdi_id = current_setting('app.d')::uuid)
        and (select estado from movimientos_banco where id = current_setting('app.m2')::uuid) = 'conciliado'
       then 'ok' else 'FALLO' end, ' — D pagada y conciliada con los datos del banco'), true);

-- 3) Elegir A a mano para el 1,160: A queda pagada; B sigue debiendo 1,160.
select set_config('app.r4', conciliar_factura_banco(current_setting('app.m1')::uuid, current_setting('app.a')::uuid)::text, true);
select set_config('app.r5', cuentas_por_pagar()::text, true);
select set_config('app.p3', concat(
  case when (current_setting('app.r4')::jsonb ->> 'saldo')::numeric = 0
        and not exists (select 1 from jsonb_array_elements(current_setting('app.r5')::jsonb -> 'cuentas') e
                         where e ->> 'cfdi_id' in (current_setting('app.a'), current_setting('app.d')))
        and exists (select 1 from jsonb_array_elements(current_setting('app.r5')::jsonb -> 'cuentas') e
                     where e ->> 'cfdi_id' = current_setting('app.b') and (e ->> 'saldo')::numeric = 1160)
       then 'ok' else 'FALLO' end, ' — A y D salen de Por pagar; B sigue con 1,160'), true);

-- 4) Desconciliar el 1,160: el pago de A queda en el libro y se propone ÉL (no A otra vez) junto con B.
select set_config('app.r6', desconciliar_movimiento(current_setting('app.m1')::uuid)::text, true);
select set_config('app.r7', proponer_conciliacion(current_setting('app.estado')::uuid)::text, true);
select set_config('app.p4', concat(
  case when (select jsonb_array_length(e -> 'candidatos') = 2
                    and e -> 'candidatos' -> 0 ->> 'clase' = 'libro'
                    and e -> 'candidatos' -> 1 ->> 'cfdi_id' = current_setting('app.b')
               from jsonb_array_elements(current_setting('app.r7')::jsonb) e where e ->> 'mov_banco_id' = current_setting('app.m1'))
       then 'ok' else 'FALLO' end, ' — sin pagar A dos veces: el libro y B'), true);

-- 5) Volver a conciliar con el movimiento del libro (no con otra factura): no se crea otro pago.
select set_config('app.r8', conciliar_movimiento(current_setting('app.m1')::uuid,
  (current_setting('app.r4')::jsonb ->> 'movimiento_id')::uuid)::text, true);
select set_config('app.p5', concat(
  case when (select count(*) from expediente_movimientos where cfdi_id = current_setting('app.a')::uuid) = 1
        and (select estado from movimientos_banco where id = current_setting('app.m1')::uuid) = 'conciliado'
       then 'ok' else 'FALLO' end, ' — A tiene un solo pago'), true);

select current_setting('app.p1') as resultado
union all select current_setting('app.p2')
union all select current_setting('app.p3')
union all select current_setting('app.p4')
union all select current_setting('app.p5');

-- No se prueba aquí porque lanza excepción: pagar con una entrada del banco, con una factura cancelada,
-- con un renglón que ya no está pendiente, o con un cargo mayor que lo que se debe (lo frena pagar_cfdi).

rollback;
