-- Prueba de 50_sync_conserva_documentos.sql. Correr DESPUÉS del 44 y el 50, el bloque completo. begin/rollback.
-- SQL plano, sin bloques plpgsql. Como admin.
--
--   1ª lectura: P1 con imagen y fichas        → se guardan
--   2ª lectura: P1 sin imagen ni documentos   → se CONSERVAN (la lectura rápida no los trae)
--   3ª lectura: P1 con otra imagen y otra ficha → se REEMPLAZAN (un valor nuevo sí cuenta)
--   y el costo y las existencias sí se actualizan en cada lectura.
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

select set_config('app.c1', sync_iniciar('prueba50', 'prueba')::text, true);
select set_config('app.n1', sync_recibir_lote(current_setting('app.c1')::uuid, '[
  {"sku_proveedor":"P1","nombre":"Panel","costo":100,"moneda":"USD","stock_local":1,"stock_proveedor":10,
   "url_imagen":"https://x/p1.png","documentos":{"ficha_tecnica":["https://x/p1.pdf"]}}]'::jsonb)::text, true);
select set_config('app.p1', concat(
  (select url_imagen from proveedor_productos where sku_proveedor = 'P1' and proveedor = 'prueba50'), ' | ',
  (select documentos::text from proveedor_productos where sku_proveedor = 'P1' and proveedor = 'prueba50'),
  ' (esperado: https://x/p1.png | {"ficha_tecnica": ["https://x/p1.pdf"]})'), true);

select set_config('app.c2', sync_iniciar('prueba50', 'prueba')::text, true);
select set_config('app.n2', sync_recibir_lote(current_setting('app.c2')::uuid, '[
  {"sku_proveedor":"P1","nombre":"Panel","costo":120,"moneda":"USD","stock_local":0,"stock_proveedor":7}]'::jsonb)::text, true);
select set_config('app.p2', concat(
  (select url_imagen from proveedor_productos where sku_proveedor = 'P1' and proveedor = 'prueba50'), ' | ',
  (select documentos::text from proveedor_productos where sku_proveedor = 'P1' and proveedor = 'prueba50'), ' | costo ',
  (select costo from proveedor_productos where sku_proveedor = 'P1' and proveedor = 'prueba50'), ' stock ',
  (select stock_local from proveedor_productos where sku_proveedor = 'P1' and proveedor = 'prueba50'),
  ' (esperado: lo mismo de antes | costo 120 stock 0 — imagen y fichas se conservan; costo y stock sí cambian)'), true);

select set_config('app.c3', sync_iniciar('prueba50', 'prueba')::text, true);
select set_config('app.n3', sync_recibir_lote(current_setting('app.c3')::uuid, '[
  {"sku_proveedor":"P1","nombre":"Panel","costo":120,"moneda":"USD",
   "url_imagen":"https://x/nueva.png","documentos":{"ficha_tecnica":["https://x/nueva.pdf"]}}]'::jsonb)::text, true);
select set_config('app.p3', concat(
  (select url_imagen from proveedor_productos where sku_proveedor = 'P1' and proveedor = 'prueba50'), ' | ',
  (select documentos::text from proveedor_productos where sku_proveedor = 'P1' and proveedor = 'prueba50'),
  ' (esperado: https://x/nueva.png | {"ficha_tecnica": ["https://x/nueva.pdf"]})'), true);

select concat_ws(E'\n', '1 ' || current_setting('app.p1'), '2 ' || current_setting('app.p2'),
  '3 ' || current_setting('app.p3')) as resultado;

rollback;
