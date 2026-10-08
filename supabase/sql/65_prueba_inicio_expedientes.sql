-- Prueba de 65_inicio_expedientes.sql. Correr DESPUÉS del 65, el bloque COMPLETO. begin/rollback.
-- SQL plano. No se compara contra un número fijo (la base real cambia): se guarda el ANTES, se
-- siembra y se comprueba la DIFERENCIA. Consume folios (las secuencias no se revierten).
--
-- Se siembran cinco cotizaciones, todas aceptadas salvo la última:
--   a) cobrada hace 20 días, expediente ABIERTO     → atrasado (alto)
--   b) cobrada hoy, expediente ABIERTO              → por cerrar (medio)
--   c) cobrada, expediente ya CERRADO               → no sale
--   d) cobranza solo PARCIAL                        → no sale (todavía no se termina de cobrar)
--   e) BORRADOR con la cobranza liquidada           → no sale (no es una venta)
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

select set_config('app.antes', inicio_admin()::text, true);

select set_config('app.cli', gen_random_uuid()::text, true);
insert into clientes (id, nombre, telefono)
values (current_setting('app.cli')::uuid, 'PRUEBA-65', '9990000065');

select set_config('app.a', gen_random_uuid()::text, true),
       set_config('app.b', gen_random_uuid()::text, true),
       set_config('app.c', gen_random_uuid()::text, true),
       set_config('app.d', gen_random_uuid()::text, true),
       set_config('app.e', gen_random_uuid()::text, true);

insert into cotizaciones (id, cliente_id, tipo, estado, partidas, subtotal, descuento, iva, total) values
  (current_setting('app.a')::uuid, current_setting('app.cli')::uuid, 'venta', 'aceptada', '[]'::jsonb, 862, 0, 138, 1000),
  (current_setting('app.b')::uuid, current_setting('app.cli')::uuid, 'venta', 'aceptada', '[]'::jsonb, 431, 0, 69, 500),
  (current_setting('app.c')::uuid, current_setting('app.cli')::uuid, 'venta', 'aceptada', '[]'::jsonb, 603, 0, 97, 700),
  (current_setting('app.d')::uuid, current_setting('app.cli')::uuid, 'venta', 'aceptada', '[]'::jsonb, 259, 0, 41, 300),
  (current_setting('app.e')::uuid, current_setting('app.cli')::uuid, 'venta', 'borrador', '[]'::jsonb, 345, 0, 55, 400);

update cotizaciones set cobranza_estado = 'liquidada', cobranza_liquidada_en = now() - interval '20 days'
 where id = current_setting('app.a')::uuid;
update cotizaciones set cobranza_estado = 'liquidada', cobranza_liquidada_en = now()
 where id in (current_setting('app.b')::uuid, current_setting('app.c')::uuid, current_setting('app.e')::uuid);
update cotizaciones set expediente_cerrado_en = now() where id = current_setting('app.c')::uuid;
update cotizaciones set cobranza_estado = 'parcial' where id = current_setting('app.d')::uuid;

select set_config('app.despues', inicio_admin()::text, true);

-- 1) Cobrada hace más de 15 días y sin cerrar: sube 1 (a), nivel alto, lleva a Cotizaciones.
select set_config('app.p1', concat(
  case when coalesce((select (e ->> 'n')::int from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e where e ->> 'clave' = 'expedientes_atrasados'), 0)
          - coalesce((select (e ->> 'n')::int from jsonb_array_elements(current_setting('app.antes')::jsonb -> 'urgente') e where e ->> 'clave' = 'expedientes_atrasados'), 0) = 1
        and (select e ->> 'nivel' from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e where e ->> 'clave' = 'expedientes_atrasados') = 'alto'
        and (select e ->> 'pantalla' from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e where e ->> 'clave' = 'expedientes_atrasados') = 'cotizaciones'
       then 'ok' else 'FALLO' end,
  ' — atrasados: sube 1 (a), nivel alto: "',
  coalesce((select e ->> 'texto' from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e where e ->> 'clave' = 'expedientes_atrasados'), 'no apareció'), '"'), true);

-- 2) Cobrada hace poco y sin cerrar: sube 1 (b), nivel medio. c, d y e no cuentan.
select set_config('app.p2', concat(
  case when coalesce((select (e ->> 'n')::int from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e where e ->> 'clave' = 'expedientes'), 0)
          - coalesce((select (e ->> 'n')::int from jsonb_array_elements(current_setting('app.antes')::jsonb -> 'urgente') e where e ->> 'clave' = 'expedientes'), 0) = 1
        and (select e ->> 'nivel' from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e where e ->> 'clave' = 'expedientes') = 'medio'
       then 'ok' else 'FALLO' end,
  ' — por cerrar: sube 1 (b), nivel medio; c (cerrado), d (parcial) y e (borrador) no cuentan: "',
  coalesce((select e ->> 'texto' from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e where e ->> 'clave' = 'expedientes'), 'no apareció'), '"'), true);

-- 3) Cerrar el expediente de (b) lo saca de la lista: baja 1 y la cuenta vuelve a como estaba.
update cotizaciones set expediente_cerrado_en = now() where id = current_setting('app.b')::uuid;
select set_config('app.cierre', inicio_admin()::text, true);
select set_config('app.p3', concat(
  case when coalesce((select (e ->> 'n')::int from jsonb_array_elements(current_setting('app.cierre')::jsonb -> 'urgente') e where e ->> 'clave' = 'expedientes'), 0)
          = coalesce((select (e ->> 'n')::int from jsonb_array_elements(current_setting('app.antes')::jsonb -> 'urgente') e where e ->> 'clave' = 'expedientes'), 0)
       then 'ok' else 'FALLO' end,
  ' — al cerrar el expediente de b deja de contar'), true);

-- 4) El técnico no ve nada de esto.
select set_config('request.jwt.claims',
  json_build_object('sub', coalesce((select id::text from perfiles where rol = 'tecnico' limit 1), ''),
                    'role', 'authenticated')::text, true);
select set_config('app.p4', concat(
  case when inicio_admin() = '{}'::jsonb then 'ok' else 'FALLO' end,
  ' — el técnico recibe un objeto vacío'), true);

select current_setting('app.p1') as resultado
union all select current_setting('app.p2')
union all select current_setting('app.p3')
union all select current_setting('app.p4');

rollback;
