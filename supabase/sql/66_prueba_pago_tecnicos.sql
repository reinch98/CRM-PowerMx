-- Prueba de 66_pago_tecnicos.sql. Correr DESPUÉS del 66, el bloque COMPLETO. begin/rollback.
-- SQL plano (sin bloques plpgsql); cada llamada que escribe va en su propia sentencia y su
-- comprobación en la siguiente. Consume folios (las secuencias no se revierten con el rollback).
--
-- Las órdenes de prueba llevan fechas de enero de 2001 para que no se mezclen con las reales.
-- El caso: tres órdenes cerradas del mismo técnico (se usa al admin como técnico).
--   · preventivo con cotización  → tarifa 600
--   · correctivo sin cotización  → tarifa 900
--   · instalación                → SIN tarifa (no se paga, se avisa)
-- Esperado al proponer: 2 servicios, total 1,500, 1 sin tarifa.
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

-- El corte de pagos (70) nace con el día en que se aplicó; las órdenes de prueba son de 2001.
-- (Sin el 70 aplicado esta línea falla: correr el 70 antes de repetir esta prueba.)
update pagos_tecnico_config set pagar_desde = '2000-01-01' where id;

select set_config('app.cli', gen_random_uuid()::text, true),
       set_config('app.cot', gen_random_uuid()::text, true),
       set_config('app.cita', gen_random_uuid()::text, true),
       set_config('app.o1', gen_random_uuid()::text, true),
       set_config('app.o2', gen_random_uuid()::text, true),
       set_config('app.o3', gen_random_uuid()::text, true);

insert into clientes (id, nombre, telefono) values (current_setting('app.cli')::uuid, 'PRUEBA-66', '9990000066');
insert into cotizaciones (id, cliente_id, tipo, estado, partidas, subtotal, descuento, iva, total)
values (current_setting('app.cot')::uuid, current_setting('app.cli')::uuid, 'venta', 'aceptada',
        jsonb_build_array(jsonb_build_object('producto_id', null, 'descripcion', 'Servicio', 'cantidad', 1,
                                             'precio_unitario', 1000, 'importe', 1000)),
        1000, 0, 160, 1160);
insert into citas (id, cliente_id, tipo_servicio, fecha, estado, cotizacion_id)
values (current_setting('app.cita')::uuid, current_setting('app.cli')::uuid, 'preventivo', '2001-01-15', 'realizada',
        current_setting('app.cot')::uuid);
insert into ordenes_servicio (id, cliente_id, cita_id, fecha, tipo_servicio, estado, tecnico_id) values
  (current_setting('app.o1')::uuid, current_setting('app.cli')::uuid, current_setting('app.cita')::uuid,
   '2001-01-15', 'preventivo', 'cerrada', current_setting('app.admin')::uuid),
  (current_setting('app.o2')::uuid, current_setting('app.cli')::uuid, null,
   '2001-01-16', 'correctivo', 'cerrada', current_setting('app.admin')::uuid),
  (current_setting('app.o3')::uuid, current_setting('app.cli')::uuid, null,
   '2001-01-17', 'instalacion', 'cerrada', current_setting('app.admin')::uuid);

insert into tarifas_pago_tecnico (tipo_servicio, rol, monto, vigente_desde) values
  ('preventivo', 'responsable', 600, '2000-01-01'),
  ('correctivo', 'responsable', 900, '2000-01-01');

-- 1) Antes de proponer: por_pagar_tecnicos ve las 3 órdenes del técnico, 1 sin tarifa, estimado 1,500.
select set_config('app.r1', por_pagar_tecnicos('2001-12-31')::text, true);
select set_config('app.p1', concat(
  case when (select (e ->> 'ordenes')::int = 3 and (e ->> 'sin_tarifa')::int = 1 and (e ->> 'estimado')::numeric = 1500
               from jsonb_array_elements(current_setting('app.r1')::jsonb) e
              where e ->> 'tecnico_id' = current_setting('app.admin'))
       then 'ok' else 'FALLO' end,
  ' — por pagar: ', current_setting('app.r1')), true);

-- 2) Proponer: 2 servicios, 1 sin tarifa, total 1,500.
select set_config('app.r2', proponer_pago_tecnico(current_setting('app.admin')::uuid, '2001-01-01', '2001-01-31')::text, true);
select set_config('app.pago', current_setting('app.r2')::jsonb ->> 'pago_id', true);
select set_config('app.p2', concat(
  case when (current_setting('app.r2')::jsonb ->> 'servicios')::int = 2
        and (current_setting('app.r2')::jsonb ->> 'total')::numeric = 1500
        and jsonb_array_length(current_setting('app.r2')::jsonb -> 'sin_tarifa') = 1
        and current_setting('app.r2')::jsonb #>> '{sin_tarifa,0,tipo_servicio}' = 'instalacion'
       then 'ok' else 'FALLO' end,
  ' — servicios ', current_setting('app.r2')::jsonb ->> 'servicios',
  ', total ', current_setting('app.r2')::jsonb ->> 'total'), true);

-- 3) Un anticipo de -200: el total baja a 1,300.
select set_config('app.r3', ajustar_pago_tecnico(current_setting('app.pago')::uuid, 'Anticipo', -200)::text, true);
select set_config('app.p3', concat(
  case when (current_setting('app.r3')::jsonb ->> 'total')::numeric = 1300 then 'ok' else 'FALLO' end,
  ' — total con anticipo ', current_setting('app.r3')::jsonb ->> 'total'), true);

-- 4) Proponer otra vez REHACE el borrador, no apila: sigue habiendo uno, conserva el ajuste (1,300).
select set_config('app.r4', proponer_pago_tecnico(current_setting('app.admin')::uuid, '2001-01-01', '2001-01-31')::text, true);
select set_config('app.p4', concat(
  case when (select count(*) from pagos_tecnico
              where tecnico_id = current_setting('app.admin')::uuid and estado = 'propuesto') = 1
        and (current_setting('app.r4')::jsonb ->> 'pago_id') = current_setting('app.pago')
        and (current_setting('app.r4')::jsonb ->> 'total')::numeric = 1300
        and (select count(*) from pagos_tecnico_lineas
              where pago_id = current_setting('app.pago')::uuid and activa) = 3
       then 'ok' else 'FALLO' end,
  ' — un borrador, 3 líneas (2 servicios + 1 ajuste), total ', current_setting('app.r4')::jsonb ->> 'total'), true);

-- 5) Aprobar y volver a aprobar (sin_cambio).
select set_config('app.r5', aprobar_pago_tecnico(current_setting('app.pago')::uuid)::text, true);
select set_config('app.r5b', aprobar_pago_tecnico(current_setting('app.pago')::uuid)::text, true);
select set_config('app.p5', concat(
  case when (select estado from pagos_tecnico where id = current_setting('app.pago')::uuid) = 'aprobado'
        and (current_setting('app.r5b')::jsonb ->> 'sin_cambio')::boolean
       then 'ok' else 'FALLO' end,
  ' — aprobado; el segundo intento no cambia nada'), true);

-- 6) Registrar el pago: queda pagado y SOLO la orden con cotización (600) carga un egreso 'tecnico'.
select set_config('app.r6', registrar_pago_tecnico(current_setting('app.pago')::uuid, 'transferencia', 'SPEI-66', '2001-01-31')::text, true);
select set_config('app.p6', concat(
  case when (select estado from pagos_tecnico where id = current_setting('app.pago')::uuid) = 'pagado'
        and (current_setting('app.r6')::jsonb ->> 'expedientes_cargados')::int = 1
        and (select count(*) from expediente_movimientos
              where cotizacion_id = current_setting('app.cot')::uuid and categoria = 'tecnico') = 1
        and (select monto from expediente_movimientos
              where cotizacion_id = current_setting('app.cot')::uuid and categoria = 'tecnico') = 600
       then 'ok' else 'FALLO' end,
  ' — pagado; egreso al expediente: ',
  coalesce((select monto::text from expediente_movimientos
             where cotizacion_id = current_setting('app.cot')::uuid and categoria = 'tecnico'), 'ninguno')), true);

-- 7) Registrar de nuevo no repite el egreso.
select set_config('app.r7', registrar_pago_tecnico(current_setting('app.pago')::uuid, 'transferencia', 'SPEI-66', '2001-01-31')::text, true);
select set_config('app.p7', concat(
  case when (current_setting('app.r7')::jsonb ->> 'sin_cambio')::boolean
        and (select count(*) from expediente_movimientos
              where cotizacion_id = current_setting('app.cot')::uuid and categoria = 'tecnico') = 1
       then 'ok' else 'FALLO' end,
  ' — un segundo registro no duplica el egreso'), true);

-- 8) Ya pagadas, esas dos órdenes no vuelven a salir: proponer de nuevo trae 0 servicios, y se cancela.
select set_config('app.r8', proponer_pago_tecnico(current_setting('app.admin')::uuid, '2001-01-01', '2001-01-31')::text, true);
select set_config('app.pago2', current_setting('app.r8')::jsonb ->> 'pago_id', true);
select set_config('app.r8b', cancelar_pago_tecnico(current_setting('app.pago2')::uuid, 'Prueba')::text, true);
select set_config('app.p8', concat(
  case when (current_setting('app.r8')::jsonb ->> 'servicios')::int = 0
        and (select estado from pagos_tecnico where id = current_setting('app.pago2')::uuid) = 'cancelado'
       then 'ok' else 'FALLO' end,
  ' — una orden pagada no se paga dos veces; el borrador vacío se cancela'), true);

-- 9) Queda pendiente solo la orden sin tarifa.
select set_config('app.r9', por_pagar_tecnicos('2001-12-31')::text, true);
select set_config('app.p9', concat(
  case when (select (e ->> 'ordenes')::int = 1 and (e ->> 'sin_tarifa')::int = 1 and (e ->> 'estimado')::numeric = 0
               from jsonb_array_elements(current_setting('app.r9')::jsonb) e
              where e ->> 'tecnico_id' = current_setting('app.admin'))
       then 'ok' else 'FALLO' end,
  ' — por pagar ahora: ', current_setting('app.r9')), true);

-- 10) Quien no es admin no ve nada de esto (RLS). Se simula con una sesión sin perfil.
select set_config('request.jwt.claims',
  json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
set local role authenticated;
select set_config('app.p10', concat(
  case when (select count(*) from pagos_tecnico) = 0
        and (select count(*) from pagos_tecnico_lineas) = 0
        and (select count(*) from tarifas_pago_tecnico) = 0
        and (select count(*) from tecnicos_pago) = 0
       then 'ok' else 'FALLO' end,
  ' — sin ser admin, las cuatro tablas se ven vacías'), true);
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
union all select current_setting('app.p10');

-- No se prueba aquí porque lanza excepción (sin plpgsql abortaría el bloque):
--   · proponer/aprobar/registrar/ajustar/cancelar como NO admin → «Solo el administrador…».
--   · proponer con un pago aprobado sin registrar → «Ese técnico tiene un pago aprobado…».
--   · registrar con el expediente de la cotización cerrado → «El expediente está cerrado…» y
--     NO queda nada a medias (el pago sigue aprobado).
--   · aprobar un pago en cero, ajustar en cero o sin concepto, cancelar sin motivo.
--   · cancelar un pago ya pagado.
-- Comprobarlos a mano si se quiere.

rollback;
