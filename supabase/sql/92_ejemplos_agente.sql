-- ---------------------------------------------------------------------------
-- 92 · El agente de WhatsApp aprende de tus correcciones (26/10/2026)
--
-- Pedido de Caña: que la sugerencia "se retroalimente". Cada vez que usas una sugerencia del
-- agente y la mandas (tal cual o corregida), queda la pareja "lo que sugirió / lo que mandaste".
-- El agente recibe las más recientes como ejemplos de CÓMO contesta PowerMx: tono, largo y datos
-- que tú agregas. No es un modelo entrenado aparte: son ejemplos en el prompt, que se ven, se
-- pueden quitar ("No imitar este") y no cuestan nada hasta que se usan.
--
-- · wa_ejemplos: una fila por borrador usado (borrador_id único: mandar dos veces el mismo
--   borrador actualiza, no duplica). Solo admin la lee y la cambia (activo).
-- · Se llena sola con un disparador en salida_wa: una respuesta con origen_id = el borrador, que
--   no sea del propio agente. Para el envío a mano por wa.me, la pantalla llama a
--   guardar_ejemplo_wa.
-- · wa_ejemplos_agente(n) es lo que lee el agente (bot o admin): primero los que corregiste, sin
--   teléfonos ni correos. Los ejemplos vienen de OTROS clientes: el prompt le dice al agente que
--   solo imite la forma y nunca repita nombres, equipos, fechas ni cifras de ahí.
-- ---------------------------------------------------------------------------

create table if not exists wa_ejemplos (
  id               uuid primary key default gen_random_uuid(),
  conversacion_id  uuid references conversaciones(id) on delete set null,
  borrador_id      uuid unique,
  cliente_escribio text,
  sugerido         text not null,
  enviado          text not null,
  corregido        boolean generated always as (btrim(sugerido) <> btrim(enviado)) stored,
  activo           boolean not null default true,
  creado_por       text,
  created_at       timestamptz not null default now()
);

alter table wa_ejemplos enable row level security;
revoke all on wa_ejemplos from anon;
grant select, update on wa_ejemplos to authenticated;
drop policy if exists admin_wa_ejemplos on wa_ejemplos;
create policy admin_wa_ejemplos on wa_ejemplos for all to authenticated
  using (es_admin()) with check (es_admin());

-- Sin teléfonos ni correos: un ejemplo viaja a la conversación de OTRO cliente.
create or replace function _sin_datos_wa(p text) returns text
language sql immutable set search_path = public as $$
  select regexp_replace(
           regexp_replace(coalesce(p, ''), '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '[correo]', 'g'),
           '\+?[0-9][0-9 -]{6,}[0-9]', '[número]', 'g')
$$;

-- Guarda (o actualiza) la pareja de un borrador usado. Interna: la llaman el disparador y
-- guardar_ejemplo_wa.
create or replace function _guardar_ejemplo_wa(p_borrador uuid, p_enviado text, p_por text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_b mensajes_wa%rowtype;
  v_desde timestamptz;
  v_cliente text;
begin
  v_b := (select m from mensajes_wa m where m.id = p_borrador and m.direccion = 'saliente');
  if v_b.id is null
     or nullif(btrim(coalesce(v_b.texto, '')), '') is null
     or nullif(btrim(coalesce(p_enviado, '')), '') is null then
    return;
  end if;

  -- Lo que el cliente escribió desde la última respuesta de verdad (no borradores) hasta la
  -- sugerencia: es la pregunta que la sugerencia contestaba.
  v_desde := (select max(created_at) from mensajes_wa
               where conversacion_id = v_b.conversacion_id and direccion = 'saliente'
                 and estado <> 'borrador' and id <> v_b.id and created_at < v_b.created_at);
  v_cliente := (select string_agg(t.texto, E'\n' order by t.created_at)
                  from (select texto, created_at from mensajes_wa
                         where conversacion_id = v_b.conversacion_id and direccion = 'entrante'
                           and created_at <= v_b.created_at
                           and created_at > coalesce(v_desde, '-infinity'::timestamptz)
                           and nullif(btrim(coalesce(texto, '')), '') is not null
                         order by created_at desc limit 5) t);

  insert into wa_ejemplos (conversacion_id, borrador_id, cliente_escribio, sugerido, enviado, creado_por)
  values (v_b.conversacion_id, v_b.id, v_cliente, btrim(v_b.texto), btrim(p_enviado), p_por)
  on conflict (borrador_id) do update
    set enviado = excluded.enviado, cliente_escribio = excluded.cliente_escribio;
end $$;
revoke all on function _guardar_ejemplo_wa(uuid, text, text) from public;

create or replace function _ejemplo_desde_salida() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.origen = 'respuesta' and new.origen_id is not null
     and coalesce(new.creado_por, '') <> 'agente' then
    perform _guardar_ejemplo_wa(new.origen_id, new.texto, new.creado_por);
  end if;
  return new;
end $$;
revoke all on function _ejemplo_desde_salida() from public;

drop trigger if exists ejemplo_desde_salida on salida_wa;
create trigger ejemplo_desde_salida after insert on salida_wa
  for each row execute function _ejemplo_desde_salida();

-- El envío a mano (wa.me) no pasa por salida_wa: la pantalla avisa con esta.
create or replace function guardar_ejemplo_wa(p_borrador uuid, p_enviado text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  perform _guardar_ejemplo_wa(p_borrador, p_enviado, coalesce(auth.jwt() ->> 'email', 'crm'));
  return jsonb_build_object('ok', true);
end $$;
revoke all on function guardar_ejemplo_wa(uuid, text) from public, anon;
grant execute on function guardar_ejemplo_wa(uuid, text) to authenticated;

-- Lo que lee el agente: primero lo que corregiste (enseña más), luego lo más nuevo.
create or replace function wa_ejemplos_agente(p_n int default 12)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el conector de WhatsApp o el administrador.' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'cliente', left(_sin_datos_wa(e.cliente_escribio), 500),
             'sugeriste', left(_sin_datos_wa(e.sugerido), 500),
             'powermx_mando', left(_sin_datos_wa(e.enviado), 500)))
      from (select * from wa_ejemplos where activo
             order by corregido desc, created_at desc
             limit least(greatest(coalesce(p_n, 12), 0), 20)) e), '[]'::jsonb);
end $$;
revoke all on function wa_ejemplos_agente(int) from public, anon;
grant execute on function wa_ejemplos_agente(int) to authenticated;

insert into _migraciones (archivo, tipo) values ('92_ejemplos_agente.sql', 'esquema')
on conflict (archivo) do nothing;
