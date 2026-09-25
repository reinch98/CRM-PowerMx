-- Prueba de la 26 (correr DESPUÉS de la 26; el bloque COMPLETO). Termina en rollback.
--
-- Todos los pasos deben decir "ok":
--  1 el admin escribe un componente sin orden de por medio
--  2 un campo vacío NO borra lo que ya estaba (el agente que no pudo leer la serie)
--  3 lo que sí trae valor sí se actualiza
--  4 otro componente no pisa al primero
--  5 un componente inventado se rechaza
--  6 un origen inventado se rechaza
--  7 el técnico no puede usar la puerta de la oficina
--  8 la puerta del técnico (guardar_placa) sigue funcionando desde su orden
--  9 el origen queda anotado en auditoría ('oficina' y 'campo')
-- 10 nadie puede llamar la función interna _fijar_componente
begin;

select set_config('app.res', 'la prueba no llegó al final (revisa si hubo un error arriba)', true);

do $$
declare
  v_admin uuid; v_tec uuid;
  v_cli uuid; v_eq uuid; v_cita uuid; v_orden uuid;
  r jsonb; v_res text := ''; v_txt text;
  v_n int; v_comp jsonb; v_b boolean;
begin
  select id into v_admin from perfiles where rol = 'admin' and coalesce(activo, true) limit 1;
  select id into v_tec from perfiles where rol = 'tecnico' and coalesce(activo, true) limit 1;
  if v_admin is null or v_tec is null then
    perform set_config('app.res', concat('SIN DATOS: admin=', coalesce(v_admin::text, 'no'),
      ' tecnico=', coalesce(v_tec::text, 'no')), true);
    return;
  end if;

  insert into clientes (nombre, telefono) values ('Cliente 26', '999 000 0260') returning id into v_cli;
  insert into equipos (cliente_id, numero_serie, tipo) values (v_cli, 'SER-26', 'generador') returning id into v_eq;
  insert into citas (cliente_id, equipo_id, fecha, tipo_servicio, estado, tecnico_id)
  values (v_cli, v_eq, (now() at time zone 'America/Mexico_City')::date, 'preventivo', 'programada', v_tec)
  returning id into v_cita;
  insert into ordenes_servicio (cliente_id, equipo_id, cita_id, fecha, tipo_servicio, tecnico_id, estado)
  values (v_cli, v_eq, v_cita, (now() at time zone 'America/Mexico_City')::date, 'preventivo', v_tec, 'abierta')
  returning id into v_orden;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);

  -- ---- 1. el admin escribe un componente ----
  r := actualizar_componente(v_eq, 'motor',
        jsonb_build_object('marca', 'Perkins', 'modelo', '1104C', 'serie', 'MOT-77'));
  select x into v_comp from equipos e, jsonb_array_elements(e.atributos -> 'componentes') x
   where e.id = v_eq and x ->> 'rol' = 'motor';
  v_res := concat(v_res, case when (r ->> 'ok') = 'true' and (v_comp ->> 'serie') = 'MOT-77'
    then '1 ok: el admin escribe un componente sin orden de por medio'
    else concat('1 FALLO: r=', r) end, E'\n');

  -- ---- 2. un campo vacío no borra ----
  r := actualizar_componente(v_eq, 'motor', jsonb_build_object('serie', '', 'modelo', '   '));
  select x into v_comp from equipos e, jsonb_array_elements(e.atributos -> 'componentes') x
   where e.id = v_eq and x ->> 'rol' = 'motor';
  v_res := concat(v_res, case when (v_comp ->> 'serie') = 'MOT-77' and (v_comp ->> 'modelo') = '1104C'
    then '2 ok: un campo vacío no borra lo que ya estaba'
    else concat('2 FALLO: comp=', v_comp) end, E'\n');

  -- ---- 3. lo que trae valor sí actualiza ----
  r := actualizar_componente(v_eq, 'motor', jsonb_build_object('serie', 'MOT-88'));
  select x into v_comp from equipos e, jsonb_array_elements(e.atributos -> 'componentes') x
   where e.id = v_eq and x ->> 'rol' = 'motor';
  v_res := concat(v_res, case when (v_comp ->> 'serie') = 'MOT-88' and (v_comp ->> 'marca') = 'Perkins'
    then '3 ok: lo que sí trae valor se actualiza y el resto se conserva'
    else concat('3 FALLO: comp=', v_comp) end, E'\n');

  -- ---- 4. otro componente ----
  r := actualizar_componente(v_eq, 'alternador', jsonb_build_object('marca', 'Stamford'));
  select jsonb_array_length(atributos -> 'componentes') into v_n from equipos where id = v_eq;
  v_res := concat(v_res, case when v_n = 2
    then '4 ok: otro componente no pisa al primero'
    else concat('4 FALLO: hay ', v_n) end, E'\n');

  -- ---- 5 y 6. valores inventados ----
  v_txt := '';
  begin perform actualizar_componente(v_eq, 'turbina', '{}'::jsonb); v_txt := 'aceptó el componente';
  exception when sqlstate '22023' then null; end;
  v_res := concat(v_res, case when v_txt = '' then '5 ok: un componente que no existe se rechaza'
    else concat('5 FALLO: ', v_txt) end, E'\n');

  v_txt := '';
  begin perform actualizar_componente(v_eq, 'motor', '{}'::jsonb, 'whatsapp'); v_txt := 'aceptó el origen';
  exception when sqlstate '22023' then null; end;
  v_res := concat(v_res, case when v_txt = '' then '6 ok: un origen que no existe se rechaza'
    else concat('6 FALLO: ', v_txt) end, E'\n');

  -- ---- 7. el técnico por la puerta de la oficina ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_tec, 'role', 'authenticated', 'email', 'tec@prueba')::text, true);
  v_txt := '';
  begin perform actualizar_componente(v_eq, 'motor', jsonb_build_object('serie', 'X')); v_txt := 'entró';
  exception when sqlstate '42501' then null; end;
  v_res := concat(v_res, case when v_txt = '' then '7 ok: el técnico no usa la puerta de la oficina'
    else concat('7 FALLO: ', v_txt) end, E'\n');

  -- ---- 8. pero la suya sigue sirviendo ----
  r := guardar_placa(v_orden, 'generador', 'placas/x/gen.jpg', jsonb_build_object('marca', 'Cummins'));
  select jsonb_array_length(atributos -> 'componentes') into v_n from equipos where id = v_eq;
  v_res := concat(v_res, case when (r ->> 'ok') = 'true' and v_n = 3
    then '8 ok: el técnico sigue guardando la placa desde su orden'
    else concat('8 FALLO: r=', r, ' n=', v_n) end, E'\n');

  -- ---- 9. el origen en auditoría ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);
  select count(*) filter (where origen = 'oficina') > 0
     and count(*) filter (where origen = 'campo') > 0
    into v_b
    from auditoria where tabla = 'equipos' and registro_id = v_eq and accion = 'componente';
  v_res := concat(v_res, case when v_b
    then '9 ok: el origen queda anotado (oficina y campo)'
    else '9 FALLO: falta algún origen en auditoría' end, E'\n');

  -- ---- 10. la función interna ----
  v_txt := '';
  begin perform _fijar_componente(v_eq, 'bms', '{}'::jsonb); v_txt := 'se pudo llamar';
  exception when insufficient_privilege then null; when others then null; end;
  v_res := concat(v_res, case when v_txt = ''
    then '10 ok: nadie llama la función interna por su cuenta'
    else concat('10 FALLO: ', v_txt) end);

  perform set_config('app.res', v_res, true);
end $$;

reset role;
select current_setting('app.res', true) as resultado;

rollback;
