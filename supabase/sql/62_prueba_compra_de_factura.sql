-- Prueba de 62_compra_de_factura.sql. Correr DESPUÉS del 62, el bloque COMPLETO. begin/rollback.
-- SQL plano; la función que escribe y sus comprobaciones van en sentencias distintas.
-- Consume folios (las secuencias no se revierten con el rollback).
--
-- El caso: una factura de "Prov 62" con una pieza que YA existe (2 × $100) y una pieza NUEVA
-- (5 × $40). Subtotal 400, IVA 16 % = 64, total 464.
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

select set_config('app.a', gen_random_uuid()::text, true);
insert into productos (id, sku, nombre, categoria, costo, activo)
values (current_setting('app.a')::uuid, 'P62-A', 'Pieza que ya existe', 'refaccion', 90, true);

select set_config('app.r1', registrar_compra_de_factura(
  jsonb_build_object('proveedor', 'Prov 62', 'factura', 'F-62-1', 'fecha', '2026-10-07',
                     'archivo_pdf', 'lecturas/prueba-62.pdf'),
  jsonb_build_array(
    jsonb_build_object('producto_id', current_setting('app.a'), 'codigo', 'XA-1',
                       'cantidad', 2, 'costo_unitario', 100),
    jsonb_build_object('nuevo', jsonb_build_object('sku', ' p62-new ', 'nombre', 'Pieza nueva de la factura',
                                                   'categoria', 'refaccion', 'unidad', 'pza'),
                       'codigo', 'XN-9', 'cantidad', 5, 'costo_unitario', 40)
  ))::text, true);

-- 1) La compra se registró con sus totales y dijo cuántas piezas y códigos guardó.
select set_config('app.p1', concat(
  case when (current_setting('app.r1')::jsonb ->> 'ok') = 'true'
        and (current_setting('app.r1')::jsonb ->> 'subtotal')::numeric = 400
        and (current_setting('app.r1')::jsonb ->> 'total')::numeric = 464
        and (current_setting('app.r1')::jsonb ->> 'productos_nuevos')::int = 1
        and (current_setting('app.r1')::jsonb ->> 'codigos_guardados')::int = 2
       then 'ok' else 'FALLO' end,
  ' — ', current_setting('app.r1')), true);

-- 2) La pieza nueva: SKU en mayúsculas y sin espacios, SIN publicar, ligada al proveedor y su código.
select set_config('app.p2', concat(
  case when (select count(*) from productos
              where sku = 'P62-NEW' and publicar is false and activo is true
                and proveedor = 'Prov 62' and proveedor_sku = 'XN-9'
                and nombre = 'Pieza nueva de la factura') = 1
       then 'ok' else 'FALLO' end,
  ' — la pieza nueva existe, sin publicar y con el SKU del proveedor'), true);

-- 3) Los dos códigos del proveedor quedaron guardados para empatar la próxima factura.
select set_config('app.p3', concat(
  case when (select count(*) from producto_proveedores
              where proveedor = 'Prov 62' and proveedor_sku in ('XA-1', 'XN-9')) = 2
       then 'ok' else 'FALLO' end,
  ' — códigos del proveedor guardados'), true);

-- 4) Entró al almacén: 5 de la nueva y 2 de la existente, con la referencia de la compra.
select set_config('app.p4', concat(
  case when (select coalesce(sum(m.cantidad), 0) from movimientos_inventario m
               join productos p on p.id = m.producto_id
              where p.sku = 'P62-NEW' and m.tipo = 'entrada'
                and m.referencia = 'COMPRA-' || (current_setting('app.r1')::jsonb ->> 'folio')) = 5
        and (select coalesce(sum(cantidad), 0) from movimientos_inventario
              where producto_id = current_setting('app.a')::uuid and tipo = 'entrada'
                and referencia = 'COMPRA-' || (current_setting('app.r1')::jsonb ->> 'folio')) = 2
       then 'ok' else 'FALLO' end,
  ' — las entradas al almacén general (5 y 2)'), true);

-- 5) Costos: la pieza nueva toma el costo de la factura (es el primero); la que ya existía NO se pisa.
select set_config('app.p5', concat(
  case when (select costo from productos where sku = 'P62-NEW') = 40
        and (select costo from productos where id = current_setting('app.a')::uuid) = 90
       then 'ok' else 'FALLO' end,
  ' — costo de la nueva = 40; la existente sigue en 90 (no se actualizó sin pedirlo)'), true);

-- 6) El archivo de la factura quedó en la compra.
select set_config('app.p6', concat(
  case when (select archivo_pdf from compras where id = (current_setting('app.r1')::jsonb ->> 'id')::uuid)
              = 'lecturas/prueba-62.pdf'
       then 'ok' else 'FALLO' end,
  ' — el archivo de la factura quedó ligado a la compra'), true);

-- 7) El bucket acepta fotos y PDF.
select set_config('app.p7', concat(
  case when (select allowed_mime_types from storage.buckets where id = 'compras') @> array['image/jpeg', 'application/pdf']
       then 'ok' else 'FALLO' end,
  ' — el bucket de facturas acepta fotos y PDF'), true);

select current_setting('app.p1') as resultado
union all select current_setting('app.p2')
union all select current_setting('app.p3')
union all select current_setting('app.p4')
union all select current_setting('app.p5')
union all select current_setting('app.p6')
union all select current_setting('app.p7');

-- No se prueba aquí porque lanza excepción (sin plpgsql abortaría el bloque): un SKU repetido, una
-- pieza nueva sin nombre o una cantidad en cero se rechazan con su mensaje y no dejan NADA a
-- medias (ni la compra ni los productos nuevos), porque todo va en la misma transacción.

rollback;
