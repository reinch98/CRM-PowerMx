-- Prueba de la 21 (correr DESPUÉS de la 21; el bloque COMPLETO). Termina en rollback: no deja nada.
-- Usa un admin y un técnico. Si falta alguno, lo dice y no hace nada.
--
-- Todos los pasos deben decir "ok":
--  1 un concepto de catálogo (correctivo) exige sku
--  2 "otro" exige nombre propio
--  3 con sku (y nombre si es "otro") se puede dar de alta
--  4 el mismo sku no se repite
--  5 diagnóstico y traslado siguen sin necesitar sku (no se rompió lo que ya había)
--  6 el técnico sigue sin ver ni escribir tarifas
begin;

select set_config('app.res', 'la prueba no llegó al final (revisa si hubo un error arriba)', true);

do $$
declare
  v_admin uuid; v_tec uuid;
  v_res text := ''; v_txt text;
begin
  select id into v_admin from perfiles where rol = 'admin' and coalesce(activo, true) limit 1;
  select id into v_tec from perfiles where rol = 'tecnico' and coalesce(activo, true) limit 1;

  if v_admin is null or v_tec is null then
    perform set_config('app.res', concat(
      'SIN DATOS: hace falta un admin y un técnico. admin=', coalesce(v_admin::text, 'no'),
      ' tecnico=', coalesce(v_tec::text, 'no')), true);
    return;
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);

  -- ---- 1. correctivo sin sku se rechaza ----
  v_txt := '';
  begin
    insert into tarifas_servicio (concepto, precio) values ('correctivo', 500);
    v_txt := 'aceptó correctivo sin sku';
  exception when check_violation then null; end;
  v_res := concat(v_res, case when v_txt = '' then '1 ok: un concepto de catálogo exige sku'
    else concat('1 FALLO: ', v_txt) end, E'\n');

  -- ---- 2. "otro" sin nombre se rechaza ----
  v_txt := '';
  begin
    insert into tarifas_servicio (concepto, sku, precio) values ('otro', 'SRV-PRUEBA-1', 500);
    v_txt := 'aceptó "otro" sin nombre';
  exception when check_violation then null; end;
  v_res := concat(v_res, case when v_txt = '' then '2 ok: "otro" exige nombre propio'
    else concat('2 FALLO: ', v_txt) end, E'\n');

  -- ---- 3. con sku (y nombre si es "otro") sí se da de alta ----
  insert into tarifas_servicio (concepto, sku, clase, precio, notas)
    values ('correctivo', 'SRV-COR-GAS-PRUEBA', 'gasolina', 850, 'prueba 21');
  insert into tarifas_servicio (concepto, sku, nombre, precio, notas)
    values ('otro', 'SRV-OTRO-PRUEBA', 'Revisión de tablero', 300, 'prueba 21');
  v_res := concat(v_res, case when (select count(*) from tarifas_servicio where sku in ('SRV-COR-GAS-PRUEBA', 'SRV-OTRO-PRUEBA')) = 2
    then '3 ok: correctivo con sku y "otro" con sku y nombre se dan de alta'
    else '3 FALLO: no se insertaron las dos filas' end, E'\n');

  -- ---- 4. el mismo sku no se repite ----
  v_txt := '';
  begin
    insert into tarifas_servicio (concepto, sku, precio) values ('preventivo', 'SRV-COR-GAS-PRUEBA', 900);
    v_txt := 'aceptó un sku repetido';
  exception when unique_violation then null; end;
  v_res := concat(v_res, case when v_txt = '' then '4 ok: el mismo sku no se repite'
    else concat('4 FALLO: ', v_txt) end, E'\n');

  -- ---- 5. diagnóstico y traslado siguen sin necesitar sku ----
  v_txt := '';
  begin
    insert into tarifas_servicio (concepto, clase, kw_desde, kw_hasta, precio) values ('diagnostico', 'gasolina', 1.5, 10, 700);
    insert into tarifas_servicio (concepto, km_desde, precio) values ('traslado', 40, 12);
  exception when others then v_txt := sqlerrm; end;
  v_res := concat(v_res, case when v_txt = '' then '5 ok: diagnóstico y traslado se dan de alta sin sku, como antes'
    else concat('5 FALLO: ', v_txt) end, E'\n');

  -- ---- 6. el técnico sigue sin ver ni escribir tarifas ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_tec, 'role', 'authenticated', 'email', 'tec@prueba')::text, true);
  declare v_n int;
  begin
    select count(*) into v_n from tarifas_servicio;
    v_txt := '';
    begin
      insert into tarifas_servicio (concepto, sku, precio) values ('correctivo', 'SRV-TEC-PRUEBA', 1);
      v_txt := 'el técnico insertó una tarifa';
    exception when insufficient_privilege then null; end;
    v_res := concat(v_res, case when v_n = 0 and v_txt = ''
      then '6 ok: el técnico sigue sin ver ni escribir tarifas'
      else concat('6 FALLO: ve ', v_n, ' filas; ', v_txt) end);
  end;

  perform set_config('app.res', v_res, true);
end $$;

select unnest(string_to_array(current_setting('app.res', true), E'\n')) as resultado;

rollback;
