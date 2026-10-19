-- Prueba de 86_factura_cierra_ciclo.sql. Correr DESPUÉS del 86, el bloque COMPLETO, con la CLI:
--   npx supabase db query --linked -f supabase/sql/86_prueba_factura_cierra_ciclo.sql
-- begin/rollback, con bloques `do` para los rechazos (el editor web los mutila; la CLI no).
-- Nombres "PRUEBA86", fechas de 2001. Consume folios.
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

select set_config('app.pa', gen_random_uuid()::text, true);
insert into productos (id, sku, nombre, categoria, unidad, activo, publicar) values
  (current_setting('app.pa')::uuid, 'P86-A', 'Pieza PRUEBA86', 'refaccion', 'pieza', true, false);

-- 1) Compra primero, XML después: la factura encuentra su compra por proveedor + folio + total.
select set_config('app.co1', registrar_compra(
  jsonb_build_object('proveedor', 'PROVEEDOR PRUEBA86 SA DE CV', 'factura', 'A-0099', 'fecha', '2001-07-01'),
  jsonb_build_array(jsonb_build_object('producto_id', current_setting('app.pa'), 'cantidad', 1, 'costo_unitario', 1000))) ->> 'id', true);
select set_config('app.prov', (select proveedor_id::text from compras where id = current_setting('app.co1')::uuid), true);
insert into cfdi (uuid_fiscal, sentido, fecha, rfc_emisor, nombre_emisor, rfc_receptor, subtotal, iva_trasladado, total, serie, folio)
values ('86868686-0000-4000-8000-000000000001', 'recibido', '2001-07-02', 'PCS010101AB6', 'PROVEEDOR PRUEBA86 SA DE CV', 'XAXX010101000', 1000, 160, 1160, 'A', '99');
select set_config('app.f1', (select id::text from cfdi where uuid_fiscal = '86868686-0000-4000-8000-000000000001'), true);
select set_config('app.p1', concat(
  case when (select compra_id::text from cfdi where id = current_setting('app.f1')::uuid) = current_setting('app.co1')
        and (select proveedor_id::text from cfdi where id = current_setting('app.f1')::uuid) = current_setting('app.prov')
       then 'ok' else 'FALLO' end, ' — compra primero: el XML (A 99, 1,160) se liga solo a su compra'), true);

-- 2) XML primero, compra después: la compra encuentra su XML (cuando ya tiene su total).
insert into cfdi (uuid_fiscal, sentido, fecha, rfc_emisor, nombre_emisor, rfc_receptor, subtotal, iva_trasladado, total, serie, folio)
values ('86868686-0000-4000-8000-000000000002', 'recibido', '2001-07-03', 'PCS010101AB6', 'PROVEEDOR PRUEBA86 SA DE CV', 'XAXX010101000', 500, 80, 580, 'B', '7');
select set_config('app.f2', (select id::text from cfdi where uuid_fiscal = '86868686-0000-4000-8000-000000000002'), true);
select set_config('app.co2', registrar_compra(
  jsonb_build_object('proveedor', 'Proveedor Prueba86', 'factura', 'B7', 'fecha', '2001-07-03'),
  jsonb_build_array(jsonb_build_object('producto_id', current_setting('app.pa'), 'cantidad', 1, 'costo_unitario', 500))) ->> 'id', true);
select set_config('app.p2', concat(
  case when (select compra_id::text from cfdi where id = current_setting('app.f2')::uuid) = current_setting('app.co2')
       then 'ok' else 'FALLO' end, ' — XML primero: la compra B7 (580) encuentra su factura B 7'), true);

-- 3) Sin pareja segura (folio distinto): no se liga sola; se ofrece y se liga a mano. La compra aprende el UUID.
select set_config('app.co3', registrar_compra(
  jsonb_build_object('proveedor', 'PROVEEDOR PRUEBA86 SA DE CV', 'factura', 'Z-5', 'fecha', '2001-07-04'),
  jsonb_build_array(jsonb_build_object('producto_id', current_setting('app.pa'), 'cantidad', 2, 'costo_unitario', 1000))) ->> 'id', true);
insert into cfdi (uuid_fiscal, sentido, fecha, rfc_emisor, nombre_emisor, rfc_receptor, subtotal, iva_trasladado, total, serie, folio)
values ('86868686-0000-4000-8000-000000000003', 'recibido', '2001-07-04', 'PCS010101AB6', 'PROVEEDOR PRUEBA86 SA DE CV', 'XAXX010101000', 2000, 320, 2320, 'C', '6');
select set_config('app.f3', (select id::text from cfdi where uuid_fiscal = '86868686-0000-4000-8000-000000000003'), true);
select set_config('app.ctx3', factura_contexto(current_setting('app.f3')::uuid)::text, true);
select set_config('app.l3', ligar_factura(current_setting('app.f3')::uuid, current_setting('app.co3')::uuid)::text, true);
select set_config('app.p3', concat(
  case when current_setting('app.ctx3')::jsonb -> 'compra' = 'null'::jsonb
        and current_setting('app.ctx3')::jsonb -> 'compras_posibles' -> 0 ->> 'id' = current_setting('app.co3')
        and (current_setting('app.ctx3')::jsonb -> 'compras_posibles' -> 0 ->> 'cuadra')::boolean
        and not (current_setting('app.ctx3')::jsonb -> 'compras_posibles' -> 0 ->> 'mismo_folio')::boolean
        and (select compra_id::text from cfdi where id = current_setting('app.f3')::uuid) = current_setting('app.co3')
        and (select uuid_fiscal from compras where id = current_setting('app.co3')::uuid) = '86868686-0000-4000-8000-000000000003'
       then 'ok' else 'FALLO' end, ' — folio distinto: no se liga solo, se ofrece (cuadra el total) y se liga a mano'), true);

-- 4) La compra que recibe un pedido de una cotización de proveedor hereda la cotización, y su factura también.
select set_config('app.cot', registrar_cotizacion_proveedor(
  jsonb_build_object('proveedor_id', current_setting('app.prov'), 'numero', 'Q-86'),
  jsonb_build_array(jsonb_build_object('producto_id', current_setting('app.pa'), 'cantidad', 1, 'precio_unitario', 1000))) ->> 'id', true);
select aceptar_cotizacion_proveedor(current_setting('app.cot')::uuid);
select set_config('app.req', (select id::text from requisiciones where cotizacion_proveedor_id = current_setting('app.cot')::uuid limit 1), true);
insert into cfdi (uuid_fiscal, sentido, fecha, rfc_emisor, nombre_emisor, rfc_receptor, subtotal, iva_trasladado, total, serie, folio)
values ('86868686-0000-4000-8000-000000000004', 'recibido', '2001-07-06', 'PCS010101AB6', 'PROVEEDOR PRUEBA86 SA DE CV', 'XAXX010101000', 1000, 160, 1160, 'D', '1');
select set_config('app.f4', (select id::text from cfdi where uuid_fiscal = '86868686-0000-4000-8000-000000000004'), true);
select set_config('app.co4', registrar_compra(
  jsonb_build_object('proveedor', 'PROVEEDOR PRUEBA86 SA DE CV', 'factura', 'D-1', 'fecha', '2001-07-06'),
  jsonb_build_array(jsonb_build_object('producto_id', current_setting('app.pa'), 'cantidad', 1, 'costo_unitario', 1000,
                                       'requisicion_id', current_setting('app.req')))) ->> 'id', true);
select set_config('app.p4', concat(
  case when (select cotizacion_proveedor_id::text from compras where id = current_setting('app.co4')::uuid) = current_setting('app.cot')
        and (select compra_id::text from cfdi where id = current_setting('app.f4')::uuid) = current_setting('app.co4')
        and (select cotizacion_proveedor_id::text from cfdi where id = current_setting('app.f4')::uuid) = current_setting('app.cot')
       then 'ok' else 'FALLO' end, ' — pedido de la cotización: compra y factura heredan la COTP'), true);

-- 5) Un anticipo de esa cotización se aplica AL APROBAR la factura en la bandeja (queda por pagar con su saldo).
select set_config('app.ant', registrar_pago_proveedor(jsonb_build_object(
  'proveedor_id', current_setting('app.prov'), 'monto', 500, 'fecha', '2001-07-05', 'referencia', 'R86A',
  'cotizacion_proveedor_id', current_setting('app.cot'))) ->> 'movimiento_id', true);
select set_config('app.ctx5', factura_contexto(current_setting('app.f4')::uuid)::text, true);
select set_config('app.doc4', (registrar_documento('cfdi_xml', 'documentos/p86d.xml', 'd1.xml', 'application/xml',
                                                    repeat('6', 64), 'xml', null, '[]'::jsonb) ->> 'documento_id'), true);
update documentos set cfdi_id = current_setting('app.f4')::uuid, estado = 'propuesto' where id = current_setting('app.doc4')::uuid;
select set_config('app.ap5', aprobar_documento(current_setting('app.doc4')::uuid, jsonb_build_object(
  'accion', 'gasto', 'categoria', 'pago_proveedor', 'pagado', false,
  'anticipos', jsonb_build_array(current_setting('app.ant'))))::text, true);
select set_config('app.p5', concat(
  case when (current_setting('app.ctx5')::jsonb -> 'anticipos' -> 0 ->> 'movimiento_id') = current_setting('app.ant')
        and (current_setting('app.ctx5')::jsonb -> 'anticipos' -> 0 ->> 'de_su_cotizacion')::boolean
        and (current_setting('app.ctx5')::jsonb -> 'anticipos' -> 0 ->> 'cabe')::boolean
        and (current_setting('app.ctx5')::jsonb -> 'cotizacion' ->> 'id') = current_setting('app.cot')
        and (current_setting('app.ap5')::jsonb ->> 'saldo')::numeric = 660
        and (select cfdi_id::text from expediente_movimientos where id = current_setting('app.ant')::uuid) = current_setting('app.f4')
        and (select por_pagar from cfdi where id = current_setting('app.f4')::uuid)
       then 'ok' else 'FALLO' end, ' — anticipo de su COTP propuesto y aplicado al aprobar: queda por pagar 660'), true);

-- 6) Un anticipo con "ya la pagué" se rechaza; pagada, el gasto queda ligado a la compra de su factura.
select set_config('app.doc1', (registrar_documento('cfdi_xml', 'documentos/p86a.xml', 'a99.xml', 'application/xml',
                                                    repeat('7', 64), 'xml', null, '[]'::jsonb) ->> 'documento_id'), true);
update documentos set cfdi_id = current_setting('app.f1')::uuid, estado = 'propuesto' where id = current_setting('app.doc1')::uuid;
select set_config('app.p6', '', true);
do $$
declare v_ok int := 0;
begin
  begin
    perform aprobar_documento(current_setting('app.doc1')::uuid, jsonb_build_object(
      'accion', 'gasto', 'categoria', 'pago_proveedor', 'pagado', true, 'monto', 1160, 'fecha', '2001-07-08',
      'anticipos', jsonb_build_array(current_setting('app.ant'))));
  exception when sqlstate '22023' then v_ok := v_ok + 1; end;
  perform set_config('app.p6', v_ok::text, true);
end $$;
select set_config('app.mov6', aprobar_documento(current_setting('app.doc1')::uuid, jsonb_build_object(
  'accion', 'gasto', 'categoria', 'pago_proveedor', 'pagado', true, 'monto', 1160, 'fecha', '2001-07-08')) ->> 'movimiento_id', true);
select set_config('app.p6', concat(
  case when current_setting('app.p6') = '1'
        and (select compra_id::text from expediente_movimientos where id = current_setting('app.mov6')::uuid) = current_setting('app.co1')
       then 'ok' else 'FALLO' end, ' — anticipo con "ya la pagué" rechazado; el pago queda ligado a su compra'), true);

-- 7) Cancelar la compra suelta su factura (la factura no se toca).
select cancelar_compra(current_setting('app.co2')::uuid, 'PRUEBA86');
select set_config('app.p7', concat(
  case when (select compra_id from cfdi where id = current_setting('app.f2')::uuid) is null
        and exists (select 1 from cfdi where id = current_setting('app.f2')::uuid)
       then 'ok' else 'FALLO' end, ' — compra cancelada: su factura queda sin compra'), true);

-- 8) La cotización lista su factura y ya no tiene anticipo suelto; la carpeta dice compra y COTP de cada factura.
select set_config('app.lista', (select x::text from jsonb_array_elements(cotizaciones_proveedor_lista(current_setting('app.prov')::uuid)) x
                                 where x ->> 'id' = current_setting('app.cot')), true);
select set_config('app.carp', carpeta_proveedor(current_setting('app.prov')::uuid)::text, true);
select set_config('app.p8', concat(
  case when jsonb_array_length(current_setting('app.lista')::jsonb -> 'facturas') = 1
        and current_setting('app.lista')::jsonb -> 'facturas' -> 0 ->> 'folio' = '1'
        and (current_setting('app.lista')::jsonb ->> 'anticipado')::numeric = 0
        and exists (select 1 from jsonb_array_elements(current_setting('app.carp')::jsonb -> 'facturas') f
                     where f ->> 'id' = current_setting('app.f4')
                       and f ->> 'cotizacion' = 'COTP-' || (select folio from cotizaciones_proveedor where id = current_setting('app.cot')::uuid)
                       and (f ->> 'compra')::bigint = (select folio from compras where id = current_setting('app.co4')::uuid)
                       and (f ->> 'pagos')::int = 1)
        and exists (select 1 from jsonb_array_elements(current_setting('app.carp')::jsonb -> 'compras') c
                     where c ->> 'id' = current_setting('app.co4') and (c ->> 'con_xml')::boolean)
       then 'ok' else 'FALLO' end, ' — la COTP lista su factura D 1; la carpeta dice compra, COTP y pagos'), true);

-- 9) Rechazos al ligar a mano; soltar sí se puede.
select set_config('app.co9', registrar_compra(
  jsonb_build_object('proveedor', 'OTRO PRUEBA86', 'factura', 'O1', 'fecha', '2001-07-04'),
  jsonb_build_array(jsonb_build_object('producto_id', current_setting('app.pa'), 'cantidad', 1, 'costo_unitario', 10))) ->> 'id', true);
select set_config('app.p9', '', true);
do $$
declare v_ok int := 0;
begin
  begin perform ligar_factura(current_setting('app.f2')::uuid, current_setting('app.co9')::uuid);
  exception when sqlstate '22023' then v_ok := v_ok + 1; end;   -- otro proveedor
  begin perform ligar_factura(current_setting('app.f2')::uuid, current_setting('app.co1')::uuid);
  exception when sqlstate '22023' then v_ok := v_ok + 1; end;   -- esa compra ya tiene su factura
  begin perform ligar_factura(current_setting('app.f2')::uuid, current_setting('app.co2')::uuid);
  exception when sqlstate '22023' then v_ok := v_ok + 1; end;   -- compra cancelada
  perform set_config('app.p9', v_ok::text, true);
end $$;
select desligar_factura(current_setting('app.f3')::uuid, 'compra');
select set_config('app.p9', concat(
  case when current_setting('app.p9') = '3'
        and (select compra_id from cfdi where id = current_setting('app.f3')::uuid) is null
       then 'ok' else 'FALLO' end, ' — 3 de 3 rechazos al ligar; soltar la compra sí'), true);

-- 10) Quien no es admin no ve ni liga.
select set_config('request.jwt.claims',
  json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
select set_config('app.p10', '', true);
do $$
declare v_ok int := 0;
begin
  begin perform factura_contexto(current_setting('app.f1')::uuid); exception when sqlstate '42501' then v_ok := v_ok + 1; end;
  begin perform ligar_factura(current_setting('app.f3')::uuid, current_setting('app.co3')::uuid); exception when sqlstate '42501' then v_ok := v_ok + 1; end;
  begin perform desligar_factura(current_setting('app.f1')::uuid, 'compra'); exception when sqlstate '42501' then v_ok := v_ok + 1; end;
  perform set_config('app.p10', concat(case when v_ok = 3 then 'ok' else 'FALLO' end, ' — sin rol de admin: 3 de 3 rechazadas'), true);
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
union all select 10, current_setting('app.p10')
order by 1;

rollback;
