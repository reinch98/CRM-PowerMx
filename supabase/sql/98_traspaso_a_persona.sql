-- ===========================================================================
-- 98 · El agente pasa al cliente con una persona y te avisa por WhatsApp (16/11/2026)
--
-- Pedido de Caña: "hasta ahora le dice al cliente que lo redirige a un compañero; quiero que cree
-- una tarjeta de contacto con su necesidad y se envíe a mi WhatsApp".
--
-- · `wa_traspasos`: una tarjeta por cliente que el agente pasó a una persona (quién, teléfono,
--   cliente del CRM si lo hay, qué necesita, si es urgente). Pendiente hasta "Ya lo atendí".
-- · `wa_pasar_a_persona` (la llama el agente, cuenta bot): crea la tarjeta y la manda al WhatsApp
--   de `wa_agente.telefono_traspasos` por la cola de salida (56):
--     - si ese número escribió al de PowerMx en las últimas 24 h (ventana abierta): un texto con
--       la tarjeta y una TARJETA DE CONTACTO de WhatsApp (tipo `contacto`), que se toca para
--       escribirle al cliente;
--     - si no: la plantilla `cliente_para_atender`, que hay que dar de alta en Meta. Mientras no
--       esté aprobada, espera en la cola sin error (la tarjeta del CRM y el aviso push sí llegan).
--   El teléfono del cliente sale de la CONVERSACIÓN, nunca del texto. Una segunda llamada con la
--   tarjeta pendiente solo actualiza la necesidad: no te vuelve a escribir.
-- · Mientras la tarjeta esté pendiente (24 h como máximo), el agente no le contesta solo a ese
--   cliente: deja borrador. La respuesta del mismo turno en que hizo el traspaso sí sale.
--
-- Sin `select ... into`. Se puede repetir. Prueba: 98_prueba_traspaso_a_persona.sql (con la CLI).
-- ===========================================================================

alter table wa_agente add column if not exists telefono_traspasos text;
-- De inicio, el teléfono del primer admin que tenga uno capturado.
update wa_agente set telefono_traspasos = (
  select p.telefono from perfiles p
   where p.rol = 'admin' and coalesce(p.activo, true) and nullif(trim(coalesce(p.telefono, '')), '') is not null
   order by p.created_at limit 1)
 where telefono_traspasos is null;

create table if not exists wa_traspasos (
  id uuid primary key default gen_random_uuid(),
  conversacion_id uuid not null references conversaciones(id) on delete cascade,
  telefono text not null,                 -- 10 dígitos, de la conversación
  cliente_id uuid references clientes(id) on delete set null,
  nombre text,                            -- como se presentó (o el contacto del CRM)
  empresa text,
  necesidad text not null,
  urgente boolean not null default false,
  estado text not null default 'pendiente' check (estado in ('pendiente', 'atendido')),
  avisado text,                           -- texto | plantilla | sin_numero
  created_at timestamptz not null default now(),
  actualizado_en timestamptz not null default now(),
  atendido_en timestamptz,
  atendido_por text,
  nota text
);
create index if not exists wa_traspasos_pendientes on wa_traspasos (conversacion_id) where estado = 'pendiente';

alter table wa_traspasos enable row level security;
revoke all on wa_traspasos from anon;
grant select on wa_traspasos to authenticated;
drop policy if exists "admin_lee_traspasos" on wa_traspasos;
create policy "admin_lee_traspasos" on wa_traspasos for select to authenticated using (es_admin());

-- ---- la cola acepta el origen y la tarjeta de contacto ----
alter table salida_wa drop constraint if exists salida_wa_origen_check;
alter table salida_wa add constraint salida_wa_origen_check
  check (origen = any (array['aviso', 'orden', 'respuesta', 'campana', 'manual', 'traspaso']));
alter table salida_wa drop constraint if exists salida_wa_tipo_check;
alter table salida_wa add constraint salida_wa_tipo_check
  check (tipo in ('texto', 'plantilla', 'imagen', 'documento', 'contacto'));

-- La plantilla que hay que dar de alta en Meta (Utilidad, español MX). Nace en borrador.
insert into wa_plantillas (nombre, categoria, uso, variables, encabezado, estado, notas) values
  ('cliente_para_atender', 'utilidad', 'traspaso', '{cliente,telefono,necesidad}', 'ninguno', 'borrador',
   E'Texto para darla de alta en Meta (Utilidad, español MX):\nHay un cliente para atender en el WhatsApp de PowerMx.\nCliente: {{cliente}}\nTeléfono: {{telefono}}\nNecesita: {{necesidad}}\nContéstale desde el CRM.')
on conflict (nombre) do nothing;

-- "+52 999 123 4567"
create or replace function _telefono_bonito(p_tel text) returns text
language sql immutable as $$
  select case when length(d) = 10
              then concat('+52 ', substr(d, 1, 3), ' ', substr(d, 4, 3), ' ', substr(d, 7, 4))
              else p_tel end
  from (select right(regexp_replace(coalesce(p_tel, ''), '\D', '', 'g'), 10) as d) x
$$;

-- ---------------------------------------------------------------------------
-- El agente pasa al cliente con una persona.
-- ---------------------------------------------------------------------------
create or replace function wa_pasar_a_persona(p_conversacion uuid, p_necesidad text,
  p_nombre text default null, p_empresa text default null, p_urgente boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_conv conversaciones%rowtype;
  v_cliente uuid;
  v_nombre_cliente text;
  v_contacto text;
  v_nec text := left(btrim(regexp_replace(coalesce(p_necesidad, ''), '\s+', ' ', 'g')), 400);
  v_nombre text := nullif(left(btrim(regexp_replace(coalesce(p_nombre, ''), '\s+', ' ', 'g')), 80), '');
  v_empresa text := nullif(left(btrim(regexp_replace(coalesce(p_empresa, ''), '\s+', ' ', 'g')), 80), '');
  v_previo uuid;
  v_id uuid := gen_random_uuid();
  v_destino text;
  v_dueno uuid;
  v_ventana boolean;
  v_quien text;
  v_tel text;
  v_vars jsonb;
  v_texto text;
  v_s uuid;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el conector de WhatsApp o el administrador.' using errcode = '42501';
  end if;
  if v_nec = '' then
    raise exception 'Escribe qué necesita el cliente.' using errcode = '22023';
  end if;
  v_conv := (select c from conversaciones c where c.id = p_conversacion);
  if v_conv.id is null then
    raise exception 'La conversación no existe.' using errcode = 'P0002';
  end if;

  -- Una tarjeta pendiente de las últimas 24 h: se actualiza, no se vuelve a avisar.
  v_previo := (select t.id from wa_traspasos t
                where t.conversacion_id = p_conversacion and t.estado = 'pendiente'
                  and t.created_at > now() - interval '24 hours'
                order by t.created_at desc limit 1);
  if v_previo is not null then
    update wa_traspasos
       set necesidad = v_nec, urgente = urgente or coalesce(p_urgente, false), actualizado_en = now(),
           nombre = coalesce(nombre, v_nombre), empresa = coalesce(empresa, v_empresa)
     where id = v_previo;
    return jsonb_build_object('ok', true, 'traspaso_id', v_previo, 'ya_avisado', true);
  end if;

  v_cliente := _cliente_de_conversacion(p_conversacion);
  v_nombre_cliente := (select c.nombre from clientes c where c.id = v_cliente);
  v_contacto := (select k.nombre from contactos k where k.id = v_conv.contacto_id);
  v_tel := right(regexp_replace(coalesce(v_conv.telefono, ''), '\D', '', 'g'), 10);

  insert into wa_traspasos (id, conversacion_id, telefono, cliente_id, nombre, empresa, necesidad, urgente)
  values (v_id, p_conversacion, v_tel, v_cliente, coalesce(v_contacto, v_nombre),
          coalesce(v_nombre_cliente, v_empresa), v_nec, coalesce(p_urgente, false));

  -- ¿A dónde te avisamos?
  v_destino := right(regexp_replace(coalesce((select a.telefono_traspasos from wa_agente a limit 1), ''), '\D', '', 'g'), 10);
  if length(v_destino) <> 10 then
    update wa_traspasos set avisado = 'sin_numero' where id = v_id;
    return jsonb_build_object('ok', true, 'traspaso_id', v_id, 'avisado', false, 'motivo', 'sin_numero');
  end if;

  v_quien := concat_ws(' · ', coalesce(v_contacto, v_nombre, 'Sin nombre'), coalesce(v_nombre_cliente, v_empresa))
             || case when v_cliente is null then ' (número nuevo)' else '' end;
  v_vars := jsonb_build_object(
    'cliente', left(v_quien, 200),
    'telefono', _telefono_bonito(v_tel),
    'necesidad', left(case when coalesce(p_urgente, false) then 'URGENTE: ' else '' end || v_nec, 420));
  v_texto := concat('Cliente para atender: ', v_vars ->> 'cliente', ' · ', v_vars ->> 'telefono',
                    ' · Necesita: ', v_vars ->> 'necesidad');

  v_dueno := (select c.id from conversaciones c where c.telefono_norm = v_destino limit 1);
  v_ventana := exists (select 1 from conversaciones c where c.id = v_dueno and c.ventana_hasta > now() + interval '1 minute');

  if v_ventana then
    -- Ventana abierta: texto libre + la tarjeta de contacto de WhatsApp.
    v_s := gen_random_uuid();
    insert into salida_wa (id, llave, telefono, conversacion_id, tipo, texto, origen, origen_id, categoria,
                           estado, aprobado_por, aprobado_en, creado_por)
    values (v_s, 'traspaso:' || v_id, v_destino, v_dueno, 'texto',
            concat(case when coalesce(p_urgente, false) then E'🔴 URGENTE\n' else '' end,
                   E'Cliente para atender\n', v_vars ->> 'cliente', E'\n', v_vars ->> 'telefono',
                   E'\nNecesita: ', v_nec),
            'traspaso', v_id, 'servicio', 'pendiente', 'agente', now(), 'agente');
    v_s := gen_random_uuid();
    insert into salida_wa (id, llave, telefono, conversacion_id, tipo, texto, variables, origen, origen_id,
                           categoria, estado, aprobado_por, aprobado_en, creado_por, programado_para)
    values (v_s, 'traspaso-tarjeta:' || v_id, v_destino, v_dueno, 'contacto',
            concat('Tarjeta de contacto: ', v_vars ->> 'cliente'),
            jsonb_strip_nulls(jsonb_build_object(
              'nombre', coalesce(v_contacto, v_nombre, 'Cliente ' || v_tel),
              'empresa', coalesce(v_nombre_cliente, v_empresa),
              'telefono', '+52' || v_tel, 'wa_id', '52' || v_tel)),
            'traspaso', v_id, 'servicio', 'pendiente', 'agente', now(), 'agente', now() + interval '5 seconds');
    update wa_traspasos set avisado = 'texto' where id = v_id;
  else
    -- Ventana cerrada: solo una plantilla aprobada puede salir.
    insert into salida_wa (id, llave, telefono, conversacion_id, tipo, plantilla, variables, texto, origen,
                           origen_id, categoria, estado, aprobado_por, aprobado_en, creado_por)
    values (gen_random_uuid(), 'traspaso:' || v_id, v_destino, v_dueno, 'plantilla', 'cliente_para_atender',
            v_vars, v_texto, 'traspaso', v_id, 'utilidad', 'pendiente', 'agente', now(), 'agente');
    update wa_traspasos set avisado = 'plantilla' where id = v_id;
  end if;

  return jsonb_build_object('ok', true, 'traspaso_id', v_id, 'avisado', true,
    'por', case when v_ventana then 'texto' else 'plantilla' end,
    'plantilla_aprobada', coalesce((select p.estado = 'aprobada' from wa_plantillas p where p.nombre = 'cliente_para_atender'), false));
end $$;
revoke all on function wa_pasar_a_persona(uuid, text, text, text, boolean) from public, anon;
grant execute on function wa_pasar_a_persona(uuid, text, text, text, boolean) to authenticated;

-- "Ya lo atendí" (solo admin). El agente vuelve a contestar en esa conversación.
create or replace function atender_traspaso(p_id uuid, p_nota text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  update wa_traspasos
     set estado = 'atendido', atendido_en = now(), atendido_por = coalesce(auth.jwt() ->> 'email', 'crm'),
         nota = nullif(btrim(coalesce(p_nota, '')), ''), actualizado_en = now()
   where id = p_id and estado = 'pendiente';
  return jsonb_build_object('ok', true, 'cambio', found);
end $$;
revoke all on function atender_traspaso(uuid, text) from public, anon;
grant execute on function atender_traspaso(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- wa_enviar_respuesta_agente (de la 90) con la pausa por traspaso. `p_traspaso` = la tarjeta que
-- el agente creó EN ESTE turno: esa respuesta ("te paso con un compañero") sí sale.
-- ---------------------------------------------------------------------------
drop function if exists wa_enviar_respuesta_agente(uuid, text);
create or replace function wa_enviar_respuesta_agente(p_conversacion uuid, p_texto text, p_traspaso uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_conv conversaciones%rowtype; v_id uuid := gen_random_uuid(); v_pausa int; v_persona timestamptz;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el conector de WhatsApp o el administrador.' using errcode = '42501';
  end if;
  if nullif(trim(coalesce(p_texto, '')), '') is null then
    raise exception 'El mensaje va vacío.' using errcode = '22023';
  end if;
  v_conv := (select c from conversaciones c where c.id = p_conversacion);
  if v_conv.id is null then
    raise exception 'La conversación no existe.' using errcode = 'P0002';
  end if;
  if v_conv.ventana_hasta is null or v_conv.ventana_hasta <= now() then
    return jsonb_build_object('enviado', false, 'motivo', 'ventana_cerrada');
  end if;
  -- ¿Una persona del CRM escribió aquí hace poco? Entonces el agente solo propone.
  v_pausa := coalesce((select pausa_si_persona_min from wa_agente limit 1), 120);
  v_persona := (select max(m.created_at) from mensajes_wa m
                 where m.conversacion_id = p_conversacion and m.direccion = 'saliente'
                   and m.estado in ('enviado', 'entregado', 'leido')
                   and exists (select 1 from perfiles p where p.email = m.enviado_por and p.rol = 'admin'));
  if v_persona is not null and v_persona > now() - make_interval(mins => v_pausa) then
    return jsonb_build_object('enviado', false, 'motivo', 'conversacion_atendida');
  end if;
  -- (98) Ya lo pasó a una persona y nadie lo ha marcado atendido: el agente solo propone.
  if exists (select 1 from wa_traspasos t
              where t.conversacion_id = p_conversacion and t.estado = 'pendiente'
                and t.created_at > now() - interval '24 hours'
                and t.id is distinct from p_traspaso) then
    return jsonb_build_object('enviado', false, 'motivo', 'pasado_a_persona');
  end if;

  insert into salida_wa (id, llave, telefono, conversacion_id, tipo, texto, origen, categoria, estado,
                         aprobado_por, aprobado_en, creado_por)
  values (v_id, 'texto:' || v_id, v_conv.telefono, v_conv.id, 'texto', trim(p_texto), 'respuesta',
          'servicio', 'pendiente', 'agente', now(), 'agente');
  return jsonb_build_object('enviado', true, 'salida_id', v_id);
end $$;
revoke all on function wa_enviar_respuesta_agente(uuid, text, uuid) from public, anon;
grant execute on function wa_enviar_respuesta_agente(uuid, text, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- tomar_salida (de la 96): la tarjeta de contacto viaja con sus datos.
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
      'id', r.id, 'to', _wa_destino(r.telefono), 'tipo', r.tipo,
      'texto', case when r.tipo not in ('plantilla', 'contacto') then r.texto end,
      'plantilla', r.plantilla, 'idioma', v_pl.idioma,
      'parametros', case when r.tipo = 'plantilla' then
         (select coalesce(jsonb_agg(jsonb_build_object('nombre', v, 'valor', v_vars ->> v)), '[]'::jsonb) from unnest(v_pl.variables) v) end,
      'contacto', case when r.tipo = 'contacto' then r.variables end,
      'documento_ruta', r.documento_ruta, 'documento_nombre', r.documento_nombre,
      'media_ruta', r.media_ruta, 'media_mime', r.media_mime, 'media_nombre', r.media_nombre)));
  end loop;
  return jsonb_build_object('ok', true, 'mensajes', v_out);
end $$;

-- marcar_salida (de la 96): la tarjeta de contacto queda en la conversación como 'otro'.
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

  v_conv := coalesce(r.conversacion_id, (select id from conversaciones where telefono_norm = r.telefono_norm));
  if v_conv is null then
    v_conv := gen_random_uuid();
    insert into conversaciones (id, telefono, estado) values (v_conv, r.telefono, 'abierta');
  end if;
  insert into mensajes_wa (conversacion_id, direccion, tipo, texto, wa_message_id, estado, enviado_por, wa_timestamp,
                           media_ruta, media_mime, media_nombre)
  values (v_conv, 'saliente',
          case when r.tipo in ('imagen', 'documento') then r.tipo
               when r.tipo = 'contacto' then 'otro'
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

insert into _migraciones (archivo, tipo) values ('98_traspaso_a_persona.sql', 'esquema')
on conflict (archivo) do nothing;
