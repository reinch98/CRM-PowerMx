-- Prueba de la 20 (correr DESPUÉS de la 20; el bloque COMPLETO). Termina en rollback: no deja nada.
-- Usa un admin, un técnico y una orden cualquiera (no hace falta que esté cerrada: estas tablas
-- no dependen del estado). Si falta alguno, lo dice y no hace nada.
--
-- Todos los pasos deben decir "ok":
--  1 el admin registra el pdf generado y un envío, con destinatarios
--  2 regenerar el mismo tipo reemplaza la fila (upsert), no la duplica
--  3 un técnico no ve nada de esto
--  4 un técnico no puede registrar un pdf ni un envío
--  5 el admin marca "enviar al cerrar"; un técnico no puede tocar esa marca (ni nada de la orden)
begin;

select set_config('app.res', 'la prueba no llegó al final (revisa si hubo un error arriba)', true);

do $$
declare
  v_admin uuid; v_tec uuid; v_orden uuid;
  v_res text := ''; v_n int; v_txt text;
begin
  select id into v_admin from perfiles where rol = 'admin' and coalesce(activo, true) limit 1;
  select id into v_tec from perfiles where rol = 'tecnico' and coalesce(activo, true) limit 1;
  select id into v_orden from ordenes_servicio limit 1;

  if v_admin is null or v_tec is null or v_orden is null then
    perform set_config('app.res', concat(
      'SIN DATOS: hace falta un admin, un técnico y una orden. admin=', coalesce(v_admin::text, 'no'),
      ' tecnico=', coalesce(v_tec::text, 'no'), ' orden=', coalesce(v_orden::text, 'no')), true);
    return;
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);

  -- ---- 1. el admin registra el pdf y un envío ----
  insert into ordenes_pdf (orden_id, tipo, ruta, generado_por)
    values (v_orden, 'cliente', 'expedientes/x/OS-1-cliente.pdf', 'admin@prueba')
    on conflict (orden_id, tipo) do update set ruta = excluded.ruta, generado_en = now();
  insert into envios_orden (orden_id, ruta, semana, destinatarios, enviado_por)
    values (v_orden, 'enviados/2026-W01/OS-1-x.pdf', '2026-W01',
            jsonb_build_array(jsonb_build_object('nombre', 'Rosa Prueba', 'telefono', '9990000000')), 'admin@prueba');
  select count(*) into v_n from ordenes_pdf where orden_id = v_orden and tipo = 'cliente';
  v_res := concat(v_res, case when v_n = 1 then '1 ok: el admin registra el pdf generado y un envío, con destinatarios'
    else concat('1 FALLO: filas=', v_n) end, E'\n');

  -- ---- 2. regenerar el mismo tipo reemplaza, no duplica ----
  insert into ordenes_pdf (orden_id, tipo, ruta, generado_por)
    values (v_orden, 'cliente', 'expedientes/x/OS-1-cliente-v2.pdf', 'admin@prueba')
    on conflict (orden_id, tipo) do update set ruta = excluded.ruta, generado_en = now();
  select count(*), max(ruta) into v_n, v_txt from ordenes_pdf where orden_id = v_orden and tipo = 'cliente';
  v_res := concat(v_res, case when v_n = 1 and v_txt like '%v2%'
    then '2 ok: regenerar el mismo tipo reemplaza la fila, no la duplica'
    else concat('2 FALLO: filas=', v_n, ' ruta=', v_txt) end, E'\n');

  -- ---- 3. un técnico no ve nada ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_tec, 'role', 'authenticated', 'email', 'tec@prueba')::text, true);
  select count(*) into v_n from ordenes_pdf where orden_id = v_orden;
  v_res := concat(v_res, case when v_n = 0 then '3 ok: un técnico no ve el pdf ni el envío'
    else concat('3 FALLO: ve ', v_n, ' filas') end, E'\n');

  -- ---- 4. un técnico no puede registrar nada ----
  v_txt := '';
  begin
    insert into ordenes_pdf (orden_id, tipo, ruta, generado_por) values (v_orden, 'interno', 'x', 'tec@prueba');
    v_txt := 'insertó un pdf ';
  exception when insufficient_privilege then null; end;
  begin
    insert into envios_orden (orden_id, ruta, semana, enviado_por) values (v_orden, 'x', '2026-W01', 'tec@prueba');
    v_txt := v_txt || 'insertó un envío';
  exception when insufficient_privilege then null; end;
  v_res := concat(v_res, case when v_txt = '' then '4 ok: un técnico no puede registrar un pdf ni un envío'
    else concat('4 FALLO: ', v_txt) end, E'\n');

  -- ---- 5. "enviar al cerrar": el admin la marca; un técnico no toca ninguna fila ----
  -- El técnico no tiene NINGUNA política de UPDATE sobre ordenes_servicio (fase 1e): RLS no lanza
  -- un error en ese caso, solo excluye la fila del UPDATE (0 filas afectadas, sin excepción). Por
  -- eso aquí se cuenta row_count en vez de esperar una excepción, a diferencia de un intento que sí
  -- ve la fila pero falla el WITH CHECK (por ejemplo, el paso 6 de la prueba de la 19).
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);
  update ordenes_servicio set enviar_al_cerrar = true where id = v_orden;
  perform set_config('request.jwt.claims', json_build_object('sub', v_tec, 'role', 'authenticated', 'email', 'tec@prueba')::text, true);
  update ordenes_servicio set enviar_al_cerrar = false where id = v_orden;
  get diagnostics v_n = row_count;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);
  declare v_marca boolean;
  begin
    select enviar_al_cerrar into v_marca from ordenes_servicio where id = v_orden;
    v_res := concat(v_res, case when v_n = 0 and v_marca
      then '5 ok: el admin marca "enviar al cerrar"; el técnico no toca ninguna fila'
      else concat('5 FALLO: filas que tocó el técnico=', v_n, ' marca=', v_marca) end);
  end;

  perform set_config('app.res', v_res, true);
end $$;

select unnest(string_to_array(current_setting('app.res', true), E'\n')) as resultado;

rollback;
