-- ============================================================================
-- 90 · El agente de WhatsApp contesta solo, y el admin recibe un aviso en su celular
--
-- Pedido de Caña (24/10/2026): "necesito que el agente empiece a responder por sí mismo y que
-- me notifique de alguna manera cuando nos envíen un mensaje".
--
-- 1. Respuesta automática. El modo 'automatico' del agente (27) nació antes de la cola de salida
--    (56): guardaba la respuesta en la conversación como 'por_enviar' y NADA la mandaba. Ahora
--    `wa_enviar_respuesta_agente` la mete a `salida_wa` como cualquier otra respuesta, y la vacía
--    `enviar-whatsapp` (la misma del reloj). `marcar_salida` la deja en la conversación al salir.
--    No contesta solo si una PERSONA escribió en esa conversación en las últimas 2 horas
--    (`wa_agente.pausa_si_persona_min`): ahí deja borrador, para no meterse en una plática que el
--    admin está atendiendo.
-- 2. Avisos push. `push_suscripciones` guarda un registro por navegador del admin que pidió
--    avisos (notificaciones web). El webhook, con la cuenta bot, lee los destinos con
--    `push_destinos()`; los que el servicio de avisos dé por muertos se quitan con `push_resultado`.
-- ============================================================================

alter table wa_agente add column if not exists pausa_si_persona_min int not null default 120;

create or replace function wa_enviar_respuesta_agente(p_conversacion uuid, p_texto text)
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

  insert into salida_wa (id, llave, telefono, conversacion_id, tipo, texto, origen, categoria, estado,
                         aprobado_por, aprobado_en, creado_por)
  values (v_id, 'texto:' || v_id, v_conv.telefono, v_conv.id, 'texto', trim(p_texto), 'respuesta',
          'servicio', 'pendiente', 'agente', now(), 'agente');
  return jsonb_build_object('enviado', true, 'salida_id', v_id);
end $$;
revoke all on function wa_enviar_respuesta_agente(uuid, text) from public, anon;
grant execute on function wa_enviar_respuesta_agente(uuid, text) to authenticated;

-- ---- avisos push ----
create table if not exists push_suscripciones (
  id uuid primary key default gen_random_uuid(),
  usuario uuid not null default auth.uid() references auth.users(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  dispositivo text,                     -- "Chrome en Android", para reconocerla en la lista
  activo boolean not null default true,
  creado_en timestamptz not null default now(),
  ultimo_aviso timestamptz
);
alter table push_suscripciones enable row level security;
revoke all on push_suscripciones from anon;
grant select, insert, update, delete on push_suscripciones to authenticated;

-- Cada admin ve y maneja solo las suyas.
drop policy if exists "push_propias" on push_suscripciones;
create policy "push_propias" on push_suscripciones for all to authenticated
  using (usuario = auth.uid() and es_admin())
  with check (usuario = auth.uid() and es_admin());

-- A dónde mandar el aviso: los navegadores activos de cualquier admin activo.
create or replace function push_destinos()
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el conector de WhatsApp o el administrador.' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
      from push_suscripciones s
      join perfiles p on p.id = s.usuario
     where s.activo and p.rol = 'admin' and coalesce(p.activo, true)
  ), '[]'::jsonb);
end $$;
revoke all on function push_destinos() from public, anon;
grant execute on function push_destinos() to authenticated;

-- Un aviso salió (anota la hora) o el servicio dijo que ese navegador ya no existe (la quita).
create or replace function push_resultado(p_endpoint text, p_vivo boolean)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el conector de WhatsApp o el administrador.' using errcode = '42501';
  end if;
  if p_vivo then
    update push_suscripciones set ultimo_aviso = now() where endpoint = p_endpoint;
  else
    delete from push_suscripciones where endpoint = p_endpoint;
  end if;
end $$;
revoke all on function push_resultado(text, boolean) from public, anon;
grant execute on function push_resultado(text, boolean) to authenticated;

notify pgrst, 'reload schema';

insert into _migraciones (archivo, tipo) values ('90_agente_automatico_y_avisos.sql', 'esquema')
on conflict (archivo) do nothing;
