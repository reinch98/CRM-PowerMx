-- Prueba de 71_avisos_finanzas.sql. Correr DESPUÉS del 71, el bloque COMPLETO. begin/rollback.
-- SQL plano (sin bloques plpgsql). Compara antes y después de crear cada cosa, para no depender de
-- lo que ya haya en la base.
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

-- Punto de partida conocido: sin RFC y sin tarifa de responsable.
update empresa_fiscal set rfc = null where id;
delete from tarifas_pago_tecnico where rol = 'responsable';

-- 1) Sin RFC ni tarifa del responsable, el Inicio lo pide (como "cuando se pueda").
select set_config('app.r1', inicio_admin()::text, true);
select set_config('app.p1', concat(
  case when exists (select 1 from jsonb_array_elements(current_setting('app.r1')::jsonb -> 'urgente') e
                     where e ->> 'clave' = 'rfc' and e ->> 'nivel' = 'bajo' and e ->> 'pantalla' = 'finanzas')
        and exists (select 1 from jsonb_array_elements(current_setting('app.r1')::jsonb -> 'urgente') e
                     where e ->> 'clave' = 'tarifa_responsable' and e ->> 'pantalla' = 'pagos')
       then 'ok' else 'FALLO' end, ' — pide el RFC y la tarifa del responsable'), true);

-- 2) Un documento por revisar sube el globo de Finanzas y aparece en el Inicio.
select set_config('app.antes', coalesce(pendientes_admin() ->> 'finanzas', '0'), true);
insert into documentos (tipo, archivo, hash_sha256, estado)
values ('ticket', 'documentos/prueba71.jpg', encode(sha256('prueba-71'::bytea), 'hex'), 'pendiente');
select set_config('app.p2', concat(
  case when (pendientes_admin() ->> 'finanzas')::int = current_setting('app.antes')::int + 1
        and exists (select 1 from jsonb_array_elements(inicio_admin() -> 'urgente') e
                     where e ->> 'clave' = 'documentos' and e ->> 'pantalla' = 'finanzas')
       then 'ok' else 'FALLO' end, ' — documento por revisar: globo +1 y aviso en Inicio'), true);

-- 3) Con RFC y tarifa del responsable capturados, esos dos avisos desaparecen.
update empresa_fiscal set rfc = 'PRUE850101AB1' where id;
insert into tarifas_pago_tecnico (tipo_servicio, rol, monto, vigente_desde) values ('preventivo', 'responsable', 600, '2026-01-01');
select set_config('app.r3', inicio_admin()::text, true);
select set_config('app.p3', concat(
  case when not exists (select 1 from jsonb_array_elements(current_setting('app.r3')::jsonb -> 'urgente') e
                         where e ->> 'clave' in ('rfc', 'tarifa_responsable'))
       then 'ok' else 'FALLO' end, ' — con RFC y tarifa, ya no los pide'), true);

-- 4) Quien no es admin recibe objetos vacíos.
select set_config('request.jwt.claims',
  json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
select set_config('app.p4', concat(
  case when pendientes_admin() = '{}'::jsonb and inicio_admin() = '{}'::jsonb
       then 'ok' else 'FALLO' end, ' — sin ser admin, nada'), true);

select current_setting('app.p1') as resultado
union all select current_setting('app.p2')
union all select current_setting('app.p3')
union all select current_setting('app.p4');

rollback;
