-- Esquema `public` de crm-generadores, foto tomada el 09/10/2026.
-- Generado por supabase/sql/00_volcar_esquema.sql — no editar a mano:
-- volver a correr ese script y reemplazar este archivo.
--
-- Contenido: 59 tablas, 6 vistas, 158 funciones, 91 políticas.
-- Es una FOTO, no una migración: si una sentencia falla por el orden,
-- se vuelve a correr al final.

-- ========== EXTENSIONES (informativo) ==========

-- extensión instalada: pg_cron (esquema pg_catalog, versión 1.6.4)

-- extensión instalada: pg_net (esquema extensions, versión 0.20.3)

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

CREATE OR REPLACE FUNCTION public._aplicar_precio(p_producto uuid, p_calc jsonb, p_origen text, p_corrida uuid, p_tc numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_p productos;
  v_precio numeric := (p_calc ->> 'precio')::numeric;
  v_costo numeric := (p_calc ->> 'costo_mxn')::numeric;
  v_publica boolean;
begin
  if v_precio < v_costo + (p_calc ->> 'margen_minimo')::numeric then
    raise exception 'Precio % por debajo de costo % + margen mínimo: no se publica.',
      v_precio, v_costo using errcode = '23514';
  end if;
  v_p := (select p from productos p where p.id = p_producto);
  v_publica := (v_p.precio is null or v_p.precio <= 0)
               and not coalesce(v_p.publicar, false)
               and coalesce(v_p.atributos ->> 'origen', '') = 'proveedor';

  update productos
     set precio = v_precio, costo = v_costo, moneda = 'MXN',
         publicar = publicar or v_publica,
         precio_sync_en = now(), updated_at = now()
   where id = p_producto;
  perform _ordenar_proveedores(p_producto, p_calc);
  insert into historial_precios (producto_id, precio_anterior, precio_nuevo,
                                 costo_anterior, costo_nuevo, tipo_cambio, origen, corrida_id)
  values (p_producto, v_p.precio, v_precio, v_p.costo, v_costo, p_tc, p_origen, p_corrida);
  perform _apunta('productos', p_producto, 'precio_por_proveedor',
                  jsonb_build_object('precio', v_p.precio, 'costo', v_p.costo),
                  jsonb_build_object('precio', v_precio, 'costo', v_costo, 'origen', p_origen,
                                     'publicado', v_publica,
                                     'opcion_1', p_calc ->> 'proveedor',
                                     'precio_de', p_calc ->> 'proveedor_precio'),
                  'sync');
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

CREATE OR REPLACE FUNCTION public._aviso_a_salida()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_pl wa_plantillas%rowtype; v_auto boolean;
begin
  if tg_op = 'INSERT' then
    if new.telefono is null or new.estado <> 'pendiente' then return new; end if;
    v_pl := (select p from wa_plantillas p where p.uso = 'aviso:' || new.tipo || ':' || new.destinatario);
    if v_pl.nombre is null then return new; end if;          -- sin plantilla: sigue siendo manual
    v_auto := coalesce((select avisos_automaticos from wa_config where id), false);
    insert into salida_wa (llave, telefono, tipo, plantilla, origen, origen_id, categoria, estado, texto, creado_por)
    values ('aviso:' || new.id, new.telefono, 'plantilla', v_pl.nombre, 'aviso', new.id, 'utilidad',
            case when v_auto then 'pendiente' else 'por_aprobar' end,
            'Aviso de ' || new.tipo || ' (plantilla ' || v_pl.nombre || ')', 'sistema')
    on conflict (llave) do nothing;
  elsif new.estado in ('enviado', 'descartado') and coalesce(new.canal, '') <> 'whatsapp_api' then
    update salida_wa set estado = 'cancelado', error = 'el aviso se resolvió fuera de la cola'
     where llave = 'aviso:' || new.id and estado in ('por_aprobar', 'pendiente');
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public._calcular_precio(p_producto uuid, p_tc numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  v_p productos;
  v_r reglas_margen;
  v_lista jsonb;
  v_cands jsonb;
  v_vigente boolean := true;
  v_bajo jsonb;
  v_alto jsonb;
begin
  v_p := (select p from productos p where p.id = p_producto);
  if v_p.id is null then
    return jsonb_build_object('ok', false, 'motivo', 'sin_producto');
  end if;

  v_lista := (
    select coalesce(jsonb_agg(jsonb_build_object(
             'proveedor', l.proveedor,
             'proveedor_sku', l.proveedor_sku,
             'leido', x.id is not null,
             'vigente', coalesce(x.vigente, false),
             'moneda', x.moneda,
             'costo', x.costo,
             'costo_mxn', case when x.costo is null or x.costo <= 0 then null
                               when x.moneda = 'USD' then case when p_tc > 0 then round(x.costo * p_tc, 2) end
                               else round(x.costo, 2) end)
           order by l.proveedor), '[]'::jsonb)
      from producto_proveedores l
      left join proveedor_productos x
        on x.proveedor = l.proveedor and x.sku_proveedor = l.proveedor_sku
     where l.producto_id = p_producto);

  if jsonb_array_length(v_lista) = 0 then
    return jsonb_build_object('ok', false, 'motivo', 'sin_lectura');
  end if;

  v_cands := (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(v_lista) e
               where (e ->> 'vigente')::boolean and e ->> 'costo_mxn' is not null);
  if jsonb_array_length(v_cands) = 0 then
    v_vigente := false;
    v_cands := (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(v_lista) e
                 where e ->> 'costo_mxn' is not null);
  end if;
  if jsonb_array_length(v_cands) = 0 then
    if exists (select 1 from jsonb_array_elements(v_lista) e
                where e ->> 'moneda' = 'USD' and (e ->> 'costo')::numeric > 0) then
      return jsonb_build_object('ok', false, 'motivo', 'sin_tipo_cambio');
    elsif exists (select 1 from jsonb_array_elements(v_lista) e where (e ->> 'leido')::boolean) then
      return jsonb_build_object('ok', false, 'motivo', 'sin_costo');
    end if;
    return jsonb_build_object('ok', false, 'motivo', 'sin_lectura');
  end if;

  -- Empate en costo: se queda la opción 1 que ya tenía (no se cambia de proveedor por nada).
  v_bajo := (select e from jsonb_array_elements(v_cands) e
              order by (e ->> 'costo_mxn')::numeric,
                       (e ->> 'proveedor') = coalesce(v_p.proveedor, '') desc, e ->> 'proveedor'
              limit 1);
  v_alto := (select e from jsonb_array_elements(v_cands) e
              order by (e ->> 'costo_mxn')::numeric desc, e ->> 'proveedor'
              limit 1);

  v_r := _regla_margen(v_p.categoria, v_p.marca);
  if v_r.id is null then
    return jsonb_build_object('ok', false, 'motivo', 'sin_regla');
  end if;
  return jsonb_build_object(
    'ok', true,
    'costo_mxn', (v_bajo ->> 'costo_mxn')::numeric,
    'costo_alto_mxn', (v_alto ->> 'costo_mxn')::numeric,
    'precio', _precio_venta((v_alto ->> 'costo_mxn')::numeric, v_r),
    'margen_pct', v_r.margen_pct, 'margen_minimo', v_r.margen_minimo_mxn, 'margen_sobre', v_r.sobre,
    'vigente', v_vigente,
    'proveedor', v_bajo ->> 'proveedor', 'proveedor_sku', v_bajo ->> 'proveedor_sku',
    'proveedor_precio', v_alto ->> 'proveedor',
    'proveedores', v_lista);
end $function$
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

CREATE OR REPLACE FUNCTION public._categoria_crm(p_categoria_proveedor text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case lower(trim(coalesce(p_categoria_proveedor, '')))
    when 'paneles solares' then array['panel', null]::text[]
    when 'inversores' then array['inversor', 'inversor']::text[]
    when 'microinversores' then array['inversor', 'microinversor']::text[]
    when 'baterías, controladores y generadores' then array['bateria', null]::text[]
    when 'monitoreo, optimizadores y protecciones' then array['accesorio_solar', 'monitoreo']::text[]
    when 'suministros de instalación' then array['accesorio_solar', 'suministros']::text[]
    when 'sistemas de montaje' then array['accesorio_solar', 'montaje']::text[]
    when 'kits' then array['accesorio_solar', 'kits']::text[]
    else null
  end
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

CREATE OR REPLACE FUNCTION public._cobranza_tras_movimiento()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if coalesce(new.tipo, old.tipo) = 'ingreso' then
    perform _recalcular_cobranza(coalesce(new.cotizacion_id, old.cotizacion_id));
  end if;
  return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public._cobranza_tras_total()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform _recalcular_cobranza(new.id);
  return null;
end;
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

CREATE OR REPLACE FUNCTION public._cotizacion_cerrada_bloquea()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if old.expediente_cerrado_en is not null and new.expediente_cerrado_en is not null
     and (new.partidas, new.subtotal, new.descuento, new.iva, new.total)
         is distinct from (old.partidas, old.subtotal, old.descuento, old.iva, old.total) then
    raise exception 'Su expediente está cerrado: reábrelo antes de cambiar las partidas o los importes.' using errcode = '22023';
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public._encolar(p_tipo text, p_producto uuid, p_sku text, p_detalle jsonb, p_corrida uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  insert into cola_revision (tipo, producto_id, proveedor_sku, detalle, corrida_id)
  values (p_tipo, p_producto, p_sku, p_detalle, p_corrida)
  on conflict (tipo, producto_id) where estado = 'pendiente'
  do update set detalle = excluded.detalle, corrida_id = excluded.corrida_id, creado_en = now()
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

CREATE OR REPLACE FUNCTION public._espejo_a_vinculos()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.proveedor is not null and new.proveedor_sku is not null then
    insert into producto_proveedores (producto_id, proveedor, proveedor_sku)
    values (new.id, new.proveedor, new.proveedor_sku)
    on conflict do nothing;
  end if;
  return null;
end $function$
;

CREATE OR REPLACE FUNCTION public._expediente_cerrado_bloquea()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
declare
  v_cot uuid;
begin
  v_cot := coalesce(new.cotizacion_id, old.cotizacion_id);
  if (select expediente_cerrado_en from cotizaciones where id = v_cot) is not null then
    raise exception 'El expediente está cerrado. Reábrelo para cambiar sus movimientos.' using errcode = '22023';
  end if;
  return coalesce(new, old);
end;
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

CREATE OR REPLACE FUNCTION public._marketing_reciente(p_norm text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from salida_wa s
     where s.telefono_norm = p_norm and s.categoria = 'marketing'
       and s.estado in ('pendiente', 'enviando', 'enviado', 'entregado', 'leido', 'sin_confirmar')
       and s.created_at > now() - make_interval(days => coalesce((select dias_entre_marketing from wa_config where id), 30)))
$function$
;

CREATE OR REPLACE FUNCTION public._ordenar_proveedores(p_producto uuid, p_calc jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_promo numeric;
begin
  if not coalesce((p_calc ->> 'ok')::boolean, false) then
    update productos set precio_promocion = null
     where id = p_producto and precio_promocion is not null;
    return;
  end if;
  update producto_proveedores l
     set opcion = r.n, costo_mxn = r.costo
    from (select e ->> 'proveedor' as proveedor,
                 nullif(e ->> 'costo_mxn', '')::numeric as costo,
                 row_number() over (
                   order by (e ->> 'proveedor') = (p_calc ->> 'proveedor') desc,
                            (e ->> 'vigente')::boolean desc,
                            nullif(e ->> 'costo_mxn', '')::numeric nulls last,
                            e ->> 'proveedor') as n
            from jsonb_array_elements(p_calc -> 'proveedores') e) r
   where l.producto_id = p_producto and l.proveedor = r.proveedor
     and (l.opcion is distinct from r.n or l.costo_mxn is distinct from r.costo);
  update productos
     set proveedor = p_calc ->> 'proveedor', proveedor_sku = p_calc ->> 'proveedor_sku'
   where id = p_producto
     and (proveedor is distinct from p_calc ->> 'proveedor'
          or proveedor_sku is distinct from p_calc ->> 'proveedor_sku');
  v_promo := _precio_promocion(p_producto, p_calc);
  update productos set precio_promocion = v_promo
   where id = p_producto and precio_promocion is distinct from v_promo;
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

CREATE OR REPLACE FUNCTION public._precio_promocion(p_producto uuid, p_calc jsonb)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  v_p productos;
  v_r reglas_margen;
  v_margen numeric := (select valor from parametros_costeo where clave = 'promo_margen_pct');
  v_minimo numeric := (select valor from parametros_costeo where clave = 'promo_descuento_minimo_pct');
  v_dias numeric := (select valor from parametros_costeo where clave = 'promo_vigencia_lista_dias');
  v_leido timestamptz;
  v_redondeo numeric;
  v_promo numeric;
begin
  if not coalesce((p_calc ->> 'ok')::boolean, false) or not coalesce((p_calc ->> 'vigente')::boolean, false) then
    return null;
  end if;
  -- Solo cuando se le compra a uno y el precio normal lo marca otro (el más caro).
  if v_margen is null or p_calc ->> 'proveedor' is null
     or p_calc ->> 'proveedor' = coalesce(p_calc ->> 'proveedor_precio', '') then
    return null;
  end if;
  v_p := (select p from productos p where p.id = p_producto);
  if v_p.precio is null or v_p.precio <= 0 then
    return null;
  end if;
  v_leido := (select x.leido_en from proveedor_productos x
               where x.proveedor = p_calc ->> 'proveedor' and x.sku_proveedor = p_calc ->> 'proveedor_sku');
  if v_leido is null or v_leido < now() - make_interval(days => coalesce(v_dias, 200)::int) then
    return null;
  end if;
  v_r := _regla_margen(v_p.categoria, v_p.marca);
  v_redondeo := coalesce(v_r.redondeo, 1);
  v_promo := ceil((p_calc ->> 'costo_mxn')::numeric * (1 + v_margen / 100) / v_redondeo) * v_redondeo;
  if v_promo > v_p.precio * (1 - coalesce(v_minimo, 5) / 100) then
    return null;
  end if;
  return v_promo;
end $function$
;

CREATE OR REPLACE FUNCTION public._precio_traslado(p_cliente uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_km     numeric;
  v_t      tarifas_servicio%rowtype;
  v_desde  numeric;
begin
  -- Asignación y no `select ... into`: el editor de Supabase confunde ese `into` con la
  -- sintaxis vieja de `create table as` y llega a mutilar el bloque (ver CLAUDE.md).
  v_km := (select distancia_km from clientes where id = p_cliente);
  if v_km is null then
    return jsonb_build_object('falta', 'El cliente no tiene capturada la distancia en km.');
  end if;

  -- La fila entera de una vez: pedir precio y km_desde por separado podría tomarlos de dos
  -- tarifas distintas si hubiera varias activas.
  v_t := (select t from tarifas_servicio t
           where t.activo and t.concepto = 'traslado'
           order by t.updated_at desc
           limit 1);

  if v_t.precio is null then
    return jsonb_build_object('falta', 'No hay tarifa de traslado capturada en Tarifas.');
  end if;
  v_desde := coalesce(v_t.km_desde, 40);

  -- Por debajo del mínimo no se cobra, y eso NO es un dato que falte: es un cliente cerca.
  if v_km < v_desde then
    return jsonb_build_object('km', v_km, 'aplica', false, 'importe', 0);
  end if;

  return jsonb_build_object('km', v_km, 'aplica', true,
                            'precio_km', v_t.precio,
                            'importe', round(v_km * v_t.precio, 2));
end $function$
;

CREATE OR REPLACE FUNCTION public._precio_venta(p_costo_mxn numeric, p_regla reglas_margen)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select ceil(greatest(
           case when p_regla.sobre = 'precio' then p_costo_mxn / (1 - p_regla.margen_pct / 100)
                else p_costo_mxn * (1 + p_regla.margen_pct / 100) end,
           p_costo_mxn + p_regla.margen_minimo_mxn) / p_regla.redondeo)
         * p_regla.redondeo
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

CREATE OR REPLACE FUNCTION public._recalcular_cobranza(p_cotizacion uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_c cotizaciones%rowtype;
  v_total numeric;
  v_cobrado numeric;
  v_verificado numeric;
  v_estado text;
begin
  v_c := (select c from cotizaciones c where c.id = p_cotizacion);
  if v_c.id is null then return; end if;
  if v_c.cobranza_manual then return; end if;      -- una decisión manual no se mueve sola

  v_total := coalesce(v_c.total, 0);
  v_cobrado := coalesce((select sum(monto) from expediente_movimientos
                          where cotizacion_id = p_cotizacion and tipo = 'ingreso'), 0);
  v_verificado := coalesce((select sum(monto) from expediente_movimientos
                             where cotizacion_id = p_cotizacion and tipo = 'ingreso'
                               and archivo is not null and leido_ia and monto_leido is not null
                               and abs(monto_leido - monto) <= 0.01), 0);

  v_estado := case
                when v_total > 0 and v_verificado >= v_total - 1 then 'liquidada'
                when v_cobrado > 0 then 'parcial'
                else 'pendiente'
              end;

  if v_estado is distinct from v_c.cobranza_estado then
    update cotizaciones
       set cobranza_estado = v_estado,
           cobranza_liquidada_en = case when v_estado = 'liquidada' then now() else null end
     where id = p_cotizacion;
    perform _apunta('cotizaciones', p_cotizacion, 'cobranza_' || v_estado,
                    jsonb_build_object('estado', v_c.cobranza_estado),
                    jsonb_build_object('verificado', v_verificado, 'cobrado', v_cobrado, 'total', v_total),
                    'oficina');
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public._recalcular_pago_tecnico(p_pago uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_total numeric;
begin
  v_total := (select coalesce(sum(monto), 0) from pagos_tecnico_lineas where pago_id = p_pago and activa);
  update pagos_tecnico set total = v_total where id = p_pago;
  return v_total;
end;
$function$
;

CREATE OR REPLACE FUNCTION public._regla_margen(p_categoria text, p_marca text)
 RETURNS reglas_margen
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select r.*
    from reglas_margen r
   where r.activo
     and (r.categoria is null or lower(r.categoria) = lower(coalesce(p_categoria, '')))
     and (r.marca is null or lower(r.marca) = lower(coalesce(p_marca, '')))
   order by (case when r.marca is not null then 2 else 0 end
             + case when r.categoria is not null then 1 else 0 end) desc
   limit 1
$function$
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

CREATE OR REPLACE FUNCTION public._sku_crm(p_proveedor text, p_sku text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case when lower(trim(p_proveedor)) = 'solarama' then
           'SLR-' || upper(regexp_replace(regexp_replace(
             translate(trim(p_sku), 'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNaeiouun'),
             '[^A-Za-z0-9.]+', '-', 'g'), '(^-+|-+$)', '', 'g'))
         else trim(p_sku) end
$function$
;

CREATE OR REPLACE FUNCTION public._tarifa_pago_tecnico(p_tecnico uuid, p_tipo text, p_rol text, p_fecha date)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select t.monto
    from tarifas_pago_tecnico t
   where t.tipo_servicio = p_tipo
     and t.rol = p_rol
     and (t.tecnico_id = p_tecnico or t.tecnico_id is null)
     and t.vigente_desde <= p_fecha
     and (t.vigente_hasta is null or t.vigente_hasta >= p_fecha)
   order by (t.tecnico_id is not null) desc, t.vigente_desde desc
   limit 1;
$function$
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

CREATE OR REPLACE FUNCTION public._variables_aviso(p_aviso uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  a avisos%rowtype; c citas%rowtype; eq equipos%rowtype;
  v_dias text[] := array['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado'];
  v_meses text[] := array['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto',
                          'septiembre', 'octubre', 'noviembre', 'diciembre'];
  v_tec text; v_folio bigint;
begin
  a := (select x from avisos x where x.id = p_aviso);
  if a.id is null then return null; end if;
  c := (select x from citas x where x.id = a.cita_id);
  if c.equipo_id is not null then eq := (select x from equipos x where x.id = c.equipo_id); end if;
  v_tec := nullif(concat_ws(' y ',
             (select coalesce(nombre, email) from perfiles where id = c.tecnico_id),
             (select coalesce(nombre, email) from perfiles where id = c.tecnico2_id)), '');
  v_folio := (select folio from ordenes_servicio where cita_id = c.id limit 1);
  return jsonb_build_object(
    'nombre', coalesce(nullif(trim(a.nombre), ''), 'cliente'),
    'servicio', case c.tipo_servicio
                  when 'preventivo' then 'mantenimiento preventivo'
                  when 'correctivo' then 'servicio correctivo'
                  when 'instalacion' then 'instalación'
                  when 'diagnostico' then 'diagnóstico'
                  when 'visita_tecnica' then 'visita técnica'
                  else coalesce(c.tipo_servicio, 'servicio') end,
    'equipo', coalesce(nullif(trim(concat_ws(' ', eq.marca, case when eq.capacidad_kw is not null then eq.capacidad_kw || ' kW' end)), ''), 'su equipo'),
    'fecha', case when c.fecha is null then 'por confirmar' else
               v_dias[extract(dow from c.fecha)::int + 1] || ' ' || extract(day from c.fecha)::int
               || ' de ' || v_meses[extract(month from c.fecha)::int] end,
    'hora', coalesce(left(c.hora::text, 5) || ' h', 'por confirmar'),
    'tecnico', coalesce(v_tec, 'nuestro equipo técnico'),
    'folio', coalesce('OS-' || v_folio, 'su orden'));
end $function$
;

CREATE OR REPLACE FUNCTION public._wa_destino(p_tel text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case
    when length(d) = 10 then '52' || d
    when d like '52%' and length(d) in (12, 13) then '52' || right(d, 10)
    else d end
  from (select regexp_replace(coalesce(p_tel, ''), '\D', '', 'g') as d) x
$function$
;

CREATE OR REPLACE FUNCTION public.aceptar_importacion_whatsapp(p_id uuid, p_cliente uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_fila importacion_whatsapp%rowtype;
  v_cliente uuid;
  v_contacto uuid;
  v_nombre text;
  v_conv uuid;
  v_n int;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;

  v_fila := (select i from importacion_whatsapp i where i.id = p_id);
  if v_fila.id is null then
    raise exception 'Esa fila no existe.' using errcode = 'P0002';
  end if;
  if v_fila.estado = 'aceptada' then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'cliente_id', v_fila.cliente_id);
  end if;
  if v_fila.telefono_norm is null then
    raise exception 'El teléfono no trae 10 dígitos: %', v_fila.telefono using errcode = '22023';
  end if;

  v_nombre := coalesce(nullif(trim(v_fila.nombre), ''), nullif(trim(v_fila.empresa), ''), 'Cliente de WhatsApp');

  if p_cliente is not null then
    if not exists (select 1 from clientes where id = p_cliente) then
      raise exception 'Ese cliente no existe.' using errcode = 'P0002';
    end if;
    v_cliente := p_cliente;
  else
    v_cliente := gen_random_uuid();
    insert into clientes (id, nombre, nombre_comercial, telefono, municipio, origen, notas)
    values (v_cliente,
            coalesce(nullif(trim(v_fila.empresa), ''), v_nombre),
            nullif(trim(v_fila.empresa), ''),
            v_fila.telefono_norm,
            nullif(trim(v_fila.ciudad), ''),
            'whatsapp_historial',
            nullif(trim(concat_ws(' · ', nullif(v_fila.equipo, ''), nullif(v_fila.ultimo_servicio, ''))), ''));
  end if;

  -- El contacto: si ese número ya es de ese cliente, se reutiliza.
  v_contacto := (select c.id from contactos c
                  where c.cliente_id = v_cliente and c.telefono_norm = v_fila.telefono_norm
                  limit 1);
  if v_contacto is null then
    v_contacto := gen_random_uuid();
    insert into contactos (id, cliente_id, nombre, telefono, verificado, activo,
                           de_toda_la_empresa, puede_pedir_citas, recibe_ordenes, recibe_cotizaciones, notas)
    values (v_contacto, v_cliente, v_nombre, v_fila.telefono_norm, true, true,
            true, true, true, true, 'Importado del historial de WhatsApp');
  else
    update contactos set activo = true, verificado = true, updated_at = now() where id = v_contacto;
  end if;

  -- Si ese número ya escribió, se liga su conversación (solo si no hay ambigüedad).
  v_n := (select count(*) from contactos c where c.activo and c.telefono_norm = v_fila.telefono_norm);
  v_conv := (select v.id from conversaciones v
              where v.telefono_norm = v_fila.telefono_norm and v.contacto_id is null);
  if v_conv is not null and v_n = 1 then
    update conversaciones set contacto_id = v_contacto, cliente_id = v_cliente where id = v_conv;
  end if;

  update importacion_whatsapp
     set estado = 'aceptada', cliente_id = v_cliente, contacto_id = v_contacto,
         revisado_por = coalesce(auth.jwt() ->> 'email', 'crm'), revisado_en = now()
   where id = p_id;

  perform _apunta('importacion_whatsapp', p_id, 'aceptada', null,
    jsonb_build_object('cliente', v_cliente, 'contacto', v_contacto, 'conversacion_ligada', v_conv is not null and v_n = 1),
    'oficina');

  return jsonb_build_object('ok', true, 'cliente_id', v_cliente, 'contacto_id', v_contacto,
                            'conversacion_ligada', v_conv is not null and v_n = 1);
end $function$
;

CREATE OR REPLACE FUNCTION public.activar_precio_automatico(p_proveedor text, p_categoria text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_n int;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  update productos p
     set precio_auto = true, updated_at = now()
   where p.activo and not p.precio_auto and p.categoria = p_categoria
     and exists (select 1 from producto_proveedores l
                  where l.producto_id = p.id and l.proveedor = lower(trim(p_proveedor)));
  get diagnostics v_n = row_count;
  if v_n > 0 then
    perform _apunta('productos', gen_random_uuid(), 'activar_precio_auto_lote', null,
                    jsonb_build_object('proveedor', lower(trim(p_proveedor)), 'categoria', p_categoria,
                                       'productos', v_n), 'oficina');
  end if;
  return v_n;
end $function$
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

CREATE OR REPLACE FUNCTION public.ajustar_pago_tecnico(p_pago uuid, p_concepto text, p_monto numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_p pagos_tecnico%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador ajusta pagos a técnicos.' using errcode = '42501';
  end if;
  v_p := (select p from pagos_tecnico p where p.id = p_pago);
  if v_p.id is null then raise exception 'Ese pago no existe.' using errcode = '22023'; end if;
  if v_p.estado <> 'propuesto' then
    raise exception 'Solo se ajusta un pago en borrador.' using errcode = '22023';
  end if;
  if coalesce(trim(p_concepto), '') = '' then
    raise exception 'Escribe el concepto del ajuste (bono, descuento, anticipo…).' using errcode = '22023';
  end if;
  if p_monto is null or p_monto = 0 then
    raise exception 'El ajuste no puede ser de cero.' using errcode = '22023';
  end if;

  insert into pagos_tecnico_lineas (pago_id, tecnico_id, clase, concepto, monto)
  values (p_pago, v_p.tecnico_id, 'ajuste', trim(p_concepto), p_monto);
  perform _recalcular_pago_tecnico(p_pago);
  return jsonb_build_object('ok', true, 'total', (select total from pagos_tecnico where id = p_pago));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.aprobar_documento(p_documento uuid, p_datos jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_d documentos%rowtype;
  v_cfdi cfdi%rowtype;
  v_accion text;
  v_cat text;
  v_monto numeric;
  v_iva numeric;
  v_fecha date;
  v_pagado boolean;
  v_mov uuid;
  v_cuenta uuid;
  v_cot uuid;
  v_correccion jsonb := '{}'::jsonb;
  v_prop jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador aprueba documentos.' using errcode = '42501';
  end if;
  v_d := (select d from documentos d where d.id = p_documento);
  if v_d.id is null then raise exception 'Ese documento no existe.' using errcode = '22023'; end if;
  if v_d.estado = 'aprobado' then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'movimiento_id', v_d.movimiento_id);
  end if;
  if v_d.estado = 'rechazado' then
    raise exception 'Ese documento fue rechazado; súbelo de nuevo si fue un error.' using errcode = '22023';
  end if;

  v_accion := coalesce(p_datos ->> 'accion', 'gasto');
  if v_accion not in ('gasto', 'archivar') then
    raise exception 'Acción no válida.' using errcode = '22023';
  end if;
  v_cfdi := (select c from cfdi c where c.id = v_d.cfdi_id);
  v_prop := coalesce(v_d.propuesta, '{}'::jsonb);

  if v_accion = 'gasto' then
    v_cat := coalesce(p_datos ->> 'categoria', '');
    if v_cat = '' or v_cat in ('cobro', 'aportacion', 'otro_ingreso') then
      raise exception 'Elige el tipo de gasto.' using errcode = '22023';
    end if;
    v_monto := coalesce((p_datos ->> 'monto')::numeric, v_cfdi.total);
    v_iva := coalesce((p_datos ->> 'iva')::numeric, v_cfdi.iva_trasladado, 0);
    v_fecha := coalesce((p_datos ->> 'fecha')::date, current_date);
    v_pagado := coalesce((p_datos ->> 'pagado')::boolean, true);
    v_cuenta := nullif(p_datos ->> 'cuenta_id', '')::uuid;
    v_cot := nullif(p_datos ->> 'cotizacion_id', '')::uuid;

    if v_pagado then
      if v_monto is null or v_monto <= 0 then
        raise exception 'El monto del gasto debe ser mayor a cero.' using errcode = '22023';
      end if;
      if v_cfdi.id is not null and exists (select 1 from expediente_movimientos where cfdi_id = v_cfdi.id) then
        raise exception 'Ese CFDI ya tiene un pago registrado.' using errcode = '22023';
      end if;
      v_mov := gen_random_uuid();
      insert into expediente_movimientos
        (id, cotizacion_id, tipo, categoria, fecha, concepto, monto, iva, forma, referencia,
         cuenta_id, cfdi_id, documento_id, archivo, archivo_nombre, notas, creado_por)
      values
        (v_mov, v_cot, 'egreso', v_cat, v_fecha,
         coalesce(nullif(trim(p_datos ->> 'concepto'), ''), v_cfdi.nombre_emisor, 'Gasto'),
         v_monto, least(coalesce(v_iva, 0), v_monto), nullif(p_datos ->> 'forma', ''),
         coalesce(nullif(trim(p_datos ->> 'referencia'), ''), v_cfdi.uuid_fiscal),
         v_cuenta, v_cfdi.id, p_documento, v_d.archivo, v_d.nombre_original,
         nullif(trim(p_datos ->> 'notas'), ''), coalesce(auth.jwt() ->> 'email', 'crm'));
    end if;

    if v_prop ? 'categoria' and v_prop ->> 'categoria' is distinct from v_cat then
      v_correccion := v_correccion || jsonb_build_object('categoria', jsonb_build_array(v_prop ->> 'categoria', v_cat));
    end if;
    if v_prop ? 'monto' and (v_prop ->> 'monto')::numeric is distinct from v_monto then
      v_correccion := v_correccion || jsonb_build_object('monto', jsonb_build_array(v_prop ->> 'monto', v_monto));
    end if;

    if v_cfdi.id is not null and v_cfdi.sentido = 'recibido' then
      insert into reglas_clasificacion (rfc_emisor, nombre, categoria, cuenta_id)
      values (v_cfdi.rfc_emisor, v_cfdi.nombre_emisor, v_cat, v_cuenta)
      on conflict (rfc_emisor) do update
        set categoria = excluded.categoria,
            cuenta_id = coalesce(excluded.cuenta_id, reglas_clasificacion.cuenta_id),
            nombre = coalesce(excluded.nombre, reglas_clasificacion.nombre),
            veces = case when reglas_clasificacion.categoria = excluded.categoria then reglas_clasificacion.veces + 1 else 1 end,
            actualizada_en = now();
    end if;
  end if;

  update documentos
     set estado = 'aprobado', movimiento_id = v_mov, correccion = nullif(v_correccion, '{}'::jsonb),
         aprobado_por = coalesce(auth.jwt() ->> 'email', 'crm'), aprobado_en = now()
   where id = p_documento;
  perform _apunta('documentos', p_documento, 'aprobar_documento', null,
                  jsonb_build_object('accion', v_accion, 'categoria', v_cat, 'monto', v_monto,
                                     'pagado', v_pagado, 'corrigio', v_correccion <> '{}'::jsonb), 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false, 'movimiento_id', v_mov);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.aprobar_pago_tecnico(p_pago uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_p pagos_tecnico%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador aprueba pagos a técnicos.' using errcode = '42501';
  end if;
  v_p := (select p from pagos_tecnico p where p.id = p_pago);
  if v_p.id is null then raise exception 'Ese pago no existe.' using errcode = '22023'; end if;
  if v_p.estado = 'aprobado' then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;
  if v_p.estado <> 'propuesto' then
    raise exception 'Ese pago está %; ya no se puede aprobar.', v_p.estado using errcode = '22023';
  end if;
  if _recalcular_pago_tecnico(p_pago) <= 0 then
    raise exception 'El pago no tiene nada que pagar.' using errcode = '22023';
  end if;

  update pagos_tecnico
     set estado = 'aprobado', aprobado_en = now(), aprobado_por = coalesce(auth.jwt() ->> 'email', 'crm')
   where id = p_pago;
  perform _apunta('pagos_tecnico', p_pago, 'aprobar_pago_tecnico', null,
                  jsonb_build_object('total', (select total from pagos_tecnico where id = p_pago)), 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.aprobar_salida(p_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  update salida_wa set estado = 'pendiente', aprobado_por = coalesce(auth.jwt() ->> 'email', 'crm'), aprobado_en = now()
   where id = any(p_ids) and estado = 'por_aprobar';
  return jsonb_build_object('ok', true, 'aprobados', (select count(*) from salida_wa where id = any(p_ids) and estado = 'pendiente'));
end $function$
;

CREATE OR REPLACE FUNCTION public.aprobar_tanda(p_tanda uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t campana_tandas%rowtype; r record; v_salida uuid; v_n int := 0; v_omit int := 0; v_motivo text;
        v_pl wa_plantillas%rowtype; v_espera int := 0;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  t := (select x from campana_tandas x where x.id = p_tanda);
  if t.id is null then
    raise exception 'Esa tanda no existe.' using errcode = 'P0002';
  end if;
  if t.estado <> 'propuesta' then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'estado', t.estado);
  end if;

  for r in select * from campana_envios where tanda_id = p_tanda and estado = 'en_tanda' loop
    v_motivo := case
      when exists (select 1 from wa_bajas b where b.telefono_norm = r.telefono_norm) then 'pidió BAJA'
      when _marketing_reciente(r.telefono_norm) then 'ya recibió marketing hace poco'
      else null end;
    if v_motivo is not null then
      update campana_envios set estado = 'omitido', motivo = v_motivo where id = r.id;
      v_omit := v_omit + 1;
      continue;
    end if;
    v_pl := (select p from wa_plantillas p where p.nombre = r.plantilla);
    if v_pl.estado is distinct from 'aprobada' then v_espera := v_espera + 1; end if;
    v_salida := gen_random_uuid();
    insert into salida_wa (id, llave, telefono, tipo, plantilla, variables, texto, origen, origen_id, categoria,
                           estado, aprobado_por, aprobado_en, creado_por)
    values (v_salida, 'campana:' || r.id, r.telefono, 'plantilla', r.plantilla,
            -- Meta rechaza variables con saltos de línea o espacios seguidos: se aplanan y se recortan.
            jsonb_strip_nulls(jsonb_build_object(
              'nombre', coalesce(nullif(left(trim(regexp_replace(coalesce(r.nombre, ''), '\s+', ' ', 'g')), 60), ''), 'cliente'),
              'equipo', coalesce(nullif(left(trim(regexp_replace(coalesce(r.equipo, ''), '\s+', ' ', 'g')), 60), ''), 'su equipo'),
              'fecha', coalesce(nullif(left(trim(regexp_replace(coalesce(r.ultimo_servicio, ''), '\s+', ' ', 'g')), 40), ''), 'su último servicio'))),
            'Campaña ' || t.mes || ' · ' || coalesce(r.categoria, ''), 'campana', r.id,
            coalesce(v_pl.categoria, 'marketing'), 'pendiente',
            coalesce(auth.jwt() ->> 'email', 'crm'), now(), coalesce(auth.jwt() ->> 'email', 'crm'))
    on conflict (llave) do nothing;
    update campana_envios set estado = 'aprobado', salida_id = v_salida where id = r.id;
    v_n := v_n + 1;
  end loop;

  update campana_tandas set estado = 'aprobada', aprobada_por = coalesce(auth.jwt() ->> 'email', 'crm'), aprobada_en = now()
   where id = p_tanda;
  return jsonb_build_object('ok', true, 'a_la_cola', v_n, 'omitidos', v_omit,
                            'esperan_plantilla', v_espera);
end $function$
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

CREATE OR REPLACE FUNCTION public.cancelar_compra(p_compra uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_c       compras%rowtype;
  v_devueltas int := 0;
begin
  if not es_admin() then
    raise exception 'Solo el administrador cancela compras.' using errcode = '42501';
  end if;
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Escribe por qué se cancela.' using errcode = '22023';
  end if;

  v_c := (select c from compras c where c.id = p_compra);
  if v_c.id is null then
    raise exception 'Esa compra no existe.' using errcode = 'P0002';
  end if;
  if v_c.estado = 'cancelada' then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'folio', v_c.folio);
  end if;

  -- Un `ajuste` negativo por cada línea que sí movió inventario. Las que solo guardaron el
  -- costo (porque su pedido ya se había recibido) no tienen nada que devolver.
  insert into movimientos_inventario (producto_id, tipo, cantidad, referencia, notas, usuario)
  select l.producto_id, 'ajuste', -l.cantidad,
         'COMPRA-' || v_c.folio || ' cancelada',
         concat('Cancelación de la compra ', v_c.folio, ': ', trim(p_motivo)),
         coalesce(auth.jwt() ->> 'email', 'crm')
    from compra_lineas l
   where l.compra_id = p_compra and l.movimiento_id is not null;
  get diagnostics v_devueltas = row_count;

  update compras
     set estado = 'cancelada', motivo_cancelacion = trim(p_motivo), updated_at = now()
   where id = p_compra;

  perform _apunta('compras', p_compra, 'cancelar',
                  jsonb_build_object('estado', v_c.estado),
                  jsonb_build_object('estado', 'cancelada', 'motivo', trim(p_motivo)), 'oficina');

  return jsonb_build_object('ok', true, 'folio', v_c.folio, 'ajustes', v_devueltas,
    'aviso', 'Los pedidos ligados siguen marcados como recibidos: revísalos si el material se devolvió.');
end $function$
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

CREATE OR REPLACE FUNCTION public.cancelar_pago_tecnico(p_pago uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_p pagos_tecnico%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador cancela pagos a técnicos.' using errcode = '42501';
  end if;
  v_p := (select p from pagos_tecnico p where p.id = p_pago);
  if v_p.id is null then raise exception 'Ese pago no existe.' using errcode = '22023'; end if;
  if v_p.estado = 'cancelado' then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;
  if v_p.estado = 'pagado' then
    raise exception 'Un pago ya registrado dejó egresos en los expedientes; corrígelo desde ahí.' using errcode = '22023';
  end if;
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Escribe el motivo de la cancelación.' using errcode = '22023';
  end if;

  update pagos_tecnico_lineas set activa = false where pago_id = p_pago;   -- las órdenes quedan libres
  update pagos_tecnico set estado = 'cancelado', motivo_cancelacion = trim(p_motivo) where id = p_pago;
  perform _apunta('pagos_tecnico', p_pago, 'cancelar_pago_tecnico',
                  jsonb_build_object('estado', v_p.estado, 'total', v_p.total),
                  jsonb_build_object('motivo', trim(p_motivo)), 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.cancelar_salida(p_ids uuid[], p_motivo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  update salida_wa set estado = 'cancelado', error = coalesce(nullif(trim(p_motivo), ''), 'cancelado por la oficina')
   where id = any(p_ids) and estado in ('por_aprobar', 'pendiente', 'fallido', 'sin_confirmar');
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.cancelar_tanda(p_tanda uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  update campana_envios set estado = 'propuesto', tanda_id = null where tanda_id = p_tanda and estado = 'en_tanda';
  update campana_tandas set estado = 'cancelada' where id = p_tanda and estado = 'propuesta';
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.catalogo_publico()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_resultado jsonb;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector del sitio.' using errcode = '42501';
  end if;

  v_resultado := (
    select coalesce(jsonb_agg(jsonb_build_object(
             'sku', p.sku,
             'categoria', p.categoria,
             'nombre', p.nombre,
             'marca', p.marca,
             'modelo', p.modelo,
             'descripcion', p.descripcion,
             'precio', p.precio,
             'precios', p.precios,
             'moneda', p.moneda,
             'unidad', p.unidad,
             'atributos', p.atributos,
             'clave_producto_sat', p.clave_producto_sat,
             'clave_unidad_sat', p.clave_unidad_sat,
             'disponible', d.disponibilidad <> 'pedido',
             'disponibilidad', d.disponibilidad,
             -- Existencias del proveedor en su última lectura (las de PowerMx no se publican).
             'existencia_merida', e.merida,
             'existencia_nacional', e.nacional,
             -- Solo si de verdad baja: una promoción por encima del precio normal no se anuncia.
             'precio_promocion', case when p.precio_promocion > 0 and p.precio_promocion < p.precio
                                      then p.precio_promocion end
           ) order by p.categoria, p.sku), '[]'::jsonb)
      from productos p
      cross join lateral (
        select case
          -- Existencia propia: físico − apartado − resguardo, la MISMA fórmula de la 39 (tres sumas por
          -- separado; juntarlas en una sola da un número equivocado).
          when coalesce((
                 select
                   coalesce(sum(case m.tipo
                                  when 'entrada' then m.cantidad
                                  when 'salida_venta' then -m.cantidad
                                  when 'consumo_resguardo' then -m.cantidad
                                  when 'consumo_servicio' then -m.cantidad
                                  when 'ajuste' then m.cantidad
                                  when 'entrega_tecnico' then -m.cantidad
                                  when 'devolucion_tecnico' then m.cantidad
                                  else 0 end), 0)
                   - coalesce(sum(case m.tipo
                                    when 'apartado' then m.cantidad
                                    when 'libera_apartado' then -m.cantidad
                                    when 'salida_venta' then -m.cantidad
                                    when 'a_resguardo' then -m.cantidad
                                    else 0 end), 0)
                   - coalesce(sum(case m.tipo
                                    when 'a_resguardo' then m.cantidad
                                    when 'consumo_resguardo' then -m.cantidad
                                    else 0 end), 0)
                 from movimientos_inventario m
                 where m.producto_id = p.id
               ), 0) > 0 then 'inmediata'
          -- Existencia del proveedor en Mérida (XLStore MID), en su última lectura.
          when exists (select 1 from producto_proveedores l
                         join proveedor_productos x
                           on x.proveedor = l.proveedor and x.sku_proveedor = l.proveedor_sku
                        where l.producto_id = p.id and x.vigente and x.stock_local > 0) then 'inmediata'
          -- Solo en la existencia nacional del proveedor.
          when exists (select 1 from producto_proveedores l
                         join proveedor_productos x
                           on x.proveedor = l.proveedor and x.sku_proveedor = l.proveedor_sku
                        where l.producto_id = p.id and x.vigente and x.stock_proveedor > 0) then 'proveedor'
          else 'pedido'
        end as disponibilidad
      ) d
      cross join lateral (
        select sum(x.stock_local) filter (where x.stock_local > 0) as merida,
               sum(x.stock_proveedor) filter (where x.stock_proveedor > 0) as nacional
          from producto_proveedores l
          join proveedor_productos x
            on x.proveedor = l.proveedor and x.sku_proveedor = l.proveedor_sku
         where l.producto_id = p.id and x.vigente
      ) e
     where p.activo and p.publicar);

  return v_resultado;
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

CREATE OR REPLACE FUNCTION public.cerrar_expediente(p_cotizacion uuid, p_forzar boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_c cotizaciones%rowtype;
  v_r jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador cierra expedientes.' using errcode = '42501';
  end if;
  v_c := (select c from cotizaciones c where c.id = p_cotizacion);
  if v_c.id is null then
    raise exception 'Esa cotización ya no existe.' using errcode = '22023';
  end if;
  if v_c.expediente_cerrado_en is not null then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;

  v_r := expediente_resumen(p_cotizacion);
  if jsonb_array_length(v_r -> 'avisos') > 0 and not p_forzar then
    return jsonb_build_object('ok', false, 'avisos', v_r -> 'avisos', 'resumen', v_r);
  end if;

  update cotizaciones
     set expediente_cerrado_en = now(),
         expediente_cerrado_por = coalesce(auth.jwt() ->> 'email', 'crm'),
         expediente_cierre = v_r
   where id = p_cotizacion;
  perform _apunta('cotizaciones', p_cotizacion, 'cerrar_expediente', null,
                  jsonb_build_object('utilidad', v_r -> 'utilidad', 'margen_pct', v_r -> 'margen_pct',
                                     'avisos', v_r -> 'avisos'), 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false, 'resumen', v_r);
end;
$function$
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

CREATE OR REPLACE FUNCTION public.cola_whatsapp()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  -- "enviando" por más de 10 min: la función se cayó a la mitad. No se reintenta sola
  -- (podría duplicar): se muestra para que una persona decida.
  update salida_wa set estado = 'sin_confirmar', error = 'no se confirmó el envío; revisa si llegó'
   where estado = 'enviando' and tomado_en < now() - interval '10 minutes';
  return (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'id', s.id, 'estado', s.estado, 'origen', s.origen, 'plantilla', s.plantilla,
            'telefono', s.telefono, 'texto', s.texto, 'error', s.error, 'creado', s.created_at,
            'plantilla_aprobada', (select p.estado = 'aprobada' from wa_plantillas p where p.nombre = s.plantilla)))
            order by s.created_at), '[]'::jsonb)
            from salida_wa s
           where s.estado in ('por_aprobar', 'pendiente', 'fallido', 'sin_confirmar'));
end $function$
;

CREATE OR REPLACE FUNCTION public.compras_recientes(p_dias integer DEFAULT 90)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when not es_admin() then '[]'::jsonb else
    coalesce((
      select jsonb_agg(x order by x ->> 'fecha' desc, (x ->> 'folio')::bigint desc)
      from (
        select jsonb_build_object(
          'id', c.id, 'folio', c.folio, 'proveedor', c.proveedor, 'factura', c.factura,
          'fecha', c.fecha, 'subtotal', c.subtotal, 'iva', c.iva, 'total', c.total,
          'moneda', c.moneda, 'estado', c.estado, 'notas', c.notas,
          'motivo_cancelacion', c.motivo_cancelacion,
          'archivo_xml', c.archivo_xml, 'archivo_pdf', c.archivo_pdf,
          'lineas', (
            select coalesce(jsonb_agg(jsonb_build_object(
                     'sku', p.sku, 'nombre', p.nombre, 'unidad', p.unidad,
                     'cantidad', l.cantidad, 'costo_unitario', l.costo_unitario,
                     'importe', l.importe,
                     'movio_inventario', l.movimiento_id is not null,
                     'pedido', (select r.folio from requisiciones r where r.id = l.requisicion_id))
                   order by p.sku), '[]'::jsonb)
              from compra_lineas l join productos p on p.id = l.producto_id
             where l.compra_id = c.id)) as x
        from compras c
        where c.fecha >= current_date - make_interval(days => greatest(p_dias, 1))
      ) z), '[]'::jsonb)
  end
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

CREATE OR REPLACE FUNCTION public.descartar_importacion_whatsapp(p_id uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if nullif(trim(coalesce(p_motivo, '')), '') is null then
    raise exception 'Escribe por qué se descarta.' using errcode = '22023';
  end if;
  update importacion_whatsapp
     set estado = 'descartada', motivo = trim(p_motivo),
         revisado_por = coalesce(auth.jwt() ->> 'email', 'crm'), revisado_en = now()
   where id = p_id and estado = 'por_revisar';
  if not found then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;
  return jsonb_build_object('ok', true);
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

CREATE OR REPLACE FUNCTION public.eliminar_cotizacion(p_cotizacion uuid, p_ejecutar boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cot cotizaciones%rowtype;
  v_citas uuid[];
  v_ordenes uuid[];
  v_reqs uuid[];
  v_bloqueos text[] := '{}';
  v_n int;
  v_folios_os text;
  v_resumen jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador puede eliminar cotizaciones.' using errcode = '42501';
  end if;

  v_cot := (select c from cotizaciones c where c.id = p_cotizacion);
  if v_cot.id is null then
    raise exception 'Esa cotización ya no existe.' using errcode = '22023';
  end if;

  v_citas   := array(select id from citas where cotizacion_id = p_cotizacion);
  v_ordenes := array(select id from ordenes_servicio where cita_id = any(v_citas));
  v_reqs    := array(select id from requisiciones where cotizacion_id = p_cotizacion);

  -- ---- lo que lo impide ----
  v_n := (select count(*) from entregas
           where orden_id = any(v_ordenes) and estado not in ('pendiente', 'cancelada'));
  if v_n > 0 then
    v_bloqueos := v_bloqueos || format('Ya se entregó material al técnico (%s entrega(s)). Hay que recibir la devolución antes.', v_n);
  end if;

  v_n := (select count(*) from devoluciones where orden_id = any(v_ordenes));
  if v_n > 0 then
    v_bloqueos := v_bloqueos || format('Tiene %s devolución(es) registradas en el almacén.', v_n);
  end if;

  v_n := (select count(*) from envios_orden where orden_id = any(v_ordenes));
  if v_n > 0 then
    v_bloqueos := v_bloqueos || format('La orden ya se envió al cliente (%s envío(s) registrados).', v_n);
  end if;

  v_n := (select count(*) from movimientos_inventario
           where tipo not in ('apartado', 'libera_apartado')
             and (cotizacion_id = p_cotizacion
                  or orden_id = any(v_ordenes) or orden_servicio_id = any(v_ordenes)));
  if v_n > 0 then
    v_bloqueos := v_bloqueos || format('Tiene %s movimiento(s) de inventario que no son apartado (entradas, consumos, ventas…).', v_n);
  end if;

  v_n := (select count(*) from (
            select producto_id
              from movimientos_inventario
             where tipo in ('apartado', 'libera_apartado') and cotizacion_id = p_cotizacion
             group by producto_id
            having sum(case tipo when 'apartado' then cantidad else -cantidad end) <> 0
          ) x);
  if v_n > 0 then
    v_bloqueos := v_bloqueos || format('Todavía tiene material apartado de %s producto(s). Cámbiala primero a Borrador para liberarlo.', v_n);
  end if;

  v_n := (select count(*) from salida_wa
           where origen = 'aviso' and estado in ('enviando', 'enviado', 'entregado', 'leido', 'sin_confirmar')
             and origen_id in (select id from avisos where cita_id = any(v_citas)));
  if v_n > 0 then
    v_bloqueos := v_bloqueos || format('Ya se mandaron %s aviso(s) de la cita por WhatsApp al cliente o al técnico.', v_n);
  end if;

  v_n := (select count(*) from requisiciones
           where id = any(v_reqs) and estado in ('pedida', 'recibida'));
  if v_n > 0 then
    v_bloqueos := v_bloqueos || format('Tiene %s pedido(s) al proveedor ya pedidos o recibidos. Cancélalos primero en Pedidos.', v_n);
  end if;

  v_n := (select count(*) from compra_lineas where requisicion_id = any(v_reqs));
  if v_n > 0 then
    v_bloqueos := v_bloqueos || 'Un pedido suyo está ligado a una compra.';
  end if;

  v_folios_os := coalesce((select string_agg('OS-' || folio, ', ' order by folio)
                             from ordenes_servicio where id = any(v_ordenes)), '');

  v_resumen := jsonb_build_object(
    'folio', v_cot.folio,
    'estado', v_cot.estado,
    'citas', coalesce(array_length(v_citas, 1), 0),
    'ordenes', coalesce(array_length(v_ordenes, 1), 0),
    'ordenes_folios', v_folios_os,
    'movimientos_apartado', (select count(*) from movimientos_inventario
                              where tipo in ('apartado', 'libera_apartado')
                                and (cotizacion_id = p_cotizacion
                                     or orden_id = any(v_ordenes) or orden_servicio_id = any(v_ordenes))),
    'pedidos', coalesce(array_length(v_reqs, 1), 0),
    'solicitudes_material', (select count(*) from solicitudes_material where orden_id = any(v_ordenes)),
    'entregas_sin_firmar', (select count(*) from entregas
                             where orden_id = any(v_ordenes) and estado in ('pendiente', 'cancelada'))
  );

  if array_length(v_bloqueos, 1) is not null then
    return jsonb_build_object('ok', false, 'ejecutado', false, 'bloqueos', to_jsonb(v_bloqueos), 'resumen', v_resumen);
  end if;

  if not p_ejecutar then
    return jsonb_build_object('ok', true, 'ejecutado', false, 'bloqueos', '[]'::jsonb, 'resumen', v_resumen);
  end if;

  -- ---- el borrado, de lo más dependiente a la cotización ----
  delete from solicitudes_material where orden_id = any(v_ordenes);
  delete from entregas where orden_id = any(v_ordenes);                  -- sus líneas se van en cascada
  delete from orden_surtido where orden_id = any(v_ordenes) or cotizacion_id = p_cotizacion;
  delete from movimientos_inventario
   where tipo in ('apartado', 'libera_apartado')
     and (cotizacion_id = p_cotizacion
          or orden_id = any(v_ordenes) or orden_servicio_id = any(v_ordenes));
  delete from requisiciones where id = any(v_reqs);
  delete from ordenes_servicio where id = any(v_ordenes);                -- partes, revisión y PDF en cascada
  -- Los avisos sin mandar que esperan en la cola de WhatsApp: si no se quitan, saldría un mensaje
  -- de una cita que ya no existe. (Esa cola no tiene llave foránea hacia los avisos.)
  delete from salida_wa
   where origen = 'aviso'
     and origen_id in (select id from avisos where cita_id = any(v_citas));
  delete from citas where id = any(v_citas);                             -- sus avisos en cascada
  delete from cotizaciones where id = p_cotizacion;

  perform _apunta('cotizaciones', p_cotizacion, 'eliminar', v_resumen, null, 'oficina');
  return jsonb_build_object('ok', true, 'ejecutado', true, 'bloqueos', '[]'::jsonb, 'resumen', v_resumen);
end;
$function$
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

CREATE OR REPLACE FUNCTION public.encolar_orden(p_envio uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_env envios_orden%rowtype; v_folio bigint; v_n int := 0; d jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  v_env := (select e from envios_orden e where e.id = p_envio);
  if v_env.id is null then
    raise exception 'Ese envío no existe.' using errcode = 'P0002';
  end if;
  v_folio := (select folio from ordenes_servicio where id = v_env.orden_id);
  for d in select * from jsonb_array_elements(coalesce(v_env.destinatarios, '[]'::jsonb)) loop
    continue when normalizar_telefono(d ->> 'telefono') is null;
    insert into salida_wa (llave, telefono, tipo, plantilla, variables, documento_ruta, documento_nombre,
                           texto, origen, origen_id, categoria, estado, creado_por)
    values ('orden:' || p_envio || ':' || normalizar_telefono(d ->> 'telefono'), d ->> 'telefono', 'plantilla',
            'orden_servicio_lista',
            jsonb_build_object('nombre', coalesce(nullif(trim(d ->> 'nombre'), ''), 'cliente'), 'folio', 'OS-' || v_folio),
            v_env.ruta, 'OS-' || v_folio || '.pdf',
            'Orden de servicio OS-' || v_folio || ' (PDF)', 'orden', p_envio, 'utilidad', 'pendiente',
            coalesce(auth.jwt() ->> 'email', 'crm'))
    on conflict (llave) do nothing;
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'encolados', v_n);
end $function$
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

CREATE OR REPLACE FUNCTION public.expediente_resumen(p_cotizacion uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_c cotizaciones%rowtype;
  v_base numeric;
  v_cobrado numeric;
  v_comprobado numeric;
  v_verificado numeric;
  v_sin_comprobar int;
  v_sin_verificar int;
  v_material jsonb;
  v_material_total numeric;
  v_sin_costo int;
  v_otros numeric;
  v_por_cat jsonb;
  v_utilidad numeric;
  v_avisos text[] := '{}';
  v_hay_tecnico boolean;
begin
  if not es_admin() then
    raise exception 'Solo el administrador ve el expediente.' using errcode = '42501';
  end if;
  v_c := (select c from cotizaciones c where c.id = p_cotizacion);
  if v_c.id is null then
    raise exception 'Esa cotización ya no existe.' using errcode = '22023';
  end if;

  v_base := coalesce(v_c.total, 0) - coalesce(v_c.iva, 0);          -- subtotal − descuento

  v_cobrado := coalesce((select sum(monto) from expediente_movimientos
                          where cotizacion_id = p_cotizacion and tipo = 'ingreso'), 0);
  v_comprobado := coalesce((select sum(monto) from expediente_movimientos
                             where cotizacion_id = p_cotizacion and tipo = 'ingreso' and archivo is not null), 0);
  v_verificado := coalesce((select sum(monto) from expediente_movimientos
                             where cotizacion_id = p_cotizacion and tipo = 'ingreso'
                               and archivo is not null and leido_ia and monto_leido is not null
                               and abs(monto_leido - monto) <= 0.01), 0);
  v_sin_comprobar := (select count(*) from expediente_movimientos
                       where cotizacion_id = p_cotizacion and tipo = 'ingreso' and archivo is null);
  v_sin_verificar := (select count(*) from expediente_movimientos
                       where cotizacion_id = p_cotizacion and tipo = 'ingreso' and archivo is not null
                         and not (leido_ia and monto_leido is not null and abs(monto_leido - monto) <= 0.01));

  if v_c.expediente_cerrado_en is not null and v_c.expediente_cierre ? 'material' then
    v_material := v_c.expediente_cierre -> 'material' -> 'lineas';
  else
    v_material := coalesce((
      select jsonb_agg(jsonb_build_object(
               'producto_id', q.pid, 'sku', p.sku, 'nombre', p.nombre, 'cantidad', q.cant,
               'costo_unitario', coalesce(p.costo, 0), 'importe', round(q.cant * coalesce(p.costo, 0), 2),
               'sin_costo', coalesce(p.costo, 0) = 0) order by p.sku)
        from (select (e ->> 'producto_id')::uuid as pid, sum((e ->> 'cantidad')::numeric) as cant
                from jsonb_array_elements(v_c.partidas) e
               where nullif(e ->> 'producto_id', '') is not null
               group by 1) q
        join productos p on p.id = q.pid), '[]'::jsonb);
  end if;
  v_material_total := coalesce((select sum((l ->> 'importe')::numeric) from jsonb_array_elements(v_material) l), 0);
  v_sin_costo := (select count(*) from jsonb_array_elements(v_material) l where (l ->> 'sin_costo')::boolean);

  v_por_cat := coalesce((
    select jsonb_object_agg(categoria, jsonb_build_object('n', n, 'monto', monto, 'sin_iva', sin_iva))
      from (select categoria, count(*) as n, sum(monto) as monto, sum(monto - iva) as sin_iva
              from expediente_movimientos
             where cotizacion_id = p_cotizacion and tipo = 'egreso'
             group by categoria) x), '{}'::jsonb);
  v_otros := coalesce((select sum(monto - iva) from expediente_movimientos
                        where cotizacion_id = p_cotizacion and tipo = 'egreso'), 0);
  v_hay_tecnico := exists (select 1 from expediente_movimientos
                            where cotizacion_id = p_cotizacion and categoria = 'tecnico');

  v_utilidad := v_base - v_material_total - v_otros;

  -- Avisos (no impiden cerrar; se muestran para cerrar con conocimiento).
  if v_c.estado <> 'aceptada' then
    v_avisos := v_avisos || format('La cotización está en estado %s, no Aceptada.', v_c.estado);
  end if;
  if v_c.total - v_cobrado > 0.009 then
    v_avisos := v_avisos || format('Falta cobrar $%s.', to_char(v_c.total - v_cobrado, 'FM999,999,990.00'));
  end if;
  if v_cobrado - v_c.total > 1 then
    v_avisos := v_avisos || format('Se cobró de más: $%s sobre el total.', to_char(v_cobrado - v_c.total, 'FM999,999,990.00'));
  end if;
  if v_sin_comprobar > 0 then
    v_avisos := v_avisos || format('%s cobro(s) sin comprobante bancario.', v_sin_comprobar);
  end if;
  if v_sin_verificar > 0 then
    v_avisos := v_avisos || format('%s cobro(s) con comprobante que no se ha leído o cuyo monto no coincide.', v_sin_verificar);
  end if;
  if v_sin_costo > 0 then
    v_avisos := v_avisos || format('%s pieza(s) de la cotización sin costo capturado: la utilidad sale inflada.', v_sin_costo);
  end if;
  if not v_hay_tecnico then
    v_avisos := array_append(v_avisos, 'No hay pago de técnicos capturado.'::text);
  end if;

  return jsonb_build_object(
    'folio', v_c.folio, 'estado', v_c.estado,
    'cerrado', v_c.expediente_cerrado_en is not null, 'cerrado_en', v_c.expediente_cerrado_en,
    'ingreso', jsonb_build_object(
      'base', v_base, 'iva', coalesce(v_c.iva, 0), 'total', coalesce(v_c.total, 0),
      'cobrado', v_cobrado, 'comprobado', v_comprobado, 'verificado', v_verificado,
      'por_cobrar', greatest(coalesce(v_c.total, 0) - v_cobrado, 0),
      'cobranza', jsonb_build_object(
        'estado', v_c.cobranza_estado, 'liquidada_en', v_c.cobranza_liquidada_en,
        'manual', v_c.cobranza_manual, 'nota', v_c.cobranza_nota,
        'falta_verificar', greatest(coalesce(v_c.total, 0) - 1 - v_verificado, 0))),
    'material', jsonb_build_object('lineas', v_material, 'total', v_material_total, 'sin_costo', v_sin_costo),
    'egresos', jsonb_build_object('por_categoria', v_por_cat, 'total_sin_iva', v_otros),
    'utilidad', v_utilidad,
    'margen_pct', case when v_base > 0 then round(v_utilidad / v_base * 100, 1) else null end,
    'avisos', to_jsonb(v_avisos));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.fijar_parametro_costeo(p_clave text, p_valor numeric)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_antes numeric;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if p_valor is null or p_valor < 0 then
    raise exception 'El valor debe ser un número de 0 en adelante.' using errcode = '22023';
  end if;
  v_antes := (select valor from parametros_costeo where clave = p_clave);
  if v_antes is null then
    raise exception 'No existe el parámetro %.', p_clave using errcode = '22023';
  end if;
  if v_antes = p_valor then
    return 'sin_cambio';
  end if;
  update parametros_costeo
     set valor = p_valor, actualizado_en = now(),
         actualizado_por = coalesce(auth.jwt() ->> 'email', 'crm')
   where clave = p_clave;
  perform _apunta('parametros_costeo', gen_random_uuid(), 'fijar_parametro',
                  jsonb_build_object('clave', p_clave, 'valor', v_antes),
                  jsonb_build_object('clave', p_clave, 'valor', p_valor), 'oficina');
  return 'ok';
end $function$
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

CREATE OR REPLACE FUNCTION public.generar_recordatorios()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_manana date := (now() at time zone 'America/Mexico_City')::date + 1;
  n int := 0;
  k int;
begin
  -- Con contactos del equipo (o de toda la empresa, si no hay equipo): uno por contacto.
  insert into avisos (cita_id, tipo, destinatario, llave, contacto_id, nombre, telefono)
  select c.id, 'recordatorio', 'cliente', 'c:' || ct.id, ct.id, ct.nombre, ct.telefono
    from citas c
    cross join lateral _contactos_de_aviso(c.id) ct
   where c.estado = 'programada' and c.fecha = v_manana
     and not exists (
       select 1 from avisos x where x.cita_id = c.id and x.llave = 'c:' || ct.id and x.tipo = 'recordatorio')
  on conflict (cita_id, llave) where estado = 'pendiente' do nothing;
  get diagnostics k = row_count; n := n + k;

  -- Sin contactos: el teléfono de la ficha del cliente, si tiene.
  insert into avisos (cita_id, tipo, destinatario, llave, nombre, telefono)
  select c.id, 'recordatorio', 'cliente', 'f:' || cl.id,
         coalesce(nullif(trim(cl.contacto_nombre), ''), cl.nombre), cl.telefono
    from citas c
    join clientes cl on cl.id = c.cliente_id
   where c.estado = 'programada' and c.fecha = v_manana
     and normalizar_telefono(cl.telefono) is not null
     and not exists (select 1 from _contactos_de_aviso(c.id))
     and not exists (
       select 1 from avisos x where x.cita_id = c.id and x.llave = 'f:' || cl.id and x.tipo = 'recordatorio')
  on conflict (cita_id, llave) where estado = 'pendiente' do nothing;
  get diagnostics k = row_count; n := n + k;

  return n;
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

CREATE OR REPLACE FUNCTION public.importar_productos_proveedor(p_proveedor text, p_categorias text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_prov text := lower(trim(p_proveedor));
  v_pp proveedor_productos;
  v_map text[];
  v_sku text;
  v_id uuid;
  v_creados int := 0;
  v_ya int := 0;
  v_sin int := 0;
  v_por jsonb := '{}'::jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;

  for v_pp in
    select * from proveedor_productos
     where proveedor = v_prov and vigente
       and (p_categorias is null or categoria = any(p_categorias))
     order by categoria, sku_proveedor
  loop
    v_map := _categoria_crm(v_pp.categoria);
    if v_map is null then
      v_sin := v_sin + 1;
      continue;
    end if;
    v_sku := _sku_crm(v_prov, v_pp.sku_proveedor);
    -- Ya ligado (un repetido de otro proveedor) o ya existe ese SKU: no se duplica.
    if exists (select 1 from producto_proveedores l
                where l.proveedor = v_prov and l.proveedor_sku = v_pp.sku_proveedor)
       or exists (select 1 from productos p where p.sku = v_sku) then
      v_ya := v_ya + 1;
      continue;
    end if;

    v_id := gen_random_uuid();
    insert into productos (id, sku, categoria, nombre, marca, modelo, descripcion, moneda, unidad,
                           minimo, publicar, activo, proveedor, proveedor_sku, precio_auto, atributos)
    values (v_id, v_sku, v_map[1],
            coalesce(nullif(trim(v_pp.nombre), ''), nullif(trim(v_pp.modelo), ''), v_pp.sku_proveedor),
            nullif(trim(v_pp.marca), ''), nullif(trim(v_pp.modelo), ''), nullif(trim(v_pp.descripcion), ''),
            'MXN', 'pieza', 0, false, true, v_prov, v_pp.sku_proveedor, false,
            jsonb_strip_nulls(jsonb_build_object(
              'origen', 'proveedor',
              'grupo_proveedor', v_pp.categoria,
              'subcategoria', v_map[2],
              'imagen_proveedor', v_pp.url_imagen,
              'documentos_proveedor', case when v_pp.documentos = '{}'::jsonb then null else v_pp.documentos end)));
    -- El disparador ya creó el vínculo al insertar el producto; aquí solo queda como opción 1.
    insert into producto_proveedores (producto_id, proveedor, proveedor_sku, opcion)
    values (v_id, v_prov, v_pp.sku_proveedor, 1)
    on conflict (producto_id, proveedor) do update set opcion = 1;

    v_creados := v_creados + 1;
    v_por := jsonb_set(v_por, array[v_map[1]], to_jsonb(coalesce((v_por ->> v_map[1])::int, 0) + 1));
  end loop;

  if v_creados > 0 then
    perform _apunta('productos', gen_random_uuid(), 'importar_de_proveedor', null,
                    jsonb_build_object('proveedor', v_prov, 'creados', v_creados, 'por_categoria', v_por),
                    'oficina');
  end if;
  return jsonb_build_object('creados', v_creados, 'ya_existian', v_ya, 'sin_categoria', v_sin,
                            'por_categoria', v_por);
end $function$
;

CREATE OR REPLACE FUNCTION public.inicio_admin()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when not es_admin() then '{}'::jsonb else jsonb_build_object(

    'fecha', current_date,

    -- ---- el día: las citas de hoy, en orden ----
    'hoy', coalesce((
      select jsonb_agg(jsonb_build_object(
               'cita_id', c.id,
               'hora', to_char(c.hora, 'HH24:MI'),
               'cliente', cl.nombre,
               'tipo', c.tipo_servicio,
               'estado', c.estado,
               'tecnico', p.nombre,
               'orden', (select o.folio from ordenes_servicio o where o.cita_id = c.id limit 1))
             order by c.hora nulls last)
        from citas c
        join clientes cl on cl.id = c.cliente_id
        left join perfiles p on p.id = c.tecnico_id
       where c.fecha = current_date
         and coalesce(c.estado, '') not in ('cancelada')), '[]'::jsonb),

    -- ---- lo que está esperando ----
    'urgente', coalesce((
      select jsonb_agg(x order by
               case x ->> 'nivel' when 'alto' then 1 when 'medio' then 2 else 3 end,
               (x ->> 'n')::int desc)
      from (
        -- Material que un técnico debe desde hace 5 días o más. Es el umbral "Atrasada" que
        -- ya usa la pantalla de Almacén; no se inventa uno nuevo.
        select jsonb_build_object(
          'clave', 'devoluciones', 'nivel', 'alto', 'pantalla', 'almacen',
          'n', n, 'texto', concat(n, case when n = 1 then ' devolución' else ' devoluciones' end,
                                  ' atrasada', case when n = 1 then '' else 's' end)) as x
          from (select count(distinct s.orden_id) as n
                  from orden_surtido s
                  join ordenes_servicio o on o.id = s.orden_id
                 where s.cantidad_entregada - s.cantidad_usada
                       - s.cantidad_devuelta - s.cantidad_diferencia > 0
                   and o.updated_at < now() - interval '5 days') z where n > 0

        union all
        -- Avisos redactados que nadie mandó: el cliente no sabe que van.
        select jsonb_build_object(
          'clave', 'avisos', 'nivel', 'alto', 'pantalla', 'agenda',
          'n', n, 'texto', concat(n, ' aviso', case when n = 1 then '' else 's' end,
                                  ' de cita sin mandar'))
          from (select count(*) as n from avisos where estado = 'pendiente') z where n > 0

        union all
        -- Un lead del sitio se enfría: es de lo que más se pudre con el tiempo.
        select jsonb_build_object(
          'clave', 'solicitudes', 'nivel', 'alto', 'pantalla', 'solicitudes',
          'n', n, 'texto', concat(n, ' solicitud', case when n = 1 then '' else 'es' end,
                                  ' del sitio sin ver'))
          from (select count(*) as n from solicitudes_web where estado = 'nueva') z where n > 0

        union all
        select jsonb_build_object(
          'clave', 'whatsapp', 'nivel', 'alto', 'pantalla', 'whatsapp',
          'n', n, 'texto', concat(n, case when n = 1 then ' conversación' else ' conversaciones' end,
                                  ' de WhatsApp sin leer'))
          from (select count(*) as n from conversaciones
                 where sin_leer > 0 and coalesce(estado, 'abierta') <> 'cerrada') z where n > 0

        union all
        select jsonb_build_object(
          'clave', 'entregas', 'nivel', 'medio', 'pantalla', 'almacen',
          'n', n, 'texto', concat(n, ' entrega', case when n = 1 then '' else 's' end,
                                  ' esperando la firma del técnico'))
          from (select count(*) as n from entregas where estado = 'pendiente') z where n > 0

        union all
        select jsonb_build_object(
          'clave', 'por_programar', 'nivel', 'medio', 'pantalla', 'agenda',
          'n', n, 'texto', concat(n, ' cita', case when n = 1 then '' else 's' end,
                                  ' por programar'))
          from (select count(*) as n from citas where estado = 'por_programar') z where n > 0

        union all
        select jsonb_build_object(
          'clave', 'cotiza_whatsapp', 'nivel', 'medio', 'pantalla', 'cotizaciones',
          'n', n, 'texto', concat(n, case when n = 1 then ' cotización' else ' cotizaciones' end,
                                  ' del agente por revisar'))
          from (select count(*) as n from cotizaciones
                 where estado = 'borrador' and origen = 'whatsapp') z where n > 0

        union all
        -- Una cotización que vence sin que nadie la persiga es una venta que se pierde sola.
        select jsonb_build_object(
          'clave', 'por_vencer', 'nivel', 'medio', 'pantalla', 'cotizaciones',
          'n', n, 'texto', concat(n, case when n = 1 then ' cotización' else ' cotizaciones' end,
                                  ' vence', case when n = 1 then '' else 'n' end,
                                  ' en 3 días o menos'))
          from (select count(*) as n from cotizaciones
                 where estado = 'enviada'
                   and fecha + coalesce(vigencia_dias, 15) between current_date
                       and current_date + 3) z where n > 0

        union all
        select jsonb_build_object(
          'clave', 'por_enviar', 'nivel', 'medio', 'pantalla', 'ordenes',
          'n', n, 'texto', concat(n, case when n = 1 then ' orden' else ' órdenes' end,
                                  ' cerrada', case when n = 1 then '' else 's' end,
                                  ' por enviar al cliente'))
          from (select count(*) as n from ordenes_servicio o
                 where o.estado = 'cerrada' and o.enviar_al_cerrar
                   and not exists (select 1 from envios_orden e where e.orden_id = o.id)) z
         where n > 0

        union all
        -- El negocio vive de las pólizas: un mantenimiento vencido es un cliente sin visitar.
        select jsonb_build_object(
          'clave', 'mantenimientos', 'nivel', 'medio', 'pantalla', 'equipos',
          'n', n, 'texto', concat(n, ' equipo', case when n = 1 then '' else 's' end,
                                  ' con el mantenimiento vencido o por vencer'))
          from (select count(*) as n from equipos
                 where coalesce(estado, 'activo') <> 'baja'
                   and proximo_mantenimiento is not null
                   and proximo_mantenimiento <= current_date + 7) z where n > 0

        union all
        select jsonb_build_object(
          'clave', 'pedidos', 'nivel', 'bajo', 'pantalla', 'requisiciones',
          'n', n, 'texto', concat(n, ' pedido', case when n = 1 then '' else 's' end,
                                  ' por poner al proveedor'))
          from (select count(*) as n from requisiciones where estado = 'pendiente') z where n > 0

        union all
        select jsonb_build_object(
          'clave', 'material', 'nivel', 'medio', 'pantalla', 'almacen',
          'n', n, 'texto', concat(n, ' pieza', case when n = 1 then '' else 's' end,
                                  ' que pidió un técnico'))
          from (select count(*) as n from solicitudes_material where estado = 'pendiente') z
         where n > 0

        union all
        -- Una venta aceptada hace más de un mes y sin cobrarse por completo: dinero que ya se ganó.
        select jsonb_build_object(
          'clave', 'cobranza_atrasada', 'nivel', 'alto', 'pantalla', 'cotizaciones',
          'n', n,
          'texto', concat(n, case when n = 1 then ' cotización' else ' cotizaciones' end,
                          ' aceptada', case when n = 1 then '' else 's' end,
                          ' con más de 30 días sin cobrarse por completo',
                          case when falta > 0
                               then concat(' · $', to_char(falta, 'FM999,999,990'), ' por cobrar')
                               else ' · cobrado: falta verificar el comprobante' end))
          from (select count(*) as n,
                       coalesce(sum(greatest(c.total - coalesce(m.cobrado, 0), 0)), 0) as falta
                  from cotizaciones c
                  left join lateral (select sum(x.monto) as cobrado
                                       from expediente_movimientos x
                                      where x.cotizacion_id = c.id and x.tipo = 'ingreso') m on true
                 where c.estado = 'aceptada' and c.cobranza_estado <> 'liquidada'
                   and coalesce(c.total, 0) > 0
                   and c.fecha <= current_date - 30) z where n > 0

        union all
        -- Lo aceptado hace menos de un mes y todavía sin cobrarse por completo.
        select jsonb_build_object(
          'clave', 'cobranza', 'nivel', 'medio', 'pantalla', 'cotizaciones',
          'n', n,
          'texto', concat(n, case when n = 1 then ' cotización' else ' cotizaciones' end,
                          ' aceptada', case when n = 1 then '' else 's' end,
                          ' sin cobrarse por completo',
                          case when falta > 0
                               then concat(' · $', to_char(falta, 'FM999,999,990'), ' por cobrar')
                               else ' · cobrado: falta verificar el comprobante' end))
          from (select count(*) as n,
                       coalesce(sum(greatest(c.total - coalesce(m.cobrado, 0), 0)), 0) as falta
                  from cotizaciones c
                  left join lateral (select sum(x.monto) as cobrado
                                       from expediente_movimientos x
                                      where x.cotizacion_id = c.id and x.tipo = 'ingreso') m on true
                 where c.estado = 'aceptada' and c.cobranza_estado <> 'liquidada'
                   and coalesce(c.total, 0) > 0
                   and c.fecha > current_date - 30) z where n > 0

        union all
        -- Cobrada hace más de 15 días y sin cerrar: la utilidad de esa operación no se conoce todavía.
        select jsonb_build_object(
          'clave', 'expedientes_atrasados', 'nivel', 'alto', 'pantalla', 'cotizaciones',
          'n', n,
          'texto', concat(n, case when n = 1 then ' cotización' else ' cotizaciones' end,
                          case when n = 1 then ' cobrada' else ' cobradas' end,
                          ' hace más de 15 días con el expediente sin cerrar (faltan los gastos y la utilidad)'))
          from (select count(*) as n
                  from cotizaciones c
                 where c.estado = 'aceptada' and c.cobranza_estado = 'liquidada'
                   and c.expediente_cerrado_en is null
                   and coalesce(c.cobranza_liquidada_en, c.updated_at, now()) <= now() - interval '15 days') z where n > 0

        union all
        -- Ya se cobró y falta capturar los gastos y cerrar para saber la utilidad.
        select jsonb_build_object(
          'clave', 'expedientes', 'nivel', 'medio', 'pantalla', 'cotizaciones',
          'n', n,
          'texto', concat(n, case when n = 1 then ' cotización' else ' cotizaciones' end,
                          case when n = 1 then ' cobrada' else ' cobradas' end,
                          ' con el expediente por cerrar (faltan los gastos y la utilidad)'))
          from (select count(*) as n
                  from cotizaciones c
                 where c.estado = 'aceptada' and c.cobranza_estado = 'liquidada'
                   and c.expediente_cerrado_en is null
                   and coalesce(c.cobranza_liquidada_en, c.updated_at, now()) > now() - interval '15 days') z where n > 0
      ) w), '[]'::jsonb))
  end
$function$
;

CREATE OR REPLACE FUNCTION public.ligar_cfdi_cotizacion(p_cfdi uuid, p_cotizacion uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_c cfdi%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador liga facturas.' using errcode = '42501';
  end if;
  v_c := (select c from cfdi c where c.id = p_cfdi);
  if v_c.id is null then raise exception 'Ese CFDI no existe.' using errcode = '22023'; end if;
  if v_c.sentido <> 'emitido' then
    raise exception 'Solo las facturas que tú emites se ligan a una cotización.' using errcode = '22023';
  end if;
  if (select id from cotizaciones where id = p_cotizacion) is null then
    raise exception 'Esa cotización no existe.' using errcode = '22023';
  end if;
  update cfdi set cotizacion_id = p_cotizacion where id = p_cfdi;
  perform _apunta('cfdi', p_cfdi, 'ligar_cfdi_cotizacion',
                  jsonb_build_object('cotizacion_id', v_c.cotizacion_id),
                  jsonb_build_object('cotizacion_id', p_cotizacion), 'oficina');
  return jsonb_build_object('ok', true);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.liquidar_cobranza(p_cotizacion uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_c cotizaciones%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador liquida cobranzas.' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_motivo, ''))) < 3 then
    raise exception 'Escribe por qué se da por liquidada (por ejemplo, una retención o un descuento).' using errcode = '22023';
  end if;
  v_c := (select c from cotizaciones c where c.id = p_cotizacion);
  if v_c.id is null then
    raise exception 'Esa cotización ya no existe.' using errcode = '22023';
  end if;
  if v_c.expediente_cerrado_en is not null then
    raise exception 'Su expediente está cerrado: reábrelo antes de cambiar la cobranza.' using errcode = '22023';
  end if;
  if v_c.cobranza_manual and v_c.cobranza_estado = 'liquidada' then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;

  update cotizaciones
     set cobranza_estado = 'liquidada', cobranza_manual = true,
         cobranza_nota = trim(p_motivo), cobranza_liquidada_en = now()
   where id = p_cotizacion;
  perform _apunta('cotizaciones', p_cotizacion, 'cobranza_liquidada_a_mano',
                  jsonb_build_object('estado', v_c.cobranza_estado),
                  jsonb_build_object('motivo', trim(p_motivo)), 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false);
end;
$function$
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

CREATE OR REPLACE FUNCTION public.marcar_salida(p_id uuid, p_ok boolean, p_wa_message_id text DEFAULT NULL::text, p_error text DEFAULT NULL::text, p_temporal boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r salida_wa%rowtype; v_conv uuid;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el conector de WhatsApp o el administrador.' using errcode = '42501';
  end if;
  r := (select s from salida_wa s where s.id = p_id);
  if r.id is null or r.estado <> 'enviando' then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;

  if not p_ok then
    if p_temporal and r.intentos < 3 then
      update salida_wa set estado = 'pendiente', error = p_error,
             programado_para = now() + (r.intentos * interval '5 minutes') where id = p_id;
    else
      update salida_wa set estado = 'fallido', error = p_error where id = p_id;
    end if;
    return jsonb_build_object('ok', true);
  end if;

  update salida_wa set estado = 'enviado', wa_message_id = p_wa_message_id, enviado_en = now(), error = null
   where id = p_id;

  -- Queda en la conversación de ese número (se crea si no existía; el trigger de la 22 la liga).
  v_conv := coalesce(r.conversacion_id, (select id from conversaciones where telefono_norm = r.telefono_norm));
  if v_conv is null then
    v_conv := gen_random_uuid();
    insert into conversaciones (id, telefono, estado) values (v_conv, r.telefono, 'abierta');
  end if;
  insert into mensajes_wa (conversacion_id, direccion, tipo, texto, wa_message_id, estado, enviado_por, wa_timestamp)
  values (v_conv, 'saliente', case when r.documento_ruta is not null then 'documento' else 'texto' end,
          coalesce(r.texto, r.plantilla), p_wa_message_id, 'enviado', coalesce(r.aprobado_por, 'api'), now())
  on conflict do nothing;
  update conversaciones set ultimo_mensaje_at = now() where id = v_conv;

  if r.origen = 'aviso' then
    update avisos set estado = 'enviado', canal = 'whatsapp_api', enviado_at = now(), enviado_por = 'api',
           texto_enviado = 'Plantilla ' || r.plantilla || ': ' || coalesce(r.variables::text, '')
     where id = r.origen_id and estado = 'pendiente';
  end if;
  return jsonb_build_object('ok', true, 'conversacion_id', v_conv);
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

CREATE OR REPLACE FUNCTION public.mis_comisiones(p_dias integer DEFAULT 120)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_yo uuid := auth.uid();
  v_ordenes jsonb;
  v_ajustes jsonb;
  v_por_cobrar numeric;
  v_pagado_mes numeric;
  v_revision int;
  v_dias int := least(greatest(coalesce(p_dias, 120), 1), 400);
begin
  if v_yo is null or coalesce(mi_rol(), '') not in ('tecnico', 'admin') then
    return jsonb_build_object('ordenes', '[]'::jsonb, 'ajustes', '[]'::jsonb,
                              'resumen', jsonb_build_object('por_cobrar', 0, 'pagado_mes', 0, 'en_revision', 0));
  end if;

  v_ordenes := coalesce((
    select jsonb_agg(jsonb_build_object(
             'orden_id', m.orden_id, 'folio', m.folio, 'fecha', m.fecha,
             'tipo_servicio', m.tipo_servicio, 'rol', m.rol,
             'cliente', (select nombre from clientes where id = m.cliente_id),
             'estado', case x.pago_estado when 'pagado' then 'pagada' when 'aprobado' then 'aprobada' else 'en_revision' end,
             'monto', x.monto, 'pago_folio', x.folio, 'fecha_pago', x.fecha_pago)
           order by m.fecha desc, m.folio desc)
      from (
        select o.id as orden_id, o.folio, o.fecha, o.tipo_servicio, o.cliente_id, 'responsable'::text as rol
          from ordenes_servicio o
         where o.tecnico_id = v_yo and o.estado = 'cerrada' and o.fecha >= current_date - v_dias
        union all
        select o.id, o.folio, o.fecha, o.tipo_servicio, o.cliente_id, 'ayudante'
          from ordenes_servicio o
         where o.tecnico2_id = v_yo and o.estado = 'cerrada' and o.fecha >= current_date - v_dias
      ) m
      left join lateral (
        select l.monto, p.estado as pago_estado, p.folio, p.fecha_pago
          from pagos_tecnico_lineas l
          join pagos_tecnico p on p.id = l.pago_id
         where l.orden_id = m.orden_id and l.tecnico_id = v_yo and l.activa and l.clase = 'servicio'
           and p.estado in ('aprobado', 'pagado')
         order by p.created_at desc limit 1
      ) x on true), '[]'::jsonb);

  v_ajustes := coalesce((
    select jsonb_agg(jsonb_build_object(
             'concepto', l.concepto, 'monto', l.monto,
             'estado', case p.estado when 'pagado' then 'pagada' else 'aprobada' end,
             'pago_folio', p.folio, 'fecha_pago', p.fecha_pago) order by p.created_at desc)
      from pagos_tecnico_lineas l
      join pagos_tecnico p on p.id = l.pago_id
     where l.tecnico_id = v_yo and l.activa and l.clase = 'ajuste' and p.estado in ('aprobado', 'pagado')
       and p.created_at >= now() - make_interval(days => v_dias)), '[]'::jsonb);

  v_por_cobrar := coalesce((
    select sum(l.monto) from pagos_tecnico_lineas l join pagos_tecnico p on p.id = l.pago_id
     where l.tecnico_id = v_yo and l.activa and p.estado = 'aprobado'), 0);
  v_pagado_mes := coalesce((
    select sum(l.monto) from pagos_tecnico_lineas l join pagos_tecnico p on p.id = l.pago_id
     where l.tecnico_id = v_yo and l.activa and p.estado = 'pagado'
       and date_trunc('month', p.fecha_pago) = date_trunc('month', (now() at time zone 'America/Merida')::date)), 0);
  v_revision := (select count(*) from jsonb_array_elements(v_ordenes) e where e ->> 'estado' = 'en_revision');

  return jsonb_build_object(
    'resumen', jsonb_build_object('por_cobrar', v_por_cobrar, 'pagado_mes', v_pagado_mes, 'en_revision', v_revision),
    'ordenes', v_ordenes, 'ajustes', v_ajustes);
end;
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

CREATE OR REPLACE FUNCTION public.pedidos_por_recibir()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when not es_admin() then '[]'::jsonb else
    coalesce((
      select jsonb_agg(jsonb_build_object(
               'requisicion_id', r.id, 'folio', r.folio, 'estado', r.estado,
               'producto_id', p.id, 'sku', p.sku, 'nombre', p.nombre, 'unidad', p.unidad,
               'cantidad', r.cantidad, 'proveedor', r.proveedor,
               'costo_referencia', p.costo, 'fecha_pedido', r.fecha_pedido)
             order by r.fecha_pedido nulls last, r.folio)
        from requisiciones r join productos p on p.id = r.producto_id
       where r.estado in ('pendiente', 'pedida')), '[]'::jsonb)
  end
$function$
;

CREATE OR REPLACE FUNCTION public.pendientes_admin()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when not es_admin() then '{}'::jsonb else jsonb_strip_nulls(jsonb_build_object(

    -- La Agenda junta dos cosas porque las dos se atienden ahí: las citas sin fecha esperando
    -- confirmación (las que pide el agente de WhatsApp caen aquí) y los avisos ya redactados
    -- que nadie ha mandado. `avisos` no tiene pestaña propia: vive debajo de "Por programar".
    'agenda', nullif(
      (select count(*) from citas where estado = 'por_programar')
      + (select count(*) from avisos where estado = 'pendiente'), 0),

    -- Órdenes cerradas marcadas "enviar al cliente en cuanto se cierre" que todavía no se
    -- enviaron. La marca se apaga sola al registrar el envío (fase 4).
    'ordenes', nullif((
      select count(*) from ordenes_servicio o
       where o.estado = 'cerrada' and o.enviar_al_cerrar
         and not exists (select 1 from envios_orden e where e.orden_id = o.id)), 0),

    -- Solicitudes del formulario del sitio que nadie ha visto.
    'solicitudes', nullif((select count(*) from solicitudes_web where estado = 'nueva'), 0),

    -- Conversaciones de WhatsApp con mensajes sin leer.
    'whatsapp', nullif((
      select count(*) from conversaciones
       where sin_leer > 0 and coalesce(estado, 'abierta') <> 'cerrada'), 0),

    -- Borradores que propuso el agente y que el admin tiene que revisar antes de enviar.
    'cotizaciones', nullif((
      select count(*) from cotizaciones
       where estado = 'borrador' and origen = 'whatsapp'), 0),

    -- Lo del almacén, junto: lo que espera firma, lo que falta devolver, lo que el técnico
    -- pidió y lo que usó sin que se lo entregaran. Son cuatro pestañas de una misma pantalla,
    -- así que un solo número es lo que corresponde a la pestaña.
    'almacen', nullif((
      (select count(*) from entregas where estado = 'pendiente')
      + (select count(distinct s.orden_id) from orden_surtido s
          where s.cantidad_entregada - s.cantidad_usada
                - s.cantidad_devuelta - s.cantidad_diferencia > 0)
      + (select count(*) from solicitudes_material where estado = 'pendiente')
      + (select count(*) from ordenes_servicio o
          where exists (
            select 1 from jsonb_array_elements(coalesce(o.refacciones, '[]'::jsonb)) x
             where (x ->> 'adicional') = 'true'
               and coalesce(x ->> 'conciliada', 'false') <> 'true'))), 0),

    -- Pedidos a proveedor que todavía no se piden. Los ya `pedida` están en manos del
    -- proveedor: no son trabajo del admin y no se cuentan.
    'requisiciones', nullif((select count(*) from requisiciones where estado = 'pendiente'), 0)

  )) end
$function$
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

CREATE OR REPLACE FUNCTION public.por_pagar_tecnicos(p_hasta date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_res jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador ve los pagos a técnicos.' using errcode = '42501';
  end if;

  v_res := (
    with servicios as (
      select o.id as orden_id, o.fecha, o.tipo_servicio, o.tecnico_id as persona, 'responsable'::text as rol
        from ordenes_servicio o where o.estado = 'cerrada' and o.tecnico_id is not null and o.fecha <= p_hasta
      union all
      select o.id, o.fecha, o.tipo_servicio, o.tecnico2_id, 'ayudante'
        from ordenes_servicio o where o.estado = 'cerrada' and o.tecnico2_id is not null and o.fecha <= p_hasta
    ), pendientes as (
      select s.*, _tarifa_pago_tecnico(s.persona, s.tipo_servicio, s.rol, s.fecha) as tarifa
        from servicios s
       where not exists (select 1 from pagos_tecnico_lineas l
                          where l.orden_id = s.orden_id and l.tecnico_id = s.persona
                            and l.activa and l.clase = 'servicio')
    )
    select coalesce(jsonb_agg(jsonb_build_object(
             'tecnico_id', x.persona,
             'nombre', (select nombre from perfiles where id = x.persona),
             'ordenes', x.n,
             'estimado', x.estimado,
             'sin_tarifa', x.sin_tarifa,
             'mas_antigua', x.mas_antigua) order by x.mas_antigua), '[]'::jsonb)
      from (
        select persona, count(*) as n,
               coalesce(sum(tarifa), 0) as estimado,
               count(*) filter (where tarifa is null) as sin_tarifa,
               min(fecha) as mas_antigua
          from pendientes group by persona
      ) x
  );
  return v_res;
end;
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

CREATE OR REPLACE FUNCTION public.proponer_pago_tecnico(p_tecnico uuid, p_desde date, p_hasta date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_pago_id uuid;
  v_sin_tarifa jsonb := '[]'::jsonb;
  v_n int := 0;
  r record;
  v_monto numeric;
begin
  if not es_admin() then
    raise exception 'Solo el administrador propone pagos a técnicos.' using errcode = '42501';
  end if;
  if p_desde is null or p_hasta is null or p_hasta < p_desde then
    raise exception 'El periodo no es válido.' using errcode = '22023';
  end if;
  if (select id from perfiles where id = p_tecnico) is null then
    raise exception 'Ese técnico no existe.' using errcode = '22023';
  end if;

  insert into tecnicos_pago (perfil_id) values (p_tecnico) on conflict (perfil_id) do nothing;

  if (select count(*) from pagos_tecnico where tecnico_id = p_tecnico and estado = 'aprobado') > 0 then
    raise exception 'Ese técnico tiene un pago aprobado sin registrar. Regístralo o cancélalo antes de proponer otro.'
      using errcode = '22023';
  end if;

  v_pago_id := (select id from pagos_tecnico where tecnico_id = p_tecnico and estado = 'propuesto');
  if v_pago_id is null then
    v_pago_id := gen_random_uuid();
    insert into pagos_tecnico (id, tecnico_id, periodo_desde, periodo_hasta, creado_por)
    values (v_pago_id, p_tecnico, p_desde, p_hasta, coalesce(auth.jwt() ->> 'email', 'crm'));
  else
    delete from pagos_tecnico_lineas where pago_id = v_pago_id and clase = 'servicio';
    update pagos_tecnico set periodo_desde = p_desde, periodo_hasta = p_hasta where id = v_pago_id;
  end if;

  for r in
    select s.orden_id, s.fecha, s.tipo_servicio, s.rol, s.cotizacion_id
      from (
        select o.id as orden_id, o.fecha, o.tipo_servicio, 'responsable'::text as rol, o.tecnico_id as persona,
               (select c.cotizacion_id from citas c where c.id = o.cita_id) as cotizacion_id
          from ordenes_servicio o where o.estado = 'cerrada'
        union all
        select o.id, o.fecha, o.tipo_servicio, 'ayudante', o.tecnico2_id,
               (select c.cotizacion_id from citas c where c.id = o.cita_id)
          from ordenes_servicio o where o.estado = 'cerrada'
      ) s
     where s.persona = p_tecnico
       and s.fecha between p_desde and p_hasta
       and not exists (select 1 from pagos_tecnico_lineas l
                        where l.orden_id = s.orden_id and l.tecnico_id = p_tecnico
                          and l.activa and l.clase = 'servicio')
     order by s.fecha, s.orden_id
  loop
    v_monto := _tarifa_pago_tecnico(p_tecnico, r.tipo_servicio, r.rol, r.fecha);
    if v_monto is null then
      v_sin_tarifa := v_sin_tarifa || jsonb_build_array(jsonb_build_object(
        'orden_id', r.orden_id, 'fecha', r.fecha, 'tipo_servicio', r.tipo_servicio, 'rol', r.rol));
    else
      insert into pagos_tecnico_lineas (pago_id, tecnico_id, clase, orden_id, cotizacion_id, tipo_servicio, rol, monto)
      values (v_pago_id, p_tecnico, 'servicio', r.orden_id, r.cotizacion_id, r.tipo_servicio, r.rol, v_monto);
      v_n := v_n + 1;
    end if;
  end loop;

  perform _recalcular_pago_tecnico(v_pago_id);
  perform _apunta('pagos_tecnico', v_pago_id, 'proponer_pago_tecnico', null,
                  jsonb_build_object('tecnico_id', p_tecnico, 'desde', p_desde, 'hasta', p_hasta,
                                     'servicios', v_n, 'sin_tarifa', jsonb_array_length(v_sin_tarifa)), 'oficina');

  return jsonb_build_object('ok', true, 'pago_id', v_pago_id, 'servicios', v_n,
                            'total', (select total from pagos_tecnico where id = v_pago_id),
                            'sin_tarifa', v_sin_tarifa);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.proponer_tanda(p_mes text, p_n integer DEFAULT 37)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tanda uuid; v_num int; r record; v_n int := 0; v_omit int := 0; v_motivo text;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if exists (select 1 from campana_tandas where mes = p_mes and estado = 'propuesta') then
    raise exception 'Ya hay una tanda propuesta de % sin aprobar: apruébala o cancélala primero.', p_mes using errcode = '22023';
  end if;
  v_num := coalesce((select max(numero) from campana_tandas where mes = p_mes), 0) + 1;
  v_tanda := gen_random_uuid();
  insert into campana_tandas (id, mes, numero, propuesta_por) values (v_tanda, p_mes, v_num, coalesce(auth.jwt() ->> 'email', 'crm'));

  for r in select * from campana_envios
            where mes = p_mes and estado = 'propuesto'
            order by coalesce(orden, 999999), created_at loop
    exit when v_n >= greatest(1, least(p_n, 250));
    v_motivo := case
      when r.telefono_norm is null then 'teléfono inválido'
      when exists (select 1 from wa_bajas b where b.telefono_norm = r.telefono_norm) then 'pidió BAJA'
      when _marketing_reciente(r.telefono_norm) then 'ya recibió marketing hace poco'
      when r.plantilla is null then 'sin plantilla asignada'
      else null end;
    if v_motivo is not null then
      update campana_envios set estado = 'omitido', motivo = v_motivo where id = r.id;
      v_omit := v_omit + 1;
      continue;
    end if;
    update campana_envios set estado = 'en_tanda', tanda_id = v_tanda where id = r.id;
    v_n := v_n + 1;
  end loop;

  if v_n = 0 then
    delete from campana_tandas where id = v_tanda;
    return jsonb_build_object('ok', true, 'vacia', true, 'omitidos', v_omit);
  end if;
  return jsonb_build_object('ok', true, 'tanda_id', v_tanda, 'numero', v_num, 'en_tanda', v_n, 'omitidos', v_omit);
end $function$
;

CREATE OR REPLACE FUNCTION public.proveedor_resumen(p_proveedor text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_prov text := lower(trim(p_proveedor));
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'por_traer', coalesce((
      select jsonb_agg(t.x order by t.x ->> 'categoria')
        from (
          select jsonb_build_object(
                   'categoria', pp.categoria,
                   'total', count(*),
                   'por_traer', count(*) filter (where not exists (
                       select 1 from producto_proveedores l
                        where l.proveedor = pp.proveedor and l.proveedor_sku = pp.sku_proveedor)
                     and not exists (
                       select 1 from productos p where p.sku = _sku_crm(pp.proveedor, pp.sku_proveedor))),
                   'equivale', _categoria_crm(pp.categoria) is not null) as x
            from proveedor_productos pp
           where pp.proveedor = v_prov and pp.vigente
           group by pp.categoria
        ) t), '[]'::jsonb),
    'vinculados', coalesce((
      select jsonb_agg(t.x order by t.x ->> 'categoria')
        from (
          select jsonb_build_object(
                   'categoria', p.categoria,
                   'total', count(*),
                   'con_auto', count(*) filter (where p.precio_auto)) as x
            from productos p
           where p.activo and exists (select 1 from producto_proveedores l
                                       where l.producto_id = p.id and l.proveedor = v_prov)
           group by p.categoria
        ) t), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.quitar_baja(p_telefono text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  delete from wa_bajas where telefono_norm = normalizar_telefono(p_telefono);
  return jsonb_build_object('ok', true, 'quitada', found);
end $function$
;

CREATE OR REPLACE FUNCTION public.quitar_de_tanda(p_ids uuid[], p_omitir boolean DEFAULT false, p_motivo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  update campana_envios
     set estado = case when p_omitir then 'omitido' else 'propuesto' end,
         motivo = case when p_omitir then coalesce(nullif(trim(p_motivo), ''), 'quitado por la oficina') end,
         tanda_id = null
   where id = any(p_ids) and estado = 'en_tanda';
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.quitar_linea_pago_tecnico(p_linea uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_l pagos_tecnico_lineas%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador cambia pagos a técnicos.' using errcode = '42501';
  end if;
  v_l := (select l from pagos_tecnico_lineas l where l.id = p_linea);
  if v_l.id is null then raise exception 'Esa línea no existe.' using errcode = '22023'; end if;
  if (select estado from pagos_tecnico where id = v_l.pago_id) <> 'propuesto' then
    raise exception 'Solo se quitan líneas de un pago en borrador.' using errcode = '22023';
  end if;
  delete from pagos_tecnico_lineas where id = p_linea;
  perform _recalcular_pago_tecnico(v_l.pago_id);
  return jsonb_build_object('ok', true, 'total', (select total from pagos_tecnico where id = v_l.pago_id));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.quitar_producto(p_producto uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_prod productos%rowtype;
  v_usos int;
begin
  if not es_admin() then
    raise exception 'Solo el administrador puede quitar artículos.' using errcode = '42501';
  end if;

  v_prod := (select p from productos p where p.id = p_producto);
  if v_prod.id is null then
    raise exception 'Ese artículo ya no existe.' using errcode = '22023';
  end if;

  v_usos :=
      (select count(*) from movimientos_inventario where producto_id = p_producto)
    + (select count(*) from entrega_lineas         where producto_id = p_producto)
    + (select count(*) from orden_surtido          where producto_id = p_producto)
    + (select count(*) from paquete_lineas         where producto_id = p_producto)
    + (select count(*) from requisiciones          where producto_id = p_producto)
    + (select count(*) from solicitudes_material   where producto_id = p_producto)
    + (select count(*) from compra_lineas          where producto_id = p_producto);

  if v_usos = 0 then
    delete from productos where id = p_producto;
    perform _apunta('productos', p_producto, 'eliminar',
                    jsonb_build_object('sku', v_prod.sku, 'nombre', v_prod.nombre),
                    null, 'oficina');
    return 'eliminado';
  end if;

  if not coalesce(v_prod.activo, true) then
    return 'sin_cambio';
  end if;

  update productos set activo = false, publicar = false where id = p_producto;
  perform _apunta('productos', p_producto, 'desactivar',
                  jsonb_build_object('activo', true, 'publicar', v_prod.publicar),
                  jsonb_build_object('activo', false, 'publicar', false), 'oficina');
  return 'desactivado';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.reabrir_cobranza(p_cotizacion uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_c cotizaciones%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador reabre cobranzas.' using errcode = '42501';
  end if;
  v_c := (select c from cotizaciones c where c.id = p_cotizacion);
  if v_c.id is null then
    raise exception 'Esa cotización ya no existe.' using errcode = '22023';
  end if;
  if v_c.expediente_cerrado_en is not null then
    raise exception 'Su expediente está cerrado: reábrelo antes de cambiar la cobranza.' using errcode = '22023';
  end if;
  if not v_c.cobranza_manual then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;

  -- Se suelta la decisión manual y se vuelve a calcular con lo que de verdad hay.
  update cotizaciones set cobranza_manual = false, cobranza_nota = null where id = p_cotizacion;
  perform _recalcular_cobranza(p_cotizacion);
  -- Si el cálculo coincide con el estado de antes, `_recalcular_cobranza` no toca nada: la fecha de
  -- liquidación sale solo si de verdad queda liquidada.
  update cotizaciones
     set cobranza_liquidada_en = null
   where id = p_cotizacion and cobranza_estado <> 'liquidada';
  perform _apunta('cotizaciones', p_cotizacion, 'cobranza_reabierta',
                  jsonb_build_object('nota', v_c.cobranza_nota), null, 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.reabrir_expediente(p_cotizacion uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_c cotizaciones%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador reabre expedientes.' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_motivo, ''))) < 3 then
    raise exception 'Escribe por qué se reabre el expediente.' using errcode = '22023';
  end if;
  v_c := (select c from cotizaciones c where c.id = p_cotizacion);
  if v_c.id is null then
    raise exception 'Esa cotización ya no existe.' using errcode = '22023';
  end if;
  if v_c.expediente_cerrado_en is null then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;
  perform _apunta('cotizaciones', p_cotizacion, 'reabrir_expediente',
                  jsonb_build_object('cerrado_en', v_c.expediente_cerrado_en,
                                     'utilidad', v_c.expediente_cierre -> 'utilidad'),
                  jsonb_build_object('motivo', trim(p_motivo)), 'oficina');
  update cotizaciones
     set expediente_cerrado_en = null, expediente_cerrado_por = null, expediente_cierre = null
   where id = p_cotizacion;
  return jsonb_build_object('ok', true, 'sin_cambio', false);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.rechazar_documento(p_documento uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_estado text;
begin
  if not es_admin() then
    raise exception 'Solo el administrador rechaza documentos.' using errcode = '42501';
  end if;
  v_estado := (select estado from documentos where id = p_documento);
  if v_estado is null then raise exception 'Ese documento no existe.' using errcode = '22023'; end if;
  if v_estado = 'rechazado' then return jsonb_build_object('ok', true, 'sin_cambio', true); end if;
  if v_estado = 'aprobado' then
    raise exception 'Ese documento ya se aprobó; corrígelo desde el libro.' using errcode = '22023';
  end if;
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Escribe por qué se rechaza.' using errcode = '22023';
  end if;
  update documentos set estado = 'rechazado', motivo_rechazo = trim(p_motivo) where id = p_documento;
  perform _apunta('documentos', p_documento, 'rechazar_documento', null,
                  jsonb_build_object('motivo', trim(p_motivo)), 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false);
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

CREATE OR REPLACE FUNCTION public.registrar_baja(p_telefono text, p_origen text DEFAULT 'whatsapp'::text, p_nota text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_norm text := normalizar_telefono(p_telefono);
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el conector de WhatsApp o el administrador.' using errcode = '42501';
  end if;
  if v_norm is null then
    raise exception 'El teléfono no trae 10 dígitos.' using errcode = '22023';
  end if;
  insert into wa_bajas (telefono_norm, origen, nota) values (v_norm, coalesce(p_origen, 'whatsapp'), p_nota)
  on conflict (telefono_norm) do nothing;
  update salida_wa set estado = 'cancelado', error = 'el número pidió BAJA'
   where telefono_norm = v_norm and categoria = 'marketing' and estado in ('por_aprobar', 'pendiente');
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.registrar_cfdi(p_datos jsonb, p_archivo text DEFAULT NULL::text, p_documento uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_rfc text;
  v_uuid text;
  v_emisor text;
  v_receptor text;
  v_sentido text;
  v_id uuid;
  v_existente uuid;
  v_cliente uuid;
  v_compra uuid;
begin
  if not es_admin() then
    raise exception 'Solo el administrador registra CFDI.' using errcode = '42501';
  end if;
  v_rfc := upper(trim(coalesce((select rfc from empresa_fiscal where id), '')));
  if v_rfc = '' then
    raise exception 'Primero captura tu RFC en Finanzas → Mi RFC.' using errcode = '22023';
  end if;

  v_uuid := lower(trim(coalesce(p_datos ->> 'uuid_fiscal', '')));
  v_emisor := upper(trim(coalesce(p_datos ->> 'rfc_emisor', '')));
  v_receptor := upper(trim(coalesce(p_datos ->> 'rfc_receptor', '')));
  if v_uuid = '' or v_emisor = '' or v_receptor = '' then
    raise exception 'El XML no trae UUID o RFC: no parece un CFDI timbrado.' using errcode = '22023';
  end if;

  v_sentido := case when v_emisor = v_rfc then 'emitido'
                    when v_receptor = v_rfc then 'recibido'
                    else null end;
  if v_sentido is null then
    raise exception 'Este CFDI no es de tu RFC (%): ni lo emitiste ni lo recibiste.', v_rfc using errcode = '22023';
  end if;

  v_existente := (select id from cfdi where uuid_fiscal = v_uuid);
  if v_existente is not null then
    if p_documento is not null then
      update documentos set cfdi_id = v_existente, estado = 'propuesto' where id = p_documento and estado = 'pendiente';
    end if;
    return jsonb_build_object('ok', true, 'duplicado', true, 'cfdi_id', v_existente,
                              'sentido', (select sentido from cfdi where id = v_existente));
  end if;

  if v_sentido = 'emitido' then
    v_cliente := (select d.cliente_id from datos_fiscales d
                   where upper(trim(d.rfc)) = v_receptor and coalesce(d.activo, true) limit 1);
  else
    v_compra := (select c.id from compras c where lower(trim(coalesce(c.uuid_fiscal, ''))) = v_uuid limit 1);
  end if;

  v_id := gen_random_uuid();
  insert into cfdi (id, uuid_fiscal, sentido, tipo_comprobante, serie, folio, fecha,
                    rfc_emisor, nombre_emisor, regimen_emisor, rfc_receptor, nombre_receptor, uso_cfdi,
                    subtotal, descuento, total, iva_trasladado, isr_retenido, iva_retenido,
                    moneda, tipo_cambio, metodo_pago, forma_pago, lugar_expedicion,
                    conceptos, relacionados, archivo_xml, cliente_id, compra_id, documento_id, creado_por)
  values (v_id, v_uuid, v_sentido, coalesce(nullif(p_datos ->> 'tipo_comprobante', ''), 'I'),
          nullif(p_datos ->> 'serie', ''), nullif(p_datos ->> 'folio', ''), (p_datos ->> 'fecha')::timestamptz,
          v_emisor, nullif(p_datos ->> 'nombre_emisor', ''), nullif(p_datos ->> 'regimen_emisor', ''),
          v_receptor, nullif(p_datos ->> 'nombre_receptor', ''), nullif(p_datos ->> 'uso_cfdi', ''),
          coalesce((p_datos ->> 'subtotal')::numeric, 0), coalesce((p_datos ->> 'descuento')::numeric, 0),
          coalesce((p_datos ->> 'total')::numeric, 0), coalesce((p_datos ->> 'iva_trasladado')::numeric, 0),
          coalesce((p_datos ->> 'isr_retenido')::numeric, 0), coalesce((p_datos ->> 'iva_retenido')::numeric, 0),
          coalesce(nullif(p_datos ->> 'moneda', ''), 'MXN'), (nullif(p_datos ->> 'tipo_cambio', ''))::numeric,
          nullif(p_datos ->> 'metodo_pago', ''), nullif(p_datos ->> 'forma_pago', ''),
          nullif(p_datos ->> 'lugar_expedicion', ''),
          coalesce(p_datos -> 'conceptos', '[]'::jsonb), coalesce(p_datos -> 'relacionados', '[]'::jsonb),
          p_archivo, v_cliente, v_compra, p_documento, coalesce(auth.jwt() ->> 'email', 'crm'));

  if p_documento is not null then
    update documentos set cfdi_id = v_id, estado = 'propuesto', tipo = 'cfdi_xml', metodo = 'xml'
     where id = p_documento and estado = 'pendiente';
  end if;
  perform _apunta('cfdi', v_id, 'registrar_cfdi', null,
                  jsonb_build_object('uuid', v_uuid, 'sentido', v_sentido, 'total', p_datos ->> 'total'), 'oficina');
  return jsonb_build_object('ok', true, 'duplicado', false, 'cfdi_id', v_id, 'sentido', v_sentido);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.registrar_compra(p_datos jsonb, p_lineas jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_compra   uuid;
  v_folio    bigint;
  v_linea    jsonb;
  v_req      requisiciones%rowtype;
  v_mov      uuid;
  v_subtotal numeric := 0;
  v_iva      numeric;
  v_entradas int := 0;
  v_ligadas  int := 0;
  v_prod     productos%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador registra compras.' using errcode = '42501';
  end if;
  if coalesce(trim(p_datos ->> 'proveedor'), '') = '' then
    raise exception 'Escribe de quién se compró.' using errcode = '22023';
  end if;
  if jsonb_typeof(p_lineas) <> 'array' or jsonb_array_length(p_lineas) = 0 then
    raise exception 'Una compra necesita al menos una pieza.' using errcode = '22023';
  end if;

  insert into compras (proveedor, factura, uuid_fiscal, fecha, moneda, notas,
                       archivo_xml, archivo_pdf, creada_por)
  values (trim(p_datos ->> 'proveedor'),
          nullif(trim(coalesce(p_datos ->> 'factura', '')), ''),
          nullif(trim(coalesce(p_datos ->> 'uuid_fiscal', '')), ''),
          coalesce((p_datos ->> 'fecha')::date, current_date),
          coalesce(nullif(p_datos ->> 'moneda', ''), 'MXN'),
          nullif(trim(coalesce(p_datos ->> 'notas', '')), ''),
          nullif(trim(coalesce(p_datos ->> 'archivo_xml', '')), ''),
          nullif(trim(coalesce(p_datos ->> 'archivo_pdf', '')), ''),
          coalesce(auth.jwt() ->> 'email', 'crm'))
  returning id, folio into v_compra, v_folio;

  for v_linea in select * from jsonb_array_elements(p_lineas) loop
    v_prod := (select p from productos p where p.id = (v_linea ->> 'producto_id')::uuid);
    if v_prod.id is null then
      raise exception 'Una de las piezas no existe en el catálogo.' using errcode = 'P0002';
    end if;
    if coalesce((v_linea ->> 'cantidad')::numeric, 0) <= 0 then
      raise exception 'La cantidad de % tiene que ser mayor que cero.', v_prod.sku
        using errcode = '22023';
    end if;

    v_mov := null;
    v_req := null;

    if nullif(v_linea ->> 'requisicion_id', '') is not null then
      v_req := (select r from requisiciones r where r.id = (v_linea ->> 'requisicion_id')::uuid);
      if v_req.id is null then
        raise exception 'El pedido ligado a % ya no existe.', v_prod.sku using errcode = 'P0002';
      end if;
      if v_req.producto_id <> v_prod.id then
        raise exception 'El pedido ligado a % es de otra pieza.', v_prod.sku using errcode = '22023';
      end if;
    end if;

    -- El inventario solo se mueve si NADIE lo movió ya por esa requisición. Un pedido que ya
    -- está `recibida` metió su entrada `REQ-n` cuando llegó el material; la factura llega
    -- después y aquí solo aporta el costo y el respaldo.
    if v_req.id is not null and v_req.estado = 'recibida' then
      v_ligadas := v_ligadas + 1;
    else
      insert into movimientos_inventario
        (producto_id, tipo, cantidad, referencia, notas, usuario)
      values (v_prod.id, 'entrada', (v_linea ->> 'cantidad')::numeric,
              'COMPRA-' || v_folio,
              concat('Compra a ', trim(p_datos ->> 'proveedor'),
                     coalesce(' · factura ' || nullif(trim(coalesce(p_datos ->> 'factura', '')), ''), '')),
              coalesce(auth.jwt() ->> 'email', 'crm'))
      returning id into v_mov;
      v_entradas := v_entradas + 1;

      -- Si venía de un pedido, queda recibido por esta compra.
      if v_req.id is not null and v_req.estado not in ('cancelada') then
        update requisiciones
           set estado = 'recibida',
               fecha_recibida = current_date,
               movimiento_id = v_mov,
               proveedor = coalesce(proveedor, trim(p_datos ->> 'proveedor')),
               updated_at = now()
         where id = v_req.id;
      end if;
    end if;

    insert into compra_lineas
      (compra_id, producto_id, requisicion_id, cantidad, costo_unitario, importe, movimiento_id)
    values (v_compra, v_prod.id, v_req.id,
            (v_linea ->> 'cantidad')::numeric,
            coalesce((v_linea ->> 'costo_unitario')::numeric, 0),
            round((v_linea ->> 'cantidad')::numeric * coalesce((v_linea ->> 'costo_unitario')::numeric, 0), 2),
            v_mov);

    v_subtotal := v_subtotal + round((v_linea ->> 'cantidad')::numeric
                                     * coalesce((v_linea ->> 'costo_unitario')::numeric, 0), 2);

    -- El costo del catálogo se toca solo si la línea lo pide.
    if coalesce((v_linea ->> 'actualizar_costo')::boolean, false) then
      update productos set costo = coalesce((v_linea ->> 'costo_unitario')::numeric, 0)
       where id = v_prod.id;
      perform _apunta('productos', v_prod.id, 'costo_por_compra',
                      jsonb_build_object('costo', v_prod.costo),
                      jsonb_build_object('costo', (v_linea ->> 'costo_unitario')::numeric,
                                         'compra', v_folio), 'oficina');
    end if;
  end loop;

  v_iva := coalesce((p_datos ->> 'iva')::numeric, round(v_subtotal * 0.16, 2));

  update compras
     set subtotal = v_subtotal, iva = v_iva, total = v_subtotal + v_iva, updated_at = now()
   where id = v_compra;

  perform _apunta('compras', v_compra, 'registrar', null,
                  jsonb_build_object('folio', v_folio, 'proveedor', trim(p_datos ->> 'proveedor'),
                                     'total', v_subtotal + v_iva), 'oficina');

  return jsonb_build_object(
    'ok', true, 'id', v_compra, 'folio', v_folio,
    'subtotal', v_subtotal, 'iva', v_iva, 'total', v_subtotal + v_iva,
    'entradas', v_entradas,
    'ya_recibidas', v_ligadas,
    'aviso', case when v_ligadas > 0
                  then concat(v_ligadas, ' pieza(s) ya habían entrado al inventario por su pedido: ',
                              'solo se les guardó el costo y la factura.')
             end);
end $function$
;

CREATE OR REPLACE FUNCTION public.registrar_compra_de_factura(p_datos jsonb, p_lineas jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_linea jsonb;
  v_lineas jsonb := '[]'::jsonb;
  v_nuevo jsonb;
  v_prod uuid;
  v_prov text;
  v_codigo text;
  v_sku text;
  v_creados int := 0;
  v_codigos int := 0;
  v_actualizar boolean;
  v_res jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador registra compras.' using errcode = '42501';
  end if;
  v_prov := trim(coalesce(p_datos ->> 'proveedor', ''));
  if v_prov = '' then
    raise exception 'Escribe de quién se compró.' using errcode = '22023';
  end if;
  if jsonb_typeof(p_lineas) <> 'array' or jsonb_array_length(p_lineas) = 0 then
    raise exception 'Una compra necesita al menos una pieza.' using errcode = '22023';
  end if;

  for v_linea in select * from jsonb_array_elements(p_lineas) loop
    v_prod := nullif(v_linea ->> 'producto_id', '')::uuid;
    v_codigo := nullif(trim(coalesce(v_linea ->> 'codigo', '')), '');
    v_nuevo := v_linea -> 'nuevo';
    v_actualizar := coalesce((v_linea ->> 'actualizar_costo')::boolean, false);

    if v_prod is null then
      if v_nuevo is null or jsonb_typeof(v_nuevo) <> 'object' then
        raise exception 'Una línea no trae pieza del catálogo ni datos de una pieza nueva.' using errcode = '22023';
      end if;
      v_sku := upper(trim(coalesce(v_nuevo ->> 'sku', '')));
      if v_sku = '' then
        raise exception 'Una pieza nueva necesita su SKU.' using errcode = '22023';
      end if;
      if trim(coalesce(v_nuevo ->> 'nombre', '')) = '' then
        raise exception 'La pieza nueva % necesita su nombre.', v_sku using errcode = '22023';
      end if;
      if trim(coalesce(v_nuevo ->> 'categoria', '')) = '' then
        raise exception 'La pieza nueva % necesita su categoría.', v_sku using errcode = '22023';
      end if;
      if exists (select 1 from productos where upper(sku) = v_sku) then
        raise exception 'Ya existe un producto con el SKU %. Elígelo de la lista o cámbiale el SKU a la pieza nueva.', v_sku
          using errcode = '22023';
      end if;
      v_prod := gen_random_uuid();
      insert into productos (id, sku, nombre, categoria, unidad, activo, publicar, proveedor, proveedor_sku)
      values (v_prod, v_sku, trim(v_nuevo ->> 'nombre'), trim(v_nuevo ->> 'categoria'),
              coalesce(nullif(trim(coalesce(v_nuevo ->> 'unidad', '')), ''), 'pieza'),
              true, false, v_prov, v_codigo);
      v_creados := v_creados + 1;
      -- Una pieza nueva no tiene costo de referencia: el de la factura es el primero.
      v_actualizar := true;
    elsif v_codigo is not null then
      -- El código que este proveedor le da a esta pieza. Si ya estaba (o ese código ya sigue a
      -- otra pieza), no se toca: la llave única del código lo impide.
      insert into producto_proveedores (producto_id, proveedor, proveedor_sku)
      values (v_prod, v_prov, v_codigo)
      on conflict do nothing;
    end if;

    if v_codigo is not null
       and exists (select 1 from producto_proveedores
                    where producto_id = v_prod and proveedor = v_prov and proveedor_sku = v_codigo) then
      v_codigos := v_codigos + 1;
    end if;

    v_lineas := v_lineas || jsonb_build_array(jsonb_build_object(
      'producto_id', v_prod,
      'cantidad', v_linea -> 'cantidad',
      'costo_unitario', v_linea -> 'costo_unitario',
      'actualizar_costo', v_actualizar));
  end loop;

  v_res := registrar_compra(p_datos, v_lineas);
  return v_res || jsonb_build_object('productos_nuevos', v_creados, 'codigos_guardados', v_codigos);
end $function$
;

CREATE OR REPLACE FUNCTION public.registrar_documento(p_tipo text, p_archivo text, p_nombre text, p_mime text, p_hash text, p_metodo text DEFAULT 'manual'::text, p_extraido jsonb DEFAULT NULL::jsonb, p_validaciones jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id uuid;
begin
  if not es_admin() then
    raise exception 'Solo el administrador sube documentos.' using errcode = '42501';
  end if;
  if coalesce(p_hash, '') !~ '^[0-9a-f]{64}$' then
    raise exception 'El archivo no trae una huella válida.' using errcode = '22023';
  end if;
  v_id := (select id from documentos where hash_sha256 = p_hash);
  if v_id is not null then
    return jsonb_build_object('ok', true, 'duplicado', true, 'documento_id', v_id,
                              'estado', (select estado from documentos where id = v_id));
  end if;
  v_id := gen_random_uuid();
  insert into documentos (id, tipo, archivo, nombre_original, mime, hash_sha256, metodo, extraido, validaciones, subido_por)
  values (v_id, coalesce(p_tipo, 'otro'), p_archivo, p_nombre, p_mime, p_hash,
          coalesce(p_metodo, 'manual'), p_extraido, coalesce(p_validaciones, '[]'::jsonb),
          coalesce(auth.jwt() ->> 'email', 'crm'));
  return jsonb_build_object('ok', true, 'duplicado', false, 'documento_id', v_id, 'estado', 'pendiente');
end;
$function$
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

CREATE OR REPLACE FUNCTION public.registrar_estado_wa(p_wa_message_id text, p_estado text, p_error text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_orden text[] := array['enviado', 'entregado', 'leido'];
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el conector de WhatsApp o el administrador.' using errcode = '42501';
  end if;
  p_estado := case p_estado when 'sent' then 'enviado' when 'delivered' then 'entregado'
                            when 'read' then 'leido' when 'failed' then 'fallido' else p_estado end;
  if p_estado not in ('enviado', 'entregado', 'leido', 'fallido') then
    return jsonb_build_object('ok', true, 'ignorado', true);
  end if;
  update salida_wa set estado = p_estado, error = coalesce(p_error, error)
   where wa_message_id = p_wa_message_id
     and (p_estado = 'fallido' or array_position(v_orden, p_estado) > coalesce(array_position(v_orden, estado), 0));
  update mensajes_wa set estado = p_estado where wa_message_id = p_wa_message_id;
  return jsonb_build_object('ok', true);
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

CREATE OR REPLACE FUNCTION public.registrar_pago_tecnico(p_pago uuid, p_forma text, p_referencia text DEFAULT NULL::text, p_fecha date DEFAULT NULL::date, p_archivo text DEFAULT NULL::text, p_cuenta uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_p pagos_tecnico%rowtype;
  v_nombre text;
  r record;
  v_sin_cot numeric;
  v_n_sin_cot int;
  v_cargados int := 0;
  v_ref text;
begin
  if not es_admin() then
    raise exception 'Solo el administrador registra pagos a técnicos.' using errcode = '42501';
  end if;
  v_p := (select p from pagos_tecnico p where p.id = p_pago);
  if v_p.id is null then raise exception 'Ese pago no existe.' using errcode = '22023'; end if;
  if v_p.estado = 'pagado' then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;
  if v_p.estado <> 'aprobado' then
    raise exception 'Primero aprueba el pago (está %).', v_p.estado using errcode = '22023';
  end if;
  if p_forma is null or p_forma not in ('transferencia', 'efectivo', 'otro') then
    raise exception 'Indica la forma de pago: transferencia, efectivo u otro.' using errcode = '22023';
  end if;
  if p_cuenta is not null and (select id from cuentas_financieras where id = p_cuenta) is null then
    raise exception 'Esa cuenta no existe.' using errcode = '22023';
  end if;

  v_nombre := (select nombre from perfiles where id = v_p.tecnico_id);
  v_ref := coalesce(nullif(trim(p_referencia), ''), 'PAGO-' || v_p.folio);

  for r in
    select l.cotizacion_id, sum(l.monto) as monto, count(*) as n
      from pagos_tecnico_lineas l
     where l.pago_id = p_pago and l.activa and l.clase = 'servicio' and l.cotizacion_id is not null
     group by l.cotizacion_id
  loop
    if r.monto > 0 then
      insert into expediente_movimientos
        (cotizacion_id, tipo, categoria, fecha, concepto, monto, forma, referencia, tecnico_id,
         cuenta_id, archivo, notas, creado_por)
      values
        (r.cotizacion_id, 'egreso', 'tecnico', coalesce(p_fecha, current_date),
         format('Pago a %s por %s servicio(s)', coalesce(v_nombre, 'técnico'), r.n),
         r.monto, p_forma, v_ref, v_p.tecnico_id, p_cuenta, p_archivo,
         format('Pago a técnicos PAGO-%s', v_p.folio), coalesce(auth.jwt() ->> 'email', 'crm'));
      v_cargados := v_cargados + 1;
    end if;
  end loop;

  v_sin_cot := coalesce((select sum(monto) from pagos_tecnico_lineas
                          where pago_id = p_pago and activa and cotizacion_id is null), 0);
  v_n_sin_cot := (select count(*) from pagos_tecnico_lineas
                   where pago_id = p_pago and activa and cotizacion_id is null);
  if v_sin_cot > 0 then
    insert into expediente_movimientos
      (cotizacion_id, tipo, categoria, fecha, concepto, monto, forma, referencia, tecnico_id,
       cuenta_id, archivo, notas, creado_por)
    values
      (null, 'egreso', 'tecnico', coalesce(p_fecha, current_date),
       format('Pago a %s (%s concepto(s) sin cotización)', coalesce(v_nombre, 'técnico'), v_n_sin_cot),
       v_sin_cot, p_forma, v_ref, v_p.tecnico_id, p_cuenta, p_archivo,
       format('Pago a técnicos PAGO-%s', v_p.folio), coalesce(auth.jwt() ->> 'email', 'crm'));
    v_cargados := v_cargados + 1;
  end if;

  update pagos_tecnico
     set estado = 'pagado', forma = p_forma, referencia = nullif(trim(p_referencia), ''),
         fecha_pago = coalesce(p_fecha, current_date), archivo = p_archivo,
         pagado_en = now(), pagado_por = coalesce(auth.jwt() ->> 'email', 'crm')
   where id = p_pago;
  perform _apunta('pagos_tecnico', p_pago, 'registrar_pago_tecnico', null,
                  jsonb_build_object('total', v_p.total, 'forma', p_forma, 'movimientos', v_cargados), 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false, 'expedientes_cargados', v_cargados);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.registrar_solicitud_web(p_nombre text, p_telefono text, p_email text DEFAULT NULL::text, p_ubicacion text DEFAULT NULL::text, p_tipos text DEFAULT NULL::text, p_uso text DEFAULT NULL::text, p_equipo_actual text DEFAULT NULL::text, p_consumo text DEFAULT NULL::text, p_presupuesto text DEFAULT NULL::text, p_plazo text DEFAULT NULL::text, p_fuente text DEFAULT NULL::text, p_notas text DEFAULT NULL::text, p_origen_url text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_nombre text := left(trim(coalesce(p_nombre, '')), 120);
  v_norm text := normalizar_telefono(p_telefono);
  v_tipos text := nullif(left(trim(coalesce(p_tipos, '')), 200), '');
  v_notas text := nullif(left(trim(coalesce(p_notas, '')), 2000), '');
  v_n int;
  v_id uuid;
  v_cliente uuid;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector del sitio.' using errcode = '42501';
  end if;
  if length(v_nombre) < 2 then
    raise exception 'Escribe tu nombre.' using errcode = '22023';
  end if;
  if v_norm is null then
    raise exception 'El WhatsApp debe tener 10 dígitos.' using errcode = '22023';
  end if;
  if p_email is not null and length(trim(p_email)) > 0
     and trim(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'El correo no parece válido.' using errcode = '22023';
  end if;

  -- Topes contra abuso: por hora en todo el sitio, y por día para un mismo número.
  v_n := (select count(*) from solicitudes_web where created_at > now() - interval '1 hour');
  if v_n >= 60 then
    raise exception 'Hay muchas solicitudes en este momento.' using errcode = '54000';
  end if;
  v_n := (select count(*) from solicitudes_web
           where telefono_norm = v_norm and created_at > now() - interval '1 day');
  if v_n >= 5 then
    raise exception 'Ya recibimos varias solicitudes de este número hoy.' using errcode = '54000';
  end if;

  -- Un doble clic o un reintento: mismo número y mismo contenido en 10 minutos.
  v_id := (select s.id from solicitudes_web s
            where s.telefono_norm = v_norm
              and s.created_at > now() - interval '10 minutes'
              and coalesce(s.tipos, '') = coalesce(v_tipos, '')
              and coalesce(s.notas, '') = coalesce(v_notas, '')
            limit 1);
  if v_id is not null then
    return jsonb_build_object('ok', true, 'repetido', true, 'id', v_id);
  end if;

  -- Cliente sugerido: solo si el teléfono es de UNA persona activa; con dos o más
  -- clientes distintos no se adivina.
  if (select count(distinct c.cliente_id) from contactos c
       where c.activo and c.telefono_norm = v_norm) = 1 then
    v_cliente := (select c.cliente_id from contactos c
                   where c.activo and c.telefono_norm = v_norm limit 1);
  end if;

  v_id := gen_random_uuid();
  insert into solicitudes_web (
    id, nombre, telefono, telefono_norm, email, ubicacion, tipos, uso, equipo_actual,
    consumo, presupuesto, plazo, fuente, notas, origen_url, cliente_id
  ) values (
    v_id, v_nombre, left(trim(p_telefono), 30), v_norm,
    nullif(left(trim(coalesce(p_email, '')), 160), ''),
    nullif(left(trim(coalesce(p_ubicacion, '')), 200), ''),
    v_tipos,
    nullif(left(trim(coalesce(p_uso, '')), 60), ''),
    nullif(left(trim(coalesce(p_equipo_actual, '')), 100), ''),
    nullif(left(trim(coalesce(p_consumo, '')), 100), ''),
    nullif(left(trim(coalesce(p_presupuesto, '')), 100), ''),
    nullif(left(trim(coalesce(p_plazo, '')), 100), ''),
    nullif(left(trim(coalesce(p_fuente, '')), 100), ''),
    v_notas,
    nullif(left(trim(coalesce(p_origen_url, '')), 300), ''),
    v_cliente
  );

  return jsonb_build_object('ok', true, 'repetido', false, 'id', v_id,
                            'cliente_sugerido', v_cliente is not null);
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

CREATE OR REPLACE FUNCTION public.resolver_revision(p_id uuid, p_aprobar boolean, p_nota text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_q cola_revision;
  v_tc numeric;
  v_calc jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  v_q := (select q from cola_revision q where q.id = p_id);
  if v_q.id is null then
    raise exception 'No existe esa revisión.' using errcode = '22023';
  end if;
  if v_q.estado <> 'pendiente' then
    return 'sin_cambio';
  end if;

  if p_aprobar then
    if v_q.tipo in ('sin_regla', 'sin_costo') then
      raise exception 'Esto no se aprueba: captura la regla o el costo y vuelve a sincronizar. Aquí solo se descarta.'
        using errcode = '22023';
    elsif v_q.tipo = 'sku_desaparecido' then
      update productos set publicar = false, updated_at = now() where id = v_q.producto_id;
      perform _apunta('productos', v_q.producto_id, 'retirado_por_proveedor', null,
                      jsonb_build_object('publicar', false), 'sync');
    else
      v_tc := (select valor from tipos_cambio where moneda = 'USD' order by fecha desc limit 1);
      v_calc := _calcular_precio(v_q.producto_id, v_tc);
      if not (v_calc ->> 'ok')::boolean then
        raise exception 'No se puede calcular el precio (%).', v_calc ->> 'motivo' using errcode = '22023';
      end if;
      if not (v_calc ->> 'vigente')::boolean then
        raise exception 'El proveedor ya no lista este producto.' using errcode = '22023';
      end if;
      perform _aplicar_precio(v_q.producto_id, v_calc, 'aprobacion', v_q.corrida_id, v_tc);
    end if;
  end if;

  update cola_revision
     set estado = case when p_aprobar then 'aprobada' else 'rechazada' end,
         resuelto_por = coalesce(auth.jwt() ->> 'email', 'crm'), resuelto_en = now(), nota = p_nota
   where id = p_id;
  return case when p_aprobar then 'aprobada' else 'rechazada' end;
end $function$
;

CREATE OR REPLACE FUNCTION public.resolver_revisiones(p_tipo text, p_aprobar boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id uuid;
  v_ok int := 0;
  v_mal int := 0;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  for v_id in select id from cola_revision where tipo = p_tipo and estado = 'pendiente' order by creado_en loop
    begin
      perform resolver_revision(v_id, p_aprobar, 'En lote');
      v_ok := v_ok + 1;
    exception when others then
      v_mal := v_mal + 1;
    end;
  end loop;
  return jsonb_build_object('resueltas', v_ok, 'fallidas', v_mal);
end $function$
;

CREATE OR REPLACE FUNCTION public.resolver_solicitud_web(p_id uuid, p_estado text, p_nota text DEFAULT NULL::text, p_cliente uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if p_estado not in ('nueva', 'atendida', 'descartada') then
    raise exception 'Estado no válido: %', p_estado using errcode = '22023';
  end if;
  if not exists (select 1 from solicitudes_web where id = p_id) then
    raise exception 'La solicitud no existe.' using errcode = 'P0002';
  end if;
  if p_cliente is not null and not exists (select 1 from clientes where id = p_cliente) then
    raise exception 'El cliente no existe.' using errcode = '22023';
  end if;

  update solicitudes_web set
    estado = p_estado,
    nota_interna = coalesce(nullif(left(trim(coalesce(p_nota, '')), 1000), ''), nota_interna),
    cliente_id = coalesce(p_cliente, cliente_id),
    atendida_por = case when p_estado = 'nueva' then null else coalesce(auth.jwt() ->> 'email', 'crm') end,
    atendida_en  = case when p_estado = 'nueva' then null else now() end
  where id = p_id;

  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.responder_whatsapp(p_conversacion uuid, p_texto text, p_borrador uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_conv conversaciones%rowtype; v_id uuid := gen_random_uuid();
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if nullif(trim(coalesce(p_texto, '')), '') is null then
    raise exception 'El mensaje va vacío.' using errcode = '22023';
  end if;
  v_conv := (select c from conversaciones c where c.id = p_conversacion);
  if v_conv.id is null then
    raise exception 'La conversación no existe.' using errcode = 'P0002';
  end if;
  if v_conv.ventana_hasta is null or v_conv.ventana_hasta <= now() then
    raise exception 'La ventana de 24 h está cerrada: solo se puede mandar una plantilla aprobada.' using errcode = '22023';
  end if;
  insert into salida_wa (id, llave, telefono, conversacion_id, tipo, texto, origen, origen_id, categoria, estado,
                         aprobado_por, aprobado_en, creado_por)
  values (v_id, 'texto:' || v_id, v_conv.telefono, v_conv.id, 'texto', trim(p_texto), 'respuesta', p_borrador,
          'servicio', 'pendiente', coalesce(auth.jwt() ->> 'email', 'crm'), now(), coalesce(auth.jwt() ->> 'email', 'crm'));
  -- El borrador del agente queda marcado: ya no se ofrece "Mandar este borrador".
  if p_borrador is not null then
    update mensajes_wa set estado = 'aprobado' where id = p_borrador and estado = 'borrador';
  end if;
  return jsonb_build_object('ok', true, 'salida_id', v_id);
end $function$
;

CREATE OR REPLACE FUNCTION public.resultados_campana(p_mes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_det jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  v_det := (
    select coalesce(jsonb_agg(x order by x ->> 'orden'), '[]'::jsonb) from (
      select jsonb_strip_nulls(jsonb_build_object(
        'id', e.id, 'orden', lpad(coalesce(e.orden, 0)::text, 6, '0'), 'nombre', e.nombre, 'telefono', e.telefono,
        'categoria', e.categoria, 'estado', e.estado, 'motivo', e.motivo,
        'envio', s.estado, 'enviado_en', s.enviado_en,
        'respondio', s.enviado_en is not null and exists (
           select 1 from mensajes_wa m join conversaciones c on c.id = m.conversacion_id
            where c.telefono_norm = e.telefono_norm and m.direccion = 'entrante' and m.created_at > s.enviado_en),
        'cita', s.enviado_en is not null and exists (
           select 1 from citas ci join contactos ct on ct.cliente_id = ci.cliente_id
            where ct.activo and ct.telefono_norm = e.telefono_norm and ci.created_at > s.enviado_en),
        'baja', exists (select 1 from wa_bajas b where b.telefono_norm = e.telefono_norm
                          and (s.enviado_en is null or b.created_at > s.enviado_en))
      )) as x
      from campana_envios e left join salida_wa s on s.id = e.salida_id
      where e.mes = p_mes) z);
  return jsonb_build_object(
    'mes', p_mes,
    'cargados', (select count(*) from campana_envios where mes = p_mes),
    'por_proponer', (select count(*) from campana_envios where mes = p_mes and estado = 'propuesto'),
    'aprobados', (select count(*) from jsonb_array_elements(v_det) d where d ->> 'estado' = 'aprobado'),
    'enviados', (select count(*) from jsonb_array_elements(v_det) d where d ->> 'enviado_en' is not null),
    'respondieron', (select count(*) from jsonb_array_elements(v_det) d where (d ->> 'respondio')::boolean),
    'citas', (select count(*) from jsonb_array_elements(v_det) d where (d ->> 'cita')::boolean),
    'bajas', (select count(*) from jsonb_array_elements(v_det) d where (d ->> 'baja')::boolean),
    'detalle', v_det);
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

CREATE OR REPLACE FUNCTION public.sugerir_cotizaciones_para_cfdi(p_cfdi uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_c cfdi%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador liga facturas.' using errcode = '42501';
  end if;
  v_c := (select c from cfdi c where c.id = p_cfdi);
  if v_c.id is null or v_c.sentido <> 'emitido' then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'cotizacion_id', q.id, 'folio', q.folio, 'cliente', cl.nombre, 'total', q.total,
             'estado', q.estado, 'coincide_total', abs(coalesce(q.total, 0) - v_c.total) <= 1,
             'mismo_cliente', q.cliente_id is not distinct from v_c.cliente_id)
           order by (abs(coalesce(q.total, 0) - v_c.total) <= 1) desc, q.created_at desc)
      from (select * from cotizaciones
             where estado in ('aceptada', 'enviada')
               and (cliente_id is not distinct from v_c.cliente_id
                    or abs(coalesce(total, 0) - v_c.total) <= 1)
             order by created_at desc limit 8) q
      join clientes cl on cl.id = q.cliente_id), '[]'::jsonb);
end;
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

CREATE OR REPLACE FUNCTION public.sync_aplicar(p_corrida uuid, p_tipo_cambio numeric, p_tc_fecha date DEFAULT NULL::date, p_tc_fuente text DEFAULT NULL::text, p_umbral_pct numeric DEFAULT 15)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_c sync_corridas;
  v_p productos;
  v_sku text;
  v_pp proveedor_productos;
  v_otro boolean;
  v_calc jsonb;
  v_var numeric;
  v_aplicados int := 0;
  v_sin_cambio int := 0;
  v_revision int := 0;
  v_faltan int := 0;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector.' using errcode = '42501';
  end if;
  v_c := (select c from sync_corridas c where c.id = p_corrida);
  if v_c.id is null or v_c.estado <> 'leida' then
    raise exception 'La corrida no está lista: primero hay que cerrar una lectura buena.'
      using errcode = '22023';
  end if;
  if p_tipo_cambio is null or p_tipo_cambio < 5 or p_tipo_cambio > 100 then
    raise exception 'Tipo de cambio fuera de rango: %.', p_tipo_cambio using errcode = '22023';
  end if;

  insert into tipos_cambio (fecha, moneda, valor, fuente)
  values (coalesce(p_tc_fecha, current_date), 'USD', p_tipo_cambio, p_tc_fuente)
  on conflict (fecha, moneda) do update set valor = excluded.valor, fuente = excluded.fuente;

  update proveedor_productos
     set vigente = false
   where proveedor = v_c.proveedor and corrida_id is distinct from p_corrida;
  update cola_revision q
     set estado = 'rechazada', resuelto_por = 'sync', resuelto_en = now(),
         nota = 'Volvió a aparecer en la lectura.'
   where q.tipo = 'sku_desaparecido' and q.estado = 'pendiente'
     and exists (select 1 from producto_proveedores l
                   join proveedor_productos x
                     on x.proveedor = l.proveedor and x.sku_proveedor = l.proveedor_sku
                  where l.producto_id = q.producto_id and x.corrida_id = p_corrida);

  -- Todos los productos con proveedor y precio automático: el tipo de cambio del día también mueve
  -- lo que solo vende el otro proveedor.
  for v_p in
    select p.* from productos p
     where p.precio_auto and p.activo
       and exists (select 1 from producto_proveedores l where l.producto_id = p.id)
     order by p.sku
  loop
    v_sku := (select l.proveedor_sku from producto_proveedores l
               where l.producto_id = v_p.id and l.proveedor = v_c.proveedor);

    if v_sku is not null then
      v_pp := (select x from proveedor_productos x
                where x.proveedor = v_c.proveedor and x.sku_proveedor = v_sku);
      v_otro := exists (select 1 from producto_proveedores l
                          join proveedor_productos x
                            on x.proveedor = l.proveedor and x.sku_proveedor = l.proveedor_sku
                         where l.producto_id = v_p.id and l.proveedor <> v_c.proveedor
                           and x.vigente and x.costo > 0);
      if (v_pp.id is null or not v_pp.vigente) and not v_otro then
        perform _encolar('sku_desaparecido', v_p.id, v_sku,
                         jsonb_build_object('nombre', v_p.nombre, 'precio_actual', v_p.precio,
                                            'proveedor', v_c.proveedor), p_corrida);
        v_revision := v_revision + 1;
        continue;
      end if;
    end if;

    v_calc := _calcular_precio(v_p.id, p_tipo_cambio);
    if not (v_calc ->> 'ok')::boolean then
      perform _ordenar_proveedores(v_p.id, v_calc);   -- apaga la promoción si la había
      perform _encolar(case v_calc ->> 'motivo' when 'sin_regla' then 'sin_regla' else 'sin_costo' end,
                       v_p.id, coalesce(v_sku, v_p.proveedor_sku),
                       jsonb_build_object('nombre', v_p.nombre, 'motivo', v_calc ->> 'motivo'), p_corrida);
      v_faltan := v_faltan + 1;
      continue;
    end if;

    update cola_revision
       set estado = 'rechazada', resuelto_por = 'sync', resuelto_en = now(),
           nota = 'Ya se resolvió: hay regla y costo.'
     where producto_id = v_p.id and tipo in ('sin_regla', 'sin_costo') and estado = 'pendiente';

    perform _ordenar_proveedores(v_p.id, v_calc);

    if v_p.precio is null or v_p.precio <= 0 then
      perform _encolar('precio_inicial', v_p.id, coalesce(v_sku, v_p.proveedor_sku),
                       v_calc || jsonb_build_object('nombre', v_p.nombre), p_corrida);
      v_revision := v_revision + 1;
      continue;
    end if;

    v_var := abs((v_calc ->> 'precio')::numeric - v_p.precio) / v_p.precio * 100;
    if v_var > p_umbral_pct then
      perform _encolar('cambio_precio', v_p.id, coalesce(v_sku, v_p.proveedor_sku),
                       v_calc || jsonb_build_object('nombre', v_p.nombre,
                                                    'precio_actual', v_p.precio,
                                                    'variacion_pct', round(v_var, 1)), p_corrida);
      v_revision := v_revision + 1;
    elsif (v_calc ->> 'precio')::numeric <> v_p.precio
       or (v_calc ->> 'costo_mxn')::numeric is distinct from v_p.costo then
      perform _aplicar_precio(v_p.id, v_calc, 'sync', p_corrida, p_tipo_cambio);
      v_aplicados := v_aplicados + 1;
    else
      v_sin_cambio := v_sin_cambio + 1;
    end if;
  end loop;

  update sync_corridas
     set estado = 'aplicada', tipo_cambio = p_tipo_cambio, terminada_en = now(),
         resumen = jsonb_build_object('aplicados', v_aplicados, 'sin_cambio', v_sin_cambio,
                                      'en_revision', v_revision, 'sin_regla_o_costo', v_faltan,
                                      'en_promocion', (select count(*) from productos
                                                        where activo and precio_promocion is not null))
   where id = p_corrida;

  return jsonb_build_object('aplicados', v_aplicados, 'sin_cambio', v_sin_cambio,
                            'en_revision', v_revision, 'sin_regla_o_costo', v_faltan);
end $function$
;

CREATE OR REPLACE FUNCTION public.sync_cerrar_lectura(p_corrida uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_c sync_corridas;
  v_filas int;
  v_previas int;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector.' using errcode = '42501';
  end if;
  v_c := (select c from sync_corridas c where c.id = p_corrida);
  if v_c.id is null or v_c.estado <> 'leyendo' then
    raise exception 'La corrida no existe o ya se cerró.' using errcode = '22023';
  end if;
  v_filas := (select count(*) from proveedor_productos where corrida_id = p_corrida);
  v_previas := (select c.filas from sync_corridas c
                 where c.proveedor = v_c.proveedor and c.id <> p_corrida
                   and c.estado in ('leida', 'aplicada')
                 order by c.iniciada_en desc limit 1);

  if v_filas = 0 or (coalesce(v_previas, 0) > 0 and v_filas < v_previas * 0.5) then
    update sync_corridas
       set estado = 'fallida', filas = v_filas, terminada_en = now(),
           error = concat('Lectura sospechosa: ', v_filas, ' filas contra ', coalesce(v_previas, 0),
                          ' de la lectura anterior. No se aplicó nada.')
     where id = p_corrida;
    return jsonb_build_object('ok', false, 'filas', v_filas, 'previas', coalesce(v_previas, 0));
  end if;

  update sync_corridas set estado = 'leida', filas = v_filas where id = p_corrida;
  return jsonb_build_object('ok', true, 'filas', v_filas, 'previas', coalesce(v_previas, 0));
end $function$
;

CREATE OR REPLACE FUNCTION public.sync_iniciar(p_proveedor text, p_fuente text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id uuid := gen_random_uuid();
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector.' using errcode = '42501';
  end if;
  if coalesce(trim(p_proveedor), '') = '' then
    raise exception 'Falta el proveedor.' using errcode = '22023';
  end if;
  insert into sync_corridas (id, proveedor, fuente) values (v_id, lower(trim(p_proveedor)), p_fuente);
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.sync_recibir_lote(p_corrida uuid, p_filas jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_c sync_corridas;
  v_f jsonb;
  v_n int := 0;
  v_moneda text;
  v_costo numeric;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector.' using errcode = '42501';
  end if;
  v_c := (select c from sync_corridas c where c.id = p_corrida);
  if v_c.id is null or v_c.estado <> 'leyendo' then
    raise exception 'La corrida no existe o ya no recibe filas.' using errcode = '22023';
  end if;
  if jsonb_typeof(p_filas) <> 'array' then
    raise exception 'Las filas deben ir en un arreglo.' using errcode = '22023';
  end if;

  for v_f in select value from jsonb_array_elements(p_filas) loop
    if coalesce(trim(v_f ->> 'sku_proveedor'), '') = '' then
      raise exception 'Una fila no trae sku_proveedor.' using errcode = '22023';
    end if;
    v_moneda := upper(coalesce(nullif(v_f ->> 'moneda', ''), ''));
    if v_moneda not in ('MXN', 'USD') then
      raise exception 'Moneda inválida en %: "%".', v_f ->> 'sku_proveedor', v_f ->> 'moneda'
        using errcode = '22023';
    end if;
    v_costo := nullif(v_f ->> 'costo', '')::numeric;
    if v_costo is not null and v_costo < 0 then
      raise exception 'Costo negativo en %.', v_f ->> 'sku_proveedor' using errcode = '22023';
    end if;

    insert into proveedor_productos (proveedor, sku_proveedor, nombre, categoria, marca, modelo,
                                     descripcion, costo, moneda, stock_local, stock_proveedor,
                                     tiempo_entrega_dias, url_imagen, documentos,
                                     corrida_id, vigente, leido_en)
    values (v_c.proveedor, trim(v_f ->> 'sku_proveedor'), v_f ->> 'nombre', v_f ->> 'categoria',
            v_f ->> 'marca', v_f ->> 'modelo', v_f ->> 'descripcion', v_costo, v_moneda,
            nullif(v_f ->> 'stock_local', '')::int, nullif(v_f ->> 'stock_proveedor', '')::int,
            nullif(v_f ->> 'tiempo_entrega_dias', '')::int, nullif(v_f ->> 'url_imagen', ''),
            coalesce(v_f -> 'documentos', '{}'::jsonb), p_corrida, true, now())
    on conflict (proveedor, sku_proveedor) do update
      set nombre = excluded.nombre, categoria = excluded.categoria, marca = excluded.marca,
          modelo = excluded.modelo, descripcion = excluded.descripcion, costo = excluded.costo,
          moneda = excluded.moneda, stock_local = excluded.stock_local,
          stock_proveedor = excluded.stock_proveedor,
          tiempo_entrega_dias = excluded.tiempo_entrega_dias,
          url_imagen = coalesce(excluded.url_imagen, proveedor_productos.url_imagen),
          documentos = case when excluded.documentos = '{}'::jsonb then proveedor_productos.documentos
                            else excluded.documentos end,
          corrida_id = excluded.corrida_id,
          vigente = true, leido_en = excluded.leido_en;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $function$
;

CREATE OR REPLACE FUNCTION public.sync_registrar_error(p_corrida uuid, p_error text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector.' using errcode = '42501';
  end if;
  update sync_corridas
     set estado = 'fallida', error = left(p_error, 2000), terminada_en = now()
   where id = p_corrida and estado in ('leyendo', 'leida');
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
    if a.tipo = 'recordatorio' then
      return concat_ws(E'\n', v_hola, '',
        'Le recordamos su cita con PowerMx mañana: ' || v_tipo || coalesce(' de su ' || v_equipo, '') || '.',
        '', 'Fecha: ' || v_cuando, v_dur,
        case when v_tec <> '' then 'Lo atenderá: ' || v_tec end,
        '', 'Si necesita cambiar la fecha, responda a este mensaje.', 'PowerMx');
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

CREATE OR REPLACE FUNCTION public.tomar_salida(p_n integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; v_out jsonb := '[]'::jsonb; v_pl wa_plantillas%rowtype; v_vars jsonb; v_motivo text;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el conector de WhatsApp o el administrador.' using errcode = '42501';
  end if;
  if not coalesce((select envio_activo from wa_config where id), false) then
    return jsonb_build_object('ok', true, 'apagado', true, 'mensajes', '[]'::jsonb);
  end if;

  for r in select * from salida_wa
            where estado = 'pendiente' and programado_para <= now()
            order by programado_para limit greatest(1, least(p_n, 50))
            for update skip locked loop
    v_motivo := null; v_vars := r.variables; v_pl := null;
    if r.tipo = 'texto' then
      if not exists (select 1 from conversaciones c where c.id = r.conversacion_id and c.ventana_hasta > now()) then
        v_motivo := 'la ventana de 24 h se cerró antes de salir';
      end if;
    else
      v_pl := (select p from wa_plantillas p where p.nombre = r.plantilla);
      if v_pl.estado is distinct from 'aprobada' then
        continue;                                    -- espera a que Meta la apruebe; no es error
      end if;
      if r.categoria = 'marketing' and exists (select 1 from wa_bajas b where b.telefono_norm = r.telefono_norm) then
        v_motivo := 'el número pidió BAJA';
      end if;
      if r.origen = 'aviso' then v_vars := _variables_aviso(r.origen_id); end if;
      if v_motivo is null and exists (select 1 from unnest(v_pl.variables) v where nullif(v_vars ->> v, '') is null) then
        v_motivo := 'faltan variables para la plantilla';
      end if;
    end if;

    if v_motivo is not null then
      update salida_wa set estado = 'cancelado', error = v_motivo where id = r.id;
      continue;
    end if;

    update salida_wa set estado = 'enviando', tomado_en = now(), intentos = intentos + 1, variables = v_vars
     where id = r.id;
    v_out := v_out || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'id', r.id, 'to', _wa_destino(r.telefono), 'tipo', r.tipo, 'texto', case when r.tipo = 'texto' then r.texto end,
      'plantilla', r.plantilla, 'idioma', v_pl.idioma,
      'parametros', case when r.tipo = 'plantilla' then
         (select coalesce(jsonb_agg(jsonb_build_object('nombre', v, 'valor', v_vars ->> v)), '[]'::jsonb) from unnest(v_pl.variables) v) end,
      'documento_ruta', r.documento_ruta, 'documento_nombre', r.documento_nombre)));
  end loop;
  return jsonb_build_object('ok', true, 'mensajes', v_out);
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

CREATE OR REPLACE FUNCTION public.vincular_producto_proveedor(p_producto uuid, p_proveedor text, p_sku text, p_precio_auto boolean DEFAULT false)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_prov text := lower(trim(p_proveedor));
  v_sku text := nullif(trim(p_sku), '');
  v_otro text;
  v_primero producto_proveedores;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if not exists (select 1 from productos where id = p_producto) then
    raise exception 'No existe ese producto.' using errcode = '22023';
  end if;

  if v_sku is null then
    delete from producto_proveedores where producto_id = p_producto and proveedor = v_prov;
  else
    if not exists (select 1 from proveedor_productos
                    where proveedor = v_prov and sku_proveedor = v_sku) then
      raise exception 'El proveedor no tiene ese código en la última lectura.' using errcode = '22023';
    end if;
    v_otro := (select p.sku from producto_proveedores l join productos p on p.id = l.producto_id
                where l.proveedor = v_prov and l.proveedor_sku = v_sku and l.producto_id <> p_producto);
    if v_otro is not null then
      raise exception 'Ese código del proveedor ya está ligado al producto %.', v_otro using errcode = '22023';
    end if;
    insert into producto_proveedores (producto_id, proveedor, proveedor_sku)
    values (p_producto, v_prov, v_sku)
    on conflict (producto_id, proveedor) do update
      set proveedor_sku = excluded.proveedor_sku, opcion = null, costo_mxn = null;
  end if;

  v_primero := (select l from producto_proveedores l where l.producto_id = p_producto
                 order by l.opcion nulls last, l.creado_en, l.proveedor limit 1);
  update productos
     set proveedor = v_primero.proveedor,
         proveedor_sku = v_primero.proveedor_sku,
         precio_auto = case when v_primero.producto_id is null then false
                            when v_sku is null then precio_auto
                            else p_precio_auto end,
         precio_promocion = null,
         updated_at = now()
   where id = p_producto;

  perform _apunta('productos', p_producto, 'vincular_proveedor', null,
                  jsonb_build_object('proveedor', v_prov, 'sku', v_sku, 'precio_auto', p_precio_auto),
                  'oficina');
  return 'ok';
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
  v_hist jsonb;
  v_razon text;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el conector de WhatsApp o el administrador.' using errcode = '42501';
  end if;

  v_cliente := _cliente_de_conversacion(p_conversacion);
  if v_cliente is null then
    -- Número sin identificar: no se le da un solo dato de nadie.
    return jsonb_build_object('conocido', false);
  end if;

  v_contacto := (select c.nombre from conversaciones v join contactos c on c.id = v.contacto_id
                  where v.id = p_conversacion);
  v_nombre_cliente := (select nombre from clientes where id = v_cliente);
  v_n := (select count(*) from equipos
           where cliente_id = v_cliente and coalesce(estado, 'activo') = 'activo');

  v_equipos := (
    select coalesce(jsonb_agg(x order by x ->> 'descripcion'), '[]'::jsonb)
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
        'numero_serie', case when v_n = 1 then e.numero_serie end
      )) as x
      from equipos e
      where e.cliente_id = v_cliente and coalesce(e.estado, 'activo') = 'activo'
    ) z);

  v_cita := (
    select jsonb_strip_nulls(jsonb_build_object(
             'fecha', c.fecha, 'hora', c.hora, 'estado', c.estado, 'tipo', c.tipo_servicio))
      from citas c
     where c.cliente_id = v_cliente and c.estado in ('programada', 'por_programar')
     order by c.fecha nulls last
     limit 1);

  -- Lo que se trajo del historial (lo más reciente aceptado de ese cliente).
  v_hist := (
    select jsonb_strip_nulls(jsonb_build_object(
             'equipo', nullif(i.equipo, ''),
             'ultimo_servicio', nullif(i.ultimo_servicio, ''),
             'pendiente', nullif(i.pendiente, ''),
             'importado_el', i.revisado_en::date))
      from importacion_whatsapp i
     where i.cliente_id = v_cliente and i.estado = 'aceptada'
     order by i.revisado_en desc
     limit 1);

  -- Razón social: la de datos_fiscales manda; si no hay, la del historial.
  v_razon := coalesce(
    (select d.razon_social from datos_fiscales d where d.cliente_id = v_cliente limit 1),
    (select nullif(i.razon_social, '') from importacion_whatsapp i
      where i.cliente_id = v_cliente and i.estado = 'aceptada'
      order by i.revisado_en desc limit 1));

  return jsonb_strip_nulls(jsonb_build_object(
    'conocido', true,
    'contacto', v_contacto,
    'cliente', v_nombre_cliente,
    'equipos', v_equipos,
    'proxima_cita', v_cita,
    'historial', v_hist,
    'razon_social', v_razon));
end $function$
;

CREATE OR REPLACE FUNCTION public.wa_cotizar_preventivo(p_conversacion uuid, p_equipo uuid, p_tipo text DEFAULT 'menor'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cliente   uuid;
  e           equipos%rowtype;
  v_clase     text;
  v_cap       numeric;
  v_tarifa    tarifas_servicio%rowtype;
  v_paquete   uuid;
  v_traslado  jsonb;
  v_partidas  jsonb := '[]'::jsonb;
  v_subtotal  numeric := 0;
  v_iva       numeric;
  v_ya        cotizaciones%rowtype;
  v_id        uuid;
  v_folio     int;
  v_desc      text;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el conector de WhatsApp o el administrador.' using errcode = '42501';
  end if;
  if p_tipo not in ('menor', 'mayor') then
    return jsonb_build_object('ok', false, 'falta', 'El mantenimiento es menor o mayor.');
  end if;

  -- El cliente sale del número. Si no está ligado, no se cotiza nada.
  v_cliente := _cliente_de_conversacion(p_conversacion);
  if v_cliente is null then
    return jsonb_build_object('ok', false,
      'falta', 'Ese número todavía no está ligado a un cliente: una persona tiene que enlazarlo.');
  end if;

  -- El equipo tiene que ser de ESE cliente, aunque el id venga bien escrito.
  e := (select x from equipos x where x.id = p_equipo and x.cliente_id = v_cliente);
  if e.id is null then
    return jsonb_build_object('ok', false, 'falta', 'Ese equipo no es de este cliente.');
  end if;

  v_clase := _clase_de_equipo(e);
  v_cap   := _capacidad_de_equipo(e);

  -- La tarifa fija por clase y tramo de kW. Gana la más específica: primero la que sí tiene
  -- clase, y dentro de ésas la que empieza más arriba. Es la misma búsqueda que hace
  -- `paquete_preventivo` (SQL 28): si se cambia una, hay que cambiar la otra.
  v_tarifa := (select t from tarifas_servicio t
                where t.activo
                  and t.concepto = 'preventivo_' || p_tipo
                  and (t.clase is null or t.clase = v_clase)
                  and (t.kw_desde is null or (v_cap is not null and v_cap >= t.kw_desde))
                  and (t.kw_hasta is null or (v_cap is not null and v_cap <= t.kw_hasta))
                order by (t.clase is not null) desc, t.kw_desde desc nulls last
                limit 1);

  v_paquete  := _paquete_de_equipo(e.id, p_tipo);
  v_traslado := _precio_traslado(v_cliente);

  -- Todo lo que puede faltar, con el motivo en palabras. Sin esto habría que inventar un
  -- precio, que es justo lo que el diseño prohíbe.
  if v_clase is null then
    return jsonb_build_object('ok', false,
      'falta', 'No se sabe de qué clase es el equipo: falta capturar el combustible.');
  elsif v_cap is null then
    return jsonb_build_object('ok', false, 'falta', 'El equipo no tiene capacidad capturada.');
  elsif v_tarifa.precio is null then
    return jsonb_build_object('ok', false,
      'falta', concat('No hay tarifa de mantenimiento ', p_tipo, ' para esa clase y capacidad.'));
  elsif v_paquete is null then
    return jsonb_build_object('ok', false,
      'falta', 'Ese equipo todavía no tiene paquete de refacciones capturado.');
  elsif v_traslado ? 'falta' then
    return jsonb_build_object('ok', false, 'falta', v_traslado ->> 'falta');
  end if;

  -- Una línea del paquete sin ningún código disponible se caería en silencio del arreglo, y el
  -- almacén no tendría qué preparar. Mejor no cotizar y que lo vea una persona.
  if exists (
    select 1 from paquete_lineas l
     where l.paquete_id = v_paquete
       and not exists (select 1 from _codigos_de_linea(l.id))
  ) then
    return jsonb_build_object('ok', false,
      'falta', 'Al paquete de ese equipo le falta el código de alguna refacción.');
  end if;

  -- ¿Ya hay un borrador del agente para lo mismo? No se apilan cotizaciones: pedir dos veces
  -- devuelve la que ya estaba, igual que `wa_solicitar_cita` no apila citas. Se busca por la
  -- marca `servicio` de la partida y no por el sku, que en `tarifas_servicio` puede ser nulo.
  v_ya := (select c from cotizaciones c
            where c.cliente_id = v_cliente and c.equipo_id = e.id
              and c.estado = 'borrador' and c.origen = 'whatsapp'
              and c.tipo = 'preventivo'
              and c.partidas @> jsonb_build_array(
                    jsonb_build_object('servicio', 'preventivo_' || p_tipo))
            order by c.created_at desc
            limit 1);
  if v_ya.id is not null then
    return jsonb_build_object('ok', true, 'repetida', true, 'folio', v_ya.folio, 'tipo', p_tipo);
  end if;

  -- 1) El servicio. Partida LIBRE (sin producto_id): no mueve inventario.
  v_partidas := v_partidas || jsonb_build_array(jsonb_build_object(
    'producto_id', null, 'sku', v_tarifa.sku,
    -- `servicio` marca de qué se trata la partida, como hace `tarifas.js` con 'diagnostico' y
    -- 'traslado'. Sirve para no apilar borradores del mismo tipo.
    'servicio', 'preventivo_' || p_tipo,
    'descripcion', coalesce(v_tarifa.nombre, concat('Mantenimiento ', p_tipo)),
    'unidad', 'servicio', 'cantidad', 1,
    'precio_unitario', v_tarifa.precio, 'importe', v_tarifa.precio));
  v_subtotal := v_subtotal + v_tarifa.precio;

  -- 2) Las refacciones del paquete: precio 0 y marcadas `incluida`, pero CON producto_id para
  --    que aparten inventario el día que alguien acepte. De cada línea se toma el código con
  --    más existencia, que puede ser el genérico en vez del original (SQL 29).
  v_partidas := v_partidas || coalesce((
    select jsonb_agg(jsonb_build_object(
             'producto_id', c.producto_id, 'sku', c.sku, 'descripcion', c.nombre,
             'unidad', coalesce(c.unidad, 'pieza'), 'cantidad', l.cantidad,
             'precio_unitario', 0, 'importe', 0, 'incluida', true)
           order by l.orden)
      from paquete_lineas l
      cross join lateral (
        select * from _codigos_de_linea(l.id) x order by x.disponible desc limit 1
      ) c
     where l.paquete_id = v_paquete), '[]'::jsonb);

  -- 3) El traslado, si aplica.
  if (v_traslado ->> 'aplica')::boolean then
    v_partidas := v_partidas || jsonb_build_array(jsonb_build_object(
      'producto_id', null, 'sku', '',
      'descripcion', concat('Servicio de traslado (', v_traslado ->> 'km', ' km, solo ida)'),
      'unidad', 'km', 'cantidad', (v_traslado ->> 'km')::numeric,
      'precio_unitario', (v_traslado ->> 'precio_km')::numeric,
      'importe', (v_traslado ->> 'importe')::numeric));
    v_subtotal := v_subtotal + (v_traslado ->> 'importe')::numeric;
  end if;

  v_iva := round(v_subtotal * 0.16, 2);

  insert into cotizaciones (cliente_id, equipo_id, tipo, partidas, subtotal, descuento,
                            iva, total, requiere_visita, estado, origen, creada_por,
                            notas_internas)
  values (v_cliente, e.id, 'preventivo', v_partidas, v_subtotal, 0,
          v_iva, v_subtotal + v_iva, true, 'borrador', 'whatsapp', 'agente-whatsapp',
          concat('Propuesta del agente de WhatsApp (mantenimiento ', p_tipo,
                 '). Revisar antes de enviar.'))
  -- Este `into` sí se queda: va con `returning` y sin `from`, así que no se puede confundir
  -- con un `create table as`. Lo que el editor malinterpreta es `select ... into X from ...`.
  returning id, folio into v_id, v_folio;   --  no lo confunde: no lleva 

  perform _apunta('cotizaciones', v_id, 'cotizacion_whatsapp', null,
                  jsonb_build_object('tipo', p_tipo, 'equipo_id', e.id), 'whatsapp');

  v_desc := trim(concat_ws(' ', e.marca, e.modelo,
                           case when e.capacidad_kw is not null
                                then concat(e.capacidad_kw, ' kW') end));

  -- El total NO se devuelve: el agente no le dice el precio al cliente.
  return jsonb_build_object('ok', true, 'folio', v_folio, 'tipo', p_tipo,
                            'equipo', nullif(v_desc, ''),
                            'aviso', 'Quedó en borrador. Una persona la revisa y la envía.');
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

create table if not exists public._migraciones (
  archivo text not null,
  numero integer generated always as (("substring"(archivo, '^[0-9]+'::text))::integer) stored,
  tipo text not null,
  aplicada_en timestamp with time zone not null,
  por text not null,
  nota text
);

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

create table if not exists public.campana_envios (
  id uuid not null,
  mes text not null,
  categoria text,
  prioridad text,
  telefono text not null,
  nombre text,
  equipo text,
  ultimo_servicio text,
  plantilla text,
  telefono_norm text generated always as (normalizar_telefono(telefono)) stored,
  orden integer,
  estado text not null,
  motivo text,
  tanda_id uuid,
  salida_id uuid,
  created_at timestamp with time zone not null
);

create table if not exists public.campana_tandas (
  id uuid not null,
  mes text not null,
  numero integer not null,
  estado text not null,
  propuesta_por text,
  aprobada_por text,
  aprobada_en timestamp with time zone,
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

create table if not exists public.cfdi (
  id uuid not null,
  uuid_fiscal text not null,
  sentido text not null,
  tipo_comprobante text not null,
  serie text,
  folio text,
  fecha timestamp with time zone not null,
  rfc_emisor text not null,
  nombre_emisor text,
  regimen_emisor text,
  rfc_receptor text not null,
  nombre_receptor text,
  uso_cfdi text,
  subtotal numeric(14,2) not null,
  descuento numeric(14,2) not null,
  total numeric(14,2) not null,
  iva_trasladado numeric(14,2) not null,
  isr_retenido numeric(14,2) not null,
  iva_retenido numeric(14,2) not null,
  moneda text not null,
  tipo_cambio numeric(14,6),
  metodo_pago text,
  forma_pago text,
  lugar_expedicion text,
  conceptos jsonb not null,
  relacionados jsonb not null,
  archivo_xml text,
  estado_sat text not null,
  cliente_id uuid,
  cotizacion_id uuid,
  compra_id uuid,
  documento_id uuid,
  creado_por text,
  created_at timestamp with time zone not null
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

create table if not exists public.cola_revision (
  id uuid not null,
  tipo text not null,
  producto_id uuid not null,
  proveedor_sku text,
  detalle jsonb not null,
  estado text not null,
  corrida_id uuid,
  creado_en timestamp with time zone not null,
  resuelto_por text,
  resuelto_en timestamp with time zone,
  nota text
);

create table if not exists public.compra_lineas (
  id uuid not null,
  compra_id uuid not null,
  producto_id uuid not null,
  requisicion_id uuid,
  cantidad numeric not null,
  costo_unitario numeric not null,
  importe numeric not null,
  movimiento_id uuid,
  created_at timestamp with time zone not null
);

create table if not exists public.compras (
  id uuid not null,
  folio bigint generated always as identity not null,
  proveedor text not null,
  factura text,
  uuid_fiscal text,
  fecha date not null,
  subtotal numeric not null,
  iva numeric not null,
  total numeric not null,
  moneda text not null,
  estado text not null,
  motivo_cancelacion text,
  notas text,
  archivo_xml text,
  archivo_pdf text,
  creada_por text,
  created_at timestamp with time zone not null,
  updated_at timestamp with time zone not null
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
  prog_tecnico2_id uuid,
  origen text,
  forma_pago text,
  garantia text,
  expediente_cerrado_en timestamp with time zone,
  expediente_cerrado_por text,
  expediente_cierre jsonb,
  cobranza_estado text not null,
  cobranza_liquidada_en timestamp with time zone,
  cobranza_manual boolean not null,
  cobranza_nota text
);

create table if not exists public.cuentas_financieras (
  id uuid not null,
  nombre text not null,
  tipo text not null,
  banco text,
  ultimos4 text,
  activa boolean not null,
  created_at timestamp with time zone not null
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

create table if not exists public.documentos (
  id uuid not null,
  tipo text not null,
  archivo text not null,
  nombre_original text,
  mime text,
  hash_sha256 text not null,
  estado text not null,
  metodo text not null,
  extraido jsonb,
  propuesta jsonb,
  validaciones jsonb not null,
  correccion jsonb,
  modelo text,
  cfdi_id uuid,
  movimiento_id uuid,
  motivo_rechazo text,
  subido_por text,
  aprobado_por text,
  aprobado_en timestamp with time zone,
  created_at timestamp with time zone not null
);

create table if not exists public.empresa_fiscal (
  id boolean not null,
  rfc text,
  razon_social text,
  regimen_fiscal text,
  cp_expedicion text,
  updated_at timestamp with time zone not null
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

create table if not exists public.expediente_movimientos (
  id uuid not null,
  cotizacion_id uuid,
  tipo text not null,
  categoria text not null,
  fecha date not null,
  concepto text,
  monto numeric(14,2) not null,
  iva numeric(14,2) not null,
  forma text,
  referencia text,
  tecnico_id uuid,
  archivo text,
  archivo_nombre text,
  notas text,
  creado_por text,
  created_at timestamp with time zone not null,
  leido_ia boolean not null,
  monto_leido numeric(14,2),
  cuenta_id uuid,
  cfdi_id uuid,
  documento_id uuid,
  compra_id uuid
);

create table if not exists public.historial_precios (
  id uuid not null,
  producto_id uuid not null,
  precio_anterior numeric,
  precio_nuevo numeric,
  costo_anterior numeric,
  costo_nuevo numeric,
  tipo_cambio numeric,
  origen text not null,
  corrida_id uuid,
  creado_en timestamp with time zone not null
);

create table if not exists public.importacion_whatsapp (
  id uuid not null,
  telefono text not null,
  nombre text,
  empresa text,
  ciudad text,
  equipo text,
  ultimo_servicio text,
  pendiente text,
  segmento text,
  factura text,
  razon_social text,
  nota text,
  telefono_norm text generated always as (normalizar_telefono(telefono)) stored,
  estado text not null,
  cliente_id uuid,
  contacto_id uuid,
  motivo text,
  revisado_por text,
  revisado_en timestamp with time zone,
  created_at timestamp with time zone not null
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

create table if not exists public.pagos_tecnico (
  id uuid not null,
  folio bigint generated always as identity not null,
  tecnico_id uuid not null,
  periodo_desde date not null,
  periodo_hasta date not null,
  estado text not null,
  total numeric(14,2) not null,
  forma text,
  referencia text,
  fecha_pago date,
  archivo text,
  motivo_cancelacion text,
  notas text,
  creado_por text,
  aprobado_por text,
  aprobado_en timestamp with time zone,
  pagado_por text,
  pagado_en timestamp with time zone,
  created_at timestamp with time zone not null
);

create table if not exists public.pagos_tecnico_lineas (
  id uuid not null,
  pago_id uuid not null,
  tecnico_id uuid not null,
  clase text not null,
  orden_id uuid,
  cotizacion_id uuid,
  tipo_servicio text,
  rol text,
  concepto text,
  monto numeric(12,2) not null,
  activa boolean not null,
  created_at timestamp with time zone not null
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

create table if not exists public.parametros_costeo (
  clave text not null,
  etiqueta text not null,
  valor numeric not null,
  unidad text,
  nota text,
  orden integer not null,
  actualizado_en timestamp with time zone not null,
  actualizado_por text
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

create table if not exists public.producto_proveedores (
  producto_id uuid not null,
  proveedor text not null,
  proveedor_sku text not null,
  opcion integer,
  costo_mxn numeric,
  creado_en timestamp with time zone not null
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
  grupo_equivalente text,
  proveedor text,
  proveedor_sku text,
  precio_auto boolean not null,
  precio_sync_en timestamp with time zone,
  precio_promocion numeric
);

create table if not exists public.proveedor_productos (
  id uuid not null,
  proveedor text not null,
  sku_proveedor text not null,
  nombre text,
  categoria text,
  marca text,
  modelo text,
  descripcion text,
  costo numeric,
  moneda text not null,
  stock_local integer,
  stock_proveedor integer,
  tiempo_entrega_dias integer,
  url_imagen text,
  documentos jsonb not null,
  corrida_id uuid,
  vigente boolean not null,
  leido_en timestamp with time zone not null
);

create table if not exists public.reglas_clasificacion (
  rfc_emisor text not null,
  nombre text,
  categoria text not null,
  cuenta_id uuid,
  veces integer not null,
  actualizada_en timestamp with time zone not null
);

create table if not exists public.reglas_margen (
  id uuid not null,
  categoria text,
  marca text,
  margen_pct numeric not null,
  margen_minimo_mxn numeric not null,
  redondeo numeric not null,
  activo boolean not null,
  created_at timestamp with time zone not null,
  sobre text not null
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

create table if not exists public.salida_wa (
  id uuid not null,
  llave text not null,
  telefono text not null,
  telefono_norm text generated always as (normalizar_telefono(telefono)) stored,
  conversacion_id uuid,
  tipo text not null,
  plantilla text,
  variables jsonb,
  documento_ruta text,
  documento_nombre text,
  texto text,
  origen text not null,
  origen_id uuid,
  categoria text not null,
  estado text not null,
  intentos integer not null,
  error text,
  wa_message_id text,
  programado_para timestamp with time zone not null,
  aprobado_por text,
  aprobado_en timestamp with time zone,
  tomado_en timestamp with time zone,
  enviado_en timestamp with time zone,
  creado_por text,
  created_at timestamp with time zone not null
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

create table if not exists public.solicitudes_web (
  id uuid not null,
  created_at timestamp with time zone not null,
  nombre text not null,
  telefono text not null,
  telefono_norm text not null,
  email text,
  ubicacion text,
  tipos text,
  uso text,
  equipo_actual text,
  consumo text,
  presupuesto text,
  plazo text,
  fuente text,
  notas text,
  origen_url text,
  cliente_id uuid,
  estado text not null,
  nota_interna text,
  atendida_por text,
  atendida_en timestamp with time zone
);

create table if not exists public.sync_corridas (
  id uuid not null,
  proveedor text not null,
  fuente text,
  estado text not null,
  filas integer,
  tipo_cambio numeric,
  resumen jsonb,
  error text,
  iniciada_en timestamp with time zone not null,
  terminada_en timestamp with time zone
);

create table if not exists public.tarifas_pago_tecnico (
  id uuid not null,
  tipo_servicio text not null,
  rol text not null,
  tecnico_id uuid,
  monto numeric(12,2) not null,
  vigente_desde date not null,
  vigente_hasta date,
  notas text,
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

create table if not exists public.tecnicos_pago (
  perfil_id uuid not null,
  esquema_pago text not null,
  alta_imss boolean not null,
  rfc text,
  banco text,
  cuenta_ultimos4 text,
  notas text,
  created_at timestamp with time zone not null,
  updated_at timestamp with time zone not null
);

create table if not exists public.tipos_cambio (
  fecha date not null,
  moneda text not null,
  valor numeric not null,
  fuente text
);

create table if not exists public.wa_agente (
  id boolean not null,
  activo boolean not null,
  modo text not null,
  tope_dia integer not null,
  instrucciones text,
  updated_at timestamp with time zone not null
);

create table if not exists public.wa_bajas (
  telefono_norm text not null,
  origen text not null,
  nota text,
  created_at timestamp with time zone not null
);

create table if not exists public.wa_config (
  id boolean not null,
  envio_activo boolean not null,
  avisos_automaticos boolean not null,
  dias_entre_marketing integer not null,
  updated_at timestamp with time zone not null
);

create table if not exists public.wa_plantillas (
  nombre text not null,
  idioma text not null,
  categoria text not null,
  uso text,
  variables text[] not null,
  encabezado text not null,
  estado text not null,
  notas text,
  updated_at timestamp with time zone not null
);

-- ========== DEFAULTS (después de las funciones) ==========

alter table public._migraciones alter column aplicada_en set default now();

alter table public._migraciones alter column por set default CURRENT_USER;

alter table public._migraciones alter column tipo set default 'esquema'::text;

alter table public.auditoria alter column created_at set default now();

alter table public.auditoria alter column id set default gen_random_uuid();

alter table public.auditoria alter column origen set default 'agente'::text;

alter table public.avisos alter column created_at set default now();

alter table public.avisos alter column estado set default 'pendiente'::text;

alter table public.avisos alter column id set default gen_random_uuid();

alter table public.campana_envios alter column created_at set default now();

alter table public.campana_envios alter column estado set default 'propuesto'::text;

alter table public.campana_envios alter column id set default gen_random_uuid();

alter table public.campana_tandas alter column created_at set default now();

alter table public.campana_tandas alter column estado set default 'propuesta'::text;

alter table public.campana_tandas alter column id set default gen_random_uuid();

alter table public.catalogos alter column activo set default true;

alter table public.catalogos alter column created_at set default now();

alter table public.catalogos alter column id set default gen_random_uuid();

alter table public.catalogos alter column usos set default 1;

alter table public.cfdi alter column conceptos set default '[]'::jsonb;

alter table public.cfdi alter column created_at set default now();

alter table public.cfdi alter column descuento set default 0;

alter table public.cfdi alter column estado_sat set default 'no_verificado'::text;

alter table public.cfdi alter column id set default gen_random_uuid();

alter table public.cfdi alter column isr_retenido set default 0;

alter table public.cfdi alter column iva_retenido set default 0;

alter table public.cfdi alter column iva_trasladado set default 0;

alter table public.cfdi alter column moneda set default 'MXN'::text;

alter table public.cfdi alter column relacionados set default '[]'::jsonb;

alter table public.cfdi alter column subtotal set default 0;

alter table public.cfdi alter column tipo_comprobante set default 'I'::text;

alter table public.cfdi alter column total set default 0;

alter table public.citas alter column created_at set default now();

alter table public.citas alter column estado set default 'programada'::text;

alter table public.citas alter column id set default gen_random_uuid();

alter table public.clientes alter column created_at set default now();

alter table public.clientes alter column estado_cliente set default 'activo'::text;

alter table public.clientes alter column estado_geo set default 'Yucatán'::text;

alter table public.clientes alter column id set default gen_random_uuid();

alter table public.clientes alter column tipo_cliente set default 'residencial'::text;

alter table public.clientes alter column updated_at set default now();

alter table public.cola_revision alter column creado_en set default now();

alter table public.cola_revision alter column detalle set default '{}'::jsonb;

alter table public.cola_revision alter column estado set default 'pendiente'::text;

alter table public.cola_revision alter column id set default gen_random_uuid();

alter table public.compra_lineas alter column created_at set default now();

alter table public.compra_lineas alter column id set default gen_random_uuid();

alter table public.compra_lineas alter column importe set default 0;

alter table public.compras alter column created_at set default now();

alter table public.compras alter column estado set default 'registrada'::text;

alter table public.compras alter column fecha set default CURRENT_DATE;

alter table public.compras alter column id set default gen_random_uuid();

alter table public.compras alter column iva set default 0;

alter table public.compras alter column moneda set default 'MXN'::text;

alter table public.compras alter column subtotal set default 0;

alter table public.compras alter column total set default 0;

alter table public.compras alter column updated_at set default now();

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

alter table public.cotizaciones alter column cobranza_estado set default 'pendiente'::text;

alter table public.cotizaciones alter column cobranza_manual set default false;

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

alter table public.cuentas_financieras alter column activa set default true;

alter table public.cuentas_financieras alter column created_at set default now();

alter table public.cuentas_financieras alter column id set default gen_random_uuid();

alter table public.cuentas_financieras alter column tipo set default 'banco'::text;

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

alter table public.documentos alter column created_at set default now();

alter table public.documentos alter column estado set default 'pendiente'::text;

alter table public.documentos alter column id set default gen_random_uuid();

alter table public.documentos alter column metodo set default 'manual'::text;

alter table public.documentos alter column tipo set default 'otro'::text;

alter table public.documentos alter column validaciones set default '[]'::jsonb;

alter table public.empresa_fiscal alter column id set default true;

alter table public.empresa_fiscal alter column regimen_fiscal set default '626'::text;

alter table public.empresa_fiscal alter column updated_at set default now();

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

alter table public.expediente_movimientos alter column created_at set default now();

alter table public.expediente_movimientos alter column fecha set default CURRENT_DATE;

alter table public.expediente_movimientos alter column id set default gen_random_uuid();

alter table public.expediente_movimientos alter column iva set default 0;

alter table public.expediente_movimientos alter column leido_ia set default false;

alter table public.historial_precios alter column creado_en set default now();

alter table public.historial_precios alter column id set default gen_random_uuid();

alter table public.importacion_whatsapp alter column created_at set default now();

alter table public.importacion_whatsapp alter column estado set default 'por_revisar'::text;

alter table public.importacion_whatsapp alter column id set default gen_random_uuid();

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

alter table public.pagos_tecnico alter column created_at set default now();

alter table public.pagos_tecnico alter column estado set default 'propuesto'::text;

alter table public.pagos_tecnico alter column id set default gen_random_uuid();

alter table public.pagos_tecnico alter column total set default 0;

alter table public.pagos_tecnico_lineas alter column activa set default true;

alter table public.pagos_tecnico_lineas alter column clase set default 'servicio'::text;

alter table public.pagos_tecnico_lineas alter column created_at set default now();

alter table public.pagos_tecnico_lineas alter column id set default gen_random_uuid();

alter table public.paquete_lineas alter column cantidad set default 1;

alter table public.paquete_lineas alter column id set default gen_random_uuid();

alter table public.paquete_lineas alter column orden set default 0;

alter table public.paquetes_mantenimiento alter column activo set default true;

alter table public.paquetes_mantenimiento alter column created_at set default now();

alter table public.paquetes_mantenimiento alter column id set default gen_random_uuid();

alter table public.paquetes_mantenimiento alter column updated_at set default now();

alter table public.parametros_costeo alter column actualizado_en set default now();

alter table public.parametros_costeo alter column orden set default 0;

alter table public.perfiles alter column activo set default true;

alter table public.perfiles alter column created_at set default now();

alter table public.perfiles alter column rol set default 'sin_rol'::text;

alter table public.producto_proveedores alter column creado_en set default now();

alter table public.productos alter column activo set default true;

alter table public.productos alter column atributos set default '{}'::jsonb;

alter table public.productos alter column clave_unidad_sat set default 'H87'::text;

alter table public.productos alter column created_at set default now();

alter table public.productos alter column id set default gen_random_uuid();

alter table public.productos alter column minimo set default 0;

alter table public.productos alter column moneda set default 'MXN'::text;

alter table public.productos alter column precio_auto set default false;

alter table public.productos alter column precios set default '{}'::jsonb;

alter table public.productos alter column publicar set default true;

alter table public.productos alter column unidad set default 'pieza'::text;

alter table public.productos alter column updated_at set default now();

alter table public.proveedor_productos alter column documentos set default '{}'::jsonb;

alter table public.proveedor_productos alter column id set default gen_random_uuid();

alter table public.proveedor_productos alter column leido_en set default now();

alter table public.proveedor_productos alter column moneda set default 'USD'::text;

alter table public.proveedor_productos alter column vigente set default true;

alter table public.reglas_clasificacion alter column actualizada_en set default now();

alter table public.reglas_clasificacion alter column veces set default 1;

alter table public.reglas_margen alter column activo set default true;

alter table public.reglas_margen alter column created_at set default now();

alter table public.reglas_margen alter column id set default gen_random_uuid();

alter table public.reglas_margen alter column margen_minimo_mxn set default 0;

alter table public.reglas_margen alter column redondeo set default 1;

alter table public.reglas_margen alter column sobre set default 'costo'::text;

alter table public.requisiciones alter column created_at set default now();

alter table public.requisiciones alter column estado set default 'pendiente'::text;

alter table public.requisiciones alter column id set default gen_random_uuid();

alter table public.requisiciones alter column updated_at set default now();

alter table public.salida_wa alter column created_at set default now();

alter table public.salida_wa alter column estado set default 'pendiente'::text;

alter table public.salida_wa alter column id set default gen_random_uuid();

alter table public.salida_wa alter column intentos set default 0;

alter table public.salida_wa alter column programado_para set default now();

alter table public.solicitudes_material alter column created_at set default now();

alter table public.solicitudes_material alter column estado set default 'pendiente'::text;

alter table public.solicitudes_material alter column id set default gen_random_uuid();

alter table public.solicitudes_web alter column created_at set default now();

alter table public.solicitudes_web alter column estado set default 'nueva'::text;

alter table public.solicitudes_web alter column id set default gen_random_uuid();

alter table public.sync_corridas alter column estado set default 'leyendo'::text;

alter table public.sync_corridas alter column id set default gen_random_uuid();

alter table public.sync_corridas alter column iniciada_en set default now();

alter table public.tarifas_pago_tecnico alter column created_at set default now();

alter table public.tarifas_pago_tecnico alter column id set default gen_random_uuid();

alter table public.tarifas_pago_tecnico alter column rol set default 'responsable'::text;

alter table public.tarifas_pago_tecnico alter column vigente_desde set default CURRENT_DATE;

alter table public.tarifas_servicio alter column activo set default true;

alter table public.tarifas_servicio alter column created_at set default now();

alter table public.tarifas_servicio alter column id set default gen_random_uuid();

alter table public.tarifas_servicio alter column updated_at set default now();

alter table public.tecnicos_pago alter column alta_imss set default false;

alter table public.tecnicos_pago alter column created_at set default now();

alter table public.tecnicos_pago alter column esquema_pago set default 'por_servicio'::text;

alter table public.tecnicos_pago alter column updated_at set default now();

alter table public.tipos_cambio alter column moneda set default 'USD'::text;

alter table public.wa_agente alter column activo set default false;

alter table public.wa_agente alter column id set default true;

alter table public.wa_agente alter column modo set default 'borrador'::text;

alter table public.wa_agente alter column tope_dia set default 20;

alter table public.wa_agente alter column updated_at set default now();

alter table public.wa_bajas alter column created_at set default now();

alter table public.wa_bajas alter column origen set default 'whatsapp'::text;

alter table public.wa_config alter column avisos_automaticos set default false;

alter table public.wa_config alter column dias_entre_marketing set default 30;

alter table public.wa_config alter column envio_activo set default false;

alter table public.wa_config alter column id set default true;

alter table public.wa_config alter column updated_at set default now();

alter table public.wa_plantillas alter column encabezado set default 'ninguno'::text;

alter table public.wa_plantillas alter column estado set default 'en_revision'::text;

alter table public.wa_plantillas alter column idioma set default 'es_MX'::text;

alter table public.wa_plantillas alter column updated_at set default now();

alter table public.wa_plantillas alter column variables set default '{}'::text[];

-- ========== RESTRICCIONES ==========

alter table public._migraciones add constraint _migraciones_pkey PRIMARY KEY (archivo);

alter table public.auditoria add constraint auditoria_pkey PRIMARY KEY (id);

alter table public.avisos add constraint avisos_pkey PRIMARY KEY (id);

alter table public.campana_envios add constraint campana_envios_pkey PRIMARY KEY (id);

alter table public.campana_tandas add constraint campana_tandas_pkey PRIMARY KEY (id);

alter table public.catalogos add constraint catalogos_pkey PRIMARY KEY (id);

alter table public.cfdi add constraint cfdi_pkey PRIMARY KEY (id);

alter table public.citas add constraint citas_pkey PRIMARY KEY (id);

alter table public.clientes add constraint clientes_pkey PRIMARY KEY (id);

alter table public.cola_revision add constraint cola_revision_pkey PRIMARY KEY (id);

alter table public.compra_lineas add constraint compra_lineas_pkey PRIMARY KEY (id);

alter table public.compras add constraint compras_pkey PRIMARY KEY (id);

alter table public.contactos add constraint contactos_pkey PRIMARY KEY (id);

alter table public.conversaciones add constraint conversaciones_pkey PRIMARY KEY (id);

alter table public.cotizaciones add constraint cotizaciones_pkey PRIMARY KEY (id);

alter table public.cuentas_financieras add constraint cuentas_financieras_pkey PRIMARY KEY (id);

alter table public.datos_fiscales add constraint datos_fiscales_pkey PRIMARY KEY (id);

alter table public.devoluciones add constraint devoluciones_pkey PRIMARY KEY (id);

alter table public.documentos add constraint documentos_pkey PRIMARY KEY (id);

alter table public.empresa_fiscal add constraint empresa_fiscal_pkey PRIMARY KEY (id);

alter table public.entrega_lineas add constraint entrega_lineas_pkey PRIMARY KEY (id);

alter table public.entregas add constraint entregas_pkey PRIMARY KEY (id);

alter table public.envios_orden add constraint envios_orden_pkey PRIMARY KEY (id);

alter table public.equipo_contactos add constraint equipo_contactos_pkey PRIMARY KEY (id);

alter table public.equipos add constraint equipos_pkey PRIMARY KEY (id);

alter table public.expediente_movimientos add constraint expediente_movimientos_pkey PRIMARY KEY (id);

alter table public.historial_precios add constraint historial_precios_pkey PRIMARY KEY (id);

alter table public.importacion_whatsapp add constraint importacion_whatsapp_pkey PRIMARY KEY (id);

alter table public.mensajes_wa add constraint mensajes_wa_pkey PRIMARY KEY (id);

alter table public.movimientos_inventario add constraint movimientos_inventario_pkey PRIMARY KEY (id);

alter table public.orden_partes add constraint orden_partes_pkey PRIMARY KEY (id);

alter table public.orden_revision add constraint orden_revision_pkey PRIMARY KEY (orden_id);

alter table public.orden_surtido add constraint orden_surtido_pkey PRIMARY KEY (id);

alter table public.ordenes_pdf add constraint ordenes_pdf_pkey PRIMARY KEY (id);

alter table public.ordenes_servicio add constraint ordenes_servicio_pkey PRIMARY KEY (id);

alter table public.pagos_tecnico add constraint pagos_tecnico_pkey PRIMARY KEY (id);

alter table public.pagos_tecnico_lineas add constraint pagos_tecnico_lineas_pkey PRIMARY KEY (id);

alter table public.paquete_lineas add constraint paquete_lineas_pkey PRIMARY KEY (id);

alter table public.paquetes_mantenimiento add constraint paquetes_mantenimiento_pkey PRIMARY KEY (id);

alter table public.parametros_costeo add constraint parametros_costeo_pkey PRIMARY KEY (clave);

alter table public.perfiles add constraint perfiles_pkey PRIMARY KEY (id);

alter table public.producto_proveedores add constraint producto_proveedores_pkey PRIMARY KEY (producto_id, proveedor);

alter table public.productos add constraint productos_pkey PRIMARY KEY (id);

alter table public.proveedor_productos add constraint proveedor_productos_pkey PRIMARY KEY (id);

alter table public.reglas_clasificacion add constraint reglas_clasificacion_pkey PRIMARY KEY (rfc_emisor);

alter table public.reglas_margen add constraint reglas_margen_pkey PRIMARY KEY (id);

alter table public.requisiciones add constraint requisiciones_pkey PRIMARY KEY (id);

alter table public.salida_wa add constraint salida_wa_pkey PRIMARY KEY (id);

alter table public.solicitudes_material add constraint solicitudes_material_pkey PRIMARY KEY (id);

alter table public.solicitudes_web add constraint solicitudes_web_pkey PRIMARY KEY (id);

alter table public.sync_corridas add constraint sync_corridas_pkey PRIMARY KEY (id);

alter table public.tarifas_pago_tecnico add constraint tarifas_pago_tecnico_pkey PRIMARY KEY (id);

alter table public.tarifas_servicio add constraint tarifas_servicio_pkey PRIMARY KEY (id);

alter table public.tecnicos_pago add constraint tecnicos_pago_pkey PRIMARY KEY (perfil_id);

alter table public.tipos_cambio add constraint tipos_cambio_pkey PRIMARY KEY (fecha, moneda);

alter table public.wa_agente add constraint wa_agente_pkey PRIMARY KEY (id);

alter table public.wa_bajas add constraint wa_bajas_pkey PRIMARY KEY (telefono_norm);

alter table public.wa_config add constraint wa_config_pkey PRIMARY KEY (id);

alter table public.wa_plantillas add constraint wa_plantillas_pkey PRIMARY KEY (nombre);

alter table public.campana_tandas add constraint campana_tandas_mes_numero_key UNIQUE (mes, numero);

alter table public.catalogos add constraint catalogos_tipo_valor_normalizado_key UNIQUE (tipo, valor_normalizado);

alter table public.cfdi add constraint cfdi_uuid_fiscal_key UNIQUE (uuid_fiscal);

alter table public.devoluciones add constraint devoluciones_folio_key UNIQUE (folio);

alter table public.documentos add constraint documentos_hash_sha256_key UNIQUE (hash_sha256);

alter table public.entregas add constraint entregas_folio_key UNIQUE (folio);

alter table public.envios_orden add constraint envios_orden_folio_key UNIQUE (folio);

alter table public.equipo_contactos add constraint equipo_contactos_equipo_id_contacto_id_key UNIQUE (equipo_id, contacto_id);

alter table public.equipos add constraint equipos_numero_serie_key UNIQUE (numero_serie);

alter table public.orden_partes add constraint orden_partes_orden_id_autor_id_key UNIQUE (orden_id, autor_id);

alter table public.orden_surtido add constraint orden_surtido_orden_id_producto_id_key UNIQUE (orden_id, producto_id);

alter table public.ordenes_pdf add constraint ordenes_pdf_orden_id_tipo_key UNIQUE (orden_id, tipo);

alter table public.producto_proveedores add constraint producto_proveedores_proveedor_proveedor_sku_key UNIQUE (proveedor, proveedor_sku);

alter table public.productos add constraint productos_sku_key UNIQUE (sku);

alter table public.proveedor_productos add constraint proveedor_productos_proveedor_sku_proveedor_key UNIQUE (proveedor, sku_proveedor);

alter table public.requisiciones add constraint requisiciones_folio_key UNIQUE (folio);

alter table public.salida_wa add constraint salida_wa_llave_key UNIQUE (llave);

alter table public.salida_wa add constraint salida_wa_wa_message_id_key UNIQUE (wa_message_id);

alter table public.solicitudes_material add constraint solicitudes_material_folio_key UNIQUE (folio);

alter table public.wa_plantillas add constraint wa_plantillas_uso_key UNIQUE (uso);

alter table public._migraciones add constraint _migraciones_nombre CHECK ((archivo ~ '^[0-9]{2,}_[a-z0-9_]+\.sql$'::text));

alter table public._migraciones add constraint _migraciones_tipo CHECK ((tipo = ANY (ARRAY['esquema'::text, 'datos'::text])));

alter table public.avisos add constraint avisos_destinatario_check CHECK ((destinatario = ANY (ARRAY['cliente'::text, 'tecnico'::text])));

alter table public.avisos add constraint avisos_estado_check CHECK ((estado = ANY (ARRAY['pendiente'::text, 'enviado'::text, 'descartado'::text])));

alter table public.avisos add constraint avisos_tipo_check CHECK ((tipo = ANY (ARRAY['confirmacion'::text, 'reprogramacion'::text, 'cancelacion'::text, 'recordatorio'::text])));

alter table public.campana_envios add constraint campana_envios_estado_check CHECK ((estado = ANY (ARRAY['propuesto'::text, 'en_tanda'::text, 'aprobado'::text, 'omitido'::text])));

alter table public.campana_envios add constraint campana_envios_mes_check CHECK ((mes ~ '^\d{4}-\d{2}$'::text));

alter table public.campana_tandas add constraint campana_tandas_estado_check CHECK ((estado = ANY (ARRAY['propuesta'::text, 'aprobada'::text, 'cancelada'::text])));

alter table public.campana_tandas add constraint campana_tandas_mes_check CHECK ((mes ~ '^\d{4}-\d{2}$'::text));

alter table public.cfdi add constraint cfdi_estado_sat_check CHECK ((estado_sat = ANY (ARRAY['no_verificado'::text, 'vigente'::text, 'cancelado'::text])));

alter table public.cfdi add constraint cfdi_sentido_check CHECK ((sentido = ANY (ARRAY['emitido'::text, 'recibido'::text])));

alter table public.cfdi add constraint cfdi_tipo_comprobante_check CHECK ((tipo_comprobante = ANY (ARRAY['I'::text, 'E'::text, 'P'::text, 'N'::text, 'T'::text])));

alter table public.cfdi add constraint cfdi_uuid_fiscal_check CHECK ((uuid_fiscal ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'::text));

alter table public.citas add constraint citas_fecha_segun_estado CHECK (((fecha IS NOT NULL) OR (estado = ANY (ARRAY['por_programar'::text, 'cancelada'::text]))));

alter table public.cola_revision add constraint cola_revision_estado_check CHECK ((estado = ANY (ARRAY['pendiente'::text, 'aprobada'::text, 'rechazada'::text])));

alter table public.cola_revision add constraint cola_revision_tipo_check CHECK ((tipo = ANY (ARRAY['cambio_precio'::text, 'precio_inicial'::text, 'sku_desaparecido'::text, 'sin_regla'::text, 'sin_costo'::text])));

alter table public.compra_lineas add constraint compra_lineas_cantidad_check CHECK ((cantidad > (0)::numeric));

alter table public.compra_lineas add constraint compra_lineas_costo_unitario_check CHECK ((costo_unitario >= (0)::numeric));

alter table public.compras add constraint compras_estado_check CHECK ((estado = ANY (ARRAY['registrada'::text, 'cancelada'::text])));

alter table public.conversaciones add constraint conversaciones_estado_check CHECK ((estado = ANY (ARRAY['abierta'::text, 'cerrada'::text])));

alter table public.conversaciones add constraint conversaciones_sin_leer_check CHECK ((sin_leer >= 0));

alter table public.cotizaciones add constraint cotizaciones_cobranza_estado_check CHECK ((cobranza_estado = ANY (ARRAY['pendiente'::text, 'parcial'::text, 'liquidada'::text])));

alter table public.cuentas_financieras add constraint cuentas_financieras_tipo_check CHECK ((tipo = ANY (ARRAY['banco'::text, 'efectivo'::text, 'tarjeta'::text, 'otra'::text])));

alter table public.cuentas_financieras add constraint cuentas_financieras_ultimos4_check CHECK (((ultimos4 IS NULL) OR (ultimos4 ~ '^[0-9]{4}$'::text)));

alter table public.documentos add constraint documentos_estado_check CHECK ((estado = ANY (ARRAY['pendiente'::text, 'propuesto'::text, 'aprobado'::text, 'rechazado'::text])));

alter table public.documentos add constraint documentos_metodo_check CHECK ((metodo = ANY (ARRAY['xml'::text, 'ia'::text, 'manual'::text])));

alter table public.documentos add constraint documentos_tipo_check CHECK ((tipo = ANY (ARRAY['cfdi_xml'::text, 'factura_pdf'::text, 'ticket'::text, 'estado_cuenta'::text, 'comprobante_cobro'::text, 'otro'::text])));

alter table public.empresa_fiscal add constraint empresa_fiscal_cp_expedicion_check CHECK (((cp_expedicion IS NULL) OR (cp_expedicion ~ '^[0-9]{5}$'::text)));

alter table public.empresa_fiscal add constraint empresa_fiscal_id_check CHECK (id);

alter table public.empresa_fiscal add constraint empresa_fiscal_rfc_check CHECK (((rfc IS NULL) OR (rfc ~ '^[A-ZÑ&]{3,4}[0-9]{6}[A-Z0-9]{3}$'::text)));

alter table public.entrega_lineas add constraint entrega_lineas_cantidad_check CHECK ((cantidad > (0)::numeric));

alter table public.entregas add constraint entregas_estado_check CHECK ((estado = ANY (ARRAY['pendiente'::text, 'firmada'::text, 'sin_firma'::text, 'cancelada'::text])));

alter table public.equipo_contactos add constraint equipo_contactos_rol_check CHECK ((rol = ANY (ARRAY['responsable'::text, 'encargado'::text, 'administracion'::text, 'solo_avisos'::text])));

alter table public.expediente_movimientos add constraint expediente_categoria_valida CHECK ((categoria = ANY (ARRAY['cobro'::text, 'aportacion'::text, 'otro_ingreso'::text, 'tecnico'::text, 'gasolina'::text, 'vehiculo'::text, 'viaticos'::text, 'otro'::text, 'material'::text, 'herramienta'::text, 'renta'::text, 'servicios'::text, 'software'::text, 'comisiones_bancarias'::text, 'impuestos'::text, 'publicidad'::text, 'pago_proveedor'::text, 'retiro_dueno'::text])));

alter table public.expediente_movimientos add constraint expediente_cobro_con_cotizacion CHECK (((categoria <> 'cobro'::text) OR (cotizacion_id IS NOT NULL)));

alter table public.expediente_movimientos add constraint expediente_iva_no_excede CHECK ((iva <= monto));

alter table public.expediente_movimientos add constraint expediente_movimientos_iva_check CHECK ((iva >= (0)::numeric));

alter table public.expediente_movimientos add constraint expediente_movimientos_monto_check CHECK ((monto > (0)::numeric));

alter table public.expediente_movimientos add constraint expediente_tipo_categoria CHECK (((tipo = 'ingreso'::text) = (categoria = ANY (ARRAY['cobro'::text, 'aportacion'::text, 'otro_ingreso'::text]))));

alter table public.expediente_movimientos add constraint expediente_tipo_valido CHECK ((tipo = ANY (ARRAY['ingreso'::text, 'egreso'::text])));

alter table public.importacion_whatsapp add constraint importacion_whatsapp_estado_check CHECK ((estado = ANY (ARRAY['por_revisar'::text, 'aceptada'::text, 'descartada'::text])));

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

alter table public.pagos_tecnico add constraint pagos_tecnico_estado_check CHECK ((estado = ANY (ARRAY['propuesto'::text, 'aprobado'::text, 'pagado'::text, 'cancelado'::text])));

alter table public.pagos_tecnico add constraint pagos_tecnico_periodo CHECK ((periodo_hasta >= periodo_desde));

alter table public.pagos_tecnico_lineas add constraint pagos_linea_servicio_con_orden CHECK (((clase = 'servicio'::text) = (orden_id IS NOT NULL)));

alter table public.pagos_tecnico_lineas add constraint pagos_linea_servicio_positiva CHECK (((clase = 'ajuste'::text) OR (monto >= (0)::numeric)));

alter table public.pagos_tecnico_lineas add constraint pagos_tecnico_lineas_clase_check CHECK ((clase = ANY (ARRAY['servicio'::text, 'ajuste'::text])));

alter table public.pagos_tecnico_lineas add constraint pagos_tecnico_lineas_rol_check CHECK ((rol = ANY (ARRAY['responsable'::text, 'ayudante'::text])));

alter table public.paquete_lineas add constraint paquete_linea_apunta_a_algo CHECK (((producto_id IS NOT NULL) OR (grupo IS NOT NULL)));

alter table public.paquete_lineas add constraint paquete_lineas_cantidad_check CHECK ((cantidad > (0)::numeric));

alter table public.paquetes_mantenimiento add constraint paquetes_mantenimiento_tipo_check CHECK ((tipo = ANY (ARRAY['menor'::text, 'mayor'::text])));

alter table public.parametros_costeo add constraint parametros_costeo_valor_check CHECK ((valor >= (0)::numeric));

alter table public.proveedor_productos add constraint proveedor_productos_costo_check CHECK (((costo IS NULL) OR (costo >= (0)::numeric)));

alter table public.proveedor_productos add constraint proveedor_productos_moneda_check CHECK ((moneda = ANY (ARRAY['MXN'::text, 'USD'::text])));

alter table public.reglas_margen add constraint reglas_margen_margen_minimo_mxn_check CHECK ((margen_minimo_mxn >= (0)::numeric));

alter table public.reglas_margen add constraint reglas_margen_margen_pct_check CHECK ((margen_pct >= (0)::numeric));

alter table public.reglas_margen add constraint reglas_margen_precio_bajo_100 CHECK (((sobre <> 'precio'::text) OR (margen_pct < (100)::numeric)));

alter table public.reglas_margen add constraint reglas_margen_redondeo_check CHECK ((redondeo > (0)::numeric));

alter table public.reglas_margen add constraint reglas_margen_sobre_valido CHECK ((sobre = ANY (ARRAY['costo'::text, 'precio'::text])));

alter table public.requisiciones add constraint requisiciones_cantidad_check CHECK ((cantidad > (0)::numeric));

alter table public.requisiciones add constraint requisiciones_estado_check CHECK ((estado = ANY (ARRAY['pendiente'::text, 'pedida'::text, 'recibida'::text, 'cancelada'::text])));

alter table public.salida_wa add constraint salida_wa_categoria_check CHECK ((categoria = ANY (ARRAY['utilidad'::text, 'marketing'::text, 'servicio'::text])));

alter table public.salida_wa add constraint salida_wa_estado_check CHECK ((estado = ANY (ARRAY['por_aprobar'::text, 'pendiente'::text, 'enviando'::text, 'enviado'::text, 'entregado'::text, 'leido'::text, 'fallido'::text, 'cancelado'::text, 'sin_confirmar'::text])));

alter table public.salida_wa add constraint salida_wa_origen_check CHECK ((origen = ANY (ARRAY['aviso'::text, 'orden'::text, 'respuesta'::text, 'campana'::text])));

alter table public.salida_wa add constraint salida_wa_tipo_check CHECK ((tipo = ANY (ARRAY['texto'::text, 'plantilla'::text])));

alter table public.solicitudes_material add constraint solicitudes_material_cantidad_check CHECK ((cantidad > (0)::numeric));

alter table public.solicitudes_material add constraint solicitudes_material_check CHECK (((producto_id IS NOT NULL) OR (NULLIF(TRIM(BOTH FROM COALESCE(descripcion_libre, ''::text)), ''::text) IS NOT NULL)));

alter table public.solicitudes_material add constraint solicitudes_material_estado_check CHECK ((estado = ANY (ARRAY['pendiente'::text, 'atendida'::text, 'descartada'::text])));

alter table public.solicitudes_web add constraint solicitudes_web_estado_check CHECK ((estado = ANY (ARRAY['nueva'::text, 'atendida'::text, 'descartada'::text])));

alter table public.sync_corridas add constraint sync_corridas_estado_check CHECK ((estado = ANY (ARRAY['leyendo'::text, 'leida'::text, 'aplicada'::text, 'fallida'::text])));

alter table public.tarifas_pago_tecnico add constraint tarifas_pago_tecnico_monto_check CHECK ((monto >= (0)::numeric));

alter table public.tarifas_pago_tecnico add constraint tarifas_pago_tecnico_rol_check CHECK ((rol = ANY (ARRAY['responsable'::text, 'ayudante'::text])));

alter table public.tarifas_pago_tecnico add constraint tarifas_pago_tecnico_tipo_servicio_check CHECK ((tipo_servicio = ANY (ARRAY['preventivo'::text, 'correctivo'::text, 'instalacion'::text, 'diagnostico'::text, 'visita_tecnica'::text])));

alter table public.tarifas_pago_tecnico add constraint tarifas_pago_vigencia CHECK (((vigente_hasta IS NULL) OR (vigente_hasta >= vigente_desde)));

alter table public.tarifas_servicio add constraint tarifas_servicio_concepto_ok CHECK ((concepto = ANY (ARRAY['diagnostico'::text, 'traslado'::text, 'correctivo'::text, 'preventivo'::text, 'preventivo_menor'::text, 'preventivo_mayor'::text, 'instalacion_gas'::text, 'instalacion_electrica'::text, 'otro'::text])));

alter table public.tarifas_servicio add constraint tarifas_servicio_nombre_si_otro CHECK (((concepto <> 'otro'::text) OR (NULLIF(TRIM(BOTH FROM COALESCE(nombre, ''::text)), ''::text) IS NOT NULL)));

alter table public.tarifas_servicio add constraint tarifas_servicio_precio_check CHECK ((precio >= (0)::numeric));

alter table public.tarifas_servicio add constraint tarifas_servicio_sku_si_catalogo CHECK (((concepto = ANY (ARRAY['diagnostico'::text, 'traslado'::text])) OR (NULLIF(TRIM(BOTH FROM COALESCE(sku, ''::text)), ''::text) IS NOT NULL)));

alter table public.tecnicos_pago add constraint tecnicos_pago_cuenta_ultimos4_check CHECK (((cuenta_ultimos4 IS NULL) OR (cuenta_ultimos4 ~ '^[0-9]{4}$'::text)));

alter table public.tecnicos_pago add constraint tecnicos_pago_esquema_pago_check CHECK ((esquema_pago = ANY (ARRAY['por_servicio'::text, 'fijo'::text, 'comision'::text, 'mixto'::text])));

alter table public.tipos_cambio add constraint tipos_cambio_valor_check CHECK ((valor > (0)::numeric));

alter table public.wa_agente add constraint wa_agente_id_check CHECK (id);

alter table public.wa_agente add constraint wa_agente_modo_check CHECK ((modo = ANY (ARRAY['borrador'::text, 'automatico'::text])));

alter table public.wa_agente add constraint wa_agente_tope_dia_check CHECK ((tope_dia > 0));

alter table public.wa_config add constraint wa_config_dias_entre_marketing_check CHECK ((dias_entre_marketing > 0));

alter table public.wa_config add constraint wa_config_id_check CHECK (id);

alter table public.wa_plantillas add constraint wa_plantillas_categoria_check CHECK ((categoria = ANY (ARRAY['utilidad'::text, 'marketing'::text])));

alter table public.wa_plantillas add constraint wa_plantillas_encabezado_check CHECK ((encabezado = ANY (ARRAY['ninguno'::text, 'documento'::text])));

alter table public.wa_plantillas add constraint wa_plantillas_estado_check CHECK ((estado = ANY (ARRAY['borrador'::text, 'en_revision'::text, 'aprobada'::text, 'rechazada'::text])));

alter table public.avisos add constraint avisos_cita_id_fkey FOREIGN KEY (cita_id) REFERENCES citas(id) ON DELETE CASCADE;

alter table public.avisos add constraint avisos_contacto_id_fkey FOREIGN KEY (contacto_id) REFERENCES contactos(id) ON DELETE SET NULL;

alter table public.avisos add constraint avisos_perfil_id_fkey FOREIGN KEY (perfil_id) REFERENCES perfiles(id) ON DELETE SET NULL;

alter table public.campana_envios add constraint campana_envios_plantilla_fkey FOREIGN KEY (plantilla) REFERENCES wa_plantillas(nombre);

alter table public.campana_envios add constraint campana_envios_salida_id_fkey FOREIGN KEY (salida_id) REFERENCES salida_wa(id) ON DELETE SET NULL;

alter table public.campana_envios add constraint campana_envios_tanda_id_fkey FOREIGN KEY (tanda_id) REFERENCES campana_tandas(id) ON DELETE SET NULL;

alter table public.cfdi add constraint cfdi_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES clientes(id);

alter table public.cfdi add constraint cfdi_compra_id_fkey FOREIGN KEY (compra_id) REFERENCES compras(id);

alter table public.cfdi add constraint cfdi_cotizacion_id_fkey FOREIGN KEY (cotizacion_id) REFERENCES cotizaciones(id);

alter table public.cfdi add constraint cfdi_documento_fk FOREIGN KEY (documento_id) REFERENCES documentos(id) ON DELETE SET NULL;

alter table public.citas add constraint citas_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES clientes(id);

alter table public.citas add constraint citas_cotizacion_id_fkey FOREIGN KEY (cotizacion_id) REFERENCES cotizaciones(id);

alter table public.citas add constraint citas_equipo_id_fkey FOREIGN KEY (equipo_id) REFERENCES equipos(id);

alter table public.citas add constraint citas_tecnico2_id_fkey FOREIGN KEY (tecnico2_id) REFERENCES perfiles(id);

alter table public.citas add constraint citas_tecnico_id_fkey FOREIGN KEY (tecnico_id) REFERENCES perfiles(id);

alter table public.cola_revision add constraint cola_revision_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES productos(id) ON DELETE CASCADE;

alter table public.compra_lineas add constraint compra_lineas_compra_id_fkey FOREIGN KEY (compra_id) REFERENCES compras(id) ON DELETE CASCADE;

alter table public.compra_lineas add constraint compra_lineas_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES productos(id);

alter table public.compra_lineas add constraint compra_lineas_requisicion_id_fkey FOREIGN KEY (requisicion_id) REFERENCES requisiciones(id);

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

alter table public.documentos add constraint documentos_cfdi_id_fkey FOREIGN KEY (cfdi_id) REFERENCES cfdi(id);

alter table public.documentos add constraint documentos_movimiento_id_fkey FOREIGN KEY (movimiento_id) REFERENCES expediente_movimientos(id) ON DELETE SET NULL;

alter table public.entrega_lineas add constraint entrega_lineas_entrega_id_fkey FOREIGN KEY (entrega_id) REFERENCES entregas(id) ON DELETE CASCADE;

alter table public.entrega_lineas add constraint entrega_lineas_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES productos(id);

alter table public.entregas add constraint entregas_entregado_por_fkey FOREIGN KEY (entregado_por) REFERENCES perfiles(id);

alter table public.entregas add constraint entregas_orden_id_fkey FOREIGN KEY (orden_id) REFERENCES ordenes_servicio(id);

alter table public.entregas add constraint entregas_recibido_por_fkey FOREIGN KEY (recibido_por) REFERENCES perfiles(id);

alter table public.envios_orden add constraint envios_orden_orden_id_fkey FOREIGN KEY (orden_id) REFERENCES ordenes_servicio(id);

alter table public.equipo_contactos add constraint equipo_contactos_contacto_id_fkey FOREIGN KEY (contacto_id) REFERENCES contactos(id) ON DELETE CASCADE;

alter table public.equipo_contactos add constraint equipo_contactos_equipo_id_fkey FOREIGN KEY (equipo_id) REFERENCES equipos(id) ON DELETE CASCADE;

alter table public.equipos add constraint equipos_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES clientes(id) ON DELETE RESTRICT;

alter table public.expediente_movimientos add constraint expediente_movimientos_cfdi_id_fkey FOREIGN KEY (cfdi_id) REFERENCES cfdi(id);

alter table public.expediente_movimientos add constraint expediente_movimientos_compra_id_fkey FOREIGN KEY (compra_id) REFERENCES compras(id);

alter table public.expediente_movimientos add constraint expediente_movimientos_cotizacion_id_fkey FOREIGN KEY (cotizacion_id) REFERENCES cotizaciones(id) ON DELETE CASCADE;

alter table public.expediente_movimientos add constraint expediente_movimientos_cuenta_id_fkey FOREIGN KEY (cuenta_id) REFERENCES cuentas_financieras(id);

alter table public.expediente_movimientos add constraint expediente_movimientos_documento_id_fkey FOREIGN KEY (documento_id) REFERENCES documentos(id) ON DELETE SET NULL;

alter table public.expediente_movimientos add constraint expediente_movimientos_tecnico_id_fkey FOREIGN KEY (tecnico_id) REFERENCES perfiles(id);

alter table public.historial_precios add constraint historial_precios_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES productos(id) ON DELETE CASCADE;

alter table public.importacion_whatsapp add constraint importacion_whatsapp_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES clientes(id) ON DELETE SET NULL;

alter table public.importacion_whatsapp add constraint importacion_whatsapp_contacto_id_fkey FOREIGN KEY (contacto_id) REFERENCES contactos(id) ON DELETE SET NULL;

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

alter table public.pagos_tecnico add constraint pagos_tecnico_tecnico_id_fkey FOREIGN KEY (tecnico_id) REFERENCES perfiles(id);

alter table public.pagos_tecnico_lineas add constraint pagos_tecnico_lineas_cotizacion_id_fkey FOREIGN KEY (cotizacion_id) REFERENCES cotizaciones(id);

alter table public.pagos_tecnico_lineas add constraint pagos_tecnico_lineas_orden_id_fkey FOREIGN KEY (orden_id) REFERENCES ordenes_servicio(id);

alter table public.pagos_tecnico_lineas add constraint pagos_tecnico_lineas_pago_id_fkey FOREIGN KEY (pago_id) REFERENCES pagos_tecnico(id) ON DELETE CASCADE;

alter table public.pagos_tecnico_lineas add constraint pagos_tecnico_lineas_tecnico_id_fkey FOREIGN KEY (tecnico_id) REFERENCES perfiles(id);

alter table public.paquete_lineas add constraint paquete_lineas_paquete_id_fkey FOREIGN KEY (paquete_id) REFERENCES paquetes_mantenimiento(id) ON DELETE CASCADE;

alter table public.paquete_lineas add constraint paquete_lineas_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES productos(id);

alter table public.perfiles add constraint perfiles_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES clientes(id);

alter table public.perfiles add constraint perfiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;

alter table public.producto_proveedores add constraint producto_proveedores_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES productos(id) ON DELETE CASCADE;

alter table public.reglas_clasificacion add constraint reglas_clasificacion_cuenta_id_fkey FOREIGN KEY (cuenta_id) REFERENCES cuentas_financieras(id) ON DELETE SET NULL;

alter table public.requisiciones add constraint requisiciones_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES clientes(id);

alter table public.requisiciones add constraint requisiciones_cotizacion_id_fkey FOREIGN KEY (cotizacion_id) REFERENCES cotizaciones(id);

alter table public.requisiciones add constraint requisiciones_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES productos(id);

alter table public.salida_wa add constraint salida_wa_conversacion_id_fkey FOREIGN KEY (conversacion_id) REFERENCES conversaciones(id) ON DELETE SET NULL;

alter table public.salida_wa add constraint salida_wa_plantilla_fkey FOREIGN KEY (plantilla) REFERENCES wa_plantillas(nombre);

alter table public.solicitudes_material add constraint solicitudes_material_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES clientes(id) ON DELETE SET NULL;

alter table public.solicitudes_material add constraint solicitudes_material_equipo_id_fkey FOREIGN KEY (equipo_id) REFERENCES equipos(id) ON DELETE SET NULL;

alter table public.solicitudes_material add constraint solicitudes_material_orden_id_fkey FOREIGN KEY (orden_id) REFERENCES ordenes_servicio(id) ON DELETE SET NULL;

alter table public.solicitudes_material add constraint solicitudes_material_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES productos(id);

alter table public.solicitudes_material add constraint solicitudes_material_tecnico_id_fkey FOREIGN KEY (tecnico_id) REFERENCES perfiles(id);

alter table public.solicitudes_web add constraint solicitudes_web_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES clientes(id) ON DELETE SET NULL;

alter table public.tarifas_pago_tecnico add constraint tarifas_pago_tecnico_tecnico_id_fkey FOREIGN KEY (tecnico_id) REFERENCES perfiles(id) ON DELETE CASCADE;

alter table public.tecnicos_pago add constraint tecnicos_pago_perfil_id_fkey FOREIGN KEY (perfil_id) REFERENCES perfiles(id) ON DELETE CASCADE;

-- ========== ÍNDICES ==========

CREATE UNIQUE INDEX IF NOT EXISTS cola_revision_un_pendiente ON public.cola_revision USING btree (tipo, producto_id) WHERE (estado = 'pendiente'::text);

CREATE UNIQUE INDEX IF NOT EXISTS compras_proveedor_factura ON public.compras USING btree (lower(TRIM(BOTH FROM proveedor)), lower(TRIM(BOTH FROM factura))) WHERE ((factura IS NOT NULL) AND (estado <> 'cancelada'::text));

CREATE UNIQUE INDEX IF NOT EXISTS cuentas_financieras_nombre ON public.cuentas_financieras USING btree (lower(nombre));

CREATE INDEX IF NOT EXISTS historial_precios_producto ON public.historial_precios USING btree (producto_id, creado_en DESC);

CREATE INDEX IF NOT EXISTS idx_audit_tabla ON public.auditoria USING btree (tabla, registro_id);

CREATE INDEX IF NOT EXISTS idx_avisos_cita ON public.avisos USING btree (cita_id);

CREATE INDEX IF NOT EXISTS idx_avisos_estado ON public.avisos USING btree (estado) WHERE (estado = 'pendiente'::text);

CREATE INDEX IF NOT EXISTS idx_campana_mes ON public.campana_envios USING btree (mes, estado);

CREATE INDEX IF NOT EXISTS idx_catalogos_tipo ON public.catalogos USING btree (tipo, usos DESC);

CREATE INDEX IF NOT EXISTS idx_cfdi_cotizacion ON public.cfdi USING btree (cotizacion_id);

CREATE INDEX IF NOT EXISTS idx_cfdi_fecha ON public.cfdi USING btree (sentido, fecha);

CREATE INDEX IF NOT EXISTS idx_citas_cliente ON public.citas USING btree (cliente_id);

CREATE INDEX IF NOT EXISTS idx_citas_cotizacion ON public.citas USING btree (cotizacion_id) WHERE (cotizacion_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS idx_citas_fecha ON public.citas USING btree (fecha);

CREATE INDEX IF NOT EXISTS idx_citas_por_programar ON public.citas USING btree (estado) WHERE (estado = 'por_programar'::text);

CREATE INDEX IF NOT EXISTS idx_citas_tecnico ON public.citas USING btree (tecnico_id, fecha);

CREATE INDEX IF NOT EXISTS idx_citas_tecnico2 ON public.citas USING btree (tecnico2_id, fecha) WHERE (tecnico2_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS idx_clientes_geo ON public.clientes USING btree (latitud, longitud);

CREATE INDEX IF NOT EXISTS idx_clientes_nombre ON public.clientes USING btree (nombre);

CREATE INDEX IF NOT EXISTS idx_clientes_zona ON public.clientes USING btree (zona);

CREATE INDEX IF NOT EXISTS idx_compra_lineas_compra ON public.compra_lineas USING btree (compra_id);

CREATE INDEX IF NOT EXISTS idx_compra_lineas_producto ON public.compra_lineas USING btree (producto_id);

CREATE INDEX IF NOT EXISTS idx_contactos_cliente ON public.contactos USING btree (cliente_id) WHERE activo;

CREATE INDEX IF NOT EXISTS idx_contactos_telefono ON public.contactos USING btree (telefono_norm) WHERE activo;

CREATE INDEX IF NOT EXISTS idx_conversaciones_abiertas ON public.conversaciones USING btree (ultimo_mensaje_at DESC) WHERE (estado = 'abierta'::text);

CREATE INDEX IF NOT EXISTS idx_cot_cliente ON public.cotizaciones USING btree (cliente_id);

CREATE INDEX IF NOT EXISTS idx_cot_estado ON public.cotizaciones USING btree (estado);

CREATE INDEX IF NOT EXISTS idx_datos_fiscales_cliente ON public.datos_fiscales USING btree (cliente_id);

CREATE INDEX IF NOT EXISTS idx_datos_fiscales_rfc ON public.datos_fiscales USING btree (rfc);

CREATE INDEX IF NOT EXISTS idx_devoluciones_orden ON public.devoluciones USING btree (orden_id);

CREATE INDEX IF NOT EXISTS idx_documentos_estado ON public.documentos USING btree (estado, created_at DESC);

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

CREATE INDEX IF NOT EXISTS idx_expediente_cfdi ON public.expediente_movimientos USING btree (cfdi_id);

CREATE INDEX IF NOT EXISTS idx_expediente_cot ON public.expediente_movimientos USING btree (cotizacion_id, fecha);

CREATE INDEX IF NOT EXISTS idx_expediente_cuenta ON public.expediente_movimientos USING btree (cuenta_id, fecha);

CREATE INDEX IF NOT EXISTS idx_expediente_fecha ON public.expediente_movimientos USING btree (fecha);

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

CREATE INDEX IF NOT EXISTS idx_pagos_lineas_pago ON public.pagos_tecnico_lineas USING btree (pago_id);

CREATE INDEX IF NOT EXISTS idx_pagos_tecnico_tecnico ON public.pagos_tecnico USING btree (tecnico_id, estado);

CREATE INDEX IF NOT EXISTS idx_paquete_lineas ON public.paquete_lineas USING btree (paquete_id, orden);

CREATE INDEX IF NOT EXISTS idx_perfiles_rol ON public.perfiles USING btree (rol) WHERE activo;

CREATE INDEX IF NOT EXISTS idx_productos_categoria ON public.productos USING btree (categoria) WHERE activo;

CREATE INDEX IF NOT EXISTS idx_productos_grupo_equivalente ON public.productos USING btree (grupo_equivalente) WHERE (grupo_equivalente IS NOT NULL);

CREATE INDEX IF NOT EXISTS idx_productos_sku ON public.productos USING btree (sku);

CREATE INDEX IF NOT EXISTS idx_requisiciones_cotizacion ON public.requisiciones USING btree (cotizacion_id);

CREATE INDEX IF NOT EXISTS idx_requisiciones_estado ON public.requisiciones USING btree (estado);

CREATE INDEX IF NOT EXISTS idx_requisiciones_producto ON public.requisiciones USING btree (producto_id);

CREATE INDEX IF NOT EXISTS idx_salida_wa_pendiente ON public.salida_wa USING btree (programado_para) WHERE (estado = 'pendiente'::text);

CREATE INDEX IF NOT EXISTS idx_salida_wa_tel ON public.salida_wa USING btree (telefono_norm, created_at);

CREATE INDEX IF NOT EXISTS idx_solicitudes_material_estado ON public.solicitudes_material USING btree (estado) WHERE (estado = 'pendiente'::text);

CREATE INDEX IF NOT EXISTS idx_solicitudes_material_orden ON public.solicitudes_material USING btree (orden_id) WHERE (orden_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS idx_solicitudes_material_tecnico ON public.solicitudes_material USING btree (tecnico_id);

CREATE INDEX IF NOT EXISTS idx_solicitudes_web_estado ON public.solicitudes_web USING btree (estado, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_solicitudes_web_telefono ON public.solicitudes_web USING btree (telefono_norm, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS reglas_margen_unica ON public.reglas_margen USING btree (COALESCE(lower(categoria), ''::text), COALESCE(lower(marca), ''::text)) WHERE activo;

CREATE UNIQUE INDEX IF NOT EXISTS tarifas_pago_unica ON public.tarifas_pago_tecnico USING btree (tipo_servicio, rol, COALESCE(tecnico_id, '00000000-0000-0000-0000-000000000000'::uuid), vigente_desde);

CREATE UNIQUE INDEX IF NOT EXISTS un_aviso_pendiente ON public.avisos USING btree (cita_id, llave) WHERE (estado = 'pendiente'::text);

CREATE UNIQUE INDEX IF NOT EXISTS un_campana_mes_tel ON public.campana_envios USING btree (mes, telefono_norm) WHERE (telefono_norm IS NOT NULL);

CREATE UNIQUE INDEX IF NOT EXISTS un_contacto_telefono_por_cliente ON public.contactos USING btree (cliente_id, telefono_norm) WHERE (activo AND (telefono_norm IS NOT NULL));

CREATE UNIQUE INDEX IF NOT EXISTS un_conversaciones_telefono ON public.conversaciones USING btree (telefono_norm) WHERE (telefono_norm IS NOT NULL);

CREATE UNIQUE INDEX IF NOT EXISTS un_importacion_whatsapp_tel ON public.importacion_whatsapp USING btree (telefono_norm) WHERE (telefono_norm IS NOT NULL);

CREATE UNIQUE INDEX IF NOT EXISTS un_mensajes_wa_id ON public.mensajes_wa USING btree (wa_message_id) WHERE (wa_message_id IS NOT NULL);

CREATE UNIQUE INDEX IF NOT EXISTS un_pago_propuesto_por_tecnico ON public.pagos_tecnico USING btree (tecnico_id) WHERE (estado = 'propuesto'::text);

CREATE UNIQUE INDEX IF NOT EXISTS un_responsable_por_equipo ON public.equipo_contactos USING btree (equipo_id) WHERE (rol = 'responsable'::text);

CREATE UNIQUE INDEX IF NOT EXISTS un_tarifas_servicio_sku ON public.tarifas_servicio USING btree (sku) WHERE (sku IS NOT NULL);

CREATE UNIQUE INDEX IF NOT EXISTS una_orden_un_pago_por_tecnico ON public.pagos_tecnico_lineas USING btree (orden_id, tecnico_id) WHERE (activa AND (clase = 'servicio'::text));

CREATE UNIQUE INDEX IF NOT EXISTS ux_ordenes_una_por_cita ON public.ordenes_servicio USING btree (cita_id) WHERE (cita_id IS NOT NULL);

-- ========== VISTAS (con su modo security_invoker) ==========

create or replace view public.catalogo with (security_invoker=off) as
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

create or replace view public.resguardo_por_cliente with (security_invoker=off) as
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

CREATE TRIGGER aviso_a_salida AFTER INSERT OR UPDATE OF estado ON public.avisos FOR EACH ROW EXECUTE FUNCTION _aviso_a_salida();

CREATE TRIGGER avisos_de_cita AFTER INSERT OR UPDATE ON public.citas FOR EACH ROW EXECUTE FUNCTION avisos_de_cita();

CREATE TRIGGER tocar_updated_at BEFORE UPDATE ON public.contactos FOR EACH ROW EXECUTE FUNCTION tocar_updated_at();

CREATE TRIGGER ligar_conversacion_sola BEFORE INSERT ON public.conversaciones FOR EACH ROW EXECUTE FUNCTION _ligar_conversacion_sola();

CREATE TRIGGER cobranza_tras_total AFTER UPDATE OF total ON public.cotizaciones FOR EACH ROW WHEN ((old.total IS DISTINCT FROM new.total)) EXECUTE FUNCTION _cobranza_tras_total();

CREATE TRIGGER cotizacion_cerrada_bloquea BEFORE UPDATE ON public.cotizaciones FOR EACH ROW EXECUTE FUNCTION _cotizacion_cerrada_bloquea();

CREATE TRIGGER tocar_updated_at BEFORE UPDATE ON public.cotizaciones FOR EACH ROW EXECUTE FUNCTION tocar_updated_at();

CREATE TRIGGER cobranza_tras_movimiento AFTER INSERT OR DELETE OR UPDATE ON public.expediente_movimientos FOR EACH ROW EXECUTE FUNCTION _cobranza_tras_movimiento();

CREATE TRIGGER expediente_cerrado_bloquea BEFORE INSERT OR DELETE OR UPDATE ON public.expediente_movimientos FOR EACH ROW EXECUTE FUNCTION _expediente_cerrado_bloquea();

CREATE TRIGGER tocar_updated_at BEFORE UPDATE ON public.orden_partes FOR EACH ROW EXECUTE FUNCTION tocar_updated_at();

CREATE TRIGGER sella_revision BEFORE INSERT OR UPDATE ON public.orden_revision FOR EACH ROW EXECUTE FUNCTION _sella_revision();

CREATE TRIGGER horometro_al_equipo AFTER UPDATE ON public.ordenes_servicio FOR EACH ROW EXECUTE FUNCTION _horometro_al_equipo();

CREATE TRIGGER seguridad_antes_de_cerrar BEFORE UPDATE ON public.ordenes_servicio FOR EACH ROW EXECUTE FUNCTION _seguridad_antes_de_cerrar();

CREATE TRIGGER tocar_updated_at BEFORE UPDATE ON public.ordenes_servicio FOR EACH ROW EXECUTE FUNCTION tocar_updated_at();

CREATE TRIGGER tocar_updated_at BEFORE UPDATE ON public.paquetes_mantenimiento FOR EACH ROW EXECUTE FUNCTION tocar_updated_at();

CREATE TRIGGER espejo_a_vinculos AFTER INSERT OR UPDATE OF proveedor, proveedor_sku ON public.productos FOR EACH ROW EXECUTE FUNCTION _espejo_a_vinculos();

CREATE TRIGGER completar_solicitud_material BEFORE INSERT ON public.solicitudes_material FOR EACH ROW EXECUTE FUNCTION _completar_solicitud_material();

CREATE TRIGGER tocar_updated_at BEFORE UPDATE ON public.tarifas_servicio FOR EACH ROW EXECUTE FUNCTION tocar_updated_at();

-- ========== ROW LEVEL SECURITY ==========

alter table public._migraciones enable row level security;

alter table public.auditoria enable row level security;

alter table public.avisos enable row level security;

alter table public.campana_envios enable row level security;

alter table public.campana_tandas enable row level security;

alter table public.catalogos enable row level security;

alter table public.cfdi enable row level security;

alter table public.citas enable row level security;

alter table public.clientes enable row level security;

alter table public.cola_revision enable row level security;

alter table public.compra_lineas enable row level security;

alter table public.compras enable row level security;

alter table public.contactos enable row level security;

alter table public.conversaciones enable row level security;

alter table public.cotizaciones enable row level security;

alter table public.cuentas_financieras enable row level security;

alter table public.datos_fiscales enable row level security;

alter table public.devoluciones enable row level security;

alter table public.documentos enable row level security;

alter table public.empresa_fiscal enable row level security;

alter table public.entrega_lineas enable row level security;

alter table public.entregas enable row level security;

alter table public.envios_orden enable row level security;

alter table public.equipo_contactos enable row level security;

alter table public.equipos enable row level security;

alter table public.expediente_movimientos enable row level security;

alter table public.historial_precios enable row level security;

alter table public.importacion_whatsapp enable row level security;

alter table public.mensajes_wa enable row level security;

alter table public.movimientos_inventario enable row level security;

alter table public.orden_partes enable row level security;

alter table public.orden_revision enable row level security;

alter table public.orden_surtido enable row level security;

alter table public.ordenes_pdf enable row level security;

alter table public.ordenes_servicio enable row level security;

alter table public.pagos_tecnico enable row level security;

alter table public.pagos_tecnico_lineas enable row level security;

alter table public.paquete_lineas enable row level security;

alter table public.paquetes_mantenimiento enable row level security;

alter table public.parametros_costeo enable row level security;

alter table public.perfiles enable row level security;

alter table public.producto_proveedores enable row level security;

alter table public.productos enable row level security;

alter table public.proveedor_productos enable row level security;

alter table public.reglas_clasificacion enable row level security;

alter table public.reglas_margen enable row level security;

alter table public.requisiciones enable row level security;

alter table public.salida_wa enable row level security;

alter table public.solicitudes_material enable row level security;

alter table public.solicitudes_web enable row level security;

alter table public.sync_corridas enable row level security;

alter table public.tarifas_pago_tecnico enable row level security;

alter table public.tarifas_servicio enable row level security;

alter table public.tecnicos_pago enable row level security;

alter table public.tipos_cambio enable row level security;

alter table public.wa_agente enable row level security;

alter table public.wa_bajas enable row level security;

alter table public.wa_config enable row level security;

alter table public.wa_plantillas enable row level security;

-- ========== POLÍTICAS ==========

create policy admin_lee_migraciones on public._migraciones as permissive for select to authenticated using (es_admin());

create policy admin_lee_auditoria on public.auditoria as permissive for select to authenticated using (es_admin());

create policy admin_avisos on public.avisos as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_campana_envios on public.campana_envios as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_campana_tandas on public.campana_tandas as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_catalogos on public.catalogos as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy lee_catalogos on public.catalogos as permissive for select to authenticated using (true);

create policy admin_cfdi_cambia on public.cfdi as permissive for update to authenticated using (es_admin()) with check (es_admin());

create policy admin_cfdi_inserta on public.cfdi as permissive for insert to authenticated with check (es_admin());

create policy admin_cfdi_lee on public.cfdi as permissive for select to authenticated using (es_admin());

create policy admin_citas on public.citas as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy cliente_ve_sus_citas on public.citas as permissive for select to authenticated using (((mi_rol() = 'cliente'::text) AND (cliente_id = mi_cliente())));

create policy tecnico2_ve_sus_citas on public.citas as permissive for select to authenticated using (((mi_rol() = 'tecnico'::text) AND (tecnico2_id = auth.uid())));

create policy tecnico_ve_sus_citas on public.citas as permissive for select to authenticated using (((mi_rol() = 'tecnico'::text) AND (tecnico_id = auth.uid())));

create policy admin_clientes on public.clientes as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy cliente_ve_lo_suyo on public.clientes as permissive for select to authenticated using (((mi_rol() = 'cliente'::text) AND (id = mi_cliente())));

create policy tecnico_lee_clientes on public.clientes as permissive for select to authenticated using ((mi_rol() = 'tecnico'::text));

create policy admin_cola_revision on public.cola_revision as permissive for select to authenticated using (es_admin());

create policy admin_compra_lineas on public.compra_lineas as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_compras on public.compras as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_contactos on public.contactos as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_conversaciones on public.conversaciones as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_cotizaciones on public.cotizaciones as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy cliente_ve_sus_cotizaciones on public.cotizaciones as permissive for select to authenticated using (((mi_rol() = 'cliente'::text) AND (cliente_id = mi_cliente())));

create policy admin_cuentas on public.cuentas_financieras as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_datos_fiscales on public.datos_fiscales as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_devoluciones on public.devoluciones as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_doc_cambia on public.documentos as permissive for update to authenticated using (es_admin()) with check (es_admin());

create policy admin_doc_inserta on public.documentos as permissive for insert to authenticated with check (es_admin());

create policy admin_doc_lee on public.documentos as permissive for select to authenticated using (es_admin());

create policy admin_empresa_fiscal on public.empresa_fiscal as permissive for all to authenticated using (es_admin()) with check (es_admin());

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

create policy admin_expediente on public.expediente_movimientos as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_historial_precios on public.historial_precios as permissive for select to authenticated using (es_admin());

create policy admin_importacion_whatsapp on public.importacion_whatsapp as permissive for all to authenticated using (es_admin()) with check (es_admin());

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

create policy admin_pagos_tecnico on public.pagos_tecnico as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_pagos_lineas on public.pagos_tecnico_lineas as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_paquete_lineas on public.paquete_lineas as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_paquetes on public.paquetes_mantenimiento as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_parametros_costeo on public.parametros_costeo as permissive for select to authenticated using (es_admin());

create policy admin_edita_perfiles on public.perfiles as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy ve_su_perfil on public.perfiles as permissive for select to authenticated using (((id = auth.uid()) OR es_admin()));

create policy admin_producto_proveedores on public.producto_proveedores as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_productos on public.productos as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_proveedor_productos on public.proveedor_productos as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_reglas on public.reglas_clasificacion as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_reglas_margen on public.reglas_margen as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_requisiciones on public.requisiciones as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_salida_wa on public.salida_wa as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_solicitudes_material on public.solicitudes_material as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy almacen_lee_solicitudes_material on public.solicitudes_material as permissive for select to authenticated using (COALESCE((mi_rol() = 'almacenista'::text), false));

create policy tecnico_cancela_su_solicitud_material on public.solicitudes_material as permissive for update to authenticated using (((mi_rol() = 'tecnico'::text) AND (tecnico_id = auth.uid()) AND (estado = 'pendiente'::text))) with check (((mi_rol() = 'tecnico'::text) AND (tecnico_id = auth.uid()) AND (estado = ANY (ARRAY['pendiente'::text, 'descartada'::text])) AND ((orden_id IS NULL) OR soy_de_la_orden(orden_id))));

create policy tecnico_crea_solicitud_material on public.solicitudes_material as permissive for insert to authenticated with check (((mi_rol() = 'tecnico'::text) AND (tecnico_id = auth.uid()) AND ((orden_id IS NULL) OR soy_de_la_orden(orden_id))));

create policy tecnico_lee_solicitudes_material on public.solicitudes_material as permissive for select to authenticated using (((mi_rol() = 'tecnico'::text) AND ((tecnico_id = auth.uid()) OR ((orden_id IS NOT NULL) AND soy_de_la_orden(orden_id)))));

create policy admin_solicitudes_web on public.solicitudes_web as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_sync_corridas on public.sync_corridas as permissive for select to authenticated using (es_admin());

create policy admin_tarifas_pago on public.tarifas_pago_tecnico as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_tarifas_servicio on public.tarifas_servicio as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_tecnicos_pago on public.tecnicos_pago as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_tipos_cambio on public.tipos_cambio as permissive for select to authenticated using (es_admin());

create policy admin_wa_agente on public.wa_agente as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy bot_lee_wa_agente on public.wa_agente as permissive for select to authenticated using (_es_bot_o_admin());

create policy admin_wa_bajas on public.wa_bajas as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_wa_config on public.wa_config as permissive for all to authenticated using (es_admin()) with check (es_admin());

create policy admin_wa_plantillas on public.wa_plantillas as permissive for all to authenticated using (es_admin()) with check (es_admin());

-- ========== PERMISOS ==========

grant select on public._migraciones to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public._migraciones to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.auditoria to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.auditoria to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.avisos to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.avisos to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.campana_envios to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.campana_envios to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.campana_tandas to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.campana_tandas to service_role;

grant select on public.catalogo to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.catalogo to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.catalogos to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.catalogos to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.cfdi to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.cfdi to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.citas to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.citas to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.clientes to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.clientes to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.cola_revision to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.cola_revision to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.compra_lineas to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.compra_lineas to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.compras to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.compras to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.contactos to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.contactos to service_role;

grant select on public.contactos_por_equipo to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.contactos_por_equipo to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.conversaciones to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.conversaciones to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.cotizaciones to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.cotizaciones to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.cuentas_financieras to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.cuentas_financieras to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.datos_fiscales to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.datos_fiscales to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.devoluciones to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.devoluciones to service_role;

grant select on public.disponibles to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.disponibles to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.documentos to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.documentos to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.empresa_fiscal to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.empresa_fiscal to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.entrega_lineas to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.entrega_lineas to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.entregas to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.entregas to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.envios_orden to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.envios_orden to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.equipo_contactos to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.equipo_contactos to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.equipos to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.equipos to service_role;

grant select on public.existencias to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.existencias to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.expediente_movimientos to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.expediente_movimientos to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.historial_precios to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.historial_precios to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.importacion_whatsapp to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.importacion_whatsapp to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.mensajes_wa to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.mensajes_wa to service_role;

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

grant delete, insert, references, select, trigger, truncate, update on public.ordenes_servicio to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.ordenes_servicio to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.pagos_tecnico to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.pagos_tecnico to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.pagos_tecnico_lineas to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.pagos_tecnico_lineas to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.paquete_lineas to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.paquete_lineas to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.paquetes_mantenimiento to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.paquetes_mantenimiento to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.parametros_costeo to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.parametros_costeo to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.perfiles to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.perfiles to service_role;

grant select on public.por_reordenar to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.por_reordenar to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.producto_proveedores to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.producto_proveedores to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.productos to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.productos to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.proveedor_productos to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.proveedor_productos to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.reglas_clasificacion to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.reglas_clasificacion to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.reglas_margen to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.reglas_margen to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.requisiciones to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.requisiciones to service_role;

grant select on public.resguardo_por_cliente to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.resguardo_por_cliente to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.salida_wa to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.salida_wa to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.solicitudes_material to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.solicitudes_material to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.solicitudes_web to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.solicitudes_web to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.sync_corridas to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.sync_corridas to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.tarifas_pago_tecnico to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.tarifas_pago_tecnico to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.tarifas_servicio to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.tarifas_servicio to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.tecnicos_pago to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.tecnicos_pago to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.tipos_cambio to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.tipos_cambio to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.wa_agente to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.wa_agente to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.wa_bajas to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.wa_bajas to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.wa_config to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.wa_config to service_role;

grant delete, insert, references, select, trigger, truncate, update on public.wa_plantillas to authenticated;

grant delete, insert, references, select, trigger, truncate, update on public.wa_plantillas to service_role;

-- ========== LO REVOCADO (no se ve en un grant) ==========

revoke all on public._migraciones from anon;

revoke all on public.auditoria from anon;

revoke all on public.avisos from anon;

revoke all on public.campana_envios from anon;

revoke all on public.campana_tandas from anon;

revoke all on public.catalogo from anon;

revoke all on public.catalogos from anon;

revoke all on public.cfdi from anon;

revoke all on public.citas from anon;

revoke all on public.clientes from anon;

revoke all on public.cola_revision from anon;

revoke all on public.compra_lineas from anon;

revoke all on public.compras from anon;

revoke all on public.contactos from anon;

revoke all on public.contactos_por_equipo from anon;

revoke all on public.conversaciones from anon;

revoke all on public.cotizaciones from anon;

revoke all on public.cuentas_financieras from anon;

revoke all on public.datos_fiscales from anon;

revoke all on public.devoluciones from anon;

revoke all on public.disponibles from anon;

revoke all on public.documentos from anon;

revoke all on public.empresa_fiscal from anon;

revoke all on public.entrega_lineas from anon;

revoke all on public.entregas from anon;

revoke all on public.envios_orden from anon;

revoke all on public.equipo_contactos from anon;

revoke all on public.equipos from anon;

revoke all on public.existencias from anon;

revoke all on public.expediente_movimientos from anon;

revoke all on public.historial_precios from anon;

revoke all on public.importacion_whatsapp from anon;

revoke all on public.mensajes_wa from anon;

revoke all on public.movimientos_inventario from anon;

revoke all on public.orden_partes from anon;

revoke all on public.orden_revision from anon;

revoke all on public.orden_surtido from anon;

revoke all on public.ordenes_pdf from anon;

revoke all on public.ordenes_servicio from anon;

revoke all on public.pagos_tecnico from anon;

revoke all on public.pagos_tecnico_lineas from anon;

revoke all on public.paquete_lineas from anon;

revoke all on public.paquetes_mantenimiento from anon;

revoke all on public.parametros_costeo from anon;

revoke all on public.perfiles from anon;

revoke all on public.por_reordenar from anon;

revoke all on public.producto_proveedores from anon;

revoke all on public.productos from anon;

revoke all on public.proveedor_productos from anon;

revoke all on public.reglas_clasificacion from anon;

revoke all on public.reglas_margen from anon;

revoke all on public.requisiciones from anon;

revoke all on public.resguardo_por_cliente from anon;

revoke all on public.salida_wa from anon;

revoke all on public.solicitudes_material from anon;

revoke all on public.solicitudes_web from anon;

revoke all on public.sync_corridas from anon;

revoke all on public.tarifas_pago_tecnico from anon;

revoke all on public.tarifas_servicio from anon;

revoke all on public.tecnicos_pago from anon;

revoke all on public.tipos_cambio from anon;

revoke all on public.wa_agente from anon;

revoke all on public.wa_bajas from anon;

revoke all on public.wa_config from anon;

revoke all on public.wa_plantillas from anon;

revoke execute on function public._aplicar_entrega(p_entrega uuid, p_estado text, p_firma text, p_motivo text) from public;

revoke execute on function public._aplicar_precio(p_producto uuid, p_calc jsonb, p_origen text, p_corrida uuid, p_tc numeric) from public;

revoke execute on function public._apunta(p_tabla text, p_registro uuid, p_accion text, p_antes jsonb, p_despues jsonb, p_origen text) from public;

revoke execute on function public._aviso_a_salida() from public;

revoke execute on function public._calcular_precio(p_producto uuid, p_tc numeric) from public;

revoke execute on function public._cancelar_avisos(p_cita uuid, p_solo_tecnicos_fuera boolean) from public;

revoke execute on function public._categoria_crm(p_categoria_proveedor text) from public;

revoke execute on function public._cliente_de_conversacion(p_conversacion uuid) from public;

revoke execute on function public._cobranza_tras_movimiento() from public;

revoke execute on function public._cobranza_tras_total() from public;

revoke execute on function public._codigos_de_linea(p_linea uuid) from public;

revoke execute on function public._completar_solicitud_material() from public;

revoke execute on function public._contactos_de_aviso(p_cita uuid) from public;

revoke execute on function public._encolar(p_tipo text, p_producto uuid, p_sku text, p_detalle jsonb, p_corrida uuid) from public;

revoke execute on function public._encolar_avisos(p_cita uuid, p_tipo text) from public;

revoke execute on function public._es_almacen() from public;

revoke execute on function public._es_bot_o_admin() from public;

revoke execute on function public._espejo_a_vinculos() from public;

revoke execute on function public._fijar_componente(p_equipo uuid, p_rol text, p_datos jsonb, p_ruta text, p_origen text) from public;

revoke execute on function public._ligar_conversacion_sola() from public;

revoke execute on function public._marketing_reciente(p_norm text) from public;

revoke execute on function public._ordenar_proveedores(p_producto uuid, p_calc jsonb) from public;

revoke execute on function public._paquete_de_equipo(p_equipo uuid, p_tipo text) from public;

revoke execute on function public._precio_promocion(p_producto uuid, p_calc jsonb) from public;

revoke execute on function public._precio_traslado(p_cliente uuid) from public;

revoke execute on function public._precio_venta(p_costo_mxn numeric, p_regla reglas_margen) from public;

revoke execute on function public._preparar_surtido(p_orden uuid) from public;

revoke execute on function public._recalcular_cobranza(p_cotizacion uuid) from public;

revoke execute on function public._recalcular_pago_tecnico(p_pago uuid) from public;

revoke execute on function public._regla_margen(p_categoria text, p_marca text) from public;

revoke execute on function public._sku_crm(p_proveedor text, p_sku text) from public;

revoke execute on function public._tarifa_pago_tecnico(p_tecnico uuid, p_tipo text, p_rol text, p_fecha date) from public;

revoke execute on function public._tipo_para(p_cita uuid, p_llave text, p_tipo text) from public;

revoke execute on function public._variables_aviso(p_aviso uuid) from public;

revoke execute on function public.aceptar_importacion_whatsapp(p_id uuid, p_cliente uuid) from public;

revoke execute on function public.activar_precio_automatico(p_proveedor text, p_categoria text) from public;

revoke execute on function public.actualizar_componente(p_equipo uuid, p_rol text, p_datos jsonb, p_origen text) from public;

revoke execute on function public.adicionales_por_conciliar() from public;

revoke execute on function public.agendar_cita(p_cliente uuid, p_equipo uuid, p_tipo text, p_fecha date, p_hora time without time zone, p_duracion integer, p_t1 uuid, p_t2 uuid, p_zona text, p_notas text, p_cotizacion uuid, p_nueva_cotizacion jsonb, p_confirmar boolean) from public;

revoke execute on function public.ajustar_pago_tecnico(p_pago uuid, p_concepto text, p_monto numeric) from public;

revoke execute on function public.aprobar_documento(p_documento uuid, p_datos jsonb) from public;

revoke execute on function public.aprobar_pago_tecnico(p_pago uuid) from public;

revoke execute on function public.aprobar_salida(p_ids uuid[]) from public;

revoke execute on function public.aprobar_tanda(p_tanda uuid) from public;

revoke execute on function public.atender_solicitud_material(p_id uuid, p_resolucion text) from public;

revoke execute on function public.avisos_pendientes() from public;

revoke execute on function public.bandeja_whatsapp(p_incluir_cerradas boolean) from public;

revoke execute on function public.cambiar_estado_cotizacion(p_id uuid, p_nuevo text, p_forzar boolean) from public;

revoke execute on function public.cambiar_estado_requisicion(p_id uuid, p_nuevo text, p_proveedor text, p_referencia text) from public;

revoke execute on function public.cancelar_cita(p_cita uuid) from public;

revoke execute on function public.cancelar_compra(p_compra uuid, p_motivo text) from public;

revoke execute on function public.cancelar_entrega(p_entrega uuid) from public;

revoke execute on function public.cancelar_pago_tecnico(p_pago uuid, p_motivo text) from public;

revoke execute on function public.cancelar_salida(p_ids uuid[], p_motivo text) from public;

revoke execute on function public.cancelar_tanda(p_tanda uuid) from public;

revoke execute on function public.catalogo_publico() from public;

revoke execute on function public.cerrar_conversacion(p_conversacion uuid, p_abrir boolean) from public;

revoke execute on function public.cerrar_expediente(p_cotizacion uuid, p_forzar boolean) from public;

revoke execute on function public.cerrar_orden(p_orden uuid, p_firma text, p_sin_firma boolean, p_horas numeric, p_observaciones text, p_recomendaciones text, p_seguimiento boolean, p_fecha_seguimiento date, p_refacciones jsonb, p_uso jsonb) from public;

revoke execute on function public.cola_whatsapp() from public;

revoke execute on function public.compras_recientes(p_dias integer) from public;

revoke execute on function public.conciliar_adicional(p_orden uuid, p_nota text) from public;

revoke execute on function public.crear_entrega(p_orden uuid, p_lineas jsonb) from public;

revoke execute on function public.descartar_importacion_whatsapp(p_id uuid, p_motivo text) from public;

revoke execute on function public.descartar_solicitud_material(p_id uuid, p_motivo text) from public;

revoke execute on function public.devoluciones_pendientes() from public;

revoke execute on function public.eliminar_cotizacion(p_cotizacion uuid, p_ejecutar boolean) from public;

revoke execute on function public.empalmes_de(p_fecha date, p_hora time without time zone, p_dur integer, p_t1 uuid, p_t2 uuid, p_excluir uuid) from public;

revoke execute on function public.encolar_orden(p_envio uuid) from public;

revoke execute on function public.entregar_sin_firma(p_entrega uuid, p_motivo text) from public;

revoke execute on function public.equipo_de_orden(p_orden uuid, p_equipo uuid) from public;

revoke execute on function public.equipos_sin_serie() from public;

revoke execute on function public.expediente_resumen(p_cotizacion uuid) from public;

revoke execute on function public.fijar_parametro_costeo(p_clave text, p_valor numeric) from public;

revoke execute on function public.fijar_surtido(p_orden uuid, p_producto uuid, p_cantidad numeric) from public;

revoke execute on function public.firmar_entrega(p_entrega uuid, p_firma text) from public;

revoke execute on function public.generar_recordatorios() from public;

revoke execute on function public.guardar_placa(p_orden uuid, p_rol text, p_ruta text, p_datos jsonb) from public;

revoke execute on function public.identificar_telefono(p_telefono text) from public;

revoke execute on function public.importar_productos_proveedor(p_proveedor text, p_categorias text[]) from public;

revoke execute on function public.inicio_admin() from public;

revoke execute on function public.ligar_cfdi_cotizacion(p_cfdi uuid, p_cotizacion uuid) from public;

revoke execute on function public.liquidar_cobranza(p_cotizacion uuid, p_motivo text) from public;

revoke execute on function public.lista_tecnicos() from public;

revoke execute on function public.marcar_aviso(p_id uuid, p_estado text, p_canal text) from public;

revoke execute on function public.marcar_conversacion_leida(p_conversacion uuid) from public;

revoke execute on function public.marcar_salida(p_id uuid, p_ok boolean, p_wa_message_id text, p_error text, p_temporal boolean) from public;

revoke execute on function public.mis_comisiones(p_dias integer) from public;

revoke execute on function public.ordenes_por_surtir() from public;

revoke execute on function public.paquete_preventivo(p_equipo uuid, p_tipo text) from public;

revoke execute on function public.pedidos_por_recibir() from public;

revoke execute on function public.pendientes_admin() from public;

revoke execute on function public.piezas_que_se_repiten(p_clase text, p_kw_desde numeric, p_kw_hasta numeric, p_marca text, p_modelo text, p_desde date) from public;

revoke execute on function public.por_pagar_tecnicos(p_hasta date) from public;

revoke execute on function public.programar_cita(p_cita uuid, p_fecha date, p_hora time without time zone, p_duracion integer, p_t1 uuid, p_t2 uuid, p_confirmar boolean) from public;

revoke execute on function public.proponer_pago_tecnico(p_tecnico uuid, p_desde date, p_hasta date) from public;

revoke execute on function public.proponer_tanda(p_mes text, p_n integer) from public;

revoke execute on function public.proveedor_resumen(p_proveedor text) from public;

revoke execute on function public.quitar_baja(p_telefono text) from public;

revoke execute on function public.quitar_de_tanda(p_ids uuid[], p_omitir boolean, p_motivo text) from public;

revoke execute on function public.quitar_linea_pago_tecnico(p_linea uuid) from public;

revoke execute on function public.quitar_producto(p_producto uuid) from public;

revoke execute on function public.reabrir_cobranza(p_cotizacion uuid) from public;

revoke execute on function public.reabrir_expediente(p_cotizacion uuid, p_motivo text) from public;

revoke execute on function public.rechazar_documento(p_documento uuid, p_motivo text) from public;

revoke execute on function public.recibir_devolucion(p_orden uuid, p_lineas jsonb, p_observaciones text) from public;

revoke execute on function public.registrar_baja(p_telefono text, p_origen text, p_nota text) from public;

revoke execute on function public.registrar_cfdi(p_datos jsonb, p_archivo text, p_documento uuid) from public;

revoke execute on function public.registrar_compra(p_datos jsonb, p_lineas jsonb) from public;

revoke execute on function public.registrar_compra_de_factura(p_datos jsonb, p_lineas jsonb) from public;

revoke execute on function public.registrar_documento(p_tipo text, p_archivo text, p_nombre text, p_mime text, p_hash text, p_metodo text, p_extraido jsonb, p_validaciones jsonb) from public;

revoke execute on function public.registrar_equipo_en_orden(p_orden uuid, p_datos jsonb) from public;

revoke execute on function public.registrar_estado_wa(p_wa_message_id text, p_estado text, p_error text) from public;

revoke execute on function public.registrar_mensaje_entrante(p_telefono text, p_wa_message_id text, p_texto text, p_nombre_wa text, p_tipo text, p_media_id text, p_wa_timestamp timestamp with time zone) from public;

revoke execute on function public.registrar_mensaje_saliente(p_conversacion uuid, p_texto text, p_wa_message_id text, p_estado text) from public;

revoke execute on function public.registrar_pago_tecnico(p_pago uuid, p_forma text, p_referencia text, p_fecha date, p_archivo text, p_cuenta uuid) from public;

revoke execute on function public.registrar_solicitud_web(p_nombre text, p_telefono text, p_email text, p_ubicacion text, p_tipos text, p_uso text, p_equipo_actual text, p_consumo text, p_presupuesto text, p_plazo text, p_fuente text, p_notas text, p_origen_url text) from public;

revoke execute on function public.resolver_diferencia(p_orden uuid, p_producto uuid, p_motivo text) from public;

revoke execute on function public.resolver_revision(p_id uuid, p_aprobar boolean, p_nota text) from public;

revoke execute on function public.resolver_revisiones(p_tipo text, p_aprobar boolean) from public;

revoke execute on function public.resolver_solicitud_web(p_id uuid, p_estado text, p_nota text, p_cliente uuid) from public;

revoke execute on function public.responder_whatsapp(p_conversacion uuid, p_texto text, p_borrador uuid) from public;

revoke execute on function public.resultados_campana(p_mes text) from public;

revoke execute on function public.solicitudes_material_pendientes() from public;

revoke execute on function public.sugerir_cotizaciones_para_cfdi(p_cfdi uuid) from public;

revoke execute on function public.surtido_desde_paquete(p_orden uuid, p_tipo text) from public;

revoke execute on function public.sync_aplicar(p_corrida uuid, p_tipo_cambio numeric, p_tc_fecha date, p_tc_fuente text, p_umbral_pct numeric) from public;

revoke execute on function public.sync_cerrar_lectura(p_corrida uuid) from public;

revoke execute on function public.sync_iniciar(p_proveedor text, p_fuente text) from public;

revoke execute on function public.sync_recibir_lote(p_corrida uuid, p_filas jsonb) from public;

revoke execute on function public.sync_registrar_error(p_corrida uuid, p_error text) from public;

revoke execute on function public.texto_aviso(p_aviso uuid) from public;

revoke execute on function public.tomar_salida(p_n integer) from public;

revoke execute on function public.vincular_contacto(p_equipo uuid, p_contacto uuid, p_rol text, p_pedir_citas boolean, p_ordenes boolean, p_cotizaciones boolean) from public;

revoke execute on function public.vincular_conversacion(p_conversacion uuid, p_contacto uuid) from public;

revoke execute on function public.vincular_producto_proveedor(p_producto uuid, p_proveedor text, p_sku text, p_precio_auto boolean) from public;

revoke execute on function public.wa_contexto(p_conversacion uuid) from public;

revoke execute on function public.wa_cotizar_preventivo(p_conversacion uuid, p_equipo uuid, p_tipo text) from public;

revoke execute on function public.wa_puede_responder(p_conversacion uuid) from public;

revoke execute on function public.wa_solicitar_cita(p_conversacion uuid, p_equipo uuid, p_tipo text, p_nota text) from public;
