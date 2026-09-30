-- Prueba de 46_publicar_al_aprobar_precio.sql. Correr DESPUÉS del 44 y el 46, el bloque completo.
-- begin/rollback. SQL plano, sin bloques plpgsql.
--
--   X  viene del proveedor, sin precio, sin publicar      → al aprobar su primer precio SE PUBLICA
--   Y  de PowerMx (sin origen), sin precio, sin publicar  → al aprobar NO se publica
--   Z  del proveedor, YA con precio y retirado del sitio  → al cambiar su precio NO se republica
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

insert into reglas_margen (categoria, marca, margen_pct, margen_minimo_mxn, redondeo)
values (null, null, 30, 100, 10);

insert into productos (sku, categoria, nombre, marca, activo, publicar, precio, atributos,
                       proveedor, proveedor_sku, precio_auto) values
  ('PRUEBA-46-X', 'panel', 'Del proveedor', 'OTRA', true, false, null, '{"origen":"proveedor"}', 'prueba46', 'X', true),
  ('PRUEBA-46-Y', 'panel', 'De PowerMx',    'OTRA', true, false, null, '{}',                     'prueba46', 'Y', true),
  ('PRUEBA-46-Z', 'panel', 'Retirado',      'OTRA', true, false, 1000, '{"origen":"proveedor"}', 'prueba46', 'Z', true);

-- Lectura 1: costo de 100 USD (a 18 = 1,800 MXN → precio 2,340). Z cuesta 50 USD (900 → 1,170).
select set_config('app.c1', sync_iniciar('prueba46', 'prueba')::text, true);
select set_config('app.n1', sync_recibir_lote(current_setting('app.c1')::uuid, '[
  {"sku_proveedor":"X","costo":100,"moneda":"USD"},
  {"sku_proveedor":"Y","costo":100,"moneda":"USD"},
  {"sku_proveedor":"Z","costo":50,"moneda":"USD"}]'::jsonb)::text, true);
select set_config('app.r1', sync_cerrar_lectura(current_setting('app.c1')::uuid)::text, true);
select set_config('app.r1b', sync_aplicar(current_setting('app.c1')::uuid, 18, current_date, 'prueba')::text, true);

-- Antes de aprobar nada: nada se publicó solo.
select set_config('app.p1', concat(
  'X=', (select publicar from productos where sku = 'PRUEBA-46-X'),
  ' Y=', (select publicar from productos where sku = 'PRUEBA-46-Y'),
  ' (esperado: false y false — el sync no publica, solo la aprobación)'), true);

select set_config('app.r2', resolver_revisiones('precio_inicial', true)::text, true);
select set_config('app.p2', concat(
  current_setting('app.r2'), ' — X: precio ', (select precio from productos where sku = 'PRUEBA-46-X'),
  ' publicar=', (select publicar from productos where sku = 'PRUEBA-46-X'),
  '; Y: precio ', (select precio from productos where sku = 'PRUEBA-46-Y'),
  ' publicar=', (select publicar from productos where sku = 'PRUEBA-46-Y'),
  ' (esperado: X 2340 true; Y 2340 false)'), true);

-- Z ya tenía precio (1000) y costó 50 USD → 1,170 (+17 %: pasa el umbral y va a la cola); se aprueba.
select set_config('app.r3', resolver_revisiones('cambio_precio', true)::text, true);
select set_config('app.p3', concat(
  current_setting('app.r3'), ' — Z: precio ', (select precio from productos where sku = 'PRUEBA-46-Z'),
  ' publicar=', (select publicar from productos where sku = 'PRUEBA-46-Z'),
  ' (esperado: 1170 y false — ya tenía precio, así que no se republica)'), true);

-- La auditoría dice si publicó.
select set_config('app.p4', concat(
  (select count(*) from auditoria where accion = 'precio_por_proveedor'
      and (valor_nuevo ->> 'publicado')::boolean),
  ' aprobación que publicó (esperado: 1)'), true);

select concat_ws(E'\n', '1 ' || current_setting('app.p1'), '2 ' || current_setting('app.p2'),
  '3 ' || current_setting('app.p3'), '4 ' || current_setting('app.p4')) as resultado;

rollback;
