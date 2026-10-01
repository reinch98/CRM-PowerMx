-- Prueba de 52_disponibilidad_y_promociones.sql. Correr DESPUÉS del 52, el bloque completo.
-- begin/rollback. SQL plano, sin bloques plpgsql (el editor de Supabase los mutila).
--
-- Escenario, con tipo de cambio 20, regla de 30 % SOBRE EL COSTO y la promoción en 40 % / 5 % / 200 días
-- (se fijan dentro de la transacción; el rollback deja todo como estaba):
--   P52A  repetido: XLStore 100 USD (2,000), 3 en Mérida; Solarama 70 USD (1,400).
--         Precio normal 2,000 × 1.30 = 2,600 · costo 1,400 · promoción 1,400 × 1.40 = 1,960 (24.6 % menos).
--   P52B  repetido: XLStore 100 USD, solo existencia nacional; Solarama 95 USD → 1,900 × 1.40 = 2,660,
--         más caro que el normal (2,600): NO es promoción.
--   P52C  solo Solarama, 50 USD → 1,000 × 1.30 = 1,300; sobre pedido.
-- Los conteos de las sincronizaciones no se comparan: en la base real hay cientos de productos con
-- precio automático que también se recalculan dentro de la prueba. Se revisan solo los de la prueba.
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

-- 1. La regla general quedó sobre el costo ---------------------------------------------------------
select set_config('app.p1', concat(
  (select concat(margen_pct, ' % sobre el ', sobre) from reglas_margen
    where activo and categoria is null and marca is null limit 1),
  ' (esperado: 30 % sobre el costo)'), true);

update reglas_margen set activo = false where activo;
insert into reglas_margen (categoria, marca, margen_pct, margen_minimo_mxn, redondeo, sobre)
values (null, null, 30, 0, 1, 'costo');
update parametros_costeo set valor = 40 where clave = 'promo_margen_pct';
update parametros_costeo set valor = 5 where clave = 'promo_descuento_minimo_pct';
update parametros_costeo set valor = 200 where clave = 'promo_vigencia_lista_dias';

insert into proveedor_productos (proveedor, sku_proveedor, nombre, categoria, costo, moneda, stock_local, stock_proveedor, vigente) values
  ('xlstore',  'P52A-XL',  'Repetido barato en Solarama', 'Inversores', 100, 'USD', 3, 40, true),
  ('solarama', 'P52A SOL', 'Repetido barato en Solarama', 'Inversores',  70, 'USD', null, null, true),
  ('xlstore',  'P52B-XL',  'Repetido parejo',             'Inversores', 100, 'USD', 0, 12, true),
  ('solarama', 'P52B SOL', 'Repetido parejo',             'Inversores',  95, 'USD', null, null, true),
  ('solarama', 'P52C SOL', 'Solo Solarama',               'Inversores',  50, 'USD', null, null, true);
insert into productos (sku, categoria, nombre, proveedor, proveedor_sku, precio_auto, precio, publicar, atributos) values
  ('P52A', 'inversor', 'Repetido barato en Solarama', 'xlstore',  'P52A-XL',  true, 2600, true, '{"origen":"proveedor"}'),
  ('P52B', 'inversor', 'Repetido parejo',             'xlstore',  'P52B-XL',  true, 2600, true, '{"origen":"proveedor"}'),
  ('P52C', 'inversor', 'Solo Solarama',               'solarama', 'P52C SOL', true, 1300, true, '{"origen":"proveedor"}');
select vincular_producto_proveedor((select id from productos where sku = 'P52A'), 'solarama', 'P52A SOL', true);
select vincular_producto_proveedor((select id from productos where sku = 'P52B'), 'solarama', 'P52B SOL', true);

-- 2. Una sincronización de XLStore calcula la promoción -------------------------------------------------
select set_config('app.corrida', sync_iniciar('xlstore', 'prueba52')::text, true);
update proveedor_productos set corrida_id = current_setting('app.corrida')::uuid where proveedor = 'xlstore';
update sync_corridas set estado = 'leida', filas = 2 where id = current_setting('app.corrida')::uuid;
select sync_aplicar(current_setting('app.corrida')::uuid, 20);
select set_config('app.p2', concat(
  (select concat(precio, ' / costo ', costo, ' / promo ', coalesce(precio_promocion::text, 'ninguna'), ' / opción 1 ', proveedor)
     from productos where sku = 'P52A'), ' ; ',
  (select concat(precio, ' / promo ', coalesce(precio_promocion::text, 'ninguna')) from productos where sku = 'P52B'),
  ' (esperado: 2600 / costo 1400.00 / promo 1960 / opción 1 solarama ; 2600 / promo ninguna)'), true);

-- 3. Lo que solo vende Solarama también sigue el tipo de cambio de la lectura de XLStore ---------------------
select set_config('app.corrida2', sync_iniciar('xlstore', 'prueba52')::text, true);
update proveedor_productos set corrida_id = current_setting('app.corrida2')::uuid where proveedor = 'xlstore';
update sync_corridas set estado = 'leida', filas = 2 where id = current_setting('app.corrida2')::uuid;
select sync_aplicar(current_setting('app.corrida2')::uuid, 21);
select set_config('app.p3', concat(
  (select concat(precio, ' / costo ', costo) from productos where sku = 'P52C'),
  ' (esperado: 1365 / costo 1050.00 — 50 USD × 21 × 1.30)'), true);

-- 4. Una lista de Solarama vieja apaga la promoción ------------------------------------------------------------
update proveedor_productos set leido_en = now() - interval '300 days' where proveedor = 'solarama' and sku_proveedor = 'P52A SOL';
select set_config('app.corrida3', sync_iniciar('xlstore', 'prueba52')::text, true);
update proveedor_productos set corrida_id = current_setting('app.corrida3')::uuid where proveedor = 'xlstore';
update sync_corridas set estado = 'leida', filas = 2 where id = current_setting('app.corrida3')::uuid;
select sync_aplicar(current_setting('app.corrida3')::uuid, 20);
select set_config('app.p4', concat(
  (select coalesce(precio_promocion::text, 'ninguna') from productos where sku = 'P52A'),
  ' (esperado: ninguna — la lista de Solarama tiene 300 días y el tope es 200)'), true);
update proveedor_productos set leido_en = now() where proveedor = 'solarama' and sku_proveedor = 'P52A SOL';
select set_config('app.corrida4', sync_iniciar('xlstore', 'prueba52')::text, true);
update proveedor_productos set corrida_id = current_setting('app.corrida4')::uuid where proveedor = 'xlstore';
update sync_corridas set estado = 'leida', filas = 2 where id = current_setting('app.corrida4')::uuid;
select sync_aplicar(current_setting('app.corrida4')::uuid, 20);

-- 5. El catálogo del sitio: disponibilidad, existencias del proveedor y precio de promoción ----------------------
select set_config('app.cat', (
  select jsonb_agg(e order by e ->> 'sku') from jsonb_array_elements(catalogo_publico()) e
   where e ->> 'sku' in ('P52A', 'P52B', 'P52C'))::text, true);
select set_config('app.p5', concat(
  (select string_agg(concat(e ->> 'sku', ' ', e ->> 'disponibilidad', ' ', e ->> 'disponible', ' ',
                            coalesce(e ->> 'precio_promocion', '-'), ' existencia ',
                            coalesce(e ->> 'existencia_merida', '-'), '/', coalesce(e ->> 'existencia_nacional', '-')),
                    ' ; ' order by e ->> 'sku')
     from jsonb_array_elements(current_setting('app.cat')::jsonb) e),
  ' | ', (select count(*) from jsonb_array_elements(current_setting('app.cat')::jsonb) e
           where e ? 'stock_local' or e ? 'costo' or e ? 'stock_proveedor'), ' campos privados',
  ' (esperado: P52A inmediata true 1960 existencia 3/40 ; P52B proveedor true - existencia -/12 ; P52C pedido false - existencia -/- | 0 campos privados)'), true);

-- 6. Quitar un proveedor apaga la promoción hasta la siguiente sincronización ------------------------------------
select vincular_producto_proveedor((select id from productos where sku = 'P52A'), 'solarama', null, true);
select set_config('app.p6', concat(
  (select concat(coalesce(precio_promocion::text, 'ninguna'), ' / auto=', precio_auto) from productos where sku = 'P52A'),
  ' (esperado: ninguna / auto=true)'), true);

select concat_ws(E'\n',
  '1 ' || current_setting('app.p1'),
  '2 ' || current_setting('app.p2'),
  '3 ' || current_setting('app.p3'),
  '4 ' || current_setting('app.p4'),
  '5 ' || current_setting('app.p5'),
  '6 ' || current_setting('app.p6')) as resultado;

rollback;
