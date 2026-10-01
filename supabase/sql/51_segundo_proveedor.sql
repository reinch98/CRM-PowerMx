-- ---------------------------------------------------------------------------
-- 51_segundo_proveedor.sql — Solarama como segundo proveedor, varios proveedores por producto,
-- margen sobre el precio de venta y parámetros de costeo. Pedido de Caña el 01/10/2026.
--
-- Decisiones de Caña:
--   · Solarama entra como proveedor, con sus productos en el catálogo (sin imágenes por ahora).
--   · Los artículos REPETIDOS (los vende XLStore y Solarama) se conservan como UN producto con DOS
--     proveedores:
--        costo  = el del proveedor MÁS BARATO, que queda como "opción 1" (a quién se le compra);
--        precio = el que daría el proveedor MÁS CARO (lo que se publica).
--   · El margen de los productos es del 30 % SOBRE EL PRECIO DE VENTA (igual que los paquetes en
--     Costos-Base): precio = costo / 0.70, o sea 42.9 % sobre el costo. Antes era 35 % sobre el costo.
--   · La mano de obra que se estimó en el borrador de paquetes queda como valor inicial, editable.
--   · Pendiente anotado: promociones en paquetes para reducir ese margen.
--
-- Qué cambia:
--   1. `reglas_margen.sobre` ('costo' | 'precio') y `_precio_venta` sabe calcular las dos. La regla
--      general pasa a 30 % sobre el precio SOLO si seguía en el 35 % sobre el costo del botón inicial
--      (correr este archivo otra vez no pisa una regla que Caña ya haya editado).
--   2. Tabla `producto_proveedores`: un producto puede tener un código en cada proveedor.
--      `productos.proveedor` / `proveedor_sku` se quedan como ESPEJO de la opción 1, para que lo que
--      ya los leía siga funcionando. Se migran los vínculos que ya había.
--   3. `_calcular_precio` mira a todos los proveedores ligados; `sync_aplicar` recorre los productos
--      ligados al proveedor de la corrida; un producto que un proveedor deja de listar NO se manda a
--      "ya no lo lista" si el otro proveedor todavía lo tiene.
--   4. `importar_productos_proveedor` crea el SKU del CRM: el de XLStore se queda igual (así nació
--      la 45); los de Solarama llevan prefijo SLR- y van sin espacios ni símbolos, porque el SKU
--      nombra la imagen y la ficha en el sitio. Un disparador mantiene `producto_proveedores` al día
--      aunque alguien escriba el proveedor directo en `productos`.
--   5. `parametros_costeo`: mano de obra por panel y fija, trámite, respaldo, imprevistos y metros
--      incluidos. Solo admin. Los usará el armado de paquetes; hoy se ven y se editan en Precios.
--   6. Los 27 artículos repetidos quedan ligados a Solarama (lista revisada a mano el 01/10/2026,
--      por modelo exacto; los dudosos —variantes Tr/MC4 de Victron, Mega fuse en paquete de 5,
--      medidores de otra corriente— se quedaron fuera a propósito).
--
-- Orden para ponerlo en marcha: este archivo → su prueba → leer el PDF de Solarama con el sync
-- (`--proveedor solarama --adaptador solarama`) → Proveedor → "Traer productos" con Solarama.
--
-- Repetible. Solo plpgsql dentro de funciones; sin `select ... into` (ver CLAUDE.md).
-- ---------------------------------------------------------------------------

-- 1. Margen sobre el costo o sobre el precio de venta -------------------------------------------

alter table reglas_margen add column if not exists sobre text not null default 'costo';
alter table reglas_margen drop constraint if exists reglas_margen_sobre_valido;
alter table reglas_margen add constraint reglas_margen_sobre_valido
  check (sobre in ('costo', 'precio'));
-- 100 % sobre el precio sería dividir entre cero.
alter table reglas_margen drop constraint if exists reglas_margen_precio_bajo_100;
alter table reglas_margen add constraint reglas_margen_precio_bajo_100
  check (sobre <> 'precio' or margen_pct < 100);

-- precio = el mayor entre (costo con su margen) y (costo + margen mínimo), redondeado SIEMPRE
-- hacia arriba. Con margen sobre el precio: costo / (1 - margen); sobre el costo: costo × (1 + margen).
create or replace function _precio_venta(p_costo_mxn numeric, p_regla reglas_margen)
returns numeric
language sql immutable as $$
  select ceil(greatest(
           case when p_regla.sobre = 'precio' then p_costo_mxn / (1 - p_regla.margen_pct / 100)
                else p_costo_mxn * (1 + p_regla.margen_pct / 100) end,
           p_costo_mxn + p_regla.margen_minimo_mxn) / p_regla.redondeo)
         * p_regla.redondeo
$$;

update reglas_margen
   set margen_pct = 30, sobre = 'precio'
 where activo and categoria is null and marca is null
   and margen_pct = 35 and sobre = 'costo';
insert into reglas_margen (categoria, marca, margen_pct, margen_minimo_mxn, redondeo, sobre)
select null, null, 30, 0, 1, 'precio'
 where not exists (select 1 from reglas_margen where activo and categoria is null and marca is null);

-- 2. Varios proveedores por producto ------------------------------------------------------------

create table if not exists producto_proveedores (
  producto_id uuid not null references productos (id) on delete cascade,
  proveedor text not null,
  proveedor_sku text not null,
  -- 1 = el más barato: con su costo se calcula y a él se le compra. Lo reordena cada sincronización.
  opcion int,
  costo_mxn numeric,          -- el último costo calculado de este proveedor, para mostrarlo
  creado_en timestamptz not null default now(),
  primary key (producto_id, proveedor),
  unique (proveedor, proveedor_sku)   -- un código del proveedor sigue a UN solo producto
);

alter table producto_proveedores enable row level security;
drop policy if exists admin_producto_proveedores on producto_proveedores;
create policy admin_producto_proveedores on producto_proveedores
  for all to authenticated using (es_admin()) with check (es_admin());
revoke all on producto_proveedores from anon;

-- Los vínculos que ya existían (todos de XLStore) pasan a la tabla nueva como opción 1.
insert into producto_proveedores (producto_id, proveedor, proveedor_sku, opcion)
select p.id, p.proveedor, p.proveedor_sku, 1
  from productos p
 where p.proveedor is not null and p.proveedor_sku is not null
on conflict do nothing;

-- Y de aquí en adelante: si alguien escribe el proveedor directo en `productos` (el Table Editor, un
-- script viejo), el vínculo aparece solo. Así la tabla es la única verdad sin cuidar dos lugares.
create or replace function _espejo_a_vinculos()
returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  if new.proveedor is not null and new.proveedor_sku is not null then
    insert into producto_proveedores (producto_id, proveedor, proveedor_sku)
    values (new.id, new.proveedor, new.proveedor_sku)
    on conflict do nothing;
  end if;
  return null;
end $fn$;
drop trigger if exists espejo_a_vinculos on productos;
create trigger espejo_a_vinculos after insert or update of proveedor, proveedor_sku on productos
  for each row execute function _espejo_a_vinculos();

-- 3. Parámetros de costeo (mano de obra, trámites, metros incluidos) ----------------------------

create table if not exists parametros_costeo (
  clave text primary key,
  etiqueta text not null,
  valor numeric not null check (valor >= 0),
  unidad text,
  nota text,
  orden int not null default 0,
  actualizado_en timestamptz not null default now(),
  actualizado_por text
);

alter table parametros_costeo enable row level security;
drop policy if exists admin_parametros_costeo on parametros_costeo;
create policy admin_parametros_costeo on parametros_costeo
  for select to authenticated using (es_admin());
revoke all on parametros_costeo from anon;

-- Valores del borrador de paquetes (30/09/2026). `on conflict do nothing`: correr esto otra vez NO
-- pisa lo que Caña ya corrigió.
insert into parametros_costeo (clave, etiqueta, valor, unidad, nota, orden) values
  ('mano_obra_panel', 'Mano de obra por panel', 800, 'MXN', 'Estimado del borrador; corrígelo con lo que te cuesta de verdad.', 1),
  ('mano_obra_fija', 'Mano de obra fija por instalación (conexión, arranque y monitoreo)', 2500, 'MXN', 'Estimado del borrador.', 2),
  ('tramite_cfe', 'Trámite ante CFE y diagrama unifilar', 1500, 'MXN', 'Estimado del borrador. No aplica a un sistema que no inyecta a la red.', 3),
  ('mano_obra_respaldo', 'Mano de obra del respaldo con batería', 2500, 'MXN', 'Estimado del borrador.', 4),
  ('imprevistos_pct', 'Imprevistos y merma, sobre el costo', 3, '%', null, 5),
  ('metros_panel_inversor', 'Metros incluidos de panel a inversor', 30, 'm', 'Por cadena. Fuera de esto se cotiza con visita.', 6),
  ('metros_inversor_conexion', 'Metros incluidos de inversor a la conexión', 10, 'm', null, 7)
on conflict (clave) do nothing;

create or replace function fijar_parametro_costeo(p_clave text, p_valor numeric)
returns text
language plpgsql security definer set search_path = public as $fn$
declare
  v_antes numeric;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if p_valor is null or p_valor < 0 then
    raise exception 'El valor debe ser un número de 0 en adelante.' using errcode = '22023';
  end if;
  v_antes := (select valor from parametros_costeo where clave = p_clave);
  if v_antes is null then
    raise exception 'No existe el parámetro %.', p_clave using errcode = '22023';
  end if;
  if v_antes = p_valor then
    return 'sin_cambio';
  end if;
  update parametros_costeo
     set valor = p_valor, actualizado_en = now(),
         actualizado_por = coalesce(auth.jwt() ->> 'email', 'crm')
   where clave = p_clave;
  perform _apunta('parametros_costeo', gen_random_uuid(), 'fijar_parametro',
                  jsonb_build_object('clave', p_clave, 'valor', v_antes),
                  jsonb_build_object('clave', p_clave, 'valor', p_valor), 'oficina');
  return 'ok';
end $fn$;

-- 4. SKU del CRM para un producto que llega de un proveedor -----------------------------------------

-- XLStore (y cualquier otro): su código tal cual, como lo dejó la 45 (así se llaman sus imágenes y
-- fichas). Solarama: sus códigos traen espacios y símbolos ("KIT1X4A10°", "MIN 3600TL-X2") y algunos
-- son solo números, así que llevan prefijo y van limpios: SLR-KIT1X4A10, SLR-MIN-3600TL-X2.
create or replace function _sku_crm(p_proveedor text, p_sku text)
returns text
language sql immutable as $$
  select case when lower(trim(p_proveedor)) = 'solarama' then
           'SLR-' || upper(regexp_replace(regexp_replace(
             translate(trim(p_sku), 'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNaeiouun'),
             '[^A-Za-z0-9.]+', '-', 'g'), '(^-+|-+$)', '', 'g'))
         else trim(p_sku) end
$$;

-- 5. Precio con varios proveedores -----------------------------------------------------------------

-- Qué precio le toca a un producto: costo = el proveedor más barato (opción 1), precio = el que daría
-- el más caro. Solo cuentan las lecturas VIGENTES con costo; si ningún proveedor lo lista ya, se usa
-- la última lectura que haya y se marca `vigente: false` (la cola no deja aprobar con eso).
create or replace function _calcular_precio(p_producto uuid, p_tc numeric)
returns jsonb
language plpgsql stable set search_path = public as $fn$
declare
  v_p productos;
  v_r reglas_margen;
  v_lista jsonb;
  v_cands jsonb;
  v_vigente boolean := true;
  v_bajo jsonb;
  v_alto jsonb;
begin
  v_p := (select p from productos p where p.id = p_producto);
  if v_p.id is null then
    return jsonb_build_object('ok', false, 'motivo', 'sin_producto');
  end if;

  v_lista := (
    select coalesce(jsonb_agg(jsonb_build_object(
             'proveedor', l.proveedor,
             'proveedor_sku', l.proveedor_sku,
             'leido', x.id is not null,
             'vigente', coalesce(x.vigente, false),
             'moneda', x.moneda,
             'costo', x.costo,
             'costo_mxn', case when x.costo is null or x.costo <= 0 then null
                               when x.moneda = 'USD' then case when p_tc > 0 then round(x.costo * p_tc, 2) end
                               else round(x.costo, 2) end)
           order by l.proveedor), '[]'::jsonb)
      from producto_proveedores l
      left join proveedor_productos x
        on x.proveedor = l.proveedor and x.sku_proveedor = l.proveedor_sku
     where l.producto_id = p_producto);

  if jsonb_array_length(v_lista) = 0 then
    return jsonb_build_object('ok', false, 'motivo', 'sin_lectura');
  end if;

  v_cands := (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(v_lista) e
               where (e ->> 'vigente')::boolean and e ->> 'costo_mxn' is not null);
  if jsonb_array_length(v_cands) = 0 then
    v_vigente := false;
    v_cands := (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(v_lista) e
                 where e ->> 'costo_mxn' is not null);
  end if;
  if jsonb_array_length(v_cands) = 0 then
    if exists (select 1 from jsonb_array_elements(v_lista) e
                where e ->> 'moneda' = 'USD' and (e ->> 'costo')::numeric > 0) then
      return jsonb_build_object('ok', false, 'motivo', 'sin_tipo_cambio');
    elsif exists (select 1 from jsonb_array_elements(v_lista) e where (e ->> 'leido')::boolean) then
      return jsonb_build_object('ok', false, 'motivo', 'sin_costo');
    end if;
    return jsonb_build_object('ok', false, 'motivo', 'sin_lectura');
  end if;

  -- Empate en costo: se queda la opción 1 que ya tenía (no se cambia de proveedor por nada).
  v_bajo := (select e from jsonb_array_elements(v_cands) e
              order by (e ->> 'costo_mxn')::numeric,
                       (e ->> 'proveedor') = coalesce(v_p.proveedor, '') desc, e ->> 'proveedor'
              limit 1);
  v_alto := (select e from jsonb_array_elements(v_cands) e
              order by (e ->> 'costo_mxn')::numeric desc, e ->> 'proveedor'
              limit 1);

  v_r := _regla_margen(v_p.categoria, v_p.marca);
  if v_r.id is null then
    return jsonb_build_object('ok', false, 'motivo', 'sin_regla');
  end if;
  return jsonb_build_object(
    'ok', true,
    'costo_mxn', (v_bajo ->> 'costo_mxn')::numeric,
    'costo_alto_mxn', (v_alto ->> 'costo_mxn')::numeric,
    'precio', _precio_venta((v_alto ->> 'costo_mxn')::numeric, v_r),
    'margen_pct', v_r.margen_pct, 'margen_minimo', v_r.margen_minimo_mxn, 'margen_sobre', v_r.sobre,
    'vigente', v_vigente,
    'proveedor', v_bajo ->> 'proveedor', 'proveedor_sku', v_bajo ->> 'proveedor_sku',
    'proveedor_precio', v_alto ->> 'proveedor',
    'proveedores', v_lista);
end $fn$;

-- Reordena las opciones (la 1 es la del cálculo) y deja el espejo en `productos`.
create or replace function _ordenar_proveedores(p_producto uuid, p_calc jsonb)
returns void
language plpgsql security definer set search_path = public as $fn$
begin
  if not coalesce((p_calc ->> 'ok')::boolean, false) then
    return;
  end if;
  update producto_proveedores l
     set opcion = r.n, costo_mxn = r.costo
    from (select e ->> 'proveedor' as proveedor,
                 nullif(e ->> 'costo_mxn', '')::numeric as costo,
                 row_number() over (
                   order by (e ->> 'proveedor') = (p_calc ->> 'proveedor') desc,
                            (e ->> 'vigente')::boolean desc,
                            nullif(e ->> 'costo_mxn', '')::numeric nulls last,
                            e ->> 'proveedor') as n
            from jsonb_array_elements(p_calc -> 'proveedores') e) r
   where l.producto_id = p_producto and l.proveedor = r.proveedor
     and (l.opcion is distinct from r.n or l.costo_mxn is distinct from r.costo);
  update productos
     set proveedor = p_calc ->> 'proveedor', proveedor_sku = p_calc ->> 'proveedor_sku'
   where id = p_producto
     and (proveedor is distinct from p_calc ->> 'proveedor'
          or proveedor_sku is distinct from p_calc ->> 'proveedor_sku');
end $fn$;

-- Igual que la 46 (publica el primer precio de un producto del proveedor), más el orden de opciones.
create or replace function _aplicar_precio(p_producto uuid, p_calc jsonb, p_origen text,
                                           p_corrida uuid, p_tc numeric)
returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_p productos;
  v_precio numeric := (p_calc ->> 'precio')::numeric;
  v_costo numeric := (p_calc ->> 'costo_mxn')::numeric;
  v_publica boolean;
begin
  if v_precio < v_costo + (p_calc ->> 'margen_minimo')::numeric then
    raise exception 'Precio % por debajo de costo % + margen mínimo: no se publica.',
      v_precio, v_costo using errcode = '23514';
  end if;
  v_p := (select p from productos p where p.id = p_producto);
  v_publica := (v_p.precio is null or v_p.precio <= 0)
               and not coalesce(v_p.publicar, false)
               and coalesce(v_p.atributos ->> 'origen', '') = 'proveedor';

  update productos
     set precio = v_precio, costo = v_costo, moneda = 'MXN',
         publicar = publicar or v_publica,
         precio_sync_en = now(), updated_at = now()
   where id = p_producto;
  perform _ordenar_proveedores(p_producto, p_calc);
  insert into historial_precios (producto_id, precio_anterior, precio_nuevo,
                                 costo_anterior, costo_nuevo, tipo_cambio, origen, corrida_id)
  values (p_producto, v_p.precio, v_precio, v_p.costo, v_costo, p_tc, p_origen, p_corrida);
  perform _apunta('productos', p_producto, 'precio_por_proveedor',
                  jsonb_build_object('precio', v_p.precio, 'costo', v_p.costo),
                  jsonb_build_object('precio', v_precio, 'costo', v_costo, 'origen', p_origen,
                                     'publicado', v_publica,
                                     'opcion_1', p_calc ->> 'proveedor',
                                     'precio_de', p_calc ->> 'proveedor_precio'),
                  'sync');
end $fn$;

create or replace function sync_aplicar(p_corrida uuid, p_tipo_cambio numeric,
                                        p_tc_fecha date default null, p_tc_fuente text default null,
                                        p_umbral_pct numeric default 15)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_c sync_corridas;
  v_p productos;
  v_sku text;
  v_pp proveedor_productos;
  v_otro boolean;
  v_calc jsonb;
  v_var numeric;
  v_aplicados int := 0;
  v_sin_cambio int := 0;
  v_revision int := 0;
  v_faltan int := 0;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector.' using errcode = '42501';
  end if;
  v_c := (select c from sync_corridas c where c.id = p_corrida);
  if v_c.id is null or v_c.estado <> 'leida' then
    raise exception 'La corrida no está lista: primero hay que cerrar una lectura buena.'
      using errcode = '22023';
  end if;
  if p_tipo_cambio is null or p_tipo_cambio < 5 or p_tipo_cambio > 100 then
    raise exception 'Tipo de cambio fuera de rango: %.', p_tipo_cambio using errcode = '22023';
  end if;

  insert into tipos_cambio (fecha, moneda, valor, fuente)
  values (coalesce(p_tc_fecha, current_date), 'USD', p_tipo_cambio, p_tc_fuente)
  on conflict (fecha, moneda) do update set valor = excluded.valor, fuente = excluded.fuente;

  update proveedor_productos
     set vigente = false
   where proveedor = v_c.proveedor and corrida_id is distinct from p_corrida;
  update cola_revision q
     set estado = 'rechazada', resuelto_por = 'sync', resuelto_en = now(),
         nota = 'Volvió a aparecer en la lectura.'
   where q.tipo = 'sku_desaparecido' and q.estado = 'pendiente'
     and exists (select 1 from producto_proveedores l
                   join proveedor_productos x
                     on x.proveedor = l.proveedor and x.sku_proveedor = l.proveedor_sku
                  where l.producto_id = q.producto_id and x.corrida_id = p_corrida);

  for v_p in
    select p.* from productos p
     where p.precio_auto and p.activo
       and exists (select 1 from producto_proveedores l
                    where l.producto_id = p.id and l.proveedor = v_c.proveedor)
     order by p.sku
  loop
    v_sku := (select l.proveedor_sku from producto_proveedores l
               where l.producto_id = v_p.id and l.proveedor = v_c.proveedor);
    v_pp := (select x from proveedor_productos x
              where x.proveedor = v_c.proveedor and x.sku_proveedor = v_sku);
    -- ¿Otro proveedor ligado todavía lo vende? Entonces que este lo deje de listar no lo retira.
    v_otro := exists (select 1 from producto_proveedores l
                        join proveedor_productos x
                          on x.proveedor = l.proveedor and x.sku_proveedor = l.proveedor_sku
                       where l.producto_id = v_p.id and l.proveedor <> v_c.proveedor
                         and x.vigente and x.costo > 0);

    if (v_pp.id is null or not v_pp.vigente) and not v_otro then
      perform _encolar('sku_desaparecido', v_p.id, v_sku,
                       jsonb_build_object('nombre', v_p.nombre, 'precio_actual', v_p.precio,
                                          'proveedor', v_c.proveedor), p_corrida);
      v_revision := v_revision + 1;
      continue;
    end if;

    v_calc := _calcular_precio(v_p.id, p_tipo_cambio);
    if not (v_calc ->> 'ok')::boolean then
      perform _encolar(case v_calc ->> 'motivo' when 'sin_regla' then 'sin_regla' else 'sin_costo' end,
                       v_p.id, v_sku,
                       jsonb_build_object('nombre', v_p.nombre, 'motivo', v_calc ->> 'motivo'), p_corrida);
      v_faltan := v_faltan + 1;
      continue;
    end if;

    update cola_revision
       set estado = 'rechazada', resuelto_por = 'sync', resuelto_en = now(),
           nota = 'Ya se resolvió: hay regla y costo.'
     where producto_id = v_p.id and tipo in ('sin_regla', 'sin_costo') and estado = 'pendiente';

    -- El orden de proveedores se actualiza aunque el precio no cambie: la opción 1 puede cambiar
    -- sin que cambie el precio publicado (el precio lo marca el más caro).
    perform _ordenar_proveedores(v_p.id, v_calc);

    if v_p.precio is null or v_p.precio <= 0 then
      perform _encolar('precio_inicial', v_p.id, v_sku,
                       v_calc || jsonb_build_object('nombre', v_p.nombre), p_corrida);
      v_revision := v_revision + 1;
      continue;
    end if;

    v_var := abs((v_calc ->> 'precio')::numeric - v_p.precio) / v_p.precio * 100;
    if v_var > p_umbral_pct then
      perform _encolar('cambio_precio', v_p.id, v_sku,
                       v_calc || jsonb_build_object('nombre', v_p.nombre,
                                                    'precio_actual', v_p.precio,
                                                    'variacion_pct', round(v_var, 1)), p_corrida);
      v_revision := v_revision + 1;
    elsif (v_calc ->> 'precio')::numeric <> v_p.precio
       or (v_calc ->> 'costo_mxn')::numeric is distinct from v_p.costo then
      perform _aplicar_precio(v_p.id, v_calc, 'sync', p_corrida, p_tipo_cambio);
      v_aplicados := v_aplicados + 1;
    else
      v_sin_cambio := v_sin_cambio + 1;
    end if;
  end loop;

  update sync_corridas
     set estado = 'aplicada', tipo_cambio = p_tipo_cambio, terminada_en = now(),
         resumen = jsonb_build_object('aplicados', v_aplicados, 'sin_cambio', v_sin_cambio,
                                      'en_revision', v_revision, 'sin_regla_o_costo', v_faltan)
   where id = p_corrida;

  return jsonb_build_object('aplicados', v_aplicados, 'sin_cambio', v_sin_cambio,
                            'en_revision', v_revision, 'sin_regla_o_costo', v_faltan);
end $fn$;

-- 6. Vincular: agrega o quita UN proveedor de un producto ---------------------------------------

-- `p_sku` vacío quita a ese proveedor. `p_precio_auto` fija el interruptor del producto (la pantalla
-- manda el que ya tenía al agregar un segundo proveedor, para no apagarlo). Sin proveedores, el
-- precio automático se apaga solo.
create or replace function vincular_producto_proveedor(p_producto uuid, p_proveedor text,
                                                       p_sku text, p_precio_auto boolean default false)
returns text
language plpgsql security definer set search_path = public as $fn$
declare
  v_prov text := lower(trim(p_proveedor));
  v_sku text := nullif(trim(p_sku), '');
  v_otro text;
  v_primero producto_proveedores;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if not exists (select 1 from productos where id = p_producto) then
    raise exception 'No existe ese producto.' using errcode = '22023';
  end if;

  if v_sku is null then
    delete from producto_proveedores where producto_id = p_producto and proveedor = v_prov;
  else
    if not exists (select 1 from proveedor_productos
                    where proveedor = v_prov and sku_proveedor = v_sku) then
      raise exception 'El proveedor no tiene ese código en la última lectura.' using errcode = '22023';
    end if;
    v_otro := (select p.sku from producto_proveedores l join productos p on p.id = l.producto_id
                where l.proveedor = v_prov and l.proveedor_sku = v_sku and l.producto_id <> p_producto);
    if v_otro is not null then
      raise exception 'Ese código del proveedor ya está ligado al producto %.', v_otro using errcode = '22023';
    end if;
    insert into producto_proveedores (producto_id, proveedor, proveedor_sku)
    values (p_producto, v_prov, v_sku)
    on conflict (producto_id, proveedor) do update
      set proveedor_sku = excluded.proveedor_sku, opcion = null, costo_mxn = null;
  end if;

  -- Espejo: la opción 1 si ya se calculó; si no, el primero que se ligó.
  v_primero := (select l from producto_proveedores l where l.producto_id = p_producto
                 order by l.opcion nulls last, l.creado_en, l.proveedor limit 1);
  update productos
     set proveedor = v_primero.proveedor,
         proveedor_sku = v_primero.proveedor_sku,
         precio_auto = case when v_primero.producto_id is null then false
                            when v_sku is null then precio_auto
                            else p_precio_auto end,
         updated_at = now()
   where id = p_producto;

  perform _apunta('productos', p_producto, 'vincular_proveedor', null,
                  jsonb_build_object('proveedor', v_prov, 'sku', v_sku, 'precio_auto', p_precio_auto),
                  'oficina');
  return 'ok';
end $fn$;

-- 7. Traer productos, resumen y precio automático, con la tabla de vínculos ------------------------

create or replace function proveedor_resumen(p_proveedor text)
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare
  v_prov text := lower(trim(p_proveedor));
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'por_traer', coalesce((
      select jsonb_agg(t.x order by t.x ->> 'categoria')
        from (
          select jsonb_build_object(
                   'categoria', pp.categoria,
                   'total', count(*),
                   'por_traer', count(*) filter (where not exists (
                       select 1 from producto_proveedores l
                        where l.proveedor = pp.proveedor and l.proveedor_sku = pp.sku_proveedor)
                     and not exists (
                       select 1 from productos p where p.sku = _sku_crm(pp.proveedor, pp.sku_proveedor))),
                   'equivale', _categoria_crm(pp.categoria) is not null) as x
            from proveedor_productos pp
           where pp.proveedor = v_prov and pp.vigente
           group by pp.categoria
        ) t), '[]'::jsonb),
    'vinculados', coalesce((
      select jsonb_agg(t.x order by t.x ->> 'categoria')
        from (
          select jsonb_build_object(
                   'categoria', p.categoria,
                   'total', count(*),
                   'con_auto', count(*) filter (where p.precio_auto)) as x
            from productos p
           where p.activo and exists (select 1 from producto_proveedores l
                                       where l.producto_id = p.id and l.proveedor = v_prov)
           group by p.categoria
        ) t), '[]'::jsonb));
end $fn$;

create or replace function importar_productos_proveedor(p_proveedor text, p_categorias text[] default null)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_prov text := lower(trim(p_proveedor));
  v_pp proveedor_productos;
  v_map text[];
  v_sku text;
  v_id uuid;
  v_creados int := 0;
  v_ya int := 0;
  v_sin int := 0;
  v_por jsonb := '{}'::jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;

  for v_pp in
    select * from proveedor_productos
     where proveedor = v_prov and vigente
       and (p_categorias is null or categoria = any(p_categorias))
     order by categoria, sku_proveedor
  loop
    v_map := _categoria_crm(v_pp.categoria);
    if v_map is null then
      v_sin := v_sin + 1;
      continue;
    end if;
    v_sku := _sku_crm(v_prov, v_pp.sku_proveedor);
    -- Ya ligado (un repetido de otro proveedor) o ya existe ese SKU: no se duplica.
    if exists (select 1 from producto_proveedores l
                where l.proveedor = v_prov and l.proveedor_sku = v_pp.sku_proveedor)
       or exists (select 1 from productos p where p.sku = v_sku) then
      v_ya := v_ya + 1;
      continue;
    end if;

    v_id := gen_random_uuid();
    insert into productos (id, sku, categoria, nombre, marca, modelo, descripcion, moneda, unidad,
                           minimo, publicar, activo, proveedor, proveedor_sku, precio_auto, atributos)
    values (v_id, v_sku, v_map[1],
            coalesce(nullif(trim(v_pp.nombre), ''), nullif(trim(v_pp.modelo), ''), v_pp.sku_proveedor),
            nullif(trim(v_pp.marca), ''), nullif(trim(v_pp.modelo), ''), nullif(trim(v_pp.descripcion), ''),
            'MXN', 'pieza', 0, false, true, v_prov, v_pp.sku_proveedor, false,
            jsonb_strip_nulls(jsonb_build_object(
              'origen', 'proveedor',
              'grupo_proveedor', v_pp.categoria,
              'subcategoria', v_map[2],
              'imagen_proveedor', v_pp.url_imagen,
              'documentos_proveedor', case when v_pp.documentos = '{}'::jsonb then null else v_pp.documentos end)));
    -- El disparador ya creó el vínculo al insertar el producto; aquí solo queda como opción 1.
    insert into producto_proveedores (producto_id, proveedor, proveedor_sku, opcion)
    values (v_id, v_prov, v_pp.sku_proveedor, 1)
    on conflict (producto_id, proveedor) do update set opcion = 1;

    v_creados := v_creados + 1;
    v_por := jsonb_set(v_por, array[v_map[1]], to_jsonb(coalesce((v_por ->> v_map[1])::int, 0) + 1));
  end loop;

  if v_creados > 0 then
    perform _apunta('productos', gen_random_uuid(), 'importar_de_proveedor', null,
                    jsonb_build_object('proveedor', v_prov, 'creados', v_creados, 'por_categoria', v_por),
                    'oficina');
  end if;
  return jsonb_build_object('creados', v_creados, 'ya_existian', v_ya, 'sin_categoria', v_sin,
                            'por_categoria', v_por);
end $fn$;

create or replace function activar_precio_automatico(p_proveedor text, p_categoria text)
returns int
language plpgsql security definer set search_path = public as $fn$
declare
  v_n int;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  update productos p
     set precio_auto = true, updated_at = now()
   where p.activo and not p.precio_auto and p.categoria = p_categoria
     and exists (select 1 from producto_proveedores l
                  where l.producto_id = p.id and l.proveedor = lower(trim(p_proveedor)));
  get diagnostics v_n = row_count;
  if v_n > 0 then
    perform _apunta('productos', gen_random_uuid(), 'activar_precio_auto_lote', null,
                    jsonb_build_object('proveedor', lower(trim(p_proveedor)), 'categoria', p_categoria,
                                       'productos', v_n), 'oficina');
  end if;
  return v_n;
end $fn$;

-- 8. Los repetidos: el mismo artículo en XLStore y en Solarama --------------------------------------
-- Comparados por modelo exacto el 01/10/2026 (XLStore = código de su catálogo; Solarama = el código
-- de su lista de septiembre de 2026). Se ligan aunque Solarama todavía no se haya leído: al leerlo,
-- el sync ya los encuentra, y "Traer productos" no los vuelve a crear.

insert into producto_proveedores (producto_id, proveedor, proveedor_sku)
select p.id, 'solarama', r.solarama
  from (values
    ('INVGROWS10',  'MIN 5000TL-X2'),
    ('INVGROWS11',  'MIN 6000TL-X2'),
    ('INVGROWS3',   'MIN 10000TL-X2'),
    ('BATGROWS119', 'AXE 5.0L-C1 PEDESTAL'),
    ('INVGROWS123', 'TPM-CT-E'),
    ('INVGROWS122', 'TPM-E (ZEROEXPORT)'),
    ('INVHUA1S5',   'SUN2000-3KTL-L1'),
    ('INVHUA1S6',   'SUN2000-5KTL-L1'),
    ('INVHUA1S7',   'SUN2000-6KTL-L1'),
    ('INVHUA1S105', 'SUN2000-8K-LC0'),
    ('INVHUA1S106', 'SUN2000-10K-LC0'),
    ('INVHUA1S109', 'SUN2000-20KTL-M3'),
    ('INVHUA1S110', 'SUN2000-40KTL-M3'),
    ('INVHUA1S22',  'SUN2000-50K-MGL0'),
    ('INVHUA1S23',  'SUN2000-80K-MGL0'),
    ('INVHUA1S111', 'SUN2000-100KTL-M2'),
    ('INVHUA1S11',  'SUN2000-150K-MG0 PRO'),
    ('INVHUA1S113', 'SMART LOGGER 3000A'),
    ('INVHUA1S112', 'SDONGLE-A05'),
    ('INVVIC1S102', 'MULTI-48/3000'),
    ('INVVIC1S119', 'MULTI-48/5000'),
    ('INVVIC1S114', 'QUATTRO-48/10000'),
    ('CONVIC1S17',  'EKRANO'),
    ('INVVIC1S33',  'LYNX-P'),
    ('BATVIC1S23',  'LYNX-D'),
    ('INVVIC1S107', 'MK3-USB'),
    ('BATVIC1S118', 'FUSE HOLDER')
  ) as r(xlstore, solarama)
  join productos p on p.sku = r.xlstore
on conflict do nothing;

-- 9. Permisos ---------------------------------------------------------------------------------------

revoke all on function _precio_venta(numeric, reglas_margen)                     from public, anon;
revoke all on function _calcular_precio(uuid, numeric)                           from public, anon;
revoke all on function _ordenar_proveedores(uuid, jsonb)                         from public, anon, authenticated;
revoke all on function _aplicar_precio(uuid, jsonb, text, uuid, numeric)         from public, anon, authenticated;
revoke all on function _sku_crm(text, text)                                      from public, anon;
revoke all on function _espejo_a_vinculos()                                      from public, anon, authenticated;
revoke all on function sync_aplicar(uuid, numeric, date, text, numeric)          from public;
revoke all on function vincular_producto_proveedor(uuid, text, text, boolean)    from public;
revoke all on function proveedor_resumen(text)                                   from public;
revoke all on function importar_productos_proveedor(text, text[])                from public;
revoke all on function activar_precio_automatico(text, text)                     from public;
revoke all on function fijar_parametro_costeo(text, numeric)                     from public;

grant execute on function sync_aplicar(uuid, numeric, date, text, numeric)       to authenticated;
grant execute on function vincular_producto_proveedor(uuid, text, text, boolean) to authenticated;
grant execute on function proveedor_resumen(text)                                to authenticated;
grant execute on function importar_productos_proveedor(text, text[])             to authenticated;
grant execute on function activar_precio_automatico(text, text)                  to authenticated;
grant execute on function fijar_parametro_costeo(text, numeric)                  to authenticated;

-- 10. Cómo quedó ----------------------------------------------------------------------------------

select
  (select count(*) from producto_proveedores where proveedor = 'solarama') as repetidos_ligados_a_solarama,
  27 - (select count(*) from producto_proveedores where proveedor = 'solarama'
           and proveedor_sku in ('MIN 5000TL-X2','MIN 6000TL-X2','MIN 10000TL-X2','AXE 5.0L-C1 PEDESTAL',
             'TPM-CT-E','TPM-E (ZEROEXPORT)','SUN2000-3KTL-L1','SUN2000-5KTL-L1','SUN2000-6KTL-L1',
             'SUN2000-8K-LC0','SUN2000-10K-LC0','SUN2000-20KTL-M3','SUN2000-40KTL-M3','SUN2000-50K-MGL0',
             'SUN2000-80K-MGL0','SUN2000-100KTL-M2','SUN2000-150K-MG0 PRO','SMART LOGGER 3000A',
             'SDONGLE-A05','MULTI-48/3000','MULTI-48/5000','QUATTRO-48/10000','EKRANO','LYNX-P',
             'LYNX-D','MK3-USB','FUSE HOLDER')) as repetidos_sin_producto_xlstore,
  (select count(*) from producto_proveedores where proveedor = 'xlstore') as vinculos_xlstore,
  (select concat(margen_pct, ' % sobre el ', case sobre when 'precio' then 'precio de venta' else 'costo' end)
     from reglas_margen where activo and categoria is null and marca is null limit 1) as regla_general,
  (select count(*) from parametros_costeo) as parametros_costeo;
