-- ===========================================================================
-- WHATSAPP · COLA DE SALIDA (todo lo que se manda por la API pasa por aquí)
--
-- Antes cada salida iba por su lado: avisos de cita con wa.me, el PDF de la orden a mano, los
-- borradores del agente. Ahora todo entra a UNA cola, `salida_wa`, y una sola Edge Function
-- (`enviar-whatsapp`, fase 3) la vacía contra la API de Meta. Las reglas viven aquí, no en el
-- código:
--   · Ventana de 24 h: texto libre solo con la ventana abierta; fuera, plantilla aprobada.
--   · Bajas: a quien pidió BAJA no le llega marketing (los avisos de SU cita sí).
--   · Nada se manda dos veces: `llave` única por envío; un envío que quedó "enviando" sin
--     confirmación NO se reintenta solo (Meta no tiene llave de idempotencia): lo revisa una persona.
--   · Una plantilla solo sale si está `aprobada` en `wa_plantillas` y el envío está encendido.
--
-- Qué entra a la cola en esta versión:
--   · avisos de cita (16 y 54): solos, al crearse el aviso, si hay plantilla para ese tipo.
--     `avisos_automaticos` arranca APAGADO: quedan "por aprobar" hasta que lo enciendas.
--   · la orden de servicio en PDF: `encolar_orden(envio)` al registrar "Enviar al cliente".
--   · respuestas de texto (admin o borrador del agente aprobado): `responder_whatsapp`.
-- Las campañas de marketing van en la 57 (necesitan sus plantillas y el plan cargado).
--
-- Sin `select ... into` en plpgsql (el editor de Supabase los mutila). Se puede repetir.
-- Prueba: 56_prueba_salida_whatsapp.sql.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Configuración (una fila)
-- ---------------------------------------------------------------------------
create table if not exists wa_config (
  id boolean primary key default true check (id),
  envio_activo boolean not null default false,        -- interruptor general: apagado hasta tener token
  avisos_automaticos boolean not null default false,  -- avisos de cita: solos o "por aprobar"
  dias_entre_marketing int not null default 30 check (dias_entre_marketing > 0),
  updated_at timestamptz not null default now()
);
insert into wa_config (id) values (true) on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Plantillas: lo que Meta aprobó. `variables` = nombres EXACTOS de las variables del cuerpo,
-- como quedaron en Meta ({{nombre}} → 'nombre'). Si no coinciden, Meta rechaza el envío.
-- ---------------------------------------------------------------------------
create table if not exists wa_plantillas (
  nombre text primary key,
  idioma text not null default 'es_MX',
  categoria text not null check (categoria in ('utilidad', 'marketing')),
  uso text unique,                    -- aviso:<tipo>:<destinatario> | orden | campana:<segmento>
  variables text[] not null default '{}',
  encabezado text not null default 'ninguno' check (encabezado in ('ninguno', 'documento')),
  estado text not null default 'en_revision' check (estado in ('borrador', 'en_revision', 'aprobada', 'rechazada')),
  notas text,
  updated_at timestamptz not null default now()
);

-- Las 5 que se mandaron a revisión el 01/10/2026. Las variables son una SUPOSICIÓN:
-- al aprobarse, corrígelas para que coincidan con Meta y pon estado = 'aprobada'.
insert into wa_plantillas (nombre, categoria, uso, variables, encabezado, notas) values
  ('cita_confirmada',      'utilidad', 'aviso:confirmacion:cliente',   '{nombre,servicio,fecha,hora}', 'ninguno',   'Verificar variables contra Meta'),
  ('cita_reprogramada',    'utilidad', 'aviso:reprogramacion:cliente', '{nombre,servicio,fecha,hora}', 'ninguno',   'Verificar variables contra Meta'),
  ('cita_cancelada',       'utilidad', 'aviso:cancelacion:cliente',    '{nombre,servicio,fecha}',      'ninguno',   'Verificar variables contra Meta'),
  ('recordatorio_cita',    'utilidad', 'aviso:recordatorio:cliente',   '{nombre,servicio,hora}',       'ninguno',   'Verificar variables contra Meta'),
  ('orden_servicio_lista', 'utilidad', 'orden',                        '{nombre,folio}',               'documento', 'Verificar variables contra Meta')
on conflict (nombre) do nothing;

-- ---------------------------------------------------------------------------
-- Bajas: números que no quieren marketing
-- ---------------------------------------------------------------------------
create table if not exists wa_bajas (
  telefono_norm text primary key,
  origen text not null default 'whatsapp',    -- whatsapp (escribió BAJA / botón de Meta) | oficina
  nota text,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- La cola
-- ---------------------------------------------------------------------------
create table if not exists salida_wa (
  id uuid primary key default gen_random_uuid(),
  llave text not null unique,                 -- aviso:<id> | orden:<envio>:<tel> | texto:<uuid>
  telefono text not null,
  telefono_norm text generated always as (normalizar_telefono(telefono)) stored,
  conversacion_id uuid references conversaciones(id) on delete set null,
  tipo text not null check (tipo in ('texto', 'plantilla')),
  plantilla text references wa_plantillas(nombre),
  variables jsonb,                            -- fijas; los avisos las calculan al salir (datos frescos)
  documento_ruta text,                        -- bucket ordenes, para el encabezado de documento
  documento_nombre text,
  texto text,                                 -- texto libre, o resumen legible de la plantilla
  origen text not null check (origen in ('aviso', 'orden', 'respuesta', 'campana')),
  origen_id uuid,
  categoria text not null check (categoria in ('utilidad', 'marketing', 'servicio')),
  estado text not null default 'pendiente' check (estado in
    ('por_aprobar', 'pendiente', 'enviando', 'enviado', 'entregado', 'leido', 'fallido', 'cancelado', 'sin_confirmar')),
  intentos int not null default 0,
  error text,
  wa_message_id text unique,
  programado_para timestamptz not null default now(),
  aprobado_por text, aprobado_en timestamptz,
  tomado_en timestamptz, enviado_en timestamptz,
  creado_por text,
  created_at timestamptz not null default now()
);
create index if not exists idx_salida_wa_pendiente on salida_wa(programado_para) where estado = 'pendiente';
create index if not exists idx_salida_wa_tel on salida_wa(telefono_norm, created_at);

alter table wa_config enable row level security;
alter table wa_plantillas enable row level security;
alter table wa_bajas enable row level security;
alter table salida_wa enable row level security;
revoke all on wa_config, wa_plantillas, wa_bajas, salida_wa from anon;
grant select, insert, update, delete on wa_config, wa_plantillas, wa_bajas, salida_wa to authenticated;
drop policy if exists "admin_wa_config" on wa_config;
create policy "admin_wa_config" on wa_config for all to authenticated using (es_admin()) with check (es_admin());
drop policy if exists "admin_wa_plantillas" on wa_plantillas;
create policy "admin_wa_plantillas" on wa_plantillas for all to authenticated using (es_admin()) with check (es_admin());
drop policy if exists "admin_wa_bajas" on wa_bajas;
create policy "admin_wa_bajas" on wa_bajas for all to authenticated using (es_admin()) with check (es_admin());
drop policy if exists "admin_salida_wa" on salida_wa;
create policy "admin_salida_wa" on salida_wa for all to authenticated using (es_admin()) with check (es_admin());

-- ---------------------------------------------------------------------------
-- Número de destino para la API: México a 52 + 10 dígitos; extranjeros con su código.
-- ---------------------------------------------------------------------------
create or replace function _wa_destino(p_tel text) returns text
language sql immutable as $$
  select case
    when length(d) = 10 then '52' || d
    when d like '52%' and length(d) in (12, 13) then '52' || right(d, 10)
    else d end
  from (select regexp_replace(coalesce(p_tel, ''), '\D', '', 'g') as d) x
$$;

-- ---------------------------------------------------------------------------
-- Variables de un aviso de cita, en versión CORTA (las plantillas son texto fijo).
-- Nunca vacías: Meta rechaza un parámetro vacío.
-- ---------------------------------------------------------------------------
create or replace function _variables_aviso(p_aviso uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  a avisos%rowtype; c citas%rowtype; eq equipos%rowtype;
  v_dias text[] := array['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado'];
  v_meses text[] := array['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto',
                          'septiembre', 'octubre', 'noviembre', 'diciembre'];
  v_tec text; v_folio bigint;
begin
  a := (select x from avisos x where x.id = p_aviso);
  if a.id is null then return null; end if;
  c := (select x from citas x where x.id = a.cita_id);
  if c.equipo_id is not null then eq := (select x from equipos x where x.id = c.equipo_id); end if;
  v_tec := nullif(concat_ws(' y ',
             (select coalesce(nombre, email) from perfiles where id = c.tecnico_id),
             (select coalesce(nombre, email) from perfiles where id = c.tecnico2_id)), '');
  v_folio := (select folio from ordenes_servicio where cita_id = c.id limit 1);
  return jsonb_build_object(
    'nombre', coalesce(nullif(trim(a.nombre), ''), 'cliente'),
    'servicio', case c.tipo_servicio
                  when 'preventivo' then 'mantenimiento preventivo'
                  when 'correctivo' then 'servicio correctivo'
                  when 'instalacion' then 'instalación'
                  when 'diagnostico' then 'diagnóstico'
                  when 'visita_tecnica' then 'visita técnica'
                  else coalesce(c.tipo_servicio, 'servicio') end,
    'equipo', coalesce(nullif(trim(concat_ws(' ', eq.marca, case when eq.capacidad_kw is not null then eq.capacidad_kw || ' kW' end)), ''), 'su equipo'),
    'fecha', case when c.fecha is null then 'por confirmar' else
               v_dias[extract(dow from c.fecha)::int + 1] || ' ' || extract(day from c.fecha)::int
               || ' de ' || v_meses[extract(month from c.fecha)::int] end,
    'hora', coalesce(left(c.hora::text, 5) || ' h', 'por confirmar'),
    'tecnico', coalesce(v_tec, 'nuestro equipo técnico'),
    'folio', coalesce('OS-' || v_folio, 'su orden'));
end $$;
revoke all on function _variables_aviso(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Avisos de cita → cola. Al crearse un aviso con teléfono y con plantilla para su uso.
-- Si el aviso se manda a mano (wa.me) o se descarta, lo que esperaba en la cola se cancela.
-- ---------------------------------------------------------------------------
create or replace function _aviso_a_salida() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_pl wa_plantillas%rowtype; v_auto boolean;
begin
  if tg_op = 'INSERT' then
    if new.telefono is null or new.estado <> 'pendiente' then return new; end if;
    v_pl := (select p from wa_plantillas p where p.uso = 'aviso:' || new.tipo || ':' || new.destinatario);
    if v_pl.nombre is null then return new; end if;          -- sin plantilla: sigue siendo manual
    v_auto := coalesce((select avisos_automaticos from wa_config where id), false);
    insert into salida_wa (llave, telefono, tipo, plantilla, origen, origen_id, categoria, estado, texto, creado_por)
    values ('aviso:' || new.id, new.telefono, 'plantilla', v_pl.nombre, 'aviso', new.id, 'utilidad',
            case when v_auto then 'pendiente' else 'por_aprobar' end,
            'Aviso de ' || new.tipo || ' (plantilla ' || v_pl.nombre || ')', 'sistema')
    on conflict (llave) do nothing;
  elsif new.estado in ('enviado', 'descartado') and coalesce(new.canal, '') <> 'whatsapp_api' then
    update salida_wa set estado = 'cancelado', error = 'el aviso se resolvió fuera de la cola'
     where llave = 'aviso:' || new.id and estado in ('por_aprobar', 'pendiente');
  end if;
  return new;
end $$;
revoke all on function _aviso_a_salida() from public, anon, authenticated;
drop trigger if exists aviso_a_salida on avisos;
create trigger aviso_a_salida after insert or update of estado on avisos
  for each row execute function _aviso_a_salida();

-- ---------------------------------------------------------------------------
-- La orden de servicio en PDF → una fila por destinatario del envío (20).
-- Registrar "Enviar al cliente" ya es la aprobación: entra como pendiente.
-- ---------------------------------------------------------------------------
create or replace function encolar_orden(p_envio uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_env envios_orden%rowtype; v_folio bigint; v_n int := 0; d jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  v_env := (select e from envios_orden e where e.id = p_envio);
  if v_env.id is null then
    raise exception 'Ese envío no existe.' using errcode = 'P0002';
  end if;
  v_folio := (select folio from ordenes_servicio where id = v_env.orden_id);
  for d in select * from jsonb_array_elements(coalesce(v_env.destinatarios, '[]'::jsonb)) loop
    continue when normalizar_telefono(d ->> 'telefono') is null;
    insert into salida_wa (llave, telefono, tipo, plantilla, variables, documento_ruta, documento_nombre,
                           texto, origen, origen_id, categoria, estado, creado_por)
    values ('orden:' || p_envio || ':' || normalizar_telefono(d ->> 'telefono'), d ->> 'telefono', 'plantilla',
            'orden_servicio_lista',
            jsonb_build_object('nombre', coalesce(nullif(trim(d ->> 'nombre'), ''), 'cliente'), 'folio', 'OS-' || v_folio),
            v_env.ruta, 'OS-' || v_folio || '.pdf',
            'Orden de servicio OS-' || v_folio || ' (PDF)', 'orden', p_envio, 'utilidad', 'pendiente',
            coalesce(auth.jwt() ->> 'email', 'crm'))
    on conflict (llave) do nothing;
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'encolados', v_n);
end $$;

-- ---------------------------------------------------------------------------
-- Respuesta de texto libre (admin, o el borrador del agente que el admin aprueba).
-- Solo con la ventana de 24 h abierta.
-- ---------------------------------------------------------------------------
create or replace function responder_whatsapp(p_conversacion uuid, p_texto text, p_borrador uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_conv conversaciones%rowtype; v_id uuid := gen_random_uuid();
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if nullif(trim(coalesce(p_texto, '')), '') is null then
    raise exception 'El mensaje va vacío.' using errcode = '22023';
  end if;
  v_conv := (select c from conversaciones c where c.id = p_conversacion);
  if v_conv.id is null then
    raise exception 'La conversación no existe.' using errcode = 'P0002';
  end if;
  if v_conv.ventana_hasta is null or v_conv.ventana_hasta <= now() then
    raise exception 'La ventana de 24 h está cerrada: solo se puede mandar una plantilla aprobada.' using errcode = '22023';
  end if;
  insert into salida_wa (id, llave, telefono, conversacion_id, tipo, texto, origen, origen_id, categoria, estado,
                         aprobado_por, aprobado_en, creado_por)
  values (v_id, 'texto:' || v_id, v_conv.telefono, v_conv.id, 'texto', trim(p_texto), 'respuesta', p_borrador,
          'servicio', 'pendiente', coalesce(auth.jwt() ->> 'email', 'crm'), now(), coalesce(auth.jwt() ->> 'email', 'crm'));
  -- El borrador del agente queda marcado: ya no se ofrece "Mandar este borrador".
  if p_borrador is not null then
    update mensajes_wa set estado = 'aprobado' where id = p_borrador and estado = 'borrador';
  end if;
  return jsonb_build_object('ok', true, 'salida_id', v_id);
end $$;

-- Aprobar o cancelar lo que espera en la cola.
create or replace function aprobar_salida(p_ids uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  update salida_wa set estado = 'pendiente', aprobado_por = coalesce(auth.jwt() ->> 'email', 'crm'), aprobado_en = now()
   where id = any(p_ids) and estado = 'por_aprobar';
  return jsonb_build_object('ok', true, 'aprobados', (select count(*) from salida_wa where id = any(p_ids) and estado = 'pendiente'));
end $$;

create or replace function cancelar_salida(p_ids uuid[], p_motivo text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  update salida_wa set estado = 'cancelado', error = coalesce(nullif(trim(p_motivo), ''), 'cancelado por la oficina')
   where id = any(p_ids) and estado in ('por_aprobar', 'pendiente', 'fallido', 'sin_confirmar');
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- La Edge Function toma un lote. Revisa las reglas OTRA VEZ al salir (pudo cambiar algo
-- desde que se encoló): ventana, baja, plantilla aprobada. Lo que no pasa se marca con su motivo.
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
    if r.tipo = 'texto' then
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
      'id', r.id, 'to', _wa_destino(r.telefono), 'tipo', r.tipo, 'texto', case when r.tipo = 'texto' then r.texto end,
      'plantilla', r.plantilla, 'idioma', v_pl.idioma,
      'parametros', case when r.tipo = 'plantilla' then
         (select coalesce(jsonb_agg(jsonb_build_object('nombre', v, 'valor', v_vars ->> v)), '[]'::jsonb) from unnest(v_pl.variables) v) end,
      'documento_ruta', r.documento_ruta, 'documento_nombre', r.documento_nombre)));
  end loop;
  return jsonb_build_object('ok', true, 'mensajes', v_out);
end $$;

-- Resultado de cada envío. Un error temporal vuelve a la cola con espera (hasta 3 intentos).
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
  insert into mensajes_wa (conversacion_id, direccion, tipo, texto, wa_message_id, estado, enviado_por, wa_timestamp)
  values (v_conv, 'saliente', case when r.documento_ruta is not null then 'documento' else 'texto' end,
          coalesce(r.texto, r.plantilla), p_wa_message_id, 'enviado', coalesce(r.aprobado_por, 'api'), now())
  on conflict do nothing;
  update conversaciones set ultimo_mensaje_at = now() where id = v_conv;

  if r.origen = 'aviso' then
    update avisos set estado = 'enviado', canal = 'whatsapp_api', enviado_at = now(), enviado_por = 'api',
           texto_enviado = 'Plantilla ' || r.plantilla || ': ' || coalesce(r.variables::text, '')
     where id = r.origen_id and estado = 'pendiente';
  end if;
  return jsonb_build_object('ok', true, 'conversacion_id', v_conv);
end $$;

-- Acuses de Meta (webhook `statuses`): entregado / leído / fallido. Solo avanza, nunca retrocede.
create or replace function registrar_estado_wa(p_wa_message_id text, p_estado text, p_error text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_orden text[] := array['enviado', 'entregado', 'leido'];
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el conector de WhatsApp o el administrador.' using errcode = '42501';
  end if;
  p_estado := case p_estado when 'sent' then 'enviado' when 'delivered' then 'entregado'
                            when 'read' then 'leido' when 'failed' then 'fallido' else p_estado end;
  if p_estado not in ('enviado', 'entregado', 'leido', 'fallido') then
    return jsonb_build_object('ok', true, 'ignorado', true);
  end if;
  update salida_wa set estado = p_estado, error = coalesce(p_error, error)
   where wa_message_id = p_wa_message_id
     and (p_estado = 'fallido' or array_position(v_orden, p_estado) > coalesce(array_position(v_orden, estado), 0));
  update mensajes_wa set estado = p_estado where wa_message_id = p_wa_message_id;
  return jsonb_build_object('ok', true);
end $$;

-- BAJA: la registra el webhook (texto "BAJA"/"STOP" o el botón de baja de Meta) o la oficina.
create or replace function registrar_baja(p_telefono text, p_origen text default 'whatsapp', p_nota text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_norm text := normalizar_telefono(p_telefono);
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el conector de WhatsApp o el administrador.' using errcode = '42501';
  end if;
  if v_norm is null then
    raise exception 'El teléfono no trae 10 dígitos.' using errcode = '22023';
  end if;
  insert into wa_bajas (telefono_norm, origen, nota) values (v_norm, coalesce(p_origen, 'whatsapp'), p_nota)
  on conflict (telefono_norm) do nothing;
  update salida_wa set estado = 'cancelado', error = 'el número pidió BAJA'
   where telefono_norm = v_norm and categoria = 'marketing' and estado in ('por_aprobar', 'pendiente');
  return jsonb_build_object('ok', true);
end $$;

create or replace function quitar_baja(p_telefono text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  delete from wa_bajas where telefono_norm = normalizar_telefono(p_telefono);
  return jsonb_build_object('ok', true, 'quitada', found);
end $$;

-- Lo que la oficina tiene que ver: por aprobar, fallidos y los que salieron sin confirmación.
-- NO es `stable`: escribe (pasa a sin_confirmar lo atorado), y Postgres no deja escribir en una
-- función stable ("UPDATE is not allowed in a non-volatile function"). Corregido el 03/10/2026.
create or replace function cola_whatsapp() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  -- "enviando" por más de 10 min: la función se cayó a la mitad. No se reintenta sola
  -- (podría duplicar): se muestra para que una persona decida.
  update salida_wa set estado = 'sin_confirmar', error = 'no se confirmó el envío; revisa si llegó'
   where estado = 'enviando' and tomado_en < now() - interval '10 minutes';
  return (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'id', s.id, 'estado', s.estado, 'origen', s.origen, 'plantilla', s.plantilla,
            'telefono', s.telefono, 'texto', s.texto, 'error', s.error, 'creado', s.created_at,
            'plantilla_aprobada', (select p.estado = 'aprobada' from wa_plantillas p where p.nombre = s.plantilla)))
            order by s.created_at), '[]'::jsonb)
            from salida_wa s
           where s.estado in ('por_aprobar', 'pendiente', 'fallido', 'sin_confirmar'));
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'encolar_orden(uuid)', 'responder_whatsapp(uuid, text, uuid)', 'aprobar_salida(uuid[])',
    'cancelar_salida(uuid[], text)', 'tomar_salida(int)', 'marcar_salida(uuid, boolean, text, text, boolean)',
    'registrar_estado_wa(text, text, text)', 'registrar_baja(text, text, text)', 'quitar_baja(text)',
    'cola_whatsapp()'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Para la fase 3 (NO correr todavía): cuando exista la Edge Function `enviar-whatsapp`,
-- pg_cron la despierta cada minuto con pg_net. Los pasos exactos irán con el código.
-- ---------------------------------------------------------------------------

notify pgrst, 'reload schema';

select 'rls salida_wa' as que, relrowsecurity::text as ok from pg_class where relname = 'salida_wa'
union all
select 'trigger aviso_a_salida', exists (select 1 from pg_trigger where tgname = 'aviso_a_salida' and not tgisinternal)::text;
