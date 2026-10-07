-- Prueba de 63_cobranza_cotizacion.sql. Correr DESPUÉS del 63, el bloque COMPLETO. begin/rollback.
-- SQL plano; lo que escribe y su comprobación van en sentencias distintas.
-- Consume folios (las secuencias no se revierten con el rollback).
--
-- El caso: una venta con total de $2,900. Se cobra en dos pagos (1,000 y 1,900) con su comprobante
-- leído por la IA. Esperado: parcial con el primero, liquidada con el segundo.
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

select set_config('app.cli', gen_random_uuid()::text, true),
       set_config('app.cot', gen_random_uuid()::text, true);

insert into clientes (id, nombre, telefono)
values (current_setting('app.cli')::uuid, 'PRUEBA-63', '9990000063');
insert into cotizaciones (id, cliente_id, tipo, estado, partidas, subtotal, descuento, iva, total)
values (current_setting('app.cot')::uuid, current_setting('app.cli')::uuid, 'venta', 'aceptada',
        '[]'::jsonb, 2500, 0, 400, 2900);

-- 1) Sin cobros: pendiente.
select set_config('app.p1', concat(
  case when (select cobranza_estado from cotizaciones where id = current_setting('app.cot')::uuid) = 'pendiente'
       then 'ok' else 'FALLO' end, ' — sin cobros: pendiente'), true);

-- 2) Un cobro de 1,000 con comprobante LEÍDO que coincide: parcial (falta lo demás).
insert into expediente_movimientos (cotizacion_id, tipo, categoria, monto, forma, archivo, leido_ia, monto_leido)
values (current_setting('app.cot')::uuid, 'ingreso', 'cobro', 1000, 'transferencia', 'x/a.pdf', true, 1000);
select set_config('app.p2', concat(
  case when (select cobranza_estado from cotizaciones where id = current_setting('app.cot')::uuid) = 'parcial'
        and (select cobranza_liquidada_en from cotizaciones where id = current_setting('app.cot')::uuid) is null
       then 'ok' else 'FALLO' end, ' — un cobro verificado por 1,000: parcial'), true);

-- 3) El segundo cobro (1,900) con su comprobante leído que cuadra: la cobranza se LIQUIDA sola.
insert into expediente_movimientos (cotizacion_id, tipo, categoria, monto, forma, archivo, leido_ia, monto_leido, referencia)
values (current_setting('app.cot')::uuid, 'ingreso', 'cobro', 1900, 'transferencia', 'x/b.pdf', true, 1900, 'SPEI-63');
select set_config('app.p3', concat(
  case when (select cobranza_estado from cotizaciones where id = current_setting('app.cot')::uuid) = 'liquidada'
        and (select cobranza_liquidada_en from cotizaciones where id = current_setting('app.cot')::uuid) is not null
        and (select cobranza_manual from cotizaciones where id = current_setting('app.cot')::uuid) is false
       then 'ok' else 'FALLO' end, ' — 1,000 + 1,900 verificados = total: liquidada sola'), true);

-- 4) Borrar el cobro que la cerraba la vuelve a abrir.
delete from expediente_movimientos
 where cotizacion_id = current_setting('app.cot')::uuid and referencia = 'SPEI-63';
select set_config('app.p4', concat(
  case when (select cobranza_estado from cotizaciones where id = current_setting('app.cot')::uuid) = 'parcial'
        and (select cobranza_liquidada_en from cotizaciones where id = current_setting('app.cot')::uuid) is null
       then 'ok' else 'FALLO' end, ' — al borrar el cobro que la cerraba vuelve a parcial'), true);

-- 5) Un comprobante cuyo monto leído NO coincide con lo capturado no verifica nada.
insert into expediente_movimientos (cotizacion_id, tipo, categoria, monto, forma, archivo, leido_ia, monto_leido, referencia)
values (current_setting('app.cot')::uuid, 'ingreso', 'cobro', 1900, 'transferencia', 'x/c.pdf', true, 1800, 'SPEI-63B');
select set_config('app.p5', concat(
  case when (select cobranza_estado from cotizaciones where id = current_setting('app.cot')::uuid) = 'parcial'
       then 'ok' else 'FALLO' end, ' — leído 1,800 contra capturado 1,900: no cuadra, no liquida'), true);

-- 6) Un cobro con comprobante pero SIN leer tampoco liquida solo.
update expediente_movimientos set leido_ia = false, monto_leido = null
 where cotizacion_id = current_setting('app.cot')::uuid and referencia = 'SPEI-63B';
select set_config('app.p6', concat(
  case when (select cobranza_estado from cotizaciones where id = current_setting('app.cot')::uuid) = 'parcial'
       then 'ok' else 'FALLO' end, ' — comprobante sin leer: no liquida'), true);

-- 7) Dar por liquidada A MANO (una retención): queda liquidada, manual y con su motivo.
select set_config('app.r7', liquidar_cobranza(current_setting('app.cot')::uuid, 'Retención de ISR del cliente')::text, true);
select set_config('app.p7', concat(
  case when (select cobranza_estado from cotizaciones where id = current_setting('app.cot')::uuid) = 'liquidada'
        and (select cobranza_manual from cotizaciones where id = current_setting('app.cot')::uuid) is true
        and (select cobranza_nota from cotizaciones where id = current_setting('app.cot')::uuid) = 'Retención de ISR del cliente'
       then 'ok' else 'FALLO' end, ' — liquidada a mano con su motivo'), true);

-- 8) Y esa decisión manual NO se mueve sola: se borra un cobro y sigue liquidada.
delete from expediente_movimientos
 where cotizacion_id = current_setting('app.cot')::uuid and referencia = 'SPEI-63B';
select set_config('app.p8', concat(
  case when (select cobranza_estado from cotizaciones where id = current_setting('app.cot')::uuid) = 'liquidada'
       then 'ok' else 'FALLO' end, ' — lo manual no se recalcula solo'), true);

-- 9) Reabrirla suelta lo manual y recalcula con lo que de verdad hay (solo 1,000 verificado: parcial).
select set_config('app.r9', reabrir_cobranza(current_setting('app.cot')::uuid)::text, true);
select set_config('app.p9', concat(
  case when (select cobranza_estado from cotizaciones where id = current_setting('app.cot')::uuid) = 'parcial'
        and (select cobranza_manual from cotizaciones where id = current_setting('app.cot')::uuid) is false
        and (select cobranza_nota from cotizaciones where id = current_setting('app.cot')::uuid) is null
       then 'ok' else 'FALLO' end, ' — reabierta: se recalcula con lo verificado'), true);

-- 10) Si el total de la cotización baja a lo ya verificado (1,000), se liquida sola.
update cotizaciones set total = 1000 where id = current_setting('app.cot')::uuid;
select set_config('app.p10', concat(
  case when (select cobranza_estado from cotizaciones where id = current_setting('app.cot')::uuid) = 'liquidada'
       then 'ok' else 'FALLO' end, ' — al cambiar el total se vuelve a comparar'), true);

-- 11) El resumen del expediente trae el estado de la cobranza y lo verificado.
select set_config('app.r11', expediente_resumen(current_setting('app.cot')::uuid)::text, true);
select set_config('app.p11', concat(
  case when (current_setting('app.r11')::jsonb #>> '{ingreso,cobranza,estado}') = 'liquidada'
        and (current_setting('app.r11')::jsonb #>> '{ingreso,verificado}')::numeric = 1000
       then 'ok' else 'FALLO' end,
  ' — el resumen dice ', current_setting('app.r11')::jsonb #>> '{ingreso,cobranza,estado}',
  ' con ', current_setting('app.r11')::jsonb #>> '{ingreso,verificado}', ' verificados'), true);

-- 12) Quedó rastro de los cambios de estado.
select set_config('app.p12', concat(
  case when (select count(*) from auditoria where tabla = 'cotizaciones'
               and registro_id = current_setting('app.cot')::uuid
               and accion like 'cobranza_%') >= 5
       then 'ok' else 'FALLO' end, ' — auditoría de la cobranza'), true);

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

-- No se prueba aquí porque lanza excepción (sin plpgsql abortaría el bloque): liquidar sin motivo, o
-- con el expediente cerrado, se rechaza con su mensaje.

rollback;
