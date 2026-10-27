-- Prueba del 92 (con rollback: no deja nada). Correr con la CLI:
--   npx supabase db query --linked -f supabase/sql/92_prueba_ejemplos_agente.sql
begin;

-- Escenario: una conversación de prueba con la ventana abierta, dos mensajes del cliente (uno con
-- teléfono y correo) y un borrador del agente.
select set_config('app.conv', gen_random_uuid()::text, true);
insert into conversaciones (id, telefono, ventana_hasta)
values (current_setting('app.conv')::uuid, '529990009201', now() + interval '20 hours');
insert into mensajes_wa (conversacion_id, direccion, tipo, texto, estado, created_at)
values (current_setting('app.conv')::uuid, 'entrante', 'texto', 'Hola, ¿dan mantenimiento?', 'recibido', now() - interval '3 minutes'),
       (current_setting('app.conv')::uuid, 'entrante', 'texto', 'Mi cel es 999 123 4567 y mi correo ana@ejemplo.com', 'recibido', now() - interval '2 minutes');
select set_config('app.borr', gen_random_uuid()::text, true);
insert into mensajes_wa (id, conversacion_id, direccion, tipo, texto, estado, created_at)
values (current_setting('app.borr')::uuid, current_setting('app.conv')::uuid, 'saliente', 'texto', 'Sí, claro.', 'borrador', now() - interval '1 minute');

-- Como el admin
select set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated', 'email', email)::text, true)
  from perfiles where rol = 'admin' and coalesce(activo, true) order by created_at limit 1;
set local role authenticated;

-- 1. Mandar la sugerencia corregida guarda el ejemplo
select responder_whatsapp(current_setting('app.conv')::uuid, 'Sí, con gusto. ¿De qué equipo se trata?', current_setting('app.borr')::uuid);
select set_config('app.p1', concat(
  case when n = 1 and corr and cli like 'Hola%' and cli like '%ana@%' then 'ok' else 'FALLA' end,
  ' (n=', n, ', corregido=', corr, ')'), true)
from (select count(*) n, bool_and(corregido) corr, max(cliente_escribio) cli
        from wa_ejemplos where borrador_id = current_setting('app.borr')::uuid) x;

-- 2. Volver a mandar el mismo borrador actualiza, no duplica
select responder_whatsapp(current_setting('app.conv')::uuid, 'Sí, con gusto.', current_setting('app.borr')::uuid);
select set_config('app.p2', concat(case when n = 1 and env = 'Sí, con gusto.' then 'ok' else 'FALLA' end, ' (n=', n, ')'), true)
from (select count(*) n, max(enviado) env from wa_ejemplos where borrador_id = current_setting('app.borr')::uuid) x;

-- 3. Lo que lee el agente va sin teléfono ni correo
select set_config('app.p3', case
  when e::text like '%[número]%' and e::text like '%[correo]%' and e::text not like '%4567%' and e::text not like '%ana@%'
  then 'ok' else concat('FALLA ', left(e::text, 200)) end, true)
from (select wa_ejemplos_agente(20) e) x;

-- 4. "No imitar este" lo saca de lo que lee el agente
update wa_ejemplos set activo = false where borrador_id = current_setting('app.borr')::uuid;
select set_config('app.p4', case when wa_ejemplos_agente(20)::text not like '%con gusto%' then 'ok' else 'FALLA' end, true);

-- 5. Lo que manda el propio agente (automático) no se vuelve ejemplo
reset role;
select set_config('app.borr2', gen_random_uuid()::text, true);
insert into mensajes_wa (id, conversacion_id, direccion, tipo, texto, estado)
values (current_setting('app.borr2')::uuid, current_setting('app.conv')::uuid, 'saliente', 'texto', 'Otro', 'borrador');
insert into salida_wa (llave, telefono, conversacion_id, tipo, texto, origen, origen_id, categoria, estado, creado_por)
values ('prueba92:' || gen_random_uuid(), '529990009201', current_setting('app.conv')::uuid, 'texto', 'Otro',
        'respuesta', current_setting('app.borr2')::uuid, 'servicio', 'cancelado', 'agente');
select set_config('app.p5', case when not exists (select 1 from wa_ejemplos where borrador_id = current_setting('app.borr2')::uuid)
  then 'ok' else 'FALLA' end, true);

-- 6. Un técnico no ve los ejemplos
select set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true)
  from perfiles where rol = 'tecnico' order by created_at limit 1;
set local role authenticated;
select set_config('app.p6', case when (select count(*) from wa_ejemplos) = 0 then 'ok' else 'FALLA' end, true);

select current_setting('app.p1') p1_guarda, current_setting('app.p2') p2_no_duplica,
       current_setting('app.p3') p3_sin_datos, current_setting('app.p4') p4_no_imitar,
       current_setting('app.p5') p5_agente_no, current_setting('app.p6') p6_tecnico;
rollback;
