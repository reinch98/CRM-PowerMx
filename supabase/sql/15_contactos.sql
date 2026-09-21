-- ===========================================================================
-- CONTACTOS: las personas de un cliente y quién está a cargo de cada equipo
--
-- Base para que, más adelante, el agente de WhatsApp reconozca números, sepa de qué
-- equipo habla cada persona (sin pedirle el número de serie) y a quién mandar la orden
-- de servicio y las cotizaciones. No depende de WhatsApp: sirve ya para el CRM.
--
--   · `contactos`: una fila por persona-y-número (si alguien tiene dos números, dos
--     filas con el mismo nombre). Pertenece a un cliente (empresa). Puede ser "de toda la
--     empresa" (por ejemplo administración: aplica a todos sus equipos).
--   · `equipo_contactos`: qué personas están a cargo de un equipo, con su rol
--     (responsable | encargado | administracion | solo_avisos) y sus permisos:
--     pedir citas, recibir órdenes de servicio, recibir cotizaciones.
--     Un equipo tiene como máximo UN responsable; encargados y demás, los que sean.
--   · Los teléfonos se comparan por sus últimos 10 dígitos (`telefono_norm`): WhatsApp
--     entrega los de México como 521…, y sin normalizar no coincidirían con "999 123 4567".
--   · Un mismo número puede estar en varios clientes (un encargado de dos sucursales).
--   · `contactos_por_equipo`: vista con todo el que corresponde a un equipo (los ligados
--     y los de toda la empresa).
--   · `identificar_telefono(tel)`: dado un número, devuelve sus contactos, clientes y equipos.
--     Por ahora solo admin; el agente de WhatsApp la usará con su propia cuenta.
--   · Los contactos de un número NO verificado no deben dar datos (`verificado`).
--
-- Solo el admin lee y escribe. `clientes.telefono` sigue siendo el teléfono de la ficha
-- (el técnico lo usa para llamar); los contactos de aquí son las personas.
-- Se puede volver a ejecutar sin problema (la migración no duplica).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Normalizar teléfonos: últimos 10 dígitos, o nulo si no hay 10.
-- ---------------------------------------------------------------------------
create or replace function normalizar_telefono(t text) returns text
language sql immutable as $$
  select case
    when length(regexp_replace(coalesce(t, ''), '\D', '', 'g')) >= 10
      then right(regexp_replace(t, '\D', '', 'g'), 10)
  end
$$;

-- ---------------------------------------------------------------------------
-- 2. Tablas
-- ---------------------------------------------------------------------------
create table if not exists contactos (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references clientes(id) on delete cascade,
  nombre text not null,
  puesto text,
  telefono text,
  telefono_norm text generated always as (normalizar_telefono(telefono)) stored,
  email text,
  whatsapp boolean not null default true,        -- ¿ese número usa WhatsApp?
  verificado boolean not null default false,     -- el admin confirmó que es de esa persona
  activo boolean not null default true,
  notas text,
  -- Contacto de toda la empresa: aplica a todos sus equipos con estos permisos.
  de_toda_la_empresa boolean not null default false,
  puede_pedir_citas boolean not null default false,
  recibe_ordenes boolean not null default false,
  recibe_cotizaciones boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_contactos_cliente on contactos(cliente_id) where activo;
create index if not exists idx_contactos_telefono on contactos(telefono_norm) where activo;
-- El mismo número no se repite dentro de un mismo cliente (sí entre clientes distintos).
create unique index if not exists un_contacto_telefono_por_cliente
  on contactos(cliente_id, telefono_norm) where activo and telefono_norm is not null;

drop trigger if exists tocar_updated_at on contactos;
create trigger tocar_updated_at before update on contactos
  for each row execute function tocar_updated_at();

create table if not exists equipo_contactos (
  id uuid primary key default gen_random_uuid(),
  equipo_id uuid not null references equipos(id) on delete cascade,
  contacto_id uuid not null references contactos(id) on delete cascade,
  rol text not null check (rol in ('responsable', 'encargado', 'administracion', 'solo_avisos')),
  puede_pedir_citas boolean not null default false,
  recibe_ordenes boolean not null default false,
  recibe_cotizaciones boolean not null default false,
  created_at timestamptz not null default now(),
  unique (equipo_id, contacto_id)
);

create index if not exists idx_equipo_contactos_contacto on equipo_contactos(contacto_id);
-- Un solo responsable por equipo.
create unique index if not exists un_responsable_por_equipo
  on equipo_contactos(equipo_id) where rol = 'responsable';

-- ---------------------------------------------------------------------------
-- 3. RLS: solo admin
-- ---------------------------------------------------------------------------
alter table contactos        enable row level security;
alter table equipo_contactos enable row level security;
revoke all on contactos, equipo_contactos from anon;

drop policy if exists "admin_contactos" on contactos;
create policy "admin_contactos" on contactos for all to authenticated
  using (es_admin()) with check (es_admin());
drop policy if exists "admin_equipo_contactos" on equipo_contactos;
create policy "admin_equipo_contactos" on equipo_contactos for all to authenticated
  using (es_admin()) with check (es_admin());

-- ---------------------------------------------------------------------------
-- 4. Vista: todo el que corresponde a un equipo (invoker: aplica RLS de quien consulta).
-- ---------------------------------------------------------------------------
create or replace view contactos_por_equipo as
select ec.equipo_id, c.id as contacto_id, c.cliente_id, c.nombre, c.puesto,
       c.telefono, c.telefono_norm, c.whatsapp, c.verificado,
       ec.rol, ec.puede_pedir_citas, ec.recibe_ordenes, ec.recibe_cotizaciones,
       'equipo'::text as origen
  from equipo_contactos ec
  join contactos c on c.id = ec.contacto_id
 where c.activo
union all
select e.id, c.id, c.cliente_id, c.nombre, c.puesto,
       c.telefono, c.telefono_norm, c.whatsapp, c.verificado,
       'empresa'::text, c.puede_pedir_citas, c.recibe_ordenes, c.recibe_cotizaciones,
       'empresa'::text
  from contactos c
  join equipos e on e.cliente_id = c.cliente_id
 where c.activo and c.de_toda_la_empresa
   and not exists (select 1 from equipo_contactos x
                    where x.equipo_id = e.id and x.contacto_id = c.id);

alter view contactos_por_equipo set (security_invoker = on);
revoke all on contactos_por_equipo from anon, authenticated;
grant select on contactos_por_equipo to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Funciones
-- ---------------------------------------------------------------------------

-- Liga a una persona con un equipo y le pone sus permisos según el rol (se pueden
-- pasar a mano). Si el rol es "responsable", el responsable anterior pasa a "encargado".
-- La persona debe ser del mismo cliente que el equipo.
create or replace function vincular_contacto(
  p_equipo uuid,
  p_contacto uuid,
  p_rol text,
  p_pedir_citas boolean default null,
  p_ordenes boolean default null,
  p_cotizaciones boolean default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cliente_equipo uuid;
  v_cliente_contacto uuid;
  v_citas boolean;
  v_ord boolean;
  v_cot boolean;
  v_bajados int := 0;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if p_rol not in ('responsable', 'encargado', 'administracion', 'solo_avisos') then
    raise exception 'Rol no válido: %', p_rol using errcode = '22023';
  end if;

  select cliente_id into v_cliente_equipo from equipos where id = p_equipo;
  if not found then raise exception 'El equipo no existe.' using errcode = 'P0002'; end if;
  select cliente_id into v_cliente_contacto from contactos where id = p_contacto and activo;
  if not found then raise exception 'El contacto no existe o está inactivo.' using errcode = 'P0002'; end if;
  if v_cliente_equipo is distinct from v_cliente_contacto then
    raise exception 'La persona y el equipo son de clientes distintos.' using errcode = '22023';
  end if;

  -- Permisos por defecto de cada rol.
  v_citas := coalesce(p_pedir_citas, p_rol in ('responsable', 'encargado'));
  v_ord   := coalesce(p_ordenes,     true);
  v_cot   := coalesce(p_cotizaciones, p_rol in ('responsable', 'administracion'));

  if p_rol = 'responsable' then
    update equipo_contactos set rol = 'encargado'
     where equipo_id = p_equipo and rol = 'responsable' and contacto_id <> p_contacto;
    get diagnostics v_bajados = row_count;
  end if;

  insert into equipo_contactos
    (equipo_id, contacto_id, rol, puede_pedir_citas, recibe_ordenes, recibe_cotizaciones)
  values (p_equipo, p_contacto, p_rol, v_citas, v_ord, v_cot)
  on conflict (equipo_id, contacto_id) do update
    set rol = excluded.rol,
        puede_pedir_citas = excluded.puede_pedir_citas,
        recibe_ordenes = excluded.recibe_ordenes,
        recibe_cotizaciones = excluded.recibe_cotizaciones;

  return jsonb_build_object('ok', true, 'rol', p_rol, 'responsable_anterior_bajado', v_bajados > 0);
end $$;

-- Dado un número (en cualquier formato), quiénes son, de qué cliente y a cargo de qué
-- equipos. Incluye el número de serie porque el cliente casi nunca lo sabe: el agente lo
-- toma de aquí. Solo admin por ahora.
create or replace function identificar_telefono(p_telefono text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_norm text := normalizar_telefono(p_telefono);
  r jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if v_norm is null then
    return '[]'::jsonb;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'contacto_id', c.id,
      'nombre', c.nombre,
      'puesto', c.puesto,
      'verificado', c.verificado,
      'whatsapp', c.whatsapp,
      'cliente_id', c.cliente_id,
      'cliente', cl.nombre,
      'de_toda_la_empresa', c.de_toda_la_empresa,
      'equipos', (
        select coalesce(jsonb_agg(jsonb_build_object(
            'equipo_id', x.equipo_id,
            'descripcion', nullif(trim(concat_ws(' ', eq.tipo, eq.marca, eq.modelo,
                              case when eq.capacidad_kw is not null then eq.capacidad_kw || ' kW' end)), ''),
            'numero_serie', eq.numero_serie,
            'rol', x.rol,
            'origen', x.origen,
            'puede_pedir_citas', x.puede_pedir_citas,
            'recibe_ordenes', x.recibe_ordenes,
            'recibe_cotizaciones', x.recibe_cotizaciones,
            'en_poliza', eq.en_poliza,
            'ultima_orden', (
              select jsonb_build_object('folio', o.folio, 'fecha', o.fecha, 'estado', o.estado)
                from ordenes_servicio o
               where o.equipo_id = x.equipo_id
               order by o.fecha desc nulls last, o.folio desc limit 1)
          ) order by eq.numero_serie), '[]'::jsonb)
        from contactos_por_equipo x
        join equipos eq on eq.id = x.equipo_id
        where x.contacto_id = c.id)
    ) order by cl.nombre), '[]'::jsonb)
    into r
  from contactos c
  join clientes cl on cl.id = c.cliente_id
  where c.activo and c.telefono_norm = v_norm;

  return r;
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'vincular_contacto(uuid, uuid, text, boolean, boolean, boolean)',
    'identificar_telefono(text)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Migración: la persona y los teléfonos que ya están en la ficha de cada cliente
--    pasan a ser contactos de toda la empresa (con permisos completos). Se marcan
--    verificados porque los capturó el administrador en la ficha. Repetible.
-- ---------------------------------------------------------------------------
insert into contactos
  (cliente_id, nombre, telefono, email, verificado, de_toda_la_empresa,
   puede_pedir_citas, recibe_ordenes, recibe_cotizaciones, notas)
select cl.id,
       coalesce(nullif(trim(cl.contacto_nombre), ''), 'Contacto principal'),
       cl.telefono, nullif(trim(cl.email), ''), true, true, true, true, true,
       'Migrado de la ficha del cliente'
  from clientes cl
 where normalizar_telefono(cl.telefono) is not null
   and not exists (select 1 from contactos c
                    where c.cliente_id = cl.id and c.activo
                      and c.telefono_norm = normalizar_telefono(cl.telefono));

insert into contactos
  (cliente_id, nombre, telefono, verificado, de_toda_la_empresa,
   puede_pedir_citas, recibe_ordenes, recibe_cotizaciones, notas)
select cl.id,
       coalesce(nullif(trim(cl.contacto_nombre), ''), 'Contacto principal'),
       cl.telefono_alterno, true, true, true, true, true,
       'Migrado del teléfono alterno de la ficha'
  from clientes cl
 where normalizar_telefono(cl.telefono_alterno) is not null
   and not exists (select 1 from contactos c
                    where c.cliente_id = cl.id and c.activo
                      and c.telefono_norm = normalizar_telefono(cl.telefono_alterno));

notify pgrst, 'reload schema';

-- Verificación: cuántos contactos migró y que las tablas tengan RLS.
select 'contactos migrados' as que, count(*)::text as valor from contactos
union all
select 'clientes con teléfono válido', count(*)::text from clientes where normalizar_telefono(telefono) is not null
union all
select 'rls ' || relname, relrowsecurity::text from pg_class where relname in ('contactos', 'equipo_contactos');
