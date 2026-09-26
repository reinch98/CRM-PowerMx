-- ===========================================================================
-- PAQUETES DE MANTENIMIENTO PREVENTIVO
--
-- Cómo lo quiere Caña (25/09/2026):
--   · El precio de **mantenimiento menor y mayor es FIJO**, tabulado por **clase y
--     capacidad**. No es una fórmula como el diagnóstico.
--   · El cliente ve **un solo precio**: las refacciones van incluidas. Pero por dentro
--     **sí apartan inventario**, para que el almacén sepa qué surtir.
--   · Lo que cambia de un equipo a otro no es el precio sino **qué código de producto se
--     usa**: hay material genérico que sirve igual que el original.
--   · Más adelante, el paquete se irá aprendiendo de lo que de verdad se usó en visitas
--     anteriores (`orden_surtido.cantidad_usada`, que ya queda estructurado desde la 18).
--
-- **Esto no toca `cambiar_estado_cotizacion` ni el almacén.** Comprobado leyendo la 14: el
-- apartado y la lista de surtido solo miran `producto_id` y `cantidad` — **el precio nunca
-- entra**. Así que una partida de refacción con `precio: 0` aparta inventario y llega al
-- almacén igual que cualquier otra, sin cambiar una línea de esas funciones. La pantalla la
-- marca como incluida para no cobrarla dos veces.
--
-- Se puede repetir sin problema. Prueba: 28_prueba_paquetes_preventivo.sql.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. El precio: dos conceptos nuevos de catálogo.
--
-- La 21 ya dejó `preventivo` con SKU propio, clase y tramo de kW opcionales. Faltaba
-- distinguir menor de mayor, que son dos servicios con precios distintos.
-- La restricción se busca por su DEFINICIÓN, no por su nombre: Postgres se lo puso solo.
-- ---------------------------------------------------------------------------
do $$
declare v_nombre text;
begin
  select conname into v_nombre
    from pg_constraint
   where conrelid = 'tarifas_servicio'::regclass
     and contype = 'c'
     and pg_get_constraintdef(oid) ilike '%concepto%'
   limit 1;
  if v_nombre is not null then
    execute format('alter table tarifas_servicio drop constraint %I', v_nombre);
  end if;
end $$;

alter table tarifas_servicio add constraint tarifas_servicio_concepto_ok
  check (concepto in ('diagnostico', 'traslado', 'correctivo', 'preventivo',
                      'preventivo_menor', 'preventivo_mayor',
                      'instalacion_gas', 'instalacion_electrica', 'otro'));

-- ---------------------------------------------------------------------------
-- 2. Material genérico: productos que se pueden usar uno por otro.
--
-- Una columna y no una tabla aparte: es una etiqueta ("FILTRO-ACEITE-P554407") que el
-- admin escribe igual en los dos productos, y con eso ya son intercambiables. Más
-- sencillo de capturar y de entender que un catálogo de equivalencias.
-- ---------------------------------------------------------------------------
alter table productos add column if not exists grupo_equivalente text;
create index if not exists idx_productos_grupo_equivalente
  on productos(grupo_equivalente) where grupo_equivalente is not null;

-- ---------------------------------------------------------------------------
-- 3. El paquete: qué lleva un preventivo de este equipo.
--
-- Un paquete apunta a una clase y un tramo de kW (lo general), o a una marca y modelo
-- concretos (lo específico). Al buscar, **gana el específico**: si hay paquete para el
-- modelo exacto, ese se usa; si no, el de su clase y tramo.
-- ---------------------------------------------------------------------------
create table if not exists paquetes_mantenimiento (
  id uuid primary key default gen_random_uuid(),
  tipo text not null check (tipo in ('menor', 'mayor')),
  clase text,                          -- gasolina | gas_lp | diesel | solar | bateria
  kw_desde numeric,
  kw_hasta numeric,
  marca text,                          -- si se llenan marca y modelo, gana sobre lo general
  modelo text,
  nombre text,
  activo boolean not null default true,
  notas text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists paquete_lineas (
  id uuid primary key default gen_random_uuid(),
  paquete_id uuid not null references paquetes_mantenimiento(id) on delete cascade,
  descripcion text not null,           -- "Filtro de aceite": lo que hace falta, no el código
  producto_id uuid references productos(id),   -- el código de cabecera, si hay uno preferido
  grupo text,                          -- o el grupo equivalente, para dejarlo abierto
  cantidad numeric not null default 1 check (cantidad > 0),
  orden int not null default 0,
  constraint paquete_linea_apunta_a_algo check (producto_id is not null or grupo is not null)
);
create index if not exists idx_paquete_lineas on paquete_lineas(paquete_id, orden);

drop trigger if exists tocar_updated_at on paquetes_mantenimiento;
create trigger tocar_updated_at before update on paquetes_mantenimiento
  for each row execute function tocar_updated_at();

-- Solo admin: aquí se decide qué se le pone a un equipo y eso es comercial.
alter table paquetes_mantenimiento enable row level security;
alter table paquete_lineas enable row level security;
revoke all on paquetes_mantenimiento, paquete_lineas from anon;

drop policy if exists "admin_paquetes" on paquetes_mantenimiento;
create policy "admin_paquetes" on paquetes_mantenimiento for all to authenticated
  using (es_admin()) with check (es_admin());

drop policy if exists "admin_paquete_lineas" on paquete_lineas;
create policy "admin_paquete_lineas" on paquete_lineas for all to authenticated
  using (es_admin()) with check (es_admin());

-- ---------------------------------------------------------------------------
-- 4. Clase y capacidad de un equipo, como las calcula el navegador (`tarifas.js`).
--
-- Se repiten aquí porque el precio del preventivo lo tiene que poder calcular la BASE: el
-- agente de WhatsApp no puede depender de una función que vive en el navegador del admin.
-- El gas natural entra con el gas LP, igual que en el diagnóstico.
-- ---------------------------------------------------------------------------
create or replace function _clase_de_equipo(e equipos) returns text
language sql immutable set search_path = public as $$
  select case
    when e.tipo = 'solar' then 'solar'
    when e.tipo = 'bateria' then 'bateria'
    when e.tipo = 'generador' then case e.atributos ->> 'combustible'
      when 'gasolina' then 'gasolina'
      when 'gas_lp' then 'gas_lp'
      when 'gas_natural' then 'gas_lp'
      when 'diesel' then 'diesel'
      else null end
    else null end
$$;

create or replace function _capacidad_de_equipo(e equipos) returns numeric
language sql immutable set search_path = public as $$
  select coalesce(
    nullif(e.capacidad_kw, 0),
    case when e.tipo = 'solar'
         then nullif((e.atributos ->> 'potencia_inversor_kw')::numeric, 0) end,
    case when e.tipo = 'bateria'
         then nullif((e.atributos ->> 'capacidad_kwh')::numeric, 0) end)
$$;

-- ---------------------------------------------------------------------------
-- 5. Lo que hace falta para cotizar un preventivo de ese equipo.
--
-- Devuelve el precio (fijo, de la tabla) y las líneas del paquete, cada una con **todos los
-- códigos que sirven** y cuánto hay disponible de cada uno. Quien cotice elige; si el
-- original está agotado y el genérico no, se ve de inmediato.
-- ---------------------------------------------------------------------------
create or replace function paquete_preventivo(p_equipo uuid, p_tipo text default 'menor')
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  e equipos%rowtype;
  v_clase text;
  v_cap numeric;
  v_tarifa record;
  v_paquete paquetes_mantenimiento%rowtype;
  v_lineas jsonb;
begin
  if not es_admin() and not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector de WhatsApp.' using errcode = '42501';
  end if;
  if p_tipo not in ('menor', 'mayor') then
    raise exception 'El mantenimiento es menor o mayor: %', p_tipo using errcode = '22023';
  end if;

  select * into e from equipos where id = p_equipo;
  if not found then raise exception 'Ese equipo no existe.' using errcode = 'P0002'; end if;

  v_clase := _clase_de_equipo(e);
  v_cap := _capacidad_de_equipo(e);

  -- Precio fijo por clase y tramo. Si dos tramos empalman gana el más específico,
  -- igual que en el diagnóstico: el que empieza más arriba.
  select t.sku, t.nombre, t.precio into v_tarifa
    from tarifas_servicio t
   where t.activo
     and t.concepto = 'preventivo_' || p_tipo
     and (t.clase is null or t.clase = v_clase)
     and (t.kw_desde is null or (v_cap is not null and v_cap >= t.kw_desde))
     and (t.kw_hasta is null or (v_cap is not null and v_cap <= t.kw_hasta))
   order by (t.clase is not null) desc, t.kw_desde desc nulls last
   limit 1;

  -- El paquete: primero el del modelo exacto, si existe.
  select * into v_paquete
    from paquetes_mantenimiento p
   where p.activo and p.tipo = p_tipo
     and (p.marca is null or lower(p.marca) = lower(coalesce(e.marca, '')))
     and (p.modelo is null or lower(p.modelo) = lower(coalesce(e.modelo, '')))
     and (p.clase is null or p.clase = v_clase)
     and (p.kw_desde is null or (v_cap is not null and v_cap >= p.kw_desde))
     and (p.kw_hasta is null or (v_cap is not null and v_cap <= p.kw_hasta))
   order by (p.modelo is not null) desc, (p.marca is not null) desc,
            (p.clase is not null) desc, p.kw_desde desc nulls last
   limit 1;

  if v_paquete.id is not null then
    select coalesce(jsonb_agg(x order by x ->> 'orden'), '[]'::jsonb) into v_lineas
    from (
      select jsonb_build_object(
        'linea_id', l.id,
        'descripcion', l.descripcion,
        'cantidad', l.cantidad,
        'orden', lpad(l.orden::text, 4, '0'),
        'opciones', (
          -- El producto de cabecera y todo lo que comparta su grupo equivalente.
          select coalesce(jsonb_agg(jsonb_build_object(
                   'producto_id', pr.id, 'sku', pr.sku, 'nombre', pr.nombre,
                   'unidad', pr.unidad, 'precio', pr.precio,
                   'disponible', coalesce(d.disponible, 0),
                   'preferido', pr.id = l.producto_id)
                 order by (pr.id = l.producto_id) desc, coalesce(d.disponible, 0) desc), '[]'::jsonb)
            from productos pr
            left join disponibles d on d.id = pr.id
           where pr.id = l.producto_id
              or (l.grupo is not null and pr.grupo_equivalente = l.grupo)
              or (l.producto_id is not null and pr.grupo_equivalente is not null
                  and pr.grupo_equivalente = (select grupo_equivalente from productos where id = l.producto_id))
        )) as x
      from paquete_lineas l
      where l.paquete_id = v_paquete.id
    ) z;
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'ok', true,
    'equipo_id', e.id,
    'clase', v_clase,
    'capacidad', v_cap,
    'tipo', p_tipo,
    'servicio', case when v_tarifa.sku is not null then jsonb_build_object(
        'sku', v_tarifa.sku, 'nombre', v_tarifa.nombre, 'precio', v_tarifa.precio) end,
    'paquete', case when v_paquete.id is not null then jsonb_build_object(
        'paquete_id', v_paquete.id, 'nombre', v_paquete.nombre) end,
    'lineas', coalesce(v_lineas, '[]'::jsonb),
    -- Por qué NO se puede cotizar solo, en palabras: el que cotiza lo lee tal cual.
    'falta', case
      when v_clase is null then 'No se sabe de qué clase es el equipo: captura el combustible.'
      when v_cap is null then 'El equipo no tiene capacidad capturada.'
      when v_tarifa.sku is null then 'No hay tarifa de mantenimiento ' || p_tipo ||
                                    ' para esa clase y capacidad: captúrala en Tarifas.'
      when v_paquete.id is null then 'No hay paquete de refacciones para ese equipo todavía.'
      end));
end $$;
revoke all on function paquete_preventivo(uuid, text) from public, anon;
grant execute on function paquete_preventivo(uuid, text) to authenticated;

notify pgrst, 'reload schema';
