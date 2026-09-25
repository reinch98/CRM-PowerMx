-- ===========================================================================
-- EL EQUIPO SE CAPTURA EN CAMPO
--
-- El cliente casi nunca sabe el modelo ni la serie; el técnico sí, porque está parado
-- frente a la placa. Así que el equipo deja de ser un requisito para agendar y pasa a ser
-- algo que la base APRENDE en cada visita:
--
--   primer servicio  → la orden nace sin equipo; al visitarlo, el técnico lo da de alta
--   servicios luego  → el técnico elige uno de los guardados del cliente, o agrega otro
--
-- Agendar sin equipo YA se podía (`agendar_cita` solo valida `p_equipo` si no viene nulo):
-- esta parte no se construye aquí.
--
-- Tres cambios:
--   1. `numero_serie` deja de ser obligatorio. Una placa borrada no puede detener el
--      trabajo. Postgres permite varios nulos en un índice único, así que muchos equipos
--      "sin serie" conviven sin chocar entre ellos.
--   2. El técnico liga o da de alta el equipo de SU orden, con funciones acotadas
--      (no tiene permiso de escribir en `equipos`).
--   3. El horómetro sube al equipo. Hasta ahora se quedaba en `ordenes_servicio.horas_equipo`
--      y para saber las horas de un generador había que buscar su última orden.
--
-- Se puede repetir sin problema. Prueba: 23_prueba_equipo_en_campo.sql.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. La serie deja de ser obligatoria
-- ---------------------------------------------------------------------------
alter table equipos alter column numero_serie drop not null;

-- Cuándo se leyó el horómetro que trae el equipo. Sin esto, un número de horas suelto
-- no dice nada: 1,200 horas de hace dos años no es el estado de hoy.
alter table equipos add column if not exists horas_uso_fecha date;

-- ---------------------------------------------------------------------------
-- Apunte en `auditoria`. La tabla ya existía (del esquema base) con origen 'agente'
-- por defecto; aquí el origen es 'campo': lo escribió un técnico desde su celular.
-- ---------------------------------------------------------------------------
create or replace function _apunta(
  p_tabla text, p_registro uuid, p_accion text,
  p_antes jsonb default null, p_despues jsonb default null, p_origen text default 'campo'
) returns void
language sql security definer set search_path = public as $$
  insert into auditoria (tabla, registro_id, accion, valor_anterior, valor_nuevo, origen, usuario)
  values (p_tabla, p_registro, p_accion, p_antes, p_despues, p_origen,
          coalesce(auth.jwt() ->> 'email', 'crm'))
$$;
revoke all on function _apunta(text, uuid, text, jsonb, jsonb, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. El horómetro sube al equipo
--
-- Va como TRIGGER y no dentro de `cerrar_orden` a propósito: así también cubre una orden
-- que el admin cierre o corrija a mano desde la oficina, y no hay que volver a copiar
-- entera la función de cierre (que ya se reescribió en la 12 y en la 18).
--
-- Un horómetro que va PARA ATRÁS no se bloquea: puede ser un motor reemplazado, un
-- tablero nuevo o un dedo equivocado. Se guarda igual y queda el rastro en `auditoria`
-- con el valor anterior, para que se pueda revisar después.
-- ---------------------------------------------------------------------------
create or replace function _horometro_al_equipo() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_antes numeric;
begin
  if new.estado <> 'cerrada' or new.horas_equipo is null or new.equipo_id is null then
    return new;
  end if;
  -- Solo cuando el cierre es nuevo o cambió la lectura: no repetir en cada `update`.
  if old.estado = 'cerrada' and old.horas_equipo is not distinct from new.horas_equipo then
    return new;
  end if;

  select horas_uso into v_antes from equipos where id = new.equipo_id;

  update equipos
     set horas_uso = new.horas_equipo,
         horas_uso_fecha = coalesce(new.fecha, (now() at time zone 'America/Mexico_City')::date),
         updated_at = now()
   where id = new.equipo_id;

  perform _apunta('equipos', new.equipo_id, 'horometro',
    jsonb_build_object('horas_uso', v_antes),
    jsonb_build_object('horas_uso', new.horas_equipo, 'orden', new.folio,
                       'retrocede', v_antes is not null and new.horas_equipo < v_antes));
  return new;
end $$;

drop trigger if exists horometro_al_equipo on ordenes_servicio;
create trigger horometro_al_equipo after update on ordenes_servicio
  for each row execute function _horometro_al_equipo();

-- ---------------------------------------------------------------------------
-- 3. El técnico liga un equipo YA guardado a su orden
--
-- Solo de SU orden (T1 o T2: el ayudante bien puede ser quien lee la placa) y solo
-- mientras está abierta. El equipo tiene que ser del mismo cliente de la orden: un id
-- que venga de otro lado no liga nada.
-- La cita se actualiza junto con la orden, para que la Agenda muestre lo mismo.
-- ---------------------------------------------------------------------------
create or replace function equipo_de_orden(p_orden uuid, p_equipo uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o ordenes_servicio%rowtype; e equipos%rowtype;
begin
  select * into o from ordenes_servicio where id = p_orden for update;
  if not found then raise exception 'La orden no existe.' using errcode = 'P0002'; end if;
  if not (es_admin() or soy_de_la_orden(p_orden)) then
    raise exception 'Esa orden no es tuya.' using errcode = '42501';
  end if;
  if o.estado <> 'abierta' then
    raise exception 'La orden ya está cerrada: el equipo se elige antes de cerrar.' using errcode = '22023';
  end if;

  select * into e from equipos where id = p_equipo;
  if not found then raise exception 'Ese equipo no existe.' using errcode = 'P0002'; end if;
  if e.cliente_id <> o.cliente_id then
    raise exception 'Ese equipo no es de este cliente.' using errcode = '42501';
  end if;

  if o.equipo_id is not distinct from p_equipo then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'equipo_id', p_equipo);
  end if;

  update ordenes_servicio set equipo_id = p_equipo where id = o.id;
  update citas set equipo_id = p_equipo where id = o.cita_id;
  perform _apunta('ordenes_servicio', o.id, 'equipo',
    jsonb_build_object('equipo_id', o.equipo_id), jsonb_build_object('equipo_id', p_equipo));

  return jsonb_build_object('ok', true, 'equipo_id', p_equipo,
                            'serie', e.numero_serie, 'sin_serie', e.numero_serie is null);
end $$;
revoke all on function equipo_de_orden(uuid, uuid) from public, anon;
grant execute on function equipo_de_orden(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. El técnico da de alta un equipo NUEVO desde su orden
--
-- `p_datos`: { tipo, marca, modelo, capacidad_kw, numero_serie, combustible,
--              ubicacion_equipo, anio, notas }
-- Todo es opcional salvo el tipo, que decide de qué trabajo se trata (generador o solar)
-- y además manda el tipo de orden de servicio.
--
-- El técnico NO puede tocar nada comercial: `en_poliza`, `frecuencia_meses` y
-- `proximo_mantenimiento` se quedan como están; eso lo decide la oficina.
--
-- Si escribe una serie que ESE cliente ya tiene registrada, no se duplica el equipo:
-- se liga el que ya existía y se completan sus huecos. Es el caso normal de un equipo
-- que alguien dio de alta a medias desde la oficina.
-- ---------------------------------------------------------------------------
create or replace function registrar_equipo_en_orden(p_orden uuid, p_datos jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  o ordenes_servicio%rowtype;
  v_serie text := nullif(trim(coalesce(p_datos ->> 'numero_serie', '')), '');
  v_tipo text := coalesce(nullif(trim(coalesce(p_datos ->> 'tipo', '')), ''), 'generador');
  v_comb text := nullif(trim(coalesce(p_datos ->> 'combustible', '')), '');
  v_id uuid;
  v_antes jsonb;
  v_reusado boolean := false;
begin
  select * into o from ordenes_servicio where id = p_orden for update;
  if not found then raise exception 'La orden no existe.' using errcode = 'P0002'; end if;
  if not (es_admin() or soy_de_la_orden(p_orden)) then
    raise exception 'Esa orden no es tuya.' using errcode = '42501';
  end if;
  if o.estado <> 'abierta' then
    raise exception 'La orden ya está cerrada: el equipo se captura antes de cerrar.' using errcode = '22023';
  end if;
  if o.cliente_id is null then
    raise exception 'La orden no tiene cliente: no se le puede colgar un equipo.' using errcode = '22023';
  end if;
  if v_tipo not in ('generador', 'solar', 'bateria', 'otro') then
    raise exception 'Tipo de equipo no válido: %', v_tipo using errcode = '22023';
  end if;
  if v_comb is not null and v_comb not in ('gasolina', 'gas_lp', 'gas_natural', 'diesel') then
    raise exception 'Combustible no válido: %', v_comb using errcode = '22023';
  end if;

  -- ¿Ese cliente ya tenía este equipo? Se completa, no se duplica.
  if v_serie is not null then
    select id into v_id from equipos where cliente_id = o.cliente_id and numero_serie = v_serie;
  end if;

  if v_id is not null then
    v_reusado := true;
    select to_jsonb(e) into v_antes from equipos e where e.id = v_id;
    update equipos
       set marca = coalesce(marca, nullif(trim(coalesce(p_datos ->> 'marca', '')), '')),
           modelo = coalesce(modelo, nullif(trim(coalesce(p_datos ->> 'modelo', '')), '')),
           capacidad_kw = coalesce(capacidad_kw, (p_datos ->> 'capacidad_kw')::numeric),
           anio = coalesce(anio, (p_datos ->> 'anio')::int),
           ubicacion_equipo = coalesce(ubicacion_equipo, nullif(trim(coalesce(p_datos ->> 'ubicacion_equipo', '')), '')),
           atributos = case when v_comb is null or coalesce(atributos ->> 'combustible', '') <> ''
                            then atributos else atributos || jsonb_build_object('combustible', v_comb) end,
           updated_at = now()
     where id = v_id;
    perform _apunta('equipos', v_id, 'completar_en_campo', v_antes, p_datos);
  else
    insert into equipos (cliente_id, numero_serie, tipo, marca, modelo, capacidad_kw, anio,
                         ubicacion_equipo, notas, atributos)
    values (o.cliente_id, v_serie, v_tipo,
            nullif(trim(coalesce(p_datos ->> 'marca', '')), ''),
            nullif(trim(coalesce(p_datos ->> 'modelo', '')), ''),
            (p_datos ->> 'capacidad_kw')::numeric,
            (p_datos ->> 'anio')::int,
            nullif(trim(coalesce(p_datos ->> 'ubicacion_equipo', '')), ''),
            nullif(trim(coalesce(p_datos ->> 'notas', '')), ''),
            case when v_comb is null then '{}'::jsonb else jsonb_build_object('combustible', v_comb) end)
    returning id into v_id;
    perform _apunta('equipos', v_id, 'alta_en_campo', null, p_datos);
  end if;

  update ordenes_servicio set equipo_id = v_id where id = o.id;
  update citas set equipo_id = v_id where id = o.cita_id;

  return jsonb_build_object('ok', true, 'equipo_id', v_id, 'reusado', v_reusado,
                            'sin_serie', v_serie is null);
end $$;
revoke all on function registrar_equipo_en_orden(uuid, jsonb) from public, anon;
grant execute on function registrar_equipo_en_orden(uuid, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Los equipos a los que les falta la serie
--
-- La lista que la oficina tiene que ir cerrando: se creó en campo con la placa ilegible
-- y alguien debe conseguir el dato. Trae el cliente y la última orden donde se atendió,
-- para saber a quién preguntarle.
-- ---------------------------------------------------------------------------
create or replace function equipos_sin_serie()
returns table (
  equipo_id uuid, cliente_id uuid, cliente text, tipo text, marca text, modelo text,
  capacidad_kw numeric, ubicacion_equipo text, dado_de_alta timestamptz,
  ultima_orden int, ultima_visita date
)
language sql stable security definer set search_path = public as $$
  select e.id, e.cliente_id, c.nombre, e.tipo, e.marca, e.modelo,
         e.capacidad_kw, e.ubicacion_equipo, e.created_at,
         o.folio, o.fecha
    from equipos e
    join clientes c on c.id = e.cliente_id
    left join lateral (
      select folio, fecha from ordenes_servicio
       where equipo_id = e.id order by fecha desc nulls last limit 1
    ) o on true
   where e.numero_serie is null
     and coalesce(e.estado, 'activo') = 'activo'
     and es_admin()
   order by e.created_at;
$$;
revoke all on function equipos_sin_serie() from public, anon;
grant execute on function equipos_sin_serie() to authenticated;

notify pgrst, 'reload schema';
