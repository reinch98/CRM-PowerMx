-- Prueba de la 28 (correr DESPUÉS de la 28; el bloque COMPLETO). Termina en rollback.
--
-- Todos los pasos deben decir "ok":
--  1 la tarifa se elige por clase y tramo de kW, con precio fijo
--  2 un equipo de otra capacidad cae en otro tramo
--  3 el paquete general (clase + tramo) trae sus líneas
--  4 el paquete del MODELO exacto gana sobre el general
--  5 una línea ofrece el original y su genérico, con lo disponible de cada uno
--  6 el preferido sale primero aunque tenga menos existencia
--  7 sin combustible capturado lo dice con todas sus letras
--  8 sin tarifa para esa clase lo dice y no inventa precio
--  9 el gas natural se cobra como gas LP
-- 10 un técnico no puede leer paquetes ni llamar la función
begin;

select set_config('app.res', 'la prueba no llegó al final (revisa si hubo un error arriba)', true);

do $$
declare
  v_admin uuid; v_tec uuid; v_cli uuid;
  eq_22 uuid; eq_300 uuid; eq_modelo uuid; eq_sin uuid; eq_gn uuid; eq_solar uuid;
  p_gen uuid; p_mod uuid;
  prod_orig uuid; prod_gen uuid;
  r jsonb; v_res text := ''; v_txt text;
  v_n int; v_lin jsonb; v_op jsonb;
begin
  select id into v_admin from perfiles where rol = 'admin' and coalesce(activo, true) limit 1;
  select id into v_tec from perfiles where rol = 'tecnico' and coalesce(activo, true) limit 1;
  if v_admin is null or v_tec is null then
    perform set_config('app.res', concat('SIN DATOS: admin=', coalesce(v_admin::text, 'no'),
      ' tecnico=', coalesce(v_tec::text, 'no')), true);
    return;
  end if;

  insert into clientes (nombre, telefono) values ('Cliente 28', '999 000 0280') returning id into v_cli;

  -- Equipos: mismo diésel en dos capacidades, uno con modelo propio, uno sin combustible,
  -- uno de gas natural y uno solar (para el paso 8).
  insert into equipos (cliente_id, numero_serie, tipo, marca, modelo, capacidad_kw, atributos)
  values (v_cli, 'SER-28-A', 'generador', 'Generac', 'SD022', 22, '{"combustible":"diesel"}'::jsonb)
  returning id into eq_22;
  insert into equipos (cliente_id, numero_serie, tipo, marca, capacidad_kw, atributos)
  values (v_cli, 'SER-28-B', 'generador', 'Cummins', 300, '{"combustible":"diesel"}'::jsonb)
  returning id into eq_300;
  insert into equipos (cliente_id, numero_serie, tipo, marca, modelo, capacidad_kw, atributos)
  values (v_cli, 'SER-28-C', 'generador', 'Kohler', 'KG40', 40, '{"combustible":"diesel"}'::jsonb)
  returning id into eq_modelo;
  insert into equipos (cliente_id, numero_serie, tipo, marca, capacidad_kw, atributos)
  values (v_cli, 'SER-28-D', 'generador', 'Onan', 25, '{}'::jsonb)
  returning id into eq_sin;
  insert into equipos (cliente_id, numero_serie, tipo, marca, capacidad_kw, atributos)
  values (v_cli, 'SER-28-E', 'generador', 'Generac', 22, '{"combustible":"gas_natural"}'::jsonb)
  returning id into eq_gn;
  insert into equipos (cliente_id, numero_serie, tipo, marca, capacidad_kw)
  values (v_cli, 'SER-28-F', 'solar', 'Huawei', 10)
  returning id into eq_solar;

  -- Tarifas: diésel chico y diésel grande, y gas LP chico.
  insert into tarifas_servicio (concepto, clase, kw_desde, kw_hasta, precio, sku, nombre, activo)
  values ('preventivo_menor', 'diesel', 0, 100, 4500, 'SRV-PMEN-DSL-CH', 'Mantenimiento menor diésel hasta 100 kW', true),
         ('preventivo_menor', 'diesel', 101, 600, 9800, 'SRV-PMEN-DSL-GR', 'Mantenimiento menor diésel 101-600 kW', true),
         ('preventivo_menor', 'gas_lp', 0, 100, 4200, 'SRV-PMEN-GLP-CH', 'Mantenimiento menor gas hasta 100 kW', true);

  -- Productos: un filtro original y su genérico, con el mismo grupo.
  insert into productos (sku, nombre, categoria, precio, unidad, grupo_equivalente)
  values ('FIL-ORIG-1', 'Filtro de aceite Perkins', 'refacciones', 320, 'pieza', 'FILTRO-ACEITE-P554407')
  returning id into prod_orig;
  insert into productos (sku, nombre, categoria, precio, unidad, grupo_equivalente)
  values ('FIL-GEN-1', 'Filtro de aceite genérico', 'refacciones', 180, 'pieza', 'FILTRO-ACEITE-P554407')
  returning id into prod_gen;
  -- El genérico tiene más existencia que el original.
  insert into movimientos_inventario (producto_id, tipo, cantidad, referencia)
  values (prod_orig, 'entrada', 2, 'PRUEBA-28'), (prod_gen, 'entrada', 10, 'PRUEBA-28');

  -- Paquete general para diésel hasta 100 kW, y uno específico del modelo KG40.
  insert into paquetes_mantenimiento (tipo, clase, kw_desde, kw_hasta, nombre)
  values ('menor', 'diesel', 0, 100, 'Menor diésel chico') returning id into p_gen;
  insert into paquete_lineas (paquete_id, descripcion, producto_id, cantidad, orden)
  values (p_gen, 'Filtro de aceite', prod_orig, 1, 1);

  insert into paquetes_mantenimiento (tipo, clase, kw_desde, kw_hasta, marca, modelo, nombre)
  values ('menor', 'diesel', 0, 100, 'Kohler', 'KG40', 'Menor KG40') returning id into p_mod;
  insert into paquete_lineas (paquete_id, descripcion, producto_id, cantidad, orden)
  values (p_mod, 'Filtro de aceite del KG40', prod_orig, 2, 1);

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated', 'email', 'admin@prueba')::text, true);

  -- ---- 1. tarifa por clase y tramo ----
  r := paquete_preventivo(eq_22, 'menor');
  v_res := concat(v_res, case when (r #>> '{servicio,sku}') = 'SRV-PMEN-DSL-CH'
                              and (r #>> '{servicio,precio}') = '4500'
    then '1 ok: la tarifa sale por clase y tramo, con precio fijo'
    else concat('1 FALLO: ', r -> 'servicio') end, E'\n');

  -- ---- 2. otro tramo ----
  r := paquete_preventivo(eq_300, 'menor');
  v_res := concat(v_res, case when (r #>> '{servicio,sku}') = 'SRV-PMEN-DSL-GR'
    then '2 ok: otra capacidad cae en otro tramo'
    else concat('2 FALLO: ', r -> 'servicio') end, E'\n');

  -- ---- 3. paquete general ----
  r := paquete_preventivo(eq_22, 'menor');
  v_res := concat(v_res, case when (r #>> '{paquete,paquete_id}')::uuid = p_gen
                              and jsonb_array_length(r -> 'lineas') = 1
    then '3 ok: el paquete general trae sus líneas'
    else concat('3 FALLO: ', r -> 'paquete') end, E'\n');

  -- ---- 4. gana el del modelo ----
  r := paquete_preventivo(eq_modelo, 'menor');
  v_res := concat(v_res, case when (r #>> '{paquete,paquete_id}')::uuid = p_mod
    then '4 ok: el paquete del modelo exacto gana sobre el general'
    else concat('4 FALLO: ', r -> 'paquete') end, E'\n');

  -- ---- 5 y 6. opciones y orden ----
  r := paquete_preventivo(eq_22, 'menor');
  v_lin := r -> 'lineas' -> 0;
  v_op := v_lin -> 'opciones';
  v_res := concat(v_res, case when jsonb_array_length(v_op) = 2
                              and (v_op -> 0 ->> 'disponible') = '2'
                              and (v_op -> 1 ->> 'disponible') = '10'
    then '5 ok: la línea ofrece el original y su genérico con lo disponible de cada uno'
    else concat('5 FALLO: ', v_op) end, E'\n');
  v_res := concat(v_res, case when (v_op -> 0 ->> 'preferido') = 'true'
                              and (v_op -> 0 ->> 'sku') = 'FIL-ORIG-1'
    then '6 ok: el preferido sale primero aunque tenga menos existencia'
    else concat('6 FALLO: ', v_op -> 0) end, E'\n');

  -- ---- 7. sin combustible ----
  r := paquete_preventivo(eq_sin, 'menor');
  v_res := concat(v_res, case when (r ->> 'falta') like '%combustible%' and r -> 'servicio' is null
    then '7 ok: sin combustible capturado lo dice y no inventa precio'
    else concat('7 FALLO: ', r) end, E'\n');

  -- ---- 8. sin tarifa para esa clase ----
  r := paquete_preventivo(eq_solar, 'menor');
  v_res := concat(v_res, case when (r ->> 'falta') like '%tarifa%' and r -> 'servicio' is null
    then '8 ok: sin tarifa para esa clase lo dice y no inventa precio'
    else concat('8 FALLO: ', r) end, E'\n');

  -- ---- 9. gas natural = gas LP ----
  r := paquete_preventivo(eq_gn, 'menor');
  v_res := concat(v_res, case when (r ->> 'clase') = 'gas_lp'
                              and (r #>> '{servicio,sku}') = 'SRV-PMEN-GLP-CH'
    then '9 ok: el gas natural se cobra como gas LP'
    else concat('9 FALLO: clase=', r ->> 'clase', ' tarifa=', r -> 'servicio') end, E'\n');

  -- ---- 10. el técnico ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_tec, 'role', 'authenticated', 'email', 'tec@prueba')::text, true);
  select count(*) into v_n from paquetes_mantenimiento;
  v_txt := '';
  begin perform paquete_preventivo(eq_22, 'menor'); v_txt := 'llamó la función';
  exception when sqlstate '42501' then null; end;
  v_res := concat(v_res, case when v_n = 0 and v_txt = ''
    then '10 ok: un técnico no ve paquetes ni llama la función'
    else concat('10 FALLO: ve ', v_n, ' paquetes; ', v_txt) end);

  perform set_config('app.res', v_res, true);
end $$;

reset role;
select current_setting('app.res', true) as resultado;

rollback;
