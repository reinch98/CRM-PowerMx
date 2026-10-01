-- ---------------------------------------------------------------------------
-- 52_disponibilidad_y_promociones.sql — margen sobre el costo, disponibilidad con las existencias del
-- proveedor y precio "EN PROMOCIÓN". Pedido de Caña el 01/10/2026, después de correr la 51.
--
-- Decisiones de Caña:
--   · "El margen es sobre el costo": la regla general queda en 30 % SOBRE EL COSTO (precio = costo × 1.30).
--     La 51 la había dejado en 30 % sobre el precio de venta; aquí se corrige solo si sigue así.
--   · En el sitio, la disponibilidad sale de las existencias de la última lectura de XLStore. Lo de
--     Solarama es SOBRE PEDIDO (su lista no trae existencias).
--   · Los artículos que comparten proveedor siguen con el precio del más caro.
--   · Apartado "EN PROMOCIÓN": los repetidos que salen bastante más baratos comprándolos en Solarama
--     se ofrecen a un precio menor, que aún deja un margen considerable.
--   · Solarama manda su lista cada ~5 meses: la promoción solo vale mientras esa lista sea reciente.
--
-- Qué cambia:
--   1. Regla general: 30 % sobre el costo.
--   2. `productos.precio_promocion`. Se calcula en la base (`_precio_promocion`) con tres parámetros
--      nuevos de `parametros_costeo`, editables en Precios:
--        promo_margen_pct (40)            margen sobre el costo del proveedor más barato;
--        promo_descuento_minimo_pct (5)   si no baja al menos esto contra el precio normal, no es promoción;
--        promo_vigencia_lista_dias (200)  una lista más vieja que esto no da promociones.
--      Solo hay promoción si el más barato (opción 1) NO es el que marca el precio normal, su lectura
--      está vigente y es reciente, y el producto ya tiene precio publicado. Nunca baja del costo × 1.40.
--   3. `sync_aplicar` recalcula TODOS los productos con proveedor y precio automático, no solo los del
--      proveedor de la corrida: así lo que solo vende Solarama (lista cada ~5 meses) sigue el tipo de
--      cambio de cada lectura de XLStore. "Ya no lo lista" sigue siendo solo del proveedor de la corrida.
--   4. `catalogo_publico()` agrega `disponibilidad` ('inmediata' | 'proveedor' | 'pedido'),
--      `precio_promocion` y las EXISTENCIAS DEL PROVEEDOR de su última lectura (`existencia_merida` y
--      `existencia_nacional`; Caña: "quiero que aparezcan las existencias de Exel"). 'inmediata' =
--      existencia propia o en XLStore Mérida; 'proveedor' = solo en la existencia nacional de XLStore;
--      'pedido' = nada de lo anterior (todo lo de Solarama). `disponible` sigue existiendo (= no es
--      'pedido'). La cantidad del almacén PROPIO sigue sin publicarse.
--
-- Repetible. Sin `select ... into` (ver CLAUDE.md).
-- ---------------------------------------------------------------------------

-- 1. El margen es sobre el costo ----------------------------------------------------------------

update reglas_margen
   set sobre = 'costo'
 where activo and categoria is null and marca is null
   and margen_pct = 30 and sobre = 'precio';

-- 2. Precio de promoción -------------------------------------------------------------------------

alter table productos add column if not exists precio_promocion numeric;

insert into parametros_costeo (clave, etiqueta, valor, unidad, nota, orden) values
  ('promo_margen_pct', 'Margen de la promoción, sobre el costo del proveedor más barato', 40, '%',
   'Un repetido que sale bastante más barato en Solarama se ofrece a ese costo más este margen.', 20),
  ('promo_descuento_minimo_pct', 'Descuento mínimo para que sea promoción', 5, '%',
   'Si el precio de promoción no baja al menos esto contra el precio normal, no se anuncia.', 21),
  ('promo_vigencia_lista_dias', 'Días que vale la lista del proveedor para una promoción', 200, 'días',
   'Solarama manda su lista cada ~5 meses; más vieja que esto, la promoción se apaga sola.', 22)
on conflict (clave) do nothing;

create or replace function _precio_promocion(p_producto uuid, p_calc jsonb)
returns numeric
language plpgsql stable set search_path = public as $fn$
declare
  v_p productos;
  v_r reglas_margen;
  v_margen numeric := (select valor from parametros_costeo where clave = 'promo_margen_pct');
  v_minimo numeric := (select valor from parametros_costeo where clave = 'promo_descuento_minimo_pct');
  v_dias numeric := (select valor from parametros_costeo where clave = 'promo_vigencia_lista_dias');
  v_leido timestamptz;
  v_redondeo numeric;
  v_promo numeric;
begin
  if not coalesce((p_calc ->> 'ok')::boolean, false) or not coalesce((p_calc ->> 'vigente')::boolean, false) then
    return null;
  end if;
  -- Solo cuando se le compra a uno y el precio normal lo marca otro (el más caro).
  if v_margen is null or p_calc ->> 'proveedor' is null
     or p_calc ->> 'proveedor' = coalesce(p_calc ->> 'proveedor_precio', '') then
    return null;
  end if;
  v_p := (select p from productos p where p.id = p_producto);
  if v_p.precio is null or v_p.precio <= 0 then
    return null;
  end if;
  v_leido := (select x.leido_en from proveedor_productos x
               where x.proveedor = p_calc ->> 'proveedor' and x.sku_proveedor = p_calc ->> 'proveedor_sku');
  if v_leido is null or v_leido < now() - make_interval(days => coalesce(v_dias, 200)::int) then
    return null;
  end if;
  v_r := _regla_margen(v_p.categoria, v_p.marca);
  v_redondeo := coalesce(v_r.redondeo, 1);
  v_promo := ceil((p_calc ->> 'costo_mxn')::numeric * (1 + v_margen / 100) / v_redondeo) * v_redondeo;
  if v_promo > v_p.precio * (1 - coalesce(v_minimo, 5) / 100) then
    return null;
  end if;
  return v_promo;
end $fn$;

-- Igual que en la 51, más la promoción: se recalcula cada vez que se reordenan los proveedores (en
-- cada sincronización y al aplicar un precio). Un cálculo que falla apaga la promoción.
create or replace function _ordenar_proveedores(p_producto uuid, p_calc jsonb)
returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_promo numeric;
begin
  if not coalesce((p_calc ->> 'ok')::boolean, false) then
    update productos set precio_promocion = null
     where id = p_producto and precio_promocion is not null;
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
  v_promo := _precio_promocion(p_producto, p_calc);
  update productos set precio_promocion = v_promo
   where id = p_producto and precio_promocion is distinct from v_promo;
end $fn$;

-- 3. La sincronización recalcula todo lo que tiene proveedor ------------------------------------------

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

  -- Todos los productos con proveedor y precio automático: el tipo de cambio del día también mueve
  -- lo que solo vende el otro proveedor.
  for v_p in
    select p.* from productos p
     where p.precio_auto and p.activo
       and exists (select 1 from producto_proveedores l where l.producto_id = p.id)
     order by p.sku
  loop
    v_sku := (select l.proveedor_sku from producto_proveedores l
               where l.producto_id = v_p.id and l.proveedor = v_c.proveedor);

    if v_sku is not null then
      v_pp := (select x from proveedor_productos x
                where x.proveedor = v_c.proveedor and x.sku_proveedor = v_sku);
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
    end if;

    v_calc := _calcular_precio(v_p.id, p_tipo_cambio);
    if not (v_calc ->> 'ok')::boolean then
      perform _ordenar_proveedores(v_p.id, v_calc);   -- apaga la promoción si la había
      perform _encolar(case v_calc ->> 'motivo' when 'sin_regla' then 'sin_regla' else 'sin_costo' end,
                       v_p.id, coalesce(v_sku, v_p.proveedor_sku),
                       jsonb_build_object('nombre', v_p.nombre, 'motivo', v_calc ->> 'motivo'), p_corrida);
      v_faltan := v_faltan + 1;
      continue;
    end if;

    update cola_revision
       set estado = 'rechazada', resuelto_por = 'sync', resuelto_en = now(),
           nota = 'Ya se resolvió: hay regla y costo.'
     where producto_id = v_p.id and tipo in ('sin_regla', 'sin_costo') and estado = 'pendiente';

    perform _ordenar_proveedores(v_p.id, v_calc);

    if v_p.precio is null or v_p.precio <= 0 then
      perform _encolar('precio_inicial', v_p.id, coalesce(v_sku, v_p.proveedor_sku),
                       v_calc || jsonb_build_object('nombre', v_p.nombre), p_corrida);
      v_revision := v_revision + 1;
      continue;
    end if;

    v_var := abs((v_calc ->> 'precio')::numeric - v_p.precio) / v_p.precio * 100;
    if v_var > p_umbral_pct then
      perform _encolar('cambio_precio', v_p.id, coalesce(v_sku, v_p.proveedor_sku),
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
                                      'en_revision', v_revision, 'sin_regla_o_costo', v_faltan,
                                      'en_promocion', (select count(*) from productos
                                                        where activo and precio_promocion is not null))
   where id = p_corrida;

  return jsonb_build_object('aplicados', v_aplicados, 'sin_cambio', v_sin_cambio,
                            'en_revision', v_revision, 'sin_regla_o_costo', v_faltan);
end $fn$;

-- Quitar un proveedor o apagar el precio automático también apaga la promoción: la siguiente
-- sincronización la vuelve a calcular si sigue valiendo. (Misma función de la 51, una línea más.)
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

  v_primero := (select l from producto_proveedores l where l.producto_id = p_producto
                 order by l.opcion nulls last, l.creado_en, l.proveedor limit 1);
  update productos
     set proveedor = v_primero.proveedor,
         proveedor_sku = v_primero.proveedor_sku,
         precio_auto = case when v_primero.producto_id is null then false
                            when v_sku is null then precio_auto
                            else p_precio_auto end,
         precio_promocion = null,
         updated_at = now()
   where id = p_producto;

  perform _apunta('productos', p_producto, 'vincular_proveedor', null,
                  jsonb_build_object('proveedor', v_prov, 'sku', v_sku, 'precio_auto', p_precio_auto),
                  'oficina');
  return 'ok';
end $fn$;

-- 4. Catálogo público con disponibilidad y promoción --------------------------------------------------

create or replace function catalogo_publico()
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_resultado jsonb;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector del sitio.' using errcode = '42501';
  end if;

  v_resultado := (
    select coalesce(jsonb_agg(jsonb_build_object(
             'sku', p.sku,
             'categoria', p.categoria,
             'nombre', p.nombre,
             'marca', p.marca,
             'modelo', p.modelo,
             'descripcion', p.descripcion,
             'precio', p.precio,
             'precios', p.precios,
             'moneda', p.moneda,
             'unidad', p.unidad,
             'atributos', p.atributos,
             'clave_producto_sat', p.clave_producto_sat,
             'clave_unidad_sat', p.clave_unidad_sat,
             'disponible', d.disponibilidad <> 'pedido',
             'disponibilidad', d.disponibilidad,
             -- Existencias del proveedor en su última lectura (las de PowerMx no se publican).
             'existencia_merida', e.merida,
             'existencia_nacional', e.nacional,
             -- Solo si de verdad baja: una promoción por encima del precio normal no se anuncia.
             'precio_promocion', case when p.precio_promocion > 0 and p.precio_promocion < p.precio
                                      then p.precio_promocion end
           ) order by p.categoria, p.sku), '[]'::jsonb)
      from productos p
      cross join lateral (
        select case
          -- Existencia propia: físico − apartado − resguardo, la MISMA fórmula de la 39 (tres sumas por
          -- separado; juntarlas en una sola da un número equivocado).
          when coalesce((
                 select
                   coalesce(sum(case m.tipo
                                  when 'entrada' then m.cantidad
                                  when 'salida_venta' then -m.cantidad
                                  when 'consumo_resguardo' then -m.cantidad
                                  when 'consumo_servicio' then -m.cantidad
                                  when 'ajuste' then m.cantidad
                                  when 'entrega_tecnico' then -m.cantidad
                                  when 'devolucion_tecnico' then m.cantidad
                                  else 0 end), 0)
                   - coalesce(sum(case m.tipo
                                    when 'apartado' then m.cantidad
                                    when 'libera_apartado' then -m.cantidad
                                    when 'salida_venta' then -m.cantidad
                                    when 'a_resguardo' then -m.cantidad
                                    else 0 end), 0)
                   - coalesce(sum(case m.tipo
                                    when 'a_resguardo' then m.cantidad
                                    when 'consumo_resguardo' then -m.cantidad
                                    else 0 end), 0)
                 from movimientos_inventario m
                 where m.producto_id = p.id
               ), 0) > 0 then 'inmediata'
          -- Existencia del proveedor en Mérida (XLStore MID), en su última lectura.
          when exists (select 1 from producto_proveedores l
                         join proveedor_productos x
                           on x.proveedor = l.proveedor and x.sku_proveedor = l.proveedor_sku
                        where l.producto_id = p.id and x.vigente and x.stock_local > 0) then 'inmediata'
          -- Solo en la existencia nacional del proveedor.
          when exists (select 1 from producto_proveedores l
                         join proveedor_productos x
                           on x.proveedor = l.proveedor and x.sku_proveedor = l.proveedor_sku
                        where l.producto_id = p.id and x.vigente and x.stock_proveedor > 0) then 'proveedor'
          else 'pedido'
        end as disponibilidad
      ) d
      cross join lateral (
        select sum(x.stock_local) filter (where x.stock_local > 0) as merida,
               sum(x.stock_proveedor) filter (where x.stock_proveedor > 0) as nacional
          from producto_proveedores l
          join proveedor_productos x
            on x.proveedor = l.proveedor and x.sku_proveedor = l.proveedor_sku
         where l.producto_id = p.id and x.vigente
      ) e
     where p.activo and p.publicar);

  return v_resultado;
end $fn$;

-- 5. Permisos -------------------------------------------------------------------------------------

revoke all on function _precio_promocion(uuid, jsonb)                            from public, anon, authenticated;
revoke all on function _ordenar_proveedores(uuid, jsonb)                         from public, anon, authenticated;
revoke all on function sync_aplicar(uuid, numeric, date, text, numeric)          from public;
revoke all on function vincular_producto_proveedor(uuid, text, text, boolean)    from public;
revoke all on function catalogo_publico()                                        from public, anon;
grant execute on function sync_aplicar(uuid, numeric, date, text, numeric)       to authenticated;
grant execute on function vincular_producto_proveedor(uuid, text, text, boolean) to authenticated;
grant execute on function catalogo_publico()                                     to authenticated;

-- 6. Cómo quedó -------------------------------------------------------------------------------------

select
  (select concat(margen_pct, ' % sobre el ', case sobre when 'precio' then 'precio de venta' else 'costo' end)
     from reglas_margen where activo and categoria is null and marca is null limit 1) as regla_general,
  (select string_agg(concat(clave, '=', valor), ', ' order by orden)
     from parametros_costeo where clave like 'promo_%') as parametros_de_promocion,
  (select count(*) from productos where precio_promocion is not null) as en_promocion_por_ahora;
