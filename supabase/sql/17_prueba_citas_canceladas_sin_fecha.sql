-- Prueba de la 17 (correr DESPUÉS de la 17; el bloque COMPLETO). Termina en rollback: no deja nada.
-- Necesita un admin y un cliente. Todos los pasos deben decir "ok":
--  1 cancelar una cita "por programar" (sin fecha) con cancelar_cita ya no truena
--  2 cancelar una cotización aceptada cuya cita no tiene fecha (rechazarla) tampoco
--  3 una cita programada o realizada SIN fecha sigue prohibida
begin;

select set_config('app.res', 'la prueba no llegó al final (revisa si hubo un error arriba)', true);

do $$
declare
  v_admin uuid; v_cli uuid; v_cot uuid;
  k1 uuid; k2 uuid;
  r jsonb; v_res text := ''; v_estado text; v_est2 text;
begin
  select id into v_admin from perfiles where rol = 'admin' and coalesce(activo, true) limit 1;
  select id into v_cli from clientes limit 1;
  select id into v_cot from cotizaciones limit 1;

  if v_admin is null or v_cli is null then
    perform set_config('app.res', 'SIN DATOS: hace falta un admin y un cliente.', true);
    return;
  end if;

  -- ---- preparación (como dueño de la base; se deshace al final) ----
  insert into citas (cliente_id, tipo_servicio, fecha, hora, estado, origen)
    values (v_cli, 'preventivo', null, null, 'por_programar', 'manual') returning id into k1;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);

  -- ---- 1. cancelar_cita sobre una cita sin fecha ----
  begin
    r := cancelar_cita(k1);
    select estado into v_estado from citas where id = k1;
    v_res := concat(v_res, case when (r ->> 'ok') = 'true' and v_estado = 'cancelada'
      then '1 ok: una cita "por programar" se cancela sin problema'
      else concat('1 FALLO: respuesta=', r, ' estado=', v_estado) end, E'\n');
  exception when others then
    v_res := concat(v_res, '1 FALLO: ', sqlerrm, E'\n');
  end;

  -- ---- 2. rechazar una cotización aceptada cuya cita no tiene fecha ----
  if v_cot is null then
    v_res := concat(v_res, '2 omitido: no hay cotizaciones', E'\n');
  else
    begin
      -- (como dueño no se puede: se hace como admin con lo que permite la política)
      insert into citas (cliente_id, tipo_servicio, fecha, estado, origen, cotizacion_id)
        values (v_cli, 'preventivo', null, 'por_programar', 'cotizacion', v_cot) returning id into k2;
      update citas set estado = 'cancelada' where id = k2;
      select estado into v_est2 from citas where id = k2;
      v_res := concat(v_res, case when v_est2 = 'cancelada'
        then '2 ok: una cita de cotización sin fecha también se puede cancelar'
        else concat('2 FALLO: estado=', v_est2) end, E'\n');
    exception when others then
      v_res := concat(v_res, '2 FALLO: ', sqlerrm, E'\n');
    end;
  end if;

  -- ---- 3. programada sin fecha sigue prohibida ----
  begin
    insert into citas (cliente_id, tipo_servicio, fecha, estado, origen)
      values (v_cli, 'preventivo', null, 'programada', 'manual');
    v_res := concat(v_res, '3 FALLO: dejó una cita programada sin fecha');
  exception when check_violation then
    v_res := concat(v_res, '3 ok: programada sin fecha sigue prohibida');
  end;

  perform set_config('app.res', v_res, true);
end $$;

select unnest(string_to_array(current_setting('app.res', true), E'\n')) as resultado;

rollback;
