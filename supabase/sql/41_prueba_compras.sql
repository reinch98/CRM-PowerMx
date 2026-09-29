-- ---------------------------------------------------------------------------
-- Prueba de 41_compras.sql. Correr DESPUÉS del 41, y el bloque COMPLETO.
-- Todo en begin/rollback. SQL plano, sin bloques plpgsql (ver CLAUDE.md).
--
-- El caso que más importa es el 5: una factura que llega DESPUÉS de haber recibido el
-- material no vuelve a mover el inventario. Si eso falla, cada pieza entra dos veces y el
-- almacén promete existencias que no tiene.
--
-- Consume folios de compra y de requisición (las secuencias no se revierten con el rollback).
-- ---------------------------------------------------------------------------

begin;

-- Llamar como admin: todas las funciones exigen `es_admin()`, y el editor SQL no trae claims.
select set_config('app.admin',
         coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
         json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

-- ---- el escenario ----
select set_config('app.prod', gen_random_uuid()::text, true),
       set_config('app.reqA', gen_random_uuid()::text, true),
       set_config('app.reqB', gen_random_uuid()::text, true),
       set_config('app.movB', gen_random_uuid()::text, true);

insert into productos (id, sku, categoria, nombre, unidad, precio, costo, activo)
values (current_setting('app.prod')::uuid, 'PRUEBA41-FIL', 'refaccion',
        'Filtro de prueba 41', 'pieza', 500, 285, true);

-- Pedido A: puesto al proveedor y todavía sin llegar.
insert into requisiciones (id, producto_id, cantidad, estado, proveedor, fecha_pedido)
values (current_setting('app.reqA')::uuid, current_setting('app.prod')::uuid, 4, 'pedida',
        'Refaccionaria PRUEBA-41', current_date);

-- Pedido B: YA recibido, con su entrada REQ-n puesta, como lo dejaría
-- `cambiar_estado_requisicion`. Su factura llega después.
insert into movimientos_inventario (id, producto_id, tipo, cantidad, referencia, usuario)
values (current_setting('app.movB')::uuid, current_setting('app.prod')::uuid, 'entrada', 3,
        'REQ-prueba41', 'prueba');
insert into requisiciones (id, producto_id, cantidad, estado, fecha_recibida, movimiento_id)
values (current_setting('app.reqB')::uuid, current_setting('app.prod')::uuid, 3, 'recibida',
        current_date, current_setting('app.movB')::uuid);

-- El físico de partida: 3, del pedido B que ya llegó.
select set_config('app.fisico0',
  (select coalesce(sum(case when tipo in ('entrada','ajuste') then cantidad else 0 end), 0)::text
     from movimientos_inventario where producto_id = current_setting('app.prod')::uuid), true);

select set_config('app.p0', concat(
  case when nullif(current_setting('app.admin'), '') is null then 'FALLO: no hay admin'
       else 'ok' end,
  ' — escenario listo: físico de partida ', current_setting('app.fisico0'),
  ' (el pedido B ya había llegado)'), true);

-- ---- registrar la compra: 3 líneas, una de cada caso ----
select set_config('app.r', registrar_compra(
  jsonb_build_object('proveedor', 'Refaccionaria PRUEBA-41', 'factura', 'A-4471',
                     'uuid_fiscal', 'PRUEBA-41-UUID', 'notas', 'prueba'),
  jsonb_build_array(
    -- 1) compra directa, sin pedido: repone el estante
    jsonb_build_object('producto_id', current_setting('app.prod'), 'cantidad', 10,
                       'costo_unitario', 310, 'actualizar_costo', true),
    -- 2) ligada al pedido A, que estaba `pedida`: la compra lo recibe
    jsonb_build_object('producto_id', current_setting('app.prod'), 'cantidad', 4,
                       'costo_unitario', 310, 'requisicion_id', current_setting('app.reqA')),
    -- 3) ligada al pedido B, YA recibido: solo costo y factura, sin tocar inventario
    jsonb_build_object('producto_id', current_setting('app.prod'), 'cantidad', 3,
                       'costo_unitario', 300, 'requisicion_id', current_setting('app.reqB'))
  ))::text, true);

select set_config('app.p1', concat('respuesta: ', current_setting('app.r')), true);

-- 2) Los totales los calcula la base: 10×310 + 4×310 + 3×300 = 3100 + 1240 + 900 = 5240.
select set_config('app.p2', concat(
  case when (current_setting('app.r')::jsonb ->> 'subtotal')::numeric = 5240
        and (current_setting('app.r')::jsonb ->> 'iva')::numeric = 838.40
        and (current_setting('app.r')::jsonb ->> 'total')::numeric = 6078.40
       then 'ok' else 'FALLO' end,
  ' — subtotal ', current_setting('app.r')::jsonb ->> 'subtotal',
  ', IVA ', current_setting('app.r')::jsonb ->> 'iva',
  ', total ', current_setting('app.r')::jsonb ->> 'total',
  ' (se esperaba 5240 / 838.40 / 6078.40)'), true);

-- 3) Solo DOS líneas movieron inventario; la tercera no.
select set_config('app.p3', concat(
  case when (current_setting('app.r')::jsonb ->> 'entradas')::int = 2
        and (current_setting('app.r')::jsonb ->> 'ya_recibidas')::int = 1
       then 'ok' else 'FALLO' end,
  ' — ', current_setting('app.r')::jsonb ->> 'entradas', ' entradas y ',
  current_setting('app.r')::jsonb ->> 'ya_recibidas',
  ' línea(s) que ya habían entrado (se esperaba 2 y 1)'), true);

-- 4) El físico subió 14 (10 + 4), no 17.
select set_config('app.fisico1',
  (select coalesce(sum(case when tipo in ('entrada','ajuste') then cantidad else 0 end), 0)::text
     from movimientos_inventario where producto_id = current_setting('app.prod')::uuid), true);

select set_config('app.p4', concat(
  case when current_setting('app.fisico1')::numeric - current_setting('app.fisico0')::numeric = 14
       then 'ok' else 'FALLO' end,
  ' — el físico subió ',
  current_setting('app.fisico1')::numeric - current_setting('app.fisico0')::numeric,
  ' (se esperaban 14: 10 de la compra directa y 4 del pedido A)'), true);

-- 5) LA QUE MÁS IMPORTA: el pedido B no generó una segunda entrada.
select set_config('app.p5', concat(
  case when (select count(*) from movimientos_inventario
              where producto_id = current_setting('app.prod')::uuid
                and referencia like 'COMPRA-%') = 2
       then 'ok' else 'FALLO' end,
  ' — hay ',
  (select count(*) from movimientos_inventario
    where producto_id = current_setting('app.prod')::uuid and referencia like 'COMPRA-%'),
  ' movimientos de la compra (deben ser 2: la factura del pedido ya recibido no mueve nada)'), true);

-- 6) El pedido A quedó recibido, apuntando al movimiento de la compra.
select set_config('app.p6', concat(
  case when r.estado = 'recibida' and r.movimiento_id is not null
        and m.referencia like 'COMPRA-%'
       then 'ok' else 'FALLO' end,
  ' — el pedido A quedó ', r.estado, ' con el movimiento ', coalesce(m.referencia, 'ninguno')), true)
from requisiciones r left join movimientos_inventario m on m.id = r.movimiento_id
where r.id = current_setting('app.reqA')::uuid;

-- 7) El pedido B conserva SU movimiento original, no el de la compra.
select set_config('app.p7', concat(
  case when r.movimiento_id = current_setting('app.movB')::uuid then 'ok' else 'FALLO' end,
  ' — el pedido B conserva su entrada original (no se le pisó con la de la compra)'), true)
from requisiciones r where r.id = current_setting('app.reqB')::uuid;

-- 8) El costo del catálogo se actualizó porque la línea lo pidió (285 → 310).
select set_config('app.p8', concat(
  case when costo = 310 then 'ok' else 'FALLO' end,
  ' — el costo del catálogo quedó en ', costo, ' (se esperaba 310: la línea pidió actualizarlo)'), true)
from productos where id = current_setting('app.prod')::uuid;

-- ---- cancelar ----
select set_config('app.rc', cancelar_compra(
  (current_setting('app.r')::jsonb ->> 'id')::uuid, 'Factura capturada dos veces')::text, true);

select set_config('app.fisico2',
  (select coalesce(sum(case when tipo in ('entrada','ajuste') then cantidad else 0 end), 0)::text
     from movimientos_inventario where producto_id = current_setting('app.prod')::uuid), true);

-- 9) Cancelar devuelve el físico al de antes de la compra, con movimientos y sin borrar nada.
select set_config('app.p9', concat(
  case when current_setting('app.fisico2')::numeric = current_setting('app.fisico0')::numeric
        and (current_setting('app.rc')::jsonb ->> 'ajustes')::int = 2
       then 'ok' else 'FALLO' end,
  ' — tras cancelar el físico volvió a ', current_setting('app.fisico2'),
  ' con ', current_setting('app.rc')::jsonb ->> 'ajustes',
  ' ajustes (se esperaba ', current_setting('app.fisico0'), ' y 2)'), true);

-- 10) Nada se borró: los movimientos de la compra siguen ahí, más los ajustes.
select set_config('app.p10', concat(
  case when (select count(*) from movimientos_inventario
              where producto_id = current_setting('app.prod')::uuid
                and referencia like 'COMPRA-%') = 4
       then 'ok' else 'FALLO' end,
  ' — quedan ',
  (select count(*) from movimientos_inventario
    where producto_id = current_setting('app.prod')::uuid and referencia like 'COMPRA-%'),
  ' movimientos de la compra (2 entradas + 2 ajustes: el inventario se corrige, no se borra)'), true);

-- 11) Cancelar dos veces no mete más ajustes.
select set_config('app.p11', concat(
  case when (cancelar_compra((current_setting('app.r')::jsonb ->> 'id')::uuid, 'otra vez')
             ->> 'sin_cambio') = 'true'
       then 'ok' else 'FALLO' end,
  ' — cancelar dos veces devuelve "sin cambio"'), true);

-- ---- lo que ve quien no es admin ----
select set_config('request.jwt.claims',
         json_build_object('sub', coalesce((select id::text from perfiles where rol = 'tecnico' limit 1), ''),
                           'role', 'authenticated')::text, true);

select set_config('app.p12', concat(
  case when compras_recientes() = '[]'::jsonb and pedidos_por_recibir() = '[]'::jsonb
       then 'ok' else 'FALLO' end,
  ' — el técnico recibe listas vacías de compras y pedidos (ahí van los costos)'), true);

select current_setting('app.p0', true) as resultado
union all select current_setting('app.p1', true)
union all select current_setting('app.p2', true)
union all select current_setting('app.p3', true)
union all select current_setting('app.p4', true)
union all select current_setting('app.p5', true)
union all select current_setting('app.p6', true)
union all select current_setting('app.p7', true)
union all select current_setting('app.p8', true)
union all select current_setting('app.p9', true)
union all select current_setting('app.p10', true)
union all select current_setting('app.p11', true)
union all select current_setting('app.p12', true);

rollback;
