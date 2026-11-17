-- ---------------------------------------------------------------------------
-- Prueba de 99_solicitud_a_cotizacion.sql. Correr DESPUÉS del 98 y el 99, el bloque COMPLETO.
-- Todo va en begin/rollback (el folio de la cotización de prueba sí se consume: la secuencia
-- no se revierte). SQL plano, sin plpgsql.
-- npx supabase db query --linked -f supabase/sql/99_prueba_solicitud_a_cotizacion.sql
--
-- A mano (lanzan excepción, sin begin/rollback no dejan nada): ligar como técnico
-- ('Solo el administrador.') y ligar una solicitud ya ligada a OTRA cotización
-- ('Esta solicitud ya está ligada a otra cotización.').
-- ---------------------------------------------------------------------------

begin;

select set_config('app.admin',
         coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true),
       set_config('app.tecnico',
         coalesce((select id::text from perfiles where rol = 'tecnico' and coalesce(activo, true) limit 1), ''), true);

select set_config('app.p0',
         case when nullif(current_setting('app.admin'), '') is null then 'FALLO: no hay admin activo'
              when nullif(current_setting('app.tecnico'), '') is null then 'FALLO: no hay técnico activo'
              else 'ok — hay admin y técnico con quienes probar' end, true);

-- Escenario: un cliente, una solicitud con cálculo y una cotización en borrador.
select set_config('app.cliente', gen_random_uuid()::text, true),
       set_config('app.solicitud', gen_random_uuid()::text, true),
       set_config('app.cot', gen_random_uuid()::text, true);

insert into clientes (id, nombre, telefono)
values (current_setting('app.cliente')::uuid, 'Cliente de prueba (99)', '9990009901');

insert into solicitudes_web (id, nombre, telefono, telefono_norm, tipos, notas, nota_interna, calculo)
values (current_setting('app.solicitud')::uuid, 'Prueba 99', '999 000 9901', '9990009901', 'Solar',
        'Desde la calculadora solar', 'Le marqué el lunes.',
        '{"kwh_mes": 468.8, "paquete": {"sku": "PKG-ESSENTIAL", "precio": 53999}}'::jsonb);

insert into cotizaciones (id, cliente_id, fecha, vigencia_dias, tipo, partidas, subtotal, descuento,
                          iva, total, requiere_visita, estado, creada_por)
values (current_setting('app.cot')::uuid, current_setting('app.cliente')::uuid, current_date, 15,
        'instalacion', '[]'::jsonb, 46550.86, 0, 7448.14, 53999, true, 'borrador', 'prueba-99');

-- ---- como el ADMIN ----
select set_config('request.jwt.claims',
         json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated',
                           'email', 'admin@prueba')::text, true);
set local role authenticated;

select set_config('app.r1', ligar_solicitud_a_cotizacion(current_setting('app.solicitud')::uuid,
                                                         current_setting('app.cot')::uuid)::text, true);
select set_config('app.r2', ligar_solicitud_a_cotizacion(current_setting('app.solicitud')::uuid,
                                                         current_setting('app.cot')::uuid)::text, true);

select set_config('app.p1', concat(
  case when (current_setting('app.r1')::jsonb ->> 'ok') = 'true'
         and (current_setting('app.r1')::jsonb ->> 'sin_cambio') = 'false'
         and s.cotizacion_id = current_setting('app.cot')::uuid
         and s.cliente_id = current_setting('app.cliente')::uuid
         and s.estado = 'atendida' and s.atendida_por = 'admin@prueba' and s.atendida_en is not null
       then 'ok' else 'FALLO' end,
  ' — ligada, atendida y con el cliente de la cotización: ', current_setting('app.r1')), true)
from solicitudes_web s where s.id = current_setting('app.solicitud')::uuid;

select set_config('app.p2', concat(
  case when s.nota_interna like 'Le marqué el lunes.%' and s.nota_interna like '%creada con el paquete de la calculadora.'
       then 'ok' else 'FALLO' end,
  ' — la nota interna se conservó y ganó una línea: ', replace(s.nota_interna, E'\n', ' / ')), true)
from solicitudes_web s where s.id = current_setting('app.solicitud')::uuid;

select set_config('app.p3', concat(
  case when (current_setting('app.r2')::jsonb ->> 'sin_cambio') = 'true' then 'ok' else 'FALLO' end,
  ' — ligar otra vez la misma no cambia nada: ', current_setting('app.r2')), true);

select set_config('app.p4', concat(
  case when c.origen = 'sitio' then 'ok' else 'FALLO' end, ' — la cotización quedó con origen ', c.origen), true)
from cotizaciones c where c.id = current_setting('app.cot')::uuid;

-- ---- como el TÉCNICO: no ve la solicitud ni la cotización ----
reset role;
select set_config('request.jwt.claims',
         json_build_object('sub', current_setting('app.tecnico'), 'role', 'authenticated')::text, true);
set local role authenticated;
select set_config('app.n_tec', (select count(*) from solicitudes_web where id = current_setting('app.solicitud')::uuid)::text, true);

reset role;
select set_config('app.p5', concat(
  case when current_setting('app.n_tec') = '0' then 'ok' else 'FALLO' end,
  ' — el técnico ve ', current_setting('app.n_tec'), ' solicitudes'), true);

-- Borrar la cotización deja la solicitud sin cotización (no la borra).
delete from cotizaciones where id = current_setting('app.cot')::uuid;
select set_config('app.p6', concat(
  case when count(*) = 1 and bool_and(s.cotizacion_id is null) then 'ok' else 'FALLO' end,
  ' — al borrar la cotización, la solicitud sigue y queda sin cotización'), true)
from solicitudes_web s where s.id = current_setting('app.solicitud')::uuid;

select current_setting('app.p0') as p0, current_setting('app.p1') as p1, current_setting('app.p2') as p2,
       current_setting('app.p3') as p3, current_setting('app.p4') as p4, current_setting('app.p5') as p5,
       current_setting('app.p6') as p6;

rollback;
