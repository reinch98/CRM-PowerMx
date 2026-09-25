-- ===========================================================================
-- PLACAS DE IDENTIFICACIÓN POR COMPONENTE
--
-- Un sistema solar no tiene una placa, tiene cuatro: módulos, inversor, banco y BMS. Un
-- generador tampoco: generador, motor, alternador y tablero. Pero `equipos` guarda UNA
-- serie, y partirlo en varios equipos rompería el 1 cita : 1 orden : 1 equipo.
--
-- Así que los componentes viven en **`equipos.atributos.componentes`**, que es para lo que
-- existe ese jsonb:
--   [{ rol, marca, modelo, serie, cantidad, foto }]
-- `equipos.numero_serie` sigue siendo la del equipo principal.
--
-- La foto de la placa **no es evidencia del servicio**: no cuenta el estado, cuenta la
-- identidad. Por eso cuelga del EQUIPO y no de la orden: se toma una vez y en las visitas
-- siguientes ya no se vuelve a pedir. Vive en el bucket `ordenes`, en
-- `placas/<equipo_id>/<rol>.jpg`; las políticas de storage (06) ya cubren esa ruta.
--
-- El técnico no puede escribir en `equipos` (RLS), así que entra por esta función, que
-- comprueba que la orden sea suya y que el equipo sea el de esa orden.
--
-- Se puede repetir sin problema. Prueba: 25_prueba_placas_equipo.sql.
-- ===========================================================================

create or replace function guardar_placa(
  p_orden uuid,
  p_rol text,
  p_ruta text default null,      -- ruta de la foto en el bucket; null si solo se capturan datos
  p_datos jsonb default null     -- { marca, modelo, serie, cantidad }
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  o ordenes_servicio%rowtype;
  v_eq equipos%rowtype;
  v_previo jsonb;
  v_nuevo jsonb;
  v_otros jsonb;
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
  if p_rol not in ('modulos', 'inversor_1', 'inversor_2', 'bateria', 'bms',
                   'generador', 'motor', 'alternador', 'tablero') then
    raise exception 'Componente no válido: %', p_rol using errcode = '22023';
  end if;

  select * into v_eq from equipos where id = o.equipo_id for update;

  -- Lo que ya había de ESE componente, para no perderlo al guardar solo la foto.
  select x into v_previo
    from jsonb_array_elements(coalesce(v_eq.atributos -> 'componentes', '[]'::jsonb)) x
   where x ->> 'rol' = p_rol
   limit 1;

  v_nuevo := coalesce(v_previo, '{}'::jsonb)
             || jsonb_build_object('rol', p_rol)
             || coalesce(p_datos, '{}'::jsonb);
  if p_ruta is not null then
    v_nuevo := v_nuevo || jsonb_build_object('foto', p_ruta);
  end if;

  -- Los demás componentes se conservan tal cual.
  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_otros
    from jsonb_array_elements(coalesce(v_eq.atributos -> 'componentes', '[]'::jsonb)) x
   where x ->> 'rol' <> p_rol;

  update equipos
     set atributos = coalesce(atributos, '{}'::jsonb)
                     || jsonb_build_object('componentes', v_otros || jsonb_build_array(v_nuevo)),
         updated_at = now()
   where id = v_eq.id;

  perform _apunta('equipos', v_eq.id, 'placa', v_previo, v_nuevo);

  return jsonb_build_object('ok', true, 'equipo_id', v_eq.id, 'rol', p_rol,
                            'componentes', jsonb_array_length(v_otros) + 1);
end $$;
revoke all on function guardar_placa(uuid, text, text, jsonb) from public, anon;
grant execute on function guardar_placa(uuid, text, text, jsonb) to authenticated;

notify pgrst, 'reload schema';
