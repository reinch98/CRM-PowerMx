-- ---------------------------------------------------------------------------
-- Prueba de 54_recordatorio_cita.sql. Correr DESPUÉS del 54, y el bloque COMPLETO.
-- Todo va en begin/rollback: no deja nada.
--
-- SQL plano, sin plpgsql (ver "Pruebas en el editor SQL" en CLAUDE.md). Dos citas de
-- prueba, cada una ejercita un camino de generar_recordatorios(): A tiene un contacto
-- de la empresa (camino "c:"), B no tiene contacto y usa el teléfono de su ficha
-- (camino "f:"). Las dos para MAÑANA en hora de Mérida.
--
-- Por qué se marca la confirmación como "enviada" antes de llamar la función: al
-- insertar la cita en estado `programada`, el trigger `avisos_de_cita` (16) ya deja un
-- aviso de confirmación PENDIENTE para el mismo destinatario, y el índice único
-- `un_aviso_pendiente` es por (cita, destinatario) sin importar el tipo — si se dejara
-- pendiente, el recordatorio chocaría con él y no se crearía nada. En la vida real,
-- para cuando llega "mañana" esa confirmación ya se mandó hace días; aquí se simula
-- marcándola enviada a mano, sin pasar por marcar_aviso() para no meter otra pieza al
-- escenario.
-- ---------------------------------------------------------------------------

begin;

select set_config('app.admin',
         coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('app.p00',
         case when nullif(current_setting('app.admin'), '') is null then 'FALLO: no hay admin activo'
              else 'ok — hay un admin con quien leer el texto' end, true);

select set_config('app.manana', ((now() at time zone 'America/Mexico_City')::date + 1)::text, true);

-- ---- cliente A: con contacto de la empresa ----
select set_config('app.clienteA', gen_random_uuid()::text, true),
       set_config('app.contactoA', gen_random_uuid()::text, true),
       set_config('app.citaA', gen_random_uuid()::text, true);

insert into clientes (id, nombre, telefono) values
  (current_setting('app.clienteA')::uuid, 'Cliente de prueba 54-A', '9990005401');

insert into contactos (id, cliente_id, nombre, telefono, whatsapp, verificado, activo,
                       de_toda_la_empresa, puede_pedir_citas, recibe_ordenes, recibe_cotizaciones,
                       created_at, updated_at)
values (current_setting('app.contactoA')::uuid, current_setting('app.clienteA')::uuid,
        'Contacto de prueba 54-A', '9990005402', true, true, true, true, true, false, false, now(), now());

insert into citas (id, cliente_id, tipo_servicio, fecha, estado) values
  (current_setting('app.citaA')::uuid, current_setting('app.clienteA')::uuid, 'preventivo',
   nullif(current_setting('app.manana'), '')::date, 'programada');

-- Libera el pendiente que el trigger (16) ya encoló, como se explica arriba.
update avisos set estado = 'enviado', enviado_at = now()
 where cita_id = current_setting('app.citaA')::uuid and tipo = 'confirmacion';

-- ---- cliente B: sin contacto, con teléfono en la ficha ----
select set_config('app.clienteB', gen_random_uuid()::text, true),
       set_config('app.citaB', gen_random_uuid()::text, true);

insert into clientes (id, nombre, telefono) values
  (current_setting('app.clienteB')::uuid, 'Cliente de prueba 54-B', '9990005403');

insert into citas (id, cliente_id, tipo_servicio, fecha, estado) values
  (current_setting('app.citaB')::uuid, current_setting('app.clienteB')::uuid, 'correctivo',
   nullif(current_setting('app.manana'), '')::date, 'programada');

update avisos set estado = 'enviado', enviado_at = now()
 where cita_id = current_setting('app.citaB')::uuid and tipo = 'confirmacion';

-- ---- una cita de control que NO debe recibir recordatorio: pasado mañana ----
select set_config('app.clienteC', gen_random_uuid()::text, true),
       set_config('app.citaC', gen_random_uuid()::text, true);
insert into clientes (id, nombre, telefono) values
  (current_setting('app.clienteC')::uuid, 'Cliente de prueba 54-C', '9990005404');
insert into citas (id, cliente_id, tipo_servicio, fecha, estado) values
  (current_setting('app.citaC')::uuid, current_setting('app.clienteC')::uuid, 'preventivo',
   nullif(current_setting('app.manana'), '')::date + 1, 'programada');

select set_config('app.p0', 'ok — escenario listo: A con contacto, B con teléfono de ficha, C pasado mañana', true);

-- ---- primera corrida ----
select set_config('app.n1', generar_recordatorios()::text, true);

select set_config('app.p1', concat(
         case when exists (
                select 1 from avisos where cita_id = current_setting('app.citaA')::uuid
                 and tipo = 'recordatorio' and destinatario = 'cliente' and estado = 'pendiente')
              then 'ok' else 'FALLO' end,
         ' — A (con contacto) recibió su recordatorio pendiente'), true);

select set_config('app.p2', concat(
         case when exists (
                select 1 from avisos where cita_id = current_setting('app.citaB')::uuid
                 and tipo = 'recordatorio' and destinatario = 'cliente' and estado = 'pendiente'
                 and telefono = '9990005403')
              then 'ok' else 'FALLO' end,
         ' — B (sin contacto) recibió el suyo con el teléfono de la ficha'), true);

select set_config('app.p3', concat(
         case when not exists (select 1 from avisos where cita_id = current_setting('app.citaC')::uuid and tipo = 'recordatorio')
              then 'ok' else 'FALLO' end,
         ' — C (pasado mañana) no recibió nada'), true);

-- ---- segunda corrida: no debe duplicar ----
select set_config('app.n2', generar_recordatorios()::text, true);

select set_config('app.p4', concat(
         case when (select count(*) from avisos where cita_id = current_setting('app.citaA')::uuid and tipo = 'recordatorio') = 1
              then 'ok' else 'FALLO' end,
         ' — correrla dos veces no duplica el de A (sigue en 1)'), true);

-- ---- el texto, como admin ----
-- texto_aviso() exige es_admin(): hace falta el id de un admin REAL de la base (ya
-- comprobado en app.p00), no cualquier uuid.
select set_config('request.jwt.claims',
         json_build_object('sub', nullif(current_setting('app.admin'), ''), 'role', 'authenticated')::text, true);
set local role authenticated;

select set_config('app.textoA', coalesce(
         texto_aviso((select id from avisos where cita_id = current_setting('app.citaA')::uuid and tipo = 'recordatorio')),
         '(vacío)'), true);

select set_config('app.p5', concat(
         case when current_setting('app.textoA') ilike '%recordamos%' and current_setting('app.textoA') ilike '%mañana%'
              then 'ok' else 'FALLO' end,
         ' — el texto dice "recordamos" y "mañana": ', current_setting('app.textoA')), true);

reset role;

-- ---- nadie más puede llamar generar_recordatorios() por la API ----
select set_config('app.p6', concat(
         case when not has_function_privilege('authenticated', 'generar_recordatorios()', 'execute')
               and not has_function_privilege('anon', 'generar_recordatorios()', 'execute')
              then 'ok' else 'FALLO' end,
         ' — ni authenticated ni anon pueden ejecutar generar_recordatorios()'), true);

select current_setting('app.p00') as p00,
       current_setting('app.p0') as p0,
       current_setting('app.p1') as p1,
       current_setting('app.p2') as p2,
       current_setting('app.p3') as p3,
       current_setting('app.p4') as p4,
       current_setting('app.p5') as p5,
       current_setting('app.p6') as p6;

rollback;
