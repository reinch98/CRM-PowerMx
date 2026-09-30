-- Prueba de 44_sync_proveedor.sql. Correr DESPUÉS del 44, el bloque completo. begin/rollback.
-- SQL plano, sin bloques plpgsql (el editor de Supabase los mutila; ver CLAUDE.md).
-- Como admin: el paso 12 cambia a un técnico para comprobar que no lee nada.
--
-- Caso de referencia (tipo de cambio 18):
--   A  marca TESTMARCA  costo 100 USD → 1,800 MXN; regla de marca 20 % (mín 50, redondeo 1) → 2,160
--   B  marca OTRA       costo 200 USD → 3,600 MXN; regla general 30 % (mín 100, redondeo 10) → 4,680
--   D  marca OTRA       costo   1 USD →    18 MXN; 30 % daría 23.4, el mínimo manda: 118 → 120
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

select set_config('app.a', gen_random_uuid()::text, true),
       set_config('app.b', gen_random_uuid()::text, true),
       set_config('app.d', gen_random_uuid()::text, true);

insert into reglas_margen (categoria, marca, margen_pct, margen_minimo_mxn, redondeo) values
  (null, null,         30, 100, 10),
  (null, 'TESTMARCA',  20,  50,  1);

insert into productos (id, sku, nombre, categoria, marca, activo, publicar,
                       proveedor, proveedor_sku, precio_auto)
values (current_setting('app.a')::uuid, 'PRUEBA-44-A', 'Panel A', 'panel', 'TESTMARCA', true, true, 'prueba44', 'SKU-A', true),
       (current_setting('app.b')::uuid, 'PRUEBA-44-B', 'Panel B', 'panel', 'OTRA',      true, true, 'prueba44', 'SKU-B', true),
       (current_setting('app.d')::uuid, 'PRUEBA-44-D', 'Barato D', 'panel', 'OTRA',     true, true, 'prueba44', 'SKU-D', true);

-- 1. La regla más específica gana ---------------------------------------------------------------
select set_config('app.p1', concat(
  (select margen_pct from _regla_margen('panel', 'testmarca')), ' / ',
  (select margen_pct from _regla_margen('panel', 'OTRA')),
  ' (esperado: 20 / 30)'), true);

-- 2. Corrida 1: A, B, C (sin vincular) y D -----------------------------------------------------------
select set_config('app.c1', sync_iniciar('prueba44', 'prueba')::text, true);
select set_config('app.n1', sync_recibir_lote(current_setting('app.c1')::uuid, '[
  {"sku_proveedor":"SKU-A","nombre":"Panel A","costo":100,"moneda":"USD","stock_local":3,"stock_proveedor":40},
  {"sku_proveedor":"SKU-B","nombre":"Panel B","costo":200,"moneda":"USD","stock_local":0,"stock_proveedor":10},
  {"sku_proveedor":"SKU-C","nombre":"Sin vincular","costo":50,"moneda":"USD"},
  {"sku_proveedor":"SKU-D","nombre":"Barato D","costo":1,"moneda":"USD"}]'::jsonb)::text, true);
select set_config('app.r1', sync_cerrar_lectura(current_setting('app.c1')::uuid)::text, true);
select set_config('app.r1b', sync_aplicar(current_setting('app.c1')::uuid, 18, current_date, 'prueba')::text, true);

select set_config('app.p2', concat(
  'lote ', current_setting('app.n1'), ' filas (esperado: 4); lectura ', current_setting('app.r1'),
  '; aplicar ', current_setting('app.r1b'),
  ' — precios aún null: ',
  (select count(*) from productos where id in (current_setting('app.a')::uuid, current_setting('app.b')::uuid,
     current_setting('app.d')::uuid) and precio is null),
  ' (esperado: 3; en_revision=3, aplicados=0)'), true);

-- 3. Aprobar los precios iniciales ------------------------------------------------------------------
select set_config('app.r3', resolver_revisiones('precio_inicial', true)::text, true);
select set_config('app.p3', concat(
  current_setting('app.r3'), ' — A=', (select precio from productos where id = current_setting('app.a')::uuid),
  ' B=', (select precio from productos where id = current_setting('app.b')::uuid),
  ' D=', (select precio from productos where id = current_setting('app.d')::uuid),
  ' costos ', (select costo from productos where id = current_setting('app.a')::uuid), '/',
  (select costo from productos where id = current_setting('app.b')::uuid),
  ' (esperado: A=2160 B=4680 D=120, costos 1800/3600)'), true);

-- 4. Nunca por debajo de costo + margen mínimo ------------------------------------------------------
select set_config('app.p4', concat(
  (select count(*) from productos where id in (current_setting('app.a')::uuid, current_setting('app.b')::uuid,
     current_setting('app.d')::uuid) and precio < costo + case marca when 'TESTMARCA' then 50 else 100 end),
  ' productos bajo costo+mínimo (esperado: 0); historial: ',
  (select count(*) from historial_precios where producto_id in (current_setting('app.a')::uuid,
     current_setting('app.b')::uuid, current_setting('app.d')::uuid)), ' (esperado: 3)'), true);

-- 5. Corrida 2: A sube 5 % (se aplica solo), B sube 50 % (a la cola) ----------------------------------
select set_config('app.c2', sync_iniciar('prueba44', 'prueba')::text, true);
select set_config('app.n2', sync_recibir_lote(current_setting('app.c2')::uuid, '[
  {"sku_proveedor":"SKU-A","costo":105,"moneda":"USD"},
  {"sku_proveedor":"SKU-B","costo":300,"moneda":"USD"},
  {"sku_proveedor":"SKU-C","costo":50,"moneda":"USD"},
  {"sku_proveedor":"SKU-D","costo":1,"moneda":"USD"}]'::jsonb)::text, true);
select set_config('app.r5', sync_cerrar_lectura(current_setting('app.c2')::uuid)::text, true);
select set_config('app.r5b', sync_aplicar(current_setting('app.c2')::uuid, 18, current_date, 'prueba')::text, true);
select set_config('app.p5', concat(
  current_setting('app.r5b'), ' — A=', (select precio from productos where id = current_setting('app.a')::uuid),
  ' B=', (select precio from productos where id = current_setting('app.b')::uuid),
  ' pendientes cambio_precio: ', (select count(*) from cola_revision
    where tipo = 'cambio_precio' and estado = 'pendiente' and producto_id = current_setting('app.b')::uuid),
  ' (esperado: A=2268 B=4680 sin tocar, 1 pendiente, aplicados=1 en_revision=1)'), true);

-- 6. Repetir la misma lectura no apila avisos ni cambia nada ---------------------------------------------
select set_config('app.c3', sync_iniciar('prueba44', 'prueba')::text, true);
select set_config('app.n3', sync_recibir_lote(current_setting('app.c3')::uuid, '[
  {"sku_proveedor":"SKU-B","costo":300,"moneda":"USD"},
  {"sku_proveedor":"SKU-C","costo":50,"moneda":"USD"},
  {"sku_proveedor":"SKU-D","costo":1,"moneda":"USD"}]'::jsonb)::text, true);
select set_config('app.r6', sync_cerrar_lectura(current_setting('app.c3')::uuid)::text, true);
select set_config('app.r6b', sync_aplicar(current_setting('app.c3')::uuid, 18, current_date, 'prueba')::text, true);
select set_config('app.p6', concat(
  'pendientes de B: ', (select count(*) from cola_revision where producto_id = current_setting('app.b')::uuid
     and estado = 'pendiente'), ' (esperado: 1); ',
  'A desaparecido pendiente: ', (select count(*) from cola_revision where producto_id = current_setting('app.a')::uuid
     and tipo = 'sku_desaparecido' and estado = 'pendiente'), ' (esperado: 1); ',
  'A vigente en la lectura: ', (select vigente from proveedor_productos where sku_proveedor = 'SKU-A'
     and proveedor = 'prueba44'), ' (esperado: false); ',
  'A conserva precio ', (select precio from productos where id = current_setting('app.a')::uuid), ' (esperado: 2268)'), true);

-- 7. Rechazar el aumento de B y aprobar el retiro de A ------------------------------------------------------
select set_config('app.r7', resolver_revision(
  (select id from cola_revision where producto_id = current_setting('app.b')::uuid and estado = 'pendiente'),
  false, 'No me convence')::text, true);
select set_config('app.r7b', resolver_revision(
  (select id from cola_revision where producto_id = current_setting('app.a')::uuid and estado = 'pendiente'),
  true, 'Ya no lo venden')::text, true);
select set_config('app.p7', concat(
  current_setting('app.r7'), '/', current_setting('app.r7b'), ' — B conserva ',
  (select precio from productos where id = current_setting('app.b')::uuid),
  ' (esperado: 4680); A publicar=', (select publicar from productos where id = current_setting('app.a')::uuid),
  ' (esperado: false)'), true);

-- 8. Aprobar dos veces no repite --------------------------------------------------------------------------------
select set_config('app.p8', concat(resolver_revision(
  (select id from cola_revision where producto_id = current_setting('app.a')::uuid and tipo = 'sku_desaparecido' limit 1),
  true, null), ' (esperado: sin_cambio)'), true);

-- 9. Una lectura vacía se rechaza y no aplica nada ---------------------------------------------------------------------
select set_config('app.c4', sync_iniciar('prueba44', 'prueba')::text, true);
select set_config('app.r9', sync_cerrar_lectura(current_setting('app.c4')::uuid)::text, true);
select set_config('app.p9', concat(
  current_setting('app.r9'), ' — estado: ',
  (select estado from sync_corridas where id = current_setting('app.c4')::uuid), ' (esperado: ok=false, fallida)'), true);

-- 10. Una lectura con menos de la mitad de la anterior también (2 filas contra 3 = 66 %, pasa; 1 contra 3, no) ------
select set_config('app.c5', sync_iniciar('prueba44', 'prueba')::text, true);
select set_config('app.n5', sync_recibir_lote(current_setting('app.c5')::uuid,
  '[{"sku_proveedor":"SKU-B","costo":200,"moneda":"USD"}]'::jsonb)::text, true);
select set_config('app.r10', sync_cerrar_lectura(current_setting('app.c5')::uuid)::text, true);
select set_config('app.p10', concat(current_setting('app.r10'), ' (esperado: ok=false)'), true);

-- 11. Vincular un código que sí existe en la lectura (rechazar uno inexistente lanza excepción: prueba manual) --------------------------------
select set_config('app.p11', concat(
  vincular_producto_proveedor(current_setting('app.b')::uuid, 'prueba44', 'SKU-B', true),
  ' — auditoría de precio del sync: ',
  (select count(*) from auditoria where tabla = 'productos' and accion = 'precio_por_proveedor'
     and registro_id in (current_setting('app.a')::uuid, current_setting('app.b')::uuid,
                         current_setting('app.d')::uuid)),
  ' (esperado: ok — 4 renglones: 3 iniciales + 1 subida de A)'), true);

-- 12. Como técnico no se lee nada de esto (RLS). Va al final: cambia el rol. ---------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', coalesce((select id::text from perfiles where rol = 'tecnico' limit 1), gen_random_uuid()::text),
                    'role', 'authenticated')::text, true);
set local role authenticated;
select set_config('app.p12', concat(
  (select count(*) from proveedor_productos), ' / ', (select count(*) from reglas_margen), ' / ',
  (select count(*) from cola_revision), ' / ', (select count(*) from historial_precios),
  ' (esperado: 0 / 0 / 0 / 0)'), true);

select concat_ws(E'\n',
  '1 ' || current_setting('app.p1'),  '2 ' || current_setting('app.p2'),
  '3 ' || current_setting('app.p3'),  '4 ' || current_setting('app.p4'),
  '5 ' || current_setting('app.p5'),  '6 ' || current_setting('app.p6'),
  '7 ' || current_setting('app.p7'),  '8 ' || current_setting('app.p8'),
  '9 ' || current_setting('app.p9'),  '10 ' || current_setting('app.p10'),
  '11 ' || current_setting('app.p11'), '12 ' || current_setting('app.p12')) as resultado;

rollback;
