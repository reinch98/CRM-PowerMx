-- Prueba del 96 (con rollback: no deja nada). Lleva bloques `do` para los rechazos: correr con la CLI
--   npx supabase db query --linked -f supabase/sql/96_prueba_enviar_archivos_whatsapp.sql
begin;

-- Escenario (como dueño de la base): una conversación con la ventana abierta, otra cerrada, y
-- archivos "subidos" al bucket con lo que Storage guarda de cada uno.
select set_config('app.c1', gen_random_uuid()::text, true), set_config('app.c2', gen_random_uuid()::text, true);
insert into conversaciones (id, telefono, estado, ventana_hasta) values
  (current_setting('app.c1')::uuid, '9990009601', 'abierta', now() + interval '2 hours'),
  (current_setting('app.c2')::uuid, '9990009602', 'abierta', now() - interval '1 hour');
insert into storage.objects (bucket_id, name, metadata) values
  ('whatsapp', 'enviados/' || current_setting('app.c1') || '/a.jpg',      '{"mimetype":"image/jpeg","size":120000}'),
  ('whatsapp', 'enviados/' || current_setting('app.c1') || '/b.pdf',      '{"mimetype":"application/pdf","size":300000}'),
  ('whatsapp', 'enviados/' || current_setting('app.c1') || '/grande.jpg', '{"mimetype":"image/jpeg","size":6000000}'),
  ('whatsapp', 'enviados/' || current_setting('app.c1') || '/x.zip',      '{"mimetype":"application/zip","size":1000}'),
  ('whatsapp', 'enviados/' || current_setting('app.c2') || '/c.jpg',      '{"mimetype":"image/jpeg","size":1000}'),
  ('whatsapp', current_setting('app.c1') || '/del_cliente.jpg',           '{"mimetype":"image/jpeg","size":1000}');
update wa_config set envio_activo = true where id;

select set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated', 'email', email)::text, true)
  from perfiles where rol = 'admin' and coalesce(activo, true) order by created_at limit 1;
set local role authenticated;

-- 1. Una foto con su pie queda en la cola como imagen
select set_config('app.r1', responder_whatsapp_archivo(current_setting('app.c1')::uuid,
  'enviados/' || current_setting('app.c1') || '/a.jpg', 'tablero.jpg', '  Así quedó el tablero  ')::text, true);
select set_config('app.p1', case
  when s.tipo = 'imagen' and s.estado = 'pendiente' and s.origen = 'respuesta' and s.media_mime = 'image/jpeg'
   and s.texto = 'Así quedó el tablero' and s.media_nombre = 'tablero.jpg' and s.telefono_norm = '9990009601'
  then 'ok' else concat('FALLA ', row_to_json(s)::text) end, true)
from salida_wa s where s.id = (current_setting('app.r1')::jsonb ->> 'salida_id')::uuid;

-- 2. Un doble toque no la manda dos veces
select set_config('app.p2', case
  when (responder_whatsapp_archivo(current_setting('app.c1')::uuid,
          'enviados/' || current_setting('app.c1') || '/a.jpg') ->> 'repetido') = 'true'
  then 'ok' else 'FALLA' end, true);

-- 3. Un PDF sale como documento, sin pie
select set_config('app.r3', responder_whatsapp_archivo(current_setting('app.c1')::uuid,
  'enviados/' || current_setting('app.c1') || '/b.pdf', 'Cotizacion 12.pdf', null)::text, true);
select set_config('app.p3', case
  when s.tipo = 'documento' and s.texto is null and s.media_nombre = 'Cotizacion 12.pdf' then 'ok'
  else concat('FALLA ', row_to_json(s)::text) end, true)
from salida_wa s where s.id = (current_setting('app.r3')::jsonb ->> 'salida_id')::uuid;

-- 4. Una foto de más de 5 MB se rechaza
do $$ begin
  perform responder_whatsapp_archivo(current_setting('app.c1')::uuid, 'enviados/' || current_setting('app.c1') || '/grande.jpg');
  perform set_config('app.p4', 'FALLA (no rechazó)', true);
exception when others then
  perform set_config('app.p4', case when sqlerrm like '%5 MB%' then 'ok' else 'FALLA ' || sqlerrm end, true);
end $$;

-- 5. Un tipo que WhatsApp no acepta se rechaza
do $$ begin
  perform responder_whatsapp_archivo(current_setting('app.c1')::uuid, 'enviados/' || current_setting('app.c1') || '/x.zip');
  perform set_config('app.p5', 'FALLA (no rechazó)', true);
exception when others then
  perform set_config('app.p5', case when sqlerrm like 'WhatsApp no acepta%' then 'ok' else 'FALLA ' || sqlerrm end, true);
end $$;

-- 6. Un archivo de otra conversación no se cuela
do $$ begin
  perform responder_whatsapp_archivo(current_setting('app.c1')::uuid, 'enviados/' || current_setting('app.c2') || '/c.jpg');
  perform set_config('app.p6', 'FALLA (no rechazó)', true);
exception when others then
  perform set_config('app.p6', case when sqlerrm like '%no es de esta conversación%' then 'ok' else 'FALLA ' || sqlerrm end, true);
end $$;

-- 7. Con la ventana cerrada no se manda
do $$ begin
  perform responder_whatsapp_archivo(current_setting('app.c2')::uuid, 'enviados/' || current_setting('app.c2') || '/c.jpg');
  perform set_config('app.p7', 'FALLA (no rechazó)', true);
exception when others then
  perform set_config('app.p7', case when sqlerrm like '%ventana%' then 'ok' else 'FALLA ' || sqlerrm end, true);
end $$;

-- 8. tomar_salida la entrega con su ruta, y al marcarla queda en la conversación con el archivo
select set_config('app.lote', tomar_salida(50)::text, true);
select set_config('app.p8a', case
  when exists (select 1 from jsonb_array_elements(current_setting('app.lote')::jsonb -> 'mensajes') m
                where m ->> 'id' = current_setting('app.r1')::jsonb ->> 'salida_id'
                  and m ->> 'tipo' = 'imagen' and m ->> 'media_ruta' like 'enviados/%/a.jpg'
                  and m ->> 'texto' = 'Así quedó el tablero')
  then 'ok' else 'FALLA (no vino en el lote)' end, true);
select marcar_salida((current_setting('app.r1')::jsonb ->> 'salida_id')::uuid, true, 'wamid.prueba96', null, false);
select set_config('app.p8b', case
  when m.tipo = 'imagen' and m.direccion = 'saliente' and m.media_ruta like 'enviados/%/a.jpg'
   and m.media_mime = 'image/jpeg' and m.texto = 'Así quedó el tablero' then 'ok'
  else concat('FALLA ', row_to_json(m)::text) end, true)
from mensajes_wa m where m.wa_message_id = 'wamid.prueba96';

-- 9. El bot lee lo de enviados/, no lo que mandó el cliente
select set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true)
  from perfiles where rol = 'bot' order by created_at limit 1;
select set_config('app.p9', case
  when (select count(*) from storage.objects where bucket_id = 'whatsapp'
         and name in ('enviados/' || current_setting('app.c1') || '/a.jpg', current_setting('app.c1') || '/del_cliente.jpg')) = 1
  then 'ok' else 'FALLA' end, true);

-- 10. Un técnico no puede mandar archivos
select set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true)
  from perfiles where rol = 'tecnico' order by created_at limit 1;
do $$ begin
  perform responder_whatsapp_archivo(current_setting('app.c1')::uuid, 'enviados/' || current_setting('app.c1') || '/b.pdf');
  perform set_config('app.p10', 'FALLA (no rechazó)', true);
exception when others then
  perform set_config('app.p10', case when sqlerrm like 'Solo el administrador%' then 'ok' else 'FALLA ' || sqlerrm end, true);
end $$;

select current_setting('app.p1') p1, current_setting('app.p2') p2, current_setting('app.p3') p3,
       current_setting('app.p4') p4, current_setting('app.p5') p5, current_setting('app.p6') p6,
       current_setting('app.p7') p7, current_setting('app.p8a') p8a, current_setting('app.p8b') p8b,
       current_setting('app.p9') p9, current_setting('app.p10') p10;
rollback;
