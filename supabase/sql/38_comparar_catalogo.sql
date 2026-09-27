-- ---------------------------------------------------------------------------
-- 38_comparar_catalogo.sql — foto de `productos` para comparar contra el Excel del sitio.
--
-- Antes de que el sitio lea el catálogo del CRM (paso 3 de "unir CRM y sitio"), hay que
-- saber qué tan distintos están `productos` (CRM) y el Excel (POWERMX-sitio/Inventario).
-- `02_catalogo.sql` sembró `productos` DESDE ese Excel una sola vez, hace semanas; desde
-- entonces cada uno se pudo haber editado por su cuenta (precios en Inventario del CRM,
-- SKUs y refacciones nuevas en el Excel).
--
-- Es un SELECT, no cambia nada, se puede repetir. Corre en el editor de Supabase con tu
-- sesión (que ve todo, sin RLS) y PEGA el resultado tal cual — un solo bloque JSON — para
-- que seguimos la comparación con el Excel que ya tengo aquí.
-- ---------------------------------------------------------------------------

select jsonb_agg(jsonb_build_object(
  'sku', sku,
  'categoria', categoria,
  'nombre', nombre,
  'marca', marca,
  'precio', precio,
  'costo', costo is not null,        -- si tiene costo capturado, sin mandar el número
  'moneda', moneda,
  'activo', activo,
  'publicar', publicar,
  'grupo_equivalente', grupo_equivalente,
  'actualizado', updated_at
) order by categoria, sku) as productos
from productos;
