-- ---------------------------------------------------------------------------
-- Prueba de 55_importar_clientes_whatsapp.sql. Correr DESPUÉS del 55, y el bloque COMPLETO.
-- Todo va en begin/rollback: no deja nada. SQL plano, sin plpgsql (ver CLAUDE.md).
--
-- Escenario: un número que YA escribió (tiene conversación sin ligar) y viene en el CSV,
-- otro que se descarta. Se comprueba que antes de aceptar el agente no ve nada de ese
-- número, que aceptar crea cliente + contacto verificado y liga la conversación, que el
-- contexto trae pendiente y razón social, que aceptar dos veces no duplica, y que nadie
-- que no sea admin ve la tabla.
-- Lo que lanza excepción (descartar sin motivo, teléfono de menos de 10 dígitos) no se
-- puede probar aquí sin plpgsql: pruébalo a mano desde la pantalla o el editor, aparte.
-- ---------------------------------------------------------------------------

begin;

select set_config('app.admin',
         coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('app.p00',
         case when nullif(current_setting('app.admin'), '') is null then 'FALLO: no hay admin activo'
              else 'ok — hay un admin activo' end, true);

select set_config('request.jwt.claims',
         json_build_object('sub', nullif(current_setting('app.admin'), ''), 'role', 'authenticated')::text, true);
set local role authenticated;

select set_config('app.f1', gen_random_uuid()::text, true),
       set_config('app.f2', gen_random_uuid()::text, true),
       set_config('app.conv', gen_random_uuid()::text, true);

insert into importacion_whatsapp (id, telefono, nombre, empresa, ciudad, equipo, ultimo_servicio, pendiente, segmento, razon_social)
values (current_setting('app.f1')::uuid, '+52 1 999 000 5501', 'Prueba 55 A', 'Empresa de prueba 55', 'Mérida',
        'Generador 22 kW', '10/03/2026 · mantenimiento', 'Revisar el arranque automático', 'C',
        'Prueba Cincuenta y Cinco, S.A. de C.V.'),
       (current_setting('app.f2')::uuid, '9990005502', 'Prueba 55 B', null, null, null, null, null, 'E', null);

-- El número 5501 ya había escrito: su conversación existe y está sin ligar.
insert into conversaciones (id, telefono, nombre_wa)
values (current_setting('app.conv')::uuid, '5219990005501', 'Prueba 55 A');

select set_config('app.p1', concat(
         case when (wa_contexto(current_setting('app.conv')::uuid) ->> 'conocido') = 'false'
              then 'ok' else 'FALLO' end,
         ' — antes de aceptar, el agente no ve nada de ese número'), true);

select set_config('app.r1', aceptar_importacion_whatsapp(current_setting('app.f1')::uuid)::text, true);
select set_config('app.cliente', coalesce(current_setting('app.r1')::jsonb ->> 'cliente_id', ''), true);

select set_config('app.p2', concat(
         case when (select count(*) from contactos c
                     where c.cliente_id = nullif(current_setting('app.cliente'), '')::uuid
                       and c.telefono_norm = '9990005501' and c.verificado and c.activo) = 1
               and (select contacto_id is not null from conversaciones where id = current_setting('app.conv')::uuid)
              then 'ok' else 'FALLO' end,
         ' — aceptar crea cliente, contacto verificado y liga la conversación: ', current_setting('app.r1')), true);

select set_config('app.ctx', wa_contexto(current_setting('app.conv')::uuid)::text, true);
select set_config('app.p3', concat(
         case when current_setting('app.ctx')::jsonb #>> '{historial,pendiente}' = 'Revisar el arranque automático'
               and current_setting('app.ctx')::jsonb ->> 'razon_social' = 'Prueba Cincuenta y Cinco, S.A. de C.V.'
              then 'ok' else 'FALLO' end,
         ' — el contexto del agente trae pendiente y razón social: ', current_setting('app.ctx')), true);

select set_config('app.r2', aceptar_importacion_whatsapp(current_setting('app.f1')::uuid)::text, true);
select set_config('app.p4', concat(
         case when (current_setting('app.r2')::jsonb ->> 'sin_cambio') = 'true'
               and (select count(*) from contactos where telefono_norm = '9990005501') = 1
              then 'ok' else 'FALLO' end,
         ' — aceptar dos veces no duplica (sin_cambio, sigue un contacto)'), true);

select set_config('app.r3', descartar_importacion_whatsapp(current_setting('app.f2')::uuid, 'No confirmó')::text, true);
select set_config('app.p5', concat(
         case when (select estado from importacion_whatsapp where id = current_setting('app.f2')::uuid) = 'descartada'
               and not exists (select 1 from contactos where telefono_norm = '9990005502')
              then 'ok' else 'FALLO' end,
         ' — descartar no crea contacto'), true);

-- Alguien que no es admin (un uuid sin perfil = sin rol) no ve la tabla.
select set_config('request.jwt.claims',
         json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
select set_config('app.p6', concat(
         case when (select count(*) from importacion_whatsapp) = 0 then 'ok' else 'FALLO' end,
         ' — una cuenta sin rol no ve ninguna fila de importacion_whatsapp'), true);
reset role;

select set_config('app.p7', concat(
         case when not has_table_privilege('anon', 'importacion_whatsapp', 'select')
               and not has_function_privilege('anon', 'aceptar_importacion_whatsapp(uuid, uuid)', 'execute')
              then 'ok' else 'FALLO' end,
         ' — anon no lee la tabla ni ejecuta aceptar'), true);

select current_setting('app.p00') as p00, current_setting('app.p1') as p1, current_setting('app.p2') as p2,
       current_setting('app.p3') as p3, current_setting('app.p4') as p4, current_setting('app.p5') as p5,
       current_setting('app.p6') as p6, current_setting('app.p7') as p7;

rollback;
