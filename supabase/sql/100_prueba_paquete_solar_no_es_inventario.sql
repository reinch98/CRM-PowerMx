-- ---------------------------------------------------------------------------
-- Prueba de 100_paquete_solar_no_es_inventario.sql. Correr DESPUÉS del 100, el bloque COMPLETO.
-- Todo va en begin/rollback (los folios de cotización sí se consumen). SQL plano, sin plpgsql.
-- Apaga el disparador dentro de la transacción para fabricar cotizaciones "de antes del 100";
-- eso exige ser el dueño de la tabla: correrla con la CLI o el editor de Supabase.
-- npx supabase db query --linked -f supabase/sql/100_prueba_paquete_solar_no_es_inventario.sql
-- ---------------------------------------------------------------------------

begin;

select set_config('app.admin',
         coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('app.p0', case when nullif(current_setting('app.admin'), '') is null
                                 then 'FALLO: no hay admin activo' else 'ok — hay admin con quien probar' end, true);

-- Escenario: un cliente, un paquete solar y una pieza normal (con existencia de 10).
select set_config('app.cliente', gen_random_uuid()::text, true),
       set_config('app.pkg', gen_random_uuid()::text, true),
       set_config('app.pieza', gen_random_uuid()::text, true),
       set_config('app.c1', gen_random_uuid()::text, true),
       set_config('app.c2', gen_random_uuid()::text, true),
       set_config('app.c3', gen_random_uuid()::text, true);

insert into clientes (id, nombre, telefono) values (current_setting('app.cliente')::uuid, 'Cliente de prueba (100)', '9990010001');
insert into productos (id, sku, nombre, categoria, precio, activo, publicar)
values (current_setting('app.pkg')::uuid, 'PKG-PRUEBA-100', 'Paquete de prueba (100)', 'paquete_solar', 53999, true, false),
       (current_setting('app.pieza')::uuid, 'PIEZA-PRUEBA-100', 'Pieza de prueba (100)', 'panel', 3000, true, false);
insert into movimientos_inventario (id, producto_id, tipo, cantidad, referencia, notas, usuario, created_at)
values (gen_random_uuid(), current_setting('app.pieza')::uuid, 'entrada', 10, 'PRUEBA-100', 'prueba', 'prueba', now());

select set_config('app.partidas', jsonb_build_array(
  jsonb_build_object('producto_id', current_setting('app.pkg'), 'sku', 'PKG-PRUEBA-100', 'descripcion', 'Paquete', 'cantidad', 1, 'precio_unitario', 46550.86),
  jsonb_build_object('producto_id', current_setting('app.pieza'), 'sku', 'PIEZA-PRUEBA-100', 'descripcion', 'Pieza', 'cantidad', 2, 'precio_unitario', 0, 'incluida', true)
)::text, true);

-- 1) Una cotización NUEVA con el paquete como producto: el disparador le quita el producto_id.
insert into cotizaciones (id, cliente_id, fecha, vigencia_dias, tipo, partidas, subtotal, descuento, iva, total, requiere_visita, estado, creada_por)
values (current_setting('app.c1')::uuid, current_setting('app.cliente')::uuid, current_date, 15, 'venta',
        current_setting('app.partidas')::jsonb, 46550.86, 0, 7448.14, 53999, false, 'borrador', 'prueba-100');

select set_config('app.p1', concat(
  case when (c.partidas -> 0 ->> 'producto_id') is null
         and c.partidas -> 0 ->> 'paquete_sku' = 'PKG-PRUEBA-100'
         and c.partidas -> 1 ->> 'producto_id' = current_setting('app.pieza')
         and jsonb_array_length(c.partidas) = 2
       then 'ok' else 'FALLO' end,
  ' — el paquete quedó sin producto_id y la pieza con el suyo: ', c.partidas::text), true)
from cotizaciones c where c.id = current_setting('app.c1')::uuid;

-- Una cotización "de antes" ya ACEPTADA con el paquete apartado, y un borrador "de antes".
alter table cotizaciones disable trigger paquete_solar_no_es_inventario;
insert into cotizaciones (id, cliente_id, fecha, vigencia_dias, tipo, partidas, subtotal, descuento, iva, total, requiere_visita, estado, creada_por)
values (current_setting('app.c2')::uuid, current_setting('app.cliente')::uuid, current_date, 15, 'venta',
        current_setting('app.partidas')::jsonb, 46550.86, 0, 7448.14, 53999, false, 'aceptada', 'prueba-100'),
       (current_setting('app.c3')::uuid, current_setting('app.cliente')::uuid, current_date, 15, 'venta',
        current_setting('app.partidas')::jsonb, 46550.86, 0, 7448.14, 53999, false, 'borrador', 'prueba-100');
alter table cotizaciones enable trigger paquete_solar_no_es_inventario;
insert into movimientos_inventario (id, producto_id, tipo, cantidad, cotizacion_id, referencia, notas, usuario, created_at)
values (gen_random_uuid(), current_setting('app.pkg')::uuid, 'apartado', 1, current_setting('app.c2')::uuid, 'PRUEBA-100', 'de antes', 'prueba', now()),
       (gen_random_uuid(), current_setting('app.pieza')::uuid, 'apartado', 2, current_setting('app.c2')::uuid, 'PRUEBA-100', 'de antes', 'prueba', now());
insert into requisiciones (producto_id, cotizacion_id, cliente_id, cantidad, creada_por, estado)
values (current_setting('app.pkg')::uuid, current_setting('app.c2')::uuid, current_setting('app.cliente')::uuid, 1, 'prueba-100', 'pendiente');

-- 2) Tocar las partidas de la ACEPTADA no las cambia (su apartado depende de ellas).
update cotizaciones set partidas = partidas where id = current_setting('app.c2')::uuid;
select set_config('app.p2', concat(
  case when c.partidas -> 0 ->> 'producto_id' = current_setting('app.pkg') then 'ok' else 'FALLO' end,
  ' — la cotización aceptada de antes conserva sus partidas'), true)
from cotizaciones c where c.id = current_setting('app.c2')::uuid;

-- 3) La corrección única del 100 (la misma sentencia): limpia el borrador de antes y cancela
--    la requisición pendiente del paquete.
update cotizaciones c set partidas = c.partidas
 where c.estado in ('borrador', 'enviada')
   and exists (select 1 from jsonb_array_elements(coalesce(c.partidas, '[]'::jsonb)) e
                 join productos pr on pr.id::text = e ->> 'producto_id'
                where pr.categoria = 'paquete_solar');
update requisiciones r set estado = 'cancelada',
       notas = concat_ws(E'\n', nullif(r.notas, ''), 'Cancelada (SQL 100): un paquete solar no se pide al proveedor; se piden sus piezas.'),
       updated_at = now()
  from productos pr
 where pr.id = r.producto_id and pr.categoria = 'paquete_solar' and r.estado = 'pendiente';

select set_config('app.p3', concat(
  case when (select (partidas -> 0 ->> 'producto_id') is null from cotizaciones where id = current_setting('app.c3')::uuid)
         and (select count(*) from requisiciones where producto_id = current_setting('app.pkg')::uuid and estado = 'pendiente') = 0
         and (select count(*) from requisiciones where producto_id = current_setting('app.pkg')::uuid and estado = 'cancelada') = 1
       then 'ok' else 'FALLO' end,
  ' — el borrador de antes quedó limpio y la requisición del paquete, cancelada'), true);

-- ---- como el ADMIN: aceptar y regresar ----
select set_config('request.jwt.claims',
         json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated', 'email', 'admin@prueba')::text, true);
set local role authenticated;

select set_config('app.r4', cambiar_estado_cotizacion(current_setting('app.c1')::uuid, 'aceptada')::text, true);
select set_config('app.r5', cambiar_estado_cotizacion(current_setting('app.c2')::uuid, 'borrador')::text, true);

reset role;

-- 4) Aceptar la NUEVA aparta solo la pieza: ni un movimiento ni una requisición del paquete.
select set_config('app.p4', concat(
  case when (select count(*) from movimientos_inventario where cotizacion_id = current_setting('app.c1')::uuid and producto_id = current_setting('app.pkg')::uuid) = 0
         and (select coalesce(sum(cantidad), 0) from movimientos_inventario where cotizacion_id = current_setting('app.c1')::uuid and producto_id = current_setting('app.pieza')::uuid and tipo = 'apartado') = 2
         and (select count(*) from requisiciones where cotizacion_id = current_setting('app.c1')::uuid and producto_id = current_setting('app.pkg')::uuid) = 0
       then 'ok' else 'FALLO' end,
  ' — aceptar apartó la pieza (2) y nada del paquete: ', current_setting('app.r4')), true);

-- 5) Sacar de "aceptada" la de ANTES libera también su paquete: el apartado no se queda atorado.
select set_config('app.p5', concat(
  case when (select coalesce(sum(case when tipo = 'apartado' then cantidad when tipo = 'libera_apartado' then -cantidad else 0 end), 0)
               from movimientos_inventario
              where cotizacion_id = current_setting('app.c2')::uuid and producto_id = current_setting('app.pkg')::uuid) = 0
       then 'ok' else 'FALLO' end,
  ' — la aceptada de antes liberó su paquete al regresar a borrador: ', current_setting('app.r5')), true);

select current_setting('app.p0') as p0, current_setting('app.p1') as p1, current_setting('app.p2') as p2,
       current_setting('app.p3') as p3, current_setting('app.p4') as p4, current_setting('app.p5') as p5;

rollback;
