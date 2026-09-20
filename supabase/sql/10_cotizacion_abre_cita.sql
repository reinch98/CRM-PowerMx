-- ===========================================================================
-- FLUJO DE SERVICIO · FASE 1b · UNA COTIZACIÓN ACEPTADA ABRE CITA Y ORDEN
--
-- Reemplaza la función de 08_requisiciones.sql (que a su vez reemplazó a la de 07).
-- Además de apartar inventario y generar requisiciones, ahora:
--
--  ACEPTAR una cotización que requiere visita (instalación, mantenimiento o
--  diagnóstico; o venta, refacciones y renta si marcaron `requiere_visita`):
--    · Si ya tiene una cita activa ligada (nació de una cita en la Agenda), se
--      usa ESA; no se abre otra.
--    · Si no, se abre una cita con la programación propuesta (prog_*). Sin fecha,
--      la cita queda `por_programar`.
--    · Cada cita tiene UNA orden (`abierta`), con los mismos técnicos.
--
--  SALIR de "aceptada", o pasar a rechazada/vencida: se cancelan las citas activas
--  ligadas y sus órdenes, SOLO si nadie ha capturado trabajo en ellas. Si ya hay
--  trabajo, no se toca nada y se avisa.
--
-- Se puede volver a ejecutar sin problema.
-- ===========================================================================

create or replace function cambiar_estado_cotizacion(
  p_id uuid,
  p_nuevo text,
  p_forzar boolean default false     -- sin efecto; se conserva por compatibilidad
) returns jsonb
language plpgsql
set search_path = public
as $$
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
    insert into movimientos_inventario
      (producto_id, tipo, cantidad, cliente_id, cotizacion_id, referencia, notas, usuario)
    select (p ->> 'producto_id')::uuid, 'libera_apartado', (p ->> 'cantidad')::numeric,
           c.cliente_id, c.id, 'COT-' || c.folio,
           'Liberado: la cotización pasó a ' || p_nuevo, quien
    from jsonb_array_elements(coalesce(c.partidas, '[]'::jsonb)) p
    where nullif(p ->> 'producto_id', '') is not null
      and (p ->> 'cantidad')::numeric > 0;
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
                              or exists (select 1 from orden_partes op where op.orden_id = o.id)))
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
$$;

revoke all on function cambiar_estado_cotizacion(uuid, text, boolean) from public, anon;
grant execute on function cambiar_estado_cotizacion(uuid, text, boolean) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- PRUEBA (begin/rollback SÍ deshace; solo se ve el resultado de la ÚLTIMA sentencia,
-- por eso cada paso se guarda con set_config). Correr SIEMPRE el bloque completo.
--
-- Necesitas: el uuid de un admin, el uuid de una cotización en BORRADOR de tipo
-- instalacion, mantenimiento o diagnostico (o con requiere_visita), y opcionalmente
-- dos uuid de técnicos para probarlos como T1 y T2.
--
--   begin;
--   set local role authenticated;
--   select set_config('request.jwt.claims',
--     json_build_object('sub', '<UUID-ADMIN>', 'role', 'authenticated',
--                       'email', 'prueba@powermx')::text, true);
--
--   -- (opcional) darle programación propuesta a la cotización
--   update cotizaciones set prog_fecha = current_date + 3, prog_hora = '09:00',
--          prog_duracion_min = 120, prog_tecnico_id = '<UUID-T1>', prog_tecnico2_id = '<UUID-T2>'
--    where id = '<UUID-COTIZACION>';
--
--   select set_config('app.a', cambiar_estado_cotizacion('<UUID-COTIZACION>', 'aceptada')::text, true);
--   select set_config('app.b', (select coalesce(jsonb_agg(jsonb_build_object(
--       'cita_estado', ci.estado, 'fecha', ci.fecha, 'origen', ci.origen,
--       'orden_estado', o.estado, 'orden_folio', o.folio, 'tecnico2', ci.tecnico2_id is not null)),
--       '[]'::jsonb)::text
--     from citas ci left join ordenes_servicio o on o.cita_id = ci.id
--     where ci.cotizacion_id = '<UUID-COTIZACION>'), true);
--   select set_config('app.c', cambiar_estado_cotizacion('<UUID-COTIZACION>', 'rechazada')::text, true);
--   select set_config('app.d', (select coalesce(jsonb_agg(jsonb_build_object(
--       'cita_estado', ci.estado, 'orden_estado', o.estado)), '[]'::jsonb)::text
--     from citas ci left join ordenes_servicio o on o.cita_id = ci.id
--     where ci.cotizacion_id = '<UUID-COTIZACION>'), true);
--
--   select current_setting('app.a')::jsonb as aceptar,   -- cita_nueva true, orden_folio, cita_estado
--          current_setting('app.b')::jsonb as visita,    -- 1 cita 'programada' (o 'por_programar') + orden 'abierta'
--          current_setting('app.c')::jsonb as rechazar,  -- citas_canceladas = 1
--          current_setting('app.d')::jsonb as despues;   -- cita 'cancelada' y orden 'cancelada'
--   rollback;
-- ---------------------------------------------------------------------------
