-- Prueba de 79_corregir_forma_pago_tecnico.sql. Correr DESPUÉS del 79, el bloque COMPLETO. begin/rollback.
-- SQL plano (sin bloques plpgsql). Fechas de 2001 para no mezclarse con datos reales. Consume folios.
--
-- Pago a técnico (el admin hace de técnico): preventivo con cotización 600 + correctivo sin cotización 900,
-- registrado por transferencia desde Banorte; el egreso de 600 conciliado con un cargo del banco.
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);
update pagos_tecnico_config set pagar_desde = '2000-01-01' where id;

select set_config('app.banorte', (select id::text from cuentas_financieras where lower(nombre) = 'banorte negocio'), true),
       set_config('app.efectivo', (select id::text from cuentas_financieras where lower(nombre) = 'efectivo'), true),
       set_config('app.cli', gen_random_uuid()::text, true),
       set_config('app.cot', gen_random_uuid()::text, true),
       set_config('app.cita', gen_random_uuid()::text, true),
       set_config('app.o1', gen_random_uuid()::text, true),
       set_config('app.o2', gen_random_uuid()::text, true);

insert into clientes (id, nombre, telefono) values (current_setting('app.cli')::uuid, 'PRUEBA-79', '9990000079');
insert into cotizaciones (id, cliente_id, tipo, estado, partidas, subtotal, descuento, iva, total)
values (current_setting('app.cot')::uuid, current_setting('app.cli')::uuid, 'venta', 'aceptada', '[]'::jsonb, 1000, 0, 160, 1160);
insert into citas (id, cliente_id, tipo_servicio, fecha, estado, cotizacion_id)
values (current_setting('app.cita')::uuid, current_setting('app.cli')::uuid, 'preventivo', '2001-01-15', 'realizada',
        current_setting('app.cot')::uuid);
insert into ordenes_servicio (id, cliente_id, cita_id, fecha, tipo_servicio, estado, tecnico_id) values
  (current_setting('app.o1')::uuid, current_setting('app.cli')::uuid, current_setting('app.cita')::uuid,
   '2001-01-15', 'preventivo', 'cerrada', current_setting('app.admin')::uuid),
  (current_setting('app.o2')::uuid, current_setting('app.cli')::uuid, null,
   '2001-01-16', 'correctivo', 'cerrada', current_setting('app.admin')::uuid);
insert into tarifas_pago_tecnico (tipo_servicio, rol, monto, vigente_desde) values
  ('preventivo', 'responsable', 600, '2000-01-01'),
  ('correctivo', 'responsable', 900, '2000-01-01');

select set_config('app.pago', (proponer_pago_tecnico(current_setting('app.admin')::uuid, '2001-01-01', '2001-01-31') ->> 'pago_id'), true);
select set_config('app.x1', aprobar_pago_tecnico(current_setting('app.pago')::uuid)::text, true);
select set_config('app.x2', registrar_pago_tecnico(current_setting('app.pago')::uuid, 'transferencia', 'SPEI-79', '2001-01-31',
                                                   null, current_setting('app.banorte')::uuid)::text, true);
select set_config('app.estado', (registrar_estado_cuenta(current_setting('app.banorte')::uuid, jsonb_build_object(
  'periodo_desde', '2001-01-01', 'periodo_hasta', '2001-01-31',
  'movimientos', jsonb_build_array(jsonb_build_object('fecha', '2001-01-31', 'descripcion', 'SPEI PRUEBA-79', 'cargo', 600))),
  null) ->> 'estado_id'), true);
select set_config('app.banco', (select id::text from movimientos_banco where estado_id = current_setting('app.estado')::uuid), true);
select set_config('app.x3', conciliar_movimiento(current_setting('app.banco')::uuid,
  (select id from expediente_movimientos where pago_tecnico_id = current_setting('app.pago')::uuid and monto = 600))::text, true);

-- 1) Era efectivo y de la caja: forma, cuenta, fecha y referencia cambian en el pago y en sus 2 egresos;
--    el cargo de Banorte conciliado vuelve a pendiente porque ya no es de esa cuenta.
select set_config('app.r1', corregir_forma_pago_tecnico(current_setting('app.pago')::uuid, 'efectivo', '2001-02-02', '',
                                                        current_setting('app.efectivo')::uuid, 'Se pagó en efectivo')::text, true);
select set_config('app.p1', concat(
  case when (current_setting('app.r1')::jsonb ->> 'egresos')::int = 2
        and (current_setting('app.r1')::jsonb ->> 'banco_liberados')::int = 1
        and (select forma = 'efectivo' and fecha_pago = '2001-02-02' and referencia is null and estado = 'pagado'
               from pagos_tecnico where id = current_setting('app.pago')::uuid)
        and (select count(*) from expediente_movimientos
              where pago_tecnico_id = current_setting('app.pago')::uuid and forma = 'efectivo' and fecha = '2001-02-02'
                and cuenta_id::text = current_setting('app.efectivo')
                and referencia = 'PAGO-' || (select folio from pagos_tecnico where id = current_setting('app.pago')::uuid)) = 2
        and (select estado from movimientos_banco where id = current_setting('app.banco')::uuid) = 'pendiente'
        and exists (select 1 from auditoria where tabla = 'pagos_tecnico' and registro_id = current_setting('app.pago')::uuid
                     and accion = 'corregir_forma_pago_tecnico' and valor_anterior ->> 'forma' = 'transferencia')
       then 'ok' else 'FALLO' end, ' — corregido a efectivo: ', current_setting('app.r1')), true);

-- 2) Los montos no se tocan: siguen 600 al expediente y 900 al libro general.
select set_config('app.p2', concat(
  case when (select sum(monto) from expediente_movimientos where pago_tecnico_id = current_setting('app.pago')::uuid) = 1500
        and (select monto from expediente_movimientos
              where pago_tecnico_id = current_setting('app.pago')::uuid and cotizacion_id = current_setting('app.cot')::uuid) = 600
       then 'ok' else 'FALLO' end, ' — montos intactos'), true);

-- 3) Corregir otra vez en la MISMA cuenta no libera nada del banco.
select set_config('app.x4', conciliar_movimiento(current_setting('app.banco')::uuid,
  (select id from expediente_movimientos where pago_tecnico_id = current_setting('app.pago')::uuid and monto = 600))::text, true);
select set_config('app.r3', corregir_forma_pago_tecnico(current_setting('app.pago')::uuid, 'otro', '2001-02-02', 'Vale 12',
                                                        current_setting('app.efectivo')::uuid, null)::text, true);
select set_config('app.p3', concat(
  case when (current_setting('app.r3')::jsonb ->> 'banco_liberados')::int = 0
        and (select estado from movimientos_banco where id = current_setting('app.banco')::uuid) = 'conciliado'
        and (select forma = 'otro' and referencia = 'Vale 12' from pagos_tecnico where id = current_setting('app.pago')::uuid)
       then 'ok' else 'FALLO' end, ' — misma cuenta: el banco no se toca'), true);

select current_setting('app.p1') as resultado
union all select current_setting('app.p2')
union all select current_setting('app.p3');

-- No se prueba aquí porque lanza excepción: un pago que no está registrado, una forma inválida, sin fecha,
-- una cuenta que no existe, un expediente cerrado y cualquier llamada sin ser admin.

rollback;
