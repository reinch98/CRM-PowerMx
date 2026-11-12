-- Prueba de 97_polizas.sql. Todo dentro de begin/rollback: no deja nada.
-- Se corre con la CLI (lleva bloques `do` para los rechazos):
--   npx supabase db query --linked -f supabase/sql/97_prueba_polizas.sql
-- Ojo: consume folios de pólizas, citas y órdenes (las secuencias no se revierten).
begin;

create temp table r (paso int, ok boolean, detalle text) on commit drop;
grant all on r to authenticated;

-- Cliente y dos equipos de prueba (uno enfriado por aire, otro diésel).
insert into clientes (id, nombre, telefono) values
  ('97000000-0000-0000-0000-000000000001', 'Cliente prueba 97', '9990000097');
insert into equipos (id, cliente_id, tipo, marca, modelo, capacidad_kw, atributos) values
  ('97000000-0000-0000-0000-0000000000a1', '97000000-0000-0000-0000-000000000001', 'generador',
   'Generac', 'G0072101', 24, '{"combustible":"gas_lp","enfriamiento":"air_cooled"}'),
  ('97000000-0000-0000-0000-0000000000a2', '97000000-0000-0000-0000-000000000001', 'generador',
   'Cummins', 'C80D6', 80, '{"combustible":"diesel"}');

-- Los ids se toman ANTES de cambiar de rol: después, RLS esconde `perfiles`.
select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('app.tecnico',
  coalesce((select id::text from perfiles where rol = 'tecnico' and coalesce(activo, true) limit 1), ''), true);
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'email', 'prueba97', 'role', 'authenticated')::text, true);

-- 1. Estándar desde hoy: 4 visitas, la primera ya con cita por programar y su orden.
select set_config('app.p1', (crear_poliza(jsonb_build_object(
  'equipo_id', '97000000-0000-0000-0000-0000000000a1', 'nivel', 'estandar',
  'inicio', _hoy_merida(), 'subtotal', 14000)) ->> 'id'), true);
insert into r select 1,
  (select count(*) from poliza_visitas where poliza_id = current_setting('app.p1')::uuid) = 4
  and (select estado from poliza_visitas where poliza_id = current_setting('app.p1')::uuid and numero = 1) = 'agendada'
  and (select c.estado from poliza_visitas v join citas c on c.id = v.cita_id
        where v.poliza_id = current_setting('app.p1')::uuid and v.numero = 1) = 'por_programar'
  and exists (select 1 from poliza_visitas v join ordenes_servicio o on o.cita_id = v.cita_id
               where v.poliza_id = current_setting('app.p1')::uuid and v.numero = 1 and o.estado = 'abierta')
  and (select total from polizas where id = current_setting('app.p1')::uuid) = 16240
  and (select alcance from polizas where id = current_setting('app.p1')::uuid) = 'aire'
  and (select en_poliza from equipos where id = '97000000-0000-0000-0000-0000000000a1'),
  'estándar: 4 visitas, 1 cita, total 16,240, alcance aire, equipo en póliza';

-- 2. Realizar la cita de la visita 1 → visita realizada y próximo mantenimiento a 3 meses.
update citas set estado = 'realizada', fecha = _hoy_merida()
 where id = (select cita_id from poliza_visitas
              where poliza_id = current_setting('app.p1')::uuid and numero = 1);
insert into r select 2,
  (select estado from poliza_visitas where poliza_id = current_setting('app.p1')::uuid and numero = 1) = 'realizada'
  and (select proximo_mantenimiento from equipos where id = '97000000-0000-0000-0000-0000000000a1')
      = (_hoy_merida() + interval '3 months')::date,
  'realizada: la visita sigue a la cita y el próximo mantenimiento avanza';

-- 3. El reloj con 120 días abre la cita de la visita 2 (y no repite la 1).
-- (Llamada y comprobación en sentencias distintas: una sentencia no ve lo que escribe su función.)
select set_config('app.n3', generar_citas_poliza(120) ->> 'citas', true);
insert into r select 3,
  current_setting('app.n3')::int >= 1
  and (select estado from poliza_visitas where poliza_id = current_setting('app.p1')::uuid and numero = 2) = 'agendada',
  'reloj: abre la cita de la siguiente visita';

-- 4. Cancelar esa cita → la visita vuelve a pendiente.
select cancelar_cita((select cita_id from poliza_visitas
                       where poliza_id = current_setting('app.p1')::uuid and numero = 2));
insert into r select 4,
  (select estado from poliza_visitas where poliza_id = current_setting('app.p1')::uuid and numero = 2) = 'pendiente'
  and (select cita_id from poliza_visitas where poliza_id = current_setting('app.p1')::uuid and numero = 2) is null,
  'cita cancelada: la visita vuelve a pendiente';

-- 5. Omitirla con motivo → no se vuelve a agendar.
select omitir_visita_poliza((select id from poliza_visitas
                              where poliza_id = current_setting('app.p1')::uuid and numero = 2),
                            'El cliente estuvo fuera');
select generar_citas_poliza(120);
insert into r select 5,
  (select estado from poliza_visitas where poliza_id = current_setting('app.p1')::uuid and numero = 2) = 'omitida',
  'omitida: el reloj ya no la agenda';

-- 6. Otra póliza que se empalma con la vigente se rechaza.
do $$ begin
  perform crear_poliza(jsonb_build_object('equipo_id', '97000000-0000-0000-0000-0000000000a1',
    'nivel', 'basica', 'inicio', _hoy_merida() + 30, 'subtotal', 8000));
  insert into r values (6, false, 'empalme: se aceptó una segunda póliza');
exception when sqlstate '22023' then
  insert into r values (6, true, 'empalme: rechazada');
end $$;

-- 7. Integral en diésel: alcance líquido, 12 visitas, banco de carga en la 7.
select set_config('app.p2', (crear_poliza(jsonb_build_object(
  'equipo_id', '97000000-0000-0000-0000-0000000000a2', 'nivel', 'integral',
  'inicio', _hoy_merida() - 10, 'subtotal', 60000)) ->> 'id'), true);
insert into r select 7,
  (select alcance from polizas where id = current_setting('app.p2')::uuid) = 'liquido'
  and (select count(*) from poliza_visitas where poliza_id = current_setting('app.p2')::uuid) = 12
  and (select banco_carga and tipo = 'mayor' from poliza_visitas
        where poliza_id = current_setting('app.p2')::uuid and numero = 7)
  and (select fin from polizas where id = current_setting('app.p2')::uuid)
      = ((_hoy_merida() - 10) + interval '12 months')::date - 1,
  'integral diésel: líquido, 12 visitas, banco de carga en la mayor, fin a 12 meses';

-- 8. Cancelar la póliza: su cita sin trabajo se cancela, las visitas también y el equipo sale de póliza.
select cancelar_poliza(current_setting('app.p2')::uuid, 'Prueba');
insert into r select 8,
  not exists (select 1 from poliza_visitas where poliza_id = current_setting('app.p2')::uuid
               and estado in ('pendiente', 'agendada'))
  and not exists (select 1 from citas where equipo_id = '97000000-0000-0000-0000-0000000000a2'
                   and estado <> 'cancelada')
  and not (select en_poliza from equipos where id = '97000000-0000-0000-0000-0000000000a2'),
  'cancelada: visitas y citas canceladas, equipo fuera de póliza';

-- 9. Renovar: empieza el día siguiente al fin de la anterior y no choca.
-- (La llamada va sola: dentro de un `where`, una función volátil se evalúa por cada fila.)
select set_config('app.p3', (crear_poliza(jsonb_build_object(
  'equipo_id', '97000000-0000-0000-0000-0000000000a1', 'nivel', 'basica',
  'renueva_a', current_setting('app.p1'), 'subtotal', 9000)) ->> 'id'), true);
insert into r select 9,
  (select inicio from polizas where id = current_setting('app.p3')::uuid)
  = (select fin + 1 from polizas where id = current_setting('app.p1')::uuid)
  and (select count(*) from poliza_visitas where poliza_id = current_setting('app.p3')::uuid) = 2,
  'renovación: empieza al día siguiente del fin';

-- 10. polizas_lista trae las tres con sus visitas.
insert into r select 10,
  (select count(*) from jsonb_array_elements(polizas_lista(365)) x
    where x ->> 'cliente' = 'Cliente prueba 97') = 3,
  'lista: las tres pólizas del cliente';

-- 11. Un técnico no ve pólizas ni puede pedir la lista.
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.tecnico'), 'role', 'authenticated')::text, true);
do $$ begin
  perform polizas_lista(365);
  insert into r values (11, false, 'técnico: pudo pedir la lista');
exception when sqlstate '42501' then
  insert into r values (11, (select count(*) from polizas) = 0, 'técnico: sin lista y 0 pólizas visibles');
end $$;

select paso, case when ok then 'ok' else 'FALLA' end resultado, detalle from r order by paso;
rollback;
