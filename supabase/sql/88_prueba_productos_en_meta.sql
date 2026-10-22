-- Prueba de 88_productos_en_meta.sql. Correr DESPUÉS del 88, el bloque COMPLETO, con la CLI:
--   npx supabase db query --linked -f supabase/sql/88_prueba_productos_en_meta.sql
-- begin/rollback: los productos de prueba "P88" no quedan.
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

insert into productos (sku, nombre, categoria, unidad, precio, activo, publicar)
values ('P88-A', 'Producto PRUEBA88 A', 'refaccion', 'pieza', 100, true, true),
       ('P88-B', 'Producto PRUEBA88 B', 'refaccion', 'pieza', 200, true, true);

-- 1) Nace apagado: nada sale a Meta sin marcarlo.
select set_config('app.p1', concat(
  case when (select bool_and(not en_meta) from productos where sku in ('P88-A', 'P88-B'))
       then 'ok' else 'FALLO' end, ' — un producto nuevo nace sin ir a Meta'), true);

-- 2) Marcado uno, catalogo_publico lo dice para ese y no para el otro.
update productos set en_meta = true where sku = 'P88-A';
select set_config('app.p2', concat(
  case when (select (e ->> 'en_meta')::boolean from jsonb_array_elements(catalogo_publico()) e where e ->> 'sku' = 'P88-A')
        and not (select (e ->> 'en_meta')::boolean from jsonb_array_elements(catalogo_publico()) e where e ->> 'sku' = 'P88-B')
       then 'ok' else 'FALLO' end, ' — catalogo_publico manda en_meta por producto'), true);

-- 3) El resto del catálogo sigue saliendo igual (el sitio publica todo, marcado o no).
select set_config('app.p3', concat(
  case when (select count(*) from jsonb_array_elements(catalogo_publico()) e where e ->> 'sku' like 'P88-%') = 2
       then 'ok' else 'FALLO' end, ' — los dos siguen en el catálogo del sitio'), true);

select current_setting('app.p1') as p1, current_setting('app.p2') as p2, current_setting('app.p3') as p3;

rollback;
