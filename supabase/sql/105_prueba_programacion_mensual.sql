-- Prueba de 105 (programación mensual y recordatorio). Todo con rollback: no deja nada.
-- Correr con la CLI: npx supabase db query --linked -f supabase/sql/105_prueba_programacion_mensual.sql
-- Usa una póliza de prueba sobre un equipo nuevo de un cliente nuevo, con visitas en el mes siguiente.
begin;

select set_config('app.admin', (select id::text from perfiles where rol = 'admin' and activo order by created_at limit 1), true);
select set_config('app.tecnico', (select id::text from perfiles where rol = 'tecnico' and activo order by created_at limit 1), true);
select set_config('app.mes', (date_trunc('month', _hoy_merida()) + interval '1 month')::date::text, true);
select set_config('app.cliente', gen_random_uuid()::text, true);
select set_config('app.equipo', gen_random_uuid()::text, true);
select set_config('app.equipo2', gen_random_uuid()::text, true);

insert into clientes (id, nombre, telefono, zona) values
  (current_setting('app.cliente')::uuid, 'Cliente prueba 105', '9990000105', 'ZONA-105');
insert into equipos (id, cliente_id, tipo, marca, modelo, capacidad_kw, atributos) values
  (current_setting('app.equipo')::uuid, current_setting('app.cliente')::uuid, 'generador', 'Generac', 'P105', 22,
   '{"combustible":"gas_lp","enfriamiento":"aire"}'),
  (current_setting('app.equipo2')::uuid, current_setting('app.cliente')::uuid, 'generador', 'Kohler', 'K105', 14,
   '{"combustible":"gas_lp"}');
-- El segundo equipo no tiene póliza y le toca mantenimiento el día 10 del mes siguiente.
update equipos set proximo_mantenimiento = current_setting('app.mes')::date + 9
 where id = current_setting('app.equipo2')::uuid;

select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated', 'email', 'prueba@powermx')::text, true);
set local role authenticated;

-- La póliza empieza el día 5 del mes siguiente: la visita 1 cae en ese mes.
select set_config('app.poliza', (crear_poliza(jsonb_build_object(
  'equipo_id', current_setting('app.equipo'), 'nivel', 'estandar', 'alcance', 'aire',
  'inicio', (current_setting('app.mes')::date + 4)::text, 'subtotal', 1000)) ->> 'id'), true);
-- Si crear_poliza ya abrió la cita (cae dentro de 21 días), se quita para probar "sin cita".
reset role;
delete from ordenes_servicio where cita_id in
  (select cita_id from poliza_visitas where poliza_id = current_setting('app.poliza')::uuid and cita_id is not null);
select set_config('app.cita_previa', coalesce((select cita_id::text from poliza_visitas
  where poliza_id = current_setting('app.poliza')::uuid and numero = 1), ''), true);
update poliza_visitas set estado = 'pendiente', cita_id = null
 where poliza_id = current_setting('app.poliza')::uuid and numero = 1;
delete from citas where id = nullif(current_setting('app.cita_previa'), '')::uuid;
set local role authenticated;

-- 1 · Antes de abrir el mes: la visita sale "sin cita" y el equipo sin póliza sale como sugerido.
select set_config('app.p1', (select concat(
  jsonb_array_length(jsonb_path_query_array(r -> 'sin_cita', '$[*] ? (@.cliente == "Cliente prueba 105")')), '/',
  jsonb_array_length(jsonb_path_query_array(r -> 'sugeridos', '$[*] ? (@.cliente == "Cliente prueba 105")')))
  from (select programacion_mensual(current_setting('app.mes')::date) r) t), true);

-- 2 · Abrir el mes siguiente abre la cita de la visita 1 (por programar, con orden).
select set_config('app.p2', (abrir_programacion_mensual(current_setting('app.mes')::date) ->> 'ok'), true);
select set_config('app.p2b', (select concat(pv.estado, '/', c.estado, '/',
         (select count(*) from ordenes_servicio o where o.cita_id = c.id))
  from poliza_visitas pv join citas c on c.id = pv.cita_id
 where pv.poliza_id = current_setting('app.poliza')::uuid and pv.numero = 1), true);

-- 3 · Ahora la visita sale entre las citas (por programar) con su póliza y número de visita.
select set_config('app.p3', (select concat(x ->> 'estado', '/', x ->> 'visita', ' de ', x ->> 'visitas', '/', x ->> 'visita_tipo', '/', r ->> 'abierta')
  from (select programacion_mensual(current_setting('app.mes')::date) r) t,
       jsonb_array_elements(r -> 'citas') x
 where x ->> 'cliente' = 'Cliente prueba 105'), true);

-- 4 · Abrir dos veces no duplica citas.
select set_config('app.p4', (abrir_programacion_mensual(current_setting('app.mes')::date) ->> 'citas'), true);
select set_config('app.p4b', (select count(*)::text from citas where cliente_id = current_setting('app.cliente')::uuid), true);

-- 5 · Marcar revisado.
select set_config('app.p5', (marcar_programacion_revisada(current_setting('app.mes')::date) ->> 'revisada'), true);
select set_config('app.p5b', (select (programacion_mensual(current_setting('app.mes')::date) ->> 'revisada_en') is not null)::text, true);

-- 6 · El recordatorio del día anterior dice la visita de la póliza y pide confirmar.
reset role;
update citas set estado = 'programada', fecha = current_setting('app.mes')::date + 4, hora = '09:00'
 where id = (select cita_id from poliza_visitas where poliza_id = current_setting('app.poliza')::uuid and numero = 1);
select set_config('app.aviso', gen_random_uuid()::text, true);
insert into avisos (id, cita_id, tipo, destinatario, llave, nombre, telefono)
values (current_setting('app.aviso')::uuid,
        (select cita_id from poliza_visitas where poliza_id = current_setting('app.poliza')::uuid and numero = 1),
        'recordatorio', 'cliente', 'prueba105', 'Martha', '9990000105');
set local role authenticated;
select set_config('app.p6', (select texto_aviso(current_setting('app.aviso')::uuid)), true);

-- 7 · Un técnico no puede ver la programación.
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.tecnico'), 'role', 'authenticated')::text, true);
do $$ begin
  perform programacion_mensual(null);
  perform set_config('app.p7', 'pudo', true);
exception when others then
  perform set_config('app.p7', sqlstate, true);
end $$;

reset role;
select
  case when current_setting('app.p1') = '1/1' then 'ok' else 'FALLA ' || current_setting('app.p1') end as "1 sin cita y sugerido",
  case when current_setting('app.p2') = 'true' and current_setting('app.p2b') = 'agendada/por_programar/1' then 'ok'
       else 'FALLA ' || current_setting('app.p2b') end as "2 abrir el mes",
  case when current_setting('app.p3') = 'por_programar/1 de 4/menor/true' then 'ok' else 'FALLA ' || current_setting('app.p3') end as "3 en la lista",
  case when current_setting('app.p4') = '0' and current_setting('app.p4b') = '1' then 'ok'
       else 'FALLA ' || current_setting('app.p4') || '/' || current_setting('app.p4b') end as "4 no duplica",
  case when current_setting('app.p5') = 'true' and current_setting('app.p5b') = 'true' then 'ok' else 'FALLA' end as "5 revisado",
  case when current_setting('app.p6') like '%visita 1 de 4 de su póliza POL-%' and current_setting('app.p6') like '%Responda SÍ%'
        and current_setting('app.p6') like '%combustible suficiente%' then 'ok' else 'FALLA ' || current_setting('app.p6') end as "6 recordatorio",
  case when current_setting('app.p7') = '42501' then 'ok' else 'FALLA ' || current_setting('app.p7') end as "7 técnico no",
  current_setting('app.p6') as texto;
rollback;
