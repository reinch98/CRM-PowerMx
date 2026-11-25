-- Prueba del 103 (admin técnico de campo). SQL plano, todo con rollback.
-- Correr con: npx supabase db query --linked -f supabase/sql/103_prueba_admin_tecnico.sql
begin;

-- Un admin desechable (no se toca el perfil real) y un cliente de prueba.
select set_config('app.adm', gen_random_uuid()::text, true);
insert into auth.users (id, email, aud, role)
values (current_setting('app.adm')::uuid, 'prueba103@example.com', 'authenticated', 'authenticated');
update perfiles set rol = 'admin', activo = true, nombre = 'Admin 103', hace_campo = false
 where id = current_setting('app.adm')::uuid;
insert into perfiles (id, email, rol, activo, nombre, hace_campo)
select current_setting('app.adm')::uuid, 'prueba103@example.com', 'admin', true, 'Admin 103', false
where not exists (select 1 from perfiles where id = current_setting('app.adm')::uuid);
select set_config('app.cli', gen_random_uuid()::text, true);
insert into clientes (id, nombre, telefono) values (current_setting('app.cli')::uuid, 'Cliente 103', '9990000103');

-- 1. Sin la marca, el admin no es técnico de campo.
select set_config('app.p1', (not _tecnico_de_campo(current_setting('app.adm')::uuid))::text, true);

-- Con la marca, sí. Ya como ese admin:
update perfiles set hace_campo = true where id = current_setting('app.adm')::uuid;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.adm'), 'role', 'authenticated', 'email', 'prueba103@example.com')::text, true);
set local role authenticated;

-- 2. Sale en lista_tecnicos.
select set_config('app.p2', exists (select 1 from lista_tecnicos() where id = current_setting('app.adm')::uuid)::text, true);

-- 3. Se agenda como responsable y la orden nace con él.
select set_config('app.r3', agendar_cita(current_setting('app.cli')::uuid, null, 'correctivo', '2030-01-07', '10:00', 60,
  current_setting('app.adm')::uuid, null, null, 'prueba 103')::text, true);
select set_config('app.p3', ((current_setting('app.r3')::jsonb ->> 'ok')::boolean
  and exists (select 1 from ordenes_servicio where id = (current_setting('app.r3')::jsonb ->> 'orden_id')::uuid
                and tecnico_id = current_setting('app.adm')::uuid))::text, true);

-- 4. Los técnicos de verdad siguen saliendo.
select set_config('app.p4', ((select count(*) from lista_tecnicos()) >= 2)::text, true);

-- 5. Una orden cerrada suya no aparece en "Por pagar" (el dueño no se paga).
update ordenes_servicio set estado = 'cerrada', fecha = current_date
 where id = (current_setting('app.r3')::jsonb ->> 'orden_id')::uuid;
select set_config('app.p5', (position(current_setting('app.adm') in por_pagar_tecnicos()::text) = 0)::text, true);

reset role;
-- 6. Un técnico normal sigue siendo técnico de campo; cliente, almacén y bot, no.
select set_config('app.p6', ((select bool_and(_tecnico_de_campo(id)) from perfiles where rol = 'tecnico' and activo)
  and not coalesce((select bool_or(_tecnico_de_campo(id)) from perfiles where rol in ('cliente', 'almacenista', 'bot')), false))::text, true);

select concat_ws(' | ',
  '1 sin marca no es técnico: ' || current_setting('app.p1'),
  '2 en lista_tecnicos: ' || current_setting('app.p2'),
  '3 agenda como T1: ' || current_setting('app.p3'),
  '4 siguen los técnicos: ' || current_setting('app.p4'),
  '5 no sale en por pagar: ' || current_setting('app.p5'),
  '6 roles intactos: ' || current_setting('app.p6')) r;
rollback;
