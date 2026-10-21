-- ============================================================================
-- 87 · Fotos, documentos y audios que llegan por WhatsApp
--
-- Pedido de Caña (20/10/2026): "¿cómo puedo ver las imágenes que mandan al WhatsApp?".
-- Hasta hoy el webhook (22) guardaba solo el `media_id` de Meta y el archivo se quedaba en
-- los servidores de Meta, que lo borran a los 30 días. Ahora:
--   1. el webhook lo baja al llegar y lo sube al bucket privado `whatsapp` (solo admin lo lee);
--   2. la bandeja lo muestra (foto en miniatura, audio, documento con "Abrir");
--   3. lo que ya había llegado y Meta todavía guarda (menos de 30 días) se trae una vez con
--      la Edge Function `media-whatsapp`.
--
-- Quién escribe: la cuenta `bot` (webhook y `media-whatsapp`), nunca `service_role`. El bot
-- puede SUBIR a `whatsapp/` pero no leer; leer es solo del admin. Ni técnico ni almacén
-- entran: una foto de un cliente puede traer su casa, su placa o su identificación.
-- ============================================================================

alter table mensajes_wa
  add column if not exists media_ruta text,          -- ruta dentro del bucket `whatsapp`
  add column if not exists media_mime text,          -- image/jpeg, audio/ogg, application/pdf…
  add column if not exists media_nombre text,        -- el nombre del documento, si traía
  add column if not exists media_error text,         -- por qué no se pudo bajar (en palabras)
  add column if not exists media_intentos int not null default 0;

-- Lo que falta por bajar: pocas filas, se buscan seguido.
create index if not exists idx_mensajes_wa_media_pendiente
  on mensajes_wa(created_at) where media_id is not null and media_ruta is null;

-- ---- el bucket: privado. 25 MB: Meta deja documentos de hasta 100 MB, pero eso no
-- cabe bien en un celular; uno más pesado se queda con su motivo y se ve en WhatsApp. ----
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('whatsapp', 'whatsapp', false, 26214400, null)
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit;

drop policy if exists "whatsapp_admin_lee"     on storage.objects;
drop policy if exists "whatsapp_bot_sube"      on storage.objects;
drop policy if exists "whatsapp_bot_reemplaza" on storage.objects;
create policy "whatsapp_admin_lee" on storage.objects for select to authenticated
  using (bucket_id = 'whatsapp' and public.es_admin());
create policy "whatsapp_bot_sube" on storage.objects for insert to authenticated
  with check (bucket_id = 'whatsapp' and public._es_bot_o_admin());
-- `upsert` necesita update: un reintento que encuentra el archivo ya subido lo reemplaza
-- por el mismo, en vez de fallar.
create policy "whatsapp_bot_reemplaza" on storage.objects for update to authenticated
  using (bucket_id = 'whatsapp' and public._es_bot_o_admin())
  with check (bucket_id = 'whatsapp' and public._es_bot_o_admin());

-- ---------------------------------------------------------------------------
-- media_pendientes: lo que falta por bajar de Meta. Solo lo de los últimos 30 días (lo
-- anterior Meta ya lo borró y pedirlo solo gasta llamadas). Sin `p_mensaje`, se salta lo que
-- ya falló tres veces; con `p_mensaje` (el botón "Traer de Meta" de un mensaje) se intenta
-- ese aunque haya fallado antes.
-- ---------------------------------------------------------------------------
create or replace function media_pendientes(p_n int default 20, p_mensaje uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector de WhatsApp.' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', x.id, 'wa_message_id', x.wa_message_id, 'media_id', x.media_id,
             'conversacion_id', x.conversacion_id, 'texto', x.texto) order by x.created_at)
    from (
      select m.* from mensajes_wa m
      where m.direccion = 'entrante'
        and m.media_id is not null and m.media_ruta is null
        and coalesce(m.wa_timestamp, m.created_at) > now() - interval '30 days'
        and (case when p_mensaje is null then m.media_intentos < 3 else m.id = p_mensaje end)
      order by m.created_at
      limit greatest(1, least(coalesce(p_n, 20), 50))
    ) x
  ), '[]'::jsonb);
end $$;
revoke all on function media_pendientes(int, uuid) from public, anon;
grant execute on function media_pendientes(int, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- guardar_media_wa: deja el resultado de bajar un archivo. Con ruta, quedó guardado (y se
-- borra el error de un intento anterior); sin ruta, suma un intento y guarda el motivo.
-- Se busca por `wa_message_id`: el webhook lo tiene a la mano y es único (22).
-- ---------------------------------------------------------------------------
create or replace function guardar_media_wa(
  p_wa_message_id text,
  p_ruta text default null,
  p_mime text default null,
  p_nombre text default null,
  p_error text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_n int;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector de WhatsApp.' using errcode = '42501';
  end if;
  if nullif(trim(p_ruta), '') is not null then
    update mensajes_wa
       set media_ruta = p_ruta, media_mime = nullif(trim(p_mime), ''),
           media_nombre = coalesce(nullif(trim(p_nombre), ''), media_nombre), media_error = null
     where wa_message_id = p_wa_message_id;
  else
    update mensajes_wa
       set media_intentos = media_intentos + 1,
           media_error = left(coalesce(nullif(trim(p_error), ''), 'No se pudo bajar el archivo.'), 300)
     where wa_message_id = p_wa_message_id and media_ruta is null;
  end if;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', v_n > 0);
end $$;
revoke all on function guardar_media_wa(text, text, text, text, text) from public, anon;
grant execute on function guardar_media_wa(text, text, text, text, text) to authenticated;

notify pgrst, 'reload schema';

insert into _migraciones (archivo, tipo) values ('87_media_whatsapp.sql', 'esquema')
on conflict (archivo) do nothing;
