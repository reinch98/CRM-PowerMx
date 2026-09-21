-- Prueba de la 15 (correr DESPUÉS de la 15; el bloque COMPLETO). Termina en rollback: no deja nada.
--
-- Usa un cliente que ya tenga un equipo (y, si existe, otro cliente distinto) y un admin y
-- un técnico. Los teléfonos de la prueba son inventados (999 000 0001…). Si falta algún
-- dato, lo dice y no hace nada. Todos los pasos deben decir "ok":
--  1 normalizar teléfonos (+52 1…, 52…, con guiones, y uno corto da nulo)
--  2 no se repite el mismo número dentro de un cliente
--  3 vincular: el primero queda responsable con todos los permisos
--  4 un segundo responsable directo se rechaza (índice único)
--  5 vincular como responsable a otra persona baja al anterior a encargado
--  6 una persona de otro cliente no se puede ligar a este equipo
--  7 un contacto "de toda la empresa" aparece en la vista aunque no esté ligado
--  8 identificar_telefono reconoce el número en cualquier formato y trae equipo y serie
--  9 el mismo número en dos clientes devuelve los dos
-- 10 un técnico no lee contactos ni puede identificar ni vincular
-- 11 un número desconocido o inválido devuelve lista vacía
begin;

select set_config('app.res', 'la prueba no llegó al final (revisa si hubo un error arriba)', true);

do $$
declare
  v_admin uuid; v_tec uuid; v_cli uuid; v_eq uuid; v_cli2 uuid; v_eq_serie text;
  c1 uuid; c2 uuid; c3 uuid; c4 uuid; c_otro uuid;
  r jsonb; v_res text := ''; v_n int; v_txt text; v_rol text;
begin
  select id into v_admin from perfiles where rol = 'admin' and coalesce(activo, true) limit 1;
  select id into v_tec from perfiles where rol = 'tecnico' and coalesce(activo, true) limit 1;
  select cliente_id, id, numero_serie into v_cli, v_eq, v_eq_serie
    from equipos where cliente_id is not null limit 1;
  select id into v_cli2 from clientes where id <> v_cli limit 1;

  if v_admin is null or v_tec is null or v_cli is null then
    perform set_config('app.res', concat(
      'SIN DATOS: hace falta un admin, un técnico y un cliente con equipo. ',
      'admin=', coalesce(v_admin::text, 'no'), ' tecnico=', coalesce(v_tec::text, 'no'),
      ' cliente_con_equipo=', coalesce(v_cli::text, 'no')), true);
    return;
  end if;

  -- Si solo hay un cliente, se crea otro DENTRO de la prueba (se deshace con el rollback).
  if v_cli2 is null then
    begin
      insert into clientes (nombre, telefono) values ('Cliente de prueba 15', '999 000 0009') returning id into v_cli2;
    exception when others then
      v_cli2 := null;
      v_txt := sqlerrm;
    end;
    if v_cli2 is null then
      v_res := concat(v_res, 'AVISO: no se pudo crear un segundo cliente (', v_txt, '); se omiten los pasos 6 y 9', E'\n');
    end if;
  end if;

  -- ---- 1. normalización (sin permisos especiales: es una función pura) ----
  v_res := concat(v_res, case
    when normalizar_telefono('+52 1 999 000 0001') = '9990000001'
     and normalizar_telefono('52 (999) 000-0001') = '9990000001'
     and normalizar_telefono('9990000001') = '9990000001'
     and normalizar_telefono('12345') is null
     and normalizar_telefono(null) is null
    then '1 ok: normalizar quita el 52/521, signos y espacios; lo corto da nulo'
    else concat('1 FALLO: ', normalizar_telefono('+52 1 999 000 0001'), ' / ', normalizar_telefono('52 (999) 000-0001'),
                ' / ', coalesce(normalizar_telefono('12345'), 'nulo')) end, E'\n');

  -- ---- preparación (como dueño de la base) ----
  insert into contactos (cliente_id, nombre, telefono, verificado) values (v_cli, 'Persona Uno', '999 000 0001', true) returning id into c1;
  insert into contactos (cliente_id, nombre, telefono, verificado) values (v_cli, 'Persona Dos', '999 000 0002', true) returning id into c2;
  insert into contactos (cliente_id, nombre, telefono, verificado, de_toda_la_empresa,
                         puede_pedir_citas, recibe_ordenes, recibe_cotizaciones)
    values (v_cli, 'Administración', '999 000 0003', true, true, false, true, true) returning id into c3;
  if v_cli2 is not null then
    insert into contactos (cliente_id, nombre, telefono, verificado) values (v_cli2, 'Persona de otro cliente', '999 000 0001', true) returning id into c_otro;
  end if;

  -- ---- 2. el mismo número no se repite dentro de un cliente ----
  begin
    insert into contactos (cliente_id, nombre, telefono) values (v_cli, 'Repetida', '+52 1 999 000 0001');
    v_res := concat(v_res, '2 FALLO: dejó repetir el número en el mismo cliente', E'\n');
  exception when unique_violation then
    v_res := concat(v_res, '2 ok: el mismo número no se repite dentro de un cliente', E'\n');
  end;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);

  -- ---- 3. vincular: el primero es responsable con todos los permisos ----
  r := vincular_contacto(v_eq, c1, 'responsable');
  -- concat() escribe los booleanos como t / f, no true / false.
  select concat(rol, ':', puede_pedir_citas, ':', recibe_ordenes, ':', recibe_cotizaciones) into v_txt
    from equipo_contactos where equipo_id = v_eq and contacto_id = c1;
  v_res := concat(v_res, case when v_txt = 'responsable:t:t:t'
    then '3 ok: el responsable queda con pedir citas, órdenes y cotizaciones'
    else concat('3 FALLO: ', v_txt) end, E'\n');

  -- ---- 4. un segundo responsable directo se rechaza ----
  begin
    insert into equipo_contactos (equipo_id, contacto_id, rol) values (v_eq, c2, 'responsable');
    v_res := concat(v_res, '4 FALLO: dejó dos responsables en el mismo equipo', E'\n');
  exception when unique_violation then
    v_res := concat(v_res, '4 ok: un equipo no puede tener dos responsables', E'\n');
  end;

  -- ---- 5. vincular como responsable baja al anterior a encargado ----
  r := vincular_contacto(v_eq, c2, 'responsable');
  select rol into v_rol from equipo_contactos where equipo_id = v_eq and contacto_id = c1;
  select count(*) into v_n from equipo_contactos where equipo_id = v_eq and rol = 'responsable';
  v_res := concat(v_res, case when v_rol = 'encargado' and v_n = 1 and (r ->> 'responsable_anterior_bajado') = 'true'
    then '5 ok: el nuevo responsable baja al anterior a encargado (sigue con sus permisos)'
    else concat('5 FALLO: el anterior quedó como ', v_rol, ', responsables=', v_n) end, E'\n');

  -- ---- 6. una persona de otro cliente no se liga a este equipo ----
  if c_otro is null then
    v_res := concat(v_res, '6 omitido: no hay un segundo cliente', E'\n');
  else
    begin
      perform vincular_contacto(v_eq, c_otro, 'encargado');
      v_res := concat(v_res, '6 FALLO: ligó a una persona de otro cliente', E'\n');
    exception when sqlstate '22023' then
      v_res := concat(v_res, '6 ok: la persona y el equipo deben ser del mismo cliente', E'\n');
    end;
  end if;

  -- ---- 7. el contacto de toda la empresa aparece en la vista sin estar ligado ----
  select count(*) into v_n from contactos_por_equipo where equipo_id = v_eq and contacto_id = c3 and origen = 'empresa';
  v_res := concat(v_res, case when v_n = 1 then '7 ok: administración (de toda la empresa) aparece en el equipo sin ligarla'
    else concat('7 FALLO: aparece ', v_n, ' veces') end, E'\n');

  -- ---- 8. identificar un número en cualquier formato ----
  r := identificar_telefono('+52 1 (999) 000-0002');
  select (r -> 0 ->> 'nombre') || '|' || coalesce(r -> 0 -> 'equipos' -> 0 ->> 'numero_serie', 'sin serie') || '|' ||
         coalesce(r -> 0 -> 'equipos' -> 0 ->> 'rol', '?')
    into v_txt;
  v_res := concat(v_res, case when v_txt like 'Persona Dos|%' and v_txt like concat('%|', coalesce(v_eq_serie, 'sin serie'), '|%')
    then concat('8 ok: reconoce el número y trae el equipo con su serie (', v_txt, ')')
    else concat('8 FALLO: ', v_txt) end, E'\n');

  -- ---- 9. el mismo número en dos clientes devuelve los dos ----
  r := identificar_telefono('9990000001');
  select jsonb_array_length(r) into v_n;
  v_res := concat(v_res, case
    when c_otro is null then concat('9 omitido: no hay un segundo cliente (devolvió ', v_n, ' persona)')
    when v_n = 2 then '9 ok: un número en dos clientes devuelve las dos personas'
    else concat('9 FALLO: devolvió ', v_n) end, E'\n');

  -- ---- 11. desconocido o inválido ----
  v_res := concat(v_res, case
    when jsonb_array_length(identificar_telefono('9991119999')) = 0 and jsonb_array_length(identificar_telefono('123')) = 0
    then '11 ok: un número desconocido o inválido devuelve lista vacía'
    else '11 FALLO: devolvió algo' end, E'\n');

  -- ---- 10. un técnico no ve ni hace nada de esto ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_tec, 'role', 'authenticated', 'email', 'tecnico@prueba')::text, true);
  select (select count(*) from contactos) + (select count(*) from equipo_contactos)
       + (select count(*) from contactos_por_equipo) into v_n;
  v_txt := '';
  begin perform identificar_telefono('9990000001'); v_txt := v_txt || 'identificó '; exception when sqlstate '42501' then null; end;
  begin perform vincular_contacto(v_eq, c1, 'encargado'); v_txt := v_txt || 'vinculó '; exception when sqlstate '42501' then null; end;
  v_res := concat(v_res, case when v_n = 0 and v_txt = ''
    then '10 ok: el técnico no lee contactos ni puede identificar ni vincular'
    else concat('10 FALLO: lee ', v_n, ' filas; ', v_txt) end);

  perform set_config('app.res', v_res, true);
end $$;

select unnest(string_to_array(current_setting('app.res', true), E'\n')) as resultado;

rollback;
