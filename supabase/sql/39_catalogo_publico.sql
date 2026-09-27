-- ---------------------------------------------------------------------------
-- 39_catalogo_publico.sql — el CRM como fuente del catálogo del sitio (paso 3 de
-- "unir CRM y sitio"). Reemplaza al Excel como origen de precios y disponibilidad;
-- las fotos y fichas técnicas se siguen sirviendo desde POWERMX-sitio/Inventario.
--
-- Mismo patrón que registrar_solicitud_web: una función security definer que solo
-- puede llamar la cuenta `bot` (o el admin), nunca `anon`. `convertir.js` la llama
-- por lotes al construirse el sitio (GitHub Action o la compu de Caña) — NO la llama
-- el navegador de un visitante, así que no hace falta abrir una puerta pública nueva
-- en la base ni pensar en caché de tráfico.
--
-- Lo que NUNCA sale de aquí: costo, el físico exacto (solo "disponible" en booleano) ni
-- productos con publicar=false. **Sí sale sin precio** (decisión de Caña el 27/09/2026:
-- "todo el catálogo debe publicarse, lo que no tenga stock debe decir sobre pedido") — el
-- sitio ya sabe mostrar "Precio a consultar" y un botón de cotizar en vez de un precio, y
-- "Sobre pedido" en vez de "no disponible" cuando el disponible da 0. No publicar por falta
-- de precio se sentía raro: la refacción existe, se puede pedir, solo falta capturarle un
-- precio — eso no debería esconderla del catálogo.
--
-- Repetible: create or replace.
-- ---------------------------------------------------------------------------

create or replace function catalogo_publico()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_resultado jsonb;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector del sitio.' using errcode = '42501';
  end if;

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
           -- Disponible = físico − apartado − resguardo, la MISMA fórmula que la vista
           -- `existencias` (calculada aquí directo, con las tres sumas por separado,
           -- porque esa vista es invoker y desde una función de la cuenta bot se vería
           -- vacía: ver CLAUDE.md, "Modo de las vistas"). Ojo: no es una sola suma —
           -- salida_venta resta de físico Y de apartado a la vez, entre otros cruces;
           -- juntar los casos en una sola suma da un número distinto y equivocado.
           'disponible', coalesce((
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
           ), 0) > 0
         ) order by p.categoria, p.sku), '[]'::jsonb)
    into v_resultado
    from productos p
   where p.activo
     and p.publicar;

  return v_resultado;
end $$;

revoke all on function catalogo_publico() from public, anon;
grant execute on function catalogo_publico() to authenticated;
