-- ===========================================================================
-- REQUISICIONES DE PEDIDO
--
-- Al aceptar una cotización, lo que no alcanza en almacén se manda a
-- Requisiciones en vez de solo preguntar "¿aceptar de todos modos?". La
-- cotización se acepta igual y aparta lo que hay; lo que falta queda como una
-- línea por producto, ligada a la cotización, para pedirlo al proveedor.
--
-- Ciclo:   pendiente → pedida → recibida        (o cancelada)
-- Al marcar RECIBIDA se registra solo el movimiento `entrada` en el inventario,
-- en la misma operación: no se captura dos veces.
--
-- Reemplaza la función de 07_cotizacion_estado.sql (ya no pregunta ni devuelve
-- faltantes para confirmar: acepta y genera la requisición). El parámetro
-- p_forzar se conserva sin efecto para que el CRM anterior no truene mientras
-- se publica el nuevo. Al correr los scripts en orden (07, 08) queda esta versión.
--
-- Se puede volver a ejecutar sin problema.
-- ===========================================================================

create table if not exists requisiciones (
  id uuid primary key default gen_random_uuid(),
  folio bigint generated always as identity unique,
  producto_id uuid not null references productos(id),
  cotizacion_id uuid references cotizaciones(id),
  cliente_id uuid references clientes(id),
  cantidad numeric not null check (cantidad > 0),          -- lo que hay que pedir
  estado text not null default 'pendiente'
    check (estado in ('pendiente', 'pedida', 'recibida', 'cancelada')),
  proveedor text,
  referencia text,                                          -- orden de compra o pedido
  notas text,
  fecha_pedido date,
  fecha_recibida date,
  movimiento_id uuid,                                       -- la entrada que generó al recibirse
  creada_por text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_requisiciones_estado on requisiciones(estado);
create index if not exists idx_requisiciones_cotizacion on requisiciones(cotizacion_id);
create index if not exists idx_requisiciones_producto on requisiciones(producto_id);

alter table requisiciones enable row level security;

drop policy if exists "admin_requisiciones" on requisiciones;
create policy "admin_requisiciones" on requisiciones for all to authenticated
  using (es_admin()) with check (es_admin());

revoke all on requisiciones from anon;

-- ---------------------------------------------------------------------------
-- Cambio de estado de la COTIZACIÓN (versión con requisiciones)
-- ---------------------------------------------------------------------------
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
  faltantes jsonb := '[]'::jsonb;
  n_mov int := 0;
  n_req int := 0;
  n_canc int := 0;
  n_curso int := 0;
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
    -- 1) Requisiciones por lo que falta. Se calcula ANTES de apartar: el
    --    disponible todavía no incluye esta cotización.
    --    Faltante = lo que pide menos lo disponible (si el disponible ya está en
    --    negativo por otra cotización, no se resta nada: falta todo). Se descuenta
    --    lo que esta misma cotización ya tenga pedido y sin recibir, para que
    --    aceptar de nuevo no duplique la requisición.
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

    -- Lo que aún no se pide deja de hacer falta. Lo que ya se pidió al
    -- proveedor NO se cancela solo: el pedido existe; se avisa para que lo revises.
    update requisiciones
       set estado = 'cancelada',
           notas = coalesce(notas || E'\n', '') || 'Cancelada: la cotización COT-' || c.folio || ' pasó a ' || p_nuevo,
           updated_at = now()
     where cotizacion_id = c.id and estado = 'pendiente';
    get diagnostics n_canc = row_count;

    select count(*) into n_curso
      from requisiciones where cotizacion_id = c.id and estado = 'pedida';
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
    'requisiciones_en_curso', n_curso
  );
end;
$$;

revoke all on function cambiar_estado_cotizacion(uuid, text, boolean) from public, anon;
grant execute on function cambiar_estado_cotizacion(uuid, text, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Cambio de estado de una REQUISICIÓN
--   pendiente → pedida      (proveedor y referencia opcionales)
--   pendiente | pedida → recibida   (registra la entrada al inventario)
--   pendiente | pedida → cancelada
-- Recibida y cancelada son finales: un error se corrige con un movimiento
-- (ajuste), como en el resto del inventario.
-- Se recibe siempre la cantidad completa; una entrega parcial se resuelve
-- registrando la entrada real en Inventario y cancelando esta línea.
-- ---------------------------------------------------------------------------
create or replace function cambiar_estado_requisicion(
  p_id uuid,
  p_nuevo text,
  p_proveedor text default null,
  p_referencia text default null
) returns jsonb
language plpgsql
set search_path = public
as $$
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
$$;

revoke all on function cambiar_estado_requisicion(uuid, text, text, text) from public, anon;
grant execute on function cambiar_estado_requisicion(uuid, text, text, text) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- PRUEBA (en el editor de Supabase). begin/rollback SÍ deshace los cambios, pero
-- solo se ve el resultado de la ÚLTIMA sentencia: por eso cada paso se guarda con
-- set_config y se lee al final. Correr SIEMPRE el bloque completo.
--
-- Necesitas: el uuid de una cuenta admin y el de una cotización en BORRADOR con un
-- producto de existencia CERO o menor a lo que pide (para que falte algo).
--
--   begin;
--   set local role authenticated;
--   select set_config('request.jwt.claims',
--     json_build_object('sub', '<UUID-ADMIN>', 'role', 'authenticated',
--                       'email', 'prueba@powermx')::text, true);
--
--   select set_config('app.a', cambiar_estado_cotizacion('<UUID-COTIZACION>', 'aceptada')::text, true);
--   select set_config('app.b', (select coalesce(jsonb_agg(jsonb_build_object(
--       'folio', folio, 'cantidad', cantidad, 'estado', estado)), '[]'::jsonb)::text
--       from requisiciones where cotizacion_id = '<UUID-COTIZACION>'), true);
--   select set_config('app.c', cambiar_estado_requisicion(
--       (select id from requisiciones where cotizacion_id = '<UUID-COTIZACION>' limit 1),
--       'pedida', 'Proveedor de prueba', 'OC-1')::text, true);
--   select set_config('app.d', cambiar_estado_requisicion(
--       (select id from requisiciones where cotizacion_id = '<UUID-COTIZACION>' limit 1),
--       'recibida')::text, true);
--   select set_config('app.e', cambiar_estado_cotizacion('<UUID-COTIZACION>', 'rechazada')::text, true);
--
--   select current_setting('app.a')::jsonb as aceptar,        -- requisiciones > 0 y la lista faltantes
--          current_setting('app.b')::jsonb as requisiciones,  -- estado pendiente
--          current_setting('app.c')::jsonb as pedir,          -- estado pedida
--          current_setting('app.d')::jsonb as recibir,        -- movimiento_id lleno
--          current_setting('app.e')::jsonb as rechazar,       -- movimientos = partidas, canceladas 0
--          (select coalesce(jsonb_agg(jsonb_build_object('tipo', tipo, 'cantidad', cantidad)), '[]'::jsonb)
--             from movimientos_inventario where cotizacion_id = '<UUID-COTIZACION>'
--               or referencia like 'REQ-%') as movimientos;
--   rollback;
--
-- Esperado: aceptar genera requisiciones; pedir y recibir cambian su estado; al
-- recibir aparece un movimiento `entrada` con referencia REQ-n; al rechazar se
-- libera el apartado.
-- ---------------------------------------------------------------------------
