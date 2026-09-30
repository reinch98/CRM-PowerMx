-- ---------------------------------------------------------------------------
-- 44_sync_proveedor.sql — precios y existencias del proveedor (XLStore / Exel Solar)
-- alimentan `productos` con márgenes y candados. Pedido de Caña el 29/09/2026.
--
-- Decisión de diseño (opción A): NO hay una segunda tabla `productos`. El CRM sigue siendo
-- la fuente de verdad del catálogo (el sitio lo lee con `catalogo_publico()`), y el sync es
-- una puerta más para llegar a `precio` y `costo`. Lo que sí es nuevo:
--
--   proveedor_productos  lo que el proveedor dijo en la última lectura (costo, stock).
--   reglas_margen        cuánto se le suma al costo, por categoría y/o marca.
--   historial_precios    cada cambio de precio hecho por el sync o por una aprobación.
--   cola_revision        lo que NO se publica solo y espera a que el admin decida.
--   sync_corridas        una fila por lectura: qué pasó, cuántas filas, si falló.
--   tipos_cambio         el FIX que se usó, para poder explicar un precio después.
--
-- Solo se toca un producto si el admin lo VINCULÓ (`proveedor_sku`) y prendió `precio_auto`.
-- Lo demás de `proveedor_productos` es solo consulta: leer 900 productos no publica ninguno.
--
-- CANDADOS (todos en la base, no en el script: el script puede equivocarse o cambiar):
--   1. Nunca por debajo de costo + margen mínimo (el precio se redondea siempre HACIA ARRIBA).
--   2. Cambio de más de ±15 % → cola_revision, no se publica. Un producto sin precio previo
--      también espera aprobación: no hay referencia contra qué compararlo.
--   3. Un SKU vinculado que el proveedor ya no lista → cola_revision (no se desactiva solo).
--   4. Una lectura con menos de la mitad de las filas de la anterior se marca fallida y no se
--      aplica: casi siempre es una lectura parcial, no que el proveedor borró medio catálogo.
--   5. Si algo falla, la corrida queda `fallida` y el script sale con error (GitHub avisa).
--
-- El precio se calcula AQUÍ, en un solo lugar (`_precio_venta`): así el script no tiene una
-- segunda copia de la fórmula que pueda dar otro número.
--
-- Solo el admin o la cuenta `bot` (la misma del webhook y del catálogo) corren la sincronización;
-- solo el admin resuelve la cola y vincula productos. `anon` no toca nada.
--
-- Repetible: `if not exists`, `drop policy if exists`, `create or replace`.
-- ---------------------------------------------------------------------------

-- 1. Tablas -----------------------------------------------------------------

create table if not exists proveedor_productos (
  id uuid primary key default gen_random_uuid(),
  proveedor text not null,
  sku_proveedor text not null,
  nombre text,
  categoria text,
  marca text,
  modelo text,
  descripcion text,
  costo numeric check (costo is null or costo >= 0),
  moneda text not null default 'USD' check (moneda in ('MXN', 'USD')),
  -- Stock local = en la sucursal cercana del proveedor (para XLStore, MID/Mérida): sirve para
  -- decir "inmediata". Stock del proveedor = lo que tiene en todo su sistema.
  stock_local int,
  stock_proveedor int,
  tiempo_entrega_dias int,
  url_imagen text,
  documentos jsonb not null default '{}',
  corrida_id uuid,
  vigente boolean not null default true,
  leido_en timestamptz not null default now(),
  unique (proveedor, sku_proveedor)
);

create table if not exists reglas_margen (
  id uuid primary key default gen_random_uuid(),
  categoria text,   -- categoría de `productos` (panel, bateria, ...); null = cualquiera
  marca text,       -- null = cualquiera
  margen_pct numeric not null check (margen_pct >= 0),
  margen_minimo_mxn numeric not null default 0 check (margen_minimo_mxn >= 0),
  redondeo numeric not null default 1 check (redondeo > 0),  -- el precio termina en múltiplo de esto
  activo boolean not null default true,
  created_at timestamptz not null default now()
);
-- Una regla activa por combinación (categoria, marca); las dos nulas = la regla general.
create unique index if not exists reglas_margen_unica
  on reglas_margen (coalesce(lower(categoria), ''), coalesce(lower(marca), '')) where activo;

create table if not exists sync_corridas (
  id uuid primary key default gen_random_uuid(),
  proveedor text not null,
  fuente text,
  estado text not null default 'leyendo'
    check (estado in ('leyendo', 'leida', 'aplicada', 'fallida')),
  filas int,
  tipo_cambio numeric,
  resumen jsonb,
  error text,
  iniciada_en timestamptz not null default now(),
  terminada_en timestamptz
);

create table if not exists tipos_cambio (
  fecha date not null,
  moneda text not null default 'USD',
  valor numeric not null check (valor > 0),
  fuente text,
  primary key (fecha, moneda)
);

create table if not exists historial_precios (
  id uuid primary key default gen_random_uuid(),
  producto_id uuid not null references productos (id) on delete cascade,
  precio_anterior numeric,
  precio_nuevo numeric,
  costo_anterior numeric,
  costo_nuevo numeric,
  tipo_cambio numeric,
  origen text not null,      -- 'sync' | 'aprobacion'
  corrida_id uuid,
  creado_en timestamptz not null default now()
);
create index if not exists historial_precios_producto on historial_precios (producto_id, creado_en desc);

create table if not exists cola_revision (
  id uuid primary key default gen_random_uuid(),
  tipo text not null check (tipo in
    ('cambio_precio', 'precio_inicial', 'sku_desaparecido', 'sin_regla', 'sin_costo')),
  producto_id uuid not null references productos (id) on delete cascade,
  proveedor_sku text,
  detalle jsonb not null default '{}',
  estado text not null default 'pendiente' check (estado in ('pendiente', 'aprobada', 'rechazada')),
  corrida_id uuid,
  creado_en timestamptz not null default now(),
  resuelto_por text,
  resuelto_en timestamptz,
  nota text
);
-- Un pendiente por tipo y producto: una lectura nueva actualiza el detalle, no apila.
create unique index if not exists cola_revision_un_pendiente
  on cola_revision (tipo, producto_id) where estado = 'pendiente';

-- Enlace producto ↔ proveedor. `precio_auto` es el interruptor: sin él, el sync ni lo mira.
alter table productos add column if not exists proveedor text;
alter table productos add column if not exists proveedor_sku text;
alter table productos add column if not exists precio_auto boolean not null default false;
alter table productos add column if not exists precio_sync_en timestamptz;

-- 2. RLS: solo admin lee/escribe directo; la sincronización entra por funciones ---------------

alter table proveedor_productos enable row level security;
alter table reglas_margen       enable row level security;
alter table sync_corridas       enable row level security;
alter table tipos_cambio        enable row level security;
alter table historial_precios   enable row level security;
alter table cola_revision       enable row level security;

drop policy if exists admin_proveedor_productos on proveedor_productos;
drop policy if exists admin_reglas_margen       on reglas_margen;
drop policy if exists admin_sync_corridas       on sync_corridas;
drop policy if exists admin_tipos_cambio        on tipos_cambio;
drop policy if exists admin_historial_precios   on historial_precios;
drop policy if exists admin_cola_revision       on cola_revision;

create policy admin_proveedor_productos on proveedor_productos
  for all to authenticated using (es_admin()) with check (es_admin());
create policy admin_reglas_margen on reglas_margen
  for all to authenticated using (es_admin()) with check (es_admin());
create policy admin_sync_corridas on sync_corridas
  for select to authenticated using (es_admin());
create policy admin_tipos_cambio on tipos_cambio
  for select to authenticated using (es_admin());
create policy admin_historial_precios on historial_precios
  for select to authenticated using (es_admin());
create policy admin_cola_revision on cola_revision
  for select to authenticated using (es_admin());

revoke all on proveedor_productos, reglas_margen, sync_corridas, tipos_cambio,
              historial_precios, cola_revision from anon;

-- 3. Cálculo de precio (un solo lugar) ---------------------------------------------------------

-- La regla más específica gana: marca+categoría > marca > categoría > general.
create or replace function _regla_margen(p_categoria text, p_marca text)
returns reglas_margen
language sql stable set search_path = public as $$
  select r.*
    from reglas_margen r
   where r.activo
     and (r.categoria is null or lower(r.categoria) = lower(coalesce(p_categoria, '')))
     and (r.marca is null or lower(r.marca) = lower(coalesce(p_marca, '')))
   order by (case when r.marca is not null then 2 else 0 end
             + case when r.categoria is not null then 1 else 0 end) desc
   limit 1
$$;

-- precio = el mayor entre (costo × (1 + margen)) y (costo + margen mínimo), redondeado
-- SIEMPRE hacia arriba al múltiplo de la regla. Por eso nunca queda bajo costo + mínimo.
create or replace function _precio_venta(p_costo_mxn numeric, p_regla reglas_margen)
returns numeric
language sql immutable as $$
  select ceil(greatest(p_costo_mxn * (1 + p_regla.margen_pct / 100),
                       p_costo_mxn + p_regla.margen_minimo_mxn) / p_regla.redondeo)
         * p_regla.redondeo
$$;

-- Qué precio le tocaría a un producto vinculado con el costo y el tipo de cambio dados.
create or replace function _calcular_precio(p_producto uuid, p_tc numeric)
returns jsonb
language plpgsql stable set search_path = public as $fn$
declare
  v_p productos;
  v_pp proveedor_productos;
  v_r reglas_margen;
  v_costo numeric;
begin
  v_p := (select p from productos p where p.id = p_producto);
  if v_p.id is null then
    return jsonb_build_object('ok', false, 'motivo', 'sin_producto');
  end if;
  v_pp := (select x from proveedor_productos x
            where x.proveedor = v_p.proveedor and x.sku_proveedor = v_p.proveedor_sku);
  if v_pp.id is null then
    return jsonb_build_object('ok', false, 'motivo', 'sin_lectura');
  end if;
  if v_pp.costo is null or v_pp.costo <= 0 then
    return jsonb_build_object('ok', false, 'motivo', 'sin_costo');
  end if;
  if v_pp.moneda = 'USD' and (p_tc is null or p_tc <= 0) then
    return jsonb_build_object('ok', false, 'motivo', 'sin_tipo_cambio');
  end if;
  v_costo := round(v_pp.costo * (case when v_pp.moneda = 'USD' then p_tc else 1 end), 2);
  v_r := _regla_margen(v_p.categoria, v_p.marca);
  if v_r.id is null then
    return jsonb_build_object('ok', false, 'motivo', 'sin_regla');
  end if;
  return jsonb_build_object('ok', true, 'costo_mxn', v_costo,
                            'precio', _precio_venta(v_costo, v_r),
                            'margen_pct', v_r.margen_pct, 'margen_minimo', v_r.margen_minimo_mxn,
                            'vigente', v_pp.vigente);
end $fn$;

-- Escribe precio y costo, deja historial y auditoría. Última línea de defensa: si por
-- cualquier razón el precio quedara bajo costo + mínimo, se detiene todo.
create or replace function _aplicar_precio(p_producto uuid, p_calc jsonb, p_origen text,
                                           p_corrida uuid, p_tc numeric)
returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_p productos;
  v_precio numeric := (p_calc ->> 'precio')::numeric;
  v_costo numeric := (p_calc ->> 'costo_mxn')::numeric;
begin
  if v_precio < v_costo + (p_calc ->> 'margen_minimo')::numeric then
    raise exception 'Precio % por debajo de costo % + margen mínimo: no se publica.',
      v_precio, v_costo using errcode = '23514';
  end if;
  v_p := (select p from productos p where p.id = p_producto);
  update productos
     set precio = v_precio, costo = v_costo, moneda = 'MXN',
         precio_sync_en = now(), updated_at = now()
   where id = p_producto;
  insert into historial_precios (producto_id, precio_anterior, precio_nuevo,
                                 costo_anterior, costo_nuevo, tipo_cambio, origen, corrida_id)
  values (p_producto, v_p.precio, v_precio, v_p.costo, v_costo, p_tc, p_origen, p_corrida);
  perform _apunta('productos', p_producto, 'precio_por_proveedor',
                  jsonb_build_object('precio', v_p.precio, 'costo', v_p.costo),
                  jsonb_build_object('precio', v_precio, 'costo', v_costo, 'origen', p_origen),
                  'sync');
end $fn$;
revoke all on function _aplicar_precio(uuid, jsonb, text, uuid, numeric) from public, anon, authenticated;

create or replace function _encolar(p_tipo text, p_producto uuid, p_sku text, p_detalle jsonb,
                                    p_corrida uuid)
returns void
language sql security definer set search_path = public as $$
  insert into cola_revision (tipo, producto_id, proveedor_sku, detalle, corrida_id)
  values (p_tipo, p_producto, p_sku, p_detalle, p_corrida)
  on conflict (tipo, producto_id) where estado = 'pendiente'
  do update set detalle = excluded.detalle, corrida_id = excluded.corrida_id, creado_en = now()
$$;
revoke all on function _encolar(text, uuid, text, jsonb, uuid) from public, anon, authenticated;

-- 4. Sincronización: iniciar → lotes → cerrar lectura → aplicar ----------------------------------

create or replace function sync_iniciar(p_proveedor text, p_fuente text default null)
returns uuid
language plpgsql security definer set search_path = public as $fn$
declare
  v_id uuid := gen_random_uuid();
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector.' using errcode = '42501';
  end if;
  if coalesce(trim(p_proveedor), '') = '' then
    raise exception 'Falta el proveedor.' using errcode = '22023';
  end if;
  insert into sync_corridas (id, proveedor, fuente) values (v_id, lower(trim(p_proveedor)), p_fuente);
  return v_id;
end $fn$;

-- Cada fila: sku_proveedor, nombre, categoria, marca, modelo, descripcion, costo, moneda,
-- stock_local, stock_proveedor, tiempo_entrega_dias, url_imagen, documentos.
create or replace function sync_recibir_lote(p_corrida uuid, p_filas jsonb)
returns int
language plpgsql security definer set search_path = public as $fn$
declare
  v_c sync_corridas;
  v_f jsonb;
  v_n int := 0;
  v_moneda text;
  v_costo numeric;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector.' using errcode = '42501';
  end if;
  v_c := (select c from sync_corridas c where c.id = p_corrida);
  if v_c.id is null or v_c.estado <> 'leyendo' then
    raise exception 'La corrida no existe o ya no recibe filas.' using errcode = '22023';
  end if;
  if jsonb_typeof(p_filas) <> 'array' then
    raise exception 'Las filas deben ir en un arreglo.' using errcode = '22023';
  end if;

  for v_f in select value from jsonb_array_elements(p_filas) loop
    if coalesce(trim(v_f ->> 'sku_proveedor'), '') = '' then
      raise exception 'Una fila no trae sku_proveedor.' using errcode = '22023';
    end if;
    v_moneda := upper(coalesce(nullif(v_f ->> 'moneda', ''), ''));
    if v_moneda not in ('MXN', 'USD') then
      raise exception 'Moneda inválida en %: "%".', v_f ->> 'sku_proveedor', v_f ->> 'moneda'
        using errcode = '22023';
    end if;
    v_costo := nullif(v_f ->> 'costo', '')::numeric;
    if v_costo is not null and v_costo < 0 then
      raise exception 'Costo negativo en %.', v_f ->> 'sku_proveedor' using errcode = '22023';
    end if;

    insert into proveedor_productos (proveedor, sku_proveedor, nombre, categoria, marca, modelo,
                                     descripcion, costo, moneda, stock_local, stock_proveedor,
                                     tiempo_entrega_dias, url_imagen, documentos,
                                     corrida_id, vigente, leido_en)
    values (v_c.proveedor, trim(v_f ->> 'sku_proveedor'), v_f ->> 'nombre', v_f ->> 'categoria',
            v_f ->> 'marca', v_f ->> 'modelo', v_f ->> 'descripcion', v_costo, v_moneda,
            nullif(v_f ->> 'stock_local', '')::int, nullif(v_f ->> 'stock_proveedor', '')::int,
            nullif(v_f ->> 'tiempo_entrega_dias', '')::int, nullif(v_f ->> 'url_imagen', ''),
            coalesce(v_f -> 'documentos', '{}'::jsonb), p_corrida, true, now())
    on conflict (proveedor, sku_proveedor) do update
      set nombre = excluded.nombre, categoria = excluded.categoria, marca = excluded.marca,
          modelo = excluded.modelo, descripcion = excluded.descripcion, costo = excluded.costo,
          moneda = excluded.moneda, stock_local = excluded.stock_local,
          stock_proveedor = excluded.stock_proveedor,
          tiempo_entrega_dias = excluded.tiempo_entrega_dias, url_imagen = excluded.url_imagen,
          documentos = excluded.documentos, corrida_id = excluded.corrida_id,
          vigente = true, leido_en = excluded.leido_en;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $fn$;

-- Candado 4: una lectura con menos de la mitad de la anterior se rechaza.
create or replace function sync_cerrar_lectura(p_corrida uuid)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_c sync_corridas;
  v_filas int;
  v_previas int;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector.' using errcode = '42501';
  end if;
  v_c := (select c from sync_corridas c where c.id = p_corrida);
  if v_c.id is null or v_c.estado <> 'leyendo' then
    raise exception 'La corrida no existe o ya se cerró.' using errcode = '22023';
  end if;
  v_filas := (select count(*) from proveedor_productos where corrida_id = p_corrida);
  v_previas := (select c.filas from sync_corridas c
                 where c.proveedor = v_c.proveedor and c.id <> p_corrida
                   and c.estado in ('leida', 'aplicada')
                 order by c.iniciada_en desc limit 1);

  if v_filas = 0 or (coalesce(v_previas, 0) > 0 and v_filas < v_previas * 0.5) then
    update sync_corridas
       set estado = 'fallida', filas = v_filas, terminada_en = now(),
           error = concat('Lectura sospechosa: ', v_filas, ' filas contra ', coalesce(v_previas, 0),
                          ' de la lectura anterior. No se aplicó nada.')
     where id = p_corrida;
    return jsonb_build_object('ok', false, 'filas', v_filas, 'previas', coalesce(v_previas, 0));
  end if;

  update sync_corridas set estado = 'leida', filas = v_filas where id = p_corrida;
  return jsonb_build_object('ok', true, 'filas', v_filas, 'previas', coalesce(v_previas, 0));
end $fn$;

create or replace function sync_registrar_error(p_corrida uuid, p_error text)
returns void
language plpgsql security definer set search_path = public as $fn$
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector.' using errcode = '42501';
  end if;
  update sync_corridas
     set estado = 'fallida', error = left(p_error, 2000), terminada_en = now()
   where id = p_corrida and estado in ('leyendo', 'leida');
end $fn$;

create or replace function sync_aplicar(p_corrida uuid, p_tipo_cambio numeric,
                                        p_tc_fecha date default null, p_tc_fuente text default null,
                                        p_umbral_pct numeric default 15)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_c sync_corridas;
  v_p productos;
  v_pp proveedor_productos;
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
  -- Un FIX fuera de este rango es un error de captura o de lectura, no una devaluación.
  if p_tipo_cambio is null or p_tipo_cambio < 5 or p_tipo_cambio > 100 then
    raise exception 'Tipo de cambio fuera de rango: %.', p_tipo_cambio using errcode = '22023';
  end if;

  insert into tipos_cambio (fecha, moneda, valor, fuente)
  values (coalesce(p_tc_fecha, current_date), 'USD', p_tipo_cambio, p_tc_fuente)
  on conflict (fecha, moneda) do update set valor = excluded.valor, fuente = excluded.fuente;

  -- Lo que el proveedor ya no lista deja de estar vigente...
  update proveedor_productos
     set vigente = false
   where proveedor = v_c.proveedor and corrida_id is distinct from p_corrida;
  -- ...y lo que reapareció cancela su aviso de "desaparecido".
  update cola_revision q
     set estado = 'rechazada', resuelto_por = 'sync', resuelto_en = now(),
         nota = 'Volvió a aparecer en la lectura.'
   where q.tipo = 'sku_desaparecido' and q.estado = 'pendiente'
     and exists (select 1 from productos p
                   join proveedor_productos x
                     on x.proveedor = p.proveedor and x.sku_proveedor = p.proveedor_sku
                  where p.id = q.producto_id and x.corrida_id = p_corrida);

  for v_p in
    select * from productos
     where precio_auto and activo and proveedor = v_c.proveedor and proveedor_sku is not null
     order by sku
  loop
    v_pp := (select x from proveedor_productos x
              where x.proveedor = v_p.proveedor and x.sku_proveedor = v_p.proveedor_sku);

    if v_pp.id is null or not v_pp.vigente then
      perform _encolar('sku_desaparecido', v_p.id, v_p.proveedor_sku,
                       jsonb_build_object('nombre', v_p.nombre, 'precio_actual', v_p.precio), p_corrida);
      v_revision := v_revision + 1;
      continue;
    end if;

    v_calc := _calcular_precio(v_p.id, p_tipo_cambio);
    if not (v_calc ->> 'ok')::boolean then
      -- Sin costo o sin regla: no hay qué aprobar, hay que arreglar la causa.
      perform _encolar(case v_calc ->> 'motivo' when 'sin_regla' then 'sin_regla' else 'sin_costo' end,
                       v_p.id, v_p.proveedor_sku,
                       jsonb_build_object('nombre', v_p.nombre, 'motivo', v_calc ->> 'motivo'), p_corrida);
      v_faltan := v_faltan + 1;
      continue;
    end if;

    -- Ya hay regla y costo: los avisos de "falta capturar" de una lectura anterior sobran.
    update cola_revision
       set estado = 'rechazada', resuelto_por = 'sync', resuelto_en = now(),
           nota = 'Ya se resolvió: hay regla y costo.'
     where producto_id = v_p.id and tipo in ('sin_regla', 'sin_costo') and estado = 'pendiente';

    if v_p.precio is null or v_p.precio <= 0 then
      perform _encolar('precio_inicial', v_p.id, v_p.proveedor_sku,
                       v_calc || jsonb_build_object('nombre', v_p.nombre), p_corrida);
      v_revision := v_revision + 1;
      continue;
    end if;

    v_var := abs((v_calc ->> 'precio')::numeric - v_p.precio) / v_p.precio * 100;
    if v_var > p_umbral_pct then
      perform _encolar('cambio_precio', v_p.id, v_p.proveedor_sku,
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

-- 5. Cola de revisión y vínculos (solo admin) ----------------------------------------------------

-- Aprobar recalcula con el costo y el FIX más recientes: nunca aplica un precio viejo
-- guardado en la cola. Aprobar un "desaparecido" retira el producto del sitio (publicar=false).
create or replace function resolver_revision(p_id uuid, p_aprobar boolean, p_nota text default null)
returns text
language plpgsql security definer set search_path = public as $fn$
declare
  v_q cola_revision;
  v_tc numeric;
  v_calc jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  v_q := (select q from cola_revision q where q.id = p_id);
  if v_q.id is null then
    raise exception 'No existe esa revisión.' using errcode = '22023';
  end if;
  if v_q.estado <> 'pendiente' then
    return 'sin_cambio';
  end if;

  if p_aprobar then
    if v_q.tipo in ('sin_regla', 'sin_costo') then
      raise exception 'Esto no se aprueba: captura la regla o el costo y vuelve a sincronizar. Aquí solo se descarta.'
        using errcode = '22023';
    elsif v_q.tipo = 'sku_desaparecido' then
      update productos set publicar = false, updated_at = now() where id = v_q.producto_id;
      perform _apunta('productos', v_q.producto_id, 'retirado_por_proveedor', null,
                      jsonb_build_object('publicar', false), 'sync');
    else
      v_tc := (select valor from tipos_cambio where moneda = 'USD' order by fecha desc limit 1);
      v_calc := _calcular_precio(v_q.producto_id, v_tc);
      if not (v_calc ->> 'ok')::boolean then
        raise exception 'No se puede calcular el precio (%).', v_calc ->> 'motivo' using errcode = '22023';
      end if;
      if not (v_calc ->> 'vigente')::boolean then
        raise exception 'El proveedor ya no lista este producto.' using errcode = '22023';
      end if;
      perform _aplicar_precio(v_q.producto_id, v_calc, 'aprobacion', v_q.corrida_id, v_tc);
    end if;
  end if;

  update cola_revision
     set estado = case when p_aprobar then 'aprobada' else 'rechazada' end,
         resuelto_por = coalesce(auth.jwt() ->> 'email', 'crm'), resuelto_en = now(), nota = p_nota
   where id = p_id;
  return case when p_aprobar then 'aprobada' else 'rechazada' end;
end $fn$;

-- En lote, por tipo. Cada una en su propia subtransacción: una que falle no tumba las demás.
create or replace function resolver_revisiones(p_tipo text, p_aprobar boolean)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_id uuid;
  v_ok int := 0;
  v_mal int := 0;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  for v_id in select id from cola_revision where tipo = p_tipo and estado = 'pendiente' order by creado_en loop
    begin
      perform resolver_revision(v_id, p_aprobar, 'En lote');
      v_ok := v_ok + 1;
    exception when others then
      v_mal := v_mal + 1;
    end;
  end loop;
  return jsonb_build_object('resueltas', v_ok, 'fallidas', v_mal);
end $fn$;

create or replace function vincular_producto_proveedor(p_producto uuid, p_proveedor text,
                                                       p_sku text, p_precio_auto boolean default false)
returns text
language plpgsql security definer set search_path = public as $fn$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if p_sku is not null and not exists (
       select 1 from proveedor_productos
        where proveedor = lower(trim(p_proveedor)) and sku_proveedor = trim(p_sku)) then
    raise exception 'El proveedor no tiene ese código en la última lectura.' using errcode = '22023';
  end if;
  update productos
     set proveedor = case when p_sku is null then null else lower(trim(p_proveedor)) end,
         proveedor_sku = nullif(trim(p_sku), ''),
         precio_auto = case when p_sku is null then false else p_precio_auto end,
         updated_at = now()
   where id = p_producto;
  if not found then
    raise exception 'No existe ese producto.' using errcode = '22023';
  end if;
  perform _apunta('productos', p_producto, 'vincular_proveedor', null,
                  jsonb_build_object('proveedor', p_proveedor, 'sku', p_sku, 'precio_auto', p_precio_auto),
                  'oficina');
  return 'ok';
end $fn$;

-- 6. Permisos ----------------------------------------------------------------------------------

revoke all on function sync_iniciar(text, text)                                  from public;
revoke all on function sync_recibir_lote(uuid, jsonb)                            from public;
revoke all on function sync_cerrar_lectura(uuid)                                 from public;
revoke all on function sync_registrar_error(uuid, text)                          from public;
revoke all on function sync_aplicar(uuid, numeric, date, text, numeric)          from public;
revoke all on function resolver_revision(uuid, boolean, text)                    from public;
revoke all on function resolver_revisiones(text, boolean)                        from public;
revoke all on function vincular_producto_proveedor(uuid, text, text, boolean)    from public;
revoke all on function _calcular_precio(uuid, numeric)                           from public, anon;
revoke all on function _regla_margen(text, text)                                 from public, anon;
revoke all on function _precio_venta(numeric, reglas_margen)                     from public, anon;

grant execute on function sync_iniciar(text, text)                               to authenticated;
grant execute on function sync_recibir_lote(uuid, jsonb)                         to authenticated;
grant execute on function sync_cerrar_lectura(uuid)                              to authenticated;
grant execute on function sync_registrar_error(uuid, text)                       to authenticated;
grant execute on function sync_aplicar(uuid, numeric, date, text, numeric)       to authenticated;
grant execute on function resolver_revision(uuid, boolean, text)                 to authenticated;
grant execute on function resolver_revisiones(text, boolean)                     to authenticated;
grant execute on function vincular_producto_proveedor(uuid, text, text, boolean) to authenticated;
