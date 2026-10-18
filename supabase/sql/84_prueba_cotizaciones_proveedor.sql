-- Prueba de 84_cotizaciones_proveedor.sql. Correr DESPUÉS del 84, el bloque COMPLETO, con la CLI:
--   npx supabase db query --linked -f supabase/sql/84_prueba_cotizaciones_proveedor.sql
-- begin/rollback, con bloques `do` para los rechazos (el editor web los mutila; la CLI no).
-- Nombres "PRUEBA84". Consume folios de cotizaciones de proveedor y de pedidos.
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

-- Tres piezas existentes: A y B normales, C con precio automático (se fuerza aquí y se deshace al final).
select set_config('app.a', gen_random_uuid()::text, true), set_config('app.b', gen_random_uuid()::text, true),
       set_config('app.c', gen_random_uuid()::text, true),
       set_config('app.h1', repeat('1', 64), true), set_config('app.h2', repeat('2', 64), true);
insert into productos (id, sku, nombre, categoria, unidad, activo, publicar, costo) values
  (current_setting('app.a')::uuid, 'P84-A', 'Filtro de aceite PRUEBA84', 'refaccion', 'pieza', true, false, 100),
  (current_setting('app.b')::uuid, 'P84-B', 'Banda PRUEBA84', 'refaccion', 'pieza', true, false, 50),
  (current_setting('app.c')::uuid, 'P84-C', 'Inversor PRUEBA84', 'inversor', 'pieza', true, false, 9000);
update productos set precio_auto = true where id = current_setting('app.c')::uuid;
select set_config('app.mov0', (select count(*)::text from movimientos_inventario), true);

-- 1) En pesos: una pieza que existe (con su código) y una nueva. No mueve inventario.
select set_config('app.r1', registrar_cotizacion_proveedor(
  jsonb_build_object('proveedor', 'Proveedor PRUEBA84 S.A. de C.V.', 'numero', 'Q-84-1', 'fecha', '2001-04-01',
                     'vigencia', '2001-04-15', 'moneda', 'MXN', 'archivo', 'cotizaciones/p84.pdf',
                     'archivo_bucket', 'compras', 'archivo_hash', current_setting('app.h1')),
  jsonb_build_array(
    jsonb_build_object('producto_id', current_setting('app.a'), 'codigo', 'PRV-A', 'descripcion', 'Filtro', 'cantidad', 5,
                       'precio_unitario', 110),
    jsonb_build_object('nuevo', jsonb_build_object('sku', 'P84-NUEVA', 'nombre', 'Manguera PRUEBA84', 'categoria', 'refaccion'),
                       'codigo', 'PRV-M', 'descripcion', 'Manguera', 'cantidad', 2, 'precio_unitario', 75.5)))::text, true);
select set_config('app.q1', current_setting('app.r1')::jsonb ->> 'id', true);
select set_config('app.prov', (select proveedor_id::text from cotizaciones_proveedor where id = current_setting('app.q1')::uuid), true);
select set_config('app.p1', concat(
  case when (current_setting('app.r1')::jsonb ->> 'total')::numeric = 813.16      -- (550 + 151) × 1.16
        and (select count(*) from cotizacion_proveedor_lineas where cotizacion_id = current_setting('app.q1')::uuid) = 2
        and (select publicar = false and precio is null and costo = 75.50 from productos where sku = 'P84-NUEVA')
        and exists (select 1 from producto_proveedores where producto_id = current_setting('app.a')::uuid
                     and proveedor_sku = 'PRV-A' and proveedor_id::text = current_setting('app.prov'))
        and (select costo from productos where id = current_setting('app.a')::uuid) = 100      -- no se pidió actualizar
        and (select count(*)::text from movimientos_inventario) = current_setting('app.mov0')
       then 'ok' else 'FALLO' end, ' — registrada: total ', current_setting('app.r1')::jsonb ->> 'total',
       ', pieza nueva sin publicar con costo, código ligado, inventario sin mover'), true);

-- 2) El mismo número del mismo proveedor no entra dos veces; el mismo archivo tampoco.
select set_config('app.p2', '', true);
do $$
declare v_ok int := 0;
begin
  begin perform registrar_cotizacion_proveedor(
          jsonb_build_object('proveedor_id', current_setting('app.prov'), 'numero', 'q-84-1'),
          jsonb_build_array(jsonb_build_object('producto_id', current_setting('app.b'), 'cantidad', 1, 'precio_unitario', 1)));
  exception when sqlstate '22023' then v_ok := v_ok + 1; end;
  begin perform registrar_cotizacion_proveedor(
          jsonb_build_object('proveedor_id', current_setting('app.prov'), 'numero', 'Q-84-OTRA', 'archivo_hash', current_setting('app.h1')),
          jsonb_build_array(jsonb_build_object('producto_id', current_setting('app.b'), 'cantidad', 1, 'precio_unitario', 1)));
  exception when sqlstate '22023' then v_ok := v_ok + 1; end;
  perform set_config('app.p2', concat(case when v_ok = 2
      and archivo_repetido(current_setting('app.h1'), 'dinero') ->> 'donde' like 'como la cotización de proveedor COTP-%'
    then 'ok' else 'FALLO' end, ' — número repetido y archivo repetido rechazados; la bandeja también la reconoce'), true);
end $$;

-- 3) En dólares: sin tipo de cambio no entra; con él, el costo va en pesos. Actualizar el costo de una
--    pieza normal sí; de una con precio automático, no (avisa).
select set_config('app.p3a', '', true);
do $$
declare v_ok boolean := false;
begin
  begin perform registrar_cotizacion_proveedor(
          jsonb_build_object('proveedor_id', current_setting('app.prov'), 'numero', 'Q-84-USD0', 'moneda', 'USD'),
          jsonb_build_array(jsonb_build_object('producto_id', current_setting('app.b'), 'cantidad', 1, 'precio_unitario', 3)));
  exception when sqlstate '22023' then v_ok := true; end;
  perform set_config('app.p3a', case when v_ok then 'ok' else 'FALLO' end, true);
end $$;
select set_config('app.r3', registrar_cotizacion_proveedor(
  jsonb_build_object('proveedor_id', current_setting('app.prov'), 'numero', 'Q-84-USD', 'moneda', 'USD', 'tipo_cambio', 18,
                     'fecha', '2001-04-02'),
  jsonb_build_array(
    jsonb_build_object('producto_id', current_setting('app.b'), 'cantidad', 4, 'precio_unitario', 3.5, 'actualizar_costo', true),
    jsonb_build_object('producto_id', current_setting('app.c'), 'cantidad', 1, 'precio_unitario', 600, 'actualizar_costo', true)))::text, true);
select set_config('app.p3', concat(
  case when current_setting('app.p3a') = 'ok'
        and (select costo from productos where id = current_setting('app.b')::uuid) = 63          -- 3.5 × 18
        and (select costo from productos where id = current_setting('app.c')::uuid) = 9000        -- automático: igual
        and (current_setting('app.r3')::jsonb ->> 'costos_actualizados')::int = 1
        and jsonb_array_length(current_setting('app.r3')::jsonb -> 'avisos') = 1
        and (select tipo_cambio from cotizaciones_proveedor where id = (current_setting('app.r3')::jsonb ->> 'id')::uuid) = 18
       then 'ok' else 'FALLO' end, ' — USD exige tipo de cambio; costo en pesos 63; la de precio automático no cambia y avisa'), true);

-- 4) Aceptar: toma el pedido pendiente de la misma pieza (2) y crea otro por el resto (3).
insert into requisiciones (producto_id, cantidad, estado, notas) values (current_setting('app.a')::uuid, 2, 'pendiente', 'PRUEBA84');
select set_config('app.r4', aceptar_cotizacion_proveedor(current_setting('app.q1')::uuid)::text, true);
select set_config('app.r4b', aceptar_cotizacion_proveedor(current_setting('app.q1')::uuid)::text, true);
select set_config('app.p4', concat(
  case when (current_setting('app.r4')::jsonb ->> 'pedidos_tomados')::int = 1
        and (current_setting('app.r4')::jsonb ->> 'pedidos_nuevos')::int = 2           -- el resto de A y la pieza nueva
        and (select sum(cantidad) from requisiciones where cotizacion_proveedor_id = current_setting('app.q1')::uuid
               and producto_id = current_setting('app.a')::uuid and estado = 'pedida') = 5
        and not exists (select 1 from requisiciones where notas = 'PRUEBA84' and estado = 'pendiente')
        and (select estado from cotizaciones_proveedor where id = current_setting('app.q1')::uuid) = 'aceptada'
        and (current_setting('app.r4b')::jsonb ->> 'sin_cambio')::boolean
        and jsonb_array_length(current_setting('app.r4')::jsonb -> 'avisos') = 1        -- vigencia de 2001, vencida
       then 'ok' else 'FALLO' end, ' — aceptar tomó REQ pendiente (2) y pidió el resto (3) más la nueva; repetir no cambia'), true);

-- 5) Cancelar la aceptada: los pedidos ya hechos se quedan (solo avisa).
select set_config('app.r5', cambiar_estado_cotizacion_proveedor(current_setting('app.q1')::uuid, 'cancelada', 'Prueba')::text, true);
select set_config('app.p5', concat(
  case when (current_setting('app.r5')::jsonb ->> 'pedidos_vivos')::int = 3
        and (select count(*) from requisiciones where cotizacion_proveedor_id = current_setting('app.q1')::uuid and estado = 'pedida') = 3
       then 'ok' else 'FALLO' end, ' — cancelada; sus 3 pedidos siguen "pedida" y se avisa'), true);

-- 6) Rechazar exige motivo; reabrir la deja vigente.
select set_config('app.q3', current_setting('app.r3')::jsonb ->> 'id', true);
select set_config('app.p6a', '', true);
do $$
declare v_ok boolean := false;
begin
  begin perform cambiar_estado_cotizacion_proveedor(current_setting('app.q3')::uuid, 'rechazada', '');
  exception when sqlstate '22023' then v_ok := true; end;
  perform set_config('app.p6a', case when v_ok then 'ok' else 'FALLO' end, true);
end $$;
select cambiar_estado_cotizacion_proveedor(current_setting('app.q3')::uuid, 'rechazada', 'Muy cara');
select set_config('app.e6', (select estado from cotizaciones_proveedor where id = current_setting('app.q3')::uuid), true);
select cambiar_estado_cotizacion_proveedor(current_setting('app.q3')::uuid, 'vigente');
select set_config('app.p6', concat(
  case when current_setting('app.p6a') = 'ok' and current_setting('app.e6') = 'rechazada'
        and (select estado from cotizaciones_proveedor where id = current_setting('app.q3')::uuid) = 'vigente'
       then 'ok' else 'FALLO' end, ' — rechazar pide motivo; rechazada y reabierta'), true);

-- 7) Desde la bandeja de Finanzas: el documento sale de la bandeja al registrarla.
select set_config('app.doc', (registrar_documento('factura_pdf', 'documentos/p84.pdf', 'cotizacion.pdf', 'application/pdf',
                                                   current_setting('app.h2'), 'manual', null, '[]'::jsonb) ->> 'documento_id'), true);
select set_config('app.r7', registrar_cotizacion_proveedor(
  jsonb_build_object('proveedor_id', current_setting('app.prov'), 'numero', 'Q-84-BANDEJA', 'archivo', 'documentos/p84.pdf',
                     'archivo_bucket', 'finanzas', 'archivo_hash', current_setting('app.h2'), 'documento_id', current_setting('app.doc')),
  jsonb_build_array(jsonb_build_object('producto_id', current_setting('app.b'), 'cantidad', 1, 'precio_unitario', 60)))::text, true);
select set_config('app.p7', concat(
  case when (select estado from documentos where id = current_setting('app.doc')::uuid) = 'rechazado'
        and (select motivo_rechazo from documentos where id = current_setting('app.doc')::uuid) like 'Registrada como cotización de proveedor COTP-%'
       then 'ok' else 'FALLO' end, ' — el documento de la bandeja quedó fuera: ',
       (select motivo_rechazo from documentos where id = current_setting('app.doc')::uuid)), true);

-- 8) La lista del proveedor: 3 cotizaciones, vencida calculada en la vigente de 2001 con vigencia.
update cotizaciones_proveedor set vigencia = '2001-04-10' where id = current_setting('app.q3')::uuid;
select set_config('app.lista', cotizaciones_proveedor_lista(current_setting('app.prov')::uuid, 100000)::text, true);
select set_config('app.p8', concat(
  case when jsonb_array_length(current_setting('app.lista')::jsonb) = 3
        and exists (select 1 from jsonb_array_elements(current_setting('app.lista')::jsonb) x
                     where x ->> 'id' = current_setting('app.q3') and (x ->> 'vencida')::boolean)
        and exists (select 1 from jsonb_array_elements(current_setting('app.lista')::jsonb) x
                     where x ->> 'id' = current_setting('app.q1') and (x ->> 'pedidos')::int = 3
                       and jsonb_array_length(x -> 'lineas') = 2)
       then 'ok' else 'FALLO' end, ' — lista: 3 del proveedor, la vencida marcada, pedidos y renglones'), true);

-- 9) Quien no es admin no ve ni registra.
select set_config('request.jwt.claims',
  json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
select set_config('app.p9', '', true);
do $$
declare v_ok int := 0;
begin
  begin perform cotizaciones_proveedor_lista(); exception when sqlstate '42501' then v_ok := v_ok + 1; end;
  begin perform aceptar_cotizacion_proveedor(current_setting('app.q3')::uuid); exception when sqlstate '42501' then v_ok := v_ok + 1; end;
  begin perform registrar_cotizacion_proveedor('{"proveedor":"X"}'::jsonb, '[]'::jsonb);
  exception when sqlstate '42501' then v_ok := v_ok + 1; end;
  perform set_config('app.p9', concat(case when v_ok = 3 then 'ok' else 'FALLO' end, ' — sin rol de admin: 3 de 3 rechazadas'), true);
end $$;

select 1 as paso, current_setting('app.p1') as resultado
union all select 2, current_setting('app.p2')
union all select 3, current_setting('app.p3')
union all select 4, current_setting('app.p4')
union all select 5, current_setting('app.p5')
union all select 6, current_setting('app.p6')
union all select 7, current_setting('app.p7')
union all select 8, current_setting('app.p8')
union all select 9, current_setting('app.p9')
order by 1;

rollback;
