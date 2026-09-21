-- Prueba de la 16 (correr DESPUÉS de la 16; el bloque COMPLETO). Termina en rollback: no deja nada.
--
-- Usa un cliente que ya tenga equipo, un admin y un técnico. Dentro de la transacción desactiva
-- los contactos que ya hubiera de ese cliente y crea los suyos (teléfonos inventados 999 000 010x).
-- Todos los pasos deben decir "ok":
--  1 confirmar una cita avisa a 2 personas del cliente (responsable y encargado; NO a administración,
--    que no pide citas) y a 1 técnico
--  2 el mensaje al cliente trae el horario; el del técnico trae dirección, referencias, mapa,
--    contacto con teléfono y su papel, y nada de precios
--  3 un cambio que no toca horario ni técnicos no duplica avisos
--  4 marcar enviado guarda el texto y repetirlo no hace nada
--  5 reprogramar: al técnico que ya recibió se le manda el cambio; al cliente, que aún no recibía,
--    le sigue esperando su confirmación (no se convierte en "reprogramación")
--  6 quitar al técnico: su aviso pasa a "ya no estás asignado"
--  7 cancelar la cita: al cliente, que nunca recibió nada, no se le avisa; queda solo el aviso al técnico
--  8 un técnico no lee la cola ni la tabla
--  9 una cita "por programar" no avisa; al programarla, sí; un técnico sin teléfono aparece sin número
-- 10 sin contactos, se usa el teléfono de la ficha del cliente (o queda un aviso sin número)
-- 11 un técnico recién asignado recibe una confirmación, no un "cambio"
begin;

select set_config('app.res', 'la prueba no llegó al final (revisa si hubo un error arriba)', true);

do $$
declare
  v_admin uuid; v_tec uuid; v_cli uuid; v_eq uuid;
  c1 uuid; c2 uuid; c3 uuid;
  k1 uuid; k2 uuid; k3 uuid;                       -- las tres citas de la prueba
  r jsonb; v_res text := ''; v_n int; v_n2 int; v_n3 int; v_txt text; v_tec_txt text; v_cli_txt text;
  v_aviso uuid; v_tipo text;
begin
  select id into v_admin from perfiles where rol = 'admin' and coalesce(activo, true) limit 1;
  select id into v_tec from perfiles where rol = 'tecnico' and coalesce(activo, true) limit 1;
  select cliente_id, id into v_cli, v_eq from equipos where cliente_id is not null limit 1;

  if v_admin is null or v_tec is null or v_cli is null then
    perform set_config('app.res', concat(
      'SIN DATOS: hace falta un admin, un técnico y un cliente con equipo. admin=', coalesce(v_admin::text, 'no'),
      ' tecnico=', coalesce(v_tec::text, 'no'), ' cliente_con_equipo=', coalesce(v_cli::text, 'no')), true);
    return;
  end if;

  -- ---- preparación (como dueño de la base; se deshace al final) ----
  update perfiles set telefono = '999 111 0001' where id = v_tec;
  update perfiles set telefono = null where id = v_admin;
  update clientes set direccion = 'Calle 10 #123', colonia = 'Centro', municipio = 'Mérida',
                      referencias = 'Portón azul', maps_url = 'https://maps.example/x'
   where id = v_cli;
  update contactos set activo = false where cliente_id = v_cli;
  insert into contactos (cliente_id, nombre, telefono, verificado) values (v_cli, 'Rosa Responsable', '999 000 0101', true) returning id into c1;
  insert into contactos (cliente_id, nombre, telefono, verificado, de_toda_la_empresa, puede_pedir_citas, recibe_ordenes)
    values (v_cli, 'Administración', '999 000 0102', true, true, false, true) returning id into c2;
  insert into contactos (cliente_id, nombre, telefono, verificado) values (v_cli, 'Enrique Encargado', '999 000 0103', true) returning id into c3;
  insert into equipo_contactos (equipo_id, contacto_id, rol, puede_pedir_citas, recibe_ordenes, recibe_cotizaciones)
    values (v_eq, c1, 'responsable', true, true, true), (v_eq, c3, 'encargado', true, true, false);

  -- ---- 1. confirmar una cita (el trigger arma la cola) ----
  insert into citas (cliente_id, equipo_id, tipo_servicio, fecha, hora, duracion_min, tecnico_id, estado, origen, notas)
    values (v_cli, v_eq, 'preventivo', current_date + 3, '09:00', 90, v_tec, 'programada', 'manual', 'Llegar con el encargado')
    returning id into k1;
  select count(*) filter (where destinatario = 'cliente'), count(*) filter (where destinatario = 'tecnico')
    into v_n, v_n2 from avisos where cita_id = k1 and estado = 'pendiente';
  v_res := concat(v_res, case when v_n = 2 and v_n2 = 1
    then '1 ok: la cita avisa a 2 del cliente (responsable y encargado, no administración) y a 1 técnico'
    else concat('1 FALLO: cliente=', v_n, ' técnico=', v_n2) end, E'\n');

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);

  -- ---- 2. los textos ----
  r := avisos_pendientes();
  select x ->> 'texto' into v_tec_txt from jsonb_array_elements(r -> 'pendientes') x
   where x ->> 'cita_id' = k1::text and x ->> 'destinatario' = 'tecnico';
  select x ->> 'texto' into v_cli_txt from jsonb_array_elements(r -> 'pendientes') x
   where x ->> 'cita_id' = k1::text and x ->> 'nombre' = 'Rosa Responsable';
  v_res := concat(v_res, case
    when v_cli_txt like '%Hola Rosa Responsable,%' and v_cli_txt like '%Le confirmamos su cita%'
     and v_cli_txt like '%09:00 h%' and v_cli_txt like '%Duración aproximada: 90 min%'
     and v_tec_txt like '%Nuevo servicio%' and v_tec_txt like '%Calle 10 #123%' and v_tec_txt like '%Portón azul%'
     and v_tec_txt like '%https://maps.example/x%' and v_tec_txt like '%Rosa Responsable%999 000 0101%'
     and v_tec_txt like '%Eres el responsable%' and v_tec_txt like '%09:00 h%'
     and v_tec_txt not like '%$%' and v_tec_txt !~* 'precio|costo'
    then '2 ok: al cliente le llega el horario; al técnico, dirección, referencias, mapa, contacto y su papel, sin precios'
    else concat('2 FALLO. Cliente: [', v_cli_txt, '] Técnico: [', v_tec_txt, ']') end, E'\n');

  -- ---- 3. un cambio que no toca horario ni técnicos no duplica ----
  update citas set notas = 'Llegar con el encargado (actualizado)' where id = k1;
  select count(*) into v_n from avisos where cita_id = k1 and estado = 'pendiente';
  v_res := concat(v_res, case when v_n = 3 then '3 ok: un cambio sin importancia no duplica avisos'
    else concat('3 FALLO: hay ', v_n, ' pendientes') end, E'\n');

  -- ---- 4. marcar enviado (al técnico) ----
  select id into v_aviso from avisos where cita_id = k1 and destinatario = 'tecnico';
  r := marcar_aviso(v_aviso, 'enviado');
  select estado, canal into v_txt, v_tipo from avisos where id = v_aviso;
  select (texto_enviado is not null and texto_enviado like '%Nuevo servicio%')::int into v_n from avisos where id = v_aviso;
  v_res := concat(v_res, case
    when v_txt = 'enviado' and v_tipo = 'whatsapp_manual' and v_n = 1
         and (marcar_aviso(v_aviso, 'enviado') ->> 'sin_cambio') = 'true'
    then '4 ok: marcar enviado guarda el texto y repetirlo no hace nada'
    else concat('4 FALLO: estado=', v_txt, ' canal=', v_tipo, ' texto=', v_n) end, E'\n');

  -- ---- 5. reprogramar ----
  update citas set fecha = current_date + 4 where id = k1;
  select tipo into v_tipo from avisos where cita_id = k1 and destinatario = 'tecnico' and estado = 'pendiente';
  select count(*) into v_n from avisos where cita_id = k1 and destinatario = 'cliente' and estado = 'pendiente' and tipo = 'confirmacion';
  select count(*) into v_n2 from avisos where cita_id = k1 and estado = 'pendiente';
  v_res := concat(v_res, case when v_tipo = 'reprogramacion' and v_n = 2 and v_n2 = 3
    then '5 ok: el técnico que ya recibió recibe el cambio; al cliente le sigue esperando su confirmación'
    else concat('5 FALLO: técnico=', v_tipo, ' clientes con confirmación=', v_n, ' pendientes=', v_n2) end, E'\n');

  -- ---- 6. quitar al técnico ----
  update citas set tecnico_id = null where id = k1;
  select tipo into v_tipo from avisos where cita_id = k1 and destinatario = 'tecnico' and estado = 'pendiente';
  select x ->> 'texto' into v_tec_txt from jsonb_array_elements(avisos_pendientes() -> 'pendientes') x
   where x ->> 'cita_id' = k1::text and x ->> 'destinatario' = 'tecnico';
  v_res := concat(v_res, case when v_tipo = 'cancelacion' and v_tec_txt like '%Ya no estás asignado%'
    then '6 ok: al técnico que se quitó le llega "ya no estás asignado"'
    else concat('6 FALLO: tipo=', v_tipo, ' texto=[', v_tec_txt, ']') end, E'\n');

  -- ---- 7. cancelar la cita ----
  update citas set estado = 'cancelada' where id = k1;
  select count(*) filter (where estado = 'pendiente'), count(*) filter (where estado = 'descartado' and destinatario = 'cliente')
    into v_n, v_n2 from avisos where cita_id = k1;
  v_res := concat(v_res, case when v_n = 1 and v_n2 = 2
    then '7 ok: al cliente, que nunca recibió nada, no se le avisa; queda solo el aviso al técnico'
    else concat('7 FALLO: pendientes=', v_n, ' descartados del cliente=', v_n2) end, E'\n');

  -- ---- 9. por programar → programada ----
  insert into citas (cliente_id, equipo_id, tipo_servicio, fecha, hora, duracion_min, tecnico_id, tecnico2_id, estado, origen)
    values (v_cli, v_eq, 'correctivo', null, null, 60, v_tec, v_admin, 'por_programar', 'manual')
    returning id into k2;
  select count(*) into v_n from avisos where cita_id = k2;
  update citas set estado = 'programada', fecha = current_date + 5, hora = '11:30' where id = k2;
  select count(*) into v_n2 from avisos where cita_id = k2 and destinatario = 'tecnico' and estado = 'pendiente';
  select count(*) into v_n3 from jsonb_array_elements(avisos_pendientes() -> 'pendientes') x
   where x ->> 'cita_id' = k2::text and (x ->> 'destinatario') = 'tecnico' and (x ->> 'telefono') is null;
  v_res := concat(v_res, case when v_n = 0 and v_n2 = 2 and v_n3 = 1
    then '9 ok: "por programar" no avisa; al programarla sí (2 técnicos; el que no tiene teléfono aparece sin número)'
    else concat('9 FALLO: antes=', v_n, ' técnicos=', v_n2, ' sin número=', v_n3) end, E'\n');

  -- ---- 10. sin contactos: teléfono de la ficha ----
  update contactos set activo = false where cliente_id = v_cli;
  insert into citas (cliente_id, equipo_id, tipo_servicio, fecha, hora, duracion_min, tecnico_id, estado, origen)
    values (v_cli, v_eq, 'preventivo', current_date + 6, '08:00', 60, v_tec, 'programada', 'manual')
    returning id into k3;
  select llave into v_txt from avisos where cita_id = k3 and destinatario = 'cliente';
  select count(*) into v_n from avisos where cita_id = k3 and destinatario = 'cliente';
  v_res := concat(v_res, case when v_n = 1 and (v_txt like 'f:%' or v_txt like 's:%')
    then concat('10 ok: sin contactos, se usa la ficha del cliente (', case when v_txt like 'f:%' then 'con su teléfono' else 'sin teléfono: aviso sin número' end, ')')
    else concat('10 FALLO: avisos al cliente=', v_n, ' llave=', v_txt) end, E'\n');

  -- ---- 11. técnico recién asignado ----
  update citas set tecnico2_id = v_admin where id = k3;
  select tipo into v_tipo from avisos where cita_id = k3 and destinatario = 'tecnico' and perfil_id = v_admin and estado = 'pendiente';
  v_res := concat(v_res, case when v_tipo = 'confirmacion'
    then '11 ok: un técnico recién asignado recibe una confirmación, no un "cambio"'
    else concat('11 FALLO: tipo=', v_tipo) end, E'\n');

  -- ---- 8. un técnico no lee la cola ni la tabla ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_tec, 'role', 'authenticated', 'email', 'tecnico@prueba')::text, true);
  select count(*) into v_n from avisos;
  v_txt := '';
  begin perform avisos_pendientes(); v_txt := 'leyó la cola'; exception when sqlstate '42501' then null; end;
  begin perform marcar_aviso(v_aviso, 'descartado'); v_txt := v_txt || ' marcó'; exception when sqlstate '42501' then null; end;
  v_res := concat(v_res, case when v_n = 0 and v_txt = '' then '8 ok: el técnico no lee la cola ni la tabla ni marca avisos'
    else concat('8 FALLO: lee ', v_n, ' filas; ', v_txt) end);

  perform set_config('app.res', v_res, true);
end $$;

select unnest(string_to_array(current_setting('app.res', true), E'\n')) as resultado;

rollback;
