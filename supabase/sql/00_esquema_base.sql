-- Esquema `public` de crm-generadores, foto tomada el 26/09/2026.
-- Generado por supabase/sql/00_volcar_esquema.sql — no editar a mano:
-- volver a correr ese script y reemplazar este archivo.
--
-- Contenido: 30 tablas, 6 vistas, 74 funciones, 60 políticas.
-- Es una FOTO, no una migración: si una sentencia falla por el orden,
-- se vuelve a correr al final.

-- ========== EXTENSIONES (informativo) ==========

-- extensión instalada: pg_stat_statements (esquema extensions, versión 1.11)

-- extensión instalada: pgcrypto (esquema extensions, versión 1.3)

-- extensión instalada: plpgsql (esquema pg_catalog, versión 1.0)

-- extensión instalada: supabase_vault (esquema vault, versión 0.3.1)

-- extensión instalada: unaccent (esquema extensions, versión 1.1)

-- extensión instalada: uuid-ossp (esquema extensions, versión 1.1)

-- ========== TIPOS ==========

-- ========== FUNCIONES (van antes de las tablas: hay columnas generadas que las llaman) ==========

CREATE OR REPLACE FUNCTION public._aplicar_entrega(p_entrega uuid, p_estado text, p_firma text, p_motivo text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  e entregas%rowtype;
  o ordenes_servicio%rowtype;
  l record;
  v_cot uuid;
  v_cot_estado text;
  v_fisico numeric;
  v_pide numeric;
  v_previo numeric;
  v_lib numeric;
  quien text := coalesce(auth.jwt() ->> 'email', 'crm');
begin
  select * into e from entregas where id = p_entrega;
  select * into o from ordenes_servicio where id = e.orden_id for update;
  if o.estado <> 'abierta' then
    raise exception 'La orden ya no está abierta: no se puede entregar material.' using errcode = '22023';
  end if;

  select ci.cotizacion_id into v_cot from citas ci where ci.id = o.cita_id;
  if v_cot is not null then
    select estado into v_cot_estado from cotizaciones where id = v_cot;
  end if;

  for l in select * from entrega_lineas where entrega_id = e.id loop
    select fisico into v_fisico from existencias where id = l.producto_id;
    if coalesce(v_fisico, 0) < l.cantidad then
      raise exception 'No hay existencia suficiente de % (hay %, se entregan %).',
        l.sku, coalesce(v_fisico, 0), l.cantidad using errcode = '22023';
    end if;

    -- Lo que sigue apartado de esa cotización para ese producto (se calcula ANTES
    -- de registrar esta entrega): lo pedido menos lo ya entregado.
    v_lib := 0;
    if v_cot is not null and v_cot_estado = 'aceptada' then
      select coalesce(sum((x ->> 'cantidad')::numeric), 0) into v_pide
        from cotizaciones c, jsonb_array_elements(coalesce(c.partidas, '[]'::jsonb)) x
       where c.id = v_cot and x ->> 'producto_id' = l.producto_id::text;
      select coalesce(sum(cantidad), 0) into v_previo
        from movimientos_inventario
       where cotizacion_id = v_cot and producto_id = l.producto_id and tipo = 'entrega_tecnico';
      v_lib := greatest(least(l.cantidad, v_pide - v_previo), 0);
    end if;

    insert into movimientos_inventario
      (producto_id, tipo, cantidad, cotizacion_id, orden_id, tecnico_id, referencia, notas, usuario)
    values
      (l.producto_id, 'entrega_tecnico', l.cantidad, v_cot, o.id, o.tecnico_id,
       'ENT-' || e.folio, 'Entrega al técnico responsable · OS-' || o.folio, quien);

    if v_lib > 0 then
      insert into movimientos_inventario
        (producto_id, tipo, cantidad, cliente_id, cotizacion_id, orden_id, tecnico_id, referencia, notas, usuario)
      values
        (l.producto_id, 'libera_apartado', v_lib, o.cliente_id, v_cot, o.id, o.tecnico_id,
         'ENT-' || e.folio, 'Lo apartado pasó a manos del técnico', quien);
    end if;

    update orden_surtido
       set cantidad_entregada = cantidad_entregada + l.cantidad
     where orden_id = o.id and producto_id = l.producto_id;
  end loop;

  update entregas
     set estado = p_estado, firma_ruta = p_firma, motivo_sin_firma = p_motivo,
         entregada_at = now()
   where id = e.id;
end $function$
;

CREATE OR REPLACE FUNCTION public._apunta(p_tabla text, p_registro uuid, p_accion text, p_antes jsonb DEFAULT NULL::jsonb, p_despues jsonb DEFAULT NULL::jsonb, p_origen text DEFAULT 'campo'::text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  insert into auditoria (tabla, registro_id, accion, valor_anterior, valor_nuevo, origen, usuario)
  values (p_tabla, p_registro, p_accion, p_antes, p_despues, p_origen,
          coalesce(auth.jwt() ->> 'email', 'crm'))
$function$
;

CREATE OR REPLACE FUNCTION public._cancelar_avisos(p_cita uuid, p_solo_tecnicos_fuera boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c citas%rowtype;
begin
  select * into c from citas where id = p_cita;

  -- Con historial de envío: el pendiente (si lo hay) pasa a ser una cancelación; si no lo hay, se crea.
  insert into avisos (cita_id, tipo, destinatario, llave, contacto_id, perfil_id, nombre, telefono)
  select distinct on (a.llave) a.cita_id, 'cancelacion', a.destinatario, a.llave, a.contacto_id, a.perfil_id, a.nombre, a.telefono
    from avisos a
   where a.cita_id = p_cita and a.estado = 'enviado' and a.tipo <> 'cancelacion'
     and not exists (select 1 from avisos b where b.cita_id = a.cita_id and b.llave = a.llave and b.tipo = 'cancelacion' and b.estado = 'enviado')
     and (not p_solo_tecnicos_fuera
          or (a.destinatario = 'tecnico' and a.perfil_id is distinct from c.tecnico_id and a.perfil_id is distinct from c.tecnico2_id))
   order by a.llave, a.enviado_at desc
  on conflict (cita_id, llave) where estado = 'pendiente'
    do update set tipo = 'cancelacion';

  -- Sin historial de envío: lo pendiente ya no tiene sentido.
  update avisos a set estado = 'descartado'
   where a.cita_id = p_cita and a.estado = 'pendiente' and a.tipo <> 'cancelacion'
     and not exists (select 1 from avisos b where b.cita_id = a.cita_id and b.llave = a.llave and b.estado = 'enviado')
     and (not p_solo_tecnicos_fuera
          or (a.destinatario = 'tecnico' and a.perfil_id is distinct from c.tecnico_id and a.perfil_id is distinct from c.tecnico2_id));
end $function$
;

CREATE OR REPLACE FUNCTION public._capacidad_de_equipo(e equipos)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select coalesce(
    nullif(e.capacidad_kw, 0),
    case when e.tipo = 'solar'
         then nullif((e.atributos ->> 'potencia_inversor_kw')::numeric, 0) end,
    case when e.tipo = 'bateria'
         then nullif((e.atributos ->> 'capacidad_kwh')::numeric, 0) end)
$function$
;

CREATE OR REPLACE FUNCTION public._clase_de_equipo(e equipos)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select case
    when e.tipo = 'solar' then 'solar'
    when e.tipo = 'bateria' then 'bateria'
    when e.tipo = 'generador' then case e.atributos ->> 'combustible'
      when 'gasolina' then 'gasolina'
      when 'gas_lp' then 'gas_lp'
      when 'gas_natural' then 'gas_lp'
      when 'diesel' then 'diesel'
      else null end
    else null end
$function$
;

CREATE OR REPLACE FUNCTION public._cliente_de_conversacion(p_conversacion uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select c.cliente_id
    from conversaciones v
    join contactos c on c.id = v.contacto_id and c.activo
   where v.id = p_conversacion
$function$
;

CREATE OR REPLACE FUNCTION public._codigos_de_linea(p_linea uuid)
 RETURNS TABLE(producto_id uuid, sku text, nombre text, unidad text, disponible numeric, preferido boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select pr.id, pr.sku, pr.nombre, pr.unidad,
         coalesce(d.disponible, 0), pr.id = l.producto_id
    from paquete_lineas l
    join productos pr
      on pr.id = l.producto_id
      or (l.grupo is not null and pr.grupo_equivalente = l.grupo)
      or (l.producto_id is not null and pr.grupo_equivalente is not null
          and pr.grupo_equivalente = (select grupo_equivalente from productos where id = l.producto_id))
    left join disponibles d on d.id = pr.id
   where l.id = p_linea
   order by (pr.id = l.producto_id) desc, coalesce(d.disponible, 0) desc
$function$
;

CREATE OR REPLACE FUNCTION public._completar_solicitud_material()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p productos%rowtype;
begin
  if new.orden_id is not null then
    select o.equipo_id, o.cliente_id into new.equipo_id, new.cliente_id
      from ordenes_servicio o where o.id = new.orden_id;
    if not found then
      raise exception 'La orden no existe.' using errcode = 'P0002';
    end if;
  elsif new.equipo_id is not null and new.cliente_id is null then
    select e.cliente_id into new.cliente_id from equipos e where e.id = new.equipo_id;
  end if;

  if new.producto_id is not null then
    select * into p from productos where id = new.producto_id and activo;
    if not found then
      raise exception 'La pieza no existe.' using errcode = 'P0002';
    end if;
    new.sku := p.sku;
    new.nombre := p.nombre;
    new.unidad := p.unidad;
    new.descripcion_libre := null;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public._contactos_de_aviso(p_cita uuid)
 RETURNS SETOF contactos
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select ct.*
    from citas c
    join contactos ct on ct.cliente_id = c.cliente_id
   where c.id = p_cita
     and ct.activo and ct.whatsapp and ct.telefono_norm is not null
     and (
       (c.equipo_id is not null and exists (
          select 1 from contactos_por_equipo v
           where v.equipo_id = c.equipo_id and v.contacto_id = ct.id
             and (v.rol = 'responsable' or v.puede_pedir_citas)))
       or (c.equipo_id is null and ct.de_toda_la_empresa and ct.puede_pedir_citas)
     )
$function$
;

CREATE OR REPLACE FUNCTION public._encolar_avisos(p_cita uuid, p_tipo text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c citas%rowtype;
  cl clientes%rowtype;
  n int := 0;
  k int;
  v_llave text;
begin
  select * into c from citas where id = p_cita;
  if not found then return 0; end if;

  -- Técnicos: T1 y T2, con el teléfono de su perfil (puede faltar).
  insert into avisos (cita_id, tipo, destinatario, llave, perfil_id, nombre, telefono)
  select c.id, _tipo_para(c.id, 't:' || p.id, p_tipo), 'tecnico', 't:' || p.id, p.id,
         coalesce(p.nombre, p.email), nullif(trim(p.telefono), '')
    from perfiles p
   where p.id in (c.tecnico_id, c.tecnico2_id)
  on conflict (cita_id, llave) where estado = 'pendiente' do nothing;
  get diagnostics k = row_count; n := n + k;

  -- Cliente: sus contactos (con teléfono y WhatsApp).
  if exists (select 1 from _contactos_de_aviso(c.id)) then
    insert into avisos (cita_id, tipo, destinatario, llave, contacto_id, nombre, telefono)
    select c.id, _tipo_para(c.id, 'c:' || ct.id, p_tipo), 'cliente', 'c:' || ct.id, ct.id, ct.nombre, ct.telefono
      from _contactos_de_aviso(c.id) ct
    on conflict (cita_id, llave) where estado = 'pendiente' do nothing;
    get diagnostics k = row_count; n := n + k;
  else
    -- Sin contactos: el teléfono de la ficha; si tampoco hay, un aviso sin número, para que la
    -- cola muestre que a ese cliente no hay a quién avisarle.
    select * into cl from clientes where id = c.cliente_id;
    v_llave := case when normalizar_telefono(cl.telefono) is not null then 'f:' || cl.id else 's:' || c.id end;
    insert into avisos (cita_id, tipo, destinatario, llave, nombre, telefono)
    values (c.id, _tipo_para(c.id, v_llave, p_tipo), 'cliente', v_llave,
            coalesce(nullif(trim(cl.contacto_nombre), ''), cl.nombre),
            case when normalizar_telefono(cl.telefono) is not null then cl.telefono end)
    on conflict (cita_id, llave) where estado = 'pendiente' do nothing;
    get diagnostics k = row_count; n := n + k;
  end if;

  return n;
end $function$
;

CREATE OR REPLACE FUNCTION public._es_almacen()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select es_admin() or coalesce(mi_rol() = 'almacenista', false)
$function$
;

CREATE OR REPLACE FUNCTION public._es_bot_o_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select es_admin() or coalesce(mi_rol() = 'bot', false)
$function$
;

CREATE OR REPLACE FUNCTION public._fijar_componente(p_equipo uuid, p_rol text, p_datos jsonb DEFAULT NULL::jsonb, p_ruta text DEFAULT NULL::text, p_origen text DEFAULT 'campo'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public._horometro_al_equipo()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public._ligar_conversacion_sola()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_n int; v_norm text;
begin
  if new.contacto_id is not null then
    select cliente_id into new.cliente_id from contactos where id = new.contacto_id;
    return new;
  end if;

  -- OJO: `telefono_norm` es una columna GENERADA, y Postgres las calcula DESPUÉS de
  -- los triggers `before insert`: aquí todavía llega en null. Hay que normalizar a
  -- mano con la misma función, o la conversación nunca se liga a su contacto.
  v_norm := normalizar_telefono(new.telefono);
  if v_norm is null then return new; end if;

  select count(*) into v_n from contactos c
   where c.activo and c.telefono_norm = v_norm;
  if v_n = 1 then
    select c.id, c.cliente_id into new.contacto_id, new.cliente_id
      from contactos c
     where c.activo and c.telefono_norm = v_norm;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public._paquete_de_equipo(p_equipo uuid, p_tipo text)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select p.id
    from paquetes_mantenimiento p, equipos e
   where e.id = p_equipo
     and p.activo and p.tipo = p_tipo
     and (p.marca is null or lower(p.marca) = lower(coalesce(e.marca, '')))
     and (p.modelo is null or lower(p.modelo) = lower(coalesce(e.modelo, '')))
     and (p.clase is null or p.clase = _clase_de_equipo(e))
     and (p.kw_desde is null or _capacidad_de_equipo(e) >= p.kw_desde)
     and (p.kw_hasta is null or _capacidad_de_equipo(e) <= p.kw_hasta)
   order by (p.modelo is not null) desc, (p.marca is not null) desc,
            (p.clase is not null) desc, p.kw_desde desc nulls last
   limit 1
$function$
;

CREATE OR REPLACE FUNCTION public._preparar_surtido(p_orden uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n int;
begin
  insert into orden_surtido
    (orden_id, producto_id, sku, nombre, unidad, cantidad_pedida, origen, cotizacion_id)
  select o.id, q.producto_id, p.sku, p.nombre, p.unidad, q.pide, 'cotizacion', c.id
  from ordenes_servicio o
  join citas ci on ci.id = o.cita_id
  join cotizaciones c on c.id = ci.cotizacion_id
  cross join lateral (
    select (x ->> 'producto_id')::uuid as producto_id, sum((x ->> 'cantidad')::numeric) as pide
    from jsonb_array_elements(coalesce(c.partidas, '[]'::jsonb)) x
    where nullif(x ->> 'producto_id', '') is not null
      and (x ->> 'cantidad')::numeric > 0
    group by 1
  ) q
  join productos p on p.id = q.producto_id
  where o.id = p_orden and o.estado = 'abierta' and c.estado = 'aceptada'
  on conflict (orden_id, producto_id) do nothing;
  get diagnostics n = row_count;
  return n;
end $function$
;

CREATE OR REPLACE FUNCTION public._seguridad_antes_de_cerrar()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_sin_control text;
begin
  if new.estado <> 'cerrada' or old.estado = 'cerrada' then
    return new;
  end if;

  select string_agg(clave, ', ' order by clave) into v_sin_control
  from (
    select p.key as clave
      from orden_revision r,
           jsonb_each(coalesce(r.datos -> 'puntos', '{}'::jsonb)) p
     where r.orden_id = new.id
       and p.key like '1.%'                                  -- sección 1: seguridad
       and (p.value ->> 'v') = 'M'                            -- "M" aquí es el "NO" del papel
       and coalesce(trim(p.value ->> 'obs'), '') = ''         -- sin control compensatorio
  ) x;

  if v_sin_control is not null then
    raise exception 'Seguridad sin resolver en % . Escribe el control compensatorio o suspende el servicio.',
      v_sin_control using errcode = '22023';
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public._sella_revision()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  new.updated_at := now();
  new.actualizado_por := coalesce(auth.uid(), new.actualizado_por);
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public._tipo_para(p_cita uuid, p_llave text, p_tipo text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case
           when p_tipo = 'reprogramacion'
                and not exists (select 1 from avisos x
                                 where x.cita_id = p_cita and x.llave = p_llave and x.estado = 'enviado')
             then 'confirmacion'
           else p_tipo
         end
$function$
;

CREATE OR REPLACE FUNCTION public.actualizar_componente(p_equipo uuid, p_rol text, p_datos jsonb, p_origen text DEFAULT 'oficina'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if p_origen not in ('oficina', 'agente') then
    raise exception 'Origen no válido: %', p_origen using errcode = '22023';
  end if;
  return _fijar_componente(p_equipo, p_rol, p_datos, null, p_origen);
end $function$
;

CREATE OR REPLACE FUNCTION public.adicionales_por_conciliar()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r jsonb;
begin
  if not _es_almacen() then
    raise exception 'Solo el almacén o el administrador.' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'orden_id', o.id, 'folio', o.folio, 'cliente', cl.nombre, 'fecha', o.fecha,
      'tecnico1', t1.nombre,
      'items', (select jsonb_agg(jsonb_build_object('descripcion', x ->> 'descripcion', 'cantidad', x ->> 'cantidad'))
                  from jsonb_array_elements(o.refacciones) x
                 where (x ->> 'adicional') = 'true' and coalesce(x ->> 'conciliada', 'false') <> 'true')
    ) order by o.fecha desc nulls last, o.folio desc), '[]'::jsonb)
    into r
  from ordenes_servicio o
  join clientes cl on cl.id = o.cliente_id
  left join perfiles t1 on t1.id = o.tecnico_id
  where o.estado = 'cerrada'
    and jsonb_typeof(o.refacciones) = 'array'
    and exists (select 1 from jsonb_array_elements(o.refacciones) x
                 where (x ->> 'adicional') = 'true' and coalesce(x ->> 'conciliada', 'false') <> 'true');
  return r;
end $function$
;

CREATE OR REPLACE FUNCTION public.agendar_cita(p_cliente uuid, p_equipo uuid, p_tipo text, p_fecha date, p_hora time without time zone, p_duracion integer, p_t1 uuid, p_t2 uuid, p_zona text, p_notas text, p_cotizacion uuid DEFAULT NULL::uuid, p_nueva_cotizacion jsonb DEFAULT NULL::jsonb, p_confirmar boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.atender_solicitud_material(p_id uuid, p_resolucion text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s solicitudes_material%rowtype;
begin
  if not _es_almacen() then
    raise exception 'Solo el almacén o el administrador.' using errcode = '42501';
  end if;
  if nullif(trim(coalesce(p_resolucion, '')), '') is null then
    raise exception 'Escribe cómo se resolvió.' using errcode = '22023';
  end if;
  select * into s from solicitudes_material where id = p_id for update;
  if not found then raise exception 'La solicitud no existe.' using errcode = 'P0002'; end if;
  if s.estado <> 'pendiente' then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'estado', s.estado);
  end if;

  update solicitudes_material
     set estado = 'atendida', resolucion = trim(p_resolucion),
         atendida_por = coalesce(auth.jwt() ->> 'email', 'crm'), atendida_at = now()
   where id = p_id;
  return jsonb_build_object('ok', true, 'folio', s.folio);
end $function$
;

CREATE OR REPLACE FUNCTION public.avisos_de_cita()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if tg_op = 'INSERT' then
    if new.estado = 'programada' and new.fecha is not null then
      perform _encolar_avisos(new.id, 'confirmacion');
    end if;
    return new;
  end if;

  -- UPDATE
  if new.estado = 'programada' and old.estado is distinct from 'programada' and new.fecha is not null then
    perform _encolar_avisos(new.id, 'confirmacion');

  elsif new.estado = 'programada' and old.estado = 'programada' and (
        new.fecha is distinct from old.fecha or new.hora is distinct from old.hora
        or new.duracion_min is distinct from old.duracion_min
        or new.tecnico_id is distinct from old.tecnico_id
        or new.tecnico2_id is distinct from old.tecnico2_id) then
    -- A quien ya recibió aviso se le manda el cambio; a quien no, se le pone al día solo lo pendiente.
    perform _encolar_avisos(new.id, 'reprogramacion');
    -- Un técnico que quedó fuera de la cita recibe un "ya no estás asignado".
    if new.tecnico_id is distinct from old.tecnico_id or new.tecnico2_id is distinct from old.tecnico2_id then
      perform _cancelar_avisos(new.id, true);
    end if;

  elsif new.estado = 'cancelada' and old.estado = 'programada' then
    perform _cancelar_avisos(new.id, false);
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public.avisos_pendientes()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'pendientes', coalesce((
      select jsonb_agg(jsonb_build_object(
          'id', a.id, 'cita_id', a.cita_id, 'tipo', a.tipo, 'destinatario', a.destinatario,
          'nombre', a.nombre, 'telefono', a.telefono, 'telefono_norm', normalizar_telefono(a.telefono),
          'fecha', ci.fecha, 'hora', ci.hora, 'cliente', cl.nombre,
          'texto', texto_aviso(a.id)
        ) order by ci.fecha nulls last, ci.hora nulls last, a.destinatario desc, a.nombre)
        from avisos a
        join citas ci on ci.id = a.cita_id
        join clientes cl on cl.id = ci.cliente_id
       where a.estado = 'pendiente'), '[]'::jsonb),
    'recientes', coalesce((
      select jsonb_agg(jsonb_build_object(
          'id', a.id, 'tipo', a.tipo, 'destinatario', a.destinatario, 'nombre', a.nombre,
          'telefono', a.telefono, 'telefono_norm', normalizar_telefono(a.telefono),
          'estado', a.estado, 'enviado_at', a.enviado_at, 'cliente', cl.nombre,
          'fecha', ci.fecha, 'hora', ci.hora, 'texto', a.texto_enviado
        ) order by coalesce(a.enviado_at, a.created_at) desc)
        from avisos a
        join citas ci on ci.id = a.cita_id
        join clientes cl on cl.id = ci.cliente_id
       where a.estado in ('enviado', 'descartado')
         and coalesce(a.enviado_at, a.created_at) > now() - interval '3 days'), '[]'::jsonb)
  ) into r;
  return r;
end $function$
;

CREATE OR REPLACE FUNCTION public.bandeja_whatsapp(p_incluir_cerradas boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', cv.id,
      'telefono', cv.telefono,
      'nombre_wa', cv.nombre_wa,
      'estado', cv.estado,
      'sin_leer', cv.sin_leer,
      'ventana_hasta', cv.ventana_hasta,
      'ventana_abierta', cv.ventana_hasta is not null and cv.ventana_hasta > now(),
      'ultimo_mensaje_at', cv.ultimo_mensaje_at,
      'contacto_id', cv.contacto_id,
      'contacto', ct.nombre,
      'cliente', cl.nombre,
      'equipos', (
        select coalesce(jsonb_agg(distinct nullif(trim(concat_ws(' ', eq.tipo, eq.marca,
                 case when eq.capacidad_kw is not null then eq.capacidad_kw || ' kW' end)), '')), '[]'::jsonb)
          from contactos_por_equipo v
          join equipos eq on eq.id = v.equipo_id
         where v.contacto_id = cv.contacto_id),
      'ultimo_texto', (
        select m.texto from mensajes_wa m
         where m.conversacion_id = cv.id
         order by m.created_at desc limit 1)
    ) order by cv.ultimo_mensaje_at desc nulls last), '[]'::jsonb)
    into r
  from conversaciones cv
  left join contactos ct on ct.id = cv.contacto_id
  left join clientes cl on cl.id = cv.cliente_id
  where p_incluir_cerradas or cv.estado = 'abierta';

  return r;
end $function$
;

CREATE OR REPLACE FUNCTION public.cambiar_estado_cotizacion(p_id uuid, p_nuevo text, p_forzar boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  c cotizaciones%rowtype;
  cita citas%rowtype;
  faltantes jsonb := '[]'::jsonb;
  n_mov int := 0;
  n_req int := 0;
  n_canc int := 0;
  n_curso int := 0;
  n_citas_canc int := 0;
  n_citas_trabajo int := 0;
  cita_nueva boolean := false;
  v_orden uuid;
  v_folio int;
  hoy date := (now() at time zone 'America/Mexico_City')::date;   -- el servidor está en UTC
  quien text := coalesce(auth.jwt() ->> 'email', 'crm');
begin
  if not es_admin() then
    raise exception 'Solo el administrador puede cambiar el estado de una cotización.'
      using errcode = '42501';
  end if;

  if p_nuevo not in ('borrador', 'enviada', 'aceptada', 'rechazada', 'vencida') then
    raise exception 'Estado no válido: %', p_nuevo using errcode = '22023';
  end if;

  select * into c from cotizaciones where id = p_id for update;
  if not found then
    raise exception 'La cotización no existe.' using errcode = 'P0002';
  end if;

  if c.estado = p_nuevo then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'folio', c.folio, 'estado', c.estado);
  end if;

  if p_nuevo = 'aceptada' then
    -- 1) Requisiciones por lo que falta (se calcula ANTES de apartar).
    with q as (
      select (p ->> 'producto_id')::uuid as producto_id,
             sum((p ->> 'cantidad')::numeric) as pide
      from jsonb_array_elements(coalesce(c.partidas, '[]'::jsonb)) p
      where nullif(p ->> 'producto_id', '') is not null
        and (p ->> 'cantidad')::numeric > 0
      group by 1
    ),
    f as (
      select q.producto_id,
             coalesce(d.sku, q.producto_id::text) as sku,
             q.pide,
             coalesce(d.disponible, 0) as disponible,
             q.pide - greatest(coalesce(d.disponible, 0), 0)
               - coalesce((select sum(r.cantidad) from requisiciones r
                            where r.cotizacion_id = c.id
                              and r.producto_id = q.producto_id
                              and r.estado in ('pendiente', 'pedida')), 0) as a_pedir
      from q
      left join disponibles d on d.id = q.producto_id
      where coalesce(d.disponible, 0) < q.pide
    ),
    nuevas as (
      insert into requisiciones (producto_id, cotizacion_id, cliente_id, cantidad, creada_por)
      select producto_id, c.id, c.cliente_id, a_pedir, quien
      from f
      where a_pedir > 0
      returning producto_id, cantidad
    )
    select coalesce(jsonb_agg(jsonb_build_object(
             'sku', f.sku, 'pide', f.pide, 'disponible', f.disponible,
             'a_pedir', n.cantidad)), '[]'::jsonb),
           count(*)
      into faltantes, n_req
    from nuevas n
    join f on f.producto_id = n.producto_id;

    -- 2) Apartar lo pedido en la cotización.
    insert into movimientos_inventario
      (producto_id, tipo, cantidad, cliente_id, cotizacion_id, referencia, notas, usuario)
    select (p ->> 'producto_id')::uuid, 'apartado', (p ->> 'cantidad')::numeric,
           c.cliente_id, c.id, 'COT-' || c.folio,
           'Apartado al aprobar la cotización', quien
    from jsonb_array_elements(coalesce(c.partidas, '[]'::jsonb)) p
    where nullif(p ->> 'producto_id', '') is not null
      and (p ->> 'cantidad')::numeric > 0;
    get diagnostics n_mov = row_count;

    -- 3) Visita: cita + orden.
    if c.tipo in ('instalacion', 'mantenimiento', 'diagnostico') or coalesce(c.requiere_visita, false) then
      select * into cita from citas
       where cotizacion_id = c.id and estado in ('por_programar', 'programada')
       order by created_at
       limit 1;

      if not found then
        insert into citas
          (cliente_id, equipo_id, tipo_servicio, fecha, hora, duracion_min,
           tecnico_id, tecnico2_id, tecnico, zona, notas, estado, origen, cotizacion_id)
        values
          (c.cliente_id, c.equipo_id,
           case c.tipo when 'instalacion' then 'instalacion'
                       when 'mantenimiento' then 'preventivo'
                       when 'diagnostico' then 'diagnostico'
                       else 'visita_tecnica' end,
           c.prog_fecha, c.prog_hora, c.prog_duracion_min,
           c.prog_tecnico_id, c.prog_tecnico2_id,
           (select nombre from perfiles where id = c.prog_tecnico_id),
           (select zona from clientes where id = c.cliente_id),
           'Cotización COT-' || c.folio,
           case when c.prog_fecha is null then 'por_programar' else 'programada' end,
           'cotizacion', c.id)
        returning * into cita;
        cita_nueva := true;
      end if;

      -- Una orden por cita. Nace `abierta`; el técnico la llena por partes.
      select id, folio into v_orden, v_folio from ordenes_servicio where cita_id = cita.id;
      if v_orden is null then
        insert into ordenes_servicio
          (cliente_id, equipo_id, cita_id, fecha, tipo_servicio,
           tecnico_id, tecnico2_id, tecnico, estado)
        values
          (cita.cliente_id, cita.equipo_id, cita.id, coalesce(cita.fecha, hoy), cita.tipo_servicio,
           cita.tecnico_id, cita.tecnico2_id, cita.tecnico, 'abierta')
        returning id, folio into v_orden, v_folio;
      end if;
    end if;

  elsif c.estado = 'aceptada' then
    -- 14: se libera lo que AÚN queda apartado = lo pedido menos lo ya entregado al
    -- técnico. Sin entregas es idéntico a antes (toda la partida).
    insert into movimientos_inventario
      (producto_id, tipo, cantidad, cliente_id, cotizacion_id, referencia, notas, usuario)
    select q.producto_id, 'libera_apartado', q.pide - coalesce(e.entregado, 0),
           c.cliente_id, c.id, 'COT-' || c.folio,
           'Liberado: la cotización pasó a ' || p_nuevo, quien
    from (
      select (p ->> 'producto_id')::uuid as producto_id, sum((p ->> 'cantidad')::numeric) as pide
      from jsonb_array_elements(coalesce(c.partidas, '[]'::jsonb)) p
      where nullif(p ->> 'producto_id', '') is not null
        and (p ->> 'cantidad')::numeric > 0
      group by 1
    ) q
    left join (
      select producto_id, sum(cantidad) as entregado
      from movimientos_inventario
      where cotizacion_id = c.id and tipo = 'entrega_tecnico'
      group by producto_id
    ) e on e.producto_id = q.producto_id
    where q.pide - coalesce(e.entregado, 0) > 0;
    get diagnostics n_mov = row_count;

    -- Lo que aún no se pide deja de hacer falta. Lo ya pedido al proveedor NO se
    -- cancela solo: el pedido existe; se avisa para que lo revises.
    update requisiciones
       set estado = 'cancelada',
           notas = coalesce(notas || E'\n', '') || 'Cancelada: la cotización COT-' || c.folio || ' pasó a ' || p_nuevo,
           updated_at = now()
     where cotizacion_id = c.id and estado = 'pendiente';
    get diagnostics n_canc = row_count;

    select count(*) into n_curso
      from requisiciones where cotizacion_id = c.id and estado = 'pedida';
  end if;

  -- Cancelar la visita: al salir de "aceptada", o al rechazar / vencer (aunque nunca
  -- se haya aceptado: la cotización de un diagnóstico nace de una cita). Solo si
  -- nadie ha capturado trabajo; si ya hay, se deja y se avisa.
  if p_nuevo <> 'aceptada' and (c.estado = 'aceptada' or p_nuevo in ('rechazada', 'vencida')) then
    with candidatas as (
      select ci.id as cita_id,
             (exists (select 1 from ordenes_servicio o
                       where o.cita_id = ci.id
                         and (coalesce(o.trabajos_realizados, '') <> ''
                              or exists (select 1 from orden_partes op where op.orden_id = o.id)
                              -- 14: material ya entregado al técnico
                              or exists (select 1 from entregas en
                                          where en.orden_id = o.id
                                            and en.estado in ('firmada', 'sin_firma'))))
             ) as con_trabajo
      from citas ci
      where ci.cotizacion_id = c.id and ci.estado in ('por_programar', 'programada')
    ),
    sin_trabajo as (
      select cita_id from candidatas where not con_trabajo
    ),
    ordenes_canceladas as (
      update ordenes_servicio set estado = 'cancelada'
       where cita_id in (select cita_id from sin_trabajo) and estado = 'abierta'
      returning id
    ),
    citas_canceladas as (
      update citas set estado = 'cancelada'
       where id in (select cita_id from sin_trabajo)
      returning id
    )
    select (select count(*) from citas_canceladas),
           (select count(*) from candidatas where con_trabajo)
      into n_citas_canc, n_citas_trabajo;
  end if;

  update cotizaciones
     set estado = p_nuevo,
         aprobada_por     = case when p_nuevo = 'aceptada' then quien else aprobada_por end,
         fecha_aprobacion = case when p_nuevo = 'aceptada' then now() else fecha_aprobacion end
   where id = p_id;

  return jsonb_build_object(
    'ok', true,
    'folio', c.folio,
    'anterior', c.estado,
    'estado', p_nuevo,
    'movimientos', n_mov,
    'movimiento', case
      when p_nuevo = 'aceptada' then 'apartado'
      when c.estado = 'aceptada' then 'libera_apartado'
      else null end,
    'requisiciones', n_req,
    'faltantes', faltantes,
    'requisiciones_canceladas', n_canc,
    'requisiciones_en_curso', n_curso,
    'cita_id', case when p_nuevo = 'aceptada' then cita.id else null end,
    'cita_estado', case when p_nuevo = 'aceptada' then cita.estado else null end,
    'cita_fecha', case when p_nuevo = 'aceptada' then cita.fecha else null end,
    'cita_nueva', cita_nueva,
    'orden_id', v_orden,
    'orden_folio', v_folio,
    'citas_canceladas', n_citas_canc,
    'citas_con_trabajo', n_citas_trabajo
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.cambiar_estado_requisicion(p_id uuid, p_nuevo text, p_proveedor text DEFAULT NULL::text, p_referencia text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  r requisiciones%rowtype;
  quien text := coalesce(auth.jwt() ->> 'email', 'crm');
  hoy date := (now() at time zone 'America/Mexico_City')::date;   -- el servidor está en UTC
  v_mov uuid;
begin
  if not es_admin() then
    raise exception 'Solo el administrador puede cambiar una requisición.'
      using errcode = '42501';
  end if;

  if p_nuevo not in ('pedida', 'recibida', 'cancelada') then
    raise exception 'Estado no válido: %', p_nuevo using errcode = '22023';
  end if;

  select * into r from requisiciones where id = p_id for update;
  if not found then
    raise exception 'La requisición no existe.' using errcode = 'P0002';
  end if;

  if r.estado = p_nuevo then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'folio', r.folio, 'estado', r.estado);
  end if;

  if r.estado in ('recibida', 'cancelada') then
    raise exception 'La requisición REQ-% ya está % y no se puede cambiar.', r.folio, r.estado
      using errcode = '22023';
  end if;

  if p_nuevo = 'pedida' then
    update requisiciones
       set estado = 'pedida',
           proveedor = coalesce(nullif(trim(p_proveedor), ''), proveedor),
           referencia = coalesce(nullif(trim(p_referencia), ''), referencia),
           fecha_pedido = hoy,
           updated_at = now()
     where id = p_id;

  elsif p_nuevo = 'recibida' then
    insert into movimientos_inventario
      (producto_id, tipo, cantidad, referencia, notas, usuario)
    values
      (r.producto_id, 'entrada', r.cantidad,
       'REQ-' || r.folio || coalesce(' · ' || nullif(r.referencia, ''), ''),
       'Recepción de requisición', quien)
    returning id into v_mov;

    update requisiciones
       set estado = 'recibida',
           movimiento_id = v_mov,
           fecha_recibida = hoy,
           updated_at = now()
     where id = p_id;

  else  -- cancelada
    update requisiciones
       set estado = 'cancelada',
           notas = coalesce(notas || E'\n', '') || 'Cancelada manualmente por ' || quien,
           updated_at = now()
     where id = p_id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'folio', r.folio,
    'anterior', r.estado,
    'estado', p_nuevo,
    'movimiento_id', v_mov
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.cancelar_cita(p_cita uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.cancelar_entrega(p_entrega uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare e entregas%rowtype;
begin
  if not _es_almacen() then
    raise exception 'Solo el almacén o el administrador.' using errcode = '42501';
  end if;
  select * into e from entregas where id = p_entrega for update;
  if not found then raise exception 'La entrega no existe.' using errcode = 'P0002'; end if;
  if e.estado = 'cancelada' then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'folio', e.folio);
  end if;
  if e.estado <> 'pendiente' then
    raise exception 'La entrega ya se hizo: el material se corrige con una devolución.' using errcode = '22023';
  end if;
  update entregas set estado = 'cancelada' where id = e.id;
  return jsonb_build_object('ok', true, 'folio', e.folio);
end $function$
;

CREATE OR REPLACE FUNCTION public.cerrar_conversacion(p_conversacion uuid, p_abrir boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  update conversaciones set estado = case when p_abrir then 'abierta' else 'cerrada' end
   where id = p_conversacion;
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.cerrar_orden(p_orden uuid, p_firma text, p_sin_firma boolean DEFAULT false, p_horas numeric DEFAULT NULL::numeric, p_observaciones text DEFAULT NULL::text, p_recomendaciones text DEFAULT NULL::text, p_seguimiento boolean DEFAULT false, p_fecha_seguimiento date DEFAULT NULL::date, p_refacciones jsonb DEFAULT NULL::jsonb, p_uso jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o ordenes_servicio%rowtype;
  s orden_surtido%rowtype;
  u record;
  v_trabajos text;
  v_fotos jsonb;
  v_obs text;
  v_consumos int := 0;
  quien text := coalesce(auth.jwt() ->> 'email', 'crm');
begin
  select * into o from ordenes_servicio where id = p_orden for update;
  if not found then
    raise exception 'La orden no existe.' using errcode = 'P0002';
  end if;

  if not (es_admin() or (mi_rol() = 'tecnico' and o.tecnico_id = auth.uid())) then
    raise exception 'Solo el técnico responsable puede cerrar la orden.' using errcode = '42501';
  end if;

  -- Ya cerrada: el reintento de un cierre que sí llegó. No se toca nada (tampoco el inventario).
  if o.estado = 'cerrada' then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'folio', o.folio);
  end if;
  if o.estado <> 'abierta' then
    raise exception 'La orden OS-% está % y ya no se puede cerrar.', o.folio, o.estado
      using errcode = '22023';
  end if;

  -- Las partes de los dos técnicos, la del responsable primero.
  select string_agg(trim(p.notas), E'\n\n' order by (p.autor_id = o.tecnico_id) desc, p.created_at)
    into v_trabajos
  from orden_partes p
  where p.orden_id = o.id and coalesce(trim(p.notas), '') <> '';

  if coalesce(v_trabajos, '') = '' then
    raise exception 'Anota los trabajos realizados antes de cerrar la orden.' using errcode = '22023';
  end if;

  if p_firma is null and not coalesce(p_sin_firma, false) then
    raise exception 'Falta la firma del cliente.' using errcode = '22023';
  end if;

  -- Material usado: se valida TODO antes de tocar nada.
  if p_uso is not null then
    if jsonb_typeof(p_uso) <> 'array' then
      raise exception 'El material usado no es válido.' using errcode = '22023';
    end if;
    for u in
      select (x ->> 'producto_id')::uuid as producto_id, sum((x ->> 'usadas')::numeric) as usadas
        from jsonb_array_elements(p_uso) x group by 1
    loop
      if u.usadas is null or u.usadas < 0 then
        raise exception 'Las cantidades usadas no son válidas.' using errcode = '22023';
      end if;
      select * into s from orden_surtido where orden_id = o.id and producto_id = u.producto_id;
      if not found then
        raise exception 'Esa pieza no está en el material de la orden.' using errcode = '22023';
      end if;
      if u.usadas > s.cantidad_entregada then
        raise exception 'Declaraste % usadas de % pero solo recibiste %.',
          u.usadas, s.sku, s.cantidad_entregada using errcode = '22023';
      end if;
    end loop;

    for u in
      select (x ->> 'producto_id')::uuid as producto_id, sum((x ->> 'usadas')::numeric) as usadas
        from jsonb_array_elements(p_uso) x group by 1
    loop
      update orden_surtido set cantidad_usada = u.usadas
       where orden_id = o.id and producto_id = u.producto_id;
      if u.usadas > 0 then
        insert into movimientos_inventario
          (producto_id, tipo, cantidad, cliente_id, orden_id, tecnico_id, referencia, notas, usuario)
        values
          (u.producto_id, 'consumo_tecnico', u.usadas, o.cliente_id, o.id, o.tecnico_id,
           'OS-' || o.folio, 'Material usado en el servicio', quien);
        v_consumos := v_consumos + 1;
      end if;
    end loop;
  end if;

  select coalesce(jsonb_agg(f.valor), '[]'::jsonb) into v_fotos
  from orden_partes p, jsonb_array_elements(p.fotos) as f(valor)
  where p.orden_id = o.id;

  v_obs := nullif(trim(coalesce(p_observaciones, '')), '');
  if p_firma is null then
    v_obs := coalesce(v_obs || E'\n', '') || 'El cliente no firmó la orden.';
  end if;

  update ordenes_servicio
     set trabajos_realizados = v_trabajos,
         fotos = v_fotos,
         firma_cliente = p_firma,
         horas_equipo = p_horas,
         observaciones = v_obs,
         recomendaciones = nullif(trim(coalesce(p_recomendaciones, '')), ''),
         requiere_seguimiento = coalesce(p_seguimiento, false),
         fecha_seguimiento = case when coalesce(p_seguimiento, false) then p_fecha_seguimiento else null end,
         -- Lo que usó y no le entregaron: "adicional", por conciliar.
         refacciones = coalesce((
           select jsonb_agg(r || jsonb_build_object('adicional', true, 'conciliada', false))
             from jsonb_array_elements(p_refacciones) r), '[]'::jsonb),
         estado = 'cerrada'
   where id = o.id;

  update citas set estado = 'realizada'
   where id = o.cita_id and estado in ('programada', 'por_programar');

  return jsonb_build_object('ok', true, 'folio', o.folio, 'fotos', jsonb_array_length(v_fotos),
                            'consumos', v_consumos);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.conciliar_adicional(p_orden uuid, p_nota text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o ordenes_servicio%rowtype;
begin
  if not _es_almacen() then
    raise exception 'Solo el almacén o el administrador.' using errcode = '42501';
  end if;
  select * into o from ordenes_servicio where id = p_orden for update;
  if not found then raise exception 'La orden no existe.' using errcode = 'P0002'; end if;
  if jsonb_typeof(o.refacciones) is distinct from 'array' then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;

  update ordenes_servicio
     set refacciones = (
       select coalesce(jsonb_agg(
                case when (r ->> 'adicional') = 'true' and coalesce(r ->> 'conciliada', 'false') <> 'true'
                     then r || jsonb_build_object('conciliada', true,
                                                  'conciliada_nota', nullif(trim(coalesce(p_nota, '')), ''),
                                                  'conciliada_el', now())
                     else r end
                order by ord), '[]'::jsonb)
         from jsonb_array_elements(o.refacciones) with ordinality as t(r, ord))
   where id = o.id;
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.crear_entrega(p_orden uuid, p_lineas jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o ordenes_servicio%rowtype;
  l record;
  v_pend numeric;
  v_fisico numeric;
  v_id uuid;
  v_folio bigint;
begin
  if not _es_almacen() then
    raise exception 'Solo el almacén o el administrador.' using errcode = '42501';
  end if;
  select * into o from ordenes_servicio where id = p_orden for update;
  if not found then raise exception 'La orden no existe.' using errcode = 'P0002'; end if;
  if o.estado <> 'abierta' then
    raise exception 'La orden ya no está abierta.' using errcode = '22023';
  end if;
  if o.tecnico_id is null then
    raise exception 'La orden no tiene técnico responsable.' using errcode = '22023';
  end if;
  if jsonb_typeof(p_lineas) is distinct from 'array' or jsonb_array_length(p_lineas) = 0 then
    raise exception 'Elige al menos una pieza.' using errcode = '22023';
  end if;

  for l in
    select (x ->> 'producto_id')::uuid as producto_id, sum((x ->> 'cantidad')::numeric) as cantidad
    from jsonb_array_elements(p_lineas) x group by 1
  loop
    if l.cantidad is null or l.cantidad <= 0 then
      raise exception 'Las cantidades deben ser mayores que cero.' using errcode = '22023';
    end if;
    select s.cantidad_pedida - s.cantidad_entregada - coalesce((
             select sum(el.cantidad) from entrega_lineas el join entregas en on en.id = el.entrega_id
              where en.orden_id = p_orden and en.estado = 'pendiente'
                and el.producto_id = l.producto_id), 0)
      into v_pend
      from orden_surtido s where s.orden_id = p_orden and s.producto_id = l.producto_id;
    if not found then
      raise exception 'Esa pieza no está en la lista de surtido de la orden.' using errcode = '22023';
    end if;
    if l.cantidad > v_pend then
      raise exception 'Solo quedan % por entregar de una pieza.', v_pend using errcode = '22023';
    end if;
    select fisico into v_fisico from existencias where id = l.producto_id;
    if l.cantidad > coalesce(v_fisico, 0) then
      raise exception 'No hay existencia suficiente (hay %, se piden %).',
        coalesce(v_fisico, 0), l.cantidad using errcode = '22023';
    end if;
  end loop;

  insert into entregas (orden_id, entregado_por, recibido_por)
  values (p_orden, auth.uid(), o.tecnico_id)
  returning id, folio into v_id, v_folio;

  insert into entrega_lineas (entrega_id, producto_id, sku, nombre, unidad, cantidad)
  select v_id, s.producto_id, s.sku, s.nombre, s.unidad, q.cantidad
  from (
    select (x ->> 'producto_id')::uuid as producto_id, sum((x ->> 'cantidad')::numeric) as cantidad
    from jsonb_array_elements(p_lineas) x group by 1
  ) q
  join orden_surtido s on s.orden_id = p_orden and s.producto_id = q.producto_id;

  return jsonb_build_object('ok', true, 'entrega_id', v_id, 'folio', v_folio);
end $function$
;

CREATE OR REPLACE FUNCTION public.crear_perfil()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  insert into perfiles (id, email, nombre)
  values (new.id, new.email, split_part(new.email, '@', 1))
  on conflict (id) do nothing;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public.descartar_solicitud_material(p_id uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s solicitudes_material%rowtype;
begin
  if not _es_almacen() then
    raise exception 'Solo el almacén o el administrador.' using errcode = '42501';
  end if;
  if nullif(trim(coalesce(p_motivo, '')), '') is null then
    raise exception 'Escribe el motivo.' using errcode = '22023';
  end if;
  select * into s from solicitudes_material where id = p_id for update;
  if not found then raise exception 'La solicitud no existe.' using errcode = 'P0002'; end if;
  if s.estado <> 'pendiente' then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'estado', s.estado);
  end if;

  update solicitudes_material
     set estado = 'descartada', resolucion = trim(p_motivo),
         atendida_por = coalesce(auth.jwt() ->> 'email', 'crm'), atendida_at = now()
   where id = p_id;
  return jsonb_build_object('ok', true, 'folio', s.folio);
end $function$
;

CREATE OR REPLACE FUNCTION public.devoluciones_pendientes()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r jsonb;
begin
  if not _es_almacen() then
    raise exception 'Solo el almacén o el administrador.' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(t.obj order by t.dias desc, t.folio), '[]'::jsonb) into r
  from (
    select o.folio,
           floor(extract(epoch from (now() - o.updated_at)) / 86400)::int as dias,
           jsonb_build_object(
             'orden_id', o.id, 'folio', o.folio, 'estado', o.estado,
             'cliente', cl.nombre,
             'cerrada_el', o.updated_at,
             'dias', floor(extract(epoch from (now() - o.updated_at)) / 86400)::int,
             'tecnico1', t1.nombre, 'tecnico2', t2.nombre,
             'lineas', (
               select coalesce(jsonb_agg(jsonb_build_object(
                   'producto_id', s.producto_id, 'sku', s.sku, 'nombre', s.nombre, 'unidad', s.unidad,
                   'entregada', s.cantidad_entregada, 'usada', s.cantidad_usada,
                   'devuelta', s.cantidad_devuelta, 'diferencia', s.cantidad_diferencia,
                   'pendiente', s.cantidad_entregada - s.cantidad_usada - s.cantidad_devuelta - s.cantidad_diferencia
                 ) order by s.nombre), '[]'::jsonb)
                 from orden_surtido s where s.orden_id = o.id and s.cantidad_entregada > 0),
             'devoluciones', (
               select coalesce(jsonb_agg(jsonb_build_object(
                   'folio', d.folio, 'observaciones', d.observaciones, 'fecha', d.created_at
                 ) order by d.created_at desc), '[]'::jsonb)
                 from devoluciones d where d.orden_id = o.id)
           ) as obj
      from ordenes_servicio o
      join clientes cl on cl.id = o.cliente_id
      left join perfiles t1 on t1.id = o.tecnico_id
      left join perfiles t2 on t2.id = o.tecnico2_id
     where o.estado in ('cerrada', 'cancelada')
       and exists (select 1 from orden_surtido s
                    where s.orden_id = o.id
                      and s.cantidad_entregada - s.cantidad_usada - s.cantidad_devuelta - s.cantidad_diferencia > 0)
  ) t;
  return r;
end $function$
;

CREATE OR REPLACE FUNCTION public.empalmes_de(p_fecha date, p_hora time without time zone, p_dur integer, p_t1 uuid, p_t2 uuid, p_excluir uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.entregar_sin_firma(p_entrega uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare e entregas%rowtype;
begin
  if not _es_almacen() then
    raise exception 'Solo el almacén o el administrador.' using errcode = '42501';
  end if;
  if nullif(trim(coalesce(p_motivo, '')), '') is null then
    raise exception 'Escribe por qué no se firmó.' using errcode = '22023';
  end if;
  select * into e from entregas where id = p_entrega for update;
  if not found then raise exception 'La entrega no existe.' using errcode = 'P0002'; end if;
  if e.estado in ('firmada', 'sin_firma') then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'folio', e.folio);
  end if;
  if e.estado <> 'pendiente' then
    raise exception 'Esta entrega fue cancelada.' using errcode = '22023';
  end if;

  perform _aplicar_entrega(e.id, 'sin_firma', null, trim(p_motivo));
  return jsonb_build_object('ok', true, 'folio', e.folio);
end $function$
;

CREATE OR REPLACE FUNCTION public.equipo_de_orden(p_orden uuid, p_equipo uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.equipos_sin_serie()
 RETURNS TABLE(equipo_id uuid, cliente_id uuid, cliente text, tipo text, marca text, modelo text, capacidad_kw numeric, ubicacion_equipo text, dado_de_alta timestamp with time zone, ultima_orden integer, ultima_visita date)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.es_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((select rol from perfiles where id = auth.uid() and activo) = 'admin', false)
$function$
;

CREATE OR REPLACE FUNCTION public.fijar_surtido(p_orden uuid, p_producto uuid, p_cantidad numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o ordenes_servicio%rowtype;
  s orden_surtido%rowtype;
  v_pend numeric;
  p productos%rowtype;
begin
  if not _es_almacen() then
    raise exception 'Solo el almacén o el administrador.' using errcode = '42501';
  end if;
  if p_cantidad is null or p_cantidad < 0 then
    raise exception 'La cantidad no es válida.' using errcode = '22023';
  end if;
  select * into o from ordenes_servicio where id = p_orden for update;
  if not found then raise exception 'La orden no existe.' using errcode = 'P0002'; end if;
  if o.estado <> 'abierta' then
    raise exception 'La orden ya no está abierta.' using errcode = '22023';
  end if;

  select * into s from orden_surtido where orden_id = p_orden and producto_id = p_producto;
  if found then
    select coalesce(sum(el.cantidad), 0) into v_pend
      from entrega_lineas el join entregas en on en.id = el.entrega_id
     where en.orden_id = p_orden and en.estado = 'pendiente' and el.producto_id = p_producto;
    if p_cantidad < s.cantidad_entregada + v_pend then
      raise exception 'Ya hay % entregadas o por firmar de % : no se puede bajar a %.',
        s.cantidad_entregada + v_pend, s.sku, p_cantidad using errcode = '22023';
    end if;
    if p_cantidad = 0 then
      delete from orden_surtido where id = s.id;
    else
      update orden_surtido set cantidad_pedida = p_cantidad where id = s.id;
    end if;
  elsif p_cantidad > 0 then
    select * into p from productos where id = p_producto and activo;
    if not found then raise exception 'La pieza no existe.' using errcode = 'P0002'; end if;
    insert into orden_surtido (orden_id, producto_id, sku, nombre, unidad, cantidad_pedida, origen)
    values (p_orden, p_producto, p.sku, p.nombre, p.unidad, p_cantidad, 'manual');
  end if;

  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.firmar_entrega(p_entrega uuid, p_firma text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  e entregas%rowtype;
  o ordenes_servicio%rowtype;
begin
  select * into e from entregas where id = p_entrega for update;
  if not found then raise exception 'La entrega no existe.' using errcode = 'P0002'; end if;
  select * into o from ordenes_servicio where id = e.orden_id;

  if not (coalesce(mi_rol() = 'tecnico', false) and o.tecnico_id = auth.uid()) then
    raise exception 'Solo el técnico responsable de la orden firma de recibido.' using errcode = '42501';
  end if;
  if e.estado in ('firmada', 'sin_firma') then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'folio', e.folio);
  end if;
  if e.estado <> 'pendiente' then
    raise exception 'Esta entrega fue cancelada.' using errcode = '22023';
  end if;
  if p_firma is null or p_firma !~ '^entregas/' then
    raise exception 'Falta la firma.' using errcode = '22023';
  end if;

  perform _aplicar_entrega(e.id, 'firmada', p_firma, null);
  return jsonb_build_object('ok', true, 'folio', e.folio);
end $function$
;

CREATE OR REPLACE FUNCTION public.guardar_placa(p_orden uuid, p_rol text, p_ruta text DEFAULT NULL::text, p_datos jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.identificar_telefono(p_telefono text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_norm text := normalizar_telefono(p_telefono);
  r jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if v_norm is null then
    return '[]'::jsonb;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'contacto_id', c.id,
      'nombre', c.nombre,
      'puesto', c.puesto,
      'verificado', c.verificado,
      'whatsapp', c.whatsapp,
      'cliente_id', c.cliente_id,
      'cliente', cl.nombre,
      'de_toda_la_empresa', c.de_toda_la_empresa,
      'equipos', (
        select coalesce(jsonb_agg(jsonb_build_object(
            'equipo_id', x.equipo_id,
            'descripcion', nullif(trim(concat_ws(' ', eq.tipo, eq.marca, eq.modelo,
                              case when eq.capacidad_kw is not null then eq.capacidad_kw || ' kW' end)), ''),
            'numero_serie', eq.numero_serie,
            'rol', x.rol,
            'origen', x.origen,
            'puede_pedir_citas', x.puede_pedir_citas,
            'recibe_ordenes', x.recibe_ordenes,
            'recibe_cotizaciones', x.recibe_cotizaciones,
            'en_poliza', eq.en_poliza,
            'ultima_orden', (
              select jsonb_build_object('folio', o.folio, 'fecha', o.fecha, 'estado', o.estado)
                from ordenes_servicio o
               where o.equipo_id = x.equipo_id
               order by o.fecha desc nulls last, o.folio desc limit 1)
          ) order by eq.numero_serie), '[]'::jsonb)
        from contactos_por_equipo x
        join equipos eq on eq.id = x.equipo_id
        where x.contacto_id = c.id)
    ) order by cl.nombre), '[]'::jsonb)
    into r
  from contactos c
  join clientes cl on cl.id = c.cliente_id
  where c.activo and c.telefono_norm = v_norm;

  return r;
end $function$
;

CREATE OR REPLACE FUNCTION public.lista_tecnicos()
 RETURNS TABLE(id uuid, nombre text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select p.id, coalesce(p.nombre, p.email)
  from perfiles p
  where p.rol = 'tecnico' and p.activo and mi_rol() in ('admin', 'tecnico')
  order by 2
$function$
;

CREATE OR REPLACE FUNCTION public.marcar_aviso(p_id uuid, p_estado text, p_canal text DEFAULT 'whatsapp_manual'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a avisos%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if p_estado not in ('enviado', 'descartado') then
    raise exception 'Estado no válido: %', p_estado using errcode = '22023';
  end if;
  select * into a from avisos where id = p_id for update;
  if not found then raise exception 'El aviso no existe.' using errcode = 'P0002'; end if;
  if a.estado <> 'pendiente' then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'estado', a.estado);
  end if;

  update avisos
     set estado = p_estado,
         canal = case when p_estado = 'enviado' then p_canal end,
         texto_enviado = case when p_estado = 'enviado' then texto_aviso(p_id) end,
         enviado_at = case when p_estado = 'enviado' then now() end,
         enviado_por = coalesce(auth.jwt() ->> 'email', 'crm')
   where id = p_id;
  return jsonb_build_object('ok', true, 'estado', p_estado);
end $function$
;

CREATE OR REPLACE FUNCTION public.marcar_conversacion_leida(p_conversacion uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  update conversaciones set sin_leer = 0 where id = p_conversacion;
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.mi_cliente()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select cliente_id from perfiles where id = auth.uid() and activo
$function$
;

CREATE OR REPLACE FUNCTION public.mi_rol()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select rol from perfiles where id = auth.uid() and activo
$function$
;

CREATE OR REPLACE FUNCTION public.normalizar_telefono(t text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case
    when length(regexp_replace(coalesce(t, ''), '\D', '', 'g')) >= 10
      then right(regexp_replace(t, '\D', '', 'g'), 10)
  end
$function$
;

CREATE OR REPLACE FUNCTION public.orden_abierta(p_orden uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from ordenes_servicio o where o.id = p_orden and o.estado = 'abierta')
$function$
;

CREATE OR REPLACE FUNCTION public.ordenes_por_surtir()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r jsonb;
begin
  if not _es_almacen() then
    raise exception 'Solo el almacén o el administrador.' using errcode = '42501';
  end if;

  perform _preparar_surtido(o.id)
    from ordenes_servicio o join citas ci on ci.id = o.cita_id
   where o.estado = 'abierta' and ci.estado = 'programada';

  select coalesce(jsonb_agg(t.obj order by t.fecha nulls last, t.hora nulls last), '[]'::jsonb)
    into r
  from (
    select ci.fecha, ci.hora,
      jsonb_build_object(
        'orden_id', o.id, 'folio', o.folio,
        'cliente', cl.nombre,
        'equipo', nullif(trim(concat_ws(' ', eq.tipo, eq.marca, eq.numero_serie)), ''),
        'tipo_servicio', o.tipo_servicio,
        'fecha', ci.fecha, 'hora', ci.hora,
        'tecnico1', t1.nombre, 'tecnico2', t2.nombre,
        'lineas', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'producto_id', s.producto_id, 'sku', s.sku, 'nombre', s.nombre, 'unidad', s.unidad,
            'pedida', s.cantidad_pedida, 'entregada', s.cantidad_entregada,
            'en_entrega', coalesce((
               select sum(el.cantidad) from entrega_lineas el
                 join entregas en on en.id = el.entrega_id
                where en.orden_id = o.id and en.estado = 'pendiente'
                  and el.producto_id = s.producto_id), 0),
            'fisico', coalesce((select ex.fisico from existencias ex where ex.id = s.producto_id), 0),
            'origen', s.origen) order by s.nombre), '[]'::jsonb)
          from orden_surtido s where s.orden_id = o.id),
        'entregas', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'id', en.id, 'folio', en.folio, 'estado', en.estado,
            'lineas', (select coalesce(jsonb_agg(jsonb_build_object(
                          'sku', el.sku, 'nombre', el.nombre, 'cantidad', el.cantidad)), '[]'::jsonb)
                         from entrega_lineas el where el.entrega_id = en.id)
          ) order by en.folio), '[]'::jsonb)
          from entregas en where en.orden_id = o.id and en.estado <> 'cancelada')
      ) as obj
    from ordenes_servicio o
    join citas ci on ci.id = o.cita_id
    left join clientes cl on cl.id = o.cliente_id
    left join equipos eq on eq.id = o.equipo_id
    left join perfiles t1 on t1.id = o.tecnico_id
    left join perfiles t2 on t2.id = o.tecnico2_id
    where o.estado = 'abierta' and ci.estado = 'programada'
  ) t;

  return r;
end $function$
;

CREATE OR REPLACE FUNCTION public.paquete_preventivo(p_equipo uuid, p_tipo text DEFAULT 'menor'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  e equipos%rowtype;
  v_clase text;
  v_cap numeric;
  v_tarifa record;
  v_paquete paquetes_mantenimiento%rowtype;
  v_lineas jsonb;
begin
  if not es_admin() and not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector de WhatsApp.' using errcode = '42501';
  end if;
  if p_tipo not in ('menor', 'mayor') then
    raise exception 'El mantenimiento es menor o mayor: %', p_tipo using errcode = '22023';
  end if;

  select * into e from equipos where id = p_equipo;
  if not found then raise exception 'Ese equipo no existe.' using errcode = 'P0002'; end if;

  v_clase := _clase_de_equipo(e);
  v_cap := _capacidad_de_equipo(e);

  select t.sku, t.nombre, t.precio into v_tarifa
    from tarifas_servicio t
   where t.activo
     and t.concepto = 'preventivo_' || p_tipo
     and (t.clase is null or t.clase = v_clase)
     and (t.kw_desde is null or (v_cap is not null and v_cap >= t.kw_desde))
     and (t.kw_hasta is null or (v_cap is not null and v_cap <= t.kw_hasta))
   order by (t.clase is not null) desc, t.kw_desde desc nulls last
   limit 1;

  select * into v_paquete from paquetes_mantenimiento
   where id = _paquete_de_equipo(p_equipo, p_tipo);

  if v_paquete.id is not null then
    select coalesce(jsonb_agg(x order by x ->> 'orden'), '[]'::jsonb) into v_lineas
    from (
      select jsonb_build_object(
        'linea_id', l.id,
        'descripcion', l.descripcion,
        'cantidad', l.cantidad,
        'orden', lpad(l.orden::text, 4, '0'),
        'opciones', (
          select coalesce(jsonb_agg(jsonb_build_object(
                   'producto_id', c.producto_id, 'sku', c.sku, 'nombre', c.nombre,
                   'unidad', c.unidad, 'precio', pr.precio,
                   'disponible', c.disponible, 'preferido', c.preferido)), '[]'::jsonb)
            from _codigos_de_linea(l.id) c
            join productos pr on pr.id = c.producto_id
        )) as x
      from paquete_lineas l
      where l.paquete_id = v_paquete.id
    ) z;
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'ok', true,
    'equipo_id', e.id,
    'clase', v_clase,
    'capacidad', v_cap,
    'tipo', p_tipo,
    'servicio', case when v_tarifa.sku is not null then jsonb_build_object(
        'sku', v_tarifa.sku, 'nombre', v_tarifa.nombre, 'precio', v_tarifa.precio) end,
    'paquete', case when v_paquete.id is not null then jsonb_build_object(
        'paquete_id', v_paquete.id, 'nombre', v_paquete.nombre) end,
    'lineas', coalesce(v_lineas, '[]'::jsonb),
    'falta', case
      when v_clase is null then 'No se sabe de qué clase es el equipo: captura el combustible.'
      when v_cap is null then 'El equipo no tiene capacidad capturada.'
      when v_tarifa.sku is null then 'No hay tarifa de mantenimiento ' || p_tipo ||
                                    ' para esa clase y capacidad: captúrala en Tarifas.'
      when v_paquete.id is null then 'No hay paquete de refacciones para ese equipo todavía.'
      end));
end $function$
;

CREATE OR REPLACE FUNCTION public.piezas_que_se_repiten(p_clase text DEFAULT NULL::text, p_kw_desde numeric DEFAULT NULL::numeric, p_kw_hasta numeric DEFAULT NULL::numeric, p_marca text DEFAULT NULL::text, p_modelo text DEFAULT NULL::text, p_desde date DEFAULT NULL::date)
 RETURNS TABLE(producto_id uuid, sku text, nombre text, unidad text, visitas bigint, de_visitas bigint, cantidad_tipica numeric, ultima_vez date)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with parecidos as (
    select e.id
      from equipos e
     where (p_clase is null or _clase_de_equipo(e) = p_clase)
       and (p_kw_desde is null or _capacidad_de_equipo(e) >= p_kw_desde)
       and (p_kw_hasta is null or _capacidad_de_equipo(e) <= p_kw_hasta)
       and (p_marca is null or lower(e.marca) = lower(p_marca))
       and (p_modelo is null or lower(e.modelo) = lower(p_modelo))
  ),
  cerradas as (
    select o.id, o.fecha
      from ordenes_servicio o
      join parecidos p on p.id = o.equipo_id
     where o.estado = 'cerrada'
       and (p_desde is null or o.fecha >= p_desde)
  ),
  usado as (
    select s.producto_id, v.id as orden_id, v.fecha, s.cantidad_usada
      from orden_surtido s
      join cerradas v on v.id = s.orden_id
     where coalesce(s.cantidad_usada, 0) > 0
  )
  select u.producto_id, p.sku, p.nombre, p.unidad,
         count(distinct u.orden_id),
         (select count(*) from cerradas),
         mode() within group (order by u.cantidad_usada),
         max(u.fecha)
    from usado u
    join productos p on p.id = u.producto_id
   where es_admin()
   group by u.producto_id, p.sku, p.nombre, p.unidad
   order by count(distinct u.orden_id) desc, p.sku;
$function$
;

CREATE OR REPLACE FUNCTION public.programar_cita(p_cita uuid, p_fecha date, p_hora time without time zone, p_duracion integer, p_t1 uuid, p_t2 uuid, p_confirmar boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.recibir_devolucion(p_orden uuid, p_lineas jsonb, p_observaciones text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o ordenes_servicio%rowtype;
  l record;
  s orden_surtido%rowtype;
  v_pend numeric;
  v_obs text := nullif(trim(coalesce(p_observaciones, '')), '');
  v_falta boolean := false;
  v_id uuid;
  v_folio bigint;
  v_detalle jsonb := '[]'::jsonb;
  v_quedan int;
  quien text := coalesce(auth.jwt() ->> 'email', 'crm');
begin
  if not _es_almacen() then
    raise exception 'Solo el almacén o el administrador.' using errcode = '42501';
  end if;
  select * into o from ordenes_servicio where id = p_orden for update;
  if not found then raise exception 'La orden no existe.' using errcode = 'P0002'; end if;
  if o.estado not in ('cerrada', 'cancelada') then
    raise exception 'La orden sigue abierta: el material se devuelve cuando se cierra.' using errcode = '22023';
  end if;
  if jsonb_typeof(p_lineas) is distinct from 'array' or jsonb_array_length(p_lineas) = 0 then
    raise exception 'Elige al menos una pieza que se devuelve.' using errcode = '22023';
  end if;

  -- Validar todo antes de mover nada.
  for l in
    select (x ->> 'producto_id')::uuid as producto_id, sum((x ->> 'cantidad')::numeric) as cantidad
      from jsonb_array_elements(p_lineas) x group by 1
  loop
    if l.cantidad is null or l.cantidad < 0 then
      raise exception 'Las cantidades no son válidas.' using errcode = '22023';
    end if;
    select * into s from orden_surtido where orden_id = p_orden and producto_id = l.producto_id;
    if not found then
      raise exception 'Esa pieza no está en el material de la orden.' using errcode = '22023';
    end if;
    v_pend := s.cantidad_entregada - s.cantidad_usada - s.cantidad_devuelta - s.cantidad_diferencia;
    if l.cantidad > v_pend then
      raise exception 'De % solo están pendientes % por devolver (se quieren recibir %).',
        s.sku, v_pend, l.cantidad using errcode = '22023';
    end if;
  end loop;

  -- ¿Queda algo pendiente sin devolverse completo?
  -- (el alias es `os` y no `s`: `s` ya es una variable de esta función)
  select exists (
    select 1 from orden_surtido os
     where os.orden_id = p_orden
       and os.cantidad_entregada - os.cantidad_usada - os.cantidad_devuelta - os.cantidad_diferencia
           > coalesce((select sum((x ->> 'cantidad')::numeric)
                         from jsonb_array_elements(p_lineas) x
                        where (x ->> 'producto_id')::uuid = os.producto_id), 0)
  ) into v_falta;
  if v_falta and v_obs is null then
    raise exception 'Escribe una observación: no se devuelve todo lo pendiente.' using errcode = '22023';
  end if;

  insert into devoluciones (orden_id, recibida_por, observaciones)
  values (p_orden, auth.uid(), v_obs)
  returning id, folio into v_id, v_folio;

  for l in
    select (x ->> 'producto_id')::uuid as producto_id, sum((x ->> 'cantidad')::numeric) as cantidad
      from jsonb_array_elements(p_lineas) x group by 1
  loop
    continue when l.cantidad = 0;
    select * into s from orden_surtido where orden_id = p_orden and producto_id = l.producto_id;
    insert into movimientos_inventario
      (producto_id, tipo, cantidad, cliente_id, orden_id, tecnico_id, referencia, notas, usuario)
    values
      (l.producto_id, 'devolucion_tecnico', l.cantidad, o.cliente_id, o.id, o.tecnico_id,
       'DEV-' || v_folio, 'Devolución de material · OS-' || o.folio || coalesce(' · ' || v_obs, ''), quien);
    update orden_surtido set cantidad_devuelta = cantidad_devuelta + l.cantidad
     where id = s.id;
    v_detalle := v_detalle || jsonb_build_object(
      'producto_id', l.producto_id, 'sku', s.sku, 'nombre', s.nombre, 'cantidad', l.cantidad);
  end loop;

  update devoluciones set lineas = v_detalle where id = v_id;

  select count(*) into v_quedan from orden_surtido os
   where os.orden_id = p_orden
     and os.cantidad_entregada - os.cantidad_usada - os.cantidad_devuelta - os.cantidad_diferencia > 0;

  return jsonb_build_object('ok', true, 'folio', v_folio, 'piezas_pendientes', v_quedan);
end $function$
;

CREATE OR REPLACE FUNCTION public.registrar_equipo_en_orden(p_orden uuid, p_datos jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.registrar_mensaje_entrante(p_telefono text, p_wa_message_id text, p_texto text DEFAULT NULL::text, p_nombre_wa text DEFAULT NULL::text, p_tipo text DEFAULT 'texto'::text, p_media_id text DEFAULT NULL::text, p_wa_timestamp timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_conv conversaciones%rowtype;
  v_norm text := normalizar_telefono(p_telefono);
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector de WhatsApp.' using errcode = '42501';
  end if;
  if v_norm is null then
    raise exception 'El teléfono no trae 10 dígitos: %', p_telefono using errcode = '22023';
  end if;
  if nullif(trim(coalesce(p_wa_message_id, '')), '') is null then
    raise exception 'Falta el id del mensaje de WhatsApp.' using errcode = '22023';
  end if;

  -- Ya lo teníamos: el webhook entrega al menos una vez.
  if exists (select 1 from mensajes_wa where wa_message_id = p_wa_message_id) then
    return jsonb_build_object('ok', true, 'repetido', true);
  end if;

  select * into v_conv from conversaciones where telefono_norm = v_norm;
  if not found then
    insert into conversaciones (telefono, nombre_wa) values (p_telefono, p_nombre_wa)
    returning * into v_conv;
  end if;

  insert into mensajes_wa (conversacion_id, direccion, tipo, texto, media_id, wa_message_id, estado, wa_timestamp)
  values (v_conv.id, 'entrante', coalesce(p_tipo, 'texto'), p_texto, p_media_id, p_wa_message_id, 'recibido', p_wa_timestamp);

  update conversaciones
     set sin_leer = sin_leer + 1,
         estado = 'abierta',
         ventana_hasta = p_wa_timestamp + interval '24 hours',
         ultimo_mensaje_at = p_wa_timestamp,
         nombre_wa = coalesce(nullif(trim(coalesce(p_nombre_wa, '')), ''), nombre_wa)
   where id = v_conv.id;

  return jsonb_build_object('ok', true, 'conversacion_id', v_conv.id,
                            'contacto_id', v_conv.contacto_id, 'conocido', v_conv.contacto_id is not null);
end $function$
;

CREATE OR REPLACE FUNCTION public.registrar_mensaje_saliente(p_conversacion uuid, p_texto text, p_wa_message_id text DEFAULT NULL::text, p_estado text DEFAULT 'enviado'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_conv conversaciones%rowtype;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector de WhatsApp.' using errcode = '42501';
  end if;
  if nullif(trim(coalesce(p_texto, '')), '') is null then
    raise exception 'El mensaje va vacío.' using errcode = '22023';
  end if;
  select * into v_conv from conversaciones where id = p_conversacion;
  if not found then raise exception 'La conversación no existe.' using errcode = 'P0002'; end if;

  insert into mensajes_wa (conversacion_id, direccion, tipo, texto, wa_message_id, estado, enviado_por, wa_timestamp)
  values (p_conversacion, 'saliente', 'texto', trim(p_texto), p_wa_message_id, p_estado,
          coalesce(auth.jwt() ->> 'email', 'crm'), now());

  update conversaciones set ultimo_mensaje_at = now() where id = p_conversacion;
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.resolver_diferencia(p_orden uuid, p_producto uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o ordenes_servicio%rowtype;
  s orden_surtido%rowtype;
  v_pend numeric;
  quien text := coalesce(auth.jwt() ->> 'email', 'crm');
begin
  if not es_admin() then
    raise exception 'Solo el administrador puede dar por perdido material que no volvió.' using errcode = '42501';
  end if;
  if nullif(trim(coalesce(p_motivo, '')), '') is null then
    raise exception 'Escribe el motivo.' using errcode = '22023';
  end if;
  select * into o from ordenes_servicio where id = p_orden for update;
  if not found then raise exception 'La orden no existe.' using errcode = 'P0002'; end if;
  if o.estado not in ('cerrada', 'cancelada') then
    raise exception 'La orden sigue abierta.' using errcode = '22023';
  end if;
  select * into s from orden_surtido where orden_id = p_orden and producto_id = p_producto for update;
  if not found then raise exception 'Esa pieza no está en el material de la orden.' using errcode = '22023'; end if;

  v_pend := s.cantidad_entregada - s.cantidad_usada - s.cantidad_devuelta - s.cantidad_diferencia;
  if v_pend <= 0 then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;

  insert into movimientos_inventario
    (producto_id, tipo, cantidad, cliente_id, orden_id, tecnico_id, referencia, notas, usuario)
  values
    (p_producto, 'consumo_tecnico', v_pend, o.cliente_id, o.id, o.tecnico_id,
     'DIF-OS-' || o.folio, 'Diferencia dada por consumida: ' || trim(p_motivo), quien);
  update orden_surtido set cantidad_diferencia = cantidad_diferencia + v_pend where id = s.id;

  return jsonb_build_object('ok', true, 'cantidad', v_pend);
end $function$
;

CREATE OR REPLACE FUNCTION public.solicitudes_material_pendientes()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r jsonb;
begin
  if not _es_almacen() then
    raise exception 'Solo el almacén o el administrador.' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', s.id, 'folio', s.folio, 'creada_el', s.created_at,
      'tecnico', coalesce(p.nombre, p.email),
      'cliente', cl.nombre,
      'equipo', nullif(trim(concat_ws(' ', eq.tipo, eq.marca, eq.modelo,
                 case when eq.capacidad_kw is not null then eq.capacidad_kw || ' kW' end)), ''),
      'numero_serie', eq.numero_serie,
      'orden_folio', o.folio,
      'sku', s.sku, 'nombre', coalesce(s.nombre, s.descripcion_libre), 'unidad', s.unidad,
      'cantidad', s.cantidad, 'nota', s.nota,
      'fisico', (select ex.fisico from existencias ex where ex.id = s.producto_id)
    ) order by s.created_at), '[]'::jsonb)
    into r
  from solicitudes_material s
  join perfiles p on p.id = s.tecnico_id
  left join clientes cl on cl.id = s.cliente_id
  left join equipos eq on eq.id = s.equipo_id
  left join ordenes_servicio o on o.id = s.orden_id
  where s.estado = 'pendiente';

  return r;
end $function$
;

CREATE OR REPLACE FUNCTION public.soy_de_la_orden(p_orden uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select mi_rol() = 'tecnico' and exists (
    select 1 from ordenes_servicio o
    where o.id = p_orden and auth.uid() in (o.tecnico_id, o.tecnico2_id)
  )
$function$
;

CREATE OR REPLACE FUNCTION public.surtido_desde_paquete(p_orden uuid, p_tipo text DEFAULT 'menor'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o ordenes_servicio%rowtype;
  v_paquete uuid;
  l record;
  c record;
  n int := 0;
  v_sin_codigo text := '';
begin
  if not _es_almacen() then
    raise exception 'Solo el almacén o el administrador.' using errcode = '42501';
  end if;
  if p_tipo not in ('menor', 'mayor') then
    raise exception 'El mantenimiento es menor o mayor: %', p_tipo using errcode = '22023';
  end if;

  select * into o from ordenes_servicio where id = p_orden;
  if not found then raise exception 'La orden no existe.' using errcode = 'P0002'; end if;
  if o.estado <> 'abierta' then
    raise exception 'La orden ya está cerrada.' using errcode = '22023';
  end if;
  if o.equipo_id is null then
    raise exception 'La orden no dice de qué equipo es: sin eso no se sabe qué preparar.'
      using errcode = '22023';
  end if;

  v_paquete := _paquete_de_equipo(o.equipo_id, p_tipo);
  if v_paquete is null then
    return jsonb_build_object('ok', true, 'agregadas', 0,
      'motivo', 'Ese equipo no tiene paquete de mantenimiento ' || p_tipo || ' todavía.');
  end if;

  for l in select * from paquete_lineas where paquete_id = v_paquete order by orden loop
    -- El que más haya. `_codigos_de_linea` ya ordena por disponible dentro de cada grupo,
    -- pero aquí manda la existencia aunque no sea el preferido: es para surtir hoy.
    select * into c from _codigos_de_linea(l.id) order by disponible desc limit 1;

    if c.producto_id is null then
      v_sin_codigo := concat_ws(', ', nullif(v_sin_codigo, ''), l.descripcion);
      continue;
    end if;

    insert into orden_surtido (orden_id, producto_id, sku, nombre, unidad, cantidad_pedida, origen)
    values (p_orden, c.producto_id, c.sku, c.nombre, c.unidad, l.cantidad, 'paquete')
    on conflict (orden_id, producto_id) do nothing;
    if found then n := n + 1; end if;
  end loop;

  perform _apunta('ordenes_servicio', p_orden, 'surtido_de_paquete', null,
    jsonb_build_object('tipo', p_tipo, 'paquete', v_paquete, 'agregadas', n), 'paquete');

  return jsonb_build_object('ok', true, 'agregadas', n, 'sin_codigo', nullif(v_sin_codigo, ''));
end $function$
;

CREATE OR REPLACE FUNCTION public.texto_aviso(p_aviso uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  a avisos%rowtype;
  c citas%rowtype;
  cl clientes%rowtype;
  eq equipos%rowtype;
  v_dias text[] := array['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado'];
  v_meses text[] := array['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto',
                          'septiembre', 'octubre', 'noviembre', 'diciembre'];
  v_folio bigint;
  v_t1 text; v_t2 text; v_tec text;
  v_cuando text; v_tipo text; v_equipo text; v_dir text; v_contactos text;
  v_dur text; v_hola text; v_rol text; v_titulo text;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  select * into a from avisos where id = p_aviso;
  if not found then return null; end if;
  select * into c from citas where id = a.cita_id;
  select * into cl from clientes where id = c.cliente_id;
  if c.equipo_id is not null then select * into eq from equipos where id = c.equipo_id; end if;
  select folio into v_folio from ordenes_servicio where cita_id = c.id limit 1;   -- cita 1 : 1 orden
  select coalesce(nombre, email) into v_t1 from perfiles where id = c.tecnico_id;
  select coalesce(nombre, email) into v_t2 from perfiles where id = c.tecnico2_id;
  v_tec := concat_ws(' y ', v_t1, v_t2);

  v_cuando := case when c.fecha is null then 'por definir' else
      v_dias[extract(dow from c.fecha)::int + 1] || ' ' || extract(day from c.fecha)::int
      || ' de ' || v_meses[extract(month from c.fecha)::int]
      || case when c.hora is not null then ' a las ' || left(c.hora::text, 5) || ' h' else '' end
    end;
  v_dur := case when c.duracion_min is not null then 'Duración aproximada: ' || c.duracion_min || ' min' end;
  v_tipo := case c.tipo_servicio
              when 'preventivo' then 'mantenimiento preventivo'
              when 'correctivo' then 'servicio correctivo'
              when 'instalacion' then 'instalación'
              when 'diagnostico' then 'diagnóstico'
              when 'visita_tecnica' then 'visita técnica'
              else coalesce(c.tipo_servicio, 'servicio') end;
  v_equipo := nullif(trim(concat_ws(' ', eq.tipo, eq.marca, eq.modelo,
                case when eq.capacidad_kw is not null then eq.capacidad_kw || ' kW' end)), '');

  -- ---------------- cliente ----------------
  if a.destinatario = 'cliente' then
    v_hola := case when nullif(trim(a.nombre), '') is not null then 'Hola ' || trim(a.nombre) || ',' else 'Hola,' end;
    if a.tipo = 'cancelacion' then
      return concat_ws(E'\n', v_hola, '',
        'Le informamos que su cita de ' || v_tipo || coalesce(' de su ' || v_equipo, '')
          || ' del ' || v_cuando || ' fue cancelada.',
        '', 'Nos pondremos en contacto para reagendarla. Disculpe las molestias.', 'PowerMx');
    end if;
    return concat_ws(E'\n', v_hola, '',
      case when a.tipo = 'reprogramacion'
           then 'Le informamos que su cita con PowerMx fue reprogramada: ' || v_tipo || coalesce(' de su ' || v_equipo, '') || '.'
           else 'Le confirmamos su cita con PowerMx: ' || v_tipo || coalesce(' de su ' || v_equipo, '') || '.' end,
      '',
      case when a.tipo = 'reprogramacion' then 'Nueva fecha: ' else 'Fecha: ' end || v_cuando,
      v_dur,
      case when v_tec <> '' then 'Lo atenderá: ' || v_tec end,
      '', 'Si necesita cambiar la fecha, responda a este mensaje.', 'PowerMx');
  end if;

  -- ---------------- técnico ----------------
  v_titulo := case
    when a.tipo = 'cancelacion' and c.estado = 'cancelada' then 'Servicio CANCELADO'
    when a.tipo = 'cancelacion' then 'Ya no estás asignado a este servicio'
    when a.tipo = 'reprogramacion' then 'CAMBIO en el servicio'
    else 'Nuevo servicio' end;

  if a.tipo = 'cancelacion' then
    return concat_ws(E'\n', v_titulo,
      case when v_folio is not null then 'OS-' || v_folio || ' · ' || v_tipo end,
      'Cliente: ' || cl.nombre,
      'Estaba programado: ' || v_cuando);
  end if;

  v_dir := nullif(concat_ws(', ', nullif(trim(cl.direccion), ''), nullif(trim(cl.colonia), ''), nullif(trim(cl.municipio), '')), '');

  -- Contacto en sitio: primero el responsable del equipo, luego los demás (hasta 3).
  select string_agg(x.linea, E'\n') into v_contactos from (
    select ct.nombre || case when nullif(trim(ct.puesto), '') is not null then ' (' || trim(ct.puesto) || ')' else '' end
           || coalesce(': ' || ct.telefono, '') as linea
      from contactos ct
     where ct.activo and ct.cliente_id = c.cliente_id
       and ((c.equipo_id is not null and ct.id in (select v.contacto_id from contactos_por_equipo v where v.equipo_id = c.equipo_id))
            or (c.equipo_id is null and ct.de_toda_la_empresa))
     order by (c.equipo_id is not null and ct.id in
                (select e.contacto_id from equipo_contactos e where e.equipo_id = c.equipo_id and e.rol = 'responsable')) desc,
              ct.nombre
     limit 3) x;
  if v_contactos is null then
    v_contactos := nullif(concat_ws(': ', nullif(trim(cl.contacto_nombre), ''), nullif(trim(cl.telefono), '')), '');
  end if;

  v_rol := case when a.perfil_id = c.tecnico_id
                then 'Eres el responsable' || coalesce(' · Ayudante: ' || v_t2, '')
                else 'Eres el ayudante · Responsable: ' || coalesce(v_t1, 'sin asignar') end;

  return concat_ws(E'\n', v_titulo,
    case when v_folio is not null then 'OS-' || v_folio || ' · ' || v_tipo else initcap(v_tipo) end,
    '',
    'Fecha: ' || v_cuando, v_dur,
    '',
    'Cliente: ' || cl.nombre,
    case when v_contactos is not null then 'Contacto en sitio:' || E'\n' || v_contactos end,
    case when v_dir is not null then 'Dirección: ' || v_dir end,
    case when nullif(trim(cl.referencias), '') is not null then 'Referencias: ' || trim(cl.referencias) end,
    case when nullif(trim(cl.maps_url), '') is not null then 'Cómo llegar: ' || trim(cl.maps_url) end,
    case when v_equipo is not null then 'Equipo: ' || v_equipo || coalesce(' (serie ' || eq.numero_serie || ')', '') end,
    '',
    v_rol,
    case when nullif(trim(c.notas), '') is not null then 'Notas: ' || trim(c.notas) end);
end $function$
;

CREATE OR REPLACE FUNCTION public.tocar_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.updated_at := now();
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public.unaccent_inmutable(text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE STRICT
AS $function$
  select extensions.unaccent('extensions.unaccent'::regdictionary, $1)
$function$
;

CREATE OR REPLACE FUNCTION public.vincular_contacto(p_equipo uuid, p_contacto uuid, p_rol text, p_pedir_citas boolean DEFAULT NULL::boolean, p_ordenes boolean DEFAULT NULL::boolean, p_cotizaciones boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cliente_equipo uuid;
  v_cliente_contacto uuid;
  v_citas boolean;
  v_ord boolean;
  v_cot boolean;
  v_bajados int := 0;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if p_rol not in ('responsable', 'encargado', 'administracion', 'solo_avisos') then
    raise exception 'Rol no válido: %', p_rol using errcode = '22023';
  end if;

  select cliente_id into v_cliente_equipo from equipos where id = p_equipo;
  if not found then raise exception 'El equipo no existe.' using errcode = 'P0002'; end if;
  select cliente_id into v_cliente_contacto from contactos where id = p_contacto and activo;
  if not found then raise exception 'El contacto no existe o está inactivo.' using errcode = 'P0002'; end if;
  if v_cliente_equipo is distinct from v_cliente_contacto then
    raise exception 'La persona y el equipo son de clientes distintos.' using errcode = '22023';
  end if;

  -- Permisos por defecto de cada rol.
  v_citas := coalesce(p_pedir_citas, p_rol in ('responsable', 'encargado'));
  v_ord   := coalesce(p_ordenes,     true);
  v_cot   := coalesce(p_cotizaciones, p_rol in ('responsable', 'administracion'));

  if p_rol = 'responsable' then
    update equipo_contactos set rol = 'encargado'
     where equipo_id = p_equipo and rol = 'responsable' and contacto_id <> p_contacto;
    get diagnostics v_bajados = row_count;
  end if;

  insert into equipo_contactos
    (equipo_id, contacto_id, rol, puede_pedir_citas, recibe_ordenes, recibe_cotizaciones)
  values (p_equipo, p_contacto, p_rol, v_citas, v_ord, v_cot)
  on conflict (equipo_id, contacto_id) do update
    set rol = excluded.rol,
        puede_pedir_citas = excluded.puede_pedir_citas,
        recibe_ordenes = excluded.recibe_ordenes,
        recibe_cotizaciones = excluded.recibe_cotizaciones;

  return jsonb_build_object('ok', true, 'rol', p_rol, 'responsable_anterior_bajado', v_bajados > 0);
end $function$
;

CREATE OR REPLACE FUNCTION public.vincular_conversacion(p_conversacion uuid, p_contacto uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_cliente uuid;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  select cliente_id into v_cliente from contactos where id = p_contacto and activo;
  if not found then raise exception 'El contacto no existe o está inactivo.' using errcode = 'P0002'; end if;

  update conversaciones set contacto_id = p_contacto, cliente_id = v_cliente
   where id = p_conversacion;
  if not found then raise exception 'La conversación no existe.' using errcode = 'P0002'; end if;
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.wa_contexto(p_conversacion uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cliente uuid;
  v_contacto text;
  v_nombre_cliente text;
  v_equipos jsonb;
  v_n int;
  v_cita jsonb;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el conector de WhatsApp o el administrador.' using errcode = '42501';
  end if;

  v_cliente := _cliente_de_conversacion(p_conversacion);
  if v_cliente is null then
    -- Número sin identificar: no se le da un solo dato de nadie.
    return jsonb_build_object('conocido', false);
  end if;

  select c.nombre into v_contacto
    from conversaciones v join contactos c on c.id = v.contacto_id
   where v.id = p_conversacion;
  select nombre into v_nombre_cliente from clientes where id = v_cliente;

  select count(*) into v_n from equipos
   where cliente_id = v_cliente and coalesce(estado, 'activo') = 'activo';

  select coalesce(jsonb_agg(x order by x ->> 'descripcion'), '[]'::jsonb) into v_equipos
  from (
    select jsonb_strip_nulls(jsonb_build_object(
      'equipo_id', e.id,
      'descripcion', concat_ws(' ', nullif(e.marca, ''), nullif(e.modelo, ''),
                               case when e.capacidad_kw is not null then e.capacidad_kw || ' kW' end),
      'tipo', e.tipo,
      'en_poliza', e.en_poliza,
      'ubicacion', nullif(e.ubicacion_equipo, ''),
      'proximo_mantenimiento', e.proximo_mantenimiento,
      'ultima_visita', (select max(o.fecha) from ordenes_servicio o
                         where o.equipo_id = e.id and o.estado = 'cerrada'),
      -- La serie SOLO cuando hay un equipo: sirve para confirmar de cuál se habla.
      -- Con varios, marca y capacidad bastan y no se reparten series por WhatsApp.
      'numero_serie', case when v_n = 1 then e.numero_serie end
    )) as x
    from equipos e
    where e.cliente_id = v_cliente and coalesce(e.estado, 'activo') = 'activo'
  ) z;

  select jsonb_strip_nulls(jsonb_build_object(
           'fecha', c.fecha, 'hora', c.hora, 'estado', c.estado, 'tipo', c.tipo_servicio))
    into v_cita
    from citas c
   where c.cliente_id = v_cliente
     and c.estado in ('programada', 'por_programar')
   order by c.fecha nulls last
   limit 1;

  return jsonb_strip_nulls(jsonb_build_object(
    'conocido', true,
    'contacto', v_contacto,
    'cliente', v_nombre_cliente,
    'equipos', v_equipos,
    'proxima_cita', v_cita));
end $function$
;

CREATE OR REPLACE FUNCTION public.wa_puede_responder(p_conversacion uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tope int; v_hoy int; v_activo boolean; v_modo text;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el conector de WhatsApp o el administrador.' using errcode = '42501';
  end if;
  select tope_dia, activo, modo into v_tope, v_activo, v_modo from wa_agente where id;

  select count(*) into v_hoy
    from mensajes_wa
   where conversacion_id = p_conversacion
     and direccion = 'saliente'
     and (created_at at time zone 'America/Mexico_City')::date
         = (now() at time zone 'America/Mexico_City')::date;

  return jsonb_build_object(
    'puede', coalesce(v_activo, false) and v_hoy < coalesce(v_tope, 20),
    'activo', coalesce(v_activo, false),
    'modo', coalesce(v_modo, 'borrador'),
    'enviados_hoy', v_hoy,
    'tope', coalesce(v_tope, 20));
end $function$
;

CREATE OR REPLACE FUNCTION public.wa_solicitar_cita(p_conversacion uuid, p_equipo uuid DEFAULT NULL::uuid, p_tipo text DEFAULT 'correctivo'::text, p_nota text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cliente uuid;
  v_cita uuid;
  v_orden uuid;
  v_folio int;
  v_abierta uuid;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el conector de WhatsApp o el administrador.' using errcode = '42501';
  end if;

  v_cliente := _cliente_de_conversacion(p_conversacion);
  if v_cliente is null then
    raise exception 'Ese número todavía no está ligado a un cliente.' using errcode = '42501';
  end if;
  if p_tipo not in ('preventivo', 'correctivo', 'instalacion', 'diagnostico', 'visita_tecnica') then
    raise exception 'Tipo de servicio no válido: %', p_tipo using errcode = '22023';
  end if;
  -- Un id de equipo que venga de otro lado no liga nada: tiene que ser de ESE cliente.
  if p_equipo is not null and not exists (
       select 1 from equipos where id = p_equipo and cliente_id = v_cliente) then
    raise exception 'Ese equipo no es de este cliente.' using errcode = '42501';
  end if;

  -- Si ya hay una pendiente para el mismo equipo, no se apilan solicitudes: el agente
  -- puede insistir, pero la Agenda no debe llenarse de citas repetidas del mismo número.
  select id into v_abierta from citas
   where cliente_id = v_cliente
     and estado = 'por_programar'
     and coalesce(equipo_id::text, '') = coalesce(p_equipo::text, '')
   limit 1;
  if v_abierta is not null then
    return jsonb_build_object('ok', true, 'repetida', true, 'cita_id', v_abierta);
  end if;

  insert into citas (cliente_id, equipo_id, tipo_servicio, estado, origen, notas)
  values (v_cliente, p_equipo, p_tipo, 'por_programar', 'whatsapp',
          nullif(trim(coalesce(p_nota, '')), ''))
  returning id into v_cita;

  insert into ordenes_servicio (cliente_id, equipo_id, cita_id, tipo_servicio, estado)
  values (v_cliente, p_equipo, v_cita, p_tipo, 'abierta')
  returning id, folio into v_orden, v_folio;

  perform _apunta('citas', v_cita, 'solicitada',
    null,
    jsonb_build_object('conversacion', p_conversacion, 'tipo', p_tipo, 'equipo', p_equipo),
    'whatsapp');

  return jsonb_build_object('ok', true, 'cita_id', v_cita, 'orden_id', v_orden, 'folio', v_folio);
end $function$
;

-- ========== SECUENCIAS SUELTAS ==========

-- ========== TABLAS ==========

create table if not exists public.auditoria (
  id uuid not null,
  tabla text not null,
  registro_id uuid,
  accion text not null,
  valor_anterior jsonb,
  valor_nuevo jsonb,
  origen text,
  usuario text,
  created_at timestamp with time zone
);

create table if not exists public.avisos (
  id uuid not null,
  cita_id uuid not null,
  tipo text not null,
  destinatario text not null,
  llave text not null,
  contacto_id uuid,
  perfil_id uuid,
  nombre text,
  telefono text,
  estado text not null,
  canal text,
  texto_enviado text,
  enviado_at timestamp with time zone,
  enviado_por text,
  created_at timestamp with time zone not null
);

create table if not exists public.catalogos (
  id uuid not null,
  tipo text not null,
  valor text not null,
  valor_normalizado text generated always as (lower(unaccent_inmutable(TRIM(BOTH FROM valor)))) stored,
  usos integer,
  activo boolean,
  created_at timestamp with time zone
);

create table if not exists public.citas (
  id uuid not null,
  cliente_id uuid not null,
  equipo_id uuid,
  tipo_servicio text,
  fecha date,
  hora time without time zone,
  tecnico text,
  zona text,
  notas text,
  estado text,
  created_at timestamp with time zone,
  tecnico_id uuid,
  tecnico2_id uuid,
  duracion_min integer,
  cotizacion_id uuid,
  origen text
);

create table if not exists public.clientes (
  id uuid not null,
  nombre text not null,
  nombre_comercial text,
  tipo_cliente text,
  rfc text,
  telefono text not null,
  telefono_alterno text,
  email text,
  contacto_nombre text,
  direccion text,
  colonia text,
  municipio text,
  estado_geo text,
  codigo_postal text,
  zona text,
  maps_url text,
  latitud numeric,
  longitud numeric,
  referencias text,
  estado_cliente text,
  origen text,
  notas text,
  created_at timestamp with time zone,
  updated_at timestamp with time zone,
  distancia_km numeric
);

create table if not exists public.contactos (
  id uuid not null,
  cliente_id uuid not null,
  nombre text not null,
  puesto text,
  telefono text,
  telefono_norm text generated always as (normalizar_telefono(telefono)) stored,
  email text,
  whatsapp boolean not null,
  verificado boolean not null,
  activo boolean not null,
  notas text,
  de_toda_la_empresa boolean not null,
  puede_pedir_citas boolean not null,
  recibe_ordenes boolean not null,
  recibe_cotizaciones boolean not null,
  created_at timestamp with time zone not null,
  updated_at timestamp with time zone not null
);

create table if not exists public.conversaciones (
  id uuid not null,
  telefono text not null,
  telefono_norm text generated always as (normalizar_telefono(telefono)) stored,
  contacto_id uuid,
  cliente_id uuid,
  nombre_wa text,
  estado text not null,
  sin_leer integer not null,
  ventana_hasta timestamp with time zone,
  ultimo_mensaje_at timestamp with time zone,
  created_at timestamp with time zone not null
);

create table if not exists public.cotizaciones (
  id uuid not null,
  folio integer not null,
  cliente_id uuid not null,
  equipo_id uuid,
  fecha date not null,
  vigencia_dias integer,
  tipo text,
  partidas jsonb not null,
  subtotal numeric,
  descuento numeric,
  iva numeric,
  total numeric,
  moneda text,
  requiere_visita boolean,
  condiciones text,
  notas_internas text,
  estado text,
  creada_por text,
  aprobada_por text,
  fecha_aprobacion timestamp with time zone,
  created_at timestamp with time zone,
  updated_at timestamp with time zone,
  prog_fecha date,
  prog_hora time without time zone,
  prog_duracion_min integer,
  prog_tecnico_id uuid,
  prog_tecnico2_id uuid
);

create table if not exists public.datos_fiscales (
  id uuid not null,
  cliente_id uuid not null,
  rfc text not null,
  razon_social text not null,
  regimen_fiscal text not null,
  uso_cfdi text,
  cp_fiscal text not null,
  calle text,
  numero_exterior text,
  numero_interior text,
  colonia text,
  municipio text,
  estado text,
  cp text,
  pais text,
  forma_pago text,
  metodo_pago text,
  email_facturacion text,
  es_principal boolean,
  activo boolean,
  created_at timestamp with time zone,
  updated_at timestamp with time zone
);

create table if not exists public.devoluciones (
  id uuid not null,
  folio bigint generated always as identity not null,
  orden_id uuid not null,
  recibida_por uuid,
  observaciones text,
  lineas jsonb not null,
  created_at timestamp with time zone not null
);

create table if not exists public.entrega_lineas (
  id uuid not null,
  entrega_id uuid not null,
  producto_id uuid not null,
  sku text,
  nombre text,
  unidad text,
  cantidad numeric not null
);

create table if not exists public.entregas (
  id uuid not null,
  folio bigint generated always as identity not null,
  orden_id uuid not null,
  entregado_por uuid,
  recibido_por uuid,
  estado text not null,
  firma_ruta text,
  motivo_sin_firma text,
  notas text,
  created_at timestamp with time zone not null,
  entregada_at timestamp with time zone
);

create table if not exists public.envios_orden (
  id uuid not null,
  folio bigint generated always as identity not null,
  orden_id uuid not null,
  ruta text not null,
  semana text not null,
  destinatarios jsonb not null,
  enviado_por text,
  enviado_en timestamp with time zone not null
);

create table if not exists public.equipo_contactos (
  id uuid not null,
  equipo_id uuid not null,
  contacto_id uuid not null,
  rol text not null,
  puede_pedir_citas boolean not null,
  recibe_ordenes boolean not null,
  recibe_cotizaciones boolean not null,
  created_at timestamp with time zone not null
);

create table if not exists public.equipos (
  id uuid not null,
  cliente_id uuid not null,
  numero_serie text,
  tipo text not null,
  marca text,
  modelo text,
  capacidad_kw numeric,
  anio integer,
  fecha_instalacion date,
  ubicacion_equipo text,
  horas_uso numeric,
  tipo_mantenimiento text,
  frecuencia_meses integer,
  proximo_mantenimiento date,
  en_poliza boolean,
  estado text,
  numero_servicio_cfe text,
  numero_medidor text,
  atributos jsonb,
  notas text,
  created_at timestamp with time zone,
  updated_at timestamp with time zone,
  horas_uso_fecha date
);

create table if not exists public.mensajes_wa (
  id uuid not null,
  conversacion_id uuid not null,
  direccion text not null,
  tipo text not null,
  texto text,
  media_id text,
  wa_message_id text,
  estado text,
  error text,
  enviado_por text,
  wa_timestamp timestamp with time zone,
  created_at timestamp with time zone not null
);

create table if not exists public.movimientos_inventario (
  id uuid not null,
  tipo text not null,
  cantidad numeric not null,
  cliente_id uuid,
  equipo_id uuid,
  cotizacion_id uuid,
  orden_servicio_id uuid,
  referencia text,
  notas text,
  usuario text,
  created_at timestamp with time zone,
  producto_id uuid not null,
  orden_id uuid,
  tecnico_id uuid
);

create table if not exists public.orden_partes (
  id uuid not null,
  orden_id uuid not null,
  autor_id uuid not null,
  notas text,
  fotos jsonb not null,
  created_at timestamp with time zone not null,
  updated_at timestamp with time zone not null
);

create table if not exists public.orden_revision (
  orden_id uuid not null,
  tipo text not null,
  datos jsonb not null,
  actualizado_por uuid,
  created_at timestamp with time zone not null,
  updated_at timestamp with time zone not null
);

create table if not exists public.orden_surtido (
  id uuid not null,
  orden_id uuid not null,
  producto_id uuid not null,
  sku text,
  nombre text,
  unidad text,
  cantidad_pedida numeric not null,
  cantidad_entregada numeric not null,
  origen text not null,
  cotizacion_id uuid,
  created_at timestamp with time zone not null,
  cantidad_usada numeric not null,
  cantidad_devuelta numeric not null,
  cantidad_diferencia numeric not null
);

create table if not exists public.ordenes_pdf (
  id uuid not null,
  orden_id uuid not null,
  tipo text not null,
  ruta text not null,
  generado_por text,
  generado_en timestamp with time zone not null
);

create table if not exists public.ordenes_servicio (
  id uuid not null,
  folio integer not null,
  cliente_id uuid not null,
  equipo_id uuid,
  cita_id uuid,
  fecha date not null,
  tipo_servicio text,
  tecnico text,
  horas_equipo numeric,
  trabajos_realizados text,
  refacciones jsonb,
  observaciones text,
  recomendaciones text,
  requiere_seguimiento boolean,
  fecha_seguimiento date,
  estado text,
  firma_cliente text,
  fotos jsonb,
  created_at timestamp with time zone,
  updated_at timestamp with time zone,
  tecnico_id uuid,
  tecnico2_id uuid,
  enviar_al_cerrar boolean not null
);

create table if not exists public.paquete_lineas (
  id uuid not null,
  paquete_id uuid not null,
  descripcion text not null,
  producto_id uuid,
  grupo text,
  cantidad numeric not null,
  orden integer not null
);

create table if not exists public.paquetes_mantenimiento (
  id uuid not null,
  tipo text not null,
  clase text,
  kw_desde numeric,
  kw_hasta numeric,
  marca text,
  modelo text,
  nombre text,
  activo boolean not null,
  notas text,
  created_at timestamp with time zone not null,
  updated_at timestamp with time zone not null
);

create table if not exists public.perfiles (
  id uuid not null,
  nombre text,
  email text,
  rol text not null,
  telefono text,
  zona text,
  cliente_id uuid,
  activo boolean,
  created_at timestamp with time zone
);

create table if not exists public.productos (
  id uuid not null,
  sku text not null,
  categoria text not null,
  nombre text not null,
  marca text,
  modelo text,
  descripcion text,
  precio numeric,
  costo numeric,
  moneda text,
  precios jsonb,
  clave_producto_sat text,
  clave_unidad_sat text,
  unidad text,
  minimo integer,
  atributos jsonb,
  publicar boolean,
  activo boolean,
  created_at timestamp with time zone,
  updated_at timestamp with time zone,
  grupo_equivalente text
);

create table if not exists public.requisiciones (
  id uuid not null,
  folio bigint generated always as identity not null,
  producto_id uuid not null,
  cotizacion_id uuid,
  cliente_id uuid,
  cantidad numeric not null,
  estado text not null,
  proveedor text,
  referencia text,
  notas text,
  fecha_pedido date,
  fecha_recibida date,
  movimiento_id uuid,
  creada_por text,
  created_at timestamp with time zone not null,
  updated_at timestamp with time zone not null
);

create table if not exists public.solicitudes_material (
  id uuid not null,
  folio bigint generated always as identity not null,
  tecnico_id uuid not null,
  orden_id uuid,
  equipo_id uuid,
  cliente_id uuid,
  producto_id uuid,
  sku text,
  nombre text,
  unidad text,
  descripcion_libre text,
  cantidad numeric not null,
  nota text,
  estado text not null,
  resolucion text,
  atendida_por text,
  atendida_at timestamp with time zone,
  created_at timestamp with time zone not null
);

create table if not exists public.tarifas_servicio (
  id uuid not null,
  concepto text not null,
  clase text,
  kw_desde numeric,
  kw_hasta numeric,
  km_desde numeric,
  precio numeric not null,
  activo boolean not null,
  notas text,
  created_at timestamp with time zone not null,
  updated_at timestamp with time zone not null,
  sku text,
  nombre text
);

create table if not exists public.wa_agente (
  id boolean not null,
  activo boolean not null,
  modo text not null,
  tope_dia integer not null,
  instrucciones text,
  updated_at timestamp with time zone not null
);

-- ========== DEFAULTS (después de las funciones) ==========

alter table public.auditoria alter column created_at set default now();

alter table public.auditoria alter column id set default gen_random_uuid();

alter table public.auditoria alter column origen set default 'agente'::text;

alter table public.avisos alter column created_at set default now();

alter table public.avisos alter column estado set default 'pendiente'::text;

alter table public.avisos alter column id set default gen_random_uuid();

alter table public.catalogos alter column activo set default true;

alter table public.catalogos alter column created_at set default now();

alter table public.catalogos alter column id set default gen_random_uuid();

alter table public.catalogos alter column usos set default 1;

alter table public.citas alter column created_at set default now();

alter table public.citas alter column estado set default 'programada'::text;

alter table public.citas alter column id set default gen_random_uuid();

alter table public.clientes alter column created_at set default now();

alter table public.clientes alter column estado_cliente set default 'activo'::text;

alter table public.clientes alter column estado_geo set default 'Yucatán'::text;

alter table public.clientes alter column id set default gen_random_uuid();

alter table public.clientes alter column tipo_cliente set default 'residencial'::text;

alter table public.clientes alter column updated_at set default now();

alter table public.contactos alter column activo set default true;

alter table public.contactos alter column created_at set default now();

alter table public.contactos alter column de_toda_la_empresa set default false;

alter table public.contactos alter column id set default gen_random_uuid();

alter table public.contactos alter column puede_pedir_citas set default false;

alter table public.contactos alter column recibe_cotizaciones set default false;

alter table public.contactos alter column recibe_ordenes set default false;

alter table public.contactos alter column updated_at set default now();

alter table public.contactos alter column verificado set default false;

alter table public.contactos alter column whatsapp set default true;

alter table public.conversaciones alter column created_at set default now();

alter table public.conversaciones alter column estado set default 'abierta'::text;

alter table public.conversaciones alter column id set default gen_random_uuid();

alter table public.conversaciones alter column sin_leer set default 0;

alter table public.cotizaciones alter column creada_por set default 'agente'::text;

alter table public.cotizaciones alter column created_at set default now();

alter table public.cotizaciones alter column descuento set default 0;

alter table public.cotizaciones alter column estado set default 'borrador'::text;

alter table public.cotizaciones alter column fecha set default CURRENT_DATE;

alter table public.cotizaciones alter column folio set default nextval('cotizaciones_folio_seq'::regclass);

alter table public.cotizaciones alter column id set default gen_random_uuid();

alter table public.cotizaciones alter column iva set default 0;

alter table public.cotizaciones alter column moneda set default 'MXN'::text;

alter table public.cotizaciones alter column partidas set default '[]'::jsonb;

alter table public.cotizaciones alter column requiere_visita set default false;

alter table public.cotizaciones alter column subtotal set default 0;

alter table public.cotizaciones alter column total set default 0;

alter table public.cotizaciones alter column updated_at set default now();

alter table public.cotizaciones alter column vigencia_dias set default 15;

alter table public.datos_fiscales alter column activo set default true;

alter table public.datos_fiscales alter column created_at set default now();

alter table public.datos_fiscales alter column es_principal set default true;

alter table public.datos_fiscales alter column forma_pago set default '03'::text;

alter table public.datos_fiscales alter column id set default gen_random_uuid();

alter table public.datos_fiscales alter column metodo_pago set default 'PUE'::text;

alter table public.datos_fiscales alter column pais set default 'México'::text;

alter table public.datos_fiscales alter column updated_at set default now();

alter table public.datos_fiscales alter column uso_cfdi set default 'G03'::text;

alter table public.devoluciones alter column created_at set default now();

alter table public.devoluciones alter column id set default gen_random_uuid();

alter table public.devoluciones alter column lineas set default '[]'::jsonb;

alter table public.entrega_lineas alter column id set default gen_random_uuid();

alter table public.entregas alter column created_at set default now();

alter table public.entregas alter column estado set default 'pendiente'::text;

alter table public.entregas alter column id set default gen_random_uuid();

alter table public.envios_orden alter column destinatarios set default '[]'::jsonb;

alter table public.envios_orden alter column enviado_en set default now();

alter table public.envios_orden alter column id set default gen_random_uuid();

alter table public.equipo_contactos alter column created_at set default now();

alter table public.equipo_contactos alter column id set default gen_random_uuid();

alter table public.equipo_contactos alter column puede_pedir_citas set default false;

alter table public.equipo_contactos alter column recibe_cotizaciones set default false;

alter table public.equipo_contactos alter column recibe_ordenes set default false;

alter table public.equipos alter column atributos set default '{}'::jsonb;

alter table public.equipos alter column created_at set default now();

alter table public.equipos alter column en_poliza set default false;

alter table public.equipos alter column estado set default 'activo'::text;

alter table public.equipos alter column id set default gen_random_uuid();

alter table public.equipos alter column tipo set default 'generador'::text;

alter table public.equipos alter column updated_at set default now();

alter table public.mensajes_wa alter column created_at set default now();

alter table public.mensajes_wa alter column id set default gen_random_uuid();

alter table public.mensajes_wa alter column tipo set default 'texto'::text;

alter table public.movimientos_inventario alter column created_at set default now();

alter table public.movimientos_inventario alter column id set default gen_random_uuid();

alter table public.orden_partes alter column created_at set default now();

alter table public.orden_partes alter column fotos set default '[]'::jsonb;

alter table public.orden_partes alter column id set default gen_random_uuid();

alter table public.orden_partes alter column updated_at set default now();

alter table public.orden_revision alter column created_at set default now();

alter table public.orden_revision alter column datos set default '{}'::jsonb;

alter table public.orden_revision alter column tipo set default 'generador'::text;

alter table public.orden_revision alter column updated_at set default now();

alter table public.orden_surtido alter column cantidad_devuelta set default 0;

alter table public.orden_surtido alter column cantidad_diferencia set default 0;

alter table public.orden_surtido alter column cantidad_entregada set default 0;

alter table public.orden_surtido alter column cantidad_usada set default 0;

alter table public.orden_surtido alter column created_at set default now();

alter table public.orden_surtido alter column id set default gen_random_uuid();

alter table public.orden_surtido alter column origen set default 'cotizacion'::text;

alter table public.ordenes_pdf alter column generado_en set default now();

alter table public.ordenes_pdf alter column id set default gen_random_uuid();

alter table public.ordenes_servicio alter column created_at set default now();

alter table public.ordenes_servicio alter column enviar_al_cerrar set default false;

alter table public.ordenes_servicio alter column estado set default 'abierta'::text;

alter table public.ordenes_servicio alter column fecha set default CURRENT_DATE;

alter table public.ordenes_servicio alter column folio set default nextval('ordenes_servicio_folio_seq'::regclass);

alter table public.ordenes_servicio alter column fotos set default '[]'::jsonb;

alter table public.ordenes_servicio alter column id set default gen_random_uuid();

alter table public.ordenes_servicio alter column refacciones set default '[]'::jsonb;

alter table public.ordenes_servicio alter column requiere_seguimiento set default false;

alter table public.ordenes_servicio alter column updated_at set default now();

alter table public.paquete_lineas alter column cantidad set default 1;

alter table public.paquete_lineas alter column id set default gen_random_uuid();

alter table public.paquete_lineas alter column orden set default 0;

alter table public.paquetes_mantenimiento alter column activo set default true;

alter table public.paquetes_mantenimiento alter column created_at set default now();

alter table public.paquetes_mantenimiento alter column id set default gen_random_uuid();

alter table public.paquetes_mantenimiento alter column updated_at set default now();

alter table public.perfiles alter column activo set default true;

alter table public.perfiles alter column created_at set default now();

alter table public.perfiles alter column rol set default 'sin_rol'::text;

alter table public.productos alter column activo set default true;

alter table public.productos alter column atributos set default '{}'::jsonb;

alter table public.productos alter column clave_unidad_sat set default 'H87'::text;

alter table public.productos alter column created_at set default now();

alter table public.productos alter column id set default gen_random_uuid();

alter table public.productos alter column minimo set default 0;

alter table public.productos alter column moneda set default 'MXN'::text;

alter table public.productos alter column precios set default '{}'::jsonb;

alter table public.productos alter column publicar set default true;

alter table public.productos alter column unidad set default 'pieza'::text;

alter table public.productos alter column updated_at set default now();

alter table public.requisiciones alter column created_at set default now();

alter table public.requisiciones alter column estado set default 'pendiente'::text;

alter table public.requisiciones alter column id set default gen_random_uuid();

alter table public.requisiciones alter column updated_at set default now();

alter table public.solicitudes_material alter column created_at set default now();

alter table public.solicitudes_material alter column estado set default 'pendiente'::text;

alter table public.solicitudes_material alter column id set default gen_random_uuid();

alter table public.tarifas_servicio alter column activo set default true;

alter table public.tarifas_servicio alter column created_at set default now();

alter table public.tarifas_servicio alter column id set default gen_random_uuid();

alter table public.tarifas_servicio alter column updated_at set default now();

alter table public.wa_agente alter column activo set default false;

alter table public.wa_agente alter column id set default true;

alter table public.wa_agente alter column modo set default 'borrador'::text;

alter table public.wa_agente alter column tope_dia set default 20;

alter table public.wa_agente alter column updated_at set default now();

-- ========== RESTRICCIONES ==========

alter table public.auditoria add constraint auditoria_pkey PRIMARY KEY (id);

alter table public.avisos add constraint avisos_pkey PRIMARY KEY (id);

alter table public.catalogos add constraint catalogos_pkey PRIMARY KEY (id);

alter table public.citas add constraint citas_pkey PRIMARY KEY (id);

alter table public.clientes add constraint clientes_pkey PRIMARY KEY (id);

alter table public.contactos add constraint contactos_pkey PRIMARY KEY (id);

alter table public.conversaciones add constraint conversaciones_pkey PRIMARY KEY (id);

alter table public.cotizaciones add constraint cotizaciones_pkey PRIMARY KEY (id);

alter table public.datos_fiscales add constraint datos_fiscales_pkey PRIMARY KEY (id);

alter table public.devoluciones add constraint devoluciones_pkey PRIMARY KEY (id);

alter table public.entrega_lineas add constraint entrega_lineas_pkey PRIMARY KEY (id);

alter table public.entregas add constraint entregas_pkey PRIMARY KEY (id);

alter table public.envios_orden add constraint envios_orden_pkey PRIMARY KEY (id);

alter table public.equipo_contactos add constraint equipo_contactos_pkey PRIMARY KEY (id);

alter table public.equipos add constraint equipos_pkey PRIMARY KEY (id);

alter table public.mensajes_wa add constraint mensajes_wa_pkey PRIMARY KEY (id);

alter table public.movimientos_inventario add constraint movimientos_inventario_pkey PRIMARY KEY (id);

alter table public.orden_partes add constraint orden_partes_pkey PRIMARY KEY (id);

alter table public.orden_revision add constraint orden_revision_pkey PRIMARY KEY (orden_id);

alter table public.orden_surtido add constraint orden_surtido_pkey PRIMARY KEY (id);

alter table public.ordenes_pdf add constraint ordenes_pdf_pkey PRIMARY KEY (id);

alter table public.ordenes_servicio add constraint ordenes_servicio_pkey PRIMARY KEY (id);

alter table public.paquete_lineas add constraint paquete_lineas_pkey PRIMARY KEY (id);

alter table public.paquetes_mantenimiento add constraint paquetes_mantenimiento_pkey PRIMARY KEY (id);

alter table public.perfiles add constraint perfiles_pkey PRIMARY KEY (id);

alter table public.productos add constraint productos_pkey PRIMARY KEY (id);

alter table public.requisiciones add constraint requisiciones_pkey PRIMARY KEY (id);

alter table public.solicitudes_material add constraint solicitudes_material_pkey PRIMARY KEY (id);

alter table public.tarifas_servicio add constraint tarifas_servicio_pkey PRIMARY KEY (id);

alter table public.wa_agente add constraint wa_agente_pkey PRIMARY KEY (id);

alter table public.catalogos add constraint catalogos_tipo_valor_normalizado_key UNIQUE (tipo, valor_normalizado);

alter table public.devoluciones add constraint devoluciones_folio_key UNIQUE (folio);

alter table public.entregas add constraint entregas_folio_key UNIQUE (folio);

alter table public.envios_orden add constraint envios_orden_folio_key UNIQUE (folio);

alter table public.equipo_contactos add constraint equipo_contactos_equipo_id_contacto_id_key UNIQUE (equipo_id, contacto_id);

alter table public.equipos add constraint equipos_numero_serie_key UNIQUE (numero_serie);

alter table public.orden_partes add constraint orden_partes_orden_id_autor_id_key UNIQUE (orden_id, autor_id);

alter table public.orden_surtido add constraint orden_surtido_orden_id_producto_id_key UNIQUE (orden_id, producto_id);

alter table public.ordenes_pdf add constraint ordenes_pdf_orden_id_tipo_key UNIQUE (orden_id, tipo);

alter table public.productos add constraint productos_sku_key UNIQUE (sku);

alter table public.requisiciones add constraint requisiciones_folio_key UNIQUE (folio);

alter table public.solicitudes_material add constraint solicitudes_material_folio_key UNIQUE (folio);

alter table public.avisos add constraint avisos_destinatario_check CHECK ((destinatario = ANY (ARRAY['cliente'::text, 'tecnico'::text])));

alter table public.avisos add constraint avisos_estado_check CHECK ((estado = ANY (ARRAY['pendiente'::text, 'enviado'::text, 'descartado'::text])));

alter table public.avisos add constraint avisos_tipo_check CHECK ((tipo = ANY (ARRAY['confirmacion'::text, 'reprogramacion'::text, 'cancelacion'::text])));

alter table public.citas add constraint citas_fecha_segun_estado CHECK (((fecha IS NOT NULL) OR (estado = ANY (ARRAY['por_programar'::text, 'cancelada'::text]))));

alter table public.conversaciones add constraint conversaciones_estado_check CHECK ((estado = ANY (ARRAY['abierta'::text, 'cerrada'::text])));

alter table public.conversaciones add constraint conversaciones_sin_leer_check CHECK ((sin_leer >= 0));

alter table public.entrega_lineas add constraint entrega_lineas_cantidad_check CHECK ((cantidad > (0)::numeric));

alter table public.entregas add constraint entregas_estado_check CHECK ((estado = ANY (ARRAY['pendiente'::text, 'firmada'::text, 'sin_firma'::text, 'cancelada'::text])));

alter table public.equipo_contactos add constraint equipo_contactos_rol_check CHECK ((rol = ANY (ARRAY['responsable'::text, 'encargado'::text, 'administracion'::text, 'solo_avisos'::text])));

alter table public.mensajes_wa add constraint mensajes_wa_direccion_check CHECK ((direccion = ANY (ARRAY['entrante'::text, 'saliente'::text])));

alter table public.mensajes_wa add constraint mensajes_wa_tipo_check CHECK ((tipo = ANY (ARRAY['texto'::text, 'imagen'::text, 'documento'::text, 'audio'::text, 'ubicacion'::text, 'otro'::text])));

alter table public.orden_revision add constraint orden_revision_tipo_check CHECK ((tipo = ANY (ARRAY['generador'::text, 'solar'::text])));

alter table public.orden_surtido add constraint orden_surtido_cantidad_devuelta_check CHECK ((cantidad_devuelta >= (0)::numeric));

alter table public.orden_surtido add constraint orden_surtido_cantidad_diferencia_check CHECK ((cantidad_diferencia >= (0)::numeric));

alter table public.orden_surtido add constraint orden_surtido_cantidad_entregada_check CHECK ((cantidad_entregada >= (0)::numeric));

alter table public.orden_surtido add constraint orden_surtido_cantidad_pedida_check CHECK ((cantidad_pedida > (0)::numeric));

alter table public.orden_surtido add constraint orden_surtido_cantidad_usada_check CHECK ((cantidad_usada >= (0)::numeric));

alter table public.orden_surtido add constraint orden_surtido_uso_no_excede CHECK ((((cantidad_usada + cantidad_devuelta) + cantidad_diferencia) <= cantidad_entregada));

alter table public.ordenes_pdf add constraint ordenes_pdf_tipo_check CHECK ((tipo = ANY (ARRAY['cliente'::text, 'interno'::text])));

alter table public.paquete_lineas add constraint paquete_linea_apunta_a_algo CHECK (((producto_id IS NOT NULL) OR (grupo IS NOT NULL)));

alter table public.paquete_lineas add constraint paquete_lineas_cantidad_check CHECK ((cantidad > (0)::numeric));

alter table public.paquetes_mantenimiento add constraint paquetes_mantenimiento_tipo_check CHECK ((tipo = ANY (ARRAY['menor'::text, 'mayor'::text])));

alter table public.requisiciones add constraint requisiciones_cantidad_check CHECK ((cantidad > (0)::numeric));

alter table public.requisiciones add constraint requisiciones_estado_check CHECK ((estado = ANY (ARRAY['pendiente'::text, 'pedida'::text, 'recibida'::text, 'cancelada'::text])));

alter table public.solicitudes_material add constraint solicitudes_material_cantidad_check CHECK ((cantidad > (0)::numeric));

alter table public.solicitudes_material add constraint solicitudes_material_check CHECK (((producto_id IS NOT NULL) OR (NULLIF(TRIM(BOTH FROM COALESCE(descripcion_libre, ''::text)), ''::text) IS NOT NULL)));

alter table public.solicitudes_material add constraint solicitudes_material_estado_check CHECK ((estado = ANY (ARRAY['pendiente'::text, 'atendida'::text, 'descartada'::text])));

alter table public.tarifas_servicio add constraint tarifas_servicio_concepto_ok CHECK ((concepto = ANY (ARRAY['diagnostico'::text, 'traslado'::text, 'correctivo'::text, 'preventivo'::text, 'preventivo_menor'::text, 'preventivo_mayor'::text, 'instalacion_gas'::text, 'instalacion_electrica'::text, 'otro'::text])));

alter table public.tarifas_servicio add constraint tarifas_servicio_nombre_si_otro CHECK (((concepto <> 'otro'::text) OR (NULLIF(TRIM(BOTH FROM COALESCE(nombre, ''::text)), ''::text) IS NOT NULL)));

alter table public.tarifas_servicio add constraint tarifas_servicio_precio_check CHECK ((precio >= (0)::numeric));

alter table public.tarifas_servicio add constraint tarifas_servicio_sku_si_catalogo CHECK (((concepto = ANY (ARRAY['diagnostico'::text, 'traslado'::text])) OR (NULLIF(TRIM(BOTH FROM COALESCE(sku, ''::text)), ''::text) IS NOT NULL)));

alter table public.wa_agente add constraint wa_agente_id_check CHECK (id);

alter table public.wa_agente add constraint wa_agente_modo_check CHECK ((modo = ANY (ARRAY['borrador'::text, 'automatico'::text])));

alter table public.wa_agente add constraint wa_agente_tope_dia_check CHECK ((tope_dia > 0));

alter table public.avisos add constraint avisos_cita_id_fkey FOREIGN KEY (cita_id) REFERENCES citas(id) ON DELETE CASCADE;

alter table public.avisos add constraint avisos_contacto_id_fkey FOREIGN KEY (contacto_id) REFERENCES contactos(id) ON DELETE SET NULL;

alter table public.avisos add constraint avisos_perfil_id_fkey FOREIGN KEY (perfil_id) REFERENCES perfiles(id) ON DELETE SET NULL;

alter table public.citas add constraint citas_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES clientes(id);

alter table public.citas add constraint citas_cotizacion_id_fkey FOREIGN KEY (cotizacion_id) REFERENCES cotizaciones(id);

alter table public.citas add constraint citas_equipo_id_fkey FOREIGN KEY (equipo_id) REFERENCES equipos(id);

alter table public.citas add constraint citas_tecnico2_id_fkey FOREIGN KEY (tecnico2_id) REFERENCES perfiles(id);

alter table public.citas add constraint citas_tecnico_id_fkey FOREIGN KEY (tecnico_id) REFERENCES perfiles(id);

alter table public.contactos add constraint contactos_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES clientes(id) ON DELETE CASCADE;

alter table public.conversaciones add constraint conversaciones_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES clientes(id) ON DELETE SET NULL;

alter table public.conversaciones add constraint conversaciones_contacto_id_fkey FOREIGN KEY (contacto_id) REFERENCES contactos(id) ON DELETE SET NULL;

alter table public.cotizaciones add constraint cotizaciones_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES clientes(id);

alter table public.cotizaciones add constraint cotizaciones_equipo_id_fkey FOREIGN KEY (equipo_id) REFERENCES equipos(id);

alter table public.cotizaciones add constraint cotizaciones_prog_tecnico2_id_fkey FOREIGN KEY (prog_tecnico2_id) REFERENCES perfiles(id);

alter table public.cotizaciones add constraint cotizaciones_prog_tecnico_id_fkey FOREIGN KEY (prog_tecnico_id) REFERENCES perfiles(id);

alter table public.datos_fiscales add constraint datos_fiscales_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES clientes(id) ON DELETE CASCADE;

alter table public.devoluciones add constraint devoluciones_orden_id_fkey FOREIGN KEY (orden_id) REFERENCES ordenes_servicio(id);

alter table public.devoluciones add constraint devoluciones_recibida_por_fkey FOREIGN KEY (recibida_por) REFERENCES perfiles(id);

alter table public.entrega_lineas add constraint entrega_lineas_entrega_id_fkey FOREIGN KEY (entrega_id) REFERENCES entregas(id) ON DELETE CASCADE;

alter table public.entrega_lineas add constraint entrega_lineas_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES productos(id);

alter table public.entregas add constraint entregas_entregado_por_fkey FOREIGN KEY (entregado_por) REFERENCES perfiles(id);

alter table public.entregas add constraint entregas_orden_id_fkey FOREIGN KEY (orden_id) REFERENCES ordenes_servicio(id);

alter table public.entregas add constraint entregas_recibido_por_fkey FOREIGN KEY (recibido_por) REFERENCES perfiles(id);

alter table public.envios_orden add constraint envios_orden_orden_id_fkey FOREIGN KEY (orden_id) REFERENCES ordenes_servicio(id);

alter table public.equipo_contactos add constraint equipo_contactos_contacto_id_fkey FOREIGN KEY (contacto_id) REFERENCES contactos(id) ON DELETE CASCADE;

alter table public.equipo_contactos add constraint equipo_contactos_equipo_id_fkey FOREIGN KEY (equipo_id) REFERENCES equipos(id) ON DELETE CASCADE;

alter table public.equipos add constraint equipos_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES clientes(id) ON DELETE RESTRICT;

alter table public.mensajes_wa add constraint mensajes_wa_conversacion_id_fkey FOREIGN KEY (conversacion_id) REFERENCES conversaciones(id) ON DELETE CASCADE;

alter table public.movimientos_inventario add constraint movimientos_inventario_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES clientes(id);

alter table public.movimientos_inventario add constraint movimientos_inventario_cotizacion_id_fkey FOREIGN KEY (cotizacion_id) REFERENCES cotizaciones(id);

alter table public.movimientos_inventario add constraint movimientos_inventario_equipo_id_fkey FOREIGN KEY (equipo_id) REFERENCES equipos(id);

alter table public.movimientos_inventario add constraint movimientos_inventario_orden_id_fkey FOREIGN KEY (orden_id) REFERENCES ordenes_servicio(id);

alter table public.movimientos_inventario add constraint movimientos_inventario_orden_servicio_id_fkey FOREIGN KEY (orden_servicio_id) REFERENCES ordenes_servicio(id);

alter table public.movimientos_inventario add constraint movimientos_inventario_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES productos(id);

alter table public.movimientos_inventario add constraint movimientos_inventario_tecnico_id_fkey FOREIGN KEY (tecnico_id) REFERENCES perfiles(id);

alter table public.orden_partes add constraint orden_partes_autor_id_fkey FOREIGN KEY (autor_id) REFERENCES perfiles(id);

alter table public.orden_partes add constraint orden_partes_orden_id_fkey FOREIGN KEY (orden_id) REFERENCES ordenes_servicio(id) ON DELETE CASCADE;

alter table public.orden_revision add constraint orden_revision_actualizado_por_fkey FOREIGN KEY (actualizado_por) REFERENCES perfiles(id);

alter table public.orden_revision add constraint orden_revision_orden_id_fkey FOREIGN KEY (orden_id) REFERENCES ordenes_servicio(id) ON DELETE CASCADE;

alter table public.orden_surtido add constraint orden_surtido_cotizacion_id_fkey FOREIGN KEY (cotizacion_id) REFERENCES cotizaciones(id);

alter table public.orden_surtido add constraint orden_surtido_orden_id_fkey FOREIGN KEY (orden_id) REFERENCES ordenes_servicio(id) ON DELETE CASCADE;

alter table public.orden_surtido add constraint orden_surtido_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES productos(id);

alter table public.ordenes_pdf add constraint ordenes_pdf_orden_id_fkey FOREIGN KEY (orden_id) REFERENCES ordenes_servicio(id) ON DELETE CASCADE;

alter table public.ordenes_servicio add constraint ordenes_servicio_cita_id_fkey FOREIGN KEY (cita_id) REFERENCES citas(id);

alter table public.ordenes_servicio add constraint ordenes_servicio_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES clientes(id);

alter table public.ordenes_servicio add constraint ordenes_servicio_equipo_id_fkey FOREIGN KEY (equipo_id) REFERENCES equipos(id);

alter table public.ordenes_servicio add constraint ordenes_servicio_tecnico2_id_fkey FOREIGN KEY (tecnico2_id) REFERENCES perfiles(id);

alter table public.ordenes_servicio add constraint ordenes_servicio_tecnico_id_fkey FOREIGN KEY (tecnico_id) REFERENCES perfiles(id);

alter table public.paquete_lineas add constraint paquete_lineas_paquete_id_fkey FOREIGN KEY (paquete_id) REFERENCES paquetes_mantenimiento(id) ON DELETE CASCADE;

alter table public.paquete_lineas add constraint paquete_lineas_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES productos(id);

alter table public.perfiles add constraint perfiles_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES clientes(id);

alter table public.perfiles add constraint perfiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;

alter table public.requisiciones add constraint requisiciones_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES clientes(id);

alter table public.requisiciones add constraint requisiciones_cotizacion_id_fkey FOREIGN KEY (cotizacion_id) REFERENCES cotizaciones(id);

alter table public.requisiciones add constraint requisiciones_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES productos(id);

alter table public.solicitudes_material add constraint solicitudes_material_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES clientes(id) ON DELETE SET NULL;

alter table public.solicitudes_material add constraint solicitudes_material_equipo_id_fkey FOREIGN KEY (equipo_id) REFERENCES equipos(id) ON DELETE SET NULL;

alter table public.solicitudes_material add constraint solicitudes_material_orden_id_fkey FOREIGN KEY (orden_id) REFERENCES ordenes_servicio(id) ON DELETE SET NULL;

alter table public.solicitudes_material add constraint solicitudes_material_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES productos(id);

alter table public.solicitudes_material add constraint solicitudes_material_tecnico_id_fkey FOREIGN KEY (tecnico_id) REFERENCES perfiles(id);

-- ========== ÍNDICES ==========

CREATE INDEX IF NOT EXISTS idx_audit_tabla ON public.auditoria USING btree (tabla, registro_id);

CREATE INDEX IF NOT EXISTS idx_avisos_cita ON public.avisos USING btree (cita_id);

CREATE INDEX IF NOT EXISTS idx_avisos_estado ON public.avisos USING btree (estado) WHERE (estado = 'pendiente'::text);

CREATE INDEX IF NOT EXISTS idx_catalogos_tipo ON public.catalogos USING btree (tipo, usos DESC);

CREATE INDEX IF NOT EXISTS idx_citas_cliente ON public.citas USING btree (cliente_id);

CREATE INDEX IF NOT EXISTS idx_citas_cotizacion ON public.citas USING btree (cotizacion_id) WHERE (cotizacion_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS idx_citas_fecha ON public.citas USING btree (fecha);

CREATE INDEX IF NOT EXISTS idx_citas_por_programar ON public.citas USING btree (estado) WHERE (estado = 'por_programar'::text);

CREATE INDEX IF NOT EXISTS idx_citas_tecnico ON public.citas USING btree (tecnico_id, fecha);

CREATE INDEX IF NOT EXISTS idx_citas_tecnico2 ON public.citas USING btree (tecnico2_id, fecha) WHERE (tecnico2_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS idx_clientes_geo ON public.clientes USING btree (latitud, longitud);

CREATE INDEX IF NOT EXISTS idx_clientes_nombre ON public.clientes USING btree (nombre);

CREATE INDEX IF NOT EXISTS idx_clientes_zona ON public.clientes USING btree (zona);

CREATE INDEX IF NOT EXISTS idx_contactos_cliente ON public.contactos USING btree (cliente_id) WHERE activo;

CREATE INDEX IF NOT EXISTS idx_contactos_telefono ON public.contactos USING btree (telefono_norm) WHERE activo;

CREATE INDEX IF NOT EXISTS idx_conversaciones_abiertas ON public.conversaciones USING btree (ultimo_mensaje_at DESC) WHERE (estado = 'abierta'::text);

CREATE INDEX IF NOT EXISTS idx_cot_cliente ON public.cotizaciones USING btree (cliente_id);

CREATE INDEX IF NOT EXISTS idx_cot_estado ON public.cotizaciones USING btree (estado);

CREATE INDEX IF NOT EXISTS idx_datos_fiscales_cliente ON public.datos_fiscales USING btree (cliente_id);

CREATE INDEX IF NOT EXISTS idx_datos_fiscales_rfc ON public.datos_fiscales USING btree (rfc);

CREATE INDEX IF NOT EXISTS idx_devoluciones_orden ON public.devoluciones USING btree (orden_id);

CREATE INDEX IF NOT EXISTS idx_entrega_lineas_entrega ON public.entrega_lineas USING btree (entrega_id);

CREATE INDEX IF NOT EXISTS idx_entregas_estado ON public.entregas USING btree (estado) WHERE (estado = 'pendiente'::text);

CREATE INDEX IF NOT EXISTS idx_entregas_orden ON public.entregas USING btree (orden_id);

CREATE INDEX IF NOT EXISTS idx_envios_orden_orden ON public.envios_orden USING btree (orden_id);

CREATE INDEX IF NOT EXISTS idx_equipo_contactos_contacto ON public.equipo_contactos USING btree (contacto_id);

CREATE INDEX IF NOT EXISTS idx_equipos_cfe ON public.equipos USING btree (numero_servicio_cfe);

CREATE INDEX IF NOT EXISTS idx_equipos_cliente ON public.equipos USING btree (cliente_id);

CREATE INDEX IF NOT EXISTS idx_equipos_proximo ON public.equipos USING btree (proximo_mantenimiento);

CREATE INDEX IF NOT EXISTS idx_equipos_serie ON public.equipos USING btree (numero_serie);

CREATE INDEX IF NOT EXISTS idx_equipos_tipo ON public.equipos USING btree (tipo);

CREATE INDEX IF NOT EXISTS idx_mensajes_wa_conversacion ON public.mensajes_wa USING btree (conversacion_id, created_at);

CREATE INDEX IF NOT EXISTS idx_mov_cliente ON public.movimientos_inventario USING btree (cliente_id);

CREATE INDEX IF NOT EXISTS idx_mov_orden ON public.movimientos_inventario USING btree (orden_id) WHERE (orden_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS idx_mov_producto ON public.movimientos_inventario USING btree (producto_id);

CREATE INDEX IF NOT EXISTS idx_mov_tipo ON public.movimientos_inventario USING btree (tipo);

CREATE INDEX IF NOT EXISTS idx_orden_partes_orden ON public.orden_partes USING btree (orden_id);

CREATE INDEX IF NOT EXISTS idx_orden_revision_tipo ON public.orden_revision USING btree (tipo);

CREATE INDEX IF NOT EXISTS idx_orden_surtido_orden ON public.orden_surtido USING btree (orden_id);

CREATE INDEX IF NOT EXISTS idx_ordenes_pdf_orden ON public.ordenes_pdf USING btree (orden_id);

CREATE INDEX IF NOT EXISTS idx_ordenes_tecnico ON public.ordenes_servicio USING btree (tecnico_id, fecha);

CREATE INDEX IF NOT EXISTS idx_ordenes_tecnico2 ON public.ordenes_servicio USING btree (tecnico2_id, estado) WHERE (tecnico2_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS idx_os_cliente ON public.ordenes_servicio USING btree (cliente_id);

CREATE INDEX IF NOT EXISTS idx_os_equipo ON public.ordenes_servicio USING btree (equipo_id);

CREATE INDEX IF NOT EXISTS idx_os_fecha ON public.ordenes_servicio USING btree (fecha);

CREATE INDEX IF NOT EXISTS idx_paquete_lineas ON public.paquete_lineas USING btree (paquete_id, orden);

CREATE INDEX IF NOT EXISTS idx_perfiles_rol ON public.perfiles USING btree (rol) WHERE activo;

CREATE INDEX IF NOT EXISTS idx_productos_categoria ON public.productos USING btree (categoria) WHERE activo;

CREATE INDEX IF NOT EXISTS idx_productos_grupo_equivalente ON public.productos USING btree (grupo_equivalente) WHERE (grupo_equivalente IS NOT NULL);

CREATE INDEX IF NOT EXISTS idx_productos_sku ON public.productos USING btree (sku);

CREATE INDEX IF NOT EXISTS idx_requisiciones_cotizacion ON public.requisiciones USING btree (cotizacion_id);

CREATE INDEX IF NOT EXISTS idx_requisiciones_estado ON public.requisiciones USING btree (estado);

CREATE INDEX IF NOT EXISTS idx_requisiciones_producto ON public.requisiciones USING btree (producto_id);

CREATE INDEX IF NOT EXISTS idx_solicitudes_material_estado ON public.solicitudes_material USING btree (estado) WHERE (estado = 'pendiente'::text);

CREATE INDEX IF NOT EXISTS idx_solicitudes_material_orden ON public.solicitudes_material USING btree (orden_id) WHERE (orden_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS idx_solicitudes_material_tecnico ON public.solicitudes_material USING btree (tecnico_id);

CREATE UNIQUE INDEX IF NOT EXISTS un_aviso_pendiente ON public.avisos USING btree (cita_id, llave) WHERE (estado = 'pendiente'::text);

CREATE UNIQUE INDEX IF NOT EXISTS un_contacto_telefono_por_cliente ON public.contactos USING btree (cliente_id, telefono_norm) WHERE (activo AND (telefono_norm IS NOT NULL));

CREATE UNIQUE INDEX IF NOT EXISTS un_conversaciones_telefono ON public.conversaciones USING btree (telefono_norm) WHERE (telefono_norm IS NOT NULL);

CREATE UNIQUE INDEX IF NOT EXISTS un_mensajes_wa_id ON public.mensajes_wa USING btree (wa_message_id) WHERE (wa_message_id IS NOT NULL);

CREATE UNIQUE INDEX IF NOT EXISTS un_responsable_por_equipo ON public.equipo_contactos USING btree (equipo_id) WHERE (rol = 'responsable'::text);

CREATE UNIQUE INDEX IF NOT EXISTS un_tarifas_servicio_sku ON public.tarifas_servicio USING btree (sku) WHERE (sku IS NOT NULL);

CREATE UNIQUE INDEX IF NOT EXISTS ux_ordenes_una_por_cita ON public.ordenes_servicio USING btree (cita_id) WHERE (cita_id IS NOT NULL);

-- ========== VISTAS (con su modo security_invoker) ==========

create or replace view public.catalogo with (security_invoker=on) as
 SELECT id,
    sku,
    categoria,
    nombre,
    marca,
    modelo,
    descripcion,
    precio,
    precios,
    unidad,
    minimo,
    atributos,
    clave_producto_sat,
    clave_unidad_sat
   FROM productos
  WHERE activo AND (mi_rol() = ANY (ARRAY['admin'::text, 'tecnico'::text]));

create or replace view public.contactos_por_equipo with (security_invoker=on) as
 SELECT ec.equipo_id,
    c.id AS contacto_id,
    c.cliente_id,
    c.nombre,
    c.puesto,
    c.telefono,
    c.telefono_norm,
    c.whatsapp,
    c.verificado,
    ec.rol,
    ec.puede_pedir_citas,
    ec.recibe_ordenes,
    ec.recibe_cotizaciones,
    'equipo'::text AS origen
   FROM equipo_contactos ec
     JOIN contactos c ON c.id = ec.contacto_id
  WHERE c.activo
UNION ALL
 SELECT e.id AS equipo_id,
    c.id AS contacto_id,
    c.cliente_id,
    c.nombre,
    c.puesto,
    c.telefono,
    c.telefono_norm,
    c.whatsapp,
    c.verificado,
    'empresa'::text AS rol,
    c.puede_pedir_citas,
    c.recibe_ordenes,
    c.recibe_cotizaciones,
    'empresa'::text AS origen
   FROM contactos c
     JOIN equipos e ON e.cliente_id = c.cliente_id
  WHERE c.activo AND c.de_toda_la_empresa AND NOT (EXISTS ( SELECT 1
           FROM equipo_contactos x
          WHERE x.equipo_id = e.id AND x.contacto_id = c.id));

create or replace view public.disponibles with (security_invoker=on) as
 SELECT id,
    sku,
    categoria,
    nombre,
    marca,
    unidad,
    minimo,
    fisico,
    apartado,
    resguardo,
    fisico - apartado - resguardo AS disponible
   FROM existencias;

create or replace view public.existencias with (security_invoker=off) as
 SELECT p.id,
    p.sku,
    p.categoria,
    p.nombre,
    p.marca,
    p.unidad,
    p.minimo,
    COALESCE(sum(
        CASE m.tipo
            WHEN 'entrada'::text THEN m.cantidad
            WHEN 'salida_venta'::text THEN - m.cantidad
            WHEN 'consumo_resguardo'::text THEN - m.cantidad
            WHEN 'consumo_servicio'::text THEN - m.cantidad
            WHEN 'ajuste'::text THEN m.cantidad
            WHEN 'entrega_tecnico'::text THEN - m.cantidad
            WHEN 'devolucion_tecnico'::text THEN m.cantidad
            ELSE 0::numeric
        END), 0::numeric) AS fisico,
    COALESCE(sum(
        CASE m.tipo
            WHEN 'apartado'::text THEN m.cantidad
            WHEN 'libera_apartado'::text THEN - m.cantidad
            WHEN 'salida_venta'::text THEN - m.cantidad
            WHEN 'a_resguardo'::text THEN - m.cantidad
            ELSE 0::numeric
        END), 0::numeric) AS apartado,
    COALESCE(sum(
        CASE m.tipo
            WHEN 'a_resguardo'::text THEN m.cantidad
            WHEN 'consumo_resguardo'::text THEN - m.cantidad
            ELSE 0::numeric
        END), 0::numeric) AS resguardo,
    COALESCE(sum(
        CASE m.tipo
            WHEN 'entrega_tecnico'::text THEN m.cantidad
            WHEN 'devolucion_tecnico'::text THEN - m.cantidad
            WHEN 'consumo_tecnico'::text THEN - m.cantidad
            ELSE 0::numeric
        END), 0::numeric) AS en_custodia
   FROM productos p
     LEFT JOIN movimientos_inventario m ON m.producto_id = p.id
  WHERE p.activo AND (mi_rol() = ANY (ARRAY['admin'::text, 'tecnico'::text, 'almacenista'::text]))
  GROUP BY p.id;

create or replace view public.por_reordenar with (security_invoker=on) as
 SELECT id,
    sku,
    categoria,
    nombre,
    marca,
    unidad,
    minimo,
    fisico,
    apartado,
    resguardo,
    disponible
   FROM disponibles
  WHERE minimo > 0 AND disponible < minimo::numeric;

create or replace view public.resguardo_por_cliente with (security_invoker=on) as
 SELECT m.cliente_id,
    c.nombre AS cliente,
    m.producto_id,
    p.sku,
    p.nombre AS producto,
    sum(
        CASE m.tipo
            WHEN 'a_resguardo'::text THEN m.cantidad
            WHEN 'consumo_resguardo'::text THEN - m.cantidad
            ELSE 0::numeric
        END) AS en_resguardo
   FROM movimientos_inventario m
     JOIN productos p ON p.id = m.producto_id
     JOIN clientes c ON c.id = m.cliente_id
  WHERE (m.tipo = ANY (ARRAY['a_resguardo'::text, 'consumo_resguardo'::text])) AND ((mi_rol() = ANY (ARRAY['admin'::text, 'tecnico'::text])) OR mi_rol() = 'cliente'::text AND m.cliente_id = mi_cliente())
  GROUP BY m.cliente_id, c.nombre, m.producto_id, p.sku, p.nombre
 HAVING sum(
        CASE m.tipo
            WHEN 'a_resguardo'::text THEN m.cantidad
            ELSE - m.cantidad
        END) > 0::numeric;

-- ========== TRIGGERS ==========

CREATE TRIGGER avisos_de_cita AFTER INSERT OR UPDATE ON public.citas FOR EACH ROW EXECUTE FUNCTION avisos_de_cita();

CREATE TRIGGER tocar_updated_at BEFORE UPDATE ON public.contactos FOR EACH ROW EXECUTE FUNCTION tocar_updated_at();

CREATE TRIGGER ligar_conversacion_sola BEFORE INSERT ON public.conversaciones FOR EACH ROW EXECUTE FUNCTION _ligar_conversacion_sola();

CREATE TRIGGER tocar_updated_at BEFORE UPDATE ON public.cotizaciones FOR EACH ROW EXECUTE FUNCTION tocar_updated_at();

CREATE TRIGGER tocar_updated_at BEFORE UPDATE ON public.orden_partes FOR EACH ROW EXECUTE FUNCTION tocar_updated_at();

CREATE TRIGGER sella_revision BEFORE INSERT OR UPDATE ON public.orden_revision FOR EACH ROW EXECUTE FUNCTION _sella_revision();

CREATE TRIGGER horometro_al_equipo AFTER UPDATE ON public.ordenes_servicio FOR EACH ROW EXECUTE FUNCTION _horometro_al_equipo();

CREATE TRIGGER seguridad_antes_de_cerrar BEFORE UPDATE ON public.ordenes_servicio FOR EACH ROW EXECUTE FUNCTION _seguridad_antes_de_cerrar();

CREATE TRIGGER tocar_updated_at BEFORE UPDATE ON public.ordenes_servicio FOR EACH ROW EXECUTE FUNCTION tocar_updated_at();

CREATE TRIGGER tocar_updated_at BEFORE UPDATE ON public.paquetes_mantenimiento FOR EACH ROW EXECUTE FUNCTION tocar_updated_at();

CREATE TRIGGER completar_solicitud_material BEFORE INSERT ON public.solicitudes_material FOR EACH ROW EXECUTE FUNCTION _completar_solicitud_material();

CREATE TRIGGER tocar_updated_at BEFORE UPDATE ON public.tarifas_servicio FOR EACH ROW EXECUTE FUNCTION tocar_updated_at();

-- ========== ROW LEVEL SECURITY ==========

alter table public.auditoria enable row level security;

alter table public.avisos enable row level security;

alter table public.catalogos enable row level security;

alter table public.citas enable row level security;

alter table public.clientes enable row level security;

alter table public.contactos enable row level security;

alter table public.conversaciones enable row level security;

alter table public.cotizaciones enable row level security;

alter table public.datos_fiscales enable row level security;

alter table public.devoluciones enable row level security;

alter table public.entrega_lineas enable row level security;

alter table public.entregas enable row level security;

alter table public.envios_orden enable row level security;

alter table public.equipo_contactos enable row level security;

alter table public.equipos enable row level security;

alter table public.mensajes_wa enable row level security;

alter table public.movimientos_inventario enable row level security;

alter table public.orden_partes enable row level security;

alter table public.orden_revision enable row level security;

alter table public.orden_surtido enable row level security;

alter table public.ordenes_pdf enable row level security;

alter table public.ordenes_servicio enable row level security;

alter table public.paquete_lineas enable row level security;

alter table public.paquetes_mantenimiento enable row level security;

alter table public.perfiles enable row level security;

alter table public.productos enable row level security;

alter table public.requisiciones enable row level security;

alter table public.solicitudes_material enable row level security;

alter table public.tarifas_servicio enable row level security;

alter table public.wa_agente enable row level security;

-- ========== POLÍTICAS ==========

create policy admin_lee_auditoria on public.auditoria as permissive for select to authenticated using (es_admin());

create policy todos_escriben_auditoria on public.auditoria as permissive for insert to authenticated with check (true);

create policy admin_avisos on public.avisos as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy actualiza_catalogos on public.catalogos as permissive for update to authenticated using (true);

create policy escribe_catalogos on public.catalogos as permissive for insert to authenticated with check (true);

create policy lee_catalogos on public.catalogos as permissive for select to authenticated using (true);

create policy admin_citas on public.citas as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy cliente_ve_sus_citas on public.citas as permissive for select to authenticated using (((mi_rol() = 'cliente'::text) AND (cliente_id = mi_cliente())));

create policy tecnico2_ve_sus_citas on public.citas as permissive for select to authenticated using (((mi_rol() = 'tecnico'::text) AND (tecnico2_id = auth.uid())));

create policy tecnico_ve_sus_citas on public.citas as permissive for select to authenticated using (((mi_rol() = 'tecnico'::text) AND (tecnico_id = auth.uid())));

create policy admin_clientes on public.clientes as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy cliente_ve_lo_suyo on public.clientes as permissive for select to authenticated using (((mi_rol() = 'cliente'::text) AND (id = mi_cliente())));

create policy tecnico_lee_clientes on public.clientes as permissive for select to authenticated using ((mi_rol() = 'tecnico'::text));

create policy admin_contactos on public.contactos as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_conversaciones on public.conversaciones as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_cotizaciones on public.cotizaciones as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy cliente_ve_sus_cotizaciones on public.cotizaciones as permissive for select to authenticated using (((mi_rol() = 'cliente'::text) AND (cliente_id = mi_cliente())));

create policy admin_datos_fiscales on public.datos_fiscales as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_devoluciones on public.devoluciones as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_entrega_lineas on public.entrega_lineas as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy tecnico_lee_lineas_de_sus_entregas on public.entrega_lineas as permissive for select to authenticated using ((EXISTS ( SELECT 1
   FROM entregas e
  WHERE ((e.id = entrega_lineas.entrega_id) AND soy_de_la_orden(e.orden_id)))));

create policy admin_entregas on public.entregas as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy tecnico_lee_sus_entregas on public.entregas as permissive for select to authenticated using (soy_de_la_orden(orden_id));

create policy admin_envios_orden on public.envios_orden as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_equipo_contactos on public.equipo_contactos as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_equipos on public.equipos as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy cliente_ve_sus_equipos on public.equipos as permissive for select to authenticated using (((mi_rol() = 'cliente'::text) AND (cliente_id = mi_cliente())));

create policy tecnico_lee_equipos on public.equipos as permissive for select to authenticated using ((mi_rol() = 'tecnico'::text));

create policy admin_mensajes_wa on public.mensajes_wa as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_movimientos on public.movimientos_inventario as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy tecnico_lee_movimientos on public.movimientos_inventario as permissive for select to authenticated using ((mi_rol() = 'tecnico'::text));

create policy admin_orden_partes on public.orden_partes as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy tecnico_actualiza_su_parte on public.orden_partes as permissive for update to authenticated using (((autor_id = auth.uid()) AND soy_de_la_orden(orden_id) AND orden_abierta(orden_id))) with check (((autor_id = auth.uid()) AND soy_de_la_orden(orden_id) AND orden_abierta(orden_id)));

create policy tecnico_crea_su_parte on public.orden_partes as permissive for insert to authenticated with check (((autor_id = auth.uid()) AND soy_de_la_orden(orden_id) AND orden_abierta(orden_id)));

create policy tecnicos_leen_partes_de_su_orden on public.orden_partes as permissive for select to authenticated using (soy_de_la_orden(orden_id));

create policy admin_orden_revision on public.orden_revision as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy tecnico_actualiza_revision on public.orden_revision as permissive for update to authenticated using ((soy_de_la_orden(orden_id) AND orden_abierta(orden_id))) with check ((soy_de_la_orden(orden_id) AND orden_abierta(orden_id)));

create policy tecnico_crea_revision on public.orden_revision as permissive for insert to authenticated with check ((soy_de_la_orden(orden_id) AND orden_abierta(orden_id)));

create policy tecnico_lee_revision on public.orden_revision as permissive for select to authenticated using (soy_de_la_orden(orden_id));

create policy admin_orden_surtido on public.orden_surtido as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy tecnico_lee_su_surtido on public.orden_surtido as permissive for select to authenticated using (soy_de_la_orden(orden_id));

create policy admin_ordenes_pdf on public.ordenes_pdf as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_ordenes on public.ordenes_servicio as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy cliente_ve_sus_ordenes on public.ordenes_servicio as permissive for select to authenticated using (((mi_rol() = 'cliente'::text) AND (cliente_id = mi_cliente())));

create policy tecnico2_ve_sus_ordenes on public.ordenes_servicio as permissive for select to authenticated using (((mi_rol() = 'tecnico'::text) AND (tecnico2_id = auth.uid())));

create policy tecnico_ve_sus_ordenes on public.ordenes_servicio as permissive for select to authenticated using (((mi_rol() = 'tecnico'::text) AND (tecnico_id = auth.uid())));

create policy admin_paquete_lineas on public.paquete_lineas as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_paquetes on public.paquetes_mantenimiento as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_edita_perfiles on public.perfiles as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy ve_su_perfil on public.perfiles as permissive for select to authenticated using (((id = auth.uid()) OR es_admin()));

create policy admin_productos on public.productos as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_requisiciones on public.requisiciones as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_solicitudes_material on public.solicitudes_material as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy almacen_lee_solicitudes_material on public.solicitudes_material as permissive for select to authenticated using (COALESCE((mi_rol() = 'almacenista'::text), false));

create policy tecnico_cancela_su_solicitud_material on public.solicitudes_material as permissive for update to authenticated using (((mi_rol() = 'tecnico'::text) AND (tecnico_id = auth.uid()) AND (estado = 'pendiente'::text))) with check (((mi_rol() = 'tecnico'::text) AND (tecnico_id = auth.uid()) AND (estado = ANY (ARRAY['pendiente'::text, 'descartada'::text])) AND ((orden_id IS NULL) OR soy_de_la_orden(orden_id))));

create policy tecnico_crea_solicitud_material on public.solicitudes_material as permissive for insert to authenticated with check (((mi_rol() = 'tecnico'::text) AND (tecnico_id = auth.uid()) AND ((orden_id IS NULL) OR soy_de_la_orden(orden_id))));

create policy tecnico_lee_solicitudes_material on public.solicitudes_material as permissive for select to authenticated using (((mi_rol() = 'tecnico'::text) AND ((tecnico_id = auth.uid()) OR ((orden_id IS NOT NULL) AND soy_de_la_orden(orden_id)))));

create policy admin_tarifas_servicio on public.tarifas_servicio as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_wa_agente on public.wa_agente as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy bot_lee_wa_agente on public.wa_agente as permissive for select to authenticated using (_es_bot_o_admin());

-- ========== PERMISOS ==========

grant delete, insert, references, select, trigger, truncate, update on public.auditoria to anon;

grant delete, insert, references, select, trigger, truncate, update on public.auditoria to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.auditoria to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.avisos to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.avisos to service_role;

grant select on public.catalogo to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.catalogo to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.catalogos to anon;

grant delete, insert, references, select, trigger, truncate, update on public.catalogos to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.catalogos to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.citas to anon;

grant delete, insert, references, select, trigger, truncate, update on public.citas to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.citas to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.clientes to anon;

grant delete, insert, references, select, trigger, truncate, update on public.clientes to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.clientes to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.contactos to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.contactos to service_role;

grant select on public.contactos_por_equipo to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.contactos_por_equipo to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.conversaciones to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.conversaciones to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.cotizaciones to anon;

grant delete, insert, references, select, trigger, truncate, update on public.cotizaciones to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.cotizaciones to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.datos_fiscales to anon;

grant delete, insert, references, select, trigger, truncate, update on public.datos_fiscales to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.datos_fiscales to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.devoluciones to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.devoluciones to service_role;

grant select on public.disponibles to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.disponibles to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.entrega_lineas to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.entrega_lineas to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.entregas to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.entregas to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.envios_orden to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.envios_orden to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.equipo_contactos to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.equipo_contactos to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.equipos to anon;

grant delete, insert, references, select, trigger, truncate, update on public.equipos to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.equipos to service_role;

grant select on public.existencias to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.existencias to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.mensajes_wa to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.mensajes_wa to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.movimientos_inventario to anon;

grant delete, insert, references, select, trigger, truncate, update on public.movimientos_inventario to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.movimientos_inventario to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.orden_partes to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.orden_partes to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.orden_revision to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.orden_revision to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.orden_surtido to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.orden_surtido to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.ordenes_pdf to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.ordenes_pdf to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.ordenes_servicio to anon;

grant delete, insert, references, select, trigger, truncate, update on public.ordenes_servicio to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.ordenes_servicio to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.paquete_lineas to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.paquete_lineas to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.paquetes_mantenimiento to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.paquetes_mantenimiento to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.perfiles to anon;

grant delete, insert, references, select, trigger, truncate, update on public.perfiles to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.perfiles to service_role;

grant select on public.por_reordenar to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.por_reordenar to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.productos to anon;

grant delete, insert, references, select, trigger, truncate, update on public.productos to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.productos to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.requisiciones to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.requisiciones to service_role;

grant select on public.resguardo_por_cliente to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.resguardo_por_cliente to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.solicitudes_material to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.solicitudes_material to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.tarifas_servicio to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.tarifas_servicio to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.wa_agente to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.wa_agente to service_role;

-- ========== LO REVOCADO (no se ve en un grant) ==========

revoke all on public.avisos from anon;

revoke all on public.catalogo from anon;

revoke all on public.contactos from anon;

revoke all on public.contactos_por_equipo from anon;

revoke all on public.conversaciones from anon;

revoke all on public.devoluciones from anon;

revoke all on public.disponibles from anon;

revoke all on public.entrega_lineas from anon;

revoke all on public.entregas from anon;

revoke all on public.envios_orden from anon;

revoke all on public.equipo_contactos from anon;

revoke all on public.existencias from anon;

revoke all on public.mensajes_wa from anon;

revoke all on public.orden_partes from anon;

revoke all on public.orden_revision from anon;

revoke all on public.orden_surtido from anon;

revoke all on public.ordenes_pdf from anon;

revoke all on public.paquete_lineas from anon;

revoke all on public.paquetes_mantenimiento from anon;

revoke all on public.por_reordenar from anon;

revoke all on public.requisiciones from anon;

revoke all on public.resguardo_por_cliente from anon;

revoke all on public.solicitudes_material from anon;

revoke all on public.tarifas_servicio from anon;

revoke all on public.wa_agente from anon;

revoke execute on function public._aplicar_entrega(p_entrega uuid, p_estado text, p_firma text, p_motivo text) from public;

revoke execute on function public._apunta(p_tabla text, p_registro uuid, p_accion text, p_antes jsonb, p_despues jsonb, p_origen text) from public;

revoke execute on function public._cancelar_avisos(p_cita uuid, p_solo_tecnicos_fuera boolean) from public;

revoke execute on function public._cliente_de_conversacion(p_conversacion uuid) from public;

revoke execute on function public._codigos_de_linea(p_linea uuid) from public;

revoke execute on function public._completar_solicitud_material() from public;

revoke execute on function public._contactos_de_aviso(p_cita uuid) from public;

revoke execute on function public._encolar_avisos(p_cita uuid, p_tipo text) from public;

revoke execute on function public._es_almacen() from public;

revoke execute on function public._es_bot_o_admin() from public;

revoke execute on function public._fijar_componente(p_equipo uuid, p_rol text, p_datos jsonb, p_ruta text, p_origen text) from public;

revoke execute on function public._ligar_conversacion_sola() from public;

revoke execute on function public._paquete_de_equipo(p_equipo uuid, p_tipo text) from public;

revoke execute on function public._preparar_surtido(p_orden uuid) from public;

revoke execute on function public._tipo_para(p_cita uuid, p_llave text, p_tipo text) from public;

revoke execute on function public.actualizar_componente(p_equipo uuid, p_rol text, p_datos jsonb, p_origen text) from public;

revoke execute on function public.adicionales_por_conciliar() from public;

revoke execute on function public.agendar_cita(p_cliente uuid, p_equipo uuid, p_tipo text, p_fecha date, p_hora time without time zone, p_duracion integer, p_t1 uuid, p_t2 uuid, p_zona text, p_notas text, p_cotizacion uuid, p_nueva_cotizacion jsonb, p_confirmar boolean) from public;

revoke execute on function public.atender_solicitud_material(p_id uuid, p_resolucion text) from public;

revoke execute on function public.avisos_pendientes() from public;

revoke execute on function public.bandeja_whatsapp(p_incluir_cerradas boolean) from public;

revoke execute on function public.cambiar_estado_cotizacion(p_id uuid, p_nuevo text, p_forzar boolean) from public;

revoke execute on function public.cambiar_estado_requisicion(p_id uuid, p_nuevo text, p_proveedor text, p_referencia text) from public;

revoke execute on function public.cancelar_cita(p_cita uuid) from public;

revoke execute on function public.cancelar_entrega(p_entrega uuid) from public;

revoke execute on function public.cerrar_conversacion(p_conversacion uuid, p_abrir boolean) from public;

revoke execute on function public.cerrar_orden(p_orden uuid, p_firma text, p_sin_firma boolean, p_horas numeric, p_observaciones text, p_recomendaciones text, p_seguimiento boolean, p_fecha_seguimiento date, p_refacciones jsonb, p_uso jsonb) from public;

revoke execute on function public.conciliar_adicional(p_orden uuid, p_nota text) from public;

revoke execute on function public.crear_entrega(p_orden uuid, p_lineas jsonb) from public;

revoke execute on function public.descartar_solicitud_material(p_id uuid, p_motivo text) from public;

revoke execute on function public.devoluciones_pendientes() from public;

revoke execute on function public.empalmes_de(p_fecha date, p_hora time without time zone, p_dur integer, p_t1 uuid, p_t2 uuid, p_excluir uuid) from public;

revoke execute on function public.entregar_sin_firma(p_entrega uuid, p_motivo text) from public;

revoke execute on function public.equipo_de_orden(p_orden uuid, p_equipo uuid) from public;

revoke execute on function public.equipos_sin_serie() from public;

revoke execute on function public.fijar_surtido(p_orden uuid, p_producto uuid, p_cantidad numeric) from public;

revoke execute on function public.firmar_entrega(p_entrega uuid, p_firma text) from public;

revoke execute on function public.guardar_placa(p_orden uuid, p_rol text, p_ruta text, p_datos jsonb) from public;

revoke execute on function public.identificar_telefono(p_telefono text) from public;

revoke execute on function public.lista_tecnicos() from public;

revoke execute on function public.marcar_aviso(p_id uuid, p_estado text, p_canal text) from public;

revoke execute on function public.marcar_conversacion_leida(p_conversacion uuid) from public;

revoke execute on function public.ordenes_por_surtir() from public;

revoke execute on function public.paquete_preventivo(p_equipo uuid, p_tipo text) from public;

revoke execute on function public.piezas_que_se_repiten(p_clase text, p_kw_desde numeric, p_kw_hasta numeric, p_marca text, p_modelo text, p_desde date) from public;

revoke execute on function public.programar_cita(p_cita uuid, p_fecha date, p_hora time without time zone, p_duracion integer, p_t1 uuid, p_t2 uuid, p_confirmar boolean) from public;

revoke execute on function public.recibir_devolucion(p_orden uuid, p_lineas jsonb, p_observaciones text) from public;

revoke execute on function public.registrar_equipo_en_orden(p_orden uuid, p_datos jsonb) from public;

revoke execute on function public.registrar_mensaje_entrante(p_telefono text, p_wa_message_id text, p_texto text, p_nombre_wa text, p_tipo text, p_media_id text, p_wa_timestamp timestamp with time zone) from public;

revoke execute on function public.registrar_mensaje_saliente(p_conversacion uuid, p_texto text, p_wa_message_id text, p_estado text) from public;

revoke execute on function public.resolver_diferencia(p_orden uuid, p_producto uuid, p_motivo text) from public;

revoke execute on function public.solicitudes_material_pendientes() from public;

revoke execute on function public.surtido_desde_paquete(p_orden uuid, p_tipo text) from public;

revoke execute on function public.texto_aviso(p_aviso uuid) from public;

revoke execute on function public.vincular_contacto(p_equipo uuid, p_contacto uuid, p_rol text, p_pedir_citas boolean, p_ordenes boolean, p_cotizaciones boolean) from public;

revoke execute on function public.vincular_conversacion(p_conversacion uuid, p_contacto uuid) from public;

revoke execute on function public.wa_contexto(p_conversacion uuid) from public;

revoke execute on function public.wa_puede_responder(p_conversacion uuid) from public;

revoke execute on function public.wa_solicitar_cita(p_conversacion uuid, p_equipo uuid, p_tipo text, p_nota text) from public;
