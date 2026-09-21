-- ===========================================================================
-- FLUJO DE SERVICIO · FASE 2a · ALMACÉN: LISTA DE SURTIDO Y ENTREGA AL TÉCNICO
--
-- El almacenista prepara una entrega de material para una orden; T1 (el técnico
-- responsable) la recibe y FIRMA en su celular dentro del almacén. Hasta que se
-- firma no se mueve el inventario. Al firmar, lo entregado sale del estante y pasa
-- a "custodia del técnico": sigue siendo de la empresa, pero ya no cuenta como
-- físico ni como disponible. El técnico nunca ve precios ni costos.
--
--   · Rol nuevo `almacenista` (no requiere cambio de esquema: `perfiles.rol` es texto).
--     No lee tablas directamente: trabaja con las funciones de abajo.
--   · `orden_surtido`: lista de piezas de una orden (se arma sola con las piezas del
--     catálogo de la cotización aceptada; se puede agregar o ajustar a mano).
--   · `entregas` y `entrega_lineas`: cada entrega, su firma y sus piezas.
--   · Movimientos nuevos (`movimientos_inventario.tipo` es texto libre, sin `check`):
--       entrega_tecnico    físico −, custodia +        (al firmar la entrega)
--       devolucion_tecnico físico +, custodia −        (fase 3)
--       consumo_tecnico    custodia −                  (fase 3)
--     La entrega además registra `libera_apartado` por lo entregado de la cotización.
--   · `existencias` gana la columna `en_custodia` y el rol `almacenista`.
--   · CAMBIA `cambiar_estado_cotizacion`: al sacar una cotización de "aceptada" libera
--     solo lo que aún queda apartado (antes liberaba toda la partida: con material ya
--     entregado habría inflado el disponible). Y una cita con material entregado cuenta
--     como "con trabajo": no se cancela sola.
--
-- Orden de despliegue: primero este SQL, después el código. Se puede repetir sin tronar.
-- Prueba: 14_prueba_almacen.sql (termina en rollback).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Columnas nuevas en movimientos
-- ---------------------------------------------------------------------------
alter table movimientos_inventario
  add column if not exists orden_id uuid references ordenes_servicio(id),
  add column if not exists tecnico_id uuid references perfiles(id);

create index if not exists idx_mov_orden on movimientos_inventario(orden_id) where orden_id is not null;

-- ---------------------------------------------------------------------------
-- 2. Tablas
-- ---------------------------------------------------------------------------
create table if not exists orden_surtido (
  id uuid primary key default gen_random_uuid(),
  orden_id uuid not null references ordenes_servicio(id) on delete cascade,
  producto_id uuid not null references productos(id),
  sku text,                                  -- copias de lo que había al armar la lista:
  nombre text,                               -- el técnico las lee sin tocar `productos`
  unidad text,
  cantidad_pedida numeric not null check (cantidad_pedida > 0),
  cantidad_entregada numeric not null default 0 check (cantidad_entregada >= 0),
  origen text not null default 'cotizacion', -- cotizacion | manual
  cotizacion_id uuid references cotizaciones(id),
  created_at timestamptz not null default now(),
  unique (orden_id, producto_id)
);
create index if not exists idx_orden_surtido_orden on orden_surtido(orden_id);

create table if not exists entregas (
  id uuid primary key default gen_random_uuid(),
  folio bigint generated always as identity unique,
  orden_id uuid not null references ordenes_servicio(id),
  entregado_por uuid references perfiles(id),      -- el almacenista
  recibido_por uuid references perfiles(id),       -- T1 de la orden al crearla
  estado text not null default 'pendiente'
    check (estado in ('pendiente', 'firmada', 'sin_firma', 'cancelada')),
  firma_ruta text,                                 -- en el bucket `ordenes`: entregas/<id>.png
  motivo_sin_firma text,
  notas text,
  created_at timestamptz not null default now(),
  entregada_at timestamptz
);
create index if not exists idx_entregas_orden on entregas(orden_id);
create index if not exists idx_entregas_estado on entregas(estado) where estado = 'pendiente';

create table if not exists entrega_lineas (
  id uuid primary key default gen_random_uuid(),
  entrega_id uuid not null references entregas(id) on delete cascade,
  producto_id uuid not null references productos(id),
  sku text,
  nombre text,
  unidad text,
  cantidad numeric not null check (cantidad > 0)
);
create index if not exists idx_entrega_lineas_entrega on entrega_lineas(entrega_id);

-- ---------------------------------------------------------------------------
-- 3. RLS: admin todo; el técnico de la orden (T1 o T2) solo lee. El almacenista no
--    lee tablas: todo pasa por las funciones (security definer).
-- ---------------------------------------------------------------------------
alter table orden_surtido  enable row level security;
alter table entregas       enable row level security;
alter table entrega_lineas enable row level security;
revoke all on orden_surtido, entregas, entrega_lineas from anon;

drop policy if exists "admin_orden_surtido" on orden_surtido;
create policy "admin_orden_surtido" on orden_surtido for all to authenticated
  using (es_admin()) with check (es_admin());
drop policy if exists "tecnico_lee_su_surtido" on orden_surtido;
create policy "tecnico_lee_su_surtido" on orden_surtido for select to authenticated
  using (soy_de_la_orden(orden_id));

drop policy if exists "admin_entregas" on entregas;
create policy "admin_entregas" on entregas for all to authenticated
  using (es_admin()) with check (es_admin());
drop policy if exists "tecnico_lee_sus_entregas" on entregas;
create policy "tecnico_lee_sus_entregas" on entregas for select to authenticated
  using (soy_de_la_orden(orden_id));

drop policy if exists "admin_entrega_lineas" on entrega_lineas;
create policy "admin_entrega_lineas" on entrega_lineas for all to authenticated
  using (es_admin()) with check (es_admin());
drop policy if exists "tecnico_lee_lineas_de_sus_entregas" on entrega_lineas;
create policy "tecnico_lee_lineas_de_sus_entregas" on entrega_lineas for select to authenticated
  using (exists (select 1 from entregas e where e.id = entrega_id and soy_de_la_orden(e.orden_id)));

-- ---------------------------------------------------------------------------
-- 4. Existencias: columna `en_custodia` y rol almacenista.
--    (`disponibles` es `select *` de existencias tal como estaba: no cambia y sigue
--    siendo físico − apartado − resguardo. Lo entregado ya salió del físico.)
-- ---------------------------------------------------------------------------
create or replace view existencias as
select p.id,
    p.sku,
    p.categoria,
    p.nombre,
    p.marca,
    p.unidad,
    p.minimo,
    coalesce(sum(
        case m.tipo
            when 'entrada'::text then m.cantidad
            when 'salida_venta'::text then (- m.cantidad)
            when 'consumo_resguardo'::text then (- m.cantidad)
            when 'consumo_servicio'::text then (- m.cantidad)
            when 'ajuste'::text then m.cantidad
            when 'entrega_tecnico'::text then (- m.cantidad)
            when 'devolucion_tecnico'::text then m.cantidad
            else (0)::numeric
        end), (0)::numeric) as fisico,
    coalesce(sum(
        case m.tipo
            when 'apartado'::text then m.cantidad
            when 'libera_apartado'::text then (- m.cantidad)
            when 'salida_venta'::text then (- m.cantidad)
            when 'a_resguardo'::text then (- m.cantidad)
            else (0)::numeric
        end), (0)::numeric) as apartado,
    coalesce(sum(
        case m.tipo
            when 'a_resguardo'::text then m.cantidad
            when 'consumo_resguardo'::text then (- m.cantidad)
            else (0)::numeric
        end), (0)::numeric) as resguardo,
    coalesce(sum(
        case m.tipo
            when 'entrega_tecnico'::text then m.cantidad
            when 'devolucion_tecnico'::text then (- m.cantidad)
            when 'consumo_tecnico'::text then (- m.cantidad)
            else (0)::numeric
        end), (0)::numeric) as en_custodia
   from (productos p
     left join movimientos_inventario m on ((m.producto_id = p.id)))
  where p.activo
    and mi_rol() in ('admin', 'tecnico', 'almacenista')
  group by p.id;

alter view existencias set (security_invoker = off);
revoke all on existencias from anon, authenticated;
grant select on existencias to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Funciones de apoyo (internas)
-- ---------------------------------------------------------------------------
create or replace function _es_almacen() returns boolean
language sql stable security definer set search_path = public as $$
  select es_admin() or coalesce(mi_rol() = 'almacenista', false)
$$;
revoke all on function _es_almacen() from public, anon;

-- Arma la lista de surtido de una orden con las piezas del catálogo de su cotización
-- aceptada. Lo que ya está en la lista no se toca. Devuelve cuántas líneas agregó.
create or replace function _preparar_surtido(p_orden uuid) returns int
language plpgsql security definer set search_path = public as $$
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
end $$;
revoke all on function _preparar_surtido(uuid) from public, anon, authenticated;

-- Aplica una entrega: mueve el inventario y marca la entrega. La llaman firmar_entrega
-- y entregar_sin_firma, que ya validaron quién es quien llama.
create or replace function _aplicar_entrega(
  p_entrega uuid, p_estado text, p_firma text, p_motivo text
) returns void
language plpgsql security definer set search_path = public as $$
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
end $$;
revoke all on function _aplicar_entrega(uuid, text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Funciones públicas
-- ---------------------------------------------------------------------------

-- Lista del almacén: órdenes abiertas con cita programada, con su lista de surtido,
-- existencia física y entregas. Antes de listar arma el surtido de cada una (idempotente).
create or replace function ordenes_por_surtir() returns jsonb
language plpgsql security definer set search_path = public as $$
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
end $$;

-- Fija cuánto se surte de una pieza en una orden (agrega a mano, sube, baja o quita).
create or replace function fijar_surtido(p_orden uuid, p_producto uuid, p_cantidad numeric)
returns jsonb
language plpgsql security definer set search_path = public as $$
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
end $$;

-- Prepara una entrega (no mueve inventario hasta que se firme).
-- p_lineas: [{"producto_id": "...", "cantidad": 2}, ...]
create or replace function crear_entrega(p_orden uuid, p_lineas jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
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
end $$;

-- Una entrega pendiente (aún sin firma) se puede cancelar sin efectos.
create or replace function cancelar_entrega(p_entrega uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
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
end $$;

-- T1 recibe y firma. La firma ya está subida al bucket `ordenes` (entregas/<id>.png).
create or replace function firmar_entrega(p_entrega uuid, p_firma text) returns jsonb
language plpgsql security definer set search_path = public as $$
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
end $$;

-- El almacenista entrega sin firma cuando T1 no puede firmar (motivo obligatorio).
create or replace function entregar_sin_firma(p_entrega uuid, p_motivo text) returns jsonb
language plpgsql security definer set search_path = public as $$
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
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'ordenes_por_surtir()', 'fijar_surtido(uuid, uuid, numeric)', 'crear_entrega(uuid, jsonb)',
    'cancelar_entrega(uuid)', 'firmar_entrega(uuid, text)', 'entregar_sin_firma(uuid, text)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 7. cambiar_estado_cotizacion: copia de la versión de 10_cotizacion_abre_cita.sql con
--    DOS cambios (marcados con «14»):
--      · al salir de "aceptada" libera lo que aún queda apartado (pedido − entregado);
--      · una cita con material entregado cuenta como "con trabajo".
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
$$;

revoke all on function cambiar_estado_cotizacion(uuid, text, boolean) from public, anon;
grant execute on function cambiar_estado_cotizacion(uuid, text, boolean) to authenticated;

notify pgrst, 'reload schema';

-- Verificación: existencias con la columna nueva y las tablas con RLS.
select 'existencias.en_custodia' as que,
       exists (select 1 from information_schema.columns
                where table_name = 'existencias' and column_name = 'en_custodia')::text as ok
union all
select 'rls ' || relname, relrowsecurity::text
from pg_class where relname in ('orden_surtido', 'entregas', 'entrega_lineas');
