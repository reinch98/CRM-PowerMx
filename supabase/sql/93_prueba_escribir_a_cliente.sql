-- Prueba del 93 (con rollback: no deja nada). Lleva bloques `do` para los rechazos: correr con la CLI
--   npx supabase db query --linked -f supabase/sql/93_prueba_escribir_a_cliente.sql
begin;

-- Una BAJA de prueba para el paso 5 (antes de cambiar de rol).
insert into wa_bajas (telefono_norm, origen, nota) values ('9990009302', 'prueba', 'prueba 93');

select set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated', 'email', email)::text, true)
  from perfiles where rol = 'admin' and coalesce(activo, true) order by created_at limit 1;
set local role authenticated;

-- 1. Encola la plantilla con las variables aplanadas
select set_config('app.r1', escribir_a_cliente('+52 1 999 000 9301', 'seguimiento_pendiente',
  jsonb_build_object('nombre', '  Ana   López ', 'equipo', E'Generac\n22 kW'))::text, true);
select set_config('app.p1', case
  when s.estado = 'pendiente' and s.origen = 'manual' and s.tipo = 'plantilla' and s.categoria = 'utilidad'
   and s.telefono_norm = '9990009301' and s.variables ->> 'nombre' = 'Ana López'
   and s.variables ->> 'equipo' = 'Generac 22 kW' and s.texto like 'Plantilla seguimiento_pendiente:%'
  then 'ok' else concat('FALLA ', row_to_json(s)::text) end, true)
from salida_wa s where s.id = (current_setting('app.r1')::jsonb ->> 'salida_id')::uuid;

-- 2. Un doble toque no duplica
select set_config('app.r2', escribir_a_cliente('9990009301', 'seguimiento_pendiente',
  jsonb_build_object('nombre', 'Ana López', 'equipo', 'Generac 22 kW'))::text, true);
select set_config('app.p2', case
  when (current_setting('app.r2')::jsonb ->> 'repetido') = 'true'
   and (select count(*) from salida_wa where telefono_norm = '9990009301' and origen = 'manual') = 1
  then 'ok' else 'FALLA' end, true);

-- 3. Falta una variable → se rechaza
do $$ begin
  perform escribir_a_cliente('9990009303', 'seguimiento_pendiente', jsonb_build_object('nombre', 'Ana'));
  perform set_config('app.p3', 'FALLA (no rechazó)', true);
exception when others then
  perform set_config('app.p3', case when sqlerrm like 'Falta el dato%' then 'ok' else 'FALLA ' || sqlerrm end, true);
end $$;

-- 4. Una plantilla de aviso de cita no se manda a mano
do $$ begin
  perform escribir_a_cliente('9990009303', 'cita_confirmada', '{}'::jsonb);
  perform set_config('app.p4', 'FALLA (no rechazó)', true);
exception when others then
  perform set_config('app.p4', case when sqlerrm like 'Esa plantilla sale sola%' then 'ok' else 'FALLA ' || sqlerrm end, true);
end $$;

-- 5. Marketing a un número con BAJA → se rechaza
do $$ begin
  perform escribir_a_cliente('9990009302', 'reactivacion_cliente', jsonb_build_object('nombre', 'Ana'));
  perform set_config('app.p5', 'FALLA (no rechazó)', true);
exception when others then
  perform set_config('app.p5', case when sqlerrm like '%BAJA%' then 'ok' else 'FALLA ' || sqlerrm end, true);
end $$;

-- 6. Un técnico no puede
select set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true)
  from perfiles where rol = 'tecnico' order by created_at limit 1;
do $$ begin
  perform escribir_a_cliente('9990009304', 'seguimiento_pendiente', jsonb_build_object('nombre', 'A', 'equipo', 'B'));
  perform set_config('app.p6', 'FALLA (no rechazó)', true);
exception when others then
  perform set_config('app.p6', case when sqlstate = '42501' then 'ok' else 'FALLA ' || sqlerrm end, true);
end $$;

select current_setting('app.p1') p1_encola, current_setting('app.p2') p2_no_duplica,
       current_setting('app.p3') p3_falta_dato, current_setting('app.p4') p4_aviso_no,
       current_setting('app.p5') p5_baja, current_setting('app.p6') p6_tecnico;
rollback;
