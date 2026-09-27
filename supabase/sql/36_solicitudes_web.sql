-- ---------------------------------------------------------------------------
-- 36_solicitudes_web.sql — las solicitudes de cotización del sitio público llegan al CRM.
--
-- Hasta hoy el formulario de cotizar.html mandaba todo a un webhook de n8n y a WhatsApp;
-- nada quedaba en el CRM. Ahora el sitio llama a la Edge Function `solicitud-web`, que
-- entra con la cuenta de rol `bot` (como el webhook de WhatsApp: nada de service_role) y
-- solo puede llamar a `registrar_solicitud_web`.
--
-- Una solicitud NO crea un cliente: un número equivocado o un bot llenaría la base de
-- basura. Queda en esta tabla, el admin la ve en la pantalla "Solicitudes" y decide.
-- Lo único que hace la base por su cuenta es SUGERIR un cliente cuando el teléfono
-- coincide con exactamente una persona ya registrada.
--
-- Repetible: `if not exists`, `drop policy if exists`, `create or replace`.
-- ---------------------------------------------------------------------------

create table if not exists solicitudes_web (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  nombre text not null,
  telefono text not null,
  telefono_norm text not null,          -- últimos 10 dígitos, calculado por la función
  email text,
  ubicacion text,
  tipos text,                           -- lo que marcó en el formulario: "Generador, Solar"
  uso text,
  equipo_actual text,
  consumo text,
  presupuesto text,
  plazo text,
  fuente text,                          -- cómo nos conoció
  notas text,
  origen_url text,                      -- desde qué página del sitio lo mandó
  cliente_id uuid references clientes(id) on delete set null,   -- sugerido por teléfono, o el que el admin ligue
  estado text not null default 'nueva' check (estado in ('nueva', 'atendida', 'descartada')),
  nota_interna text,
  atendida_por text,                    -- correo de quien la resolvió
  atendida_en timestamptz
);

create index if not exists idx_solicitudes_web_estado on solicitudes_web(estado, created_at desc);
create index if not exists idx_solicitudes_web_telefono on solicitudes_web(telefono_norm, created_at desc);

alter table solicitudes_web enable row level security;
revoke all on solicitudes_web from anon;

-- Solo el admin lee y modifica. Nadie inserta directo: se entra por la función.
drop policy if exists "admin_solicitudes_web" on solicitudes_web;
create policy "admin_solicitudes_web" on solicitudes_web for all to authenticated
  using (es_admin()) with check (es_admin());

-- ---------------------------------------------------------------------------
-- Guarda una solicitud del sitio. La llama la Edge Function con la cuenta `bot`.
-- Todo lo que llega es texto de un desconocido: se recorta, se valida y nunca se
-- interpreta como instrucción.
-- Errores que la Edge Function traduce: 22023 = dato inválido (400), 54000 = tope (429).
-- ---------------------------------------------------------------------------
create or replace function registrar_solicitud_web(
  p_nombre text,
  p_telefono text,
  p_email text default null,
  p_ubicacion text default null,
  p_tipos text default null,
  p_uso text default null,
  p_equipo_actual text default null,
  p_consumo text default null,
  p_presupuesto text default null,
  p_plazo text default null,
  p_fuente text default null,
  p_notas text default null,
  p_origen_url text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_nombre text := left(trim(coalesce(p_nombre, '')), 120);
  v_norm text := normalizar_telefono(p_telefono);
  v_tipos text := nullif(left(trim(coalesce(p_tipos, '')), 200), '');
  v_notas text := nullif(left(trim(coalesce(p_notas, '')), 2000), '');
  v_n int;
  v_id uuid;
  v_cliente uuid;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector del sitio.' using errcode = '42501';
  end if;
  if length(v_nombre) < 2 then
    raise exception 'Escribe tu nombre.' using errcode = '22023';
  end if;
  if v_norm is null then
    raise exception 'El WhatsApp debe tener 10 dígitos.' using errcode = '22023';
  end if;
  if p_email is not null and length(trim(p_email)) > 0
     and trim(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'El correo no parece válido.' using errcode = '22023';
  end if;

  -- Topes contra abuso: por hora en todo el sitio, y por día para un mismo número.
  v_n := (select count(*) from solicitudes_web where created_at > now() - interval '1 hour');
  if v_n >= 60 then
    raise exception 'Hay muchas solicitudes en este momento.' using errcode = '54000';
  end if;
  v_n := (select count(*) from solicitudes_web
           where telefono_norm = v_norm and created_at > now() - interval '1 day');
  if v_n >= 5 then
    raise exception 'Ya recibimos varias solicitudes de este número hoy.' using errcode = '54000';
  end if;

  -- Un doble clic o un reintento: mismo número y mismo contenido en 10 minutos.
  v_id := (select s.id from solicitudes_web s
            where s.telefono_norm = v_norm
              and s.created_at > now() - interval '10 minutes'
              and coalesce(s.tipos, '') = coalesce(v_tipos, '')
              and coalesce(s.notas, '') = coalesce(v_notas, '')
            limit 1);
  if v_id is not null then
    return jsonb_build_object('ok', true, 'repetido', true, 'id', v_id);
  end if;

  -- Cliente sugerido: solo si el teléfono es de UNA persona activa; con dos o más
  -- clientes distintos no se adivina.
  if (select count(distinct c.cliente_id) from contactos c
       where c.activo and c.telefono_norm = v_norm) = 1 then
    v_cliente := (select c.cliente_id from contactos c
                   where c.activo and c.telefono_norm = v_norm limit 1);
  end if;

  v_id := gen_random_uuid();
  insert into solicitudes_web (
    id, nombre, telefono, telefono_norm, email, ubicacion, tipos, uso, equipo_actual,
    consumo, presupuesto, plazo, fuente, notas, origen_url, cliente_id
  ) values (
    v_id, v_nombre, left(trim(p_telefono), 30), v_norm,
    nullif(left(trim(coalesce(p_email, '')), 160), ''),
    nullif(left(trim(coalesce(p_ubicacion, '')), 200), ''),
    v_tipos,
    nullif(left(trim(coalesce(p_uso, '')), 60), ''),
    nullif(left(trim(coalesce(p_equipo_actual, '')), 100), ''),
    nullif(left(trim(coalesce(p_consumo, '')), 100), ''),
    nullif(left(trim(coalesce(p_presupuesto, '')), 100), ''),
    nullif(left(trim(coalesce(p_plazo, '')), 100), ''),
    nullif(left(trim(coalesce(p_fuente, '')), 100), ''),
    v_notas,
    nullif(left(trim(coalesce(p_origen_url, '')), 300), ''),
    v_cliente
  );

  return jsonb_build_object('ok', true, 'repetido', false, 'id', v_id,
                            'cliente_sugerido', v_cliente is not null);
end $$;

revoke all on function registrar_solicitud_web(text, text, text, text, text, text, text, text, text, text, text, text, text)
  from public, anon;
grant execute on function registrar_solicitud_web(text, text, text, text, text, text, text, text, text, text, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- El admin resuelve una solicitud: la marca atendida o descartada (o la reabre), anota
-- qué pasó y, si quiere, la liga a un cliente. Deja quién y cuándo.
-- ---------------------------------------------------------------------------
create or replace function resolver_solicitud_web(
  p_id uuid,
  p_estado text,
  p_nota text default null,
  p_cliente uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if p_estado not in ('nueva', 'atendida', 'descartada') then
    raise exception 'Estado no válido: %', p_estado using errcode = '22023';
  end if;
  if not exists (select 1 from solicitudes_web where id = p_id) then
    raise exception 'La solicitud no existe.' using errcode = 'P0002';
  end if;
  if p_cliente is not null and not exists (select 1 from clientes where id = p_cliente) then
    raise exception 'El cliente no existe.' using errcode = '22023';
  end if;

  update solicitudes_web set
    estado = p_estado,
    nota_interna = coalesce(nullif(left(trim(coalesce(p_nota, '')), 1000), ''), nota_interna),
    cliente_id = coalesce(p_cliente, cliente_id),
    atendida_por = case when p_estado = 'nueva' then null else coalesce(auth.jwt() ->> 'email', 'crm') end,
    atendida_en  = case when p_estado = 'nueva' then null else now() end
  where id = p_id;

  return jsonb_build_object('ok', true);
end $$;

revoke all on function resolver_solicitud_web(uuid, text, text, uuid) from public, anon;
grant execute on function resolver_solicitud_web(uuid, text, text, uuid) to authenticated;
