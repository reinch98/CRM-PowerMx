-- Prueba de la 29 (correr DESPUÉS de la 29; el bloque COMPLETO). Termina en rollback.
--
-- Todos los pasos deben decir "ok":
--  1 el paquete llena la lista de surtido de una póliza (que no tiene cotización)
--  2 se elige el código con MÁS disponible, aunque no sea el original
--  3 llamarla dos veces no duplica
--  4 sin equipo en la orden lo dice con todas sus letras
--  5 sin paquete para ese equipo no truena: avisa y no agrega nada
--  6 un equipo cuyo paquete tiene una línea sin códigos avisa cuál quedó fuera
--  7 el técnico no puede precargar el surtido
--  8 `piezas_que_se_repiten` cuenta VISITAS, no piezas
--  9 solo mira órdenes cerradas y del equipo que corresponde
-- 10 el almacenista puede precargar pero NO ve precios (no llama paquete_preventivo)
begin;

select set_config('app.res', 'la prueba no llegó al final (revisa si hubo un error arriba)', true);

do $$
declare
  v_admin uuid; v_tec uuid; v_alm uuid; v_rol_previo text;
  v_cli uuid; v_eq uuid; v_eq2 uuid; v_eq_sin uuid;
  v_cita uuid; v_orden uuid; v_orden_sin uuid; v_cerrada1 uuid; v_cerrada2 uuid; v_abierta uuid;
  v_del_almacen uuid;
  p_ok uuid; p_hueco uuid;
  prod_orig uuid; prod_gen uuid; prod_otro uuid;
  r jsonb; v_res text := ''; v_txt text;
  v_n int; v_sku text; v_vis bigint; v_de bigint;
begin
  select id into v_admin from perfiles where rol = 'admin' and coalesce(activo, true) limit 1;
  select id into v_tec from perfiles where rol = 'tecnico' and coalesce(activo, true) limit 1;
  select id into v_alm from perfiles where id not in (v_admin, v_tec) limit 1;
  if v_admin is null or v_tec is null or v_alm is null then
    perform set_config('app.res', concat('SIN DATOS: admin=', coalesce(v_admin::text, 'no'),
      ' tecnico=', coalesce(v_tec::text, 'no'), ' tercero=', coalesce(v_alm::text, 'no')), true);
    return;
  end if;
  select rol into v_rol_previo from perfiles where id = v_alm;
  update perfiles set rol = 'almacenista', activo = true where id = v_alm;

  insert into clientes (nombre, telefono) values ('Cliente 29', '999 000 0290') returning id into v_cli;

  insert into equipos (cliente_id, numero_serie, tipo, marca, capacidad_kw, atributos)
  values (v_cli, 'SER-29-A', 'generador', 'Generac', 22, '{"combustible":"diesel"}'::jsonb)
  returning id into v_eq;
  insert into equipos (cliente_id, numero_serie, tipo, marca, capacidad_kw, atributos)
  values (v_cli, 'SER-29-B', 'generador', 'Kohler', 22, '{"combustible":"diesel"}'::jsonb)
  returning id into v_eq2;
  -- Sin paquete posible: es solar y no hay paquetes solares.
  insert into equipos (cliente_id, numero_serie, tipo, marca, capacidad_kw)
  values (v_cli, 'SER-29-C', 'solar', 'Huawei', 10) returning id into v_eq_sin;

  insert into productos (sku, nombre, categoria, precio, unidad, grupo_equivalente)
  values ('F29-ORIG', 'Filtro original', 'refaccion', 320, 'pieza', 'GRUPO-F29')
  returning id into prod_orig;
  insert into productos (sku, nombre, categoria, precio, unidad, grupo_equivalente)
  values ('F29-GEN', 'Filtro genérico', 'refaccion', 180, 'pieza', 'GRUPO-F29')
  returning id into prod_gen;
  insert into productos (sku, nombre, categoria, precio, unidad)
  values ('BUJIA-29', 'Bujía', 'refaccion', 90, 'pieza') returning id into prod_otro;
  -- El genérico tiene más existencia que el original: el surtido debe preferirlo.
  insert into movimientos_inventario (producto_id, tipo, cantidad, referencia)
  values (prod_orig, 'entrada', 1, 'PRUEBA-29'), (prod_gen, 'entrada', 25, 'PRUEBA-29');

  insert into paquetes_mantenimiento (tipo, clase, kw_desde, kw_hasta, marca, nombre)
  values ('menor', 'diesel', 0, 100, 'Generac', 'Menor Generac') returning id into p_ok;
  insert into paquete_lineas (paquete_id, descripcion, producto_id, cantidad, orden)
  values (p_ok, 'Filtro de aceite', prod_orig, 2, 1);

  -- Un paquete con una línea que apunta a un grupo que nadie tiene.
  insert into paquetes_mantenimiento (tipo, clase, kw_desde, kw_hasta, marca, nombre)
  values ('menor', 'diesel', 0, 100, 'Kohler', 'Menor Kohler') returning id into p_hueco;
  insert into paquete_lineas (paquete_id, descripcion, grupo, cantidad, orden)
  values (p_hueco, 'Empaque especial', 'GRUPO-QUE-NO-EXISTE', 1, 1);

  -- Una cita de PÓLIZA: abre orden y NO tiene cotización.
  insert into citas (cliente_id, equipo_id, fecha, tipo_servicio, estado, origen, tecnico_id)
  values (v_cli, v_eq, (now() at time zone 'America/Mexico_City')::date, 'preventivo',
          'programada', 'poliza', v_tec)
  returning id into v_cita;
  insert into ordenes_servicio (cliente_id, equipo_id, cita_id, fecha, tipo_servicio, tecnico_id, estado)
  values (v_cli, v_eq, v_cita, (now() at time zone 'America/Mexico_City')::date, 'preventivo', v_tec, 'abierta')
  returning id into v_orden;

  insert into ordenes_servicio (cliente_id, fecha, tipo_servicio, estado)
  values (v_cli, (now() at time zone 'America/Mexico_City')::date, 'preventivo', 'abierta')
  returning id into v_orden_sin;

  -- Historial para el paso 8: dos visitas CERRADAS del mismo equipo, el filtro en las dos
  -- y la bujía en una sola. Más una ABIERTA que no debe contar.
  insert into ordenes_servicio (cliente_id, equipo_id, fecha, tipo_servicio, estado)
  values (v_cli, v_eq, current_date - 60, 'preventivo', 'cerrada') returning id into v_cerrada1;
  insert into ordenes_servicio (cliente_id, equipo_id, fecha, tipo_servicio, estado)
  values (v_cli, v_eq, current_date - 30, 'preventivo', 'cerrada') returning id into v_cerrada2;
  insert into ordenes_servicio (cliente_id, equipo_id, fecha, tipo_servicio, estado)
  values (v_cli, v_eq, current_date - 5, 'preventivo', 'abierta') returning id into v_abierta;

  -- Para el paso 10: el almacenista NO puede crear órdenes (solo admin), así que la suya
  -- se crea aquí, como dueño de la base, antes de cambiar de papel.
  insert into ordenes_servicio (cliente_id, equipo_id, fecha, tipo_servicio, estado)
  values (v_cli, v_eq, current_date, 'preventivo', 'abierta') returning id into v_del_almacen;

  -- `orden_surtido_uso_no_excede` (18): no se puede usar más de lo que se entregó, así que
  -- la entrega va junto con el uso. Además es lo realista: nadie consume lo que no recibió.
  insert into orden_surtido (orden_id, producto_id, sku, nombre, unidad,
                             cantidad_pedida, cantidad_entregada, cantidad_usada)
  values (v_cerrada1, prod_orig, 'F29-ORIG', 'Filtro original', 'pieza', 2, 2, 2),
         (v_cerrada1, prod_otro, 'BUJIA-29', 'Bujía', 'pieza', 4, 4, 4),
         (v_cerrada2, prod_orig, 'F29-ORIG', 'Filtro original', 'pieza', 2, 2, 2),
         (v_abierta,  prod_otro, 'BUJIA-29', 'Bujía', 'pieza', 9, 9, 9);

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);

  -- ---- 1 y 2. precargar el surtido ----
  r := surtido_desde_paquete(v_orden, 'menor');
  select count(*), max(sku) into v_n, v_sku from orden_surtido where orden_id = v_orden;
  v_res := concat(v_res, case when (r ->> 'agregadas') = '1' and v_n = 1
    then '1 ok: el paquete llena el surtido de una póliza sin cotización'
    else concat('1 FALLO: r=', r, ' lineas=', v_n) end, E'\n');
  v_res := concat(v_res, case when v_sku = 'F29-GEN'
    then '2 ok: se eligió el código con más disponible, no el original'
    else concat('2 FALLO: eligió ', coalesce(v_sku, 'nada')) end, E'\n');

  -- ---- 3. no duplica ----
  r := surtido_desde_paquete(v_orden, 'menor');
  select count(*) into v_n from orden_surtido where orden_id = v_orden;
  v_res := concat(v_res, case when (r ->> 'agregadas') = '0' and v_n = 1
    then '3 ok: llamarla dos veces no duplica'
    else concat('3 FALLO: r=', r, ' lineas=', v_n) end, E'\n');

  -- ---- 4. sin equipo ----
  v_txt := '';
  begin
    perform surtido_desde_paquete(v_orden_sin, 'menor');
    v_txt := 'lo dejó pasar';
  exception when sqlstate '22023' then
    get stacked diagnostics v_txt = message_text;
    v_txt := case when v_txt like '%de qué equipo%' then '' else concat('mensaje raro: ', v_txt) end;
  end;
  v_res := concat(v_res, case when v_txt = ''
    then '4 ok: una orden sin equipo lo dice con todas sus letras'
    else concat('4 FALLO: ', v_txt) end, E'\n');

  -- ---- 5. sin paquete ----
  insert into ordenes_servicio (cliente_id, equipo_id, fecha, tipo_servicio, estado)
  values (v_cli, v_eq_sin, current_date, 'preventivo', 'abierta') returning id into v_cerrada1;
  r := surtido_desde_paquete(v_cerrada1, 'menor');
  v_res := concat(v_res, case when (r ->> 'agregadas') = '0' and (r ->> 'motivo') like '%no tiene paquete%'
    then '5 ok: sin paquete avisa y no agrega nada'
    else concat('5 FALLO: ', r) end, E'\n');

  -- ---- 6. línea sin códigos ----
  insert into ordenes_servicio (cliente_id, equipo_id, fecha, tipo_servicio, estado)
  values (v_cli, v_eq2, current_date, 'preventivo', 'abierta') returning id into v_cerrada2;
  r := surtido_desde_paquete(v_cerrada2, 'menor');
  v_res := concat(v_res, case when (r ->> 'agregadas') = '0' and (r ->> 'sin_codigo') = 'Empaque especial'
    then '6 ok: avisa qué línea quedó fuera por no tener códigos'
    else concat('6 FALLO: ', r) end, E'\n');

  -- ---- 7. el técnico ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_tec, 'role', 'authenticated', 'email', 'tec@prueba')::text, true);
  v_txt := '';
  begin perform surtido_desde_paquete(v_orden, 'menor'); v_txt := 'lo dejó entrar';
  exception when sqlstate '42501' then null; end;
  v_res := concat(v_res, case when v_txt = ''
    then '7 ok: el técnico no precarga el surtido'
    else concat('7 FALLO: ', v_txt) end, E'\n');

  -- ---- 8 y 9. lo que se repite ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);
  select visitas, de_visitas into v_vis, v_de
    from piezas_que_se_repiten('diesel', 0, 100, 'Generac') where sku = 'F29-ORIG';
  v_res := concat(v_res, case when v_vis = 2 and v_de = 2
    then '8 ok: cuenta visitas (2 de 2), no piezas'
    else concat('8 FALLO: visitas=', coalesce(v_vis::text, 'null'), ' de=', coalesce(v_de::text, 'null')) end, E'\n');

  select visitas into v_vis from piezas_que_se_repiten('diesel', 0, 100, 'Generac') where sku = 'BUJIA-29';
  select count(*) into v_n from piezas_que_se_repiten('diesel', 0, 100, 'Kohler');
  v_res := concat(v_res, case when v_vis = 1 and v_n = 0
    then '9 ok: la orden abierta no cuenta y solo mira el equipo que corresponde'
    else concat('9 FALLO: bujia=', coalesce(v_vis::text, 'null'), ' kohler=', v_n) end, E'\n');

  -- ---- 10. el almacenista ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_alm, 'role', 'authenticated', 'email', 'alm@prueba')::text, true);
  r := surtido_desde_paquete(v_del_almacen, 'menor');
  v_txt := '';
  begin perform paquete_preventivo(v_eq, 'menor'); v_txt := 'vio precios';
  exception when sqlstate '42501' then null; end;
  v_res := concat(v_res, case when (r ->> 'agregadas') = '1' and v_txt = ''
    then '10 ok: el almacenista precarga el surtido pero no ve precios'
    else concat('10 FALLO: r=', r, ' ', v_txt) end);

  perform set_config('app.res', v_res, true);
  reset role;
  update perfiles set rol = v_rol_previo where id = v_alm;
end $$;

reset role;
select current_setting('app.res', true) as resultado;

rollback;
