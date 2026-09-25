-- Prueba de la 25 (correr DESPUÉS de la 25; el bloque COMPLETO). Termina en rollback.
--
-- Todos los pasos deben decir "ok":
--  1 el técnico de la orden guarda una placa y queda en atributos.componentes
--  2 guardar otro componente no pisa el anterior
--  3 volver a guardar el mismo lo actualiza y conserva lo que ya tenía
--  4 un componente inventado se rechaza
--  5 un técnico ajeno es rechazado
--  6 una orden sin equipo lo dice con todas sus letras
--  7 con la orden cerrada ya no se guardan placas
--  8 queda el rastro en auditoría
--  9 el admin también puede
-- 10 el técnico lee el equipo con sus componentes
begin;

select set_config('app.res', 'la prueba no llegó al final (revisa si hubo un error arriba)', true);

do $$
declare
  v_admin uuid; v_tec uuid; v_otro uuid; v_rol_previo text;
  v_cli uuid; v_eq uuid; v_cita uuid; v_orden uuid; v_orden_sin uuid;
  r jsonb; v_res text := ''; v_txt text;
  v_n int; v_comp jsonb; v_b boolean;
begin
  select id into v_admin from perfiles where rol = 'admin' and coalesce(activo, true) limit 1;
  select id into v_tec from perfiles where rol = 'tecnico' and coalesce(activo, true) limit 1;
  select id into v_otro from perfiles where id not in (v_admin, v_tec) limit 1;
  if v_admin is null or v_tec is null or v_otro is null then
    perform set_config('app.res', concat('SIN DATOS: admin=', coalesce(v_admin::text, 'no'),
      ' tecnico=', coalesce(v_tec::text, 'no'), ' tercero=', coalesce(v_otro::text, 'no')), true);
    return;
  end if;
  select rol into v_rol_previo from perfiles where id = v_otro;
  update perfiles set rol = 'tecnico', activo = true where id = v_otro;

  insert into clientes (nombre, telefono) values ('Cliente 25', '999 000 0250') returning id into v_cli;
  insert into equipos (cliente_id, numero_serie, tipo, marca)
  values (v_cli, 'SER-25', 'solar', 'Huawei') returning id into v_eq;

  insert into citas (cliente_id, equipo_id, fecha, tipo_servicio, estado, tecnico_id)
  values (v_cli, v_eq, (now() at time zone 'America/Mexico_City')::date, 'preventivo', 'programada', v_tec)
  returning id into v_cita;
  insert into ordenes_servicio (cliente_id, equipo_id, cita_id, fecha, tipo_servicio, tecnico_id, estado)
  values (v_cli, v_eq, v_cita, (now() at time zone 'America/Mexico_City')::date, 'preventivo', v_tec, 'abierta')
  returning id into v_orden;
  insert into orden_partes (orden_id, autor_id, notas) values (v_orden, v_tec, 'Captura de placas.');

  -- una orden sin equipo, para el paso 6
  insert into ordenes_servicio (cliente_id, fecha, tipo_servicio, tecnico_id, estado)
  values (v_cli, (now() at time zone 'America/Mexico_City')::date, 'preventivo', v_tec, 'abierta')
  returning id into v_orden_sin;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_tec, 'role', 'authenticated', 'email', 'tec@prueba')::text, true);

  -- ---- 1. la primera placa ----
  r := guardar_placa(v_orden, 'inversor_1', 'placas/x/inversor_1.jpg',
        jsonb_build_object('marca', 'Huawei', 'modelo', 'SUN2000', 'serie', 'INV-001'));
  select x into v_comp from equipos e, jsonb_array_elements(e.atributos -> 'componentes') x
   where e.id = v_eq and x ->> 'rol' = 'inversor_1';
  v_res := concat(v_res, case when (r ->> 'ok') = 'true' and (v_comp ->> 'serie') = 'INV-001'
                              and (v_comp ->> 'foto') = 'placas/x/inversor_1.jpg'
    then '1 ok: la placa queda en atributos.componentes con su foto'
    else concat('1 FALLO: r=', r, ' comp=', coalesce(v_comp::text, 'null')) end, E'\n');

  -- ---- 2. otro componente ----
  r := guardar_placa(v_orden, 'modulos', 'placas/x/modulos.jpg',
        jsonb_build_object('marca', 'Jinko', 'cantidad', 24));
  select jsonb_array_length(atributos -> 'componentes') into v_n from equipos where id = v_eq;
  v_res := concat(v_res, case when v_n = 2
    then '2 ok: guardar otro componente no pisa el anterior'
    else concat('2 FALLO: hay ', v_n, ' componentes') end, E'\n');

  -- ---- 3. actualizar el mismo sin perder lo anterior ----
  r := guardar_placa(v_orden, 'inversor_1', 'placas/x/inversor_1b.jpg', null);
  select x into v_comp from equipos e, jsonb_array_elements(e.atributos -> 'componentes') x
   where e.id = v_eq and x ->> 'rol' = 'inversor_1';
  select jsonb_array_length(atributos -> 'componentes') into v_n from equipos where id = v_eq;
  v_res := concat(v_res, case when v_n = 2 and (v_comp ->> 'serie') = 'INV-001'
                              and (v_comp ->> 'foto') = 'placas/x/inversor_1b.jpg'
    then '3 ok: se actualiza la foto y se conservan los datos que ya tenía'
    else concat('3 FALLO: n=', v_n, ' comp=', coalesce(v_comp::text, 'null')) end, E'\n');

  -- ---- 4. componente inventado ----
  v_txt := '';
  begin
    perform guardar_placa(v_orden, 'turbina', null, null);
    v_txt := 'aceptó un componente inventado';
  exception when sqlstate '22023' then null;
  end;
  v_res := concat(v_res, case when v_txt = ''
    then '4 ok: un componente que no existe se rechaza'
    else concat('4 FALLO: ', v_txt) end, E'\n');

  -- ---- 5. un técnico ajeno ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_otro, 'role', 'authenticated', 'email', 'ajeno@prueba')::text, true);
  v_txt := '';
  begin
    perform guardar_placa(v_orden, 'bms', 'placas/x/robada.jpg', null);
    v_txt := 'escribió en un equipo ajeno';
  exception when sqlstate '42501' then null;
  end;
  v_res := concat(v_res, case when v_txt = ''
    then '5 ok: un técnico que no es de la orden no toca el equipo'
    else concat('5 FALLO: ', v_txt) end, E'\n');

  -- ---- 6. orden sin equipo ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_tec, 'role', 'authenticated', 'email', 'tec@prueba')::text, true);
  v_txt := '';
  begin
    perform guardar_placa(v_orden_sin, 'motor', null, null);
    v_txt := 'guardó sin equipo';
  exception when sqlstate '22023' then
    get stacked diagnostics v_txt = message_text;
    v_txt := case when v_txt like '%elígelo antes%' then '' else concat('mensaje raro: ', v_txt) end;
  end;
  v_res := concat(v_res, case when v_txt = ''
    then '6 ok: una orden sin equipo lo dice con todas sus letras'
    else concat('6 FALLO: ', v_txt) end, E'\n');

  -- ---- 8 (antes de cerrar): el rastro ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);
  select count(*) > 0 into v_b from auditoria
   where tabla = 'equipos' and registro_id = v_eq and accion = 'placa';

  -- ---- 9. el admin ----
  r := guardar_placa(v_orden, 'bms', 'placas/x/bms.jpg', jsonb_build_object('marca', 'PowerMx'));
  select jsonb_array_length(atributos -> 'componentes') into v_n from equipos where id = v_eq;

  -- ---- 7. con la orden cerrada ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_tec, 'role', 'authenticated', 'email', 'tec@prueba')::text, true);
  perform cerrar_orden(v_orden, null::text, true, null::numeric, 'listo', null::text,
                       false, null::date, null::jsonb, null::jsonb);
  v_txt := '';
  begin
    perform guardar_placa(v_orden, 'bateria', 'placas/x/tarde.jpg', null);
    v_txt := 'guardó con la orden cerrada';
  exception when sqlstate '22023' then null;
  end;
  v_res := concat(v_res, case when v_txt = ''
    then '7 ok: con la orden cerrada ya no se guardan placas'
    else concat('7 FALLO: ', v_txt) end, E'\n');
  v_res := concat(v_res, case when v_b
    then '8 ok: queda el rastro en auditoría'
    else '8 FALLO: sin rastro' end, E'\n');
  v_res := concat(v_res, case when (r ->> 'ok') = 'true' and v_n = 3
    then '9 ok: el admin también puede'
    else concat('9 FALLO: r=', r, ' n=', v_n) end, E'\n');

  -- ---- 10. el técnico lee los componentes ----
  select jsonb_array_length(atributos -> 'componentes') into v_n from equipos where id = v_eq;
  v_res := concat(v_res, case when v_n = 3
    then '10 ok: el técnico lee el equipo con sus componentes'
    else concat('10 FALLO: ve ', coalesce(v_n::text, 'nada')) end);

  perform set_config('app.res', v_res, true);
  reset role;
  update perfiles set rol = v_rol_previo where id = v_otro;
end $$;

reset role;
select current_setting('app.res', true) as resultado;

rollback;
