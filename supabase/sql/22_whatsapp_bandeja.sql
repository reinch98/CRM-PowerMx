-- ===========================================================================
-- WHATSAPP · BANDEJA DE CONVERSACIONES
--
-- Primera pieza de la conexión con WhatsApp (fase 2 del plan de CLAUDE.md): dónde
-- viven las conversaciones y los mensajes, y cómo se reconoce de quién es un número.
-- NO depende todavía de la API de Meta: las tablas y las funciones quedan listas y el
-- webhook (Edge Function) solo tendrá que llamar `registrar_mensaje_entrante`.
--
--   conversaciones  una por NÚMERO (no por contacto: un número desconocido todavía no
--                   tiene contacto). Se liga sola al contacto cuando el número ya está
--                   en `contactos` y no hay ambigüedad.
--   mensajes_wa     uno por mensaje, entrante o saliente. `wa_message_id` es único: el
--                   webhook de Meta reintenta, y un mensaje no se debe guardar dos veces.
--
-- **Ventana de 24 horas:** WhatsApp solo deja escribir libremente durante 24 h desde el
-- último mensaje del cliente. Fuera de eso hay que usar una plantilla aprobada. La
-- conversación guarda `ventana_hasta` para que la pantalla lo diga claro, en vez de
-- dejar que el envío falle.
--
-- Quién escribe: el admin, y más adelante el webhook con una cuenta de rol `bot`
-- (nunca `service_role`, como se acordó). El técnico no ve nada de esto.
-- Se puede repetir sin problema. Prueba: 22_prueba_whatsapp_bandeja.sql.
-- ===========================================================================

create table if not exists conversaciones (
  id uuid primary key default gen_random_uuid(),
  telefono text not null,
  telefono_norm text generated always as (normalizar_telefono(telefono)) stored,
  contacto_id uuid references contactos(id) on delete set null,
  cliente_id uuid references clientes(id) on delete set null,
  nombre_wa text,                       -- el nombre que reporta WhatsApp: dato del cliente, no de confianza
  estado text not null default 'abierta' check (estado in ('abierta', 'cerrada')),
  sin_leer int not null default 0 check (sin_leer >= 0),
  ventana_hasta timestamptz,            -- hasta cuándo se puede responder sin plantilla
  ultimo_mensaje_at timestamptz,
  created_at timestamptz not null default now()
);

-- Una conversación por número. Un número inválido (sin 10 dígitos) no bloquea la tabla.
create unique index if not exists un_conversaciones_telefono
  on conversaciones(telefono_norm) where telefono_norm is not null;
create index if not exists idx_conversaciones_abiertas
  on conversaciones(ultimo_mensaje_at desc) where estado = 'abierta';

create table if not exists mensajes_wa (
  id uuid primary key default gen_random_uuid(),
  conversacion_id uuid not null references conversaciones(id) on delete cascade,
  direccion text not null check (direccion in ('entrante', 'saliente')),
  tipo text not null default 'texto' check (tipo in ('texto', 'imagen', 'documento', 'audio', 'ubicacion', 'otro')),
  texto text,
  media_id text,                        -- id de Meta; el archivo se baja después (fase del webhook)
  wa_message_id text,
  estado text,                          -- saliente: enviado | entregado | leido | fallido
  error text,
  enviado_por text,                     -- correo de quien lo mandó desde el CRM
  wa_timestamp timestamptz,             -- cuándo dice WhatsApp que ocurrió
  created_at timestamptz not null default now()
);

-- El webhook de Meta entrega al menos una vez: el mismo mensaje puede llegar repetido.
create unique index if not exists un_mensajes_wa_id
  on mensajes_wa(wa_message_id) where wa_message_id is not null;
create index if not exists idx_mensajes_wa_conversacion
  on mensajes_wa(conversacion_id, created_at);

-- ---------------------------------------------------------------------------
-- Al nacer una conversación, se liga sola al contacto si el número ya se conoce.
-- Si el mismo número está en dos clientes (la 15 lo permite: un encargado de dos
-- sucursales), se deja sin ligar a propósito: lo decide una persona.
-- ---------------------------------------------------------------------------
create or replace function _ligar_conversacion_sola() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_n int; v_norm text;
begin
  if new.contacto_id is not null then
    select cliente_id into new.cliente_id from contactos where id = new.contacto_id;
    return new;
  end if;

  -- OJO: `telefono_norm` es una columna GENERADA, y Postgres las calcula DESPUÉS de
  -- los triggers `before insert`: aquí todavía llega en null. Hay que normalizar a
  -- mano con la misma función, o la conversación nunca se liga a su contacto.
  v_norm := normalizar_telefono(new.telefono);
  if v_norm is null then return new; end if;

  select count(*) into v_n from contactos c
   where c.activo and c.telefono_norm = v_norm;
  if v_n = 1 then
    select c.id, c.cliente_id into new.contacto_id, new.cliente_id
      from contactos c
     where c.activo and c.telefono_norm = v_norm;
  end if;
  return new;
end $$;
revoke all on function _ligar_conversacion_sola() from public, anon, authenticated;

drop trigger if exists ligar_conversacion_sola on conversaciones;
create trigger ligar_conversacion_sola before insert on conversaciones
  for each row execute function _ligar_conversacion_sola();

-- ---------------------------------------------------------------------------
-- RLS: solo admin lee y escribe directo. El webhook usará las funciones de abajo.
-- ---------------------------------------------------------------------------
alter table conversaciones enable row level security;
alter table mensajes_wa enable row level security;
revoke all on conversaciones, mensajes_wa from anon;

drop policy if exists "admin_conversaciones" on conversaciones;
create policy "admin_conversaciones" on conversaciones for all to authenticated
  using (es_admin()) with check (es_admin());

drop policy if exists "admin_mensajes_wa" on mensajes_wa;
create policy "admin_mensajes_wa" on mensajes_wa for all to authenticated
  using (es_admin()) with check (es_admin());

-- ---------------------------------------------------------------------------
-- Quién puede mover la bandeja: el admin y, cuando exista, el webhook con rol `bot`.
-- ---------------------------------------------------------------------------
create or replace function _es_bot_o_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select es_admin() or coalesce(mi_rol() = 'bot', false)
$$;
revoke all on function _es_bot_o_admin() from public, anon;

-- Guarda un mensaje que ENTRA. Crea la conversación si es la primera vez, abre otra vez
-- la ventana de 24 h y suma uno a los sin leer. Si el mensaje ya estaba (el webhook
-- reintentó), no hace nada y lo dice.
create or replace function registrar_mensaje_entrante(
  p_telefono text,
  p_wa_message_id text,
  p_texto text default null,
  p_nombre_wa text default null,
  p_tipo text default 'texto',
  p_media_id text default null,
  p_wa_timestamp timestamptz default now()
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_conv conversaciones%rowtype;
  v_norm text := normalizar_telefono(p_telefono);
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector de WhatsApp.' using errcode = '42501';
  end if;
  if v_norm is null then
    raise exception 'El teléfono no trae 10 dígitos: %', p_telefono using errcode = '22023';
  end if;
  if nullif(trim(coalesce(p_wa_message_id, '')), '') is null then
    raise exception 'Falta el id del mensaje de WhatsApp.' using errcode = '22023';
  end if;

  -- Ya lo teníamos: el webhook entrega al menos una vez.
  if exists (select 1 from mensajes_wa where wa_message_id = p_wa_message_id) then
    return jsonb_build_object('ok', true, 'repetido', true);
  end if;

  select * into v_conv from conversaciones where telefono_norm = v_norm;
  if not found then
    insert into conversaciones (telefono, nombre_wa) values (p_telefono, p_nombre_wa)
    returning * into v_conv;
  end if;

  insert into mensajes_wa (conversacion_id, direccion, tipo, texto, media_id, wa_message_id, estado, wa_timestamp)
  values (v_conv.id, 'entrante', coalesce(p_tipo, 'texto'), p_texto, p_media_id, p_wa_message_id, 'recibido', p_wa_timestamp);

  update conversaciones
     set sin_leer = sin_leer + 1,
         estado = 'abierta',
         ventana_hasta = p_wa_timestamp + interval '24 hours',
         ultimo_mensaje_at = p_wa_timestamp,
         nombre_wa = coalesce(nullif(trim(coalesce(p_nombre_wa, '')), ''), nombre_wa)
   where id = v_conv.id;

  return jsonb_build_object('ok', true, 'conversacion_id', v_conv.id,
                            'contacto_id', v_conv.contacto_id, 'conocido', v_conv.contacto_id is not null);
end $$;

-- Guarda un mensaje que SALE. No manda nada por sí solo: eso lo hará el webhook/Edge
-- Function con la API. Aquí queda el registro de lo que se mandó y a quién.
create or replace function registrar_mensaje_saliente(
  p_conversacion uuid,
  p_texto text,
  p_wa_message_id text default null,
  p_estado text default 'enviado'
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_conv conversaciones%rowtype;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector de WhatsApp.' using errcode = '42501';
  end if;
  if nullif(trim(coalesce(p_texto, '')), '') is null then
    raise exception 'El mensaje va vacío.' using errcode = '22023';
  end if;
  select * into v_conv from conversaciones where id = p_conversacion;
  if not found then raise exception 'La conversación no existe.' using errcode = 'P0002'; end if;

  insert into mensajes_wa (conversacion_id, direccion, tipo, texto, wa_message_id, estado, enviado_por, wa_timestamp)
  values (p_conversacion, 'saliente', 'texto', trim(p_texto), p_wa_message_id, p_estado,
          coalesce(auth.jwt() ->> 'email', 'crm'), now());

  update conversaciones set ultimo_mensaje_at = now() where id = p_conversacion;
  return jsonb_build_object('ok', true);
end $$;

-- Liga la conversación de un número desconocido a una persona ya registrada.
create or replace function vincular_conversacion(p_conversacion uuid, p_contacto uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_cliente uuid;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  select cliente_id into v_cliente from contactos where id = p_contacto and activo;
  if not found then raise exception 'El contacto no existe o está inactivo.' using errcode = 'P0002'; end if;

  update conversaciones set contacto_id = p_contacto, cliente_id = v_cliente
   where id = p_conversacion;
  if not found then raise exception 'La conversación no existe.' using errcode = 'P0002'; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function marcar_conversacion_leida(p_conversacion uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  update conversaciones set sin_leer = 0 where id = p_conversacion;
  return jsonb_build_object('ok', true);
end $$;

create or replace function cerrar_conversacion(p_conversacion uuid, p_abrir boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  update conversaciones set estado = case when p_abrir then 'abierta' else 'cerrada' end
   where id = p_conversacion;
  return jsonb_build_object('ok', true);
end $$;

-- La bandeja: conversaciones con su contexto (de quién es el número, si la ventana de
-- 24 h sigue abierta, y el último mensaje). Nunca trae precios ni costos.
create or replace function bandeja_whatsapp(p_incluir_cerradas boolean default false)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', cv.id,
      'telefono', cv.telefono,
      'nombre_wa', cv.nombre_wa,
      'estado', cv.estado,
      'sin_leer', cv.sin_leer,
      'ventana_hasta', cv.ventana_hasta,
      'ventana_abierta', cv.ventana_hasta is not null and cv.ventana_hasta > now(),
      'ultimo_mensaje_at', cv.ultimo_mensaje_at,
      'contacto_id', cv.contacto_id,
      'contacto', ct.nombre,
      'cliente', cl.nombre,
      'equipos', (
        select coalesce(jsonb_agg(distinct nullif(trim(concat_ws(' ', eq.tipo, eq.marca,
                 case when eq.capacidad_kw is not null then eq.capacidad_kw || ' kW' end)), '')), '[]'::jsonb)
          from contactos_por_equipo v
          join equipos eq on eq.id = v.equipo_id
         where v.contacto_id = cv.contacto_id),
      'ultimo_texto', (
        select m.texto from mensajes_wa m
         where m.conversacion_id = cv.id
         order by m.created_at desc limit 1)
    ) order by cv.ultimo_mensaje_at desc nulls last), '[]'::jsonb)
    into r
  from conversaciones cv
  left join contactos ct on ct.id = cv.contacto_id
  left join clientes cl on cl.id = cv.cliente_id
  where p_incluir_cerradas or cv.estado = 'abierta';

  return r;
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'registrar_mensaje_entrante(text, text, text, text, text, text, timestamptz)',
    'registrar_mensaje_saliente(uuid, text, text, text)',
    'vincular_conversacion(uuid, uuid)',
    'marcar_conversacion_leida(uuid)',
    'cerrar_conversacion(uuid, boolean)',
    'bandeja_whatsapp(boolean)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

notify pgrst, 'reload schema';

-- Verificación: RLS puesto y el trigger que liga solo.
select 'rls conversaciones' as que, relrowsecurity::text as ok from pg_class where relname = 'conversaciones'
union all
select 'rls mensajes_wa', relrowsecurity::text from pg_class where relname = 'mensajes_wa'
union all
select 'trigger ligar_conversacion_sola',
       exists (select 1 from pg_trigger where tgname = 'ligar_conversacion_sola' and not tgisinternal)::text;
