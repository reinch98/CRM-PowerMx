-- Prueba de 75_conciliacion_bancaria.sql. Correr DESPUÉS del 75, el bloque COMPLETO. begin/rollback.
-- SQL plano (sin bloques plpgsql). Usa mayo de 2027 para no mezclarse con datos reales.
--
-- Libro: cobro 5,800 (con cotización), gasolina 812 (sin cuenta), dos gastos de 500 el mismo día.
-- Banco: abono 5,800; cargo 812; dos cargos de 500; comisión 15.08; abono 10,000 (traspaso).
-- Saldo inicial 1,000 → final 14,972.92 (cuadra).
begin;

select set_config('request.jwt.claims',
  json_build_object('sub', (select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1),
                    'role', 'authenticated')::text, true);

select set_config('app.cuenta', (select id::text from cuentas_financieras where lower(nombre) = 'banorte negocio'), true),
       set_config('app.cli', gen_random_uuid()::text, true),
       set_config('app.cot', gen_random_uuid()::text, true),
       set_config('app.cobro', gen_random_uuid()::text, true),
       set_config('app.gas', gen_random_uuid()::text, true),
       set_config('app.g500a', gen_random_uuid()::text, true),
       set_config('app.g500b', gen_random_uuid()::text, true);

insert into clientes (id, nombre, telefono) values (current_setting('app.cli')::uuid, 'PRUEBA-75', '9990000075');
insert into cotizaciones (id, cliente_id, tipo, estado, partidas, subtotal, descuento, iva, total)
values (current_setting('app.cot')::uuid, current_setting('app.cli')::uuid, 'venta', 'aceptada', '[]'::jsonb, 10000, 0, 1600, 11600);
insert into expediente_movimientos (id, cotizacion_id, tipo, categoria, fecha, monto, concepto) values
  (current_setting('app.cobro')::uuid, current_setting('app.cot')::uuid, 'ingreso', 'cobro', '2027-05-10', 5800, 'Anticipo PRUEBA-75');
insert into expediente_movimientos (id, tipo, categoria, fecha, monto, concepto) values
  (current_setting('app.gas')::uuid, 'egreso', 'gasolina', '2027-05-09', 812, 'Gasolina PRUEBA-75'),
  (current_setting('app.g500a')::uuid, 'egreso', 'viaticos', '2027-05-12', 500, 'Viático A PRUEBA-75'),
  (current_setting('app.g500b')::uuid, 'egreso', 'viaticos', '2027-05-12', 500, 'Viático B PRUEBA-75');

select set_config('app.datos', jsonb_build_object(
  'periodo_desde', '2027-05-01', 'periodo_hasta', '2027-05-31', 'saldo_inicial', 1000, 'saldo_final', 14972.92,
  'movimientos', jsonb_build_array(
    jsonb_build_object('fecha', '2027-05-10', 'descripcion', 'SPEI RECIBIDO CLIENTE', 'abono', 5800),
    jsonb_build_object('fecha', '2027-05-10', 'descripcion', 'COMPRA GASOLINERA', 'cargo', 812),
    jsonb_build_object('fecha', '2027-05-12', 'descripcion', 'PAGO SERVICIO', 'cargo', 500),
    jsonb_build_object('fecha', '2027-05-12', 'descripcion', 'PAGO SERVICIO', 'cargo', 500),
    jsonb_build_object('fecha', '2027-05-31', 'descripcion', 'COMISION MANEJO DE CUENTA', 'cargo', 15.08),
    jsonb_build_object('fecha', '2027-05-20', 'descripcion', 'TRASPASO CUENTA PROPIA', 'abono', 10000)))::text, true);

-- 1) Se guardan los 6 renglones (los dos de 500 idénticos son dos) y el estado cuadra.
select set_config('app.r1', registrar_estado_cuenta(current_setting('app.cuenta')::uuid, current_setting('app.datos')::jsonb, 'estados/prueba75.pdf')::text, true);
select set_config('app.estado', current_setting('app.r1')::jsonb ->> 'estado_id', true);
select set_config('app.p1', concat(
  case when (current_setting('app.r1')::jsonb ->> 'nuevos')::int = 6 and (current_setting('app.r1')::jsonb ->> 'cuadra')::boolean
       then 'ok' else 'FALLO' end, ' — 6 renglones, cuadra: ', current_setting('app.r1')), true);

-- 2) Subir el mismo estado otra vez no duplica nada.
select set_config('app.r2', registrar_estado_cuenta(current_setting('app.cuenta')::uuid, current_setting('app.datos')::jsonb, null)::text, true);
select set_config('app.p2', concat(
  case when (current_setting('app.r2')::jsonb ->> 'nuevos')::int = 0 and (current_setting('app.r2')::jsonb ->> 'repetidos')::int = 6
       then 'ok' else 'FALLO' end, ' — resubir no duplica'), true);

-- 3) Propuesta: cobro y gasolina son "seguros"; los de 500 tienen dos candidatos y no lo son.
select set_config('app.r3', proponer_conciliacion(current_setting('app.estado')::uuid)::text, true);
select set_config('app.p3', concat(
  case when (select count(*) from jsonb_array_elements(current_setting('app.r3')::jsonb) e where (e ->> 'seguro')::boolean) = 2
        and (select bool_and(jsonb_array_length(e -> 'candidatos') = 2 and not (e ->> 'seguro')::boolean)
               from jsonb_array_elements(current_setting('app.r3')::jsonb) e where (e ->> 'monto')::numeric = 500)
       then 'ok' else 'FALLO' end, ' — 2 seguros; los de 500, dos candidatos cada uno'), true);

-- 4) Conciliar los seguros: 2, y la gasolina queda en la cuenta Banorte.
select set_config('app.r4', conciliar_seguros(current_setting('app.estado')::uuid)::text, true);
select set_config('app.p4', concat(
  case when (current_setting('app.r4')::jsonb ->> 'conciliados')::int = 2
        and (select cuenta_id::text from expediente_movimientos where id = current_setting('app.gas')::uuid) = current_setting('app.cuenta')
       then 'ok' else 'FALLO' end, ' — 2 conciliados; la gasolina toma la cuenta'), true);

-- 5) Elegir a mano el primer 500 deja al segundo con un solo candidato: ahora es seguro.
select set_config('app.b500', (select id::text from movimientos_banco where estado_id = current_setting('app.estado')::uuid
                                  and cargo = 500 order by created_at, id limit 1), true);
select set_config('app.r5', conciliar_movimiento(current_setting('app.b500')::uuid, current_setting('app.g500a')::uuid)::text, true);
select set_config('app.r5b', conciliar_seguros(current_setting('app.estado')::uuid)::text, true);
select set_config('app.p5', concat(
  case when (current_setting('app.r5b')::jsonb ->> 'conciliados')::int = 1
        and exists (select 1 from movimientos_banco where movimiento_id = current_setting('app.g500b')::uuid)
       then 'ok' else 'FALLO' end, ' — el segundo 500 se vuelve seguro y se concilia'), true);

-- 6) La comisión se registra desde el banco (comisión bancaria) y queda conciliada.
select set_config('app.bcom', (select id::text from movimientos_banco where estado_id = current_setting('app.estado')::uuid and cargo = 15.08), true);
select set_config('app.r6', registrar_desde_banco(current_setting('app.bcom')::uuid, 'comisiones_bancarias', null, null)::text, true);
select set_config('app.p6', concat(
  case when (select categoria = 'comisiones_bancarias' and monto = 15.08 and cuenta_id::text = current_setting('app.cuenta')
               from expediente_movimientos where id = (current_setting('app.r6')::jsonb ->> 'movimiento_id')::uuid)
        and (select estado from movimientos_banco where id = current_setting('app.bcom')::uuid) = 'conciliado'
       then 'ok' else 'FALLO' end, ' — comisión registrada desde el banco y conciliada'), true);

-- 7) El traspaso se ignora con su motivo; el estado queda sin pendientes.
select set_config('app.btras', (select id::text from movimientos_banco where estado_id = current_setting('app.estado')::uuid and abono = 10000), true);
select set_config('app.r7', ignorar_movimiento_banco(current_setting('app.btras')::uuid, 'Traspaso entre mis cuentas')::text, true);
select set_config('app.r7b', resumen_conciliacion(current_setting('app.estado')::uuid)::text, true);
select set_config('app.p7', concat(
  case when (current_setting('app.r7b')::jsonb #>> '{conteo,conciliados}')::int = 5
        and (current_setting('app.r7b')::jsonb #>> '{conteo,ignorados}')::int = 1
        and (current_setting('app.r7b')::jsonb #>> '{conteo,pendientes}')::int = 0
       then 'ok' else 'FALLO' end, ' — 5 conciliados, 1 ignorado, 0 pendientes'), true);

-- 8) Desconciliar regresa el renglón a pendiente y libera el movimiento del libro.
select set_config('app.r8', desconciliar_movimiento(current_setting('app.b500')::uuid)::text, true);
select set_config('app.p8', concat(
  case when (select estado = 'pendiente' and movimiento_id is null from movimientos_banco where id = current_setting('app.b500')::uuid)
        and exists (select 1 from jsonb_array_elements(resumen_conciliacion(current_setting('app.estado')::uuid) -> 'solo_en_libro') e
                     where e ->> 'movimiento_id' = current_setting('app.g500a'))
       then 'ok' else 'FALLO' end, ' — desconciliar: pendiente, y el gasto sale "solo en el libro"'), true);

-- 9) Quien no es admin no ve los movimientos del banco.
select set_config('request.jwt.claims',
  json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
set local role authenticated;
select set_config('app.p9', concat(
  case when (select count(*) from movimientos_banco) = 0 and (select count(*) from estados_cuenta) = 0
       then 'ok' else 'FALLO' end, ' — sin ser admin, nada'), true);
reset role;

select current_setting('app.p1') as resultado
union all select current_setting('app.p2')
union all select current_setting('app.p3')
union all select current_setting('app.p4')
union all select current_setting('app.p5')
union all select current_setting('app.p6')
union all select current_setting('app.p7')
union all select current_setting('app.p8')
union all select current_setting('app.p9');

-- No se prueba aquí porque lanza excepción: conciliar con otro monto o sentido, conciliar un gasto ya
-- conciliado, ignorar sin motivo, registrar un cobro sin cotización, y cualquier llamada sin ser admin.

rollback;
