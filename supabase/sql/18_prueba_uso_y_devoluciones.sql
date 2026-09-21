-- Prueba de la 18 (correr DESPUÉS de la 18; el bloque COMPLETO). Termina en rollback: no deja nada.
--
-- Igual que la de la 14: usa un admin, un técnico (T1), un tercer perfil (al que le pone rol
-- `almacenista` solo durante la prueba), un producto activo (le mete 10 piezas) y una cotización
-- cualquiera (la deja en borrador, con 4 piezas de ese producto). Si falta algo, lo dice y no hace nada.
--
-- Flujo: el almacén entrega 3 piezas a T1 (firma) → T1 cierra la orden declarando 1 usada →
-- quedan 2 por devolver → el almacén recibe 1 → el admin da por consumida la que nunca volvió.
-- Todos los pasos deben decir "ok":
--  1 declarar más usadas de las recibidas se rechaza y la orden sigue abierta
--  2 declarar una pieza que no está en el material se rechaza
--  3 cerrar con 1 usada: custodia 3→2, físico igual, orden cerrada, cita realizada
--  4 cerrar otra vez no repite nada (custodia igual)
--  5 el almacén ve la devolución pendiente (2), con T1 y 0 días
--  6 recibir más de lo pendiente se rechaza; recibir menos sin observación se rechaza
--  7 recibir 1 con observación: físico +1, custodia 1, sigue pendiente 1
--  8 un técnico no recibe devoluciones; el almacenista no resuelve diferencias (solo admin)
--  9 el admin da por consumida la diferencia: custodia 0 y la orden sale de la lista
-- 10 lo que usó y no le entregaron queda como adicional por conciliar; conciliar lo quita de la lista
begin;

select set_config('app.res', 'la prueba no llegó al final (revisa si hubo un error arriba)', true);

do $$
declare
  v_admin uuid; v_t1 uuid; v_alm uuid; v_prod uuid; v_cot uuid; v_otro uuid;
  v_orden uuid; v_ent uuid; v_cita uuid;
  b_f numeric; b_a numeric; b_c numeric;
  f numeric; a numeric; c numeric;
  r jsonb; v_res text := ''; v_n int; v_txt text; v_x numeric; v_estado text;
begin
  select id into v_admin from perfiles where rol = 'admin' and coalesce(activo, true) limit 1;
  select id into v_t1 from perfiles where rol = 'tecnico' and coalesce(activo, true) limit 1;
  select id into v_alm from perfiles
   where id <> coalesce(v_admin, '00000000-0000-0000-0000-000000000000'::uuid)
     and id <> coalesce(v_t1, '00000000-0000-0000-0000-000000000000'::uuid) limit 1;
  select id into v_prod from productos where activo limit 1;
  select id into v_otro from productos where activo and id <> coalesce(v_prod, '00000000-0000-0000-0000-000000000000'::uuid) limit 1;
  select id into v_cot from cotizaciones limit 1;

  if v_admin is null or v_t1 is null or v_alm is null or v_prod is null or v_cot is null then
    perform set_config('app.res', concat(
      'SIN DATOS: hace falta un admin, un técnico, un tercer perfil, un producto y una cotización. ',
      'admin=', coalesce(v_admin::text, 'no'), ' t1=', coalesce(v_t1::text, 'no'), ' alm=', coalesce(v_alm::text, 'no'),
      ' prod=', coalesce(v_prod::text, 'no'), ' cot=', coalesce(v_cot::text, 'no')), true);
    return;
  end if;

  -- ---- preparación (como dueño de la base; se deshace al final) ----
  update perfiles set rol = 'almacenista', activo = true where id = v_alm;
  insert into movimientos_inventario (producto_id, tipo, cantidad, referencia, notas, usuario)
    values (v_prod, 'entrada', 10, 'PRUEBA-18', 'prueba', 'prueba');
  update citas set estado = 'cancelada' where cotizacion_id = v_cot;
  update cotizaciones
     set estado = 'borrador', tipo = 'mantenimiento',
         partidas = jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 4, 'descripcion', 'prueba')),
         prog_fecha = current_date + 2, prog_hora = '09:00', prog_duracion_min = 60,
         prog_tecnico_id = v_t1, prog_tecnico2_id = null
   where id = v_cot;

  set local role authenticated;

  -- admin acepta; almacén entrega 3; T1 firma
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);
  select fisico, apartado, en_custodia into b_f, b_a, b_c from existencias where id = v_prod;
  r := cambiar_estado_cotizacion(v_cot, 'aceptada');
  v_orden := (r ->> 'orden_id')::uuid;
  v_cita := (r ->> 'cita_id')::uuid;

  perform set_config('request.jwt.claims', json_build_object('sub', v_alm, 'role', 'authenticated', 'email', 'almacen@prueba')::text, true);
  perform ordenes_por_surtir();
  r := crear_entrega(v_orden, jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 3)));
  v_ent := (r ->> 'entrega_id')::uuid;

  perform set_config('request.jwt.claims', json_build_object('sub', v_t1, 'role', 'authenticated', 'email', 'tecnico@prueba')::text, true);
  perform firmar_entrega(v_ent, 'entregas/prueba.png');

  -- (como dueño no se puede escribir la parte del técnico con las políticas: se hace como el técnico)
  insert into orden_partes (orden_id, autor_id, notas) values (v_orden, v_t1, 'Cambié filtros y revisé el equipo.');

  -- ---- 1. más usadas que recibidas ----
  begin
    perform cerrar_orden(v_orden, null, true, null, null, null, false, null, null,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'usadas', 4)));
    v_res := concat(v_res, '1 FALLO: dejó declarar más usadas que recibidas', E'\n');
  exception when sqlstate '22023' then
    select estado into v_estado from ordenes_servicio where id = v_orden;
    v_res := concat(v_res, case when v_estado = 'abierta'
      then '1 ok: declarar más usadas que recibidas se rechaza y la orden sigue abierta'
      else concat('1 FALLO: la orden quedó ', v_estado) end, E'\n');
  end;

  -- ---- 2. una pieza que no está en el material ----
  if v_otro is null then
    v_res := concat(v_res, '2 omitido: solo hay un producto', E'\n');
  else
    begin
      perform cerrar_orden(v_orden, null, true, null, null, null, false, null, null,
        jsonb_build_array(jsonb_build_object('producto_id', v_otro, 'usadas', 1)));
      v_res := concat(v_res, '2 FALLO: aceptó una pieza que no estaba en el material', E'\n');
    exception when sqlstate '22023' then
      v_res := concat(v_res, '2 ok: una pieza que no está en el material se rechaza', E'\n');
    end;
  end if;

  -- ---- 3. cerrar con 1 usada (y un adicional que no le entregaron) ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);
  select fisico, apartado, en_custodia into f, a, c from existencias where id = v_prod;
  v_x := c;   -- custodia antes de cerrar (debe ser b_c + 3)

  perform set_config('request.jwt.claims', json_build_object('sub', v_t1, 'role', 'authenticated', 'email', 'tecnico@prueba')::text, true);
  r := cerrar_orden(v_orden, null, true, null, null, null, false, null,
        jsonb_build_array(jsonb_build_object('descripcion', 'Manguera de 1/2"', 'cantidad', '2')),
        jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'usadas', 1)));
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);
  select fisico, apartado, en_custodia into f, a, c from existencias where id = v_prod;
  select estado into v_estado from citas where id = v_cita;
  select estado into v_txt from ordenes_servicio where id = v_orden;
  v_res := concat(v_res, case when (v_x - b_c) = 3 and c - b_c = 2 and f - b_f = -3 and v_txt = 'cerrada' and v_estado = 'realizada'
    then '3 ok: cerrar con 1 usada baja la custodia de 3 a 2, no toca el físico y cierra orden y cita'
    else concat('3 FALLO: custodia antes +', v_x - b_c, ' después +', c - b_c, ', físico ', f - b_f, ', orden=', v_txt, ', cita=', v_estado, ', respuesta=', r) end, E'\n');

  -- ---- 4. cerrar otra vez: nada se repite ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_t1, 'role', 'authenticated', 'email', 'tecnico@prueba')::text, true);
  r := cerrar_orden(v_orden, null, true, null, null, null, false, null, null,
        jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'usadas', 1)));
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);
  select en_custodia into c from existencias where id = v_prod;
  v_res := concat(v_res, case when (r ->> 'sin_cambio') = 'true' and c - b_c = 2
    then '4 ok: cerrar otra vez no repite el consumo'
    else concat('4 FALLO: respuesta=', r, ' custodia +', c - b_c) end, E'\n');

  -- ---- 5. el almacén ve la devolución pendiente ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_alm, 'role', 'authenticated', 'email', 'almacen@prueba')::text, true);
  select (x -> 'lineas' -> 0 ->> 'pendiente')::numeric, (x ->> 'dias')::int, x ->> 'tecnico1'
    into v_x, v_n, v_txt
    from jsonb_array_elements(devoluciones_pendientes()) x where (x ->> 'orden_id')::uuid = v_orden;
  v_res := concat(v_res, case when v_x = 2 and v_n = 0 and v_txt is not null
    then concat('5 ok: el almacén ve 2 pendientes de devolución, de ', v_txt, ', con 0 días')
    else concat('5 FALLO: pendiente=', v_x, ' días=', v_n, ' T1=', v_txt) end, E'\n');

  -- ---- 6. recibir de más / recibir menos sin observación ----
  v_txt := '';
  begin
    perform recibir_devolucion(v_orden, jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 3)), 'x');
    v_txt := 'aceptó recibir de más ';
  exception when sqlstate '22023' then null; end;
  begin
    perform recibir_devolucion(v_orden, jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1)), '  ');
    v_txt := v_txt || 'aceptó recibir menos sin observación';
  exception when sqlstate '22023' then null; end;
  v_res := concat(v_res, case when v_txt = '' then '6 ok: recibir de más o recibir menos sin observación se rechaza'
    else concat('6 FALLO: ', v_txt) end, E'\n');

  -- ---- 7. recibir 1 con observación ----
  r := recibir_devolucion(v_orden, jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1)), 'Faltó 1 pieza');
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);
  select fisico, en_custodia into f, c from existencias where id = v_prod;
  select cantidad_devuelta into v_x from orden_surtido where orden_id = v_orden and producto_id = v_prod;
  select count(*) into v_n from devoluciones where orden_id = v_orden and observaciones = 'Faltó 1 pieza';
  v_res := concat(v_res, case when f - b_f = -2 and c - b_c = 1 and v_x = 1 and v_n = 1 and (r ->> 'piezas_pendientes') = '1'
    then '7 ok: recibir 1 con observación sube el físico, baja la custodia a 1 y queda 1 pendiente'
    else concat('7 FALLO: físico ', f - b_f, ', custodia +', c - b_c, ', devuelta=', v_x, ', observaciones=', v_n, ', respuesta=', r) end, E'\n');

  -- ---- 8. permisos ----
  v_txt := '';
  perform set_config('request.jwt.claims', json_build_object('sub', v_t1, 'role', 'authenticated', 'email', 'tecnico@prueba')::text, true);
  begin perform recibir_devolucion(v_orden, jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1)), 'x'); v_txt := 'el técnico recibió '; exception when sqlstate '42501' then null; end;
  perform set_config('request.jwt.claims', json_build_object('sub', v_alm, 'role', 'authenticated', 'email', 'almacen@prueba')::text, true);
  begin perform resolver_diferencia(v_orden, v_prod, 'x'); v_txt := v_txt || 'el almacén resolvió'; exception when sqlstate '42501' then null; end;
  v_res := concat(v_res, case when v_txt = '' then '8 ok: un técnico no recibe devoluciones y el almacenista no resuelve diferencias'
    else concat('8 FALLO: ', v_txt) end, E'\n');

  -- ---- 9. el admin da por consumida la diferencia ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);
  begin perform resolver_diferencia(v_orden, v_prod, '   '); v_txt := 'aceptó sin motivo'; exception when sqlstate '22023' then v_txt := ''; end;
  r := resolver_diferencia(v_orden, v_prod, 'Se dañó en el sitio');
  select en_custodia into c from existencias where id = v_prod;
  select count(*) into v_n from jsonb_array_elements(devoluciones_pendientes()) x where (x ->> 'orden_id')::uuid = v_orden;
  v_res := concat(v_res, case when v_txt = '' and c = b_c and v_n = 0
    then '9 ok: sin motivo se rechaza; con motivo la custodia queda en 0 y la orden sale de pendientes'
    else concat('9 FALLO: ', v_txt, ' custodia +', c - b_c, ' en la lista=', v_n) end, E'\n');

  -- ---- 10. adicionales por conciliar ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_alm, 'role', 'authenticated', 'email', 'almacen@prueba')::text, true);
  select count(*) into v_n from jsonb_array_elements(adicionales_por_conciliar()) x
   where (x ->> 'orden_id')::uuid = v_orden and (x -> 'items' -> 0 ->> 'descripcion') like 'Manguera%';
  perform conciliar_adicional(v_orden, 'Ya se repuso');
  select count(*) into v_x from jsonb_array_elements(adicionales_por_conciliar()) x where (x ->> 'orden_id')::uuid = v_orden;
  v_res := concat(v_res, case when v_n = 1 and v_x = 0
    then '10 ok: el adicional aparece por conciliar y al conciliarlo sale de la lista'
    else concat('10 FALLO: antes=', v_n, ' después=', v_x) end);

  perform set_config('app.res', v_res, true);
end $$;

select unnest(string_to_array(current_setting('app.res', true), E'\n')) as resultado;

rollback;
