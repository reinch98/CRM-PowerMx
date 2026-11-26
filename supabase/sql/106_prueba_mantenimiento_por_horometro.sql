-- Prueba del 106 (con rollback). Correr con la CLI:
--   npx supabase db query --linked -f supabase/sql/106_prueba_mantenimiento_por_horometro.sql
-- Lleva un bloque `do`: en el editor web no (lo mutila). Cualquier paso que falle lanza la excepción.
begin;
create temp table r106 (paso int, resultado text);
grant all on r106 to authenticated;

do $$
declare
  v_admin uuid := (select id from perfiles where rol = 'admin' and activo limit 1);
  v_tec   uuid := (select id from perfiles where rol = 'tecnico' and activo limit 1);
  v_cl uuid := gen_random_uuid();
  v_eq uuid := gen_random_uuid();
  v_os uuid := gen_random_uuid();
  v_hoy date := _hoy_merida();
  v_p jsonb; v_r jsonb; v_x jsonb; v_e equipos%rowtype; v_ok boolean;
begin
  insert into clientes (id, nombre, telefono) values (v_cl, 'Prueba 106', '9990000106');
  insert into equipos (id, cliente_id, tipo, marca, capacidad_kw, en_poliza, estado, atributos,
                       ultimo_mantenimiento, ultimo_mantenimiento_horas, horas_uso, horas_uso_fecha,
                       proximo_mantenimiento)
  values (v_eq, v_cl, 'generador', 'Generac', 22, false, 'activo', '{"enfriamiento":"air_cooled"}',
          v_hoy - 190, 100, 100, v_hoy - 190, v_hoy - 7);

  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- 1: a los 6 meses sale para preguntar el horómetro (aunque venció en otro mes).
  v_p := programacion_mensual(v_hoy);
  v_x := (select s from jsonb_array_elements(v_p -> 'sugeridos') s where s ->> 'equipo_id' = v_eq::text);
  if v_x ->> 'motivo' is distinct from 'revisar_horometro' or (v_x ->> 'intervalo_horas')::int <> 100 then
    raise exception 'paso 1: %', v_x;
  end if;
  insert into r106 values (1, 'ok: revisar_horometro, 100 h');

  -- 2: el cliente reporta 150 h (50 desde el servicio): no llega, se vuelve a preguntar en 3 meses.
  v_r := registrar_horometro(v_eq, 150);
  if v_r ->> 'motivo' <> 'revisar_horometro' or (v_r ->> 'horas_desde')::numeric <> 50
     or (v_r ->> 'proximo')::date <> least((v_hoy + interval '3 months')::date, (v_hoy - 190 + interval '12 months')::date) then
    raise exception 'paso 2: %', v_r;
  end if;
  insert into r106 values (2, 'ok: 50 de 100 h, próximo ' || (v_r ->> 'proximo'));

  -- 3: con el próximo en 3 meses ya no sale este mes.
  v_p := programacion_mensual(v_hoy);
  if exists (select 1 from jsonb_array_elements(v_p -> 'sugeridos') s where s ->> 'equipo_id' = v_eq::text) then
    raise exception 'paso 3: sigue en la lista';
  end if;
  insert into r106 values (3, 'ok: sale de la lista');

  -- 4: reporta 205 h: ya llegó, toca hoy y vuelve a la lista con motivo horas.
  v_r := registrar_horometro(v_eq, 205);
  v_p := programacion_mensual(v_hoy);
  v_x := (select s from jsonb_array_elements(v_p -> 'sugeridos') s where s ->> 'equipo_id' = v_eq::text);
  if v_r ->> 'motivo' <> 'horas' or (v_r ->> 'proximo')::date <> v_hoy or v_x ->> 'motivo' <> 'horas' then
    raise exception 'paso 4: % / %', v_r, v_x;
  end if;
  insert into r106 values (4, 'ok: 105 h, toca hoy');

  -- 5: un técnico no puede anotar horómetro.
  perform set_config('request.jwt.claims', json_build_object('sub', v_tec, 'role', 'authenticated')::text, true);
  v_ok := false;
  begin
    perform registrar_horometro(v_eq, 300);
  exception when insufficient_privilege then v_ok := true;
  end;
  if not v_ok then raise exception 'paso 5: el técnico pudo anotar'; end if;
  insert into r106 values (5, 'ok: técnico rechazado');

  -- 6: cerrar una orden preventiva guarda el último mantenimiento y el próximo a 6 meses.
  reset role;
  insert into ordenes_servicio (id, cliente_id, equipo_id, fecha, tipo_servicio, estado)
  values (v_os, v_cl, v_eq, v_hoy, 'preventivo', 'abierta');
  update ordenes_servicio set estado = 'cerrada', horas_equipo = 210 where id = v_os;
  v_e := (select e from equipos e where e.id = v_eq);
  if v_e.ultimo_mantenimiento <> v_hoy or v_e.ultimo_mantenimiento_horas <> 210
     or v_e.proximo_mantenimiento <> (v_hoy + interval '6 months')::date or v_e.horas_uso <> 210 then
    raise exception 'paso 6: % % % %', v_e.ultimo_mantenimiento, v_e.ultimo_mantenimiento_horas,
      v_e.proximo_mantenimiento, v_e.horas_uso;
  end if;
  insert into r106 values (6, 'ok: último ' || v_e.ultimo_mantenimiento || ' a 210 h, próximo ' || v_e.proximo_mantenimiento);

  -- 7: a los 12 meses toca aunque no llegue a las horas.
  update equipos set ultimo_mantenimiento = v_hoy - 370, horas_uso_fecha = v_hoy - 370 where id = v_eq;
  v_e := (select e from equipos e where e.id = v_eq);
  if _mantenimiento_equipo(v_e, v_hoy) ->> 'motivo' <> 'tiempo_maximo' then
    raise exception 'paso 7: %', _mantenimiento_equipo(v_e, v_hoy);
  end if;
  insert into r106 values (7, 'ok: tiempo_maximo');
end $$;

select paso, resultado from r106 order by paso;
rollback;
