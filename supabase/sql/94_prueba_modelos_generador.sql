-- Prueba del 94 (con rollback: no deja nada). Correr con la CLI:
--   npx supabase db query --linked -f supabase/sql/94_prueba_modelos_generador.sql
begin;

create temporary table resultado (paso int, que text, dio text, ok boolean) on commit drop;
grant all on resultado to authenticated;

insert into resultado
select 1, 'Modelos air / liquid (511 / 589)',
       concat(count(*) filter (where enfriamiento = 'air_cooled'), ' / ',
              count(*) filter (where enfriamiento = 'liquid_cooled')),
       count(*) filter (where enfriamiento = 'air_cooled') = 511
       and count(*) filter (where enfriamiento = 'liquid_cooled') = 589
  from modelos_generador;

-- Los kits los prueba 95_prueba_kits_sin_bujias.sql.

-- Un cliente y equipos de prueba.
insert into clientes (id, nombre, telefono)
values ('94000000-0000-0000-0000-000000000001', 'Prueba 94', '9990000094');

insert into equipos (id, cliente_id, tipo, modelo, numero_serie)
values ('94000000-0000-0000-0000-000000000002', '94000000-0000-0000-0000-000000000001',
        'generador', 'g00703-11', 'P94-1'),
       ('94000000-0000-0000-0000-000000000003', '94000000-0000-0000-0000-000000000001',
        'generador', 'Otro 123', 'P94-2'),
       ('94000000-0000-0000-0000-000000000004', '94000000-0000-0000-0000-000000000001',
        'generador', 'EG02224ANAX', 'P94-3');
update equipos set marca = 'Mi marca', capacidad_kw = 12
 where id = '94000000-0000-0000-0000-000000000004';

insert into resultado
select 4, 'El equipo aprende marca, kW y enfriamiento',
       concat(marca, ' ', capacidad_kw, ' ', atributos ->> 'enfriamiento'),
       marca = 'Generac' and capacidad_kw = 11 and atributos ->> 'enfriamiento' = 'air_cooled'
  from equipos where id = '94000000-0000-0000-0000-000000000002';

insert into resultado
select 5, 'Lo capturado a mano no se pisa', concat(marca, ' ', capacidad_kw),
       marca = 'Mi marca' and capacidad_kw = 12
  from equipos where id = '94000000-0000-0000-0000-000000000004';

insert into resultado
select 6, 'Mismo kit para menor y mayor', x.nombre,
       _paquete_de_equipo('94000000-0000-0000-0000-000000000002', 'menor')
         = (select paquete_id from modelos_generador where modelo = 'G0070311')
       and _paquete_de_equipo('94000000-0000-0000-0000-000000000002', 'mayor')
         = (select paquete_id from modelos_generador where modelo = 'G0070311')
  from (select nombre from paquetes_mantenimiento p
         where p.id = _paquete_de_equipo('94000000-0000-0000-0000-000000000002', 'menor')) x;

insert into resultado
select 7, 'Un equipo fuera de la lista no recibe kit',
       coalesce(_paquete_de_equipo('94000000-0000-0000-0000-000000000003', 'menor')::text, 'ninguno'),
       coalesce((select kit from paquetes_mantenimiento
                  where id = _paquete_de_equipo('94000000-0000-0000-0000-000000000003', 'menor')), false) = false;

-- El paquete capturado para el modelo exacto le gana al kit.
insert into paquetes_mantenimiento (id, tipo, marca, modelo, nombre)
values ('94000000-0000-0000-0000-000000000005', 'menor', 'Generac', 'g00703-11', 'Propio');
insert into resultado
select 8, 'Un paquete del modelo exacto gana al kit', '',
       _paquete_de_equipo('94000000-0000-0000-0000-000000000002', 'menor')
         = '94000000-0000-0000-0000-000000000005';

-- El técnico lee los modelos pero no los cambia.
select set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated', 'email', email)::text, true)
  from perfiles where rol = 'tecnico' and activo order by created_at limit 1;
set local role authenticated;
insert into resultado select 9, 'El técnico lee los modelos', count(*)::text, count(*) = 1100
  from modelos_generador;
update modelos_generador set capacidad_kw = 1 where modelo = 'G0070311';
reset role;
insert into resultado
select 10, 'El técnico no cambia los modelos', capacidad_kw::text, capacidad_kw = 11
  from modelos_generador where modelo = 'G0070311';

select paso, que, dio, case when ok then 'ok' else 'FALLA' end as resultado
  from resultado order by paso;
rollback;
