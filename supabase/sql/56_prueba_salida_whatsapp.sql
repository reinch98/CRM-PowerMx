-- ---------------------------------------------------------------------------
-- Prueba de 56_salida_whatsapp.sql. Correr DESPUÉS del 56, y el bloque COMPLETO.
-- begin/rollback: no deja nada (tampoco cambia wa_config ni las plantillas de verdad).
-- SQL plano, sin plpgsql. Lo que lanza excepción (responder con la ventana cerrada) se prueba
-- a mano aparte.
-- ---------------------------------------------------------------------------

begin;

select set_config('app.admin',
         coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('app.p00', case when nullif(current_setting('app.admin'), '') is null
                                  then 'FALLO: no hay admin activo' else 'ok — hay un admin activo' end, true);
select set_config('request.jwt.claims',
         json_build_object('sub', nullif(current_setting('app.admin'), ''), 'role', 'authenticated', 'email', 'admin@prueba')::text, true);
set local role authenticated;

update wa_config set envio_activo = false, avisos_automaticos = false where id;
update wa_plantillas set estado = 'en_revision' where nombre = 'cita_confirmada';

-- ---- una cita confirmada: el trigger de la 16 crea el aviso, el de la 56 lo pone en la cola ----
select set_config('app.cliente', gen_random_uuid()::text, true), set_config('app.cita', gen_random_uuid()::text, true);
insert into clientes (id, nombre, telefono) values (current_setting('app.cliente')::uuid, 'Cliente prueba 56', '9990005601');
insert into citas (id, cliente_id, tipo_servicio, fecha, hora, estado)
values (current_setting('app.cita')::uuid, current_setting('app.cliente')::uuid, 'preventivo',
        (now() at time zone 'America/Mexico_City')::date + 3, '10:00', 'programada');
select set_config('app.aviso', coalesce((select id::text from avisos where cita_id = current_setting('app.cita')::uuid
                                          and tipo = 'confirmacion' and destinatario = 'cliente' limit 1), ''), true);
select set_config('app.salida', coalesce((select id::text from salida_wa where llave = 'aviso:' || current_setting('app.aviso')), ''), true);

select set_config('app.p1', concat(
         case when (select estado from salida_wa where id = nullif(current_setting('app.salida'), '')::uuid) = 'por_aprobar'
              then 'ok' else 'FALLO' end, ' — la cita confirmada deja su aviso en la cola, por aprobar (automático apagado)'), true);

select aprobar_salida(array[current_setting('app.salida')::uuid]);
select set_config('app.t1', tomar_salida(10)::text, true);
select set_config('app.p2', concat(
         case when (current_setting('app.t1')::jsonb ->> 'apagado') = 'true'
               and (select estado from salida_wa where id = current_setting('app.salida')::uuid) = 'pendiente'
              then 'ok' else 'FALLO' end, ' — con el envío apagado no sale nada'), true);

update wa_config set envio_activo = true where id;
select set_config('app.t2', tomar_salida(10)::text, true);
select set_config('app.p3', concat(
         case when jsonb_array_length(current_setting('app.t2')::jsonb -> 'mensajes') = 0
               and (select estado from salida_wa where id = current_setting('app.salida')::uuid) = 'pendiente'
              then 'ok' else 'FALLO' end, ' — con la plantilla en revisión espera, sin error'), true);

update wa_plantillas set estado = 'aprobada' where nombre = 'cita_confirmada';
select set_config('app.t3', tomar_salida(10)::text, true);
select set_config('app.m', coalesce((select m::text from jsonb_array_elements(current_setting('app.t3')::jsonb -> 'mensajes') m
                                      where m ->> 'id' = current_setting('app.salida')), '{}'), true);
select set_config('app.p4', concat(
         case when current_setting('app.m')::jsonb ->> 'to' = '529990005601'
               and current_setting('app.m')::jsonb ->> 'plantilla' = 'cita_confirmada'
               and jsonb_array_length(current_setting('app.m')::jsonb -> 'parametros') = 4
               and not exists (select 1 from jsonb_array_elements(current_setting('app.m')::jsonb -> 'parametros') p where coalesce(p ->> 'valor', '') = '')
              then 'ok' else 'FALLO' end, ' — aprobada, sale con destino 52+10 y sus 4 variables llenas: ', current_setting('app.m')), true);

select marcar_salida(current_setting('app.salida')::uuid, true, 'wamid.prueba56.1');
select set_config('app.p5', concat(
         case when (select estado from salida_wa where id = current_setting('app.salida')::uuid) = 'enviado'
               and (select estado = 'enviado' and canal = 'whatsapp_api' from avisos where id = current_setting('app.aviso')::uuid)
               and exists (select 1 from mensajes_wa where wa_message_id = 'wamid.prueba56.1' and direccion = 'saliente')
              then 'ok' else 'FALLO' end, ' — al confirmarse: aviso enviado por API y el mensaje queda en la conversación'), true);

select set_config('app.r9', marcar_salida(current_setting('app.salida')::uuid, true, 'wamid.prueba56.otro')::text, true);
select set_config('app.p6', concat(
         case when (current_setting('app.r9')::jsonb ->> 'sin_cambio') = 'true' then 'ok' else 'FALLO' end,
         ' — marcar dos veces no cambia nada'), true);

select registrar_estado_wa('wamid.prueba56.1', 'read');
select registrar_estado_wa('wamid.prueba56.1', 'delivered');
select set_config('app.p7', concat(
         case when (select estado from salida_wa where id = current_setting('app.salida')::uuid) = 'leido'
              then 'ok' else 'FALLO' end, ' — los acuses avanzan y no retroceden (leído no vuelve a entregado)'), true);

-- ---- respuesta de texto con la ventana abierta ----
select set_config('app.e', registrar_mensaje_entrante('5219990005602', 'wamid.prueba56.in', 'Hola', 'Prueba')::text, true);
select set_config('app.r', responder_whatsapp((current_setting('app.e')::jsonb ->> 'conversacion_id')::uuid, 'Con gusto le ayudamos')::text, true);
select set_config('app.p8', concat(
         case when (select tipo = 'texto' and estado = 'pendiente' from salida_wa
                     where id = (current_setting('app.r')::jsonb ->> 'salida_id')::uuid)
              then 'ok' else 'FALLO' end, ' — responder con la ventana abierta entra a la cola'), true);

-- ---- BAJA cancela el marketing pendiente de ese número ----
insert into salida_wa (llave, telefono, tipo, plantilla, origen, categoria, estado)
values ('prueba56:mkt', '9990005603', 'plantilla', 'cita_confirmada', 'campana', 'marketing', 'pendiente');
select registrar_baja('+52 1 999 000 5603');
select set_config('app.p9', concat(
         case when (select estado from salida_wa where llave = 'prueba56:mkt') = 'cancelado'
               and exists (select 1 from wa_bajas where telefono_norm = '9990005603')
              then 'ok' else 'FALLO' end, ' — BAJA cancela el marketing pendiente de ese número'), true);

-- ---- un aviso mandado a mano cancela su lugar en la cola ----
select set_config('app.cita2', gen_random_uuid()::text, true);
insert into citas (id, cliente_id, tipo_servicio, fecha, estado)
values (current_setting('app.cita2')::uuid, current_setting('app.cliente')::uuid, 'correctivo',
        (now() at time zone 'America/Mexico_City')::date + 5, 'programada');
update avisos set estado = 'enviado', canal = 'whatsapp_manual'
 where cita_id = current_setting('app.cita2')::uuid and destinatario = 'cliente';
select set_config('app.p10', concat(
         case when (select s.estado from salida_wa s join avisos a on s.llave = 'aviso:' || a.id
                     where a.cita_id = current_setting('app.cita2')::uuid and a.destinatario = 'cliente' limit 1) = 'cancelado'
              then 'ok' else 'FALLO' end, ' — mandarlo a mano (wa.me) cancela el de la cola: no sale dos veces'), true);

-- ---- la cola de la oficina: lo atorado en "enviando" pasa a sin_confirmar ----
insert into salida_wa (llave, telefono, tipo, plantilla, origen, categoria, estado, tomado_en)
values ('prueba56:atorado', '9990005604', 'plantilla', 'cita_confirmada', 'aviso', 'utilidad', 'enviando', now() - interval '1 hour');
select set_config('app.cola', cola_whatsapp()::text, true);
select set_config('app.p13', concat(
         case when (select estado from salida_wa where llave = 'prueba56:atorado') = 'sin_confirmar'
               and exists (select 1 from jsonb_array_elements(current_setting('app.cola')::jsonb) x
                            where x ->> 'estado' = 'sin_confirmar' and x ->> 'telefono' = '9990005604')
              then 'ok' else 'FALLO' end,
         ' — cola_whatsapp() corre y pasa a "sin confirmar" lo atorado (no lo reintenta)'), true);

-- ---- nadie más ve la cola ----
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
select set_config('app.p11', concat(
         case when (select count(*) from salida_wa) = 0 and (select count(*) from wa_bajas) = 0
              then 'ok' else 'FALLO' end, ' — una cuenta sin rol no ve la cola ni las bajas'), true);
reset role;
select set_config('app.p12', concat(
         case when not has_table_privilege('anon', 'salida_wa', 'select')
               and not has_function_privilege('anon', 'tomar_salida(int)', 'execute')
              then 'ok' else 'FALLO' end, ' — anon no lee la cola ni puede tomar mensajes'), true);

select current_setting('app.p00') as p00, current_setting('app.p1') as p1, current_setting('app.p2') as p2,
       current_setting('app.p3') as p3, current_setting('app.p4') as p4, current_setting('app.p5') as p5,
       current_setting('app.p6') as p6, current_setting('app.p7') as p7, current_setting('app.p8') as p8,
       current_setting('app.p9') as p9, current_setting('app.p10') as p10, current_setting('app.p11') as p11,
       current_setting('app.p12') as p12, current_setting('app.p13') as p13;

rollback;
