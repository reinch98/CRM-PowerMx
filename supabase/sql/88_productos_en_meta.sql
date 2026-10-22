-- ============================================================================
-- 88 · Elegir qué productos van al catálogo de Meta (Facebook, Instagram y WhatsApp)
--
-- Pedido de Caña (22/10/2026): "subdivídelo para que a Meta solo se carguen productos
-- seleccionados". El sitio sigue publicando todo; el archivo catalogo-meta.csv (lo arma
-- convertir.js del repo del sitio) solo lleva los productos con en_meta.
--   * productos.en_meta nace en false: nada sale a Meta hasta que se marque.
--   * Se marca en Inventario → Catálogo (una casilla por producto, o todos los que se ven).
--     El admin ya puede escribir productos (política admin_productos): no hace falta función.
--   * catalogo_publico() se redefine COMPLETA desde la versión viva (52) con una sola línea
--     más: en_meta.
-- ============================================================================

alter table productos add column if not exists en_meta boolean not null default false;

CREATE OR REPLACE FUNCTION public.catalogo_publico()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
             -- (88) El catálogo para Meta solo lleva los productos marcados en Inventario.
             'en_meta', p.en_meta,
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
end $function$;

notify pgrst, 'reload schema';

insert into _migraciones (archivo, tipo) values ('88_productos_en_meta.sql', 'esquema')
on conflict (archivo) do nothing;
