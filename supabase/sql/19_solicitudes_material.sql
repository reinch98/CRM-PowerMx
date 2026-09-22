-- ===========================================================================
-- SOLICITUDES DE MATERIAL DEL TÉCNICO
--
-- El técnico pide una pieza que necesita (típicamente "para la siguiente visita"),
-- sin ver costos ni precios: solo indica qué pieza y cuántas, con una nota. Es una
-- SOLICITUD, no una requisición: la requisición (`requisiciones`, solo admin, ligada a
-- una cotización) sigue siendo de compras. Esta tabla es de coordinación entre el técnico
-- y el almacén/admin; NO mueve inventario por sí sola (no hay apartado automático: eso
-- lo decide una persona, a mano, con las pantallas que ya existen).
--
--   · Se pide DESDE UNA ORDEN (el técnico debe ser T1 o T2 de ella: `soy_de_la_orden`).
--     El equipo y el cliente se completan solos desde la orden (trigger).
--   · La pieza puede ser del catálogo (`producto_id`) o, si no está, una descripción libre.
--     Se copian sku/nombre/unidad a la fila (igual que `orden_surtido`/`entrega_lineas`):
--     así el técnico lee su propia solicitud sin necesitar permiso sobre `productos`.
--   · El técnico ve las suyas y las de su compañero de la misma orden; puede cancelar
--     (pasar a "descartada") solo mientras siga "pendiente". Nunca marca "atendida".
--   · Almacén/admin (`_es_almacen()`, de 14_almacen_entregas.sql) leen todas las pendientes
--     con contexto (técnico, cliente, equipo, orden, existencia física) y las resuelven:
--     `atender_solicitud_material` (con una resolución escrita: p. ej. "Se apartó en el
--     almacén" o "Se generó REQ-12") o `descartar_solicitud_material` (con motivo).
--
-- Se puede volver a ejecutar sin problema. Prueba: 19_prueba_solicitudes_material.sql.
-- ===========================================================================

create table if not exists solicitudes_material (
  id uuid primary key default gen_random_uuid(),
  folio bigint generated always as identity unique,
  tecnico_id uuid not null references perfiles(id),
  orden_id uuid references ordenes_servicio(id) on delete set null,
  equipo_id uuid references equipos(id) on delete set null,
  cliente_id uuid references clientes(id) on delete set null,
  producto_id uuid references productos(id),
  sku text,               -- copiado de productos al crear: el técnico lo lee sin permiso sobre esa tabla
  nombre text,
  unidad text,
  descripcion_libre text, -- si la pieza no está en el catálogo
  cantidad numeric not null check (cantidad > 0),
  nota text,
  estado text not null default 'pendiente' check (estado in ('pendiente', 'atendida', 'descartada')),
  resolucion text,        -- cómo se resolvió o por qué se descartó
  atendida_por text,
  atendida_at timestamptz,
  created_at timestamptz not null default now(),
  check (producto_id is not null or nullif(trim(coalesce(descripcion_libre, '')), '') is not null)
);

create index if not exists idx_solicitudes_material_estado on solicitudes_material(estado) where estado = 'pendiente';
create index if not exists idx_solicitudes_material_tecnico on solicitudes_material(tecnico_id);
create index if not exists idx_solicitudes_material_orden on solicitudes_material(orden_id) where orden_id is not null;

-- ---------------------------------------------------------------------------
-- Completa equipo/cliente desde la orden, y sku/nombre/unidad desde el producto.
-- ---------------------------------------------------------------------------
create or replace function _completar_solicitud_material() returns trigger
language plpgsql security definer set search_path = public as $$
declare p productos%rowtype;
begin
  if new.orden_id is not null then
    select o.equipo_id, o.cliente_id into new.equipo_id, new.cliente_id
      from ordenes_servicio o where o.id = new.orden_id;
    if not found then
      raise exception 'La orden no existe.' using errcode = 'P0002';
    end if;
  elsif new.equipo_id is not null and new.cliente_id is null then
    select e.cliente_id into new.cliente_id from equipos e where e.id = new.equipo_id;
  end if;

  if new.producto_id is not null then
    select * into p from productos where id = new.producto_id and activo;
    if not found then
      raise exception 'La pieza no existe.' using errcode = 'P0002';
    end if;
    new.sku := p.sku;
    new.nombre := p.nombre;
    new.unidad := p.unidad;
    new.descripcion_libre := null;
  end if;
  return new;
end $$;
revoke all on function _completar_solicitud_material() from public, anon, authenticated;

drop trigger if exists completar_solicitud_material on solicitudes_material;
create trigger completar_solicitud_material before insert on solicitudes_material
  for each row execute function _completar_solicitud_material();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table solicitudes_material enable row level security;
revoke all on solicitudes_material from anon;

drop policy if exists "admin_solicitudes_material" on solicitudes_material;
create policy "admin_solicitudes_material" on solicitudes_material for all to authenticated
  using (es_admin()) with check (es_admin());

drop policy if exists "almacen_lee_solicitudes_material" on solicitudes_material;
create policy "almacen_lee_solicitudes_material" on solicitudes_material for select to authenticated
  using (coalesce(mi_rol() = 'almacenista', false));

-- El técnico crea la suya, ligada a una orden de la que es T1 o T2 (o sin orden).
drop policy if exists "tecnico_crea_solicitud_material" on solicitudes_material;
create policy "tecnico_crea_solicitud_material" on solicitudes_material for insert to authenticated
  with check (
    mi_rol() = 'tecnico' and tecnico_id = auth.uid()
    and (orden_id is null or soy_de_la_orden(orden_id))
  );

-- Lee las suyas y las de su compañero en la misma orden.
drop policy if exists "tecnico_lee_solicitudes_material" on solicitudes_material;
create policy "tecnico_lee_solicitudes_material" on solicitudes_material for select to authenticated
  using (
    mi_rol() = 'tecnico'
    and (tecnico_id = auth.uid() or (orden_id is not null and soy_de_la_orden(orden_id)))
  );

-- Solo puede tocar la suya, y solo mientras sigue pendiente; nunca la marca "atendida".
drop policy if exists "tecnico_cancela_su_solicitud_material" on solicitudes_material;
create policy "tecnico_cancela_su_solicitud_material" on solicitudes_material for update to authenticated
  using (mi_rol() = 'tecnico' and tecnico_id = auth.uid() and estado = 'pendiente')
  with check (
    mi_rol() = 'tecnico' and tecnico_id = auth.uid() and estado in ('pendiente', 'descartada')
    and (orden_id is null or soy_de_la_orden(orden_id))
  );

-- ---------------------------------------------------------------------------
-- Funciones para almacén/admin
-- ---------------------------------------------------------------------------

-- Lista de pendientes con contexto (nunca precios: esta tabla no los tiene).
create or replace function solicitudes_material_pendientes() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if not _es_almacen() then
    raise exception 'Solo el almacén o el administrador.' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', s.id, 'folio', s.folio, 'creada_el', s.created_at,
      'tecnico', coalesce(p.nombre, p.email),
      'cliente', cl.nombre,
      'equipo', nullif(trim(concat_ws(' ', eq.tipo, eq.marca, eq.modelo,
                 case when eq.capacidad_kw is not null then eq.capacidad_kw || ' kW' end)), ''),
      'numero_serie', eq.numero_serie,
      'orden_folio', o.folio,
      'sku', s.sku, 'nombre', coalesce(s.nombre, s.descripcion_libre), 'unidad', s.unidad,
      'cantidad', s.cantidad, 'nota', s.nota,
      'fisico', (select ex.fisico from existencias ex where ex.id = s.producto_id)
    ) order by s.created_at), '[]'::jsonb)
    into r
  from solicitudes_material s
  join perfiles p on p.id = s.tecnico_id
  left join clientes cl on cl.id = s.cliente_id
  left join equipos eq on eq.id = s.equipo_id
  left join ordenes_servicio o on o.id = s.orden_id
  where s.estado = 'pendiente';

  return r;
end $$;

create or replace function atender_solicitud_material(p_id uuid, p_resolucion text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s solicitudes_material%rowtype;
begin
  if not _es_almacen() then
    raise exception 'Solo el almacén o el administrador.' using errcode = '42501';
  end if;
  if nullif(trim(coalesce(p_resolucion, '')), '') is null then
    raise exception 'Escribe cómo se resolvió.' using errcode = '22023';
  end if;
  select * into s from solicitudes_material where id = p_id for update;
  if not found then raise exception 'La solicitud no existe.' using errcode = 'P0002'; end if;
  if s.estado <> 'pendiente' then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'estado', s.estado);
  end if;

  update solicitudes_material
     set estado = 'atendida', resolucion = trim(p_resolucion),
         atendida_por = coalesce(auth.jwt() ->> 'email', 'crm'), atendida_at = now()
   where id = p_id;
  return jsonb_build_object('ok', true, 'folio', s.folio);
end $$;

create or replace function descartar_solicitud_material(p_id uuid, p_motivo text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s solicitudes_material%rowtype;
begin
  if not _es_almacen() then
    raise exception 'Solo el almacén o el administrador.' using errcode = '42501';
  end if;
  if nullif(trim(coalesce(p_motivo, '')), '') is null then
    raise exception 'Escribe el motivo.' using errcode = '22023';
  end if;
  select * into s from solicitudes_material where id = p_id for update;
  if not found then raise exception 'La solicitud no existe.' using errcode = 'P0002'; end if;
  if s.estado <> 'pendiente' then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'estado', s.estado);
  end if;

  update solicitudes_material
     set estado = 'descartada', resolucion = trim(p_motivo),
         atendida_por = coalesce(auth.jwt() ->> 'email', 'crm'), atendida_at = now()
   where id = p_id;
  return jsonb_build_object('ok', true, 'folio', s.folio);
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'solicitudes_material_pendientes()', 'atender_solicitud_material(uuid, text)',
    'descartar_solicitud_material(uuid, text)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

notify pgrst, 'reload schema';

-- Verificación: RLS puesto y la tabla con las columnas nuevas.
select 'rls solicitudes_material' as que, relrowsecurity::text as ok
from pg_class where relname = 'solicitudes_material'
union all
select 'trigger completar_solicitud_material',
       exists (select 1 from pg_trigger where tgname = 'completar_solicitud_material' and not tgisinternal)::text;
