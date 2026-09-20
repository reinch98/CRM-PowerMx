-- ===========================================================================
-- FLUJO DE SERVICIO · FASE 1c · AGENDA
--
-- La Agenda deja de insertar en `citas` desde el navegador. Cada cita nace con su
-- orden de servicio (1 : 1), y esto ocurre en una sola operación:
--
--   agendar_cita     cita nueva + su orden.
--                    · diagnóstico: crea una cotización de diagnóstico, o se enlaza a una;
--                    · póliza (equipo en póliza + preventivo): solo cita y orden;
--                    · otros tipos: cotización opcional.
--   programar_cita   pone fecha, hora, duración y técnicos a una cita "por programar",
--                    o reprograma / reasigna una ya programada. La orden la sigue.
--   cancelar_cita    cancela la cita y su orden, si nadie ha capturado trabajo.
--   lista_tecnicos   id y nombre de los técnicos activos (un técnico no puede leer el
--                    perfil de su compañero, pero necesita ver el nombre de su ayudante).
--
-- Al agendar o programar se avisa si un técnico ya tiene otra cita que se empalma; no
-- se bloquea: se devuelve la lista y se vuelve a llamar con p_confirmar = true.
--
-- Solo admin (lista_tecnicos también la usa el técnico). Corren con los permisos de quien
-- las llama, así que las políticas por rol siguen aplicando debajo.
-- Se puede volver a ejecutar sin problema.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Técnicos activos: solo id y nombre.
-- ---------------------------------------------------------------------------
create or replace function lista_tecnicos()
returns table (id uuid, nombre text)
language sql stable security definer set search_path = public as $$
  select p.id, coalesce(p.nombre, p.email)
  from perfiles p
  where p.rol = 'tecnico' and p.activo and mi_rol() in ('admin', 'tecnico')
  order by 2
$$;

revoke all on function lista_tecnicos() from public, anon;
grant execute on function lista_tecnicos() to authenticated;

-- ---------------------------------------------------------------------------
-- Citas programadas de T1 o T2 que se empalman con este horario. Sin hora, o sin
-- técnicos, no hay nada que comparar.
-- ---------------------------------------------------------------------------
create or replace function empalmes_de(
  p_fecha date, p_hora time, p_dur integer, p_t1 uuid, p_t2 uuid, p_excluir uuid default null
) returns jsonb
language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'cita_id', ci.id,
      'hora', ci.hora,
      'cliente', cl.nombre,
      'tecnicos', (select string_agg(coalesce(pf.nombre, pf.email), ', ')
                     from perfiles pf
                    where pf.id in (ci.tecnico_id, ci.tecnico2_id)
                      and pf.id in (p_t1, p_t2)))), '[]'::jsonb)
  from citas ci
  join clientes cl on cl.id = ci.cliente_id
  where p_fecha is not null and p_hora is not null
    and ci.fecha = p_fecha
    and ci.estado = 'programada'
    and ci.hora is not null
    and (p_excluir is null or ci.id <> p_excluir)
    and (ci.tecnico_id in (p_t1, p_t2) or ci.tecnico2_id in (p_t1, p_t2))
    and ci.hora < (p_hora + make_interval(mins => coalesce(p_dur, 120)))
    and p_hora < (ci.hora + make_interval(mins => coalesce(ci.duracion_min, 120)))
$$;

-- ---------------------------------------------------------------------------
-- AGENDAR: cita nueva + su orden (+ cotización de diagnóstico, si toca).
-- p_nueva_cotizacion: { partidas, subtotal, iva, total, condiciones } ya calculado por
-- el CRM (los precios salen de tarifas_servicio y se COPIAN aquí).
-- ---------------------------------------------------------------------------
create or replace function agendar_cita(
  p_cliente uuid,
  p_equipo uuid,
  p_tipo text,
  p_fecha date,
  p_hora time,
  p_duracion integer,
  p_t1 uuid,
  p_t2 uuid,
  p_zona text,
  p_notas text,
  p_cotizacion uuid default null,
  p_nueva_cotizacion jsonb default null,
  p_confirmar boolean default false
) returns jsonb
language plpgsql
set search_path = public
as $$
declare
  hoy date := (now() at time zone 'America/Mexico_City')::date;   -- el servidor está en UTC
  quien text := coalesce(auth.jwt() ->> 'email', 'crm');
  v_empalmes jsonb;
  v_poliza boolean := false;
  v_origen text;
  v_cita citas%rowtype;
  v_cot_id uuid := p_cotizacion;
  v_cot_folio int;
  v_orden uuid;
  v_orden_folio int;
begin
  if not es_admin() then
    raise exception 'Solo el administrador puede agendar citas.' using errcode = '42501';
  end if;
  if p_cliente is null then raise exception 'Falta el cliente.' using errcode = '22023'; end if;
  if p_fecha is null then raise exception 'Falta la fecha.' using errcode = '22023'; end if;
  if p_tipo not in ('preventivo', 'correctivo', 'instalacion', 'diagnostico', 'visita_tecnica') then
    raise exception 'Tipo de servicio no válido: %', p_tipo using errcode = '22023';
  end if;
  if p_t2 is not null and p_t1 is null then
    raise exception 'Elige al técnico responsable antes que a su ayudante.' using errcode = '22023';
  end if;
  if p_t1 is not null and p_t1 = p_t2 then
    raise exception 'El responsable y su ayudante no pueden ser la misma persona.' using errcode = '22023';
  end if;
  if p_t1 is not null and not exists (select 1 from perfiles where id = p_t1 and rol = 'tecnico' and activo) then
    raise exception 'El técnico responsable no es un técnico activo.' using errcode = '22023';
  end if;
  if p_t2 is not null and not exists (select 1 from perfiles where id = p_t2 and rol = 'tecnico' and activo) then
    raise exception 'El ayudante no es un técnico activo.' using errcode = '22023';
  end if;
  if p_equipo is not null and not exists (select 1 from equipos where id = p_equipo and cliente_id = p_cliente) then
    raise exception 'Ese equipo no es del cliente elegido.' using errcode = '22023';
  end if;
  if p_cotizacion is not null and not exists (select 1 from cotizaciones where id = p_cotizacion and cliente_id = p_cliente) then
    raise exception 'Esa cotización no es del cliente elegido.' using errcode = '22023';
  end if;

  v_empalmes := empalmes_de(p_fecha, p_hora, p_duracion, p_t1, p_t2, null);
  if jsonb_array_length(v_empalmes) > 0 and not p_confirmar then
    return jsonb_build_object('ok', false, 'motivo', 'empalme', 'empalmes', v_empalmes);
  end if;

  -- Póliza: mantenimiento preventivo de un equipo en póliza. Solo cita y orden.
  if p_tipo = 'preventivo' and p_equipo is not null then
    select coalesce(en_poliza, false) into v_poliza from equipos where id = p_equipo;
  end if;
  v_origen := case when v_poliza then 'poliza' else 'agenda' end;

  -- Diagnóstico: cotización de diagnóstico, nueva o enlazada.
  if p_tipo = 'diagnostico' and v_cot_id is null then
    insert into cotizaciones
      (cliente_id, equipo_id, fecha, tipo, partidas, subtotal, descuento, iva, total,
       requiere_visita, condiciones, notas_internas, estado, creada_por,
       prog_fecha, prog_hora, prog_duracion_min, prog_tecnico_id, prog_tecnico2_id)
    values
      (p_cliente, p_equipo, hoy, 'diagnostico',
       coalesce(p_nueva_cotizacion -> 'partidas', '[]'::jsonb),
       coalesce((p_nueva_cotizacion ->> 'subtotal')::numeric, 0), 0,
       coalesce((p_nueva_cotizacion ->> 'iva')::numeric, 0),
       coalesce((p_nueva_cotizacion ->> 'total')::numeric, 0),
       true, p_nueva_cotizacion ->> 'condiciones',
       'Creada desde una cita de diagnóstico del ' || p_fecha,
       'borrador', quien,
       p_fecha, p_hora, p_duracion, p_t1, p_t2)
    returning id, folio into v_cot_id, v_cot_folio;
  elsif v_cot_id is not null then
    select folio into v_cot_folio from cotizaciones where id = v_cot_id;
  end if;

  insert into citas
    (cliente_id, equipo_id, tipo_servicio, fecha, hora, duracion_min,
     tecnico_id, tecnico2_id, tecnico, zona, notas, estado, origen, cotizacion_id)
  values
    (p_cliente, p_equipo, p_tipo, p_fecha, p_hora, p_duracion,
     p_t1, p_t2, (select nombre from perfiles where id = p_t1),
     coalesce(nullif(p_zona, ''), (select zona from clientes where id = p_cliente)),
     nullif(p_notas, ''), 'programada', v_origen, v_cot_id)
  returning * into v_cita;

  insert into ordenes_servicio
    (cliente_id, equipo_id, cita_id, fecha, tipo_servicio, tecnico_id, tecnico2_id, tecnico, estado)
  values
    (v_cita.cliente_id, v_cita.equipo_id, v_cita.id, v_cita.fecha, v_cita.tipo_servicio,
     v_cita.tecnico_id, v_cita.tecnico2_id, v_cita.tecnico, 'abierta')
  returning id, folio into v_orden, v_orden_folio;

  return jsonb_build_object(
    'ok', true,
    'cita_id', v_cita.id,
    'origen', v_origen,
    'orden_id', v_orden,
    'orden_folio', v_orden_folio,
    'cotizacion_id', v_cot_id,
    'cotizacion_folio', v_cot_folio,
    'cotizacion_nueva', (p_tipo = 'diagnostico' and p_cotizacion is null),
    'empalmes', v_empalmes
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- PROGRAMAR / REPROGRAMAR / REASIGNAR una cita existente.
-- ---------------------------------------------------------------------------
create or replace function programar_cita(
  p_cita uuid,
  p_fecha date,
  p_hora time,
  p_duracion integer,
  p_t1 uuid,
  p_t2 uuid,
  p_confirmar boolean default false
) returns jsonb
language plpgsql
set search_path = public
as $$
declare
  ci citas%rowtype;
  v_orden ordenes_servicio%rowtype;
  v_hay_orden boolean;
  v_con_trabajo boolean := false;
  v_cambia boolean;
  v_empalmes jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador puede programar citas.' using errcode = '42501';
  end if;

  select * into ci from citas where id = p_cita for update;
  if not found then raise exception 'La cita no existe.' using errcode = 'P0002'; end if;
  if ci.estado in ('realizada', 'cancelada') then
    raise exception 'La cita ya está %: no se puede programar.', ci.estado using errcode = '22023';
  end if;
  if p_fecha is null then raise exception 'Falta la fecha.' using errcode = '22023'; end if;
  if p_t2 is not null and p_t1 is null then
    raise exception 'Elige al técnico responsable antes que a su ayudante.' using errcode = '22023';
  end if;
  if p_t1 is not null and p_t1 = p_t2 then
    raise exception 'El responsable y su ayudante no pueden ser la misma persona.' using errcode = '22023';
  end if;
  if p_t1 is not null and not exists (select 1 from perfiles where id = p_t1 and rol = 'tecnico' and activo) then
    raise exception 'El técnico responsable no es un técnico activo.' using errcode = '22023';
  end if;
  if p_t2 is not null and not exists (select 1 from perfiles where id = p_t2 and rol = 'tecnico' and activo) then
    raise exception 'El ayudante no es un técnico activo.' using errcode = '22023';
  end if;

  v_empalmes := empalmes_de(p_fecha, p_hora, p_duracion, p_t1, p_t2, ci.id);

  select * into v_orden from ordenes_servicio where cita_id = ci.id;
  v_hay_orden := found;
  if v_hay_orden then
    v_con_trabajo := coalesce(v_orden.trabajos_realizados, '') <> ''
      or exists (select 1 from orden_partes where orden_id = v_orden.id);
  end if;
  v_cambia := (p_t1 is distinct from ci.tecnico_id) or (p_t2 is distinct from ci.tecnico2_id);

  -- Cambiar de técnico una orden que ya tiene trabajo capturado deja a quien la llenó
  -- sin acceso: se pide confirmar.
  if not p_confirmar and (jsonb_array_length(v_empalmes) > 0 or (v_con_trabajo and v_cambia and ci.tecnico_id is not null)) then
    return jsonb_build_object('ok', false,
      'motivo', case when jsonb_array_length(v_empalmes) > 0 then 'empalme' else 'trabajo' end,
      'empalmes', v_empalmes,
      'orden_con_trabajo', v_con_trabajo and v_cambia and ci.tecnico_id is not null);
  end if;

  update citas
     set fecha = p_fecha, hora = p_hora,
         duracion_min = coalesce(p_duracion, duracion_min),
         tecnico_id = p_t1, tecnico2_id = p_t2,
         tecnico = (select nombre from perfiles where id = p_t1),
         estado = 'programada'
   where id = ci.id;

  -- La orden abierta sigue a la cita.
  update ordenes_servicio
     set fecha = p_fecha, tecnico_id = p_t1, tecnico2_id = p_t2,
         tecnico = (select nombre from perfiles where id = p_t1)
   where cita_id = ci.id and estado = 'abierta';

  return jsonb_build_object('ok', true, 'cita_id', ci.id, 'anterior', ci.estado,
                            'empalmes', v_empalmes, 'orden_folio', v_orden.folio);
end;
$$;

-- ---------------------------------------------------------------------------
-- CANCELAR una cita y su orden. Si ya hay trabajo capturado no se cancela.
-- ---------------------------------------------------------------------------
create or replace function cancelar_cita(p_cita uuid) returns jsonb
language plpgsql
set search_path = public
as $$
declare
  ci citas%rowtype;
  v_orden ordenes_servicio%rowtype;
  v_hay_orden boolean;
  v_con_trabajo boolean := false;
  v_cot int;
begin
  if not es_admin() then
    raise exception 'Solo el administrador puede cancelar citas.' using errcode = '42501';
  end if;

  select * into ci from citas where id = p_cita for update;
  if not found then raise exception 'La cita no existe.' using errcode = 'P0002'; end if;
  if ci.estado = 'cancelada' then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;
  if ci.estado = 'realizada' then
    raise exception 'La cita ya se realizó: no se puede cancelar.' using errcode = '22023';
  end if;

  select * into v_orden from ordenes_servicio where cita_id = ci.id;
  v_hay_orden := found;
  if v_hay_orden then
    v_con_trabajo := coalesce(v_orden.trabajos_realizados, '') <> ''
      or exists (select 1 from orden_partes where orden_id = v_orden.id);
  end if;

  if v_con_trabajo then
    return jsonb_build_object('ok', false, 'motivo', 'trabajo', 'orden_folio', v_orden.folio);
  end if;

  update citas set estado = 'cancelada' where id = ci.id;
  update ordenes_servicio set estado = 'cancelada' where cita_id = ci.id and estado = 'abierta';

  select folio into v_cot from cotizaciones where id = ci.cotizacion_id;
  return jsonb_build_object('ok', true, 'orden_folio', v_orden.folio, 'cotizacion_folio', v_cot);
end;
$$;

revoke all on function empalmes_de(date, time, integer, uuid, uuid, uuid) from public, anon;
revoke all on function agendar_cita(uuid, uuid, text, date, time, integer, uuid, uuid, text, text, uuid, jsonb, boolean) from public, anon;
revoke all on function programar_cita(uuid, date, time, integer, uuid, uuid, boolean) from public, anon;
revoke all on function cancelar_cita(uuid) from public, anon;
grant execute on function empalmes_de(date, time, integer, uuid, uuid, uuid) to authenticated;
grant execute on function agendar_cita(uuid, uuid, text, date, time, integer, uuid, uuid, text, text, uuid, jsonb, boolean) to authenticated;
grant execute on function programar_cita(uuid, date, time, integer, uuid, uuid, boolean) to authenticated;
grant execute on function cancelar_cita(uuid) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- PRUEBA (begin/rollback SÍ deshace; solo se ve el resultado de la ÚLTIMA sentencia, por
-- eso cada paso se guarda con set_config). Correr SIEMPRE el bloque completo.
-- Necesitas: el uuid de un admin, de un cliente y de dos técnicos.
--
--   begin;
--   set local role authenticated;
--   select set_config('request.jwt.claims',
--     json_build_object('sub', '<UUID-ADMIN>', 'role', 'authenticated', 'email', 'prueba@powermx')::text, true);
--
--   select set_config('app.a', agendar_cita('<UUID-CLIENTE>', null, 'correctivo', current_date + 5,
--       '09:00', 120, '<UUID-T1>', '<UUID-T2>', null, 'prueba')::text, true);
--   -- mismo horario y mismo técnico: debe avisar del empalme y NO crear nada
--   select set_config('app.b', agendar_cita('<UUID-CLIENTE>', null, 'correctivo', current_date + 5,
--       '10:00', 60, '<UUID-T1>', null, null, 'prueba')::text, true);
--   -- diagnóstico: crea también la cotización
--   select set_config('app.c', agendar_cita('<UUID-CLIENTE>', null, 'diagnostico', current_date + 6,
--       '09:00', 90, '<UUID-T2>', null, null, 'prueba', null,
--       '{"partidas":[{"descripcion":"Diagnóstico","cantidad":1,"precio_unitario":1000,"importe":1000}],"subtotal":1000,"iva":160,"total":1160}'::jsonb)::text, true);
--   select set_config('app.d', cancelar_cita((current_setting('app.a')::jsonb ->> 'cita_id')::uuid)::text, true);
--
--   select current_setting('app.a')::jsonb as agendar,        -- ok true, orden_folio
--          current_setting('app.b')::jsonb as empalme,        -- ok false, motivo 'empalme', 1 empalme
--          current_setting('app.c')::jsonb as diagnostico,    -- cotizacion_nueva true, cotizacion_folio
--          current_setting('app.d')::jsonb as cancelar;       -- ok true
--   rollback;
-- ---------------------------------------------------------------------------
