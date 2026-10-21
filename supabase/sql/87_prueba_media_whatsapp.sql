-- Prueba de 87_media_whatsapp.sql. Correr DESPUÉS del 87, el bloque COMPLETO, con la CLI:
--   npx supabase db query --linked -f supabase/sql/87_prueba_media_whatsapp.sql
-- begin/rollback. Teléfono 9990008700 de mentira; nada queda en la base.
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('app.tec',
  coalesce((select id::text from perfiles where rol = 'tecnico' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

-- Tres mensajes: una foto de hoy, un audio de hace 40 días (Meta ya lo borró) y un texto.
select set_config('app.conv', (registrar_mensaje_entrante(
  p_telefono => '5219990008700', p_wa_message_id => 'wamid.P87A', p_texto => null,
  p_tipo => 'imagen', p_media_id => 'media87a', p_wa_timestamp => now()) ->> 'conversacion_id'), true);
select registrar_mensaje_entrante(p_telefono => '5219990008700', p_wa_message_id => 'wamid.P87B',
  p_texto => null, p_tipo => 'audio', p_media_id => 'media87b', p_wa_timestamp => now() - interval '40 days');
select registrar_mensaje_entrante(p_telefono => '5219990008700', p_wa_message_id => 'wamid.P87C',
  p_texto => 'hola', p_tipo => 'texto', p_media_id => null, p_wa_timestamp => now());

-- 1) Pendientes: solo la foto (el audio pasó de 30 días; el texto no trae archivo).
select set_config('app.p1', concat(
  case when (select count(*) from jsonb_array_elements(media_pendientes(50)) e
              where e ->> 'conversacion_id' = current_setting('app.conv')) = 1
        and exists (select 1 from jsonb_array_elements(media_pendientes(50)) e where e ->> 'wa_message_id' = 'wamid.P87A')
       then 'ok' else 'FALLO' end, ' — pendientes: solo la foto de hoy'), true);

-- 2) Un fallo suma intento y guarda el motivo; a los 3 deja de salir en la lista general.
select guardar_media_wa('wamid.P87A', p_error => 'Meta no respondió');
select guardar_media_wa('wamid.P87A', p_error => 'Meta no respondió');
select guardar_media_wa('wamid.P87A', p_error => 'Meta no respondió');
select set_config('app.p2', concat(
  case when (select media_intentos from mensajes_wa where wa_message_id = 'wamid.P87A') = 3
        and (select media_error from mensajes_wa where wa_message_id = 'wamid.P87A') = 'Meta no respondió'
        and not exists (select 1 from jsonb_array_elements(media_pendientes(50)) e where e ->> 'wa_message_id' = 'wamid.P87A')
       then 'ok' else 'FALLO' end, ' — 3 fallos: deja de reintentarse solo'), true);

-- 3) Pero pedido a mano ("Traer de Meta") sí sale.
select set_config('app.p3', concat(
  case when jsonb_array_length(media_pendientes(5, (select id from mensajes_wa where wa_message_id = 'wamid.P87A'))) = 1
       then 'ok' else 'FALLO' end, ' — a mano se reintenta aunque haya fallado'), true);

-- 4) Guardado: ruta, tipo y el error se borra; ya no está pendiente.
select guardar_media_wa('wamid.P87A', 'c/wamid.P87A.jpg', 'image/jpeg', null);
select set_config('app.p4', concat(
  case when (select media_ruta = 'c/wamid.P87A.jpg' and media_mime = 'image/jpeg' and media_error is null
               from mensajes_wa where wa_message_id = 'wamid.P87A')
        and jsonb_array_length(media_pendientes(5, (select id from mensajes_wa where wa_message_id = 'wamid.P87A'))) = 0
       then 'ok' else 'FALLO' end, ' — guardado con ruta y tipo; ya no es pendiente'), true);

-- 5) Un fallo tardío no pisa lo ya guardado.
select guardar_media_wa('wamid.P87A', p_error => 'tarde');
select set_config('app.p5', concat(
  case when (select media_error is null and media_ruta is not null from mensajes_wa where wa_message_id = 'wamid.P87A')
       then 'ok' else 'FALLO' end, ' — un error tardío no borra el archivo guardado'), true);

-- 6) El bucket existe y es privado; las tres políticas están.
select set_config('app.p6', concat(
  case when (select not public from storage.buckets where id = 'whatsapp')
        and (select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects'
              and policyname in ('whatsapp_admin_lee', 'whatsapp_bot_sube', 'whatsapp_bot_reemplaza')) = 3
       then 'ok' else 'FALLO' end, ' — bucket whatsapp privado con sus 3 políticas'), true);

-- 7) Un técnico no puede ni ver la lista ni anotar.
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.tec'), 'role', 'authenticated')::text, true);
do $$
begin
  if current_setting('app.tec') = '' then
    perform set_config('app.p7', 'ok — (sin técnico en la base: se salta)', true); return;
  end if;
  begin
    perform media_pendientes(5);
    perform set_config('app.p7', 'FALLO — el técnico vio la lista', true);
  exception when others then
    begin
      perform guardar_media_wa('wamid.P87B', p_error => 'x');
      perform set_config('app.p7', 'FALLO — el técnico pudo anotar', true);
    exception when others then
      perform set_config('app.p7', 'ok — el técnico no ve ni anota', true);
    end;
  end;
end $$;

select current_setting('app.p1') as p1, current_setting('app.p2') as p2, current_setting('app.p3') as p3,
       current_setting('app.p4') as p4, current_setting('app.p5') as p5, current_setting('app.p6') as p6,
       current_setting('app.p7') as p7;

rollback;
