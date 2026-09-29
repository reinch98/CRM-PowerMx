-- ---------------------------------------------------------------------------
-- Prueba de 40_pendientes_admin.sql. Correr DESPUÉS del 40, y el bloque COMPLETO.
-- Todo en begin/rollback. SQL plano, sin bloques plpgsql (ver CLAUDE.md).
--
-- CÓMO SE PRUEBA UN CONTADOR. No sirve comprobar que el número sea 3, porque la base real ya
-- trae lo suyo y cambia cada día. Lo que se prueba es la **diferencia**: se guarda el conteo
-- de antes, se siembra exactamente un pendiente de cada clase, y se comprueba que cada clave
-- subió exactamente 1. Así la prueba vale igual con la base vacía o con dos años de datos.
--
-- Ojo: se siembran clientes, equipos y órdenes, así que consume folios (las secuencias no se
-- revierten con el rollback).
-- ---------------------------------------------------------------------------

begin;

-- Llamar como admin: `pendientes_admin()` devuelve `{}` a quien no lo sea, y el editor SQL no
-- trae claims (ver "Pruebas en el editor SQL" en CLAUDE.md).
select set_config('app.admin',
         coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
         json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

select set_config('app.antes', pendientes_admin()::text, true);

select set_config('app.p0', concat(
  case when nullif(current_setting('app.admin'), '') is null then 'FALLO: no hay admin'
       else 'ok' end,
  ' — llamando como admin; antes: ', current_setting('app.antes')), true);

-- ---- sembrar UN pendiente de cada clase ----
select set_config('app.cli',  gen_random_uuid()::text, true),
       set_config('app.eq',   gen_random_uuid()::text, true),
       set_config('app.ord',  gen_random_uuid()::text, true),
       set_config('app.prod', gen_random_uuid()::text, true),
       set_config('app.ctc',  gen_random_uuid()::text, true);

insert into clientes (id, nombre, telefono)
values (current_setting('app.cli')::uuid, 'PRUEBA-40', '9990000040');

insert into equipos (id, cliente_id, tipo, marca)
values (current_setting('app.eq')::uuid, current_setting('app.cli')::uuid, 'generador', 'Prueba40');

insert into productos (id, sku, categoria, nombre, unidad, precio, activo)
values (current_setting('app.prod')::uuid, 'PRUEBA40-P', 'refaccion', 'Pieza de prueba', 'pieza', 100, true);

-- agenda: una cita por programar + un aviso pendiente (los dos suman en la misma clave)
insert into citas (cliente_id, equipo_id, estado, tipo_servicio)
values (current_setting('app.cli')::uuid, current_setting('app.eq')::uuid, 'por_programar', 'preventivo');

insert into avisos (cita_id, tipo, destinatario, llave, nombre, telefono, estado)
select id, 'confirmacion', 'cliente', 'c:prueba40', 'PRUEBA-40', '9990000040', 'pendiente'
  from citas where cliente_id = current_setting('app.cli')::uuid limit 1;

-- ordenes: una cerrada, marcada para enviar, sin envío registrado
insert into ordenes_servicio (id, cliente_id, equipo_id, estado, enviar_al_cerrar)
values (current_setting('app.ord')::uuid, current_setting('app.cli')::uuid,
        current_setting('app.eq')::uuid, 'cerrada', true);

-- solicitudes: una del sitio, sin ver
insert into solicitudes_web (nombre, telefono, telefono_norm, estado)
values ('PRUEBA-40', '9990000040', '9990000040', 'nueva');

-- whatsapp: una conversación con mensajes sin leer
insert into conversaciones (telefono, sin_leer, estado)
values ('9990000041', 2, 'abierta');

-- cotizaciones: un borrador que propuso el agente
insert into cotizaciones (cliente_id, equipo_id, partidas, estado, origen, tipo)
values (current_setting('app.cli')::uuid, current_setting('app.eq')::uuid,
        '[]'::jsonb, 'borrador', 'whatsapp', 'preventivo');

-- almacen: una entrega esperando firma
insert into entregas (orden_id, estado)
values (current_setting('app.ord')::uuid, 'pendiente');

-- requisiciones: un pedido que todavía no se pide
insert into requisiciones (producto_id, cantidad, estado)
values (current_setting('app.prod')::uuid, 2, 'pendiente');

select set_config('app.despues', pendientes_admin()::text, true);
select set_config('app.p1', concat('después: ', current_setting('app.despues')), true);

-- ---- cada clave tiene que haber subido exactamente 1 (la agenda, 2: cita + aviso) ----
select set_config('app.p2', concat(
  case when coalesce((current_setting('app.despues')::jsonb ->> 'agenda')::int, 0)
          - coalesce((current_setting('app.antes')::jsonb ->> 'agenda')::int, 0) = 2
       then 'ok' else 'FALLO' end,
  ' — agenda subió ',
  coalesce((current_setting('app.despues')::jsonb ->> 'agenda')::int, 0)
  - coalesce((current_setting('app.antes')::jsonb ->> 'agenda')::int, 0),
  ' (se esperaban 2: la cita por programar y el aviso sin mandar)'), true);

select set_config('app.p3', concat(
  case when coalesce((current_setting('app.despues')::jsonb ->> 'ordenes')::int, 0)
          - coalesce((current_setting('app.antes')::jsonb ->> 'ordenes')::int, 0) = 1
       then 'ok' else 'FALLO' end,
  ' — ordenes (por enviar) subió ',
  coalesce((current_setting('app.despues')::jsonb ->> 'ordenes')::int, 0)
  - coalesce((current_setting('app.antes')::jsonb ->> 'ordenes')::int, 0)), true);

select set_config('app.p4', concat(
  case when coalesce((current_setting('app.despues')::jsonb ->> 'solicitudes')::int, 0)
          - coalesce((current_setting('app.antes')::jsonb ->> 'solicitudes')::int, 0) = 1
       then 'ok' else 'FALLO' end,
  ' — solicitudes del sitio subió ',
  coalesce((current_setting('app.despues')::jsonb ->> 'solicitudes')::int, 0)
  - coalesce((current_setting('app.antes')::jsonb ->> 'solicitudes')::int, 0)), true);

select set_config('app.p5', concat(
  case when coalesce((current_setting('app.despues')::jsonb ->> 'whatsapp')::int, 0)
          - coalesce((current_setting('app.antes')::jsonb ->> 'whatsapp')::int, 0) = 1
       then 'ok' else 'FALLO' end,
  ' — whatsapp sin leer subió ',
  coalesce((current_setting('app.despues')::jsonb ->> 'whatsapp')::int, 0)
  - coalesce((current_setting('app.antes')::jsonb ->> 'whatsapp')::int, 0),
  ' (una conversación con 2 mensajes cuenta como 1)'), true);

select set_config('app.p6', concat(
  case when coalesce((current_setting('app.despues')::jsonb ->> 'cotizaciones')::int, 0)
          - coalesce((current_setting('app.antes')::jsonb ->> 'cotizaciones')::int, 0) = 1
       then 'ok' else 'FALLO' end,
  ' — cotizaciones por revisar subió ',
  coalesce((current_setting('app.despues')::jsonb ->> 'cotizaciones')::int, 0)
  - coalesce((current_setting('app.antes')::jsonb ->> 'cotizaciones')::int, 0)), true);

select set_config('app.p7', concat(
  case when coalesce((current_setting('app.despues')::jsonb ->> 'almacen')::int, 0)
          - coalesce((current_setting('app.antes')::jsonb ->> 'almacen')::int, 0) = 1
       then 'ok' else 'FALLO' end,
  ' — almacen subió ',
  coalesce((current_setting('app.despues')::jsonb ->> 'almacen')::int, 0)
  - coalesce((current_setting('app.antes')::jsonb ->> 'almacen')::int, 0),
  ' (la entrega por firmar)'), true);

select set_config('app.p8', concat(
  case when coalesce((current_setting('app.despues')::jsonb ->> 'requisiciones')::int, 0)
          - coalesce((current_setting('app.antes')::jsonb ->> 'requisiciones')::int, 0) = 1
       then 'ok' else 'FALLO' end,
  ' — pedidos pendientes subió ',
  coalesce((current_setting('app.despues')::jsonb ->> 'requisiciones')::int, 0)
  - coalesce((current_setting('app.antes')::jsonb ->> 'requisiciones')::int, 0)), true);

-- ---- lo que NO se cuenta ----
-- Un pedido ya puesto al proveedor no es trabajo del admin.
insert into requisiciones (producto_id, cantidad, estado)
values (current_setting('app.prod')::uuid, 5, 'pedida');

select set_config('app.p9', concat(
  case when coalesce((pendientes_admin() ->> 'requisiciones')::int, 0)
          = coalesce((current_setting('app.despues')::jsonb ->> 'requisiciones')::int, 0)
       then 'ok' else 'FALLO' end,
  ' — un pedido en estado "pedida" no sube el contador (está con el proveedor)'), true);

-- ---- quien no es admin no ve nada ----
select set_config('request.jwt.claims',
         json_build_object('sub', coalesce((select id::text from perfiles where rol = 'tecnico' limit 1), ''),
                           'role', 'authenticated')::text, true);

select set_config('app.p10', concat(
  case when pendientes_admin() = '{}'::jsonb then 'ok' else 'FALLO' end,
  ' — el técnico recibe ', pendientes_admin()::text, ' (debe ser un objeto vacío)'), true);

select current_setting('app.p0', true) as resultado
union all select current_setting('app.p1', true)
union all select current_setting('app.p2', true)
union all select current_setting('app.p3', true)
union all select current_setting('app.p4', true)
union all select current_setting('app.p5', true)
union all select current_setting('app.p6', true)
union all select current_setting('app.p7', true)
union all select current_setting('app.p8', true)
union all select current_setting('app.p9', true)
union all select current_setting('app.p10', true);

rollback;
