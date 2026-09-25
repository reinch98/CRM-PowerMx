-- ===========================================================================
-- COMPONENTES DEL EQUIPO DESDE LA OFICINA
--
-- La 25 dejó al técnico guardar la FOTO de la placa desde su orden. Falta el otro lado:
-- que en la oficina se escriban marca, modelo y serie de ese componente —a mano o con lo
-- que leyó el agente de la foto— cuando la orden ya está cerrada.
--
-- El admin puede escribir en `equipos` por RLS, pero el mezclado del arreglo
-- `atributos.componentes` no debe vivir en dos lugares (una vez en SQL y otra en el
-- navegador): se saldrían de sincronía. Así que la 25 se reescribe para que las dos
-- puertas —la del técnico y la de la oficina— usen la MISMA función interna.
--
-- Se puede repetir sin problema. Prueba: 26_prueba_componente_equipo.sql.
-- ===========================================================================

-- Mezcla un componente conservando lo que ya tenía. Interna: nadie la llama de fuera.
create or replace function _fijar_componente(
  p_equipo uuid,
  p_rol text,
  p_datos jsonb default null,
  p_ruta text default null,
  p_origen text default 'campo'
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_previo jsonb; v_nuevo jsonb; v_otros jsonb; v_atrib jsonb;
begin
  if p_rol not in ('modulos', 'inversor_1', 'inversor_2', 'bateria', 'bms',
                   'generador', 'motor', 'alternador', 'tablero') then
    raise exception 'Componente no válido: %', p_rol using errcode = '22023';
  end if;

  select coalesce(atributos, '{}'::jsonb) into v_atrib from equipos where id = p_equipo for update;
  if not found then raise exception 'Ese equipo no existe.' using errcode = 'P0002'; end if;

  select x into v_previo
    from jsonb_array_elements(coalesce(v_atrib -> 'componentes', '[]'::jsonb)) x
   where x ->> 'rol' = p_rol
   limit 1;

  -- Lo que llega solo pisa lo que trae; lo demás se conserva. Un campo vacío se ignora:
  -- si el agente no pudo leer la serie, no debe borrar la que ya estaba.
  v_nuevo := coalesce(v_previo, '{}'::jsonb)
             || jsonb_build_object('rol', p_rol)
             || coalesce((select jsonb_object_agg(k, v)
                            from jsonb_each(coalesce(p_datos, '{}'::jsonb)) as e(k, v)
                           where nullif(trim(coalesce(v #>> '{}', '')), '') is not null),
                         '{}'::jsonb);
  if p_ruta is not null then
    v_nuevo := v_nuevo || jsonb_build_object('foto', p_ruta);
  end if;

  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_otros
    from jsonb_array_elements(coalesce(v_atrib -> 'componentes', '[]'::jsonb)) x
   where x ->> 'rol' <> p_rol;

  update equipos
     set atributos = v_atrib || jsonb_build_object('componentes', v_otros || jsonb_build_array(v_nuevo)),
         updated_at = now()
   where id = p_equipo;

  perform _apunta('equipos', p_equipo, 'componente', v_previo, v_nuevo, p_origen);

  return jsonb_build_object('ok', true, 'equipo_id', p_equipo, 'rol', p_rol,
                            'componente', v_nuevo,
                            'componentes', jsonb_array_length(v_otros) + 1);
end $$;
revoke all on function _fijar_componente(uuid, text, jsonb, text, text) from public, anon, authenticated;

-- El técnico, desde su orden abierta (la de la 25, ahora apoyada en la función de arriba).
create or replace function guardar_placa(
  p_orden uuid,
  p_rol text,
  p_ruta text default null,
  p_datos jsonb default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o ordenes_servicio%rowtype;
begin
  select * into o from ordenes_servicio where id = p_orden;
  if not found then raise exception 'La orden no existe.' using errcode = 'P0002'; end if;
  if not (es_admin() or soy_de_la_orden(p_orden)) then
    raise exception 'Esa orden no es tuya.' using errcode = '42501';
  end if;
  if o.estado <> 'abierta' then
    raise exception 'La orden ya está cerrada.' using errcode = '22023';
  end if;
  if o.equipo_id is null then
    raise exception 'La orden todavía no dice de qué equipo es: elígelo antes de capturar las placas.'
      using errcode = '22023';
  end if;

  return _fijar_componente(o.equipo_id, p_rol, p_datos, p_ruta, 'campo');
end $$;
revoke all on function guardar_placa(uuid, text, text, jsonb) from public, anon;
grant execute on function guardar_placa(uuid, text, text, jsonb) to authenticated;

-- La oficina, sobre cualquier equipo y sin orden de por medio. Aquí es donde se guarda lo
-- que el agente leyó de la foto, DESPUÉS de que una persona lo revisó.
create or replace function actualizar_componente(
  p_equipo uuid,
  p_rol text,
  p_datos jsonb,
  p_origen text default 'oficina'
) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if p_origen not in ('oficina', 'agente') then
    raise exception 'Origen no válido: %', p_origen using errcode = '22023';
  end if;
  return _fijar_componente(p_equipo, p_rol, p_datos, null, p_origen);
end $$;
revoke all on function actualizar_componente(uuid, text, jsonb, text) from public, anon;
grant execute on function actualizar_componente(uuid, text, jsonb, text) to authenticated;

notify pgrst, 'reload schema';
