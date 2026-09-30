-- ---------------------------------------------------------------------------
-- 43_quitar_producto.sql — quitar un artículo del inventario.
--
-- Borrar de verdad solo es posible si el producto NUNCA se movió: el inventario es un libro
-- de movimientos y cada uno apunta a su producto (llave foránea). Si tiene historia, borrarlo
-- rompería entradas, entregas, pedidos y compras viejas, así que se DESACTIVA: deja de salir en
-- Inventario, en cotizaciones y en el sitio, pero la historia queda intacta y se puede reactivar.
--
--   quitar_producto(id) -> 'eliminado' | 'desactivado' | 'sin_cambio'
--
-- Solo admin. Queda en `auditoria`. Se puede repetir.
-- ---------------------------------------------------------------------------

create or replace function quitar_producto(p_producto uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prod productos%rowtype;
  v_usos int;
begin
  if not es_admin() then
    raise exception 'Solo el administrador puede quitar artículos.' using errcode = '42501';
  end if;

  v_prod := (select p from productos p where p.id = p_producto);
  if v_prod.id is null then
    raise exception 'Ese artículo ya no existe.' using errcode = '22023';
  end if;

  v_usos :=
      (select count(*) from movimientos_inventario where producto_id = p_producto)
    + (select count(*) from entrega_lineas         where producto_id = p_producto)
    + (select count(*) from orden_surtido          where producto_id = p_producto)
    + (select count(*) from paquete_lineas         where producto_id = p_producto)
    + (select count(*) from requisiciones          where producto_id = p_producto)
    + (select count(*) from solicitudes_material   where producto_id = p_producto)
    + (select count(*) from compra_lineas          where producto_id = p_producto);

  if v_usos = 0 then
    delete from productos where id = p_producto;
    perform _apunta('productos', p_producto, 'eliminar',
                    jsonb_build_object('sku', v_prod.sku, 'nombre', v_prod.nombre),
                    null, 'oficina');
    return 'eliminado';
  end if;

  if not coalesce(v_prod.activo, true) then
    return 'sin_cambio';
  end if;

  update productos set activo = false, publicar = false where id = p_producto;
  perform _apunta('productos', p_producto, 'desactivar',
                  jsonb_build_object('activo', true, 'publicar', v_prod.publicar),
                  jsonb_build_object('activo', false, 'publicar', false), 'oficina');
  return 'desactivado';
end;
$$;

revoke all on function quitar_producto(uuid) from public;
revoke all on function quitar_producto(uuid) from anon;
grant execute on function quitar_producto(uuid) to authenticated;

notify pgrst, 'reload schema';
