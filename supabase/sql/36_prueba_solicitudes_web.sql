-- ---------------------------------------------------------------------------
-- Prueba de 36_solicitudes_web.sql. Correr DESPUÉS del 36, y el bloque COMPLETO.
-- Todo va en begin/rollback: no deja nada (los folios no aplican: no hay secuencias).
--
-- SQL plano, sin plpgsql ni `select into` (ver "Pruebas en el editor SQL" en CLAUDE.md).
--
-- LO QUE NO SE PUEDE PROBAR AQUÍ: los rechazos (nombre vacío, teléfono de menos de 10
-- dígitos, correo mal escrito, tope por hora o por día) LANZAN una excepción, y atrapar una
-- excepción exige plpgsql. Se comprueban a mano, corriendo cada línea SUELTA (sin
-- begin/rollback, con un teléfono de prueba) como el bot; cada una debe tronar con el mensaje
-- indicado, y la 4 con `54000`. Pensadas para no dejar nada si tronan.
--
--   1) select registrar_solicitud_web('', '9990003636');            -- "Escribe tu nombre."
--   2) select registrar_solicitud_web('Prueba', '12345');           -- "El WhatsApp debe tener 10 dígitos."
--   3) select registrar_solicitud_web('Prueba', '9990003636', 'no-es-correo');  -- "El correo no parece válido."
--   (el tope de 5 por día se ve con la Edge Function: mandar 6 veces con notas distintas)
-- ---------------------------------------------------------------------------

begin;

select set_config('app.bot',
         coalesce((select id::text from perfiles where rol = 'bot' and coalesce(activo, true) limit 1), ''), true),
       set_config('app.admin',
         coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true),
       set_config('app.tecnico',
         coalesce((select id::text from perfiles where rol = 'tecnico' and coalesce(activo, true) limit 1), ''), true);

select set_config('app.p0',
         case when nullif(current_setting('app.bot'), '') is null then 'FALLO: no hay perfil con rol bot'
              when nullif(current_setting('app.admin'), '') is null then 'FALLO: no hay admin activo'
              when nullif(current_setting('app.tecnico'), '') is null then 'FALLO: no hay técnico activo'
              else 'ok — hay bot, admin y técnico con quienes probar' end, true);

-- Un cliente con una persona conocida, para ver la sugerencia por teléfono.
select set_config('app.cliente', gen_random_uuid()::text, true);
insert into clientes (id, nombre, telefono)
values (current_setting('app.cliente')::uuid, 'Cliente de prueba (36)', '9990003600');
insert into contactos (id, cliente_id, nombre, telefono, whatsapp, verificado, activo,
                       de_toda_la_empresa, puede_pedir_citas, recibe_ordenes, recibe_cotizaciones,
                       created_at, updated_at)
values (gen_random_uuid(), current_setting('app.cliente')::uuid, 'Persona conocida (36)', '9990003636',
        true, true, true, true, false, false, false, now(), now());

-- ---- como el BOT (la cuenta que usa la Edge Function) ----
select set_config('request.jwt.claims',
         json_build_object('sub', current_setting('app.bot'), 'role', 'authenticated',
                           'email', 'bot@prueba')::text, true);
set local role authenticated;

-- 1) Un teléfono conocido: entra y sugiere el cliente.
select set_config('app.r1', registrar_solicitud_web(
         'Prueba Web 36', '999 000 3636', 'prueba@ejemplo.com', 'Mérida', 'Generador', 'Residencial',
         null, null, null, null, null, 'nota A', 'https://powermx.com.mx/cotizar.html')::text, true);

select set_config('app.p1', concat(
         case when (current_setting('app.r1')::jsonb ->> 'ok') = 'true'
               and (current_setting('app.r1')::jsonb ->> 'repetido') = 'false'
               and (current_setting('app.r1')::jsonb ->> 'cliente_sugerido') = 'true'
              then 'ok' else 'FALLO' end,
         ' — entró, no es repetida y sugiere cliente: ', current_setting('app.r1')), true);

-- 2) Lo mismo otra vez (doble clic): devuelve la MISMA, no duplica.
select set_config('app.r2', registrar_solicitud_web(
         'Prueba Web 36', '999 000 3636', 'prueba@ejemplo.com', 'Mérida', 'Generador', 'Residencial',
         null, null, null, null, null, 'nota A', 'https://powermx.com.mx/cotizar.html')::text, true);

select set_config('app.p2', concat(
         case when (current_setting('app.r2')::jsonb ->> 'repetido') = 'true'
               and (current_setting('app.r2')::jsonb ->> 'id') = (current_setting('app.r1')::jsonb ->> 'id')
              then 'ok' else 'FALLO' end,
         ' — el reintento devolvió la misma solicitud: ', current_setting('app.r2')), true);

-- 3) Mismo número con OTRO contenido: es otra solicitud. Y un número desconocido no sugiere nada.
select set_config('app.r3', registrar_solicitud_web(
         'Prueba Web 36', '999 000 3636', null, null, 'Solar', null, null, null, null, null, null,
         'nota B', null)::text, true);
select set_config('app.r4', registrar_solicitud_web(
         'Desconocido 36', '999 000 3637', null, null, 'Generador', null, null, null, null, null, null,
         null, null)::text, true);

select set_config('app.p3', concat(
         case when (current_setting('app.r3')::jsonb ->> 'repetido') = 'false'
               and (current_setting('app.r3')::jsonb ->> 'id') <> (current_setting('app.r1')::jsonb ->> 'id')
               and (current_setting('app.r4')::jsonb ->> 'repetido') = 'false'
               and (current_setting('app.r4')::jsonb ->> 'cliente_sugerido') = 'false'
              then 'ok' else 'FALLO' end,
         ' — otro contenido crea otra; el número desconocido no sugiere cliente: ',
         current_setting('app.r3'), ' / ', current_setting('app.r4')), true);

-- 4) El bot NO puede leer la tabla (solo escribe por la función).
select set_config('app.p4', concat(
         case when (select count(*) from solicitudes_web) = 0 then 'ok' else 'FALLO' end,
         ' — el bot ve ', (select count(*) from solicitudes_web), ' solicitudes (debe ser 0)'), true);

-- 5) Y no puede resolverlas.
with intento as (
  update solicitudes_web set estado = 'descartada' returning 1
)
select set_config('app.p5', concat(
         case when (select count(*) from intento) = 0 then 'ok' else 'FALLO' end,
         ' — el bot modificó ', (select count(*) from intento), ' solicitudes (debe ser 0)'), true);

-- ---- como TÉCNICO ----
select set_config('request.jwt.claims',
         json_build_object('sub', current_setting('app.tecnico'), 'role', 'authenticated')::text, true);

select set_config('app.p6', concat(
         case when (select count(*) from solicitudes_web) = 0 then 'ok' else 'FALLO' end,
         ' — el técnico ve ', (select count(*) from solicitudes_web), ' solicitudes (debe ser 0)'), true);

-- ---- como ADMIN ----
select set_config('request.jwt.claims',
         json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated',
                           'email', 'admin@prueba')::text, true);

select set_config('app.p7', concat(
         case when (select count(*) from solicitudes_web where telefono_norm in ('9990003636', '9990003637')) = 3
              then 'ok' else 'FALLO' end,
         ' — el admin ve ',
         (select count(*) from solicitudes_web where telefono_norm in ('9990003636', '9990003637')),
         ' de las 3 solicitudes de prueba (la repetida no cuenta)'), true);

-- La sugerencia quedó ligada al cliente correcto.
select set_config('app.p8', concat(
         case when (select cliente_id from solicitudes_web
                     where id = (current_setting('app.r1')::jsonb ->> 'id')::uuid)
                   = current_setting('app.cliente')::uuid then 'ok' else 'FALLO' end,
         ' — la solicitud sugerida quedó ligada al cliente de la prueba'), true);

-- 9) Resolverla deja quién y cuándo; reabrirla los borra.
select resolver_solicitud_web((current_setting('app.r1')::jsonb ->> 'id')::uuid, 'atendida', 'Le hablé por teléfono');

select set_config('app.p9', concat(
         case when (select estado = 'atendida' and atendida_por = 'admin@prueba' and atendida_en is not null
                           and nota_interna = 'Le hablé por teléfono'
                      from solicitudes_web where id = (current_setting('app.r1')::jsonb ->> 'id')::uuid)
              then 'ok' else 'FALLO' end,
         ' — atendida con su nota, su autor y su fecha'), true);

select resolver_solicitud_web((current_setting('app.r1')::jsonb ->> 'id')::uuid, 'nueva');

select set_config('app.p10', concat(
         case when (select estado = 'nueva' and atendida_por is null and atendida_en is null
                           and nota_interna = 'Le hablé por teléfono'
                      from solicitudes_web where id = (current_setting('app.r1')::jsonb ->> 'id')::uuid)
              then 'ok' else 'FALLO' end,
         ' — reabierta: sin autor ni fecha, y la nota se conserva'), true);

-- ---- lo que se ve desde afuera ----
reset role;

select set_config('app.p11', concat(
         case when not has_table_privilege('anon', 'solicitudes_web', 'select')
               and not has_function_privilege('anon',
                     'registrar_solicitud_web(text,text,text,text,text,text,text,text,text,text,text,text,text)', 'execute')
               and not has_function_privilege('anon', 'resolver_solicitud_web(uuid,text,text,uuid)', 'execute')
              then 'ok' else 'FALLO' end,
         ' — anon no toca la tabla ni ejecuta las funciones'), true);

select current_setting('app.p0') as p0,
       current_setting('app.p1') as p1,
       current_setting('app.p2') as p2,
       current_setting('app.p3') as p3,
       current_setting('app.p4') as p4,
       current_setting('app.p5') as p5,
       current_setting('app.p6') as p6,
       current_setting('app.p7') as p7,
       current_setting('app.p8') as p8,
       current_setting('app.p9') as p9,
       current_setting('app.p10') as p10,
       current_setting('app.p11') as p11;

rollback;
