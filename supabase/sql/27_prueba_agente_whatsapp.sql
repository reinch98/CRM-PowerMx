-- Prueba de la 27 (correr DESPUÉS de la 27; el bloque COMPLETO). Termina en rollback.
--
-- Todos los pasos deben decir "ok":
--  1 un número SIN ligar no recibe ningún dato
--  2 un número ligado recibe su cliente y sus equipos
--  3 con VARIOS equipos no se reparten números de serie
--  4 con UN equipo sí se incluye la serie, para confirmar de cuál se habla
--  5 el agente pide una cita: nace por_programar, sin fecha, origen whatsapp, con su orden
--  6 pedir otra vez lo mismo no apila citas
--  7 un equipo de OTRO cliente se rechaza aunque el id venga bien escrito
--  8 un tipo de servicio inventado se rechaza
--  9 el tope diario cuenta los mensajes salientes de hoy
-- 10 un técnico no puede usar ninguna de estas funciones
begin;

select set_config('app.res', 'la prueba no llegó al final (revisa si hubo un error arriba)', true);

do $$
declare
  v_admin uuid; v_tec uuid;
  v_cli uuid; v_cli2 uuid;
  c_uno uuid; c_dos uuid;
  v_eq1 uuid; v_eq2 uuid; v_eq_ajeno uuid;
  v_conv_sin uuid; v_conv_uno uuid; v_conv_dos uuid;
  r jsonb; v_res text := ''; v_txt text;
  v_n int; v_n2 int; v_b boolean;
begin
  select id into v_admin from perfiles where rol = 'admin' and coalesce(activo, true) limit 1;
  select id into v_tec from perfiles where rol = 'tecnico' and coalesce(activo, true) limit 1;
  if v_admin is null or v_tec is null then
    perform set_config('app.res', concat('SIN DATOS: admin=', coalesce(v_admin::text, 'no'),
      ' tecnico=', coalesce(v_tec::text, 'no')), true);
    return;
  end if;

  -- El agente tiene que estar encendido para el paso 9.
  update wa_agente set activo = true, tope_dia = 3 where id;

  insert into clientes (nombre, telefono) values ('Cliente 27 A', '999 000 0271') returning id into v_cli;
  insert into clientes (nombre, telefono) values ('Cliente 27 B', '999 000 0272') returning id into v_cli2;

  -- "Uno" tiene DOS equipos; "Dos" tiene uno solo.
  insert into equipos (cliente_id, numero_serie, tipo, marca, capacidad_kw)
  values (v_cli, 'SER-27-A', 'generador', 'Generac', 22) returning id into v_eq1;
  insert into equipos (cliente_id, numero_serie, tipo, marca, capacidad_kw)
  values (v_cli, 'SER-27-B', 'solar', 'Huawei', 10) returning id into v_eq2;
  insert into equipos (cliente_id, numero_serie, tipo, marca)
  values (v_cli2, 'SER-27-C', 'generador', 'Cummins') returning id into v_eq_ajeno;

  insert into contactos (cliente_id, nombre, telefono, verificado)
  values (v_cli, 'Rosa', '999 000 0281', true) returning id into c_uno;
  insert into contactos (cliente_id, nombre, telefono, verificado)
  values (v_cli2, 'Pedro', '999 000 0282', true) returning id into c_dos;

  insert into conversaciones (telefono) values ('999 000 0299') returning id into v_conv_sin;
  insert into conversaciones (telefono, contacto_id, cliente_id)
  values ('999 000 0281', c_uno, v_cli) returning id into v_conv_uno;
  insert into conversaciones (telefono, contacto_id, cliente_id)
  values ('999 000 0282', c_dos, v_cli2) returning id into v_conv_dos;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);

  -- ---- 1. número sin ligar ----
  r := wa_contexto(v_conv_sin);
  v_res := concat(v_res, case when (r ->> 'conocido') = 'false' and r ->> 'cliente' is null
                              and r ->> 'equipos' is null
    then '1 ok: un número sin ligar no recibe ningún dato'
    else concat('1 FALLO: ', r) end, E'\n');

  -- ---- 2. número ligado ----
  r := wa_contexto(v_conv_uno);
  v_res := concat(v_res, case when (r ->> 'conocido') = 'true' and (r ->> 'cliente') = 'Cliente 27 A'
                              and (r ->> 'contacto') = 'Rosa'
                              and jsonb_array_length(r -> 'equipos') = 2
    then '2 ok: un número ligado recibe su cliente y sus equipos'
    else concat('2 FALLO: ', r) end, E'\n');

  -- ---- 3. varios equipos, sin series ----
  select bool_or(x ? 'numero_serie') into v_b from jsonb_array_elements(r -> 'equipos') x;
  v_res := concat(v_res, case when not coalesce(v_b, false)
    then '3 ok: con varios equipos no se reparten números de serie'
    else '3 FALLO: se filtró una serie' end, E'\n');

  -- ---- 4. un solo equipo, con serie ----
  r := wa_contexto(v_conv_dos);
  select (x ->> 'numero_serie') into v_txt from jsonb_array_elements(r -> 'equipos') x limit 1;
  v_res := concat(v_res, case when v_txt = 'SER-27-C'
    then '4 ok: con un solo equipo sí se incluye la serie'
    else concat('4 FALLO: serie=', coalesce(v_txt, 'null')) end, E'\n');

  -- ---- 5. pedir cita ----
  r := wa_solicitar_cita(v_conv_uno, v_eq1, 'correctivo', 'No arranca desde ayer.');
  select count(*) into v_n from citas
   where id = (r ->> 'cita_id')::uuid and estado = 'por_programar'
     and fecha is null and origen = 'whatsapp' and cliente_id = v_cli;
  select count(*) into v_n2 from ordenes_servicio where id = (r ->> 'orden_id')::uuid;
  v_res := concat(v_res, case when (r ->> 'ok') = 'true' and v_n = 1 and v_n2 = 1
    then '5 ok: la cita nace por_programar, sin fecha, origen whatsapp, con su orden'
    else concat('5 FALLO: r=', r, ' cita=', v_n) end, E'\n');

  -- ---- 6. no apilar ----
  r := wa_solicitar_cita(v_conv_uno, v_eq1, 'correctivo', 'Insisto.');
  select count(*) into v_n from citas
   where cliente_id = v_cli and equipo_id = v_eq1 and estado = 'por_programar';
  v_res := concat(v_res, case when (r ->> 'repetida') = 'true' and v_n = 1
    then '6 ok: pedir lo mismo otra vez no apila citas'
    else concat('6 FALLO: r=', r, ' citas=', v_n) end, E'\n');

  -- ---- 7. equipo ajeno ----
  v_txt := '';
  begin
    perform wa_solicitar_cita(v_conv_uno, v_eq_ajeno, 'correctivo', null);
    v_txt := 'aceptó un equipo de otro cliente';
  exception when sqlstate '42501' then null;
  end;
  v_res := concat(v_res, case when v_txt = ''
    then '7 ok: un equipo de otro cliente se rechaza'
    else concat('7 FALLO: ', v_txt) end, E'\n');

  -- ---- 8. tipo inventado ----
  v_txt := '';
  begin
    perform wa_solicitar_cita(v_conv_uno, null, 'exorcismo', null);
    v_txt := 'aceptó el tipo';
  exception when sqlstate '22023' then null;
  end;
  v_res := concat(v_res, case when v_txt = ''
    then '8 ok: un tipo de servicio inventado se rechaza'
    else concat('8 FALLO: ', v_txt) end, E'\n');

  -- ---- 9. el tope del día ----
  r := wa_puede_responder(v_conv_uno);
  insert into mensajes_wa (conversacion_id, direccion, texto, wa_message_id)
  values (v_conv_uno, 'saliente', 'uno', 'wa.27.1'),
         (v_conv_uno, 'saliente', 'dos', 'wa.27.2'),
         (v_conv_uno, 'saliente', 'tres', 'wa.27.3');
  v_res := concat(v_res, case when (r ->> 'puede') = 'true' and (r ->> 'enviados_hoy') = '0'
                              and (wa_puede_responder(v_conv_uno) ->> 'puede') = 'false'
    then '9 ok: el tope diario cuenta los salientes de hoy y frena al llegar'
    else concat('9 FALLO: antes=', r, ' despues=', wa_puede_responder(v_conv_uno)) end, E'\n');

  -- ---- 10. un técnico ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_tec, 'role', 'authenticated', 'email', 'tec@prueba')::text, true);
  v_txt := '';
  begin perform wa_contexto(v_conv_uno); v_txt := 'leyó el contexto '; exception when sqlstate '42501' then null; end;
  begin perform wa_solicitar_cita(v_conv_uno, null, 'correctivo', null); v_txt := v_txt || 'pidió cita';
  exception when sqlstate '42501' then null; end;
  v_res := concat(v_res, case when v_txt = ''
    then '10 ok: un técnico no usa ninguna de estas funciones'
    else concat('10 FALLO: ', v_txt) end);

  perform set_config('app.res', v_res, true);
end $$;

reset role;
select current_setting('app.res', true) as resultado;

rollback;
