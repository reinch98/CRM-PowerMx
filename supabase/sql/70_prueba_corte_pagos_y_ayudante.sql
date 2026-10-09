-- Prueba de 70_corte_pagos_y_ayudante.sql. Correr DESPUÉS del 70, el bloque COMPLETO. begin/rollback.
-- SQL plano (sin bloques plpgsql); cada llamada que escribe va en su propia sentencia y su
-- comprobación en la siguiente. Consume folios (las secuencias no se revierten con el rollback).
--
-- El caso: dos órdenes cerradas del mismo técnico (el admin), una de hace 20 días y otra de hace 2,
-- con el corte hace 10 días. Solo la reciente debe poder pagarse y verse en las comisiones.
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

select set_config('app.cli', gen_random_uuid()::text, true),
       set_config('app.vieja', gen_random_uuid()::text, true),
       set_config('app.nueva', gen_random_uuid()::text, true);

-- 1) El ayudante tiene su tarifa base de 300 en los cinco tipos de servicio.
select set_config('app.p1', concat(
  case when (select count(*) from tarifas_pago_tecnico
              where rol = 'ayudante' and tecnico_id is null and monto = 300
                and tipo_servicio in ('preventivo', 'correctivo', 'instalacion', 'diagnostico', 'visita_tecnica')) = 5
       then 'ok' else 'FALLO' end, ' — ayudante: 300 por servicio en los cinco tipos'), true);

-- 2) El corte existe (una sola fila) y lo movemos a hace 10 días.
update pagos_tecnico_config set pagar_desde = current_date - 10 where id;
select set_config('app.p2', concat(
  case when (select count(*) from pagos_tecnico_config) = 1
        and (select pagar_desde from pagos_tecnico_config where id) = current_date - 10
       then 'ok' else 'FALLO' end, ' — una sola fila de corte'), true);

insert into clientes (id, nombre, telefono) values (current_setting('app.cli')::uuid, 'PRUEBA-70', '9990000070');
insert into ordenes_servicio (id, cliente_id, fecha, tipo_servicio, estado, tecnico_id) values
  (current_setting('app.vieja')::uuid, current_setting('app.cli')::uuid, current_date - 20, 'preventivo', 'cerrada', current_setting('app.admin')::uuid),
  (current_setting('app.nueva')::uuid, current_setting('app.cli')::uuid, current_date - 2, 'preventivo', 'cerrada', current_setting('app.admin')::uuid);
insert into tarifas_pago_tecnico (tipo_servicio, rol, monto, vigente_desde)
select 'preventivo', 'responsable', 600, '1999-01-01'
 where not exists (select 1 from tarifas_pago_tecnico
                    where tipo_servicio = 'preventivo' and rol = 'responsable' and tecnico_id is null and vigente_desde = '1999-01-01');

-- 3) Las comisiones del técnico muestran la reciente y NO la anterior al corte.
select set_config('app.r3', mis_comisiones(60)::text, true);
select set_config('app.p3', concat(
  case when exists (select 1 from jsonb_array_elements(current_setting('app.r3')::jsonb -> 'ordenes') e
                     where e ->> 'orden_id' = current_setting('app.nueva'))
        and not exists (select 1 from jsonb_array_elements(current_setting('app.r3')::jsonb -> 'ordenes') e
                         where e ->> 'orden_id' = current_setting('app.vieja'))
       then 'ok' else 'FALLO' end, ' — comisiones: la anterior al corte no aparece'), true);

-- 4) Al armar el pago de todo el mes, solo entra la reciente.
select set_config('app.r4', proponer_pago_tecnico(current_setting('app.admin')::uuid, current_date - 30, current_date)::text, true);
select set_config('app.p4', concat(
  case when exists (select 1 from pagos_tecnico_lineas
                     where pago_id = (current_setting('app.r4')::jsonb ->> 'pago_id')::uuid
                       and orden_id = current_setting('app.nueva')::uuid and activa)
        and not exists (select 1 from pagos_tecnico_lineas
                         where pago_id = (current_setting('app.r4')::jsonb ->> 'pago_id')::uuid
                           and orden_id = current_setting('app.vieja')::uuid)
       then 'ok' else 'FALLO' end, ' — el pago solo junta órdenes desde el corte'), true);

-- 5) Mover el corte hacia atrás vuelve a mostrar la orden vieja.
update pagos_tecnico_config set pagar_desde = current_date - 30 where id;
select set_config('app.r5', mis_comisiones(60)::text, true);
select set_config('app.p5', concat(
  case when exists (select 1 from jsonb_array_elements(current_setting('app.r5')::jsonb -> 'ordenes') e
                     where e ->> 'orden_id' = current_setting('app.vieja') and e ->> 'estado' = 'en_revision')
       then 'ok' else 'FALLO' end, ' — al mover el corte, la vieja vuelve "en revisión"'), true);

-- 6) Quien no es admin no ve ni cambia el corte.
select set_config('request.jwt.claims',
  json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
set local role authenticated;
select set_config('app.p6', concat(
  case when (select count(*) from pagos_tecnico_config) = 0 then 'ok' else 'FALLO' end,
  ' — sin ser admin, el corte no se ve'), true);
reset role;

select current_setting('app.p1') as resultado
union all select current_setting('app.p2')
union all select current_setting('app.p3')
union all select current_setting('app.p4')
union all select current_setting('app.p5')
union all select current_setting('app.p6');

rollback;
