-- ---------------------------------------------------------------------------
-- 45_importar_productos_proveedor.sql — traer al catálogo del CRM los productos del proveedor.
-- Pedido de Caña el 29/09/2026: "no veo los nuevos artículos en el inventario".
--
-- El sync (44) solo guarda lo que dice el proveedor en `proveedor_productos`; Inventario muestra
-- `productos`. Aquí está el paso que faltaba: crear el producto en el CRM, ya vinculado.
--
-- Decisiones de Caña:
--   · SKU = el código de XLStore (único, y ya queda vinculado sin inventar otro código).
--   · Todo entra SIN publicar y sin precio: se publica cuando tenga precio (activar el precio
--     automático, aprobar en la cola). Así 900 productos no salen al sitio de golpe.
--   · Se traen todas las categorías. El CRM las agrupa como el sitio las va a mostrar.
--
-- Categorías del CRM para lo que viene del proveedor (`_categoria_crm`):
--   Paneles solares                              → panel
--   Baterías, controladores y generadores        → bateria      (sin subdividir: el nombre
--       mezcla las tres cosas y adivinar por palabras se equivoca, p. ej. "sistema de control
--       con batería" o un cable para generador; se afina desde Inventario)
--   Inversores / Microinversores                 → inversor     (subcategoria en atributos)
--   Monitoreo, suministros, montaje y kits       → accesorio_solar (subcategoria en atributos)
-- Una categoría del proveedor que no esté en esta lista NO se importa y se cuenta aparte:
-- mejor que alguien decida dónde va a que caiga en una categoría equivocada.
--
-- La imagen y los documentos del proveedor quedan en `atributos` (`imagen_proveedor`,
-- `documentos_proveedor`) para la tarea de descargarlos al sitio.
--
-- Solo admin. Repetible: no duplica (salta lo que ya existe por SKU o por vínculo).
-- ---------------------------------------------------------------------------

-- [categoría del CRM, subcategoría]; null si no hay equivalente.
create or replace function _categoria_crm(p_categoria_proveedor text)
returns text[]
language sql immutable as $$
  select case lower(trim(coalesce(p_categoria_proveedor, '')))
    when 'paneles solares' then array['panel', null]::text[]
    when 'inversores' then array['inversor', 'inversor']::text[]
    when 'microinversores' then array['inversor', 'microinversor']::text[]
    when 'baterías, controladores y generadores' then array['bateria', null]::text[]
    when 'monitoreo, optimizadores y protecciones' then array['accesorio_solar', 'monitoreo']::text[]
    when 'suministros de instalación' then array['accesorio_solar', 'suministros']::text[]
    when 'sistemas de montaje' then array['accesorio_solar', 'montaje']::text[]
    when 'kits' then array['accesorio_solar', 'kits']::text[]
    else null
  end
$$;

-- Qué hay por traer y qué está vinculado, por categoría. Una sola llamada para la pantalla.
create or replace function proveedor_resumen(p_proveedor text)
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
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
                       select 1 from productos p
                        where p.sku = pp.sku_proveedor
                           or (p.proveedor = pp.proveedor and p.proveedor_sku = pp.sku_proveedor))),
                   'equivale', _categoria_crm(pp.categoria) is not null) as x
            from proveedor_productos pp
           where pp.proveedor = lower(trim(p_proveedor)) and pp.vigente
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
           where p.activo and p.proveedor = lower(trim(p_proveedor)) and p.proveedor_sku is not null
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
    if exists (select 1 from productos p
                where p.sku = v_pp.sku_proveedor
                   or (p.proveedor = v_pp.proveedor and p.proveedor_sku = v_pp.sku_proveedor)) then
      v_ya := v_ya + 1;
      continue;
    end if;

    insert into productos (sku, categoria, nombre, marca, modelo, moneda, unidad, minimo,
                           publicar, activo, proveedor, proveedor_sku, precio_auto, atributos)
    values (v_pp.sku_proveedor, v_map[1],
            coalesce(nullif(trim(v_pp.nombre), ''), nullif(trim(v_pp.modelo), ''), v_pp.sku_proveedor),
            nullif(trim(v_pp.marca), ''), nullif(trim(v_pp.modelo), ''), 'MXN', 'pieza', 0,
            false, true, v_pp.proveedor, v_pp.sku_proveedor, false,
            jsonb_strip_nulls(jsonb_build_object(
              'origen', 'proveedor',
              'grupo_proveedor', v_pp.categoria,
              'subcategoria', v_map[2],
              'imagen_proveedor', v_pp.url_imagen,
              'documentos_proveedor', case when v_pp.documentos = '{}'::jsonb then null else v_pp.documentos end)));

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

-- Activar el precio automático de toda una categoría del CRM de un jalón: con 900 productos
-- hacerlo uno por uno no es un flujo. Activarlo NO publica nada: el primer precio de cada uno
-- pasa por la cola de revisión y ahí se aprueba.
create or replace function activar_precio_automatico(p_proveedor text, p_categoria text)
returns int
language plpgsql security definer set search_path = public as $fn$
declare
  v_n int;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  update productos
     set precio_auto = true, updated_at = now()
   where activo and proveedor = lower(trim(p_proveedor)) and proveedor_sku is not null
     and not precio_auto and categoria = p_categoria;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    perform _apunta('productos', gen_random_uuid(), 'activar_precio_auto_lote', null,
                    jsonb_build_object('categoria', p_categoria, 'productos', v_n), 'oficina');
  end if;
  return v_n;
end $fn$;

revoke all on function proveedor_resumen(text)                     from public;
revoke all on function importar_productos_proveedor(text, text[])  from public;
revoke all on function activar_precio_automatico(text, text)       from public;
revoke all on function _categoria_crm(text)                        from public, anon;
grant execute on function proveedor_resumen(text)                    to authenticated;
grant execute on function importar_productos_proveedor(text, text[]) to authenticated;
grant execute on function activar_precio_automatico(text, text)      to authenticated;
