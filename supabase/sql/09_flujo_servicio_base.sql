-- ===========================================================================
-- FLUJO DE SERVICIO · FASE 1a · SOLO BASE DE DATOS (nada cambia a la vista)
--
-- Prepara el terreno para: cotización aceptada → cita + orden; técnico responsable
-- (T1) y ayudante (T2); órdenes que nacen antes de que el técnico las toque y se
-- llenan "por partes"; y tarifas de diagnóstico y traslado.
-- Plan completo: CLAUDE.md, sección "Flujo de servicio".
--
-- Todo es aditivo: columnas nuevas que aceptan vacío, tablas nuevas y políticas
-- nuevas. Lo que ya funciona (Agenda, Órdenes, Cotizaciones) no debe notar nada.
-- Se puede volver a ejecutar sin problema.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Ayuda: mantener updated_at al día. Las tablas lo tenían pero nada lo movía; lo
-- vamos a necesitar para detectar cambios al sincronizar sin señal.
-- ---------------------------------------------------------------------------
create or replace function tocar_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists tocar_updated_at on ordenes_servicio;
create trigger tocar_updated_at before update on ordenes_servicio
  for each row execute function tocar_updated_at();

drop trigger if exists tocar_updated_at on cotizaciones;
create trigger tocar_updated_at before update on cotizaciones
  for each row execute function tocar_updated_at();

-- ---------------------------------------------------------------------------
-- CITAS: segundo técnico, duración, ligadura a cotización, y "por programar".
-- ---------------------------------------------------------------------------
alter table citas
  add column if not exists tecnico2_id uuid references perfiles(id),
  add column if not exists duracion_min integer,          -- vacío = sin definir (la pantalla propone 120)
  add column if not exists cotizacion_id uuid references cotizaciones(id),
  add column if not exists origen text;                   -- 'cotizacion' | 'agenda' | 'poliza'

-- Una cotización aceptada sin fecha genera una cita "por programar": sin fecha.
-- La fecha deja de ser obligatoria, pero solo en ese estado.
alter table citas alter column fecha drop not null;
alter table citas drop constraint if exists citas_fecha_segun_estado;
alter table citas add constraint citas_fecha_segun_estado
  check (fecha is not null or estado = 'por_programar');

create index if not exists idx_citas_tecnico2 on citas(tecnico2_id, fecha) where tecnico2_id is not null;
create index if not exists idx_citas_cotizacion on citas(cotizacion_id) where cotizacion_id is not null;
create index if not exists idx_citas_por_programar on citas(estado) where estado = 'por_programar';

-- T2 ve las citas en que participa (T1 ya las veía).
drop policy if exists "tecnico2_ve_sus_citas" on citas;
create policy "tecnico2_ve_sus_citas" on citas for select to authenticated
  using (mi_rol() = 'tecnico' and tecnico2_id = auth.uid());

-- ---------------------------------------------------------------------------
-- COTIZACIONES: programación propuesta. Se captura al cotizar y se vuelve cita
-- real al aceptar.
-- ---------------------------------------------------------------------------
alter table cotizaciones
  add column if not exists prog_fecha date,
  add column if not exists prog_hora time,
  add column if not exists prog_duracion_min integer,
  add column if not exists prog_tecnico_id uuid references perfiles(id),
  add column if not exists prog_tecnico2_id uuid references perfiles(id);

-- ---------------------------------------------------------------------------
-- ÓRDENES: segundo técnico, y una sola orden por cita (una orden por visita).
-- `cita_id` y `estado` ('abierta' de origen) ya existían.
--   estado: abierta → cerrada | cancelada
-- Las órdenes viejas quedaron 'cerrada'; no se tocan.
-- ---------------------------------------------------------------------------
alter table ordenes_servicio
  add column if not exists tecnico2_id uuid references perfiles(id);

create unique index if not exists ux_ordenes_una_por_cita
  on ordenes_servicio(cita_id) where cita_id is not null;
create index if not exists idx_ordenes_tecnico2
  on ordenes_servicio(tecnico2_id, estado) where tecnico2_id is not null;

drop policy if exists "tecnico2_ve_sus_ordenes" on ordenes_servicio;
create policy "tecnico2_ve_sus_ordenes" on ordenes_servicio for select to authenticated
  using (mi_rol() = 'tecnico' and tecnico2_id = auth.uid());

-- ---------------------------------------------------------------------------
-- ¿Soy T1 o T2 de esta orden? ¿Sigue abierta? Con security definer para que las
-- políticas de orden_partes puedan preguntarlo sin toparse con las de la orden.
-- ---------------------------------------------------------------------------
create or replace function soy_de_la_orden(p_orden uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select mi_rol() = 'tecnico' and exists (
    select 1 from ordenes_servicio o
    where o.id = p_orden and auth.uid() in (o.tecnico_id, o.tecnico2_id)
  )
$$;

create or replace function orden_abierta(p_orden uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from ordenes_servicio o where o.id = p_orden and o.estado = 'abierta')
$$;

-- ---------------------------------------------------------------------------
-- ORDEN_PARTES: cada técnico escribe SU parte (notas y fotos). Una fila por técnico
-- y orden, así que dos personas nunca editan lo mismo y no hay choque al sincronizar
-- sin señal. Al cerrar la orden (solo T1) se juntan.
-- ---------------------------------------------------------------------------
create table if not exists orden_partes (
  id uuid primary key default gen_random_uuid(),
  orden_id uuid not null references ordenes_servicio(id) on delete cascade,
  autor_id uuid not null references perfiles(id),
  notas text,
  fotos jsonb not null default '[]'::jsonb,       -- rutas en el bucket `ordenes`
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (orden_id, autor_id)                      -- también permite guardar con "upsert"
);

create index if not exists idx_orden_partes_orden on orden_partes(orden_id);

drop trigger if exists tocar_updated_at on orden_partes;
create trigger tocar_updated_at before update on orden_partes
  for each row execute function tocar_updated_at();

alter table orden_partes enable row level security;
revoke all on orden_partes from anon;

drop policy if exists "admin_orden_partes" on orden_partes;
create policy "admin_orden_partes" on orden_partes for all to authenticated
  using (es_admin()) with check (es_admin());

-- T1 y T2 leen las dos partes de su orden.
drop policy if exists "tecnicos_leen_partes_de_su_orden" on orden_partes;
create policy "tecnicos_leen_partes_de_su_orden" on orden_partes for select to authenticated
  using (soy_de_la_orden(orden_id));

-- Cada uno escribe solo la suya, y solo mientras la orden está abierta.
drop policy if exists "tecnico_crea_su_parte" on orden_partes;
create policy "tecnico_crea_su_parte" on orden_partes for insert to authenticated
  with check (autor_id = auth.uid() and soy_de_la_orden(orden_id) and orden_abierta(orden_id));

drop policy if exists "tecnico_actualiza_su_parte" on orden_partes;
create policy "tecnico_actualiza_su_parte" on orden_partes for update to authenticated
  using (autor_id = auth.uid() and soy_de_la_orden(orden_id) and orden_abierta(orden_id))
  with check (autor_id = auth.uid() and soy_de_la_orden(orden_id) and orden_abierta(orden_id));

-- ---------------------------------------------------------------------------
-- CLIENTES: distancia a la oficina, para el cargo de traslado. Se captura una vez.
-- Cuando haya clientes ubicados por zonas, esto se reemplaza por un esquema de zonas.
-- ---------------------------------------------------------------------------
alter table clientes add column if not exists distancia_km numeric;

-- ---------------------------------------------------------------------------
-- TARIFAS DE SERVICIO (solo admin; el técnico nunca ve precios)
--
--   diagnostico: precio por servicio, según la CLASE del equipo y su capacidad.
--                clase: gasolina | gas_lp | diesel. Rango de capacidad en kW,
--                extremos incluidos (kw_desde <= capacidad <= kw_hasta).
--   traslado:    precio por kilómetro. km_desde = kilómetros a partir de los cuales
--                aplica (40). Cómo se cuentan (solo los que pasan de 40, o todos,
--                ida o ida y vuelta) se decide en la pantalla de cotización.
--
-- Al cotizar, el precio se COPIA a la partida (igual que el catálogo): cambiar una
-- tarifa no altera cotizaciones viejas. Las partidas de servicio son "libres"
-- (sin producto), así que no mueven inventario ni generan requisiciones.
-- ---------------------------------------------------------------------------
create table if not exists tarifas_servicio (
  id uuid primary key default gen_random_uuid(),
  concepto text not null check (concepto in ('diagnostico', 'traslado')),
  clase text,
  kw_desde numeric,
  kw_hasta numeric,
  km_desde numeric,
  precio numeric not null check (precio >= 0),
  activo boolean not null default true,
  notas text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists tocar_updated_at on tarifas_servicio;
create trigger tocar_updated_at before update on tarifas_servicio
  for each row execute function tocar_updated_at();

alter table tarifas_servicio enable row level security;
revoke all on tarifas_servicio from anon;

drop policy if exists "admin_tarifas_servicio" on tarifas_servicio;
create policy "admin_tarifas_servicio" on tarifas_servicio for all to authenticated
  using (es_admin()) with check (es_admin());

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- VERIFICACIÓN (solo lee). Debe salir: las 5 columnas nuevas de citas, las 5 de
-- cotizaciones, tecnico2_id en órdenes, distancia_km en clientes, las 3 tablas
-- nuevas y las políticas nuevas. citas.fecha debe decir is_nullable = YES.
-- ---------------------------------------------------------------------------
select 'columna' as tipo, table_name || '.' || column_name || '  null=' || is_nullable as detalle
from information_schema.columns
where table_schema = 'public'
  and ((table_name = 'citas' and column_name in ('fecha', 'tecnico2_id', 'duracion_min', 'cotizacion_id', 'origen'))
    or (table_name = 'cotizaciones' and column_name like 'prog\_%')
    or (table_name = 'ordenes_servicio' and column_name = 'tecnico2_id')
    or (table_name = 'clientes' and column_name = 'distancia_km'))
union all
select 'tabla', table_name from information_schema.tables
where table_schema = 'public' and table_name in ('orden_partes', 'tarifas_servicio')
union all
select 'politica', tablename || ': ' || policyname from pg_policies
where schemaname = 'public'
  and policyname in ('tecnico2_ve_sus_citas', 'tecnico2_ve_sus_ordenes', 'admin_orden_partes',
                     'tecnicos_leen_partes_de_su_orden', 'tecnico_crea_su_parte',
                     'tecnico_actualiza_su_parte', 'admin_tarifas_servicio')
order by 1, 2;
