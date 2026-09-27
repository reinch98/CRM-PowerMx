-- ---------------------------------------------------------------------------
-- Prueba de 39_catalogo_publico.sql. Correr DESPUÉS del 39, y el bloque COMPLETO.
-- Todo va en begin/rollback: no deja nada.
--
-- SQL plano, sin plpgsql ni `select into` (ver "Pruebas en el editor SQL" en CLAUDE.md).
-- Todos los productos y movimientos de prueba se siembran ANTES de cambiar de rol: el
-- editor los inserta sin pasar por RLS, y el bot no tiene (ni necesita) permiso para
-- escribir en `productos` directo — solo para llamar la función.
--
-- LO QUE NO SE PUEDE PROBAR AQUÍ: técnico y admin comparten el mismo rol de Postgres
-- ('authenticated') que el bot — el candado real es `_es_bot_o_admin()` DENTRO de la
-- función, no un privilegio de Postgres por persona, así que no hay nada que consultar
-- con `has_function_privilege` por usuario. Que un técnico no pueda LANZA una excepción,
-- y atraparla exige plpgsql. Se prueba a mano, corriendo esto SUELTO (sin begin/rollback)
-- con un técnico real:
--
--   select set_config('request.jwt.claims',
--            json_build_object('sub', '<uuid de un técnico>', 'role', 'authenticated')::text, true);
--   set local role authenticated;
--   select catalogo_publico();   -- debe fallar: «Solo el administrador o el conector del sitio.»
-- ---------------------------------------------------------------------------

begin;

select set_config('app.bot',
         coalesce((select id::text from perfiles where rol = 'bot' and coalesce(activo, true) limit 1), ''), true);

select set_config('app.p0',
         case when nullif(current_setting('app.bot'), '') is null then 'FALLO: no hay perfil con rol bot'
              else 'ok — hay una cuenta bot con quien probar' end, true);

-- ---- sembrar TODO el escenario, como el editor (sin RLS) ----
select set_config('app.disp', gen_random_uuid()::text, true),
       set_config('app.agot', gen_random_uuid()::text, true),
       set_config('app.nopub', gen_random_uuid()::text, true),
       set_config('app.nopre', gen_random_uuid()::text, true),
       set_config('app.vend', gen_random_uuid()::text, true),
       set_config('app.rp', gen_random_uuid()::text, true);

insert into productos (id, sku, categoria, nombre, precio, precios, unidad, activo, publicar) values
  (current_setting('app.disp')::uuid, 'PRUEBA-39-DISPONIBLE', 'refaccion', 'Prueba disponible', 100, null, 'pieza', true, true),
  (current_setting('app.agot')::uuid, 'PRUEBA-39-AGOTADO', 'refaccion', 'Prueba agotada', 100, null, 'pieza', true, true),
  (current_setting('app.nopub')::uuid, 'PRUEBA-39-SINPUBLICAR', 'refaccion', 'Prueba sin publicar', 100, null, 'pieza', true, false),
  (current_setting('app.nopre')::uuid, 'PRUEBA-39-SINPRECIO', 'refaccion', 'Prueba sin precio', null, null, 'pieza', true, true),
  (current_setting('app.vend')::uuid, 'PRUEBA-39-VENDIDO', 'refaccion', 'Prueba vendida', 100, null, 'pieza', true, true),
  (current_setting('app.rp')::uuid, 'PRUEBA-39-RENTA', 'renta', 'Prueba renta', null,
   '{"24hr": 400, "48hr": 600}'::jsonb, 'servicio', true, true);

insert into movimientos_inventario (id, tipo, cantidad, producto_id, referencia, notas, created_at) values
  (gen_random_uuid(), 'entrada', 5, current_setting('app.disp')::uuid, 'PRUEBA-39', 'prueba catálogo público', now()),
  (gen_random_uuid(), 'apartado', 2, current_setting('app.disp')::uuid, 'PRUEBA-39', 'prueba catálogo público', now()),
  (gen_random_uuid(), 'entrada', 2, current_setting('app.agot')::uuid, 'PRUEBA-39', 'prueba catálogo público', now()),
  (gen_random_uuid(), 'apartado', 2, current_setting('app.agot')::uuid, 'PRUEBA-39', 'prueba catálogo público', now()),
  -- Una venta apartada y luego vendida: salida_venta resta de FÍSICO y de APARTADO a la
  -- vez. Sumar los casos en un solo total (en vez de tres sumas separadas) daría -1 y
  -- marcaría "agotado" por error; el resultado correcto dice que quedan 2 disponibles.
  (gen_random_uuid(), 'entrada', 5, current_setting('app.vend')::uuid, 'PRUEBA-39', 'prueba catálogo público', now()),
  (gen_random_uuid(), 'apartado', 3, current_setting('app.vend')::uuid, 'PRUEBA-39', 'prueba catálogo público', now()),
  (gen_random_uuid(), 'salida_venta', 3, current_setting('app.vend')::uuid, 'PRUEBA-39', 'prueba catálogo público', now());

-- ---- como el BOT ----
select set_config('request.jwt.claims',
         json_build_object('sub', current_setting('app.bot'), 'role', 'authenticated', 'email', 'bot@prueba')::text, true);
set local role authenticated;

select set_config('app.cat', catalogo_publico()::text, true);

select set_config('app.p1', concat(
         case when current_setting('app.cat')::jsonb @> jsonb_build_array(jsonb_build_object('sku', 'PRUEBA-39-DISPONIBLE', 'disponible', true))
              then 'ok' else 'FALLO' end,
         ' — el disponible (5 entrada − 2 apartado = 3) sale como disponible: true'), true);

select set_config('app.p2', concat(
         case when current_setting('app.cat')::jsonb @> jsonb_build_array(jsonb_build_object('sku', 'PRUEBA-39-AGOTADO', 'disponible', false))
              then 'ok' else 'FALLO' end,
         ' — el agotado (2 entrada − 2 apartado = 0) sale como disponible: false'), true);

select set_config('app.p3', concat(
         case when not exists (
                select 1 from jsonb_array_elements(current_setting('app.cat')::jsonb) e
                 where e ->> 'sku' = 'PRUEBA-39-SINPUBLICAR')
              then 'ok' else 'FALLO' end,
         ' — el que tiene publicar=false no sale'), true);

-- Decisión de Caña el 27/09/2026: "todo el catálogo debe publicarse" — sin precio SÍ
-- sale (con precio en null; el sitio muestra "Precio a consultar" y cotizar por WhatsApp).
-- Lo único que sigue vetando es publicar=false (p3) y activo=false.
select set_config('app.p4', concat(
         case when current_setting('app.cat')::jsonb @> jsonb_build_array(jsonb_build_object('sku', 'PRUEBA-39-SINPRECIO', 'precio', null::jsonb))
              then 'ok' else 'FALLO' end,
         ' — el que no tiene precio SÍ sale, con precio en null'), true);

select set_config('app.p5', concat(
         case when not exists (
                select 1 from jsonb_array_elements(current_setting('app.cat')::jsonb) e,
                     jsonb_object_keys(e) k
                 where k in ('costo', 'fisico', 'apartado', 'resguardo', 'minimo'))
              then 'ok' else 'FALLO' end,
         ' — ninguna fila trae costo, físico, apartado, resguardo ni mínimo'), true);

select set_config('app.p6', concat(
         case when current_setting('app.cat')::jsonb @> jsonb_build_array(jsonb_build_object('sku', 'PRUEBA-39-VENDIDO', 'disponible', true))
              then 'ok' else 'FALLO' end,
         ' — 5 entrada, 3 apartado y 3 salida_venta: quedan 2 físicos sin apartar, disponible: true'), true);

select set_config('app.p7', concat(
         case when exists (
                select 1 from jsonb_array_elements(current_setting('app.cat')::jsonb) e
                 where e ->> 'sku' = 'PRUEBA-39-RENTA' and (e -> 'precios' ->> '24hr') = '400')
              then 'ok' else 'FALLO' end,
         ' — una renta sin precio plano pero con `precios` jsonb sí sale, con su tarifa'), true);

reset role;
select set_config('app.p8', concat(
         case when not has_function_privilege('anon', 'catalogo_publico()', 'execute')
              then 'ok' else 'FALLO' end,
         ' — anon no puede ejecutar catalogo_publico()'), true);

select current_setting('app.p0') as p0,
       current_setting('app.p1') as p1,
       current_setting('app.p2') as p2,
       current_setting('app.p3') as p3,
       current_setting('app.p4') as p4,
       current_setting('app.p5') as p5,
       current_setting('app.p6') as p6,
       current_setting('app.p7') as p7,
       current_setting('app.p8') as p8;

rollback;
