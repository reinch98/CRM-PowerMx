-- ---------------------------------------------------------------------------
-- Prueba de 42_inicio_admin.sql. Correr DESPUÉS del 42, y el bloque COMPLETO.
-- Todo en begin/rollback. SQL plano, sin bloques plpgsql (ver CLAUDE.md).
--
-- Como en la prueba del 40, no se comprueba que un número sea 3 —la base real cambia cada
-- día— sino la DIFERENCIA: se guarda el antes, se siembra un pendiente de cada clase y se
-- comprueba que su renglón subió 1. Así vale igual con la base vacía o con dos años de datos.
--
-- Consume folios (las secuencias no se revierten con el rollback).
-- ---------------------------------------------------------------------------

begin;

select set_config('app.admin',
         coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
         json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

select set_config('app.antes', inicio_admin()::text, true);

select set_config('app.p0', concat(
  case when (current_setting('app.antes')::jsonb ? 'fecha')
        and (current_setting('app.antes')::jsonb ? 'hoy')
        and (current_setting('app.antes')::jsonb ? 'urgente')
       then 'ok' else 'FALLO' end,
  ' — devuelve fecha, hoy y urgente. Hoy hay ',
  jsonb_array_length(current_setting('app.antes')::jsonb -> 'hoy'), ' cita(s) y ',
  jsonb_array_length(current_setting('app.antes')::jsonb -> 'urgente'), ' aviso(s)'), true);

-- ---- sembrar ----
select set_config('app.cli', gen_random_uuid()::text, true),
       set_config('app.eq',  gen_random_uuid()::text, true),
       set_config('app.cita', gen_random_uuid()::text, true);

insert into clientes (id, nombre, telefono)
values (current_setting('app.cli')::uuid, 'PRUEBA-42', '9990000042');

-- Una cita HOY, programada: tiene que salir en la agenda del día.
insert into citas (id, cliente_id, estado, fecha, hora, tipo_servicio)
values (current_setting('app.cita')::uuid, current_setting('app.cli')::uuid,
        'programada', current_date, '09:30', 'preventivo');

-- Un aviso sin mandar (nivel alto).
insert into avisos (cita_id, tipo, destinatario, llave, nombre, telefono, estado)
values (current_setting('app.cita')::uuid, 'confirmacion', 'cliente', 'c:prueba42',
        'PRUEBA-42', '9990000042', 'pendiente');

-- Una solicitud del sitio sin ver (nivel alto).
insert into solicitudes_web (nombre, telefono, telefono_norm, estado)
values ('PRUEBA-42', '9990000042', '9990000042', 'nueva');

-- Un equipo con el mantenimiento vencido (nivel medio).
insert into equipos (id, cliente_id, tipo, marca, proximo_mantenimiento)
values (current_setting('app.eq')::uuid, current_setting('app.cli')::uuid,
        'generador', 'Prueba42', current_date - 10);

select set_config('app.despues', inicio_admin()::text, true);

-- ---- comprobaciones ----

-- 1) La cita de hoy sale, con su hora y su cliente.
select set_config('app.p1', concat(
  case when exists (
        select 1 from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'hoy') e
         where e ->> 'cliente' = 'PRUEBA-42' and e ->> 'hora' = '09:30')
       then 'ok' else 'FALLO' end,
  ' — la cita de hoy sale con su hora y su cliente'), true);

-- 2) El aviso sin mandar subió (al menos 1: el trigger de citas ya crea el suyo al insertar la cita), con nivel alto y apuntando a la Agenda.
select set_config('app.p2', concat(
  case when coalesce((select (e ->> 'n')::int from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e where e ->> 'clave' = 'avisos'), 0)
          - coalesce((select (e ->> 'n')::int from jsonb_array_elements(current_setting('app.antes')::jsonb -> 'urgente') e where e ->> 'clave' = 'avisos'), 0) >= 1
       then 'ok' else 'FALLO' end,
  ' — avisos sin mandar subió ',
  coalesce((select (e ->> 'n')::int from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e where e ->> 'clave' = 'avisos'), 0)
  - coalesce((select (e ->> 'n')::int from jsonb_array_elements(current_setting('app.antes')::jsonb -> 'urgente') e where e ->> 'clave' = 'avisos'), 0),
  ', nivel ',
  coalesce((select e ->> 'nivel' from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e where e ->> 'clave' = 'avisos'), 'ninguno'),
  ', pantalla ',
  coalesce((select e ->> 'pantalla' from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e where e ->> 'clave' = 'avisos'), 'ninguna')), true);

-- 3) La solicitud del sitio también.
select set_config('app.p3', concat(
  case when coalesce((select (e ->> 'n')::int from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e where e ->> 'clave' = 'solicitudes'), 0)
          - coalesce((select (e ->> 'n')::int from jsonb_array_elements(current_setting('app.antes')::jsonb -> 'urgente') e where e ->> 'clave' = 'solicitudes'), 0) = 1
       then 'ok' else 'FALLO' end,
  ' — solicitudes del sitio sin ver subió 1 y apunta a ',
  coalesce((select e ->> 'pantalla' from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e where e ->> 'clave' = 'solicitudes'), 'ninguna')), true);

-- 4) El mantenimiento vencido también.
select set_config('app.p4', concat(
  case when coalesce((select (e ->> 'n')::int from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e where e ->> 'clave' = 'mantenimientos'), 0)
          - coalesce((select (e ->> 'n')::int from jsonb_array_elements(current_setting('app.antes')::jsonb -> 'urgente') e where e ->> 'clave' = 'mantenimientos'), 0) = 1
       then 'ok' else 'FALLO' end,
  ' — equipos con mantenimiento vencido subió 1'), true);

-- 5) El texto viene en palabras y con su número, listo para mostrar.
select set_config('app.p5', concat(
  case when (select e ->> 'texto' from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e
              where e ->> 'clave' = 'solicitudes') ~ '^[0-9]+ solicitud'
       then 'ok' else 'FALLO' end,
  ' — texto: "',
  coalesce((select e ->> 'texto' from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e where e ->> 'clave' = 'solicitudes'), ''), '"'), true);

-- 6) Los de nivel alto van antes que los de nivel medio: el orden es la propuesta.
select set_config('app.p6', concat(
  case when (select min(i) from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente')
             with ordinality t(e, i) where e ->> 'nivel' = 'medio')
          > (select max(i) from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente')
             with ordinality t(e, i) where e ->> 'nivel' = 'alto')
        or (select count(*) from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e
             where e ->> 'nivel' = 'medio') = 0
       then 'ok' else 'FALLO' end,
  ' — los avisos de nivel alto van antes que los de nivel medio'), true);

-- 7) Nada con cero: una lista de once avisos se deja de leer.
select set_config('app.p7', concat(
  case when not exists (
        select 1 from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e
         where (e ->> 'n')::int = 0)
       then 'ok' else 'FALLO' end,
  ' — ningún aviso viene en cero'), true);

-- 8) Cada aviso apunta a una pantalla que existe en el menú.
select set_config('app.p8', concat(
  case when not exists (
        select 1 from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e
         where e ->> 'pantalla' not in ('agenda','ordenes','almacen','clientes','contactos',
               'solicitudes','whatsapp','equipos','inventario','cotizaciones','requisiciones',
               'compras','tarifas','usuarios','agente'))
       then 'ok' else 'FALLO' end,
  ' — todos los avisos apuntan a una pantalla del menú'), true);

-- 9) Una cita cancelada de hoy no se muestra.
update citas set estado = 'cancelada' where id = current_setting('app.cita')::uuid;
select set_config('app.p9', concat(
  case when not exists (
        select 1 from jsonb_array_elements(inicio_admin() -> 'hoy') e
         where e ->> 'cliente' = 'PRUEBA-42')
       then 'ok' else 'FALLO' end,
  ' — una cita cancelada no aparece en el día'), true);

-- 10) Quien no es admin no ve nada.
select set_config('request.jwt.claims',
         json_build_object('sub', coalesce((select id::text from perfiles where rol = 'tecnico' limit 1), ''),
                           'role', 'authenticated')::text, true);
select set_config('app.p10', concat(
  case when inicio_admin() = '{}'::jsonb then 'ok' else 'FALLO' end,
  ' — el técnico recibe un objeto vacío'), true);

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
