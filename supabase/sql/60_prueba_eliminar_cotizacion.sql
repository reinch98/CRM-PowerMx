-- Prueba de 60_eliminar_cotizacion.sql. Correr DESPUÉS del 60, el bloque COMPLETO. begin/rollback.
-- SQL plano (sin bloques plpgsql) y cada llamada a la función va en su propia sentencia: una
-- sentencia no ve lo que la función cambia dentro de ella misma.
-- Consume folios (las secuencias no se revierten con el rollback).
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

select set_config('app.cli', gen_random_uuid()::text, true),
       set_config('app.prod', gen_random_uuid()::text, true),
       set_config('app.cot', gen_random_uuid()::text, true),
       set_config('app.cita', gen_random_uuid()::text, true),
       set_config('app.orden', gen_random_uuid()::text, true);

insert into clientes (id, nombre, telefono)
values (current_setting('app.cli')::uuid, 'PRUEBA-60', '9990000060');
insert into productos (id, sku, nombre, categoria, activo)
values (current_setting('app.prod')::uuid, 'PRUEBA-60', 'Pieza de prueba', 'refaccion', true);
insert into cotizaciones (id, cliente_id, tipo, estado)
values (current_setting('app.cot')::uuid, current_setting('app.cli')::uuid, 'mantenimiento', 'borrador');
insert into citas (id, cliente_id, cotizacion_id, estado)
values (current_setting('app.cita')::uuid, current_setting('app.cli')::uuid, current_setting('app.cot')::uuid, 'por_programar');
insert into ordenes_servicio (id, cliente_id, cita_id)
values (current_setting('app.orden')::uuid, current_setting('app.cli')::uuid, current_setting('app.cita')::uuid);
insert into orden_surtido (orden_id, producto_id, cantidad_pedida)
values (current_setting('app.orden')::uuid, current_setting('app.prod')::uuid, 2);
insert into entregas (orden_id, estado) values (current_setting('app.orden')::uuid, 'pendiente');
insert into requisiciones (producto_id, cantidad, estado, cotizacion_id)
values (current_setting('app.prod')::uuid, 2, 'pendiente', current_setting('app.cot')::uuid);
insert into solicitudes_material (tecnico_id, cantidad, estado, orden_id, descripcion_libre)
values (current_setting('app.admin')::uuid, 1, 'pendiente', current_setting('app.orden')::uuid, 'prueba 60');
-- Se aparta y se libera lo mismo: la cotización ya no tiene nada apartado.
insert into movimientos_inventario (producto_id, tipo, cantidad, cotizacion_id, referencia, usuario)
values (current_setting('app.prod')::uuid, 'apartado', 2, current_setting('app.cot')::uuid, 'PRUEBA-60', 'prueba'),
       (current_setting('app.prod')::uuid, 'libera_apartado', 2, current_setting('app.cot')::uuid, 'PRUEBA-60', 'prueba');

-- 1) Vista previa: dice qué se borraría y no borra nada.
select set_config('app.r1', eliminar_cotizacion(current_setting('app.cot')::uuid)::text, true);
select set_config('app.p1', concat(
  case when (current_setting('app.r1')::jsonb ->> 'ok') = 'true'
        and (current_setting('app.r1')::jsonb ->> 'ejecutado') = 'false'
        and (current_setting('app.r1')::jsonb #>> '{resumen,citas}') = '1'
        and (current_setting('app.r1')::jsonb #>> '{resumen,ordenes}') = '1'
        and (current_setting('app.r1')::jsonb #>> '{resumen,movimientos_apartado}') = '2'
        and (current_setting('app.r1')::jsonb #>> '{resumen,pedidos}') = '1'
       then 'ok' else 'FALLO' end,
  ' — vista previa: ', current_setting('app.r1')::jsonb -> 'resumen'), true);

select set_config('app.p2', concat(
  case when (select count(*) from cotizaciones where id = current_setting('app.cot')::uuid) = 1
        and (select count(*) from ordenes_servicio where id = current_setting('app.orden')::uuid) = 1
       then 'ok' else 'FALLO' end,
  ' — la vista previa no borró nada'), true);

-- 2) Una entrada de inventario ligada a la orden la bloquea.
insert into movimientos_inventario (producto_id, tipo, cantidad, orden_id, referencia, usuario)
values (current_setting('app.prod')::uuid, 'entrada', 5, current_setting('app.orden')::uuid, 'PRUEBA-60', 'prueba');
select set_config('app.r3', eliminar_cotizacion(current_setting('app.cot')::uuid, true)::text, true);
select set_config('app.p3', concat(
  case when (current_setting('app.r3')::jsonb ->> 'ok') = 'false'
        and (current_setting('app.r3')::jsonb ->> 'ejecutado') = 'false'
        and (select count(*) from cotizaciones where id = current_setting('app.cot')::uuid) = 1
       then 'ok' else 'FALLO' end,
  ' — con una entrada de inventario se niega aunque se pida ejecutar: ',
  current_setting('app.r3')::jsonb -> 'bloqueos'), true);
delete from movimientos_inventario where tipo = 'entrada' and referencia = 'PRUEBA-60';

-- 3) Material todavía apartado la bloquea.
insert into movimientos_inventario (producto_id, tipo, cantidad, cotizacion_id, referencia, usuario)
values (current_setting('app.prod')::uuid, 'apartado', 1, current_setting('app.cot')::uuid, 'PRUEBA-60', 'prueba');
select set_config('app.r4', eliminar_cotizacion(current_setting('app.cot')::uuid, true)::text, true);
select set_config('app.p4', concat(
  case when (current_setting('app.r4')::jsonb ->> 'ok') = 'false'
        and (current_setting('app.r4')::jsonb #>> '{bloqueos,0}') like '%apartado%'
       then 'ok' else 'FALLO' end,
  ' — con material apartado se niega: ', current_setting('app.r4')::jsonb -> 'bloqueos'), true);
delete from movimientos_inventario
 where tipo = 'apartado' and cantidad = 1 and referencia = 'PRUEBA-60';

-- 4) Ejecutar: se va todo lo de la cotización y el cliente se queda.
select set_config('app.r5', eliminar_cotizacion(current_setting('app.cot')::uuid, true)::text, true);
select set_config('app.p5', concat(
  case when (current_setting('app.r5')::jsonb ->> 'ejecutado') = 'true' then 'ok' else 'FALLO' end,
  ' — ejecutó el borrado'), true);

select set_config('app.p6', concat(
  case when (select count(*) from cotizaciones where id = current_setting('app.cot')::uuid) = 0
        and (select count(*) from citas where id = current_setting('app.cita')::uuid) = 0
        and (select count(*) from ordenes_servicio where id = current_setting('app.orden')::uuid) = 0
        and (select count(*) from orden_surtido where orden_id = current_setting('app.orden')::uuid) = 0
        and (select count(*) from entregas where orden_id = current_setting('app.orden')::uuid) = 0
        and (select count(*) from solicitudes_material where orden_id = current_setting('app.orden')::uuid) = 0
        and (select count(*) from requisiciones where cotizacion_id = current_setting('app.cot')::uuid) = 0
        and (select count(*) from movimientos_inventario where cotizacion_id = current_setting('app.cot')::uuid) = 0
       then 'ok' else 'FALLO' end,
  ' — no queda nada de la cotización, su cita, su orden, su surtido, su pedido ni sus movimientos'), true);

select set_config('app.p7', concat(
  case when (select count(*) from clientes where id = current_setting('app.cli')::uuid) = 1
        and (select count(*) from productos where id = current_setting('app.prod')::uuid) = 1
       then 'ok' else 'FALLO' end,
  ' — el cliente y el producto siguen existiendo'), true);

select set_config('app.p8', concat(
  case when (select count(*) from auditoria where tabla = 'cotizaciones' and accion = 'eliminar'
               and registro_id = current_setting('app.cot')::uuid) = 1
       then 'ok' else 'FALLO' end,
  ' — quedó anotado en auditoría'), true);

select current_setting('app.p1') as resultado
union all select current_setting('app.p2')
union all select current_setting('app.p3')
union all select current_setting('app.p4')
union all select current_setting('app.p5')
union all select current_setting('app.p6')
union all select current_setting('app.p7')
union all select current_setting('app.p8');

rollback;
