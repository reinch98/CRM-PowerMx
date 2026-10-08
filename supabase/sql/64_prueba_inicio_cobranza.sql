-- Prueba de 64_inicio_cobranza.sql. Correr DESPUÉS del 64, el bloque COMPLETO. begin/rollback.
-- SQL plano. Como en la prueba del 42, no se compara contra un número fijo (la base real cambia
-- cada día): se guarda el ANTES, se siembra y se comprueba la DIFERENCIA.
-- Consume folios (las secuencias no se revierten con el rollback).
--
-- Se siembran cinco cotizaciones:
--   a) aceptada hace 40 días, $1,000, sin cobros            → cobranza ATRASADA, falta $1,000
--   b) aceptada hoy, $500, sin cobros                       → cobranza (medio), falta $500
--   c) aceptada hace 40 días, cobranza LIQUIDADA            → no sale
--   d) BORRADOR hace 40 días                                → no sale (no es una venta)
--   e) aceptada hace 40 días, $400 cobrados sin verificar   → atrasada, pero NO suma al "por cobrar"
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

select set_config('app.antes', inicio_admin()::text, true);

select set_config('app.cli', gen_random_uuid()::text, true);
insert into clientes (id, nombre, telefono)
values (current_setting('app.cli')::uuid, 'PRUEBA-64', '9990000064');

select set_config('app.a', gen_random_uuid()::text, true),
       set_config('app.b', gen_random_uuid()::text, true),
       set_config('app.c', gen_random_uuid()::text, true),
       set_config('app.d', gen_random_uuid()::text, true),
       set_config('app.e', gen_random_uuid()::text, true);

insert into cotizaciones (id, cliente_id, tipo, estado, fecha, partidas, subtotal, descuento, iva, total) values
  (current_setting('app.a')::uuid, current_setting('app.cli')::uuid, 'venta', 'aceptada', current_date - 40, '[]'::jsonb, 862, 0, 138, 1000),
  (current_setting('app.b')::uuid, current_setting('app.cli')::uuid, 'venta', 'aceptada', current_date,      '[]'::jsonb, 431, 0, 69, 500),
  (current_setting('app.c')::uuid, current_setting('app.cli')::uuid, 'venta', 'aceptada', current_date - 40, '[]'::jsonb, 603, 0, 97, 700),
  (current_setting('app.d')::uuid, current_setting('app.cli')::uuid, 'venta', 'borrador', current_date - 40, '[]'::jsonb, 259, 0, 41, 300),
  (current_setting('app.e')::uuid, current_setting('app.cli')::uuid, 'venta', 'aceptada', current_date - 40, '[]'::jsonb, 345, 0, 55, 400);

update cotizaciones set cobranza_estado = 'liquidada' where id = current_setting('app.c')::uuid;
insert into expediente_movimientos (cotizacion_id, tipo, categoria, monto, forma)
values (current_setting('app.e')::uuid, 'ingreso', 'cobro', 400, 'efectivo');

select set_config('app.despues', inicio_admin()::text, true);

-- Las tres lecturas de cada aviso, antes y después.
-- n:    entero del aviso (0 si no aparece)
-- falta: el "$X por cobrar" del texto (0 si no lo trae)
select set_config('app.p1', concat(
  case when coalesce((select (e ->> 'n')::int from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e where e ->> 'clave' = 'cobranza_atrasada'), 0)
          - coalesce((select (e ->> 'n')::int from jsonb_array_elements(current_setting('app.antes')::jsonb -> 'urgente') e where e ->> 'clave' = 'cobranza_atrasada'), 0) = 2
        and (select e ->> 'nivel' from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e where e ->> 'clave' = 'cobranza_atrasada') = 'alto'
        and (select e ->> 'pantalla' from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e where e ->> 'clave' = 'cobranza_atrasada') = 'cotizaciones'
       then 'ok' else 'FALLO' end,
  ' — atrasada: sube 2 (a y e), nivel alto, lleva a Cotizaciones: "',
  coalesce((select e ->> 'texto' from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e where e ->> 'clave' = 'cobranza_atrasada'), 'no apareció'), '"'), true);

select set_config('app.p2', concat(
  case when coalesce((select (e ->> 'n')::int from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e where e ->> 'clave' = 'cobranza'), 0)
          - coalesce((select (e ->> 'n')::int from jsonb_array_elements(current_setting('app.antes')::jsonb -> 'urgente') e where e ->> 'clave' = 'cobranza'), 0) = 1
        and (select e ->> 'nivel' from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e where e ->> 'clave' = 'cobranza') = 'medio'
       then 'ok' else 'FALLO' end,
  ' — reciente: sube 1 (b), nivel medio: "',
  coalesce((select e ->> 'texto' from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e where e ->> 'clave' = 'cobranza'), 'no apareció'), '"'), true);

-- El dinero por cobrar sube lo que falta de verdad: 1,000 de (a) y 0 de (e), que ya cobró sus 400.
select set_config('app.p3', concat(
  case when coalesce((select replace(substring(e ->> 'texto' from '\$([0-9,]+) por cobrar'), ',', '')::numeric
                        from jsonb_array_elements(current_setting('app.despues')::jsonb -> 'urgente') e where e ->> 'clave' = 'cobranza_atrasada'), 0)
          - coalesce((select replace(substring(e ->> 'texto' from '\$([0-9,]+) por cobrar'), ',', '')::numeric
                        from jsonb_array_elements(current_setting('app.antes')::jsonb -> 'urgente') e where e ->> 'clave' = 'cobranza_atrasada'), 0) = 1000
       then 'ok' else 'FALLO' end,
  ' — lo atrasado por cobrar sube exactamente 1,000 (lo de e ya está cobrado)'), true);

-- (c) liquidada y (d) borrador no cuentan: por eso en p1 y p2 solo suben 2 y 1, no 4 ni 5.

-- Nada de esto se le muestra a quien no es admin.
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
