-- Prueba de 85_pagos_proveedor.sql. Correr DESPUÉS del 85, el bloque COMPLETO, con la CLI:
--   npx supabase db query --linked -f supabase/sql/85_prueba_pagos_proveedor.sql
-- begin/rollback, con bloques `do` para los rechazos (el editor web los mutila; la CLI no).
-- Nombres "PRUEBA85", fechas de 2001. Consume folios.
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

-- Dos facturas por pagar del mismo proveedor (el disparador de la 80 crea su ficha) y una de otro.
insert into cfdi (uuid_fiscal, sentido, fecha, rfc_emisor, nombre_emisor, rfc_receptor, subtotal, iva_trasladado, total, por_pagar, vence, serie, folio)
values ('85858585-0000-4000-8000-000000000001', 'recibido', '2001-05-01', 'PCO010101AB5', 'PROVEEDOR PRUEBA85 SA DE CV', 'XAXX010101000', 1000, 160, 1160, true, '2001-05-31', 'A', '1'),
       ('85858585-0000-4000-8000-000000000002', 'recibido', '2001-05-02', 'PCO010101AB5', 'PROVEEDOR PRUEBA85 SA DE CV', 'XAXX010101000', 2000, 320, 2320, true, '2001-06-01', 'A', '2'),
       ('85858585-0000-4000-8000-000000000003', 'recibido', '2001-05-02', 'OTR010101AB5', 'OTRO PRUEBA85', 'XAXX010101000', 500, 80, 580, true, '2001-06-01', 'B', '9');
select set_config('app.f1', (select id::text from cfdi where uuid_fiscal = '85858585-0000-4000-8000-000000000001'), true),
       set_config('app.f2', (select id::text from cfdi where uuid_fiscal = '85858585-0000-4000-8000-000000000002'), true),
       set_config('app.f3', (select id::text from cfdi where uuid_fiscal = '85858585-0000-4000-8000-000000000003'), true);
select set_config('app.prov', (select proveedor_id::text from cfdi where id = current_setting('app.f1')::uuid), true),
       set_config('app.pa', gen_random_uuid()::text, true);
insert into productos (id, sku, nombre, categoria, unidad, activo, publicar) values
  (current_setting('app.pa')::uuid, 'P85-A', 'Pieza PRUEBA85', 'refaccion', 'pieza', true, false);
select set_config('app.cot', registrar_cotizacion_proveedor(
  jsonb_build_object('proveedor_id', current_setting('app.prov'), 'numero', 'Q-85'),
  jsonb_build_array(jsonb_build_object('producto_id', current_setting('app.pa'), 'cantidad', 1, 'precio_unitario', 1000))) ->> 'id', true);
select set_config('app.doc', (registrar_documento('factura_pdf', 'documentos/p85.pdf', 'spei.pdf', 'application/pdf',
                                                   repeat('5', 64), 'manual', null, '[]'::jsonb) ->> 'documento_id'), true);

-- 1) Opciones: reconoce al proveedor por el texto, sus 2 facturas (la de 1,160 exacta) y su cotización.
select set_config('app.op', opciones_pago_proveedor('Proveedor Prueba85, S.A. de C.V.', 1160)::text, true);
select set_config('app.p1', concat(
  case when current_setting('app.op')::jsonb -> 'proveedor' ->> 'id' = current_setting('app.prov')
        and jsonb_array_length(current_setting('app.op')::jsonb -> 'facturas') = 2
        and (current_setting('app.op')::jsonb -> 'facturas' -> 0 ->> 'cfdi_id') = current_setting('app.f1')
        and (current_setting('app.op')::jsonb -> 'facturas' -> 0 ->> 'exacta')::boolean
        and jsonb_array_length(current_setting('app.op')::jsonb -> 'cotizaciones') = 1
        and opciones_pago_proveedor('Nadie PRUEBA85') -> 'proveedor' = 'null'::jsonb
       then 'ok' else 'FALLO' end, ' — opciones: proveedor reconocido, 2 facturas (la exacta primero), 1 cotización'), true);

-- 2) Pagar la factura exacta con el comprobante de la bandeja.
select set_config('app.r2', registrar_pago_proveedor(jsonb_build_object(
  'proveedor_id', current_setting('app.prov'), 'monto', 1160, 'fecha', '2001-05-10', 'forma', 'transferencia',
  'referencia', 'RASTREO85', 'cfdi_id', current_setting('app.f1'), 'documento_id', current_setting('app.doc')))::text, true);
select set_config('app.m2', current_setting('app.r2')::jsonb ->> 'movimiento_id', true);
select set_config('app.p2', concat(
  case when current_setting('app.r2')::jsonb ->> 'tipo' = 'pago_factura'
        and (current_setting('app.r2')::jsonb ->> 'saldo')::numeric = 0
        and (select proveedor_id::text = current_setting('app.prov') and cfdi_id::text = current_setting('app.f1')
                    and archivo = 'documentos/p85.pdf' and iva = 160
               from expediente_movimientos where id = current_setting('app.m2')::uuid)
        and (select estado = 'aprobado' and movimiento_id::text = current_setting('app.m2')
               from documentos where id = current_setting('app.doc')::uuid)
       then 'ok' else 'FALLO' end, ' — pagó la factura: saldo 0, IVA 160, comprobante ligado y aprobado en la bandeja'), true);

-- 3) La misma clave de rastreo otra vez: no escribe nada y pide confirmar.
select set_config('app.n3', (select count(*)::text from expediente_movimientos where proveedor_id::text = current_setting('app.prov')), true);
select set_config('app.r3', registrar_pago_proveedor(jsonb_build_object(
  'proveedor_id', current_setting('app.prov'), 'monto', 99, 'fecha', '2001-06-20', 'referencia', 'RASTREO85'))::text, true);
select set_config('app.p3', concat(
  case when (current_setting('app.r3')::jsonb ->> 'requiere_confirmar')::boolean
        and current_setting('app.r3')::jsonb -> 'avisos' ->> 0 like '%MISMA referencia%'
        and (select count(*)::text from expediente_movimientos where proveedor_id::text = current_setting('app.prov')) = current_setting('app.n3')
       then 'ok' else 'FALLO' end, ' — misma referencia: pide confirmar y no escribe'), true);

-- 4) Rechazos: pago mayor que el saldo; factura de otro proveedor.
select set_config('app.p4', '', true);
do $$
declare v_ok int := 0;
begin
  begin perform registrar_pago_proveedor(jsonb_build_object('proveedor_id', current_setting('app.prov'), 'monto', 3000,
          'cfdi_id', current_setting('app.f2')));
  exception when sqlstate '22023' then v_ok := v_ok + 1; end;
  begin perform registrar_pago_proveedor(jsonb_build_object('proveedor_id', current_setting('app.prov'), 'monto', 580,
          'cfdi_id', current_setting('app.f3')));
  exception when sqlstate '22023' then v_ok := v_ok + 1; end;
  perform set_config('app.p4', concat(case when v_ok = 2 then 'ok' else 'FALLO' end,
    ' — rechaza pago mayor que el saldo y factura de otro proveedor (', v_ok, ' de 2)'), true);
end $$;

-- 5) Anticipo de la cotización: sin IVA, ligado a ella, y aparece con la factura que lo cubre.
select set_config('app.r5', registrar_pago_proveedor(jsonb_build_object(
  'proveedor_id', current_setting('app.prov'), 'monto', 500, 'fecha', '2001-05-12',
  'cotizacion_proveedor_id', current_setting('app.cot')))::text, true);
select set_config('app.m5', current_setting('app.r5')::jsonb ->> 'movimiento_id', true);
select set_config('app.ant', anticipos_proveedor(current_setting('app.prov')::uuid)::text, true);
select set_config('app.p5', concat(
  case when current_setting('app.r5')::jsonb ->> 'tipo' = 'anticipo'
        and (select iva = 0 and cfdi_id is null and categoria = 'pago_proveedor'
                    and cotizacion_proveedor_id::text = current_setting('app.cot')
               from expediente_movimientos where id = current_setting('app.m5')::uuid)
        and jsonb_array_length(current_setting('app.ant')::jsonb) = 1
        and current_setting('app.ant')::jsonb -> 0 -> 'facturas' -> 0 ->> 'cfdi_id' = current_setting('app.f2')
        and current_setting('app.ant')::jsonb -> 0 ->> 'cotizacion_proveedor' like 'COTP-%'
       then 'ok' else 'FALLO' end, ' — anticipo de la cotización: sin IVA, listado con la factura que lo cubre'), true);

-- 6) Mismo proveedor y monto en menos de 7 días: pide confirmar; confirmado, se registra.
select set_config('app.r6a', registrar_pago_proveedor(jsonb_build_object(
  'proveedor_id', current_setting('app.prov'), 'monto', 500, 'fecha', '2001-05-14'))::text, true);
select set_config('app.r6', registrar_pago_proveedor(jsonb_build_object(
  'proveedor_id', current_setting('app.prov'), 'monto', 500, 'fecha', '2001-05-14'), true)::text, true);
select set_config('app.m6', current_setting('app.r6')::jsonb ->> 'movimiento_id', true);
select set_config('app.p6', concat(
  case when (current_setting('app.r6a')::jsonb ->> 'requiere_confirmar')::boolean
        and current_setting('app.r6')::jsonb ->> 'tipo' = 'anticipo'
       then 'ok' else 'FALLO' end, ' — mismo monto en la semana: pide confirmar; confirmado entra'), true);

-- 7) Aplicar el anticipo de 500 a la factura de 2,320: saldo 1,820 e IVA proporcional (68.97).
select set_config('app.r7', aplicar_anticipo(current_setting('app.m5')::uuid, current_setting('app.f2')::uuid)::text, true);
select set_config('app.p7', concat(
  case when (current_setting('app.r7')::jsonb ->> 'saldo')::numeric = 1820
        and (select iva from expediente_movimientos where id = current_setting('app.m5')::uuid) = 68.97
        and jsonb_array_length(anticipos_proveedor(current_setting('app.prov')::uuid)) = 1
       then 'ok' else 'FALLO' end, ' — anticipo aplicado: saldo 1,820, IVA 68.97, queda 1 anticipo'), true);

-- 8) Rechazos al aplicar: factura de otro proveedor; anticipo mayor que el saldo (la factura 1 ya está pagada).
select set_config('app.p8', '', true);
do $$
declare v_ok int := 0;
begin
  begin perform aplicar_anticipo(current_setting('app.m6')::uuid, current_setting('app.f3')::uuid);
  exception when sqlstate '22023' then v_ok := v_ok + 1; end;
  begin perform aplicar_anticipo(current_setting('app.m6')::uuid, current_setting('app.f1')::uuid);
  exception when sqlstate '22023' then v_ok := v_ok + 1; end;
  begin perform aplicar_anticipo(current_setting('app.m5')::uuid, current_setting('app.f2')::uuid);   -- ya aplicado
  exception when sqlstate '22023' then v_ok := v_ok + 1; end;
  perform set_config('app.p8', concat(case when v_ok = 3 then 'ok' else 'FALLO' end,
    ' — no se aplica a otro proveedor, a una factura ya pagada, ni dos veces (', v_ok, ' de 3)'), true);
end $$;

-- 9) Quitarlo de la factura: vuelve a ser anticipo y la carpeta suma 1,000 en anticipos.
select quitar_anticipo_de_factura(current_setting('app.m5')::uuid, 'Era de otra factura');
select set_config('app.p9', concat(
  case when (select cfdi_id is null and iva = 0 from expediente_movimientos where id = current_setting('app.m5')::uuid)
        and (carpeta_proveedor(current_setting('app.prov')::uuid) -> 'resumen' ->> 'anticipos')::numeric = 1000
        and (carpeta_proveedor(current_setting('app.prov')::uuid) -> 'resumen' ->> 'por_pagar')::numeric = 2320
       then 'ok' else 'FALLO' end, ' — quitado: vuelve a anticipo; carpeta: 1,000 en anticipos y 2,320 por pagar'), true);

-- 10) Quien no es admin no registra ni ve anticipos.
select set_config('request.jwt.claims',
  json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
select set_config('app.p10', '', true);
do $$
declare v_ok int := 0;
begin
  begin perform anticipos_proveedor(); exception when sqlstate '42501' then v_ok := v_ok + 1; end;
  begin perform registrar_pago_proveedor('{"proveedor":"X","monto":1}'::jsonb); exception when sqlstate '42501' then v_ok := v_ok + 1; end;
  begin perform opciones_pago_proveedor('X'); exception when sqlstate '42501' then v_ok := v_ok + 1; end;
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
