-- Prueba de 51_segundo_proveedor.sql. Correr DESPUÉS del 51, el bloque completo.
-- begin/rollback. SQL plano, sin bloques plpgsql (el editor de Supabase los mutila).
--
-- Escenario, con tipo de cambio 20 y una regla general de 30 % SOBRE EL PRECIO DE VENTA:
--   P51A  repetido: XLStore cuesta 100 USD (2,000) y Solarama 80 USD (1,600).
--         → costo 1,600 (Solarama, opción 1); precio 2,000 / 0.70 = 2,857.14 → 2,858.
--   P51B  solo en Solarama ("KIT 51° B"): al traerlo nace como SLR-KIT-51-B.
-- Las reglas que ya hubiera se apagan DENTRO de la transacción para que el escenario no dependa de
-- ellas; el rollback las deja como estaban.
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

update reglas_margen set activo = false where activo;
insert into reglas_margen (categoria, marca, margen_pct, margen_minimo_mxn, redondeo, sobre)
values (null, null, 30, 0, 1, 'precio'),
       ('prueba51', null, 35, 0, 1, 'costo');

-- 1. La fórmula: 30 % sobre el precio y 35 % sobre el costo ------------------------------------------
select set_config('app.p1', concat(
  _precio_venta(1000, (select r from reglas_margen r where activo and categoria is null and marca is null)),
  ' / ',
  _precio_venta(1000, (select r from reglas_margen r where activo and categoria = 'prueba51')),
  ' (esperado: 1429 / 1350)'), true);

-- 2. Un producto con dos proveedores -----------------------------------------------------------------
insert into proveedor_productos (proveedor, sku_proveedor, nombre, categoria, costo, moneda, vigente) values
  ('xlstore',  'P51A-XL',   'Inversor repetido', 'Inversores', 100, 'USD', true),
  ('solarama', 'P51A SOL',  'Inversor repetido', 'Inversores',  80, 'USD', true),
  ('solarama', 'KIT 51° B', 'Kit solo Solarama', 'Sistemas de montaje', 10, 'USD', true);
insert into productos (sku, categoria, nombre, proveedor, proveedor_sku, precio_auto, precio, atributos)
values ('P51A', 'inversor', 'Inversor repetido', 'xlstore', 'P51A-XL', true, 2700, '{"origen":"proveedor"}');
select set_config('app.r2', vincular_producto_proveedor(
  (select id from productos where sku = 'P51A'), 'solarama', 'P51A SOL', true), true);
select set_config('app.c2', _calcular_precio((select id from productos where sku = 'P51A'), 20)::text, true);
select set_config('app.p2', concat(
  current_setting('app.r2'), ' — costo ', current_setting('app.c2')::jsonb ->> 'costo_mxn',
  ' de ', current_setting('app.c2')::jsonb ->> 'proveedor',
  ', precio ', current_setting('app.c2')::jsonb ->> 'precio',
  ' (lo marca ', current_setting('app.c2')::jsonb ->> 'proveedor_precio', '), vínculos: ',
  (select count(*) from producto_proveedores where producto_id = (select id from productos where sku = 'P51A')),
  ' (esperado: ok — costo 1600.00 de solarama, precio 2858 (lo marca xlstore), vínculos: 2)'), true);

-- 3. El sync de Solarama aplica el precio y deja a Solarama como opción 1 ---------------------------------
select set_config('app.corrida', sync_iniciar('solarama', 'prueba51')::text, true);
update proveedor_productos set corrida_id = current_setting('app.corrida')::uuid where proveedor = 'solarama';
update sync_corridas set estado = 'leida', filas = 2 where id = current_setting('app.corrida')::uuid;
-- El conteo total de la corrida NO se compara: en la base real los repetidos ya ligados a Solarama (y,
-- desde la 52, todo lo que tiene proveedor) también se recalculan aquí. Se revisa solo P51A.
select set_config('app.r3', sync_aplicar(current_setting('app.corrida')::uuid, 20)::text, true);
select set_config('app.p3', concat(
  'precio de P51A aplicado ',
  (select count(*) from historial_precios where producto_id = (select id from productos where sku = 'P51A')
      and corrida_id = current_setting('app.corrida')::uuid), ' vez — ',
  (select concat(precio, ' / ', costo, ' / opción 1: ', proveedor, ' ', proveedor_sku) from productos where sku = 'P51A'),
  ' / ',
  (select string_agg(concat(proveedor, '=', opcion, ' (', costo_mxn, ')'), ', ' order by opcion)
     from producto_proveedores where producto_id = (select id from productos where sku = 'P51A')),
  ' (esperado: precio de P51A aplicado 1 vez — 2858 / 1600.00 / opción 1: solarama P51A SOL / solarama=1 (1600.00), xlstore=2 (2000.00))'), true);

-- 4. Si Solarama deja de listarlo, XLStore lo sigue vendiendo: NO va a "ya no lo lista" -------------------
select set_config('app.corrida2', sync_iniciar('solarama', 'prueba51')::text, true);
update proveedor_productos set corrida_id = current_setting('app.corrida2')::uuid
 where proveedor = 'solarama' and sku_proveedor = 'KIT 51° B';
update sync_corridas set estado = 'leida', filas = 1 where id = current_setting('app.corrida2')::uuid;
select set_config('app.r4', sync_aplicar(current_setting('app.corrida2')::uuid, 20)::text, true);
select set_config('app.p4', concat(
  (select count(*) from cola_revision where estado = 'pendiente' and tipo = 'sku_desaparecido'
      and producto_id = (select id from productos where sku = 'P51A')), ' desaparecidos; ',
  (select concat(precio, ' / ', costo, ' / ', proveedor) from productos where sku = 'P51A'),
  ' (esperado: 0 desaparecidos; 2858 / 2000.00 / xlstore — sin Solarama, el costo y la opción 1 son de XLStore)'), true);

-- 5. Traer productos de Solarama: SKU con prefijo y sin símbolos; el repetido no se duplica ---------------------
update proveedor_productos set vigente = true where proveedor = 'solarama';
select set_config('app.r5', importar_productos_proveedor('solarama')::text, true);
select set_config('app.p5', concat(
  current_setting('app.r5'), ' — ',
  coalesce((select concat(sku, ' | ', categoria, ' | ', proveedor, ' ', proveedor_sku, ' | ', publicar)
              from productos where sku = 'SLR-KIT-51-B'), 'NO SE CREÓ'), ' | opción ',
  (select opcion from producto_proveedores where proveedor = 'solarama' and proveedor_sku = 'KIT 51° B'),
  ' (esperado: creados 1, ya_existian 1 — SLR-KIT-51-B | accesorio_solar | solarama KIT 51° B | false | opción 1)'), true);

-- 6. Un código del proveedor sigue a un solo producto -----------------------------------------------------
select set_config('app.p6', concat(
  (select count(*) from producto_proveedores where proveedor = 'solarama' and proveedor_sku = 'P51A SOL'),
  ' vínculo para P51A SOL; espejo por disparador: ',
  (select count(*) from producto_proveedores l join productos p on p.id = l.producto_id
    where p.sku = 'P51A' and l.proveedor = 'xlstore'),
  ' (esperado: 1 vínculo; 1 — el de XLStore sigue)'), true);

-- 7. Quitar a un proveedor deja al otro y no apaga el precio automático ---------------------------------------
select set_config('app.r7', vincular_producto_proveedor(
  (select id from productos where sku = 'P51A'), 'solarama', null, false), true);
select set_config('app.p7', concat(
  current_setting('app.r7'), ' — ',
  (select concat(proveedor, ' ', proveedor_sku, ' auto=', precio_auto) from productos where sku = 'P51A'),
  ' (esperado: ok — xlstore P51A-XL auto=true)'), true);

-- 8. Parámetros de costeo: siete, con la mano de obra del borrador; editar deja rastro -------------------------
select set_config('app.r8', fijar_parametro_costeo('mano_obra_panel', 900), true);
select set_config('app.p8', concat(
  (select count(*) from parametros_costeo where clave not like 'promo_%'), ' parámetros; ',
  (select valor from parametros_costeo where clave = 'mano_obra_panel'), ' por panel (', current_setting('app.r8'), '); ',
  fijar_parametro_costeo('mano_obra_panel', 900), '; auditoría ',
  (select count(*) from auditoria where tabla = 'parametros_costeo' and accion = 'fijar_parametro'),
  ' (esperado: 7 parámetros; 900 por panel (ok); sin_cambio; auditoría 1)'), true);

-- 9. Un técnico no ve los parámetros ni los vínculos ---------------------------------------------------------
select set_config('app.tecnico',
  coalesce((select id::text from perfiles where rol = 'tecnico' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.tecnico'), 'role', 'authenticated')::text, true);
set local role authenticated;
select set_config('app.p9', concat(
  (select count(*) from parametros_costeo), ' parámetros y ',
  (select count(*) from producto_proveedores), ' vínculos visibles',
  ' (esperado: 0 y 0)'), true);
reset role;

select concat_ws(E'\n',
  '1 ' || current_setting('app.p1'),
  '2 ' || current_setting('app.p2'),
  '3 ' || current_setting('app.p3'),
  '4 ' || current_setting('app.p4'),
  '5 ' || current_setting('app.p5'),
  '6 ' || current_setting('app.p6'),
  '7 ' || current_setting('app.p7'),
  '8 ' || current_setting('app.p8'),
  '9 ' || current_setting('app.p9')) as resultado;

rollback;
