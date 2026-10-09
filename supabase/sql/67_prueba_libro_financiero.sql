-- Prueba de 67_libro_financiero.sql. Correr DESPUÉS del 66 y del 67, el bloque COMPLETO. begin/rollback.
-- SQL plano (sin bloques plpgsql); cada llamada que escribe va en su propia sentencia y su
-- comprobación en la siguiente. Consume folios (las secuencias no se revierten con el rollback).
--
-- Usa un RFC de prueba en `empresa_fiscal` (el rollback devuelve el real) y al admin como técnico.
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

update empresa_fiscal set rfc = 'PRUE850101AB1' where id;
-- El corte de pagos (70) nace con el día en que se aplicó; la orden de prueba es de hace 3 días.
-- (Sin el 70 aplicado esta línea falla: correr el 70 antes de repetir esta prueba.)
update pagos_tecnico_config set pagar_desde = current_date - 30 where id;

select set_config('app.h1', encode(sha256('prueba-67-uno'::bytea), 'hex'), true),
       set_config('app.h2', encode(sha256('prueba-67-dos'::bytea), 'hex'), true),
       set_config('app.h3', encode(sha256('prueba-67-tres'::bytea), 'hex'), true),
       set_config('app.cli', gen_random_uuid()::text, true),
       set_config('app.cot', gen_random_uuid()::text, true),
       set_config('app.orden', gen_random_uuid()::text, true);

-- 1) Un documento nuevo entra; el mismo archivo otra vez no.
select set_config('app.r1', registrar_documento('cfdi_xml', 'documentos/prueba1.xml', 'gas.xml', 'text/xml',
  current_setting('app.h1'), 'xml', null, '[]'::jsonb)::text, true);
select set_config('app.doc1', current_setting('app.r1')::jsonb ->> 'documento_id', true);
select set_config('app.r1b', registrar_documento('cfdi_xml', 'documentos/prueba1.xml', 'gas.xml', 'text/xml',
  current_setting('app.h1'), 'xml', null, '[]'::jsonb)::text, true);
select set_config('app.p1', concat(
  case when not (current_setting('app.r1')::jsonb ->> 'duplicado')::boolean
        and (current_setting('app.r1b')::jsonb ->> 'duplicado')::boolean
        and current_setting('app.r1b')::jsonb ->> 'documento_id' = current_setting('app.doc1')
       then 'ok' else 'FALLO' end, ' — el mismo archivo no entra dos veces'), true);

-- 2) Un CFDI donde tú eres el receptor queda como RECIBIDO y el documento pasa a "propuesto".
select set_config('app.r2', registrar_cfdi(jsonb_build_object(
  'uuid_fiscal', 'AAAAAAAA-0000-4000-8000-000000000067', 'tipo_comprobante', 'I', 'fecha', '2026-10-09T10:00:00-06:00',
  'rfc_emisor', 'SLA010101AAA', 'nombre_emisor', 'GASOLINERA DE PRUEBA', 'rfc_receptor', 'prue850101ab1',
  'subtotal', 700, 'total', 812, 'iva_trasladado', 112, 'metodo_pago', 'PUE', 'forma_pago', '04'),
  'documentos/prueba1.xml', current_setting('app.doc1')::uuid)::text, true);
select set_config('app.cfdi1', current_setting('app.r2')::jsonb ->> 'cfdi_id', true);
select set_config('app.p2', concat(
  case when current_setting('app.r2')::jsonb ->> 'sentido' = 'recibido'
        and (select estado from documentos where id = current_setting('app.doc1')::uuid) = 'propuesto'
        and (select uuid_fiscal from cfdi where id = current_setting('app.cfdi1')::uuid) = 'aaaaaaaa-0000-4000-8000-000000000067'
       then 'ok' else 'FALLO' end, ' — recibido, UUID en minúsculas, documento propuesto'), true);

-- 3) El mismo UUID otra vez no duplica el CFDI.
select set_config('app.r3', registrar_cfdi(jsonb_build_object(
  'uuid_fiscal', 'aaaaaaaa-0000-4000-8000-000000000067', 'fecha', '2026-10-09T10:00:00-06:00',
  'rfc_emisor', 'SLA010101AAA', 'rfc_receptor', 'PRUE850101AB1', 'total', 812))::text, true);
select set_config('app.p3', concat(
  case when (current_setting('app.r3')::jsonb ->> 'duplicado')::boolean
        and (select count(*) from cfdi where uuid_fiscal = 'aaaaaaaa-0000-4000-8000-000000000067') = 1
       then 'ok' else 'FALLO' end, ' — un CFDI no entra dos veces'), true);

-- 4) Aprobar como gasto pagado: egreso en el libro SIN cotización, con su CFDI, IVA y cuenta; aprende la regla.
select set_config('app.r4', aprobar_documento(current_setting('app.doc1')::uuid, jsonb_build_object(
  'accion', 'gasto', 'categoria', 'gasolina', 'monto', 812, 'iva', 112, 'fecha', '2026-10-09', 'pagado', true,
  'forma', 'tarjeta', 'cuenta_id', (select id from cuentas_financieras where lower(nombre) = 'banorte negocio')))::text, true);
select set_config('app.p4', concat(
  case when (select count(*) from expediente_movimientos m
              where m.cfdi_id = current_setting('app.cfdi1')::uuid and m.cotizacion_id is null
                and m.tipo = 'egreso' and m.categoria = 'gasolina' and m.monto = 812 and m.iva = 112
                and m.cuenta_id is not null and m.documento_id = current_setting('app.doc1')::uuid) = 1
        and (select estado from documentos where id = current_setting('app.doc1')::uuid) = 'aprobado'
        and (select categoria from reglas_clasificacion where rfc_emisor = 'SLA010101AAA') = 'gasolina'
       then 'ok' else 'FALLO' end, ' — gasto en el libro sin cotización; la regla del proveedor se aprendió'), true);

-- 5) Aprobar de nuevo no repite el movimiento.
select set_config('app.r5', aprobar_documento(current_setting('app.doc1')::uuid, '{"accion":"gasto","categoria":"gasolina"}'::jsonb)::text, true);
select set_config('app.p5', concat(
  case when (current_setting('app.r5')::jsonb ->> 'sin_cambio')::boolean
        and (select count(*) from expediente_movimientos where cfdi_id = current_setting('app.cfdi1')::uuid) = 1
       then 'ok' else 'FALLO' end, ' — aprobar dos veces no duplica'), true);

-- 6) Una factura PPD "aún no la pago": se aprueba sin movimiento (queda por pagar).
select set_config('app.r6', registrar_documento('cfdi_xml', 'documentos/prueba2.xml', 'ppd.xml', 'text/xml',
  current_setting('app.h2'), 'xml', null, '[]'::jsonb)::text, true);
select set_config('app.doc2', current_setting('app.r6')::jsonb ->> 'documento_id', true);
select set_config('app.r6b', registrar_cfdi(jsonb_build_object(
  'uuid_fiscal', 'bbbbbbbb-0000-4000-8000-000000000067', 'fecha', '2026-10-08T10:00:00-06:00',
  'rfc_emisor', 'REF010101BBB', 'rfc_receptor', 'PRUE850101AB1', 'total', 5000, 'iva_trasladado', 689.66,
  'metodo_pago', 'PPD'), 'documentos/prueba2.xml', current_setting('app.doc2')::uuid)::text, true);
select set_config('app.r6c', aprobar_documento(current_setting('app.doc2')::uuid,
  '{"accion":"gasto","categoria":"material","pagado":false}'::jsonb)::text, true);
select set_config('app.p6', concat(
  case when (select estado from documentos where id = current_setting('app.doc2')::uuid) = 'aprobado'
        and (select count(*) from expediente_movimientos
              where cfdi_id = (current_setting('app.r6b')::jsonb ->> 'cfdi_id')::uuid) = 0
       then 'ok' else 'FALLO' end, ' — por pagar: aprobado sin movimiento'), true);

-- 7) Una factura EMITIDA se reconoce, se sugiere su cotización por total y se liga.
insert into clientes (id, nombre, telefono) values (current_setting('app.cli')::uuid, 'PRUEBA-67', '9990000067');
insert into cotizaciones (id, cliente_id, tipo, estado, partidas, subtotal, descuento, iva, total)
values (current_setting('app.cot')::uuid, current_setting('app.cli')::uuid, 'venta', 'aceptada', '[]'::jsonb, 30000, 0, 4800, 34800);
select set_config('app.r7', registrar_documento('cfdi_xml', 'documentos/prueba3.xml', 'emitida.xml', 'text/xml',
  current_setting('app.h3'), 'xml', null, '[]'::jsonb)::text, true);
select set_config('app.r7b', registrar_cfdi(jsonb_build_object(
  'uuid_fiscal', 'cccccccc-0000-4000-8000-000000000067', 'fecha', '2026-10-07T10:00:00-06:00',
  'rfc_emisor', 'PRUE850101AB1', 'rfc_receptor', 'XEXX010101000', 'total', 34800, 'iva_trasladado', 4800,
  'isr_retenido', 375), 'documentos/prueba3.xml', (current_setting('app.r7')::jsonb ->> 'documento_id')::uuid)::text, true);
select set_config('app.cfdi3', current_setting('app.r7b')::jsonb ->> 'cfdi_id', true);
select set_config('app.r7c', sugerir_cotizaciones_para_cfdi(current_setting('app.cfdi3')::uuid)::text, true);
select set_config('app.r7d', ligar_cfdi_cotizacion(current_setting('app.cfdi3')::uuid, current_setting('app.cot')::uuid)::text, true);
select set_config('app.p7', concat(
  case when current_setting('app.r7b')::jsonb ->> 'sentido' = 'emitido'
        and exists (select 1 from jsonb_array_elements(current_setting('app.r7c')::jsonb) e
                     where e ->> 'cotizacion_id' = current_setting('app.cot') and (e ->> 'coincide_total')::boolean)
        and (select cotizacion_id::text from cfdi where id = current_setting('app.cfdi3')::uuid) = current_setting('app.cot')
       then 'ok' else 'FALLO' end, ' — emitida: se sugiere la cotización por total y se liga'), true);

-- 8) Un retiro del dueño entra al libro sin cotización; las restricciones nuevas existen.
insert into expediente_movimientos (tipo, categoria, fecha, monto, concepto)
values ('egreso', 'retiro_dueno', current_date, 5000, 'PRUEBA-67 retiro');
select set_config('app.p8', concat(
  case when (select count(*) from expediente_movimientos where concepto = 'PRUEBA-67 retiro' and cotizacion_id is null) = 1
        and (select count(*) from pg_constraint
              where conrelid = 'public.expediente_movimientos'::regclass
                and conname in ('expediente_cobro_con_cotizacion', 'expediente_tipo_categoria', 'expediente_categoria_valida')) = 3
       then 'ok' else 'FALLO' end, ' — retiro sin cotización; un cobro sin cotización lo prohíbe la base'), true);

-- 9) Comisiones: la orden cerrada se ve "en revisión" y SIN monto antes de aprobar.
insert into tarifas_pago_tecnico (tipo_servicio, rol, monto, vigente_desde) values ('preventivo', 'responsable', 600, '2000-01-01');
insert into ordenes_servicio (id, cliente_id, fecha, tipo_servicio, estado, tecnico_id)
values (current_setting('app.orden')::uuid, current_setting('app.cli')::uuid, current_date - 3, 'preventivo', 'cerrada',
        current_setting('app.admin')::uuid);
select set_config('app.r9', mis_comisiones(30)::text, true);
select set_config('app.p9', concat(
  case when (select e ->> 'estado' = 'en_revision' and e -> 'monto' = 'null'::jsonb
               from jsonb_array_elements(current_setting('app.r9')::jsonb -> 'ordenes') e
              where e ->> 'orden_id' = current_setting('app.orden'))
       then 'ok' else 'FALLO' end, ' — antes de aprobar: en revisión, sin monto'), true);

-- 10) Al aprobar el pago, el técnico ve el monto ("aprobada") y suma en "por cobrar".
select set_config('app.r10', proponer_pago_tecnico(current_setting('app.admin')::uuid, current_date - 3, current_date - 3)::text, true);
select set_config('app.pago', current_setting('app.r10')::jsonb ->> 'pago_id', true);
select set_config('app.r10b', aprobar_pago_tecnico(current_setting('app.pago')::uuid)::text, true);
select set_config('app.r10c', mis_comisiones(30)::text, true);
select set_config('app.p10', concat(
  case when (select e ->> 'estado' = 'aprobada' and (e ->> 'monto')::numeric = 600
               from jsonb_array_elements(current_setting('app.r10c')::jsonb -> 'ordenes') e
              where e ->> 'orden_id' = current_setting('app.orden'))
        and (current_setting('app.r10c')::jsonb #>> '{resumen,por_cobrar}')::numeric >= 600
       then 'ok' else 'FALLO' end, ' — aprobado: el técnico ve 600 por cobrar'), true);

-- 11) Registrar con cuenta: la orden SIN cotización va al libro general y la comisión queda "pagada".
select set_config('app.r11', registrar_pago_tecnico(current_setting('app.pago')::uuid, 'transferencia', null, current_date, null,
  (select id from cuentas_financieras where lower(nombre) = 'banorte negocio'))::text, true);
select set_config('app.r11b', mis_comisiones(30)::text, true);
select set_config('app.p11', concat(
  case when (select count(*) from expediente_movimientos
              where categoria = 'tecnico' and cotizacion_id is null and monto = 600 and cuenta_id is not null
                and notas = format('Pago a técnicos PAGO-%s', (select folio from pagos_tecnico where id = current_setting('app.pago')::uuid))) = 1
        and (select e ->> 'estado' from jsonb_array_elements(current_setting('app.r11b')::jsonb -> 'ordenes') e
              where e ->> 'orden_id' = current_setting('app.orden')) = 'pagada'
       then 'ok' else 'FALLO' end, ' — sin cotización: al libro general; comisión pagada'), true);

-- 12) Quien no es admin no ve nada de finanzas, y sin perfil no ve comisiones.
select set_config('request.jwt.claims',
  json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
set local role authenticated;
select set_config('app.p12', concat(
  case when (select count(*) from cfdi) = 0 and (select count(*) from documentos) = 0
        and (select count(*) from cuentas_financieras) = 0 and (select count(*) from empresa_fiscal) = 0
        and (select count(*) from reglas_clasificacion) = 0
        and jsonb_array_length(mis_comisiones(30) -> 'ordenes') = 0
       then 'ok' else 'FALLO' end, ' — sin ser admin: finanzas vacías y sin comisiones ajenas'), true);
reset role;

select current_setting('app.p1') as resultado
union all select current_setting('app.p2')
union all select current_setting('app.p3')
union all select current_setting('app.p4')
union all select current_setting('app.p5')
union all select current_setting('app.p6')
union all select current_setting('app.p7')
union all select current_setting('app.p8')
union all select current_setting('app.p9')
union all select current_setting('app.p10')
union all select current_setting('app.p11')
union all select current_setting('app.p12');

-- No se prueba aquí porque lanza excepción (sin plpgsql abortaría el bloque):
--   · registrar_cfdi de un RFC que no es tuyo → «Este CFDI no es de tu RFC…».
--   · registrar_cfdi sin RFC capturado en empresa_fiscal → «Primero captura tu RFC…».
--   · un cobro sin cotización → viola expediente_cobro_con_cotizacion.
--   · aprobar como gasto un CFDI que ya tiene pago → «Ese CFDI ya tiene un pago registrado».
--   · rechazar un documento ya aprobado, o sin motivo.
--   · cualquier función de finanzas llamada por quien no es admin → «Solo el administrador…».

rollback;
