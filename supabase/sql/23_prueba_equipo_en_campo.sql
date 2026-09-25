-- Prueba de la 23 (correr DESPUÉS de la 23; el bloque COMPLETO). Termina en rollback.
-- Crea su propio cliente, cita y orden; usa el admin y el técnico que ya existan.
--
-- Todos los pasos deben decir "ok":
--  1 un equipo se puede crear SIN serie (la placa ilegible no detiene el trabajo)
--  2 el técnico da de alta el equipo desde su orden, y queda ligado a la orden y a la cita
--  3 un técnico que NO es de esa orden es rechazado
--  4 una serie que el cliente ya tenía no duplica: reusa el equipo y le llena los huecos
--  5 ligar un equipo de OTRO cliente se rechaza
--  6 ligar un equipo del mismo cliente funciona, y repetirlo devuelve "sin_cambio"
--  7 al cerrar con horómetro, el equipo se entera (horas y fecha)
--  8 un horómetro que retrocede se guarda igual y deja rastro en auditoría
--  9 con la orden cerrada ya no se puede cambiar el equipo
-- 10 `equipos_sin_serie` lista el que quedó pendiente; el técnico no la puede leer
begin;

select set_config('app.res', 'la prueba no llegó al final (revisa si hubo un error arriba)', true);

do $$
declare
  v_admin uuid; v_tec uuid;
  v_cli uuid; v_cli2 uuid;
  v_cita uuid; v_orden uuid; v_orden2 uuid;
  v_eq_otro uuid; v_eq_medias uuid; v_eq uuid; v_eq2 uuid;
  r jsonb; v_res text := ''; v_txt text;
  v_n int; v_n2 int; v_horas numeric; v_fecha date; v_b boolean;
begin
  select id into v_admin from perfiles where rol = 'admin' and coalesce(activo, true) limit 1;
  select id into v_tec from perfiles where rol = 'tecnico' and coalesce(activo, true) limit 1;
  if v_admin is null or v_tec is null then
    perform set_config('app.res', concat('SIN DATOS: admin=', coalesce(v_admin::text, 'no'),
      ' tecnico=', coalesce(v_tec::text, 'no')), true);
    return;
  end if;

  -- ---- preparación, como dueño de la base ----
  insert into clientes (nombre, telefono) values ('Cliente 23 A', '999 000 0231') returning id into v_cli;
  insert into clientes (nombre, telefono) values ('Cliente 23 B', '999 000 0232') returning id into v_cli2;

  -- un equipo de OTRO cliente, para probar que no se puede robar
  insert into equipos (cliente_id, numero_serie, tipo) values (v_cli2, 'SER-23-AJENO', 'generador')
    returning id into v_eq_otro;
  -- un equipo del cliente dado de alta a medias desde la oficina (solo serie)
  insert into equipos (cliente_id, numero_serie, tipo) values (v_cli, 'SER-23-MEDIAS', 'generador')
    returning id into v_eq_medias;

  insert into citas (cliente_id, fecha, tipo_servicio, estado, tecnico_id)
  values (v_cli, (now() at time zone 'America/Mexico_City')::date, 'diagnostico', 'programada', v_tec)
  returning id into v_cita;

  insert into ordenes_servicio (cliente_id, cita_id, fecha, tipo_servicio, tecnico_id, estado)
  values (v_cli, v_cita, (now() at time zone 'America/Mexico_City')::date, 'diagnostico', v_tec, 'abierta')
  returning id into v_orden;

  -- `cerrar_orden` exige trabajo capturado: sin la parte del técnico no deja cerrar (paso 7).
  insert into orden_partes (orden_id, autor_id, notas)
  values (v_orden, v_tec, 'Se revisó el equipo y se midió el horómetro.');

  -- ---- 1. un equipo sin serie ----
  begin
    insert into equipos (cliente_id, numero_serie, tipo) values (v_cli, null, 'solar') returning id into v_eq2;
    v_res := concat(v_res, '1 ok: un equipo se puede crear sin serie', E'\n');
  exception when others then
    v_res := concat(v_res, '1 FALLO: ', sqlerrm, E'\n');
  end;
  delete from equipos where id = v_eq2;   -- se probó la restricción; el resto no lo necesita

  set local role authenticated;

  -- ---- 2. el técnico da de alta el equipo de su orden ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_tec, 'role', 'authenticated', 'email', 'tec@prueba')::text, true);
  r := registrar_equipo_en_orden(v_orden, jsonb_build_object(
        'tipo', 'generador', 'marca', 'Generac', 'modelo', 'SD022', 'capacidad_kw', 22,
        'combustible', 'diesel', 'ubicacion_equipo', 'azotea'));
  v_eq := (r ->> 'equipo_id')::uuid;
  select count(*) into v_n from ordenes_servicio where id = v_orden and equipo_id = v_eq;
  select count(*) into v_n2 from citas where id = v_cita and equipo_id = v_eq;
  v_res := concat(v_res, case when (r ->> 'ok') = 'true' and (r ->> 'sin_serie') = 'true'
                              and v_n = 1 and v_n2 = 1
    then '2 ok: el técnico dio de alta el equipo y quedó ligado a la orden y a la cita'
    else concat('2 FALLO: r=', r, ' orden=', v_n, ' cita=', v_n2) end, E'\n');

  -- ---- 3. un técnico que no es de la orden ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'otro@prueba')::text, true);
  -- el admin sí puede; para probar el rechazo se usa una orden ajena con un técnico ajeno:
  insert into ordenes_servicio (cliente_id, fecha, tipo_servicio, estado)
  values (v_cli2, (now() at time zone 'America/Mexico_City')::date, 'correctivo', 'abierta')
  returning id into v_orden2;
  perform set_config('request.jwt.claims', json_build_object('sub', v_tec, 'role', 'authenticated', 'email', 'tec@prueba')::text, true);
  v_txt := '';
  begin
    perform registrar_equipo_en_orden(v_orden2, jsonb_build_object('tipo', 'generador'));
    v_txt := 'lo dejó entrar';
  exception when sqlstate '42501' then null;
  end;
  v_res := concat(v_res, case when v_txt = ''
    then '3 ok: un técnico que no es de esa orden es rechazado'
    else concat('3 FALLO: ', v_txt) end, E'\n');

  -- ---- 4. la serie que ya existía no duplica ----
  r := registrar_equipo_en_orden(v_orden, jsonb_build_object(
        'numero_serie', 'SER-23-MEDIAS', 'marca', 'Cummins', 'capacidad_kw', 40));
  select count(*) into v_n from equipos where cliente_id = v_cli and numero_serie = 'SER-23-MEDIAS';
  select marca into v_txt from equipos where id = v_eq_medias;
  v_res := concat(v_res, case when (r ->> 'reusado') = 'true' and (r ->> 'equipo_id')::uuid = v_eq_medias
                              and v_n = 1 and v_txt = 'Cummins'
    then '4 ok: la serie repetida reusa el equipo y le llena los huecos'
    else concat('4 FALLO: r=', r, ' equipos=', v_n, ' marca=', coalesce(v_txt, 'sin marca')) end, E'\n');

  -- ---- 5. un equipo de otro cliente ----
  v_txt := '';
  begin
    perform equipo_de_orden(v_orden, v_eq_otro);
    v_txt := 'ligó un equipo ajeno';
  exception when sqlstate '42501' then null;
  end;
  v_res := concat(v_res, case when v_txt = ''
    then '5 ok: un equipo de otro cliente no se puede ligar'
    else concat('5 FALLO: ', v_txt) end, E'\n');

  -- ---- 6. ligar el equipo bueno, y repetir ----
  r := equipo_de_orden(v_orden, v_eq);
  v_txt := (equipo_de_orden(v_orden, v_eq)) ->> 'sin_cambio';
  select count(*) into v_n from ordenes_servicio where id = v_orden and equipo_id = v_eq;
  v_res := concat(v_res, case when (r ->> 'ok') = 'true' and v_txt = 'true' and v_n = 1
    then '6 ok: ligar funciona y repetirlo devuelve sin_cambio'
    else concat('6 FALLO: r=', r, ' repetido=', coalesce(v_txt, 'null'), ' orden=', v_n) end, E'\n');

  -- ---- 7. el horómetro sube al equipo al cerrar ----
  -- Los nulos van tipados: sin el cast, Postgres no sabe a qué parámetro corresponde cada uno.
  r := cerrar_orden(v_orden, null::text, true, 1200::numeric, 'todo bien', null::text,
                    false, null::date, null::jsonb, null::jsonb);
  select horas_uso, horas_uso_fecha into v_horas, v_fecha from equipos where id = v_eq;
  v_res := concat(v_res, case when (r ->> 'ok') = 'true' and v_horas = 1200 and v_fecha is not null
    then '7 ok: al cerrar, el horómetro y su fecha quedaron en el equipo'
    else concat('7 FALLO: r=', r, ' horas=', coalesce(v_horas::text, 'null'),
                ' fecha=', coalesce(v_fecha::text, 'null')) end, E'\n');

  -- ---- 8. un horómetro que retrocede ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);
  update ordenes_servicio set horas_equipo = 50 where id = v_orden;
  select horas_uso into v_horas from equipos where id = v_eq;
  select count(*) > 0 into v_b from auditoria
   where tabla = 'equipos' and registro_id = v_eq and accion = 'horometro'
     and (valor_nuevo ->> 'retrocede') = 'true';
  v_res := concat(v_res, case when v_horas = 50 and v_b
    then '8 ok: un horómetro que retrocede se guarda y deja rastro en auditoría'
    else concat('8 FALLO: horas=', coalesce(v_horas::text, 'null'), ' rastro=', v_b) end, E'\n');

  -- ---- 9. orden cerrada, no se cambia el equipo ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_tec, 'role', 'authenticated', 'email', 'tec@prueba')::text, true);
  v_txt := '';
  begin
    perform equipo_de_orden(v_orden, v_eq_medias);
    v_txt := 'lo cambió con la orden cerrada';
  exception when sqlstate '22023' then null;
  end;
  v_res := concat(v_res, case when v_txt = ''
    then '9 ok: con la orden cerrada ya no se cambia el equipo'
    else concat('9 FALLO: ', v_txt) end, E'\n');

  -- ---- 10. la lista de series pendientes ----
  select count(*) into v_n from equipos_sin_serie();   -- como técnico: no debe ver nada
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);
  select count(*) into v_n2 from equipos_sin_serie() where equipo_id = v_eq;
  v_res := concat(v_res, case when v_n = 0 and v_n2 = 1
    then '10 ok: el admin ve el equipo sin serie y el técnico no ve la lista'
    else concat('10 FALLO: tecnico ve ', v_n, ', admin encuentra ', v_n2) end);

  perform set_config('app.res', v_res, true);
end $$;

reset role;
select current_setting('app.res', true) as resultado;

rollback;
