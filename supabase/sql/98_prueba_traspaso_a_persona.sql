-- Prueba del 98 (con rollback: no deja nada). Lleva bloques `do` para los rechazos: correr con la CLI
--   npx supabase db query --linked -f supabase/sql/98_prueba_traspaso_a_persona.sql
begin;

-- Escenario (como dueño de la base): el WhatsApp de la oficina (9990009899, sin ventana), dos clientes
-- que escriben con la ventana abierta, y los ids de los perfiles antes de cambiar de rol.
update wa_agente set telefono_traspasos = '999 000 9899' where id;
update wa_config set envio_activo = true where id;
update wa_plantillas set estado = 'borrador' where nombre = 'cliente_para_atender';
select set_config('app.c1', gen_random_uuid()::text, true), set_config('app.c2', gen_random_uuid()::text, true),
       set_config('app.c3', gen_random_uuid()::text, true);
insert into conversaciones (id, telefono, estado, ventana_hasta) values
  (current_setting('app.c1')::uuid, '9990009801', 'abierta', now() + interval '2 hours'),
  (current_setting('app.c2')::uuid, '9990009802', 'abierta', now() + interval '2 hours');
select set_config('app.bot', (select id::text from perfiles where rol = 'bot' order by created_at limit 1), true),
       set_config('app.admin', (select id::text from perfiles where rol = 'admin' and coalesce(activo, true) order by created_at limit 1), true),
       set_config('app.tec', (select id::text from perfiles where rol = 'tecnico' order by created_at limit 1), true);

select set_config('request.jwt.claims', json_build_object('sub', current_setting('app.bot'), 'role', 'authenticated')::text, true);
set local role authenticated;

-- 1. Ventana de la oficina cerrada: tarjeta + plantilla a la oficina, con el teléfono de la conversación
select set_config('app.r1', wa_pasar_a_persona(current_setting('app.c1')::uuid,
  'Su generador no arranca desde ayer', 'Ana', 'Hotel Sol', true)::text, true);
reset role;
select set_config('app.p1', case
  when t.estado = 'pendiente' and t.urgente and t.telefono = '9990009801' and t.avisado = 'plantilla'
   and s.tipo = 'plantilla' and s.plantilla = 'cliente_para_atender' and s.telefono_norm = '9990009899'
   and s.origen = 'traspaso' and s.variables ->> 'telefono' = '+52 999 000 9801'
   and s.variables ->> 'necesidad' = 'URGENTE: Su generador no arranca desde ayer'
   and s.variables ->> 'cliente' = 'Ana · Hotel Sol (número nuevo)'
  then 'ok' else concat('FALLA ', row_to_json(t)::text, ' / ', row_to_json(s)::text) end, true)
from wa_traspasos t join salida_wa s on s.origen_id = t.id
where t.id = (current_setting('app.r1')::jsonb ->> 'traspaso_id')::uuid;

-- 2. Pasarlo otra vez no te vuelve a escribir: solo actualiza la necesidad
set local role authenticated;
select set_config('app.r2', wa_pasar_a_persona(current_setting('app.c1')::uuid, 'Ya tampoco prende la luz')::text, true);
reset role;
select set_config('app.p2', case
  when (current_setting('app.r2')::jsonb ->> 'ya_avisado') = 'true'
   and (select count(*) from salida_wa where origen = 'traspaso' and telefono_norm = '9990009899') = 1
   and (select necesidad from wa_traspasos where conversacion_id = current_setting('app.c1')::uuid) = 'Ya tampoco prende la luz'
  then 'ok' else 'FALLA' end, true);

-- 3. La respuesta del mismo turno sale; otra respuesta del agente después ya no (queda borrador)
set local role authenticated;
select set_config('app.r3a', wa_enviar_respuesta_agente(current_setting('app.c1')::uuid, 'Te paso con un compañero',
  (current_setting('app.r1')::jsonb ->> 'traspaso_id')::uuid)::text, true);
select set_config('app.r3b', wa_enviar_respuesta_agente(current_setting('app.c1')::uuid, 'Otra cosa')::text, true);
select set_config('app.p3', case
  when (current_setting('app.r3a')::jsonb ->> 'enviado') = 'true'
   and (current_setting('app.r3b')::jsonb ->> 'motivo') = 'pasado_a_persona'
  then 'ok' else concat('FALLA ', current_setting('app.r3a'), ' / ', current_setting('app.r3b')) end, true);
reset role;

-- 4. Con la ventana de la oficina abierta: texto + tarjeta de contacto de WhatsApp
insert into conversaciones (id, telefono, estado, ventana_hasta)
values (current_setting('app.c3')::uuid, '9990009899', 'abierta', now() + interval '3 hours');
set local role authenticated;
select set_config('app.r4', wa_pasar_a_persona(current_setting('app.c2')::uuid, 'Quiere cotizar un sistema solar', 'Luis')::text, true);
reset role;
select set_config('app.p4', case
  when (select count(*) from salida_wa s where s.origen_id = (current_setting('app.r4')::jsonb ->> 'traspaso_id')::uuid
          and s.tipo = 'texto' and s.conversacion_id = current_setting('app.c3')::uuid
          and s.texto like '%Necesita: Quiere cotizar un sistema solar%') = 1
   and (select count(*) from salida_wa s where s.origen_id = (current_setting('app.r4')::jsonb ->> 'traspaso_id')::uuid
          and s.tipo = 'contacto' and s.variables ->> 'wa_id' = '529990009802'
          and s.variables ->> 'nombre' = 'Luis' and s.variables ->> 'telefono' = '+529990009802') = 1
  then 'ok' else 'FALLA' end, true);

-- 5. tomar_salida: la tarjeta sale con sus datos; la plantilla sin aprobar espera
update salida_wa set programado_para = now() - interval '1 second' where origen = 'traspaso';
set local role authenticated;
select set_config('app.lote', tomar_salida(50)::text, true);
reset role;
select set_config('app.p5', case
  when exists (select 1 from jsonb_array_elements(current_setting('app.lote')::jsonb -> 'mensajes') m
                where m ->> 'tipo' = 'contacto' and m -> 'contacto' ->> 'wa_id' = '529990009802' and m ->> 'texto' is null)
   and not exists (select 1 from jsonb_array_elements(current_setting('app.lote')::jsonb -> 'mensajes') m
                    where m ->> 'plantilla' = 'cliente_para_atender')
  then 'ok' else 'FALLA' end, true);

-- 6. Al marcarla enviada, la tarjeta queda en la conversación de la oficina como 'otro'
-- (el id se toma antes de cambiar de rol: el bot no lee salida_wa)
select set_config('app.s6', (select s.id::text from salida_wa s where s.tipo = 'contacto'
                               and s.origen_id = (current_setting('app.r4')::jsonb ->> 'traspaso_id')::uuid), true);
set local role authenticated;
select marcar_salida(current_setting('app.s6')::uuid, true, 'wamid.prueba98', null, false);
reset role;
select set_config('app.p6', case
  when (select m.tipo from mensajes_wa m where m.wa_message_id = 'wamid.prueba98') = 'otro'
   and (select m.conversacion_id from mensajes_wa m where m.wa_message_id = 'wamid.prueba98') = current_setting('app.c3')::uuid
  then 'ok' else 'FALLA' end, true);

-- 7. "Ya lo atendí" (admin): el agente vuelve a contestar solo
select set_config('request.jwt.claims', json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);
set local role authenticated;
select atender_traspaso((current_setting('app.r1')::jsonb ->> 'traspaso_id')::uuid, 'Le llamé');
select set_config('app.r7', wa_enviar_respuesta_agente(current_setting('app.c1')::uuid, 'Hola de nuevo')::text, true);
reset role;
select set_config('app.p7', case
  when (current_setting('app.r7')::jsonb ->> 'enviado') = 'true'
   and (select estado from wa_traspasos where id = (current_setting('app.r1')::jsonb ->> 'traspaso_id')::uuid) = 'atendido'
  then 'ok' else concat('FALLA ', current_setting('app.r7')) end, true);

-- 8. Sin tu número capturado: la tarjeta queda en el CRM y dice que no avisó
update wa_agente set telefono_traspasos = null where id;
update wa_traspasos set estado = 'atendido' where conversacion_id = current_setting('app.c2')::uuid;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('app.bot'), 'role', 'authenticated')::text, true);
set local role authenticated;
select set_config('app.r8', wa_pasar_a_persona(current_setting('app.c2')::uuid, 'Pide factura')::text, true);
reset role;
select set_config('app.p8', case
  when (current_setting('app.r8')::jsonb ->> 'motivo') = 'sin_numero'
   and (select avisado from wa_traspasos where id = (current_setting('app.r8')::jsonb ->> 'traspaso_id')::uuid) = 'sin_numero'
  then 'ok' else concat('FALLA ', current_setting('app.r8')) end, true);

-- 9. Sin necesidad escrita se rechaza
set local role authenticated;
do $$ begin
  perform wa_pasar_a_persona(current_setting('app.c1')::uuid, '   ');
  perform set_config('app.p9', 'FALLA (no rechazó)', true);
exception when others then
  perform set_config('app.p9', case when sqlerrm like 'Escribe qué necesita%' then 'ok' else 'FALLA ' || sqlerrm end, true);
end $$;

-- 10. Un técnico no puede pasar clientes ni ver las tarjetas
reset role;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('app.tec'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $$ begin
  perform wa_pasar_a_persona(current_setting('app.c1')::uuid, 'algo');
  perform set_config('app.p10', 'FALLA (no rechazó)', true);
exception when others then
  perform set_config('app.p10', case when sqlerrm like 'Solo el conector%' then 'ok' else 'FALLA ' || sqlerrm end, true);
end $$;
select set_config('app.p10', case when current_setting('app.p10') = 'ok' and (select count(*) from wa_traspasos) = 0
                                  then 'ok' else concat(current_setting('app.p10'), ' (ve tarjetas)') end, true);
reset role;

select current_setting('app.p1') p1, current_setting('app.p2') p2, current_setting('app.p3') p3,
       current_setting('app.p4') p4, current_setting('app.p5') p5, current_setting('app.p6') p6,
       current_setting('app.p7') p7, current_setting('app.p8') p8, current_setting('app.p9') p9,
       current_setting('app.p10') p10;
rollback;
