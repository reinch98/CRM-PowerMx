-- Prueba de 61_expediente_cotizacion.sql. Correr DESPUÉS del 61, el bloque COMPLETO. begin/rollback.
-- SQL plano (sin bloques plpgsql); cada llamada que escribe va en su propia sentencia y su
-- comprobación en la siguiente. Consume folios (las secuencias no se revierten con el rollback).
--
-- El caso: una venta de 2,500 sin IVA (IVA 400, total 2,900) con 3 piezas de $100 de costo y un
-- servicio libre. Esperado al principio: material 300, utilidad 2,200.
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

select set_config('app.cli', gen_random_uuid()::text, true),
       set_config('app.prod', gen_random_uuid()::text, true),
       set_config('app.cot', gen_random_uuid()::text, true);

insert into clientes (id, nombre, telefono)
values (current_setting('app.cli')::uuid, 'PRUEBA-61', '9990000061');
insert into productos (id, sku, nombre, categoria, costo, activo)
values (current_setting('app.prod')::uuid, 'PRUEBA-61', 'Pieza de prueba', 'refaccion', 100, true);
insert into cotizaciones (id, cliente_id, tipo, estado, partidas, subtotal, descuento, iva, total)
values (current_setting('app.cot')::uuid, current_setting('app.cli')::uuid, 'venta', 'aceptada',
        jsonb_build_array(
          jsonb_build_object('producto_id', current_setting('app.prod'), 'sku', 'PRUEBA-61', 'descripcion', 'Pieza',
                             'cantidad', 3, 'precio_unitario', 500, 'importe', 1500),
          jsonb_build_object('producto_id', null, 'descripcion', 'Servicio de instalación',
                             'cantidad', 1, 'precio_unitario', 1000, 'importe', 1000)),
        2500, 0, 400, 2900);

-- 1) Sin movimientos: base 2,500, material 300, utilidad 2,200.
select set_config('app.r1', expediente_resumen(current_setting('app.cot')::uuid)::text, true);
select set_config('app.p1', concat(
  case when (current_setting('app.r1')::jsonb #>> '{ingreso,base}')::numeric = 2500
        and (current_setting('app.r1')::jsonb #>> '{material,total}')::numeric = 300
        and (current_setting('app.r1')::jsonb ->> 'utilidad')::numeric = 2200
        and (current_setting('app.r1')::jsonb #>> '{ingreso,por_cobrar}')::numeric = 2900
       then 'ok' else 'FALLO' end,
  ' — base ', current_setting('app.r1')::jsonb #>> '{ingreso,base}',
  ', material ', current_setting('app.r1')::jsonb #>> '{material,total}',
  ', utilidad ', current_setting('app.r1')::jsonb ->> 'utilidad'), true);

-- 2) Dos cobros: uno con comprobante y otro sin.
insert into expediente_movimientos (cotizacion_id, tipo, categoria, monto, forma, referencia, archivo)
values (current_setting('app.cot')::uuid, 'ingreso', 'cobro', 1000, 'transferencia', 'SPEI-1', 'prueba/a.pdf');
insert into expediente_movimientos (cotizacion_id, tipo, categoria, monto, forma)
values (current_setting('app.cot')::uuid, 'ingreso', 'cobro', 500, 'efectivo');
select set_config('app.r2', expediente_resumen(current_setting('app.cot')::uuid)::text, true);
select set_config('app.p2', concat(
  case when (current_setting('app.r2')::jsonb #>> '{ingreso,cobrado}')::numeric = 1500
        and (current_setting('app.r2')::jsonb #>> '{ingreso,comprobado}')::numeric = 1000
        and (current_setting('app.r2')::jsonb #>> '{ingreso,por_cobrar}')::numeric = 1400
       then 'ok' else 'FALLO' end,
  ' — cobrado ', current_setting('app.r2')::jsonb #>> '{ingreso,cobrado}',
  ', comprobado ', current_setting('app.r2')::jsonb #>> '{ingreso,comprobado}',
  ', por cobrar ', current_setting('app.r2')::jsonb #>> '{ingreso,por_cobrar}'), true);

-- 3) Egresos: gasolina con factura (232 con 32 de IVA → 200 sin IVA) y pago de técnico (800).
insert into expediente_movimientos (cotizacion_id, tipo, categoria, monto, iva, concepto)
values (current_setting('app.cot')::uuid, 'egreso', 'gasolina', 232, 32, 'Gasolina con factura');
insert into expediente_movimientos (cotizacion_id, tipo, categoria, monto, concepto, tecnico_id)
values (current_setting('app.cot')::uuid, 'egreso', 'tecnico', 800, 'Pago del técnico', current_setting('app.admin')::uuid);
select set_config('app.r3', expediente_resumen(current_setting('app.cot')::uuid)::text, true);
select set_config('app.p3', concat(
  case when (current_setting('app.r3')::jsonb #>> '{egresos,total_sin_iva}')::numeric = 1000
        and (current_setting('app.r3')::jsonb #>> '{egresos,por_categoria,gasolina,sin_iva}')::numeric = 200
        and (current_setting('app.r3')::jsonb ->> 'utilidad')::numeric = 1200
        and (current_setting('app.r3')::jsonb ->> 'margen_pct')::numeric = 48.0
       then 'ok' else 'FALLO' end,
  ' — egresos sin IVA ', current_setting('app.r3')::jsonb #>> '{egresos,total_sin_iva}',
  ', utilidad ', current_setting('app.r3')::jsonb ->> 'utilidad',
  ', margen ', current_setting('app.r3')::jsonb ->> 'margen_pct', ' %'), true);

-- 4) Cerrar sin forzar: se niega y dice por qué (falta cobrar, un cobro sin comprobante).
select set_config('app.r4', cerrar_expediente(current_setting('app.cot')::uuid)::text, true);
select set_config('app.p4', concat(
  case when (current_setting('app.r4')::jsonb ->> 'ok') = 'false'
        and jsonb_array_length(current_setting('app.r4')::jsonb -> 'avisos') = 2
        and (select expediente_cerrado_en from cotizaciones where id = current_setting('app.cot')::uuid) is null
       then 'ok' else 'FALLO' end,
  ' — avisos: ', current_setting('app.r4')::jsonb -> 'avisos'), true);

-- 5) Cerrar forzando: se congela.
select set_config('app.r5', cerrar_expediente(current_setting('app.cot')::uuid, true)::text, true);
select set_config('app.p5', concat(
  case when (current_setting('app.r5')::jsonb ->> 'ok') = 'true'
        and (select expediente_cerrado_en from cotizaciones where id = current_setting('app.cot')::uuid) is not null
        and (select (expediente_cierre ->> 'utilidad')::numeric from cotizaciones where id = current_setting('app.cot')::uuid) = 1200
       then 'ok' else 'FALLO' end,
  ' — cerrado con utilidad congelada en 1200'), true);

-- 6) El costo del catálogo sube a 500: el expediente CERRADO no se mueve; sigue en 1,200.
update productos set costo = 500 where id = current_setting('app.prod')::uuid;
select set_config('app.r6', expediente_resumen(current_setting('app.cot')::uuid)::text, true);
select set_config('app.p6', concat(
  case when (current_setting('app.r6')::jsonb ->> 'utilidad')::numeric = 1200
        and (current_setting('app.r6')::jsonb #>> '{material,total}')::numeric = 300
        and (current_setting('app.r6')::jsonb ->> 'cerrado') = 'true'
       then 'ok' else 'FALLO' end,
  ' — con el expediente cerrado, un costo nuevo no mueve la utilidad (',
  current_setting('app.r6')::jsonb ->> 'utilidad', ')'), true);

-- 7) Reabrir: ahora sí se recalcula con el costo nuevo (3 × 500 = 1,500 → utilidad 0).
select set_config('app.r7', reabrir_expediente(current_setting('app.cot')::uuid, 'prueba 61')::text, true);
select set_config('app.r7b', expediente_resumen(current_setting('app.cot')::uuid)::text, true);
select set_config('app.p7', concat(
  case when (current_setting('app.r7b')::jsonb ->> 'cerrado') = 'false'
        and (current_setting('app.r7b')::jsonb #>> '{material,total}')::numeric = 1500
        and (current_setting('app.r7b')::jsonb ->> 'utilidad')::numeric = 0
       then 'ok' else 'FALLO' end,
  ' — reabierto: material ', current_setting('app.r7b')::jsonb #>> '{material,total}',
  ', utilidad ', current_setting('app.r7b')::jsonb ->> 'utilidad'), true);

-- 8) Quedó rastro del cierre y de la reapertura.
select set_config('app.p8', concat(
  case when (select count(*) from auditoria where tabla = 'cotizaciones'
               and registro_id = current_setting('app.cot')::uuid
               and accion in ('cerrar_expediente', 'reabrir_expediente')) = 2
       then 'ok' else 'FALLO' end,
  ' — auditoría del cierre y la reapertura'), true);

-- 9) Una pieza sin costo se avisa (no se calla): el costo vuelve a cero.
update productos set costo = 0 where id = current_setting('app.prod')::uuid;
select set_config('app.r9', expediente_resumen(current_setting('app.cot')::uuid)::text, true);
select set_config('app.p9', concat(
  case when (current_setting('app.r9')::jsonb #>> '{material,sin_costo}')::int = 1
        and exists (select 1 from jsonb_array_elements_text(current_setting('app.r9')::jsonb -> 'avisos') a
                     where a like '%sin costo%')
       then 'ok' else 'FALLO' end,
  ' — una pieza sin costo capturado se avisa'), true);

select current_setting('app.p1') as resultado
union all select current_setting('app.p2')
union all select current_setting('app.p3')
union all select current_setting('app.p4')
union all select current_setting('app.p5')
union all select current_setting('app.p6')
union all select current_setting('app.p7')
union all select current_setting('app.p8')
union all select current_setting('app.p9');

-- No se prueba aquí porque lanza excepción (sin plpgsql abortaría el bloque): con el expediente
-- cerrado, un insert en expediente_movimientos y un cambio de partidas de la cotización se
-- rechazan con «El expediente está cerrado…». Comprobarlo a mano si se quiere.

rollback;
