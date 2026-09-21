-- Prueba de la 14 (correr DESPUÉS de la 14; el bloque COMPLETO). Termina en rollback: no deja nada.
--
-- Usa datos que ya existen y los deja en el estado que necesita DENTRO de la transacción:
--   · un admin, un técnico (T1) y un tercer perfil cualquiera, al que le pone rol
--     `almacenista` solo durante la prueba;
--   · un producto activo (le mete 10 piezas de existencia) y una cotización cualquiera
--     (la deja en borrador, tipo mantenimiento, con 4 piezas de ese producto).
-- Si falta alguno de esos datos, lo dice y no hace nada.
--
-- Resultado esperado (todos "ok"):
--  1 aceptar aparta 4                   2 el almacén ve la orden con 4 pedidas
--  3 crear entrega de 3 no mueve nada   4 pedir 2 más (solo queda 1) se rechaza
--  5 el almacén no puede firmar         6 T1 firma: físico −3, custodia +3, disponible igual
--  7 firmar otra vez: sin_cambio        8 T1 lee su surtido (entregada 3) y no puede escribirlo
--  9 rechazar la cotización libera solo 1 (lo que quedaba) y la cita se queda (con material)
-- 10 entrega sin firma: sin motivo se rechaza, con motivo pasa
-- 11 el almacenista no lee tablas directamente
begin;

do $$
declare
  v_admin uuid; v_t1 uuid; v_alm uuid; v_prod uuid; v_cot uuid;
  v_orden uuid; v_ent uuid; v_ent2 uuid;
  b_f numeric; b_a numeric; b_c numeric;      -- base (antes de aceptar)
  f numeric; a numeric; c numeric;
  r jsonb; v_res text := ''; v_n int; v_estado text; v_entregada numeric;
begin
  select id into v_admin from perfiles where rol = 'admin' and coalesce(activo, true) limit 1;
  select id into v_t1 from perfiles where rol = 'tecnico' and coalesce(activo, true) limit 1;
  select id into v_alm from perfiles
   where id <> coalesce(v_admin, '00000000-0000-0000-0000-000000000000'::uuid)
     and id <> coalesce(v_t1, '00000000-0000-0000-0000-000000000000'::uuid)
   limit 1;
  select id into v_prod from productos where activo limit 1;
  select id into v_cot from cotizaciones limit 1;

  if v_admin is null or v_t1 is null or v_alm is null or v_prod is null or v_cot is null then
    perform set_config('app.res',
      'SIN DATOS: hace falta un admin, un técnico, un tercer perfil, un producto y una cotización. '
      || 'admin=' || coalesce(v_admin::text, 'no') || ' t1=' || coalesce(v_t1::text, 'no')
      || ' alm=' || coalesce(v_alm::text, 'no') || ' prod=' || coalesce(v_prod::text, 'no')
      || ' cot=' || coalesce(v_cot::text, 'no'), true);
    return;
  end if;

  -- ---- preparación (como dueño de la base; se deshace al final) ----
  update perfiles set rol = 'almacenista', activo = true where id = v_alm;
  insert into movimientos_inventario (producto_id, tipo, cantidad, referencia, notas, usuario)
  values (v_prod, 'entrada', 10, 'PRUEBA-14', 'prueba', 'prueba');
  update citas set estado = 'cancelada' where cotizacion_id = v_cot;
  update cotizaciones
     set estado = 'borrador', tipo = 'mantenimiento',
         partidas = jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 4, 'descripcion', 'prueba')),
         prog_fecha = current_date + 2, prog_hora = '09:00', prog_duracion_min = 60,
         prog_tecnico_id = v_t1, prog_tecnico2_id = null
   where id = v_cot;

  set local role authenticated;

  -- ---- 1. admin acepta la cotización ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);
  select fisico, apartado, en_custodia into b_f, b_a, b_c from existencias where id = v_prod;
  r := cambiar_estado_cotizacion(v_cot, 'aceptada');
  v_orden := (r ->> 'orden_id')::uuid;
  select fisico, apartado, en_custodia into f, a, c from existencias where id = v_prod;
  v_res := v_res || case when v_orden is not null and a - b_a = 4 and f = b_f
    then '1 ok: aceptar aparta 4 y abre orden | ' else '1 FALLO: apartado +' || (a - b_a) || ', orden=' || coalesce(v_orden::text, 'null') || ' | ' end;

  -- ---- 2. el almacenista ve la orden ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_alm, 'role', 'authenticated', 'email', 'almacen@prueba')::text, true);
  select (x -> 'lineas' -> 0 ->> 'pedida')::numeric into v_entregada
    from jsonb_array_elements(ordenes_por_surtir()) x
   where (x ->> 'orden_id')::uuid = v_orden;
  v_res := v_res || case when v_entregada = 4 then '2 ok: el almacén ve la orden con 4 pedidas | '
    else '2 FALLO: pedidas=' || coalesce(v_entregada::text, 'no aparece') || ' | ' end;

  -- ---- 3. crear entrega de 3: no mueve inventario ----
  r := crear_entrega(v_orden, jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 3)));
  v_ent := (r ->> 'entrega_id')::uuid;
  select fisico, apartado, en_custodia into f, a, c from existencias where id = v_prod;
  v_res := v_res || case when v_ent is not null and f = b_f and a - b_a = 4 and c = b_c
    then '3 ok: la entrega queda pendiente y no mueve nada | ' else '3 FALLO: se movió el inventario | ' end;

  -- ---- 4. pedir 2 más (solo queda 1 por entregar) ----
  begin
    perform crear_entrega(v_orden, jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 2)));
    v_res := v_res || '4 FALLO: dejó pedir de más | ';
  exception when sqlstate '22023' then
    v_res := v_res || '4 ok: pedir de más se rechaza | ';
  end;

  -- ---- 5. el almacenista no puede firmar ----
  begin
    perform firmar_entrega(v_ent, 'entregas/x.png');
    v_res := v_res || '5 FALLO: el almacenista firmó | ';
  exception when sqlstate '42501' then
    v_res := v_res || '5 ok: el almacén no puede firmar | ';
  end;

  -- ---- 6 y 7. T1 firma ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_t1, 'role', 'authenticated', 'email', 'tecnico@prueba')::text, true);
  r := firmar_entrega(v_ent, 'entregas/prueba.png');
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);
  select fisico, apartado, en_custodia into f, a, c from existencias where id = v_prod;
  v_res := v_res || case when f - b_f = -3 and c - b_c = 3 and (f - a) = (b_f - b_a - 4)
    then '6 ok: físico −3, custodia +3, disponible igual | '
    else '6 FALLO: físico ' || (f - b_f) || ', custodia ' || (c - b_c) || ', apartado ' || (a - b_a) || ' | ' end;

  perform set_config('request.jwt.claims', json_build_object('sub', v_t1, 'role', 'authenticated', 'email', 'tecnico@prueba')::text, true);
  r := firmar_entrega(v_ent, 'entregas/prueba.png');
  v_res := v_res || case when r ->> 'sin_cambio' = 'true' then '7 ok: firmar otra vez no repite | '
    else '7 FALLO: volvió a mover | ' end;

  -- ---- 8. T1 lee su surtido pero no lo escribe ----
  select cantidad_entregada into v_entregada from orden_surtido where orden_id = v_orden and producto_id = v_prod;
  begin
    insert into orden_surtido (orden_id, producto_id, cantidad_pedida) values (v_orden, v_prod, 99);
    v_res := v_res || '8 FALLO: el técnico escribió el surtido | ';
  exception when sqlstate '42501' then
    v_res := v_res || case when v_entregada = 3 then '8 ok: T1 lee entregada=3 y no puede escribir | '
      else '8 FALLO: T1 lee entregada=' || coalesce(v_entregada::text, 'nada') || ' | ' end;
  end;

  -- ---- 9. rechazar la cotización libera solo lo que quedaba (1) ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);
  r := cambiar_estado_cotizacion(v_cot, 'rechazada');
  select fisico, apartado, en_custodia into f, a, c from existencias where id = v_prod;
  select estado into v_estado from citas where cotizacion_id = v_cot and estado <> 'cancelada' limit 1;
  v_res := v_res || case when a = b_a and (r ->> 'citas_con_trabajo')::int = 1 and v_estado = 'programada'
    then '9 ok: se libera solo 1, apartado vuelve a la base y la cita se queda | '
    else '9 FALLO: apartado ' || (a - b_a) || ', citas_con_trabajo=' || coalesce(r ->> 'citas_con_trabajo', '?') || ', cita=' || coalesce(v_estado, 'cancelada') || ' | ' end;

  -- ---- 10. entrega sin firma ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_alm, 'role', 'authenticated', 'email', 'almacen@prueba')::text, true);
  -- la cotización ya no está aceptada: el resto (1) se entrega sin apartado que liberar
  r := crear_entrega(v_orden, jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1)));
  v_ent2 := (r ->> 'entrega_id')::uuid;
  begin
    perform entregar_sin_firma(v_ent2, '  ');
    v_res := v_res || '10 FALLO: aceptó sin motivo | ';
  exception when sqlstate '22023' then
    r := entregar_sin_firma(v_ent2, 'El técnico no traía su celular');
    select estado into v_estado from entregas where id = v_ent2;
    perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);
    select fisico, apartado, en_custodia into f, a, c from existencias where id = v_prod;
    v_res := v_res || case when v_estado = 'sin_firma' and c - b_c = 4 and f - b_f = -4 and a = b_a
      then '10 ok: sin motivo se rechaza; con motivo pasa (custodia +4 en total) | '
      else '10 FALLO: estado ' || v_estado || ', custodia ' || (c - b_c) || ', apartado ' || (a - b_a) || ' | ' end;
  end;

  -- ---- 11. el almacenista no lee tablas directamente ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_alm, 'role', 'authenticated', 'email', 'almacen@prueba')::text, true);
  select (select count(*) from ordenes_servicio) + (select count(*) from orden_surtido)
       + (select count(*) from entregas) + (select count(*) from clientes) into v_n;
  v_res := v_res || case when v_n = 0 then '11 ok: el almacenista no lee tablas' else '11 FALLO: lee ' || v_n || ' filas' end;

  perform set_config('app.res', v_res, true);
end $$;

select replace(current_setting('app.res', true), ' | ', E'\n') as resultado;

rollback;
