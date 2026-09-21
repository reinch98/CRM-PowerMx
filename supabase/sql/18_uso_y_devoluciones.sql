-- ===========================================================================
-- FLUJO DE SERVICIO · FASE 3a · USO DE MATERIAL, CIERRE Y DEVOLUCIONES
--
-- Cierra el ciclo del almacén (14): el técnico responsable (T1) recibió material; al cerrar la
-- orden declara cuánto USÓ. Lo usado sale del inventario (`consumo_tecnico`, custodia −). Lo
-- que NO usó queda como PENDIENTE DE DEVOLUCIÓN: el almacenista lo recibe (`devolucion_tecnico`:
-- físico +, custodia −), con una caja de observaciones si no se devuelve todo.
--
--   · `orden_surtido` gana cantidad_usada, cantidad_devuelta y cantidad_diferencia.
--       pendiente de devolución = entregada − usada − devuelta − diferencia
--     No hay tabla aparte: se deriva. Aparecen las órdenes CERRADAS o CANCELADAS con pendiente
--     (una cita cancelada con material entregado ya no es un hueco: el material vuelve por aquí).
--   · `cerrar_orden` recibe `p_uso` ([{producto_id, usadas}]) y registra el consumo. Un cierre
--     repetido no hace nada. Lo que el técnico usó y NO le entregaron va en `p_refacciones`; se
--     marca "adicional" y "por conciliar" (sin descuento automático: el costo al cliente es
--     prácticamente fijo).
--   · `devoluciones_pendientes()`, `recibir_devolucion()`: almacén y admin. Si se devuelve menos
--     de lo pendiente, hay que escribir una observación.
--   · `resolver_diferencia()`: SOLO admin. Lo que nunca volvió se da por consumido (queda
--     escrito el motivo); el material sale del inventario como `consumo_tecnico`.
--   · `adicionales_por_conciliar()` y `conciliar_adicional()`: almacén y admin.
--
-- Orden de despliegue: primero este SQL, después el código. Se puede repetir sin tronar.
-- Prueba: 18_prueba_uso_y_devoluciones.sql (termina en rollback).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Columnas
-- ---------------------------------------------------------------------------
alter table orden_surtido
  add column if not exists cantidad_usada numeric not null default 0 check (cantidad_usada >= 0),
  add column if not exists cantidad_devuelta numeric not null default 0 check (cantidad_devuelta >= 0),
  add column if not exists cantidad_diferencia numeric not null default 0 check (cantidad_diferencia >= 0);

-- Nunca puede haber más usado, devuelto o dado por perdido que lo que se entregó.
alter table orden_surtido drop constraint if exists orden_surtido_uso_no_excede;
alter table orden_surtido add constraint orden_surtido_uso_no_excede
  check (cantidad_usada + cantidad_devuelta + cantidad_diferencia <= cantidad_entregada);

-- ---------------------------------------------------------------------------
-- 2. Devoluciones recibidas (para las observaciones y el historial)
-- ---------------------------------------------------------------------------
create table if not exists devoluciones (
  id uuid primary key default gen_random_uuid(),
  folio bigint generated always as identity unique,
  orden_id uuid not null references ordenes_servicio(id),
  recibida_por uuid references perfiles(id),
  observaciones text,
  lineas jsonb not null default '[]'::jsonb,        -- [{producto_id, sku, nombre, cantidad}]
  created_at timestamptz not null default now()
);
create index if not exists idx_devoluciones_orden on devoluciones(orden_id);

alter table devoluciones enable row level security;
revoke all on devoluciones from anon;
drop policy if exists "admin_devoluciones" on devoluciones;
create policy "admin_devoluciones" on devoluciones for all to authenticated
  using (es_admin()) with check (es_admin());

-- ---------------------------------------------------------------------------
-- 3. cerrar_orden con uso de material
--    (reemplaza a la de 12_cerrar_orden.sql; se borra la firma anterior para que PostgREST no
--    encuentre dos funciones con el mismo nombre. Las llamadas viejas, sin p_uso, siguen sirviendo.)
-- ---------------------------------------------------------------------------
drop function if exists cerrar_orden(uuid, text, boolean, numeric, text, text, boolean, date, jsonb);

create or replace function cerrar_orden(
  p_orden uuid,
  p_firma text,                          -- ruta de la firma en el bucket `ordenes`
  p_sin_firma boolean default false,     -- el cliente no pudo o no quiso firmar
  p_horas numeric default null,          -- horómetro
  p_observaciones text default null,
  p_recomendaciones text default null,
  p_seguimiento boolean default false,
  p_fecha_seguimiento date default null,
  p_refacciones jsonb default null,      -- material usado que NO entregó el almacén: [{descripcion, cantidad}]
  p_uso jsonb default null               -- material entregado que SÍ usó: [{producto_id, usadas}]
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
$$;

revoke all on function cerrar_orden(uuid, text, boolean, numeric, text, text, boolean, date, jsonb, jsonb) from public, anon;
grant execute on function cerrar_orden(uuid, text, boolean, numeric, text, text, boolean, date, jsonb, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Devoluciones pendientes y recibirlas
-- ---------------------------------------------------------------------------

-- Órdenes cerradas o canceladas con material que el técnico aún debe devolver.
create or replace function devoluciones_pendientes() returns jsonb
language plpgsql stable security definer set search_path = public as $$
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
end $$;

-- El almacenista recibe material que el técnico devuelve.
-- p_lineas: [{"producto_id": "...", "cantidad": 1}]. Si algo pendiente no se devuelve completo,
-- hay que escribir una observación (por ejemplo "faltó 1 filtro").
create or replace function recibir_devolucion(p_orden uuid, p_lineas jsonb, p_observaciones text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
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
end $$;

-- SOLO admin: lo pendiente que nunca volvió se da por consumido, con el motivo escrito.
create or replace function resolver_diferencia(p_orden uuid, p_producto uuid, p_motivo text)
returns jsonb
language plpgsql security definer set search_path = public as $$
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
end $$;

-- ---------------------------------------------------------------------------
-- 5. Adicionales: lo que el técnico usó y NO le entregaron
-- ---------------------------------------------------------------------------
create or replace function adicionales_por_conciliar() returns jsonb
language plpgsql stable security definer set search_path = public as $$
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
end $$;

-- Marca como conciliados los adicionales de una orden (con una nota: "ya se repuso", "se cobró aparte"…).
create or replace function conciliar_adicional(p_orden uuid, p_nota text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
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
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'devoluciones_pendientes()', 'recibir_devolucion(uuid, jsonb, text)',
    'resolver_diferencia(uuid, uuid, text)', 'adicionales_por_conciliar()', 'conciliar_adicional(uuid, text)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

notify pgrst, 'reload schema';

-- Verificación: las columnas nuevas, la tabla con RLS y UNA sola cerrar_orden.
select 'orden_surtido.cantidad_usada' as que,
       exists (select 1 from information_schema.columns
                where table_name = 'orden_surtido' and column_name = 'cantidad_usada')::text as ok
union all
select 'rls devoluciones', relrowsecurity::text from pg_class where relname = 'devoluciones'
union all
select 'funciones cerrar_orden (debe ser 1)', count(*)::text from pg_proc where proname = 'cerrar_orden';
