-- Prueba de la 19 (correr DESPUÉS de la 19; el bloque COMPLETO). Termina en rollback: no deja nada.
--
-- Usa un admin, un técnico (T1), un producto activo y un cliente con equipo — los mismos datos que
-- ya piden las pruebas de la 14 y la 18. Un tercer perfil cualquiera ("v_otro") hace dos papeles
-- por turnos, cambiándole el rol dentro de la transacción (se deshace con el rollback): primero
-- alguien que NO es técnico (para probar que no ve ni puede pedir), luego T2 de la orden, y al
-- final almacenista. Si falta alguno de los cuatro perfiles, lo dice y no hace nada.
--
-- Todos los pasos deben decir "ok":
--  1 T1 pide una pieza del catálogo ligada a su orden: sku/nombre se copian solos y el equipo
--    y el cliente se completan solos desde la orden
--  2 quien no es técnico no ve la solicitud ni puede crear una para esa orden
--  3 ya como T2 de la misma orden, ve la solicitud de T1
--  4 sin producto ni descripción se rechaza; cantidad 0 se rechaza
--  5 T1 cancela su propia solicitud pendiente
--  6 T1 no puede marcarla "atendida" él mismo
--  7 ya como almacenista, ve la solicitud pendiente con contexto (técnico, cliente, equipo, orden, físico)
--  8 atender sin resolución se rechaza; con resolución marca atendida y guarda quién y cuándo
--  9 descartar sin motivo se rechaza; con motivo marca descartada
-- 10 un técnico no puede atender ni descartar (solo almacén/admin)
begin;

select set_config('app.res', 'la prueba no llegó al final (revisa si hubo un error arriba)', true);

do $$
declare
  v_admin uuid; v_t1 uuid; v_otro uuid; v_prod uuid; v_cli uuid; v_eq uuid;
  v_orden uuid; v_sol uuid; v_sol2 uuid;
  r jsonb; v_res text := ''; v_n int; v_txt text; v_estado text; v_b boolean;
begin
  select id into v_admin from perfiles where rol = 'admin' and coalesce(activo, true) limit 1;
  select id into v_t1 from perfiles where rol = 'tecnico' and coalesce(activo, true) limit 1;
  select id into v_otro from perfiles
   where id <> coalesce(v_admin, '00000000-0000-0000-0000-000000000000'::uuid)
     and id <> coalesce(v_t1, '00000000-0000-0000-0000-000000000000'::uuid)
     and rol <> 'tecnico'
   limit 1;
  select id into v_prod from productos where activo limit 1;
  select cliente_id, id into v_cli, v_eq from equipos where cliente_id is not null limit 1;

  if v_admin is null or v_t1 is null or v_otro is null or v_prod is null or v_cli is null then
    perform set_config('app.res', concat(
      'SIN DATOS: hace falta un admin, un técnico, un tercer perfil (que no sea técnico) y un ',
      'cliente con equipo. admin=', coalesce(v_admin::text, 'no'), ' t1=', coalesce(v_t1::text, 'no'),
      ' otro=', coalesce(v_otro::text, 'no'), ' prod=', coalesce(v_prod::text, 'no'),
      ' cliente_con_equipo=', coalesce(v_cli::text, 'no')), true);
    return;
  end if;

  -- ---- preparación: una orden abierta con T1 y, como T2, el tercer perfil (todavía sin ese rol) ----
  insert into ordenes_servicio (cliente_id, equipo_id, tecnico_id, tecnico2_id, estado)
    values (v_cli, v_eq, v_t1, v_otro, 'abierta') returning id into v_orden;

  set local role authenticated;

  -- ---- 1. T1 pide una pieza del catálogo ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_t1, 'role', 'authenticated', 'email', 't1@prueba')::text, true);
  insert into solicitudes_material (tecnico_id, orden_id, producto_id, cantidad, nota)
    values (v_t1, v_orden, v_prod, 2, 'Para la siguiente visita') returning id into v_sol;
  declare
    v_sku text; v_nom text; v_eqid uuid; v_clid uuid;
  begin
    select sku, nombre, equipo_id, cliente_id into v_sku, v_nom, v_eqid, v_clid from solicitudes_material where id = v_sol;
    v_res := concat(v_res, case when v_sku is not null and v_nom is not null and v_eqid = v_eq and v_clid = v_cli
      then '1 ok: sku/nombre se copian solos y equipo/cliente se completan desde la orden'
      else concat('1 FALLO: sku=', v_sku, ' nombre=', v_nom, ' equipo=', v_eqid, ' cliente=', v_clid) end, E'\n');
  end;

  -- ---- 2. quien no es técnico (todavía el rol original de v_otro) no ve ni puede crear ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_otro, 'role', 'authenticated', 'email', 'otro@prueba')::text, true);
  select count(*) into v_n from solicitudes_material where id = v_sol;
  v_txt := '';
  begin
    insert into solicitudes_material (tecnico_id, orden_id, producto_id, cantidad) values (v_otro, v_orden, v_prod, 1);
    v_txt := 'insertó ';
  exception when insufficient_privilege then null; end;
  v_res := concat(v_res, case when v_n = 0 and v_txt = ''
    then '2 ok: quien no es técnico no ve la solicitud ni puede crear una'
    else concat('2 FALLO: ve ', v_n, ' filas; ', v_txt) end, E'\n');

  -- ---- 3. ahora v_otro es técnico (T2 de la misma orden): ve la solicitud de T1 ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);
  update perfiles set rol = 'tecnico', activo = true where id = v_otro;
  perform set_config('request.jwt.claims', json_build_object('sub', v_otro, 'role', 'authenticated', 'email', 'otro@prueba')::text, true);
  select count(*) into v_n from solicitudes_material where id = v_sol;
  v_res := concat(v_res, case when v_n = 1 then '3 ok: el compañero de la orden ve la solicitud'
    else '3 FALLO: no la ve' end, E'\n');

  -- ---- 4. validaciones (como T1) ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_t1, 'role', 'authenticated', 'email', 't1@prueba')::text, true);
  v_txt := '';
  begin
    insert into solicitudes_material (tecnico_id, orden_id, cantidad) values (v_t1, v_orden, 1);
    v_txt := 'aceptó sin producto ni descripción ';
  exception when check_violation then null; end;
  begin
    insert into solicitudes_material (tecnico_id, orden_id, producto_id, cantidad) values (v_t1, v_orden, v_prod, 0);
    v_txt := v_txt || 'aceptó cantidad 0';
  exception when check_violation then null; end;
  v_res := concat(v_res, case when v_txt = '' then '4 ok: sin pieza o con cantidad 0 se rechaza'
    else concat('4 FALLO: ', v_txt) end, E'\n');

  -- ---- 5. T1 cancela su propia solicitud ----
  update solicitudes_material set estado = 'descartada' where id = v_sol;
  select estado into v_estado from solicitudes_material where id = v_sol;
  v_res := concat(v_res, case when v_estado = 'descartada' then '5 ok: el técnico cancela su propia solicitud'
    else concat('5 FALLO: estado=', v_estado) end, E'\n');

  -- ---- 6. T1 no puede marcarla "atendida" él mismo ----
  insert into solicitudes_material (tecnico_id, orden_id, producto_id, cantidad)
    values (v_t1, v_orden, v_prod, 1) returning id into v_sol2;
  v_txt := '';
  begin
    update solicitudes_material set estado = 'atendida' where id = v_sol2;
    v_txt := 'se marcó atendida sola';
  exception when insufficient_privilege then null; end;
  select estado into v_estado from solicitudes_material where id = v_sol2;
  v_res := concat(v_res, case when v_txt = '' and v_estado = 'pendiente'
    then '6 ok: el técnico no puede marcar su propia solicitud como atendida'
    else concat('6 FALLO: ', v_txt, ' estado=', v_estado) end, E'\n');

  -- ---- 7. v_otro pasa a almacenista: ve la pendiente con contexto ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);
  update perfiles set rol = 'almacenista', activo = true where id = v_otro;
  perform set_config('request.jwt.claims', json_build_object('sub', v_otro, 'role', 'authenticated', 'email', 'otro@prueba')::text, true);
  declare
    ok7 boolean;
  begin
    select bool_and(coalesce((x ->> k) is not null, false)) into ok7
      from jsonb_array_elements(solicitudes_material_pendientes()) x,
           unnest(array['orden_folio', 'cliente', 'equipo', 'tecnico', 'fisico']) k
     where (x ->> 'id')::uuid = v_sol2;
    v_res := concat(v_res, case when ok7 then '7 ok: el almacén ve la pendiente con orden, cliente, equipo, técnico y físico'
      else '7 FALLO: falta contexto' end, E'\n');
  end;

  -- ---- 8. atender ----
  v_txt := '';
  begin
    perform atender_solicitud_material(v_sol2, '  ');
    v_txt := 'aceptó sin resolución ';
  exception when sqlstate '22023' then null; end;
  r := atender_solicitud_material(v_sol2, 'Se apartó en el almacén para la próxima visita');
  select estado, resolucion, atendida_por is not null into v_estado, v_txt, v_b
    from solicitudes_material where id = v_sol2;
  v_res := concat(v_res, case when v_estado = 'atendida' and v_txt = 'Se apartó en el almacén para la próxima visita' and v_b
    then '8 ok: atender sin resolución se rechaza; con resolución queda atendida con quién la resolvió'
    else concat('8 FALLO: estado=', v_estado, ' resolucion=', v_txt) end, E'\n');

  -- ---- 9. descartar ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_t1, 'role', 'authenticated', 'email', 't1@prueba')::text, true);
  insert into solicitudes_material (tecnico_id, orden_id, producto_id, cantidad) values (v_t1, v_orden, v_prod, 1) returning id into v_sol;
  perform set_config('request.jwt.claims', json_build_object('sub', v_otro, 'role', 'authenticated', 'email', 'otro@prueba')::text, true);
  v_txt := '';
  begin
    perform descartar_solicitud_material(v_sol, '   ');
    v_txt := 'aceptó sin motivo';
  exception when sqlstate '22023' then null; end;
  r := descartar_solicitud_material(v_sol, 'Ya no hace falta');
  select estado into v_estado from solicitudes_material where id = v_sol;
  v_res := concat(v_res, case when v_txt = '' and v_estado = 'descartada'
    then '9 ok: descartar sin motivo se rechaza; con motivo queda descartada'
    else concat('9 FALLO: ', v_txt, ' estado=', v_estado) end, E'\n');

  -- ---- 10. un técnico no atiende ni descarta ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_t1, 'role', 'authenticated', 'email', 't1@prueba')::text, true);
  v_txt := '';
  begin perform atender_solicitud_material(v_sol2, 'x'); v_txt := 'atendió '; exception when sqlstate '42501' then null; end;
  begin perform descartar_solicitud_material(v_sol2, 'x'); v_txt := v_txt || 'descartó'; exception when sqlstate '42501' then null; end;
  v_res := concat(v_res, case when v_txt = '' then '10 ok: un técnico no puede atender ni descartar'
    else concat('10 FALLO: ', v_txt) end);

  perform set_config('app.res', v_res, true);
end $$;

select unnest(string_to_array(current_setting('app.res', true), E'\n')) as resultado;

rollback;
