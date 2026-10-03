-- ---------------------------------------------------------------------------
-- Prueba de 57_campanas_whatsapp.sql. Correr DESPUÉS del 56 y el 57, el bloque COMPLETO.
-- begin/rollback: no deja nada. SQL plano, sin plpgsql. Usa el mes 2099-01 para no chocar
-- con una campaña real. (Proponer con una tanda pendiente lanza excepción: se prueba a mano.)
-- ---------------------------------------------------------------------------

begin;

select set_config('app.admin',
         coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('app.p00', case when nullif(current_setting('app.admin'), '') is null
                                  then 'FALLO: no hay admin activo' else 'ok — hay un admin activo' end, true);
select set_config('request.jwt.claims',
         json_build_object('sub', nullif(current_setting('app.admin'), ''), 'role', 'authenticated', 'email', 'admin@prueba')::text, true);
set local role authenticated;

-- A y E van; B pidió BAJA; C recibió marketing hace poco; D no tiene plantilla.
insert into wa_bajas (telefono_norm, origen) values ('9990005702', 'oficina') on conflict do nothing;
insert into salida_wa (llave, telefono, tipo, plantilla, origen, categoria, estado)
values ('prueba57:reciente', '9990005703', 'plantilla', 'mantenimiento_programado', 'campana', 'marketing', 'enviado');

insert into campana_envios (mes, categoria, prioridad, telefono, nombre, equipo, ultimo_servicio, plantilla, orden) values
  ('2099-01', 'Le toca este mes', 'alta',  '9990005701', 'Cliente A', 'Generac 22 kW', '10/01/2098', 'mantenimiento_programado', 1),
  ('2099-01', 'Le toca este mes', 'alta',  '9990005702', 'Cliente B', null, null, 'mantenimiento_programado', 2),
  ('2099-01', 'Atrasado',         'media', '9990005703', 'Cliente C', null, null, 'recordatorio_mantenimiento', 3),
  ('2099-01', 'Reactivación',     'baja',  '9990005704', 'Cliente D', null, null, null, 4),
  ('2099-01', 'Reactivación',     'baja',  '9990005705', 'Cliente E', null, null, 'reactivacion_cliente', 5);

select set_config('app.t', proponer_tanda('2099-01', 2)::text, true);
select set_config('app.tanda', current_setting('app.t')::jsonb ->> 'tanda_id', true);
select set_config('app.p1', concat(
         case when (current_setting('app.t')::jsonb ->> 'en_tanda') = '2' and (current_setting('app.t')::jsonb ->> 'omitidos') = '3'
               and (select string_agg(nombre, ',' order by nombre) from campana_envios where mes = '2099-01' and estado = 'en_tanda') = 'Cliente A,Cliente E'
              then 'ok' else 'FALLO' end,
         ' — la tanda toma a A y E y omite BAJA, marketing reciente y sin plantilla: ', current_setting('app.t')), true);
select set_config('app.p2', concat(
         case when (select motivo from campana_envios where mes = '2099-01' and nombre = 'Cliente B') = 'pidió BAJA'
               and (select motivo from campana_envios where mes = '2099-01' and nombre = 'Cliente C') = 'ya recibió marketing hace poco'
              then 'ok' else 'FALLO' end, ' — cada omitido dice por qué'), true);

select quitar_de_tanda(array[(select id from campana_envios where mes = '2099-01' and nombre = 'Cliente E')]);
select set_config('app.p3', concat(
         case when (select estado from campana_envios where mes = '2099-01' and nombre = 'Cliente E') = 'propuesto'
              then 'ok' else 'FALLO' end, ' — quitar de la tanda lo regresa a propuesto (otra semana)'), true);

select set_config('app.a', aprobar_tanda(current_setting('app.tanda')::uuid)::text, true);
select set_config('app.sal', coalesce((select salida_id::text from campana_envios where mes = '2099-01' and nombre = 'Cliente A'), ''), true);
select set_config('app.p4', concat(
         case when (current_setting('app.a')::jsonb ->> 'a_la_cola') = '1'
               and (current_setting('app.a')::jsonb ->> 'esperan_plantilla') = '1'
               and (select categoria = 'marketing' and estado = 'pendiente' and variables ->> 'equipo' = 'Generac 22 kW'
                      from salida_wa where id = nullif(current_setting('app.sal'), '')::uuid)
              then 'ok' else 'FALLO' end,
         ' — aprobar mete a A a la cola como marketing (espera plantilla aprobada): ', current_setting('app.a')), true);

select set_config('app.a2', aprobar_tanda(current_setting('app.tanda')::uuid)::text, true);
select set_config('app.p5', concat(
         case when (current_setting('app.a2')::jsonb ->> 'sin_cambio') = 'true'
               and (select count(*) from salida_wa where llave like 'campana:%' and telefono_norm = '9990005701') = 1
              then 'ok' else 'FALLO' end, ' — aprobar dos veces no duplica'), true);

-- Simula que salió hace una hora y que el cliente contestó.
update salida_wa set estado = 'enviado', enviado_en = now() - interval '1 hour'
 where id = current_setting('app.sal')::uuid;
select registrar_mensaje_entrante('5219990005701', 'wamid.prueba57.in', 'Sí, agéndenme', 'Cliente A');
select set_config('app.r', resultados_campana('2099-01')::text, true);
select set_config('app.p6', concat(
         case when (current_setting('app.r')::jsonb ->> 'enviados') = '1' and (current_setting('app.r')::jsonb ->> 'respondieron') = '1'
               and (current_setting('app.r')::jsonb ->> 'por_proponer') = '1'
              then 'ok' else 'FALLO' end,
         ' — resultados: 1 enviado, 1 respondió, 1 queda por proponer'), true);

select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
select set_config('app.p7', concat(
         case when (select count(*) from campana_envios) = 0 then 'ok' else 'FALLO' end,
         ' — una cuenta sin rol no ve la campaña'), true);
reset role;
select set_config('app.p8', concat(
         case when not has_table_privilege('anon', 'campana_envios', 'select')
               and not has_function_privilege('anon', 'aprobar_tanda(uuid)', 'execute')
              then 'ok' else 'FALLO' end, ' — anon no lee ni aprueba'), true);

select current_setting('app.p00') as p00, current_setting('app.p1') as p1, current_setting('app.p2') as p2,
       current_setting('app.p3') as p3, current_setting('app.p4') as p4, current_setting('app.p5') as p5,
       current_setting('app.p6') as p6, current_setting('app.p7') as p7, current_setting('app.p8') as p8;

rollback;
