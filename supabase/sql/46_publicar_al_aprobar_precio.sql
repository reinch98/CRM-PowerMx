-- ---------------------------------------------------------------------------
-- 46_publicar_al_aprobar_precio.sql — el primer precio aprobado PUBLICA el producto.
--
-- Decisión de Caña (29/09/2026): los productos que se traen del proveedor (SQL 45) entran sin
-- publicar y "se publican cuando tengan precio". Pero nada lo hacía: aprobar un precio en la cola
-- (44) escribía precio y costo y dejaba `publicar = false`, así que ningún producto del proveedor
-- llegaría jamás al sitio.
--
-- Regla, en `_aplicar_precio` (la única puerta por la que el sync y la cola escriben precio):
--   · se publica SOLO si el producto venía del proveedor (`atributos.origen = 'proveedor'`),
--     todavía no tenía precio y está sin publicar;
--   · un producto que el admin retiró del sitio teniendo precio (por ejemplo, "Retirar del sitio"
--     porque el proveedor ya no lo lista) NO se vuelve a publicar solo cuando cambie su precio;
--   · un producto de PowerMx de siempre (sin ese origen) nunca se publica desde aquí.
--
-- Misma firma que en la 44: create or replace, repetible.
-- ---------------------------------------------------------------------------

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
  insert into historial_precios (producto_id, precio_anterior, precio_nuevo,
                                 costo_anterior, costo_nuevo, tipo_cambio, origen, corrida_id)
  values (p_producto, v_p.precio, v_precio, v_p.costo, v_costo, p_tc, p_origen, p_corrida);
  perform _apunta('productos', p_producto, 'precio_por_proveedor',
                  jsonb_build_object('precio', v_p.precio, 'costo', v_p.costo),
                  jsonb_build_object('precio', v_precio, 'costo', v_costo, 'origen', p_origen,
                                     'publicado', v_publica),
                  'sync');
end $fn$;
revoke all on function _aplicar_precio(uuid, jsonb, text, uuid, numeric) from public, anon, authenticated;
