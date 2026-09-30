-- Prueba de 45_importar_productos_proveedor.sql. Correr DESPUÉS del 44 y el 45, el bloque completo.
-- begin/rollback. SQL plano, sin bloques plpgsql (el editor de Supabase los mutila).
--
-- Escenario, proveedor 'prueba45':
--   P1  Paneles solares          → se importa como panel
--   M1  Microinversores          → inversor / subcategoría microinversor
--   S1  Sistemas de montaje      → accesorio_solar / montaje
--   X1  "Categoría rara"         → no tiene equivalente: NO se importa
--   P2  Paneles solares          → ya hay un producto con ese SKU: se salta
--   P3  Paneles solares          → ya hay un producto VINCULADO a P3 (con otro SKU): se salta
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

insert into proveedor_productos (proveedor, sku_proveedor, nombre, categoria, marca, modelo, costo, moneda,
                                 url_imagen, documentos, vigente) values
  ('prueba45', 'P1', 'Panel de prueba 630W', 'Paneles solares', 'JA SOLAR', 'JA-630', 100, 'USD',
     'https://x/p1.png', '{"ficha_tecnica":["https://x/p1.pdf"]}', true),
  ('prueba45', 'M1', 'Microinversor de prueba', 'Microinversores', 'ENPHASE', 'IQ8', 50, 'USD', null, '{}', true),
  ('prueba45', 'S1', 'Riel de montaje', 'Sistemas de montaje', null, null, null, 'USD', null, '{}', true),
  ('prueba45', 'X1', 'Cosa rara', 'Categoría rara', null, null, 1, 'USD', null, '{}', true),
  ('prueba45', 'P2', 'Panel que ya existe', 'Paneles solares', null, null, 1, 'USD', null, '{}', true),
  ('prueba45', 'P3', 'Panel ya vinculado', 'Paneles solares', null, null, 1, 'USD', null, '{}', true),
  ('prueba45', 'V1', 'Ya no lo lista', 'Paneles solares', null, null, 1, 'USD', null, '{}', false);

insert into productos (sku, categoria, nombre, proveedor, proveedor_sku) values
  ('P2', 'panel', 'Ya estaba en el CRM', null, null),
  ('MI-PROPIO', 'panel', 'Mi código propio', 'prueba45', 'P3');

-- 1. Función de mapeo ---------------------------------------------------------------------------
select set_config('app.p1', concat(
  (_categoria_crm('Paneles solares'))[1], ' / ', (_categoria_crm('MICROINVERSORES'))[1], '-',
  (_categoria_crm('Microinversores'))[2], ' / ', (_categoria_crm('Baterías, controladores y generadores'))[1],
  ' / ', coalesce((_categoria_crm('Servicios'))[1], 'sin equivalente'),
  ' (esperado: panel / inversor-microinversor / bateria / sin equivalente)'), true);

-- 2. Resumen antes de importar ---------------------------------------------------------------------
select set_config('app.r2', proveedor_resumen('prueba45')::text, true);
select set_config('app.p2', concat(
  'paneles: ',
  (select x ->> 'por_traer' from jsonb_array_elements(current_setting('app.r2')::jsonb -> 'por_traer') x
    where x ->> 'categoria' = 'Paneles solares'), ' por traer de ',
  (select x ->> 'total' from jsonb_array_elements(current_setting('app.r2')::jsonb -> 'por_traer') x
    where x ->> 'categoria' = 'Paneles solares'),
  ' (esperado: 1 de 3: la que se dio de baja no cuenta, P2 y P3 ya existen); rara equivale: ',
  (select x ->> 'equivale' from jsonb_array_elements(current_setting('app.r2')::jsonb -> 'por_traer') x
    where x ->> 'categoria' = 'Categoría rara'), ' (esperado: false)'), true);

-- 3. Importar -----------------------------------------------------------------------------------------
select set_config('app.r3', importar_productos_proveedor('prueba45')::text, true);
select set_config('app.p3', concat(
  current_setting('app.r3'),
  ' (esperado: creados 3, ya_existian 2, sin_categoria 1, por_categoria panel 1 / inversor 1 / accesorio_solar 1)'), true);

-- 4. Lo creado: categoría, sin publicar, sin precio, vinculado y con su imagen ------------------------------------
select set_config('app.p4', concat(
  (select concat_ws(' | ', categoria, coalesce(atributos ->> 'subcategoria', '-'), publicar::text, coalesce(precio::text, 'sin precio'),
                    proveedor_sku, precio_auto::text, moneda, atributos ->> 'imagen_proveedor',
                    atributos -> 'documentos_proveedor' -> 'ficha_tecnica' ->> 0)
     from productos where sku = 'P1'),
  ' (esperado: panel | - | false | sin precio | P1 | false | MXN | https://x/p1.png | https://x/p1.pdf)'), true);
select set_config('app.p5', concat(
  (select concat_ws(' | ', categoria, atributos ->> 'subcategoria', publicar::text, nombre) from productos where sku = 'M1'), ' ; ',
  (select concat_ws(' | ', categoria, atributos ->> 'subcategoria', publicar::text, nombre) from productos where sku = 'S1'),
  ' (esperado: inversor | microinversor | false | Microinversor de prueba ; accesorio_solar | montaje | false | Riel de montaje)'), true);

-- 5. Lo que no se debe crear -------------------------------------------------------------------------------------
select set_config('app.p6', concat(
  (select count(*) from productos where sku = 'X1'), ' de X1, ',
  (select count(*) from productos where sku = 'V1'), ' de V1, ',
  (select count(*) from productos where sku = 'P3'), ' de P3, ',
  (select nombre from productos where sku = 'P2'),
  ' (esperado: 0, 0, 0 — el vinculado ya es MI-PROPIO — y "Ya estaba en el CRM" sin tocar)'), true);

-- 6. Repetir no duplica ---------------------------------------------------------------------------------------------
select set_config('app.r7', importar_productos_proveedor('prueba45')::text, true);
select set_config('app.p7', concat(current_setting('app.r7'), ' (esperado: creados 0, ya_existian 5)'), true);

-- 7. Importar solo una categoría --------------------------------------------------------------------------------------
delete from productos where sku = 'M1';
select set_config('app.r8', importar_productos_proveedor('prueba45', array['Sistemas de montaje'])::text, true);
select set_config('app.p8', concat(current_setting('app.r8'),
  ' — M1 sigue sin existir: ', (select count(*) = 0 from productos where sku = 'M1'),
  ' (esperado: creados 0 y true, porque solo se pidió montaje y S1 ya existe)'), true);

-- 8. Activar el precio automático de una categoría ------------------------------------------------------------------------
select set_config('app.r9', activar_precio_automatico('prueba45', 'accesorio_solar')::text, true);
select set_config('app.r9b', activar_precio_automatico('prueba45', 'accesorio_solar')::text, true);
select set_config('app.p9', concat(
  'primera vez ', current_setting('app.r9'), ', segunda ', current_setting('app.r9b'),
  '; S1 auto=', (select precio_auto from productos where sku = 'S1'),
  '; P1 auto=', (select precio_auto from productos where sku = 'P1'),
  '; S1 publicado=', (select publicar from productos where sku = 'S1'),
  ' (esperado: 1, 0; true; false; false — activar NO publica)'), true);

-- 9. Auditoría -----------------------------------------------------------------------------------------------------------------
select set_config('app.p10', concat(
  (select count(*) from auditoria where accion = 'importar_de_proveedor'), ' importaciones y ',
  (select count(*) from auditoria where accion = 'activar_precio_auto_lote'),
  ' activaciones (esperado: 1 y 1; las repeticiones sin cambios no apuntan nada)'), true);

-- 10. Un técnico no puede (RLS y guardias). Va al final: cambia el rol. ------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', coalesce((select id::text from perfiles where rol = 'tecnico' limit 1), gen_random_uuid()::text),
                    'role', 'authenticated')::text, true);
set local role authenticated;
select set_config('app.p11', concat(
  (select count(*) from proveedor_productos), ' filas del proveedor visibles (esperado: 0)'), true);

select concat_ws(E'\n',
  '1 ' || current_setting('app.p1'),  '2 ' || current_setting('app.p2'),
  '3 ' || current_setting('app.p3'),  '4 ' || current_setting('app.p4'),
  '5 ' || current_setting('app.p5'),  '6 ' || current_setting('app.p6'),
  '7 ' || current_setting('app.p7'),  '8 ' || current_setting('app.p8'),
  '9 ' || current_setting('app.p9'),  '10 ' || current_setting('app.p10'),
  '11 ' || current_setting('app.p11')) as resultado;

rollback;

-- Pruebas manuales (lanzan excepción, no caben en este editor sin plpgsql): como técnico,
-- proveedor_resumen(), importar_productos_proveedor() y activar_precio_automatico() responden
-- «Solo el administrador.» (42501).
