-- ===========================================================================
-- TARIFAS DE SERVICIO CON SU PROPIO SKU
--
-- Hasta ahora `tarifas_servicio` solo tenía dos conceptos con fórmula propia
-- (diagnóstico por clase/kW, traslado por km), cargados con el botón "Cargar
-- diagnóstico y traslado". Ahora se agregan conceptos de CATÁLOGO —correctivo,
-- preventivo, instalación de gas, instalación eléctrica, u "otro"— que el admin
-- da de alta con su propio SKU y que se buscan y agregan a una cotización
-- **igual que un producto**, por SKU o nombre.
--
-- Siguen siendo partidas LIBRES (`producto_id` null), igual que el diagnóstico y
-- el traslado: no mueven inventario ni generan requisiciones. No hace falta tocar
-- `cambiar_estado_cotizacion` ni ninguna otra función: esa función ya solo actúa
-- sobre partidas CON producto_id.
--
--   diagnostico, traslado   → sin cambio: fórmula propia, sin sku, se cargan solos.
--   correctivo, preventivo,
--   instalacion_gas,
--   instalacion_electrica,
--   otro                    → de catálogo: EXIGEN sku (único). `clase` y el tramo de
--                              kW siguen siendo opcionales (una instalación puede no
--                              depender de la clase del equipo). `otro` exige `nombre`
--                              propio, porque no hay una etiqueta por defecto para él.
--
-- Se puede repetir sin problema. Prueba: 21_prueba_tarifas_catalogo.sql.
-- ===========================================================================

-- La restricción original del concepto no tenía nombre explícito: se busca por su
-- definición en vez de adivinar cómo la nombró Postgres, y se sustituye por una más
-- amplia con un nombre fijo (para poder repetir el script sin duplicar restricciones).
do $$
declare r record;
begin
  for r in
    select con.conname
      from pg_constraint con
      join pg_class rel on rel.oid = con.conrelid
     where rel.relname = 'tarifas_servicio' and con.contype = 'c'
       and pg_get_constraintdef(con.oid) ilike '%concepto%'
  loop
    execute format('alter table tarifas_servicio drop constraint %I', r.conname);
  end loop;
end $$;

alter table tarifas_servicio add constraint tarifas_servicio_concepto_check
  check (concepto in (
    'diagnostico', 'traslado',
    'correctivo', 'preventivo', 'instalacion_gas', 'instalacion_electrica', 'otro'
  ));

alter table tarifas_servicio add column if not exists sku text;
alter table tarifas_servicio add column if not exists nombre text;

create unique index if not exists un_tarifas_servicio_sku
  on tarifas_servicio(sku) where sku is not null;

alter table tarifas_servicio drop constraint if exists tarifas_servicio_sku_si_catalogo;
alter table tarifas_servicio add constraint tarifas_servicio_sku_si_catalogo
  check (concepto in ('diagnostico', 'traslado') or nullif(trim(coalesce(sku, '')), '') is not null);

alter table tarifas_servicio drop constraint if exists tarifas_servicio_nombre_si_otro;
alter table tarifas_servicio add constraint tarifas_servicio_nombre_si_otro
  check (concepto <> 'otro' or nullif(trim(coalesce(nombre, '')), '') is not null);

notify pgrst, 'reload schema';

-- Verificación: la regla nueva y las columnas.
select conname as que, pg_get_constraintdef(oid) as regla
  from pg_constraint where conrelid = 'public.tarifas_servicio'::regclass and contype = 'c'
union all
select 'columna sku', exists (select 1 from information_schema.columns
  where table_name = 'tarifas_servicio' and column_name = 'sku')::text
union all
select 'columna nombre', exists (select 1 from information_schema.columns
  where table_name = 'tarifas_servicio' and column_name = 'nombre')::text;
