-- Prueba de la 24 (correr DESPUÉS de la 24; el bloque COMPLETO). Termina en rollback.
-- Crea su propio cliente, cita y orden; usa el admin y el técnico que ya existan.
--
-- Todos los pasos deben decir "ok":
--  1 el técnico de la orden crea su revisión y la vuelve a guardar (upsert) sin duplicar
--  2 el sello lo pone la base: updated_at y actualizado_por no se le creen al navegador
--  3 un técnico ajeno no la lee ni la escribe
--  4 el tipo solo acepta generador o solar
--  5 un punto de SEGURIDAD en "M" sin control compensatorio BLOQUEA el cierre
--  6 con el control compensatorio escrito, la orden sí cierra
--  7 un "M" fuera de la sección de seguridad no bloquea nada
--  8 con la orden cerrada el técnico ya no puede editar la revisión
--  9 cerrada, el técnico la sigue LEYENDO
-- 10 el admin lee y escribe cualquier revisión
begin;

select set_config('app.res', 'la prueba no llegó al final (revisa si hubo un error arriba)', true);

do $$
declare
  v_admin uuid; v_tec uuid; v_otro uuid;
  v_cli uuid; v_cita uuid; v_orden uuid; v_cita2 uuid; v_orden2 uuid;
  v_res text := ''; v_txt text;
  v_n int; v_quien uuid; v_sello timestamptz; v_rol_previo text;
begin
  select id into v_admin from perfiles where rol = 'admin' and coalesce(activo, true) limit 1;
  select id into v_tec from perfiles where rol = 'tecnico' and coalesce(activo, true) limit 1;
  -- Un tercer perfil hace de técnico ajeno; se le devuelve su rol al final.
  select id into v_otro from perfiles where id not in (v_admin, v_tec) limit 1;
  if v_admin is null or v_tec is null or v_otro is null then
    perform set_config('app.res', concat('SIN DATOS: admin=', coalesce(v_admin::text, 'no'),
      ' tecnico=', coalesce(v_tec::text, 'no'), ' tercero=', coalesce(v_otro::text, 'no')), true);
    return;
  end if;
  select rol into v_rol_previo from perfiles where id = v_otro;
  update perfiles set rol = 'tecnico', activo = true where id = v_otro;

  insert into clientes (nombre, telefono) values ('Cliente 24', '999 000 0240') returning id into v_cli;

  insert into citas (cliente_id, fecha, tipo_servicio, estado, tecnico_id)
  values (v_cli, (now() at time zone 'America/Mexico_City')::date, 'preventivo', 'programada', v_tec)
  returning id into v_cita;
  insert into ordenes_servicio (cliente_id, cita_id, fecha, tipo_servicio, tecnico_id, estado)
  values (v_cli, v_cita, (now() at time zone 'America/Mexico_City')::date, 'preventivo', v_tec, 'abierta')
  returning id into v_orden;
  insert into orden_partes (orden_id, autor_id, notas)
  values (v_orden, v_tec, 'Mantenimiento preventivo del sistema FV.');

  -- una segunda orden, para el paso 7
  insert into citas (cliente_id, fecha, tipo_servicio, estado, tecnico_id)
  values (v_cli, (now() at time zone 'America/Mexico_City')::date, 'preventivo', 'programada', v_tec)
  returning id into v_cita2;
  insert into ordenes_servicio (cliente_id, cita_id, fecha, tipo_servicio, tecnico_id, estado)
  values (v_cli, v_cita2, (now() at time zone 'America/Mexico_City')::date, 'preventivo', v_tec, 'abierta')
  returning id into v_orden2;
  insert into orden_partes (orden_id, autor_id, notas) values (v_orden2, v_tec, 'Revisión general.');

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_tec, 'role', 'authenticated', 'email', 'tec@prueba')::text, true);

  -- ---- 1. crear y volver a guardar ----
  insert into orden_revision (orden_id, tipo, datos)
  values (v_orden, 'solar', jsonb_build_object('puntos', jsonb_build_object(
    '2.1', jsonb_build_object('v', 'B'))));
  insert into orden_revision (orden_id, tipo, datos)
  values (v_orden, 'solar', jsonb_build_object('puntos', jsonb_build_object(
    '2.1', jsonb_build_object('v', 'B'), '2.2', jsonb_build_object('v', 'R', 'obs', 'hot spot leve', 'num', 12))))
  on conflict (orden_id) do update set tipo = excluded.tipo, datos = excluded.datos;
  select count(*) into v_n from orden_revision where orden_id = v_orden;
  select (datos -> 'puntos' -> '2.2' ->> 'obs') into v_txt from orden_revision where orden_id = v_orden;
  v_res := concat(v_res, case when v_n = 1 and v_txt = 'hot spot leve'
    then '1 ok: la revisión se crea y el upsert la reemplaza sin duplicar'
    else concat('1 FALLO: filas=', v_n, ' obs=', coalesce(v_txt, 'null')) end, E'\n');

  -- ---- 2. el sello lo pone la base ----
  update orden_revision set actualizado_por = v_admin, updated_at = '2000-01-01'
   where orden_id = v_orden;
  select actualizado_por, updated_at into v_quien, v_sello from orden_revision where orden_id = v_orden;
  v_res := concat(v_res, case when v_quien = v_tec and v_sello > now() - interval '1 minute'
    then '2 ok: el sello lo pone la base, no el navegador'
    else concat('2 FALLO: quien=', coalesce(v_quien::text, 'null'), ' sello=', v_sello) end, E'\n');

  -- ---- 3. un técnico ajeno ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_otro, 'role', 'authenticated', 'email', 'ajeno@prueba')::text, true);
  select count(*) into v_n from orden_revision where orden_id = v_orden;
  v_txt := '';
  begin
    update orden_revision set datos = '{"robado": true}'::jsonb where orden_id = v_orden;
    if found then v_txt := 'la escribió'; end if;
  exception when sqlstate '42501' then null;
  end;
  v_res := concat(v_res, case when v_n = 0 and v_txt = ''
    then '3 ok: un técnico ajeno no la lee ni la escribe'
    else concat('3 FALLO: ve ', v_n, ' filas; ', v_txt) end, E'\n');

  -- ---- 4. el tipo ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_tec, 'role', 'authenticated', 'email', 'tec@prueba')::text, true);
  v_txt := '';
  begin
    update orden_revision set tipo = 'submarino' where orden_id = v_orden;
    v_txt := 'aceptó un tipo inventado';
  exception when check_violation then null;
  end;
  v_res := concat(v_res, case when v_txt = ''
    then '4 ok: el tipo solo acepta generador o solar'
    else concat('4 FALLO: ', v_txt) end, E'\n');

  -- ---- 5. seguridad en "M" sin control compensatorio ----
  update orden_revision set datos = jsonb_set(datos, '{puntos,1.3}',
    jsonb_build_object('v', 'M', 'obs', ''))
   where orden_id = v_orden;
  v_txt := '';
  begin
    perform cerrar_orden(v_orden, null::text, true, null::numeric, 'listo', null::text,
                         false, null::date, null::jsonb, null::jsonb);
    v_txt := 'cerró con seguridad sin resolver';
  exception when sqlstate '22023' then null;
  end;
  v_res := concat(v_res, case when v_txt = ''
    then '5 ok: un punto de seguridad en "M" sin control compensatorio bloquea el cierre'
    else concat('5 FALLO: ', v_txt) end, E'\n');

  -- ---- 6. con el control escrito, sí cierra ----
  update orden_revision set datos = jsonb_set(datos, '{puntos,1.3}',
    jsonb_build_object('v', 'M', 'obs', 'Se aisló con candado propio y se avisó al supervisor.'))
   where orden_id = v_orden;
  perform cerrar_orden(v_orden, null::text, true, null::numeric, 'listo', null::text,
                       false, null::date, null::jsonb, null::jsonb);
  select count(*) into v_n from ordenes_servicio where id = v_orden and estado = 'cerrada';
  v_res := concat(v_res, case when v_n = 1
    then '6 ok: con el control compensatorio escrito, la orden cierra'
    else '6 FALLO: no cerró' end, E'\n');

  -- ---- 7. un "M" fuera de seguridad no bloquea ----
  insert into orden_revision (orden_id, tipo, datos)
  values (v_orden2, 'solar', jsonb_build_object('puntos', jsonb_build_object(
    '3.2', jsonb_build_object('v', 'M', 'obs', ''))));
  perform cerrar_orden(v_orden2, null::text, true, null::numeric, 'listo', null::text,
                       false, null::date, null::jsonb, null::jsonb);
  select count(*) into v_n from ordenes_servicio where id = v_orden2 and estado = 'cerrada';
  v_res := concat(v_res, case when v_n = 1
    then '7 ok: un "M" fuera de la sección de seguridad no bloquea el cierre'
    else '7 FALLO: bloqueó de más' end, E'\n');

  -- ---- 8. cerrada, no se edita ----
  v_txt := '';
  begin
    update orden_revision set datos = '{"tarde": true}'::jsonb where orden_id = v_orden;
    if found then v_txt := 'la editó con la orden cerrada'; end if;
  exception when sqlstate '42501' then null;
  end;
  v_res := concat(v_res, case when v_txt = ''
    then '8 ok: con la orden cerrada el técnico ya no edita la revisión'
    else concat('8 FALLO: ', v_txt) end, E'\n');

  -- ---- 9. pero la sigue leyendo ----
  select count(*) into v_n from orden_revision where orden_id = v_orden;
  v_res := concat(v_res, case when v_n = 1
    then '9 ok: cerrada, el técnico la sigue leyendo'
    else concat('9 FALLO: ve ', v_n, ' filas') end, E'\n');

  -- ---- 10. el admin ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);
  update orden_revision set datos = datos || '{"revisado_oficina": true}'::jsonb where orden_id = v_orden;
  select count(*) into v_n from orden_revision where orden_id = v_orden
     and (datos ->> 'revisado_oficina') = 'true';
  v_res := concat(v_res, case when v_n = 1
    then '10 ok: el admin lee y escribe cualquier revisión'
    else '10 FALLO: el admin no pudo' end);

  perform set_config('app.res', v_res, true);
  reset role;
  update perfiles set rol = v_rol_previo where id = v_otro;
end $$;

reset role;
select current_setting('app.res', true) as resultado;

rollback;
