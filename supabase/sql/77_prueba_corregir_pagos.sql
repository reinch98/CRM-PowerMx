-- Prueba de 77_corregir_pagos.sql. Correr DESPUÉS del 77, el bloque COMPLETO. begin/rollback.
-- SQL plano (sin bloques plpgsql). Fechas de 2001 para no mezclarse con datos reales. Consume folios.
--
-- Técnico (el admin hace de técnico): preventivo con cotización 600 + correctivo sin cotización 900 = 1,500,
-- pagado desde Banorte; el egreso de 600 queda conciliado con un cargo del banco.
-- Proveedor: factura por pagar de 1,160 pagada completa.
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);
update pagos_tecnico_config set pagar_desde = '2000-01-01' where id;

select set_config('app.cuenta', (select id::text from cuentas_financieras where lower(nombre) = 'banorte negocio'), true),
       set_config('app.cli', gen_random_uuid()::text, true),
       set_config('app.cot', gen_random_uuid()::text, true),
       set_config('app.cita', gen_random_uuid()::text, true),
       set_config('app.o1', gen_random_uuid()::text, true),
       set_config('app.o2', gen_random_uuid()::text, true),
       set_config('app.cfdi', gen_random_uuid()::text, true);

insert into clientes (id, nombre, telefono) values (current_setting('app.cli')::uuid, 'PRUEBA-77', '9990000077');
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
select set_config('app.x2', registrar_pago_tecnico(current_setting('app.pago')::uuid, 'transferencia', 'SPEI-77', '2001-01-31',
                                                   null, current_setting('app.cuenta')::uuid)::text, true);

-- El egreso de 600 conciliado con un cargo del banco.
select set_config('app.estado', (registrar_estado_cuenta(current_setting('app.cuenta')::uuid, jsonb_build_object(
  'periodo_desde', '2001-01-01', 'periodo_hasta', '2001-01-31',
  'movimientos', jsonb_build_array(jsonb_build_object('fecha', '2001-01-31', 'descripcion', 'SPEI PRUEBA-77', 'cargo', 600))),
  null) ->> 'estado_id'), true);
select set_config('app.banco', (select id::text from movimientos_banco where estado_id = current_setting('app.estado')::uuid), true);
select set_config('app.x3', conciliar_movimiento(current_setting('app.banco')::uuid,
  (select id from expediente_movimientos where pago_tecnico_id = current_setting('app.pago')::uuid and monto = 600))::text, true);

-- 1) Los egresos del pago quedan ligados a él (pago_tecnico_id) y el de 600 está conciliado.
select set_config('app.p1', concat(
  case when (select count(*) from expediente_movimientos where pago_tecnico_id = current_setting('app.pago')::uuid) = 2
        and (select estado from movimientos_banco where id = current_setting('app.banco')::uuid) = 'conciliado'
       then 'ok' else 'FALLO' end, ' — 2 egresos ligados al pago; el de 600 conciliado'), true);

-- 2) Reabrir el pago pagado: borra sus 2 egresos, libera el banco y vuelve a borrador.
select set_config('app.r2', reabrir_pago_tecnico(current_setting('app.pago')::uuid, 'Monto equivocado')::text, true);
select set_config('app.p2', concat(
  case when current_setting('app.r2')::jsonb ->> 'estaba' = 'pagado'
        and (current_setting('app.r2')::jsonb ->> 'egresos_borrados')::int = 2
        and (current_setting('app.r2')::jsonb ->> 'banco_liberados')::int = 1
        and (select estado = 'propuesto' and fecha_pago is null and forma is null from pagos_tecnico where id = current_setting('app.pago')::uuid)
        and (select count(*) from expediente_movimientos where pago_tecnico_id = current_setting('app.pago')::uuid) = 0
        and (select estado from movimientos_banco where id = current_setting('app.banco')::uuid) = 'pendiente'
        and exists (select 1 from auditoria where tabla = 'pagos_tecnico' and registro_id = current_setting('app.pago')::uuid
                     and accion = 'reabrir_pago_tecnico')
       then 'ok' else 'FALLO' end, ' — reabierto: ', current_setting('app.r2')), true);

-- 3) En borrador, cambiar el monto de la orden con cotización: 600 → 750, total 1,650.
select set_config('app.r3', fijar_monto_linea_pago(
  (select id from pagos_tecnico_lineas where pago_id = current_setting('app.pago')::uuid and orden_id = current_setting('app.o1')::uuid),
  750)::text, true);
select set_config('app.p3', concat(
  case when (current_setting('app.r3')::jsonb ->> 'total')::numeric = 1650 then 'ok' else 'FALLO' end,
  ' — total con el monto corregido: ', current_setting('app.r3')::jsonb ->> 'total'), true);

-- 4) Aprobado se puede regresar a borrador sin borrar nada (no había egresos).
select set_config('app.x4', aprobar_pago_tecnico(current_setting('app.pago')::uuid)::text, true);
select set_config('app.r4', reabrir_pago_tecnico(current_setting('app.pago')::uuid, 'Falta un bono')::text, true);
select set_config('app.p4', concat(
  case when current_setting('app.r4')::jsonb ->> 'estaba' = 'aprobado'
        and (current_setting('app.r4')::jsonb ->> 'egresos_borrados')::int = 0
        and (select estado from pagos_tecnico where id = current_setting('app.pago')::uuid) = 'propuesto'
       then 'ok' else 'FALLO' end, ' — aprobado vuelve a borrador'), true);

-- 5) Volver a aprobar y registrar: el expediente recibe 750 (no 600) y no quedan egresos viejos.
select set_config('app.x5', aprobar_pago_tecnico(current_setting('app.pago')::uuid)::text, true);
select set_config('app.x6', registrar_pago_tecnico(current_setting('app.pago')::uuid, 'transferencia', 'SPEI-77B', '2001-02-01',
                                                   null, current_setting('app.cuenta')::uuid)::text, true);
select set_config('app.p5', concat(
  case when (select count(*) from expediente_movimientos where cotizacion_id = current_setting('app.cot')::uuid and categoria = 'tecnico') = 1
        and (select monto from expediente_movimientos where cotizacion_id = current_setting('app.cot')::uuid and categoria = 'tecnico') = 750
        and (select count(*) from expediente_movimientos where pago_tecnico_id = current_setting('app.pago')::uuid) = 2
       then 'ok' else 'FALLO' end, ' — registrado de nuevo con 750'), true);

-- 6) En la base real no quedó ningún egreso de pago a técnicos sin ligar a su pago (el llenado hacia atrás).
select set_config('app.p6', concat(
  case when (select count(*) from expediente_movimientos
              where categoria = 'tecnico' and notas like 'Pago a técnicos PAGO-%' and pago_tecnico_id is null) = 0
       then 'ok' else 'FALLO' end, ' — todos los egresos de pagos a técnicos ligados a su pago'), true);

-- 7) Proveedor: pagar la factura completa y verla en "pagos registrados".
insert into cfdi (id, uuid_fiscal, sentido, fecha, rfc_emisor, nombre_emisor, rfc_receptor, subtotal, total, iva_trasladado,
                  metodo_pago, por_pagar, vence, categoria, estado_sat)
values (current_setting('app.cfdi')::uuid, gen_random_uuid()::text, 'recibido', '2001-02-01 12:00-06', 'PPP010101PPP',
        'PRUEBA-77 PROVEEDOR', 'XAXX010101000', 1000, 1160, 160, 'PPD', true, '2001-03-01', 'material', 'vigente');
select set_config('app.r7', pagar_cfdi(current_setting('app.cfdi')::uuid, 1160, '2001-02-05', current_setting('app.cuenta')::uuid, 'transferencia', null)::text, true);
select set_config('app.mov', current_setting('app.r7')::jsonb ->> 'movimiento_id', true);
select set_config('app.r7b', pagos_cfdi_registrados(20000)::text, true);
select set_config('app.p7', concat(
  case when (current_setting('app.r7')::jsonb ->> 'saldo')::numeric = 0
        and exists (select 1 from jsonb_array_elements(current_setting('app.r7b')::jsonb) e
                     where e ->> 'movimiento_id' = current_setting('app.mov') and (e ->> 'saldo')::numeric = 0
                       and (e ->> 'monto')::numeric = 1160 and not (e ->> 'conciliado')::boolean)
       then 'ok' else 'FALLO' end, ' — pagada y listada en pagos registrados'), true);

-- 8) Deshacer ese pago: la factura vuelve a deber 1,160 y regresa a "Por pagar".
select set_config('app.r8', deshacer_pago_cfdi(current_setting('app.mov')::uuid, 'Era un pago parcial')::text, true);
select set_config('app.r8b', cuentas_por_pagar()::text, true);
select set_config('app.p8', concat(
  case when (current_setting('app.r8')::jsonb ->> 'saldo')::numeric = 1160
        and not exists (select 1 from expediente_movimientos where id = current_setting('app.mov')::uuid)
        and exists (select 1 from jsonb_array_elements(current_setting('app.r8b')::jsonb -> 'cuentas') e
                     where e ->> 'cfdi_id' = current_setting('app.cfdi') and (e ->> 'saldo')::numeric = 1160)
        and exists (select 1 from auditoria where tabla = 'cfdi' and registro_id = current_setting('app.cfdi')::uuid
                     and accion = 'deshacer_pago_cfdi')
       then 'ok' else 'FALLO' end, ' — pago deshecho; la factura vuelve a Por pagar con 1,160'), true);

select current_setting('app.p1') as resultado
union all select current_setting('app.p2')
union all select current_setting('app.p3')
union all select current_setting('app.p4')
union all select current_setting('app.p5')
union all select current_setting('app.p6')
union all select current_setting('app.p7')
union all select current_setting('app.p8');

-- No se prueba aquí porque lanza excepción: reabrir sin motivo, reabrir un pago cancelado, reabrir cuando el
-- técnico ya tiene otro borrador, reabrir con un expediente cerrado, fijar el monto de un pago que no está en
-- borrador o de un bono, deshacer un movimiento que no es pago de "Por pagar", y todo sin ser admin.

rollback;
