-- Prueba de la 22 (correr DESPUÉS de la 22; el bloque COMPLETO). Termina en rollback: no deja nada.
-- Usa un admin, un técnico y un cliente. Dentro de la transacción crea contactos con teléfonos
-- inventados (999 000 02xx). Si falta algún dato, lo dice y no hace nada.
--
-- Todos los pasos deben decir "ok":
--  1 un mensaje de un número CONOCIDO abre la conversación ya ligada al contacto y su cliente
--  2 el mismo mensaje otra vez no se duplica (el webhook reintenta) y avisa "repetido"
--  3 otro mensaje del mismo número reusa la conversación y suma sin leer
--  4 el mensaje entrante abre la ventana de 24 horas
--  5 un número DESCONOCIDO abre conversación sin contacto, y vincular_conversacion lo liga
--  6 un número que está en DOS clientes no se liga solo: lo decide una persona
--  7 un mensaje saliente se guarda sin tocar los sin leer, y marcar leída los pone en cero
--  8 un teléfono sin 10 dígitos se rechaza
--  9 la bandeja trae contacto, cliente y si la ventana sigue abierta
-- 10 un técnico no ve la bandeja ni puede registrar mensajes
begin;

select set_config('app.res', 'la prueba no llegó al final (revisa si hubo un error arriba)', true);

do $$
declare
  v_admin uuid; v_tec uuid; v_cli uuid; v_cli2 uuid;
  c_conocido uuid; c_ambiguo1 uuid; c_ambiguo2 uuid; c_suelto uuid;
  v_conv uuid; v_conv2 uuid;
  r jsonb; v_res text := ''; v_txt text;
  v_n int; v_n2 int; v_n3 int; v_b boolean; v_b2 boolean;
begin
  select id into v_admin from perfiles where rol = 'admin' and coalesce(activo, true) limit 1;
  select id into v_tec from perfiles where rol = 'tecnico' and coalesce(activo, true) limit 1;
  select id into v_cli from clientes limit 1;

  if v_admin is null or v_tec is null or v_cli is null then
    perform set_config('app.res', concat(
      'SIN DATOS: hace falta un admin, un técnico y un cliente. admin=', coalesce(v_admin::text, 'no'),
      ' tecnico=', coalesce(v_tec::text, 'no'), ' cliente=', coalesce(v_cli::text, 'no')), true);
    return;
  end if;

  -- ---- preparación (como dueño de la base; se deshace al final) ----
  select id into v_cli2 from clientes where id <> v_cli limit 1;
  if v_cli2 is null then
    insert into clientes (nombre, telefono) values ('Cliente de prueba 22', '999 000 0299') returning id into v_cli2;
  end if;
  -- Por si alguno de los números inventados existiera de verdad, se apaga durante la prueba.
  update contactos set activo = false where telefono_norm in ('9990000201', '9990000202', '9990000203', '9990000250');
  insert into contactos (cliente_id, nombre, telefono, verificado) values (v_cli, 'Rosa Conocida', '999 000 0201', true) returning id into c_conocido;
  insert into contactos (cliente_id, nombre, telefono, verificado) values (v_cli, 'Ambiguo A', '999 000 0202', true) returning id into c_ambiguo1;
  insert into contactos (cliente_id, nombre, telefono, verificado) values (v_cli2, 'Ambiguo B', '999 000 0202', true) returning id into c_ambiguo2;
  insert into contactos (cliente_id, nombre, telefono, verificado) values (v_cli, 'Pedro Suelto', '999 000 0203', true) returning id into c_suelto;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);

  -- ---- 1. número conocido ----
  r := registrar_mensaje_entrante('+52 1 999 000 0201', 'wamid.001', 'Hola, necesito servicio', 'Rosa');
  select id, contacto_id = c_conocido and cliente_id = v_cli into v_conv, v_b
    from conversaciones where telefono_norm = '9990000201';
  v_res := concat(v_res, case when (r ->> 'conocido') = 'true' and v_b
    then '1 ok: un número conocido abre la conversación ya ligada al contacto y su cliente'
    else concat('1 FALLO: respuesta=', r, ' ligada=', v_b) end, E'\n');

  -- ---- 2. el mismo mensaje otra vez ----
  r := registrar_mensaje_entrante('+52 1 999 000 0201', 'wamid.001', 'Hola, necesito servicio', 'Rosa');
  select count(*) into v_n from mensajes_wa where wa_message_id = 'wamid.001';
  v_res := concat(v_res, case when (r ->> 'repetido') = 'true' and v_n = 1
    then '2 ok: el mismo mensaje no se duplica y avisa "repetido"'
    else concat('2 FALLO: respuesta=', r, ' mensajes=', v_n) end, E'\n');

  -- ---- 3. otro mensaje del mismo número ----
  r := registrar_mensaje_entrante('9990000201', 'wamid.002', '¿Cuándo pueden venir?');
  select sin_leer into v_n from conversaciones where id = v_conv;
  select count(*) into v_n2 from mensajes_wa where conversacion_id = v_conv;
  v_res := concat(v_res, case when v_n = 2 and v_n2 = 2
    then '3 ok: otro mensaje reusa la conversación y suma sin leer'
    else concat('3 FALLO: sin_leer=', v_n, ' mensajes=', v_n2) end, E'\n');

  -- ---- 4. ventana de 24 horas ----
  select ventana_hasta > now() + interval '23 hours' into v_b from conversaciones where id = v_conv;
  v_res := concat(v_res, case when v_b then '4 ok: el mensaje entrante abre la ventana de 24 horas'
    else '4 FALLO: la ventana no quedó abierta' end, E'\n');

  -- ---- 5. número desconocido y su vinculación ----
  r := registrar_mensaje_entrante('999 000 0250', 'wamid.003', 'Buenas, me pasaron su número', 'Quien sea');
  select id, contacto_id is null into v_conv2, v_b from conversaciones where telefono_norm = '9990000250';
  perform vincular_conversacion(v_conv2, c_suelto);
  select contacto_id = c_suelto and cliente_id = v_cli into v_b2 from conversaciones where id = v_conv2;
  v_res := concat(v_res, case when v_b and v_b2
    then '5 ok: un número desconocido abre sin contacto y se puede ligar a mano'
    else concat('5 FALLO: nacio_sin_contacto=', v_b, ' quedo_ligada=', v_b2) end, E'\n');

  -- ---- 6. número en dos clientes: no se liga solo ----
  r := registrar_mensaje_entrante('999 000 0202', 'wamid.004', 'Hola');
  select contacto_id is null into v_b from conversaciones where telefono_norm = '9990000202';
  v_res := concat(v_res, case when v_b
    then '6 ok: un número que está en dos clientes no se liga solo'
    else '6 FALLO: se ligó solo aunque había dos candidatos' end, E'\n');

  -- ---- 7. mensaje saliente y marcar leída ----
  perform registrar_mensaje_saliente(v_conv, 'Claro, le agendamos el jueves.');
  select sin_leer into v_n from conversaciones where id = v_conv;
  perform marcar_conversacion_leida(v_conv);
  select sin_leer into v_n2 from conversaciones where id = v_conv;
  select count(*) into v_n3 from mensajes_wa where conversacion_id = v_conv and direccion = 'saliente';
  v_res := concat(v_res, case when v_n = 2 and v_n2 = 0 and v_n3 = 1
    then '7 ok: el saliente se guarda sin tocar los sin leer, y marcar leída los pone en cero'
    else concat('7 FALLO: sin_leer antes=', v_n, ' después=', v_n2, ' salientes=', v_n3) end, E'\n');

  -- ---- 8. teléfono inválido ----
  v_txt := '';
  begin
    perform registrar_mensaje_entrante('12345', 'wamid.005', 'Hola');
    v_txt := 'aceptó un teléfono corto';
  exception when sqlstate '22023' then null; end;
  v_res := concat(v_res, case when v_txt = '' then '8 ok: un teléfono sin 10 dígitos se rechaza'
    else concat('8 FALLO: ', v_txt) end, E'\n');

  -- ---- 9. la bandeja con su contexto ----
  select bool_and(coalesce((x ->> k) is not null, false)) into v_b
    from jsonb_array_elements(bandeja_whatsapp()) x,
         unnest(array['telefono', 'contacto', 'cliente', 'ventana_abierta', 'ultimo_texto']) k
   where (x ->> 'id')::uuid = v_conv;
  v_res := concat(v_res, case when v_b
    then '9 ok: la bandeja trae contacto, cliente, ventana y último mensaje'
    else '9 FALLO: falta contexto en la bandeja' end, E'\n');

  -- ---- 10. el técnico no ve nada ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_tec, 'role', 'authenticated', 'email', 'tec@prueba')::text, true);
  select count(*) into v_n from conversaciones;
  select count(*) into v_n2 from mensajes_wa;
  v_txt := '';
  begin perform bandeja_whatsapp(); v_txt := 'leyó la bandeja '; exception when sqlstate '42501' then null; end;
  begin perform registrar_mensaje_entrante('9990000201', 'wamid.006', 'x'); v_txt := v_txt || 'registró un mensaje'; exception when sqlstate '42501' then null; end;
  v_res := concat(v_res, case when v_n = 0 and v_n2 = 0 and v_txt = ''
    then '10 ok: un técnico no ve la bandeja ni puede registrar mensajes'
    else concat('10 FALLO: ve ', v_n, ' conversaciones y ', v_n2, ' mensajes; ', v_txt) end);

  perform set_config('app.res', v_res, true);
end $$;

select unnest(string_to_array(current_setting('app.res', true), E'\n')) as resultado;

rollback;
