-- ===========================================================================
-- 96 · Mandar fotos y documentos desde la conversación de WhatsApp (05/11/2026)
--
-- Pedido de Caña: "quiero la opción de enviar documentos e imágenes en el chat".
--
-- Va por la MISMA cola de salida (56) que el texto: la oficina sube el archivo al bucket
-- privado `whatsapp`, bajo `enviados/<conversación>/…`, y `responder_whatsapp_archivo` lo
-- mete a `salida_wa`. La Edge Function `enviar-whatsapp` le pide a Storage un enlace
-- firmado de 1 hora y se lo da a Meta, que lo descarga (igual que el PDF de la orden, 58).
--
-- Reglas de WhatsApp (Cloud API) que se revisan aquí, no en el navegador:
--   · solo con la ventana de 24 h abierta (como el texto libre);
--   · foto: JPG o PNG de hasta 5 MB · documento: PDF, Word, Excel, PowerPoint o texto
--     (el bucket ya corta en 25 MB) · pie de foto de hasta 1,024 caracteres.
-- El tipo y el tamaño se leen de lo que Storage guardó, no de lo que diga el navegador.
--
-- El bot puede LEER solo `enviados/` del bucket (lo que la oficina decidió mandar); las
-- fotos que mandan los clientes las sigue leyendo solo el admin (87).
--
-- Sin `select ... into` (el editor de Supabase los mutila). Se puede repetir.
-- Prueba: 96_prueba_enviar_archivos_whatsapp.sql.
-- ===========================================================================

alter table salida_wa
  add column if not exists media_ruta text,      -- dentro del bucket `whatsapp`
  add column if not exists media_mime text,
  add column if not exists media_nombre text;

alter table salida_wa drop constraint if exists salida_wa_tipo_check;
alter table salida_wa add constraint salida_wa_tipo_check
  check (tipo in ('texto', 'plantilla', 'imagen', 'documento'));

-- Un archivo lleva su ruta; texto y plantilla no.
alter table salida_wa drop constraint if exists salida_wa_archivo_check;
alter table salida_wa add constraint salida_wa_archivo_check
  check ((tipo in ('imagen', 'documento')) = (media_ruta is not null));

-- ---- el bot lee solo lo que la oficina mandó ----
drop policy if exists "whatsapp_bot_lee_enviados" on storage.objects;
create policy "whatsapp_bot_lee_enviados" on storage.objects for select to authenticated
  using (bucket_id = 'whatsapp' and (storage.foldername(name))[1] = 'enviados' and public._es_bot_o_admin());

-- Lo que WhatsApp acepta como documento. La misma lista vive en src/lib/whatsapp.js.
create or replace function _wa_mime_documento(p_mime text) returns boolean
language sql immutable as $$
  select coalesce(p_mime, '') in (
    'application/pdf', 'text/plain',
    'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.ms-powerpoint', 'application/vnd.openxmlformats-officedocument.presentationml.presentation')
$$;

-- ---------------------------------------------------------------------------
-- La oficina manda un archivo ya subido. Devuelve {ok, salida_id, tipo} o {ok, repetido}.
-- ---------------------------------------------------------------------------
create or replace function responder_whatsapp_archivo(p_conversacion uuid, p_ruta text,
  p_nombre text default null, p_pie text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_conv conversaciones%rowtype;
  v_obj storage.objects%rowtype;
  v_mime text; v_bytes bigint; v_tipo text; v_id uuid := gen_random_uuid();
  v_pie text := nullif(trim(coalesce(p_pie, '')), '');
  v_nombre text := nullif(left(trim(coalesce(p_nombre, '')), 200), '');
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  v_conv := (select c from conversaciones c where c.id = p_conversacion);
  if v_conv.id is null then
    raise exception 'La conversación no existe.' using errcode = 'P0002';
  end if;
  if v_conv.ventana_hasta is null or v_conv.ventana_hasta <= now() then
    raise exception 'La ventana de 24 h está cerrada: WhatsApp solo deja mandar una plantilla aprobada.' using errcode = '22023';
  end if;
  -- La ruta tiene que ser de ESTA conversación: así un archivo de otro chat no se cuela.
  if coalesce(p_ruta, '') not like 'enviados/' || p_conversacion || '/%' then
    raise exception 'El archivo no es de esta conversación.' using errcode = '22023';
  end if;
  v_obj := (select o from storage.objects o where o.bucket_id = 'whatsapp' and o.name = p_ruta);
  if v_obj.id is null then
    raise exception 'El archivo no se subió: vuelve a elegirlo.' using errcode = '22023';
  end if;

  v_mime := lower(coalesce(v_obj.metadata ->> 'mimetype', ''));
  v_bytes := coalesce((v_obj.metadata ->> 'size')::bigint, 0);
  if v_mime in ('image/jpeg', 'image/png') then
    v_tipo := 'imagen';
    if v_bytes > 5 * 1024 * 1024 then
      raise exception 'WhatsApp solo acepta fotos de hasta 5 MB.' using errcode = '22023';
    end if;
  elsif _wa_mime_documento(v_mime) then
    v_tipo := 'documento';
  else
    raise exception 'WhatsApp no acepta ese tipo de archivo: manda una foto (JPG o PNG) o un PDF, Word, Excel, PowerPoint o texto.'
      using errcode = '22023';
  end if;
  if length(v_pie) > 1024 then
    raise exception 'El texto que acompaña al archivo pasa de 1,024 caracteres.' using errcode = '22023';
  end if;

  -- El mismo archivo dos veces (un doble toque) no sale dos veces.
  if exists (select 1 from salida_wa s where s.media_ruta = p_ruta and s.estado not in ('cancelado', 'fallido')) then
    return jsonb_build_object('ok', true, 'repetido', true);
  end if;

  insert into salida_wa (id, llave, telefono, conversacion_id, tipo, texto, media_ruta, media_mime, media_nombre,
                         origen, categoria, estado, aprobado_por, aprobado_en, creado_por)
  values (v_id, 'archivo:' || v_id, v_conv.telefono, v_conv.id, v_tipo, v_pie, p_ruta, v_mime,
          coalesce(v_nombre, case v_tipo when 'imagen' then 'foto.jpg' else 'documento' end),
          'respuesta', 'servicio', 'pendiente', coalesce(auth.jwt() ->> 'email', 'crm'), now(),
          coalesce(auth.jwt() ->> 'email', 'crm'));
  return jsonb_build_object('ok', true, 'salida_id', v_id, 'tipo', v_tipo);
end $$;
revoke all on function responder_whatsapp_archivo(uuid, text, text, text) from public, anon;
grant execute on function responder_whatsapp_archivo(uuid, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- tomar_salida (de la 56): un archivo también exige la ventana abierta y viaja con su ruta.
-- ---------------------------------------------------------------------------
create or replace function tomar_salida(p_n int default 20) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; v_out jsonb := '[]'::jsonb; v_pl wa_plantillas%rowtype; v_vars jsonb; v_motivo text;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el conector de WhatsApp o el administrador.' using errcode = '42501';
  end if;
  if not coalesce((select envio_activo from wa_config where id), false) then
    return jsonb_build_object('ok', true, 'apagado', true, 'mensajes', '[]'::jsonb);
  end if;

  for r in select * from salida_wa
            where estado = 'pendiente' and programado_para <= now()
            order by programado_para limit greatest(1, least(p_n, 50))
            for update skip locked loop
    v_motivo := null; v_vars := r.variables; v_pl := null;
    if r.tipo <> 'plantilla' then
      if not exists (select 1 from conversaciones c where c.id = r.conversacion_id and c.ventana_hasta > now()) then
        v_motivo := 'la ventana de 24 h se cerró antes de salir';
      end if;
    else
      v_pl := (select p from wa_plantillas p where p.nombre = r.plantilla);
      if v_pl.estado is distinct from 'aprobada' then
        continue;                                    -- espera a que Meta la apruebe; no es error
      end if;
      if r.categoria = 'marketing' and exists (select 1 from wa_bajas b where b.telefono_norm = r.telefono_norm) then
        v_motivo := 'el número pidió BAJA';
      end if;
      if r.origen = 'aviso' then v_vars := _variables_aviso(r.origen_id); end if;
      if v_motivo is null and exists (select 1 from unnest(v_pl.variables) v where nullif(v_vars ->> v, '') is null) then
        v_motivo := 'faltan variables para la plantilla';
      end if;
    end if;

    if v_motivo is not null then
      update salida_wa set estado = 'cancelado', error = v_motivo where id = r.id;
      continue;
    end if;

    update salida_wa set estado = 'enviando', tomado_en = now(), intentos = intentos + 1, variables = v_vars
     where id = r.id;
    v_out := v_out || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'id', r.id, 'to', _wa_destino(r.telefono), 'tipo', r.tipo, 'texto', case when r.tipo <> 'plantilla' then r.texto end,
      'plantilla', r.plantilla, 'idioma', v_pl.idioma,
      'parametros', case when r.tipo = 'plantilla' then
         (select coalesce(jsonb_agg(jsonb_build_object('nombre', v, 'valor', v_vars ->> v)), '[]'::jsonb) from unnest(v_pl.variables) v) end,
      'documento_ruta', r.documento_ruta, 'documento_nombre', r.documento_nombre,
      'media_ruta', r.media_ruta, 'media_mime', r.media_mime, 'media_nombre', r.media_nombre)));
  end loop;
  return jsonb_build_object('ok', true, 'mensajes', v_out);
end $$;

-- ---------------------------------------------------------------------------
-- marcar_salida (de la 56): lo enviado queda en la conversación CON su archivo, así la
-- burbuja muestra la foto o el botón "Abrir" igual que lo que manda el cliente.
-- ---------------------------------------------------------------------------
create or replace function marcar_salida(p_id uuid, p_ok boolean, p_wa_message_id text default null,
                                         p_error text default null, p_temporal boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare r salida_wa%rowtype; v_conv uuid;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el conector de WhatsApp o el administrador.' using errcode = '42501';
  end if;
  r := (select s from salida_wa s where s.id = p_id);
  if r.id is null or r.estado <> 'enviando' then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;

  if not p_ok then
    if p_temporal and r.intentos < 3 then
      update salida_wa set estado = 'pendiente', error = p_error,
             programado_para = now() + (r.intentos * interval '5 minutes') where id = p_id;
    else
      update salida_wa set estado = 'fallido', error = p_error where id = p_id;
    end if;
    return jsonb_build_object('ok', true);
  end if;

  update salida_wa set estado = 'enviado', wa_message_id = p_wa_message_id, enviado_en = now(), error = null
   where id = p_id;

  -- Queda en la conversación de ese número (se crea si no existía; el trigger de la 22 la liga).
  v_conv := coalesce(r.conversacion_id, (select id from conversaciones where telefono_norm = r.telefono_norm));
  if v_conv is null then
    v_conv := gen_random_uuid();
    insert into conversaciones (id, telefono, estado) values (v_conv, r.telefono, 'abierta');
  end if;
  insert into mensajes_wa (conversacion_id, direccion, tipo, texto, wa_message_id, estado, enviado_por, wa_timestamp,
                           media_ruta, media_mime, media_nombre)
  values (v_conv, 'saliente',
          case when r.tipo in ('imagen', 'documento') then r.tipo
               when r.documento_ruta is not null then 'documento' else 'texto' end,
          coalesce(r.texto, r.media_nombre, r.plantilla), p_wa_message_id, 'enviado', coalesce(r.aprobado_por, 'api'), now(),
          r.media_ruta, r.media_mime, r.media_nombre)
  on conflict do nothing;
  update conversaciones set ultimo_mensaje_at = now() where id = v_conv;

  if r.origen = 'aviso' then
    update avisos set estado = 'enviado', canal = 'whatsapp_api', enviado_at = now(), enviado_por = 'api',
           texto_enviado = 'Plantilla ' || r.plantilla || ': ' || coalesce(r.variables::text, '')
     where id = r.origen_id and estado = 'pendiente';
  end if;
  return jsonb_build_object('ok', true, 'conversacion_id', v_conv);
end $$;

revoke all on function tomar_salida(int) from public, anon;
grant execute on function tomar_salida(int) to authenticated;
revoke all on function marcar_salida(uuid, boolean, text, text, boolean) from public, anon;
grant execute on function marcar_salida(uuid, boolean, text, text, boolean) to authenticated;

insert into _migraciones (archivo, tipo) values ('96_enviar_archivos_whatsapp.sql', 'esquema')
on conflict (archivo) do nothing;
