-- Prueba de 74_tablero_direccion.sql. Correr DESPUÉS del 74, el bloque COMPLETO. begin/rollback.
-- SQL plano (sin bloques plpgsql). Compara el tablero ANTES y DESPUÉS de crear datos, para no depender
-- de lo que ya haya en la base.
--
-- El caso: equipo solar; cotización aceptada de hoy, base 10,000 (IVA 1,600, total 11,600); cobro de
-- 5,800 y gasolina de 500 ligada a la cotización. Esperado: ingresos +5,800, gastos +500, línea solar
-- venta +10,000 y utilidad +9,500, por cobrar +5,800 (no vencido). Con la fecha a 40 días: vencido +5,800.
begin;

select set_config('request.jwt.claims',
  json_build_object('sub', (select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1),
                    'role', 'authenticated')::text, true);

select set_config('app.cli', gen_random_uuid()::text, true),
       set_config('app.eq', gen_random_uuid()::text, true),
       set_config('app.cot', gen_random_uuid()::text, true),
       set_config('app.renta', gen_random_uuid()::text, true);

select set_config('app.t0', tablero_direccion(6)::text, true);

insert into clientes (id, nombre, telefono) values (current_setting('app.cli')::uuid, 'PRUEBA-74', '9990000074');
insert into equipos (id, cliente_id, tipo, marca) values (current_setting('app.eq')::uuid, current_setting('app.cli')::uuid, 'solar', 'PRUEBA');
insert into cotizaciones (id, cliente_id, equipo_id, tipo, estado, fecha, partidas, subtotal, descuento, iva, total)
values (current_setting('app.cot')::uuid, current_setting('app.cli')::uuid, current_setting('app.eq')::uuid,
        'instalacion', 'aceptada', current_date, '[]'::jsonb, 10000, 0, 1600, 11600);
insert into expediente_movimientos (cotizacion_id, tipo, categoria, fecha, monto, concepto) values
  (current_setting('app.cot')::uuid, 'ingreso', 'cobro', current_date, 5800, 'PRUEBA-74 cobro');
insert into expediente_movimientos (cotizacion_id, tipo, categoria, fecha, monto, iva, concepto) values
  (current_setting('app.cot')::uuid, 'egreso', 'gasolina', current_date, 500, 0, 'PRUEBA-74 gasolina');

select set_config('app.t1', tablero_direccion(6)::text, true);

-- Ayudas: el último mes y la línea solar, antes y después.
select set_config('app.mes0', (current_setting('app.t0')::jsonb -> 'mensual' -> -1)::text, true),
       set_config('app.mes1', (current_setting('app.t1')::jsonb -> 'mensual' -> -1)::text, true),
       set_config('app.sol0', coalesce((select e::text from jsonb_array_elements(current_setting('app.t0')::jsonb -> 'lineas') e
                                         where e ->> 'linea' = 'solar'), '{"venta":0,"utilidad":0}'), true),
       set_config('app.sol1', coalesce((select e::text from jsonb_array_elements(current_setting('app.t1')::jsonb -> 'lineas') e
                                         where e ->> 'linea' = 'solar'), '{"venta":0,"utilidad":0}'), true);

-- 1) Mes a mes: el mes en curso sube 5,800 de ingresos y 500 de gastos.
select set_config('app.p1', concat(
  case when (current_setting('app.mes1')::jsonb ->> 'ingresos')::numeric - (current_setting('app.mes0')::jsonb ->> 'ingresos')::numeric = 5800
        and (current_setting('app.mes1')::jsonb ->> 'gastos')::numeric - (current_setting('app.mes0')::jsonb ->> 'gastos')::numeric = 500
       then 'ok' else 'FALLO' end, ' — mes en curso: +5,800 ingresos, +500 gastos'), true);

-- 2) Línea solar: venta +10,000 y utilidad +9,500 (la misma fórmula del Expediente).
select set_config('app.p2', concat(
  case when (current_setting('app.sol1')::jsonb ->> 'venta')::numeric - (current_setting('app.sol0')::jsonb ->> 'venta')::numeric = 10000
        and (current_setting('app.sol1')::jsonb ->> 'utilidad')::numeric - (current_setting('app.sol0')::jsonb ->> 'utilidad')::numeric = 9500
       then 'ok' else 'FALLO' end, ' — línea solar: venta +10,000, utilidad +9,500 — ', current_setting('app.sol1')), true);

-- 3) Por cobrar sube 5,800 y no está vencido (es de hoy).
select set_config('app.p3', concat(
  case when (current_setting('app.t1')::jsonb #>> '{cxc,total}')::numeric - (current_setting('app.t0')::jsonb #>> '{cxc,total}')::numeric = 5800
        and (current_setting('app.t1')::jsonb #>> '{cxc,vencido}')::numeric = (current_setting('app.t0')::jsonb #>> '{cxc,vencido}')::numeric
       then 'ok' else 'FALLO' end, ' — por cobrar +5,800, sin vencer'), true);

-- 4) Con la cotización de hace 40 días, esos 5,800 pasan a vencidos.
update cotizaciones set fecha = current_date - 40 where id = current_setting('app.cot')::uuid;
select set_config('app.t2', tablero_direccion(6)::text, true);
select set_config('app.p4', concat(
  case when (current_setting('app.t2')::jsonb #>> '{cxc,vencido}')::numeric - (current_setting('app.t0')::jsonb #>> '{cxc,vencido}')::numeric = 5800
       then 'ok' else 'FALLO' end, ' — a 40 días: +5,800 vencido'), true);

-- 5) Una renta se clasifica como "rentas" aunque no tenga equipo.
insert into cotizaciones (id, cliente_id, tipo, estado, partidas, subtotal, descuento, iva, total)
values (current_setting('app.renta')::uuid, current_setting('app.cli')::uuid, 'renta', 'borrador', '[]'::jsonb, 400, 0, 64, 464);
select set_config('app.p5', concat(
  case when _linea_de_cotizacion(current_setting('app.renta')::uuid) = 'rentas'
        and _linea_de_cotizacion(current_setting('app.cot')::uuid) = 'solar'
       then 'ok' else 'FALLO' end, ' — renta → rentas; equipo solar → solar'), true);

-- 6) El periodo respeta los meses pedidos.
select set_config('app.p6', concat(
  case when jsonb_array_length(tablero_direccion(3) -> 'mensual') = 3
        and jsonb_array_length(tablero_direccion(12) -> 'mensual') = 12
       then 'ok' else 'FALLO' end, ' — 3 y 12 meses'), true);

select current_setting('app.p1') as resultado
union all select current_setting('app.p2')
union all select current_setting('app.p3')
union all select current_setting('app.p4')
union all select current_setting('app.p5')
union all select current_setting('app.p6');

-- No se prueba aquí porque lanza excepción: quien no es admin → «Solo el administrador ve el tablero.»

rollback;
