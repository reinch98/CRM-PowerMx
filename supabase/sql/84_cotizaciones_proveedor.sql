-- ===========================================================================
-- 84 · Cotizaciones de proveedor (parte B del ciclo de compras, 18/10/2026)
--
-- Lo que un proveedor nos cotiza (número, vigencia, piezas y precios). Decisiones de Caña:
--   · se lee en Compras o desde la bandeja de Finanzas, con IA, y se revisa antes de guardar;
--   · puede crear piezas nuevas en el catálogo, ligadas a ESE proveedor y a su código;
--   · NO mueve inventario: una cotización no es material recibido;
--   · estados vigente → aceptada | rechazada | cancelada; "vencida" no se guarda, se calcula con la
--     vigencia (una vigente con la fecha pasada);
--   · ACEPTARLA crea los pedidos (requisiciones) en "pedida", y antes toma los pedidos pendientes
--     de esas mismas piezas (los que dejó una cotización de cliente aceptada sin material) para no
--     pedir dos veces lo mismo.
-- El almacenista no la ve (lleva costos): todo es solo admin.
--
-- Precios en la moneda de la cotización y SIN IVA. Una cotización en dólares guarda su tipo de cambio,
-- y el costo del catálogo se guarda en pesos (precio × tipo de cambio). El costo del catálogo se
-- actualiza solo si la pieza no tenía o si se pide por renglón, y nunca en una pieza con precio
-- automático (ese costo lo manda la sincronización).
--
-- El candado de archivos repetidos (81) ahora también conoce las cotizaciones: el mismo PDF no se
-- registra dos veces como cotización, y la bandeja de Finanzas avisa si ya es una.
--
-- SQL plano fuera de las funciones, sin `select ... into` (ver CLAUDE.md). Repetible.
-- ===========================================================================

create table if not exists cotizaciones_proveedor (
  id              uuid primary key default gen_random_uuid(),
  folio           bigint generated always as identity unique,
  proveedor_id    uuid not null references proveedores (id),
  numero          text,                        -- el número que le da el proveedor
  fecha           date not null default _hoy_merida(),
  vigencia        date,
  moneda          text not null default 'MXN' check (moneda in ('MXN', 'USD')),
  tipo_cambio     numeric(14, 6) check (tipo_cambio is null or tipo_cambio > 0),
  subtotal        numeric(14, 2) not null default 0,
  iva             numeric(14, 2) not null default 0,
  total           numeric(14, 2) not null default 0,
  estado          text not null default 'vigente'
                  check (estado in ('vigente', 'aceptada', 'rechazada', 'cancelada')),
  motivo          text,
  notas           text,
  archivo         text,
  archivo_bucket  text check (archivo_bucket in ('compras', 'finanzas')),
  archivo_hash    text check (archivo_hash ~ '^[0-9a-f]{64}$'),
  documento_id    uuid references documentos (id) on delete set null,
  aceptada_en     timestamptz,
  aceptada_por    text,
  creada_por      text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint cotprov_tipo_cambio check (moneda = 'MXN' or tipo_cambio is not null)
);
-- La misma cotización de un proveedor no se captura dos veces (salvo que se haya cancelado).
create unique index if not exists cotprov_numero
  on cotizaciones_proveedor (proveedor_id, lower(trim(numero)))
  where numero is not null and estado <> 'cancelada';
create index if not exists idx_cotprov_proveedor on cotizaciones_proveedor (proveedor_id, fecha desc);

create table if not exists cotizacion_proveedor_lineas (
  id               uuid primary key default gen_random_uuid(),
  cotizacion_id    uuid not null references cotizaciones_proveedor (id) on delete cascade,
  orden            int not null,
  producto_id      uuid not null references productos (id),
  codigo           text,                       -- el código del proveedor para esa pieza
  descripcion      text not null,
  cantidad         numeric not null check (cantidad > 0),
  precio_unitario  numeric(14, 4) not null check (precio_unitario >= 0),   -- en su moneda, sin IVA
  importe          numeric(14, 2) not null,
  created_at       timestamptz not null default now()
);
create index if not exists idx_cotprov_lineas on cotizacion_proveedor_lineas (cotizacion_id, orden);

alter table requisiciones add column if not exists cotizacion_proveedor_id uuid references cotizaciones_proveedor (id);
alter table requisiciones add column if not exists cotizacion_proveedor_linea_id uuid references cotizacion_proveedor_lineas (id);
create index if not exists idx_requisiciones_cotprov on requisiciones (cotizacion_proveedor_id);

alter table cotizaciones_proveedor enable row level security;
alter table cotizacion_proveedor_lineas enable row level security;
drop policy if exists admin_cotizaciones_proveedor on cotizaciones_proveedor;
create policy admin_cotizaciones_proveedor on cotizaciones_proveedor
  for all to authenticated using (es_admin()) with check (es_admin());
drop policy if exists admin_cotizacion_proveedor_lineas on cotizacion_proveedor_lineas;
create policy admin_cotizacion_proveedor_lineas on cotizacion_proveedor_lineas
  for all to authenticated using (es_admin()) with check (es_admin());
revoke all on cotizaciones_proveedor, cotizacion_proveedor_lineas from anon;

-- ---- el candado de archivos repetidos (81), ahora con las cotizaciones ----
-- Misma función de la 81 con un bloque más al principio: una cotización de proveedor viva (no
-- cancelada) cuenta en los DOS grupos, así que la bandeja de Finanzas también la reconoce.
create or replace function _archivo_en_uso(p_hash text, p_grupo text, p_tabla text default null, p_id uuid default null)
returns text
language plpgsql stable security definer set search_path = public as $fn$
declare
  v text;
begin
  if p_hash is null then
    return null;
  end if;

  v := (select format('como la cotización de proveedor COTP-%s de %s%s (registrada el %s)', c.folio, p.nombre,
                      case when c.numero is not null then ', número ' || c.numero else '' end,
                      to_char(c.created_at at time zone 'America/Merida', 'DD/MM/YYYY'))
          from cotizaciones_proveedor c
          join proveedores p on p.id = c.proveedor_id
         where c.archivo_hash = p_hash and c.estado <> 'cancelada'
           and not coalesce(p_tabla = 'cotizaciones_proveedor' and c.id = p_id, false)
         order by c.created_at
         limit 1);
  if v is not null then
    return v;
  end if;

  if p_grupo = 'compras' then
    return (
      select format('en la compra %s de %s%s (registrada el %s)', c.folio, c.proveedor,
                    case when c.factura is not null then ', factura ' || c.factura else '' end,
                    to_char(c.fecha, 'DD/MM/YYYY'))
        from compras c
        join archivos_subidos a on a.bucket = 'compras' and a.ruta in (c.archivo_pdf, c.archivo_xml)
       where a.hash = p_hash and c.estado <> 'cancelada'
         and not coalesce(p_tabla = 'compras' and c.id = p_id, false)
       order by c.created_at
       limit 1);
  end if;

  -- grupo 'dinero'
  if p_tabla is distinct from 'documentos' then
    v := (select format('en la bandeja de Finanzas (%s, "%s", subido el %s)',
                        case when d.estado = 'aprobado' then 'ya aprobado' else 'por revisar' end,
                        coalesce(d.nombre_original, 'sin nombre'),
                        to_char(d.created_at at time zone 'America/Merida', 'DD/MM/YYYY'))
            from documentos d
           where d.hash_sha256 = p_hash and d.estado <> 'rechazado'
           order by d.created_at
           limit 1);
    if v is not null then
      return v;
    end if;
  end if;

  v := (select format('%s: %s del %s por %s',
                      case when m.cotizacion_id is not null
                           then 'en el expediente de la cotización ' || coalesce((select q.folio::text from cotizaciones q where q.id = m.cotizacion_id), '')
                           else 'en el libro de Finanzas' end,
                      case when m.tipo = 'ingreso' then 'un cobro' else 'un gasto' end,
                      to_char(m.fecha, 'DD/MM/YYYY'),
                      to_char(m.monto, 'FM$999,999,990.00'))
          from expediente_movimientos m
          join archivos_subidos a on a.bucket = 'finanzas' and a.ruta = m.archivo
         where a.hash = p_hash
           and not coalesce(p_tabla = 'expediente_movimientos' and m.id = p_id, false)
         order by m.created_at
         limit 1);
  if v is not null then
    return v;
  end if;

  return (
    select format('en el estado de cuenta de %s%s', coalesce(cf.nombre, 'la cuenta'),
                  case when e.periodo_desde is not null
                       then format(' del %s al %s', to_char(e.periodo_desde, 'DD/MM/YYYY'), to_char(e.periodo_hasta, 'DD/MM/YYYY'))
                       else '' end)
      from estados_cuenta e
      join archivos_subidos a on a.bucket = 'finanzas' and a.ruta = e.archivo
      left join cuentas_financieras cf on cf.id = e.cuenta_id
     where a.hash = p_hash
       and not coalesce(p_tabla = 'estados_cuenta' and e.id = p_id, false)
     order by e.created_at
     limit 1);
end $fn$;
revoke execute on function _archivo_en_uso(text, text, text, uuid) from public, anon, authenticated;

create or replace function _archivo_no_repetido_cotprov() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  if new.archivo_hash is not null and new.estado <> 'cancelada'
     and (tg_op = 'INSERT' or new.archivo_hash is distinct from old.archivo_hash
          or (old.estado = 'cancelada' and new.estado <> 'cancelada')) then
    perform _rechazar_si_repetido(new.archivo_hash, 'compras', 'cotizaciones_proveedor', new.id);
  end if;
  return new;
end $fn$;
drop trigger if exists archivo_no_repetido on cotizaciones_proveedor;
create trigger archivo_no_repetido before insert or update of archivo_hash, estado on cotizaciones_proveedor
  for each row execute function _archivo_no_repetido_cotprov();

-- ---- registrar ----
-- p_datos: proveedor_id | proveedor (texto) + rfc, numero, fecha, vigencia, moneda, tipo_cambio, iva,
--          notas, archivo, archivo_bucket, archivo_hash, documento_id (si viene de la bandeja).
-- p_lineas: [{ producto_id | nuevo:{sku,nombre,categoria,unidad}, codigo, descripcion, cantidad,
--             precio_unitario (o costo_unitario), actualizar_costo }]
create or replace function registrar_cotizacion_proveedor(p_datos jsonb, p_lineas jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_prov      proveedores;
  v_pid       uuid;
  v_id        uuid := gen_random_uuid();
  v_folio     bigint;
  v_moneda    text := upper(coalesce(nullif(trim(p_datos ->> 'moneda'), ''), 'MXN'));
  v_tc        numeric := nullif(p_datos ->> 'tipo_cambio', '')::numeric;
  v_factor    numeric;
  v_numero    text := nullif(trim(coalesce(p_datos ->> 'numero', '')), '');
  v_otra      bigint;
  v_linea     jsonb;
  v_nuevo     jsonb;
  v_prod      uuid;
  v_codigo    text;
  v_sku       text;
  v_cant      numeric;
  v_precio    numeric;
  v_costo     numeric;
  v_orden     int := 0;
  v_subtotal  numeric := 0;
  v_iva       numeric;
  v_creados   int := 0;
  v_costos    int := 0;
  v_avisos    text[] := '{}';
  v_auto      boolean;
  v_antes     numeric;
  v_doc       uuid := nullif(p_datos ->> 'documento_id', '')::uuid;
begin
  if not es_admin() then
    raise exception 'Solo el administrador registra cotizaciones de proveedor.' using errcode = '42501';
  end if;

  v_prov := (select p from proveedores p where p.id = nullif(p_datos ->> 'proveedor_id', '')::uuid);
  if v_prov.id is null then
    -- En dos pasos: si _proveedor_id crea la ficha, la misma sentencia no la vería.
    v_pid := _proveedor_id(p_datos ->> 'proveedor', p_datos ->> 'rfc', true);
    v_prov := (select p from proveedores p where p.id = v_pid);
  end if;
  if v_prov.id is null then
    raise exception 'Escribe de qué proveedor es la cotización.' using errcode = '22023';
  end if;

  if v_moneda not in ('MXN', 'USD') then
    raise exception 'La moneda tiene que ser pesos (MXN) o dólares (USD).' using errcode = '22023';
  end if;
  if v_moneda = 'USD' and coalesce(v_tc, 0) <= 0 then
    raise exception 'Una cotización en dólares necesita el tipo de cambio.' using errcode = '22023';
  end if;
  v_factor := case when v_moneda = 'USD' then v_tc else 1 end;
  if v_moneda = 'MXN' then
    v_tc := null;
  end if;

  if v_numero is not null then
    v_otra := (select c.folio from cotizaciones_proveedor c
                where c.proveedor_id = v_prov.id and lower(trim(c.numero)) = lower(v_numero)
                  and c.estado <> 'cancelada');
    if v_otra is not null then
      raise exception 'La cotización % de % ya está registrada como COTP-%.', v_numero, v_prov.nombre, v_otra
        using errcode = '22023';
    end if;
  end if;

  if jsonb_typeof(p_lineas) <> 'array' or jsonb_array_length(p_lineas) = 0 then
    raise exception 'Una cotización necesita al menos una pieza.' using errcode = '22023';
  end if;

  insert into cotizaciones_proveedor (id, proveedor_id, numero, fecha, vigencia, moneda, tipo_cambio, notas,
                                      archivo, archivo_bucket, archivo_hash, documento_id, creada_por)
  values (v_id, v_prov.id, v_numero,
          coalesce(nullif(p_datos ->> 'fecha', '')::date, _hoy_merida()),
          nullif(p_datos ->> 'vigencia', '')::date,
          v_moneda, v_tc, nullif(trim(coalesce(p_datos ->> 'notas', '')), ''),
          nullif(p_datos ->> 'archivo', ''), nullif(p_datos ->> 'archivo_bucket', ''),
          nullif(lower(p_datos ->> 'archivo_hash'), ''), v_doc,
          coalesce(auth.jwt() ->> 'email', 'crm'));
  v_folio := (select folio from cotizaciones_proveedor where id = v_id);

  for v_linea in select * from jsonb_array_elements(p_lineas) loop
    v_orden := v_orden + 1;
    v_prod := nullif(v_linea ->> 'producto_id', '')::uuid;
    v_codigo := nullif(trim(coalesce(v_linea ->> 'codigo', '')), '');
    v_nuevo := v_linea -> 'nuevo';
    v_cant := nullif(v_linea ->> 'cantidad', '')::numeric;
    v_precio := coalesce(nullif(v_linea ->> 'precio_unitario', ''), nullif(v_linea ->> 'costo_unitario', ''))::numeric;
    if coalesce(v_cant, 0) <= 0 then
      raise exception 'El renglón % no tiene cantidad.', v_orden using errcode = '22023';
    end if;
    if v_precio is null or v_precio < 0 then
      raise exception 'El renglón % no tiene un precio válido.', v_orden using errcode = '22023';
    end if;
    v_costo := round(v_precio * v_factor, 2);

    if v_prod is null then
      if v_nuevo is null or jsonb_typeof(v_nuevo) <> 'object' then
        raise exception 'El renglón % no trae pieza del catálogo ni datos de una pieza nueva.', v_orden using errcode = '22023';
      end if;
      v_sku := upper(trim(coalesce(v_nuevo ->> 'sku', '')));
      if v_sku = '' then
        raise exception 'Una pieza nueva necesita su SKU.' using errcode = '22023';
      end if;
      if trim(coalesce(v_nuevo ->> 'nombre', '')) = '' or trim(coalesce(v_nuevo ->> 'categoria', '')) = '' then
        raise exception 'La pieza nueva % necesita nombre y categoría.', v_sku using errcode = '22023';
      end if;
      if exists (select 1 from productos where upper(sku) = v_sku) then
        raise exception 'Ya existe un producto con el SKU %. Elígelo de la lista o cámbiale el SKU a la pieza nueva.', v_sku
          using errcode = '22023';
      end if;
      v_prod := gen_random_uuid();
      -- Sin publicar y sin precio; el disparador de la 51 la liga al proveedor con su código.
      insert into productos (id, sku, nombre, categoria, unidad, activo, publicar, costo, proveedor, proveedor_sku)
      values (v_prod, v_sku, trim(v_nuevo ->> 'nombre'), trim(v_nuevo ->> 'categoria'),
              coalesce(nullif(trim(coalesce(v_nuevo ->> 'unidad', '')), ''), 'pieza'),
              true, false, v_costo, v_prov.nombre, v_codigo);
      v_creados := v_creados + 1;
    else
      if not exists (select 1 from productos where id = v_prod) then
        raise exception 'El renglón % apunta a una pieza que no existe.', v_orden using errcode = '22023';
      end if;
      -- El código que este proveedor le da a la pieza, si aún no estaba ligada a él. Con el nombre
      -- del proveedor y no con su clave de sincronización: esos vínculos los maneja la sincronización.
      if v_codigo is not null
         and not exists (select 1 from producto_proveedores where producto_id = v_prod and proveedor_id = v_prov.id) then
        insert into producto_proveedores (producto_id, proveedor, proveedor_sku, proveedor_id)
        values (v_prod, v_prov.nombre, v_codigo, v_prov.id)
        on conflict do nothing;
      end if;
      -- El costo del catálogo: solo si se pide, y nunca en una pieza con precio automático.
      if coalesce((v_linea ->> 'actualizar_costo')::boolean, false) then
        v_auto := (select coalesce(precio_auto, false) from productos where id = v_prod);
        if v_auto then
          v_avisos := array_append(v_avisos, format('%s tiene precio automático: su costo lo manda la sincronización y no se cambió.',
                                                    (select sku from productos where id = v_prod)));
        else
          v_antes := (select costo from productos where id = v_prod);
          update productos set costo = v_costo where id = v_prod;
          perform _apunta('productos', v_prod, 'costo_por_cotizacion_proveedor',
                          jsonb_build_object('costo', v_antes),
                          jsonb_build_object('costo', v_costo, 'cotizacion', 'COTP-' || v_folio), 'oficina');
          v_costos := v_costos + 1;
        end if;
      end if;
    end if;

    -- El último costo de este proveedor, para verlo en su carpeta (no toca los vínculos sincronizados).
    update producto_proveedores set costo_mxn = v_costo
     where producto_id = v_prod and proveedor_id = v_prov.id and proveedor is distinct from v_prov.clave;

    insert into cotizacion_proveedor_lineas (cotizacion_id, orden, producto_id, codigo, descripcion, cantidad,
                                             precio_unitario, importe)
    values (v_id, v_orden, v_prod, v_codigo,
            coalesce(nullif(trim(coalesce(v_linea ->> 'descripcion', '')), ''), (select nombre from productos where id = v_prod)),
            v_cant, v_precio, round(v_cant * v_precio, 2));
    v_subtotal := v_subtotal + round(v_cant * v_precio, 2);
  end loop;

  v_iva := coalesce(nullif(p_datos ->> 'iva', '')::numeric, round(v_subtotal * 0.16, 2));
  update cotizaciones_proveedor
     set subtotal = v_subtotal, iva = v_iva, total = v_subtotal + v_iva
   where id = v_id;

  -- Si venía de la bandeja de Finanzas, sale de ahí: no es un gasto.
  if v_doc is not null then
    update documentos set estado = 'rechazado',
           motivo_rechazo = format('Registrada como cotización de proveedor COTP-%s', v_folio)
     where id = v_doc and estado in ('pendiente', 'propuesto');
  end if;

  perform _apunta('cotizaciones_proveedor', v_id, 'registrar', null,
                  (select to_jsonb(c) from cotizaciones_proveedor c where c.id = v_id), 'oficina');
  return jsonb_build_object('ok', true, 'id', v_id, 'folio', v_folio, 'proveedor', v_prov.nombre,
                            'subtotal', v_subtotal, 'total', v_subtotal + v_iva, 'moneda', v_moneda,
                            'productos_nuevos', v_creados, 'costos_actualizados', v_costos,
                            'avisos', to_jsonb(v_avisos));
end $fn$;

-- ---- aceptar: crea los pedidos ----
create or replace function aceptar_cotizacion_proveedor(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_c       cotizaciones_proveedor;
  v_prov    proveedores;
  v_l       record;
  v_r       record;
  v_resta   numeric;
  v_ref     text;
  v_nuevos  int := 0;
  v_tomados int := 0;
  v_avisos  text[] := '{}';
begin
  if not es_admin() then
    raise exception 'Solo el administrador acepta cotizaciones de proveedor.' using errcode = '42501';
  end if;
  v_c := (select c from cotizaciones_proveedor c where c.id = p_id);
  if v_c.id is null then
    raise exception 'Esa cotización no existe.' using errcode = '22023';
  end if;
  if v_c.estado = 'aceptada' then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;
  if v_c.estado <> 'vigente' then
    raise exception 'Solo se acepta una cotización vigente (esta está %).', v_c.estado using errcode = '22023';
  end if;
  if v_c.vigencia is not null and v_c.vigencia < _hoy_merida() then
    v_avisos := array_append(v_avisos, format('Su vigencia terminó el %s: confirma el precio con el proveedor.',
                                              to_char(v_c.vigencia, 'DD/MM/YYYY')));
  end if;
  v_prov := (select p from proveedores p where p.id = v_c.proveedor_id);
  v_ref := concat_ws(' ', 'COTP-' || v_c.folio, case when v_c.numero is not null then '(' || v_c.numero || ')' end);

  for v_l in select * from cotizacion_proveedor_lineas where cotizacion_id = p_id order by orden loop
    v_resta := v_l.cantidad;
    -- Primero los pedidos pendientes de esa misma pieza (los deja una cotización de cliente aceptada
    -- sin material): se toman enteros mientras quepan.
    for v_r in select * from requisiciones
                where producto_id = v_l.producto_id and estado = 'pendiente' and cotizacion_proveedor_id is null
                order by created_at loop
      if v_r.cantidad <= v_resta then
        update requisiciones
           set estado = 'pedida', proveedor = v_prov.nombre, proveedor_id = v_prov.id,
               referencia = coalesce(referencia, v_ref), fecha_pedido = _hoy_merida(),
               cotizacion_proveedor_id = p_id, cotizacion_proveedor_linea_id = v_l.id, updated_at = now()
         where id = v_r.id;
        v_resta := v_resta - v_r.cantidad;
        v_tomados := v_tomados + 1;
      else
        v_avisos := array_append(v_avisos, format('REQ-%s pide %s de %s, más de lo cotizado: quedó pendiente.',
                                                  v_r.folio, v_r.cantidad, v_l.descripcion));
      end if;
    end loop;
    if v_resta > 0 then
      insert into requisiciones (producto_id, cantidad, estado, proveedor, proveedor_id, referencia, fecha_pedido,
                                 cotizacion_proveedor_id, cotizacion_proveedor_linea_id, notas, creada_por)
      values (v_l.producto_id, v_resta, 'pedida', v_prov.nombre, v_prov.id, v_ref, _hoy_merida(),
              p_id, v_l.id, 'De la cotización de proveedor aceptada', coalesce(auth.jwt() ->> 'email', 'crm'));
      v_nuevos := v_nuevos + 1;
    end if;
  end loop;

  update cotizaciones_proveedor
     set estado = 'aceptada', aceptada_en = now(), aceptada_por = coalesce(auth.jwt() ->> 'email', 'crm'),
         updated_at = now()
   where id = p_id;
  perform _apunta('cotizaciones_proveedor', p_id, 'aceptar', jsonb_build_object('estado', v_c.estado),
                  jsonb_build_object('estado', 'aceptada', 'pedidos_nuevos', v_nuevos, 'pedidos_tomados', v_tomados),
                  'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false, 'pedidos_nuevos', v_nuevos,
                            'pedidos_tomados', v_tomados, 'avisos', to_jsonb(v_avisos));
end $fn$;

-- ---- rechazar, cancelar o volver a vigente ----
-- Cancelar una aceptada NO cancela sus pedidos "pedida" (ya están con el proveedor): solo avisa,
-- igual que la regla de Pedidos.
create or replace function cambiar_estado_cotizacion_proveedor(p_id uuid, p_estado text, p_motivo text default null)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_c cotizaciones_proveedor;
  v_pedidas int;
begin
  if not es_admin() then
    raise exception 'Solo el administrador cambia cotizaciones de proveedor.' using errcode = '42501';
  end if;
  v_c := (select c from cotizaciones_proveedor c where c.id = p_id);
  if v_c.id is null then
    raise exception 'Esa cotización no existe.' using errcode = '22023';
  end if;
  if p_estado = v_c.estado then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;
  if not ((v_c.estado = 'vigente' and p_estado in ('rechazada', 'cancelada'))
       or (v_c.estado = 'aceptada' and p_estado = 'cancelada')
       or (v_c.estado = 'rechazada' and p_estado = 'vigente')) then
    raise exception 'No se puede pasar una cotización % a %.', v_c.estado, p_estado using errcode = '22023';
  end if;
  if p_estado in ('rechazada', 'cancelada') and coalesce(trim(p_motivo), '') = '' then
    raise exception 'Escribe por qué.' using errcode = '22023';
  end if;

  update cotizaciones_proveedor
     set estado = p_estado, motivo = case when p_estado = 'vigente' then motivo else trim(p_motivo) end,
         updated_at = now()
   where id = p_id;
  v_pedidas := (select count(*) from requisiciones where cotizacion_proveedor_id = p_id and estado = 'pedida');
  perform _apunta('cotizaciones_proveedor', p_id, 'cambiar_estado', jsonb_build_object('estado', v_c.estado),
                  jsonb_build_object('estado', p_estado, 'motivo', p_motivo), 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false, 'pedidos_vivos', v_pedidas);
end $fn$;

-- ---- la lista (para Compras y para la carpeta del proveedor) ----
create or replace function cotizaciones_proveedor_lista(p_proveedor uuid default null, p_dias int default 365)
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
begin
  if not es_admin() then
    raise exception 'Solo el administrador ve las cotizaciones de proveedor.' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', c.id, 'folio', c.folio, 'proveedor_id', c.proveedor_id, 'proveedor', p.nombre,
             'numero', c.numero, 'fecha', c.fecha, 'vigencia', c.vigencia, 'estado', c.estado,
             'vencida', c.estado = 'vigente' and c.vigencia is not null and c.vigencia < _hoy_merida(),
             'moneda', c.moneda, 'tipo_cambio', c.tipo_cambio, 'subtotal', c.subtotal, 'iva', c.iva,
             'total', c.total, 'motivo', c.motivo, 'notas', c.notas, 'archivo', c.archivo,
             'archivo_bucket', c.archivo_bucket, 'aceptada_en', c.aceptada_en,
             'pedidos', (select count(*) from requisiciones r where r.cotizacion_proveedor_id = c.id),
             'pedidos_recibidos', (select count(*) from requisiciones r
                                    where r.cotizacion_proveedor_id = c.id and r.estado = 'recibida'),
             'lineas', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'producto_id', l.producto_id, 'sku', pr.sku, 'nombre', pr.nombre, 'codigo', l.codigo,
                        'descripcion', l.descripcion, 'cantidad', l.cantidad,
                        'precio_unitario', l.precio_unitario, 'importe', l.importe) order by l.orden)
                 from cotizacion_proveedor_lineas l join productos pr on pr.id = l.producto_id
                where l.cotizacion_id = c.id), '[]'::jsonb))
           order by (c.estado = 'vigente') desc, c.fecha desc, c.folio desc)
      from cotizaciones_proveedor c
      join proveedores p on p.id = c.proveedor_id
     where (p_proveedor is null or c.proveedor_id = p_proveedor)
       and (c.estado = 'vigente' or c.fecha >= _hoy_merida() - greatest(coalesce(p_dias, 365), 1))
  ), '[]'::jsonb);
end $fn$;

revoke execute on function registrar_cotizacion_proveedor(jsonb, jsonb), aceptar_cotizacion_proveedor(uuid),
  cambiar_estado_cotizacion_proveedor(uuid, text, text), cotizaciones_proveedor_lista(uuid, int)
  from public, anon;
grant execute on function registrar_cotizacion_proveedor(jsonb, jsonb), aceptar_cotizacion_proveedor(uuid),
  cambiar_estado_cotizacion_proveedor(uuid, text, text), cotizaciones_proveedor_lista(uuid, int)
  to authenticated;

notify pgrst, 'reload schema';

insert into _migraciones (archivo, tipo) values ('84_cotizaciones_proveedor.sql', 'esquema')
on conflict (archivo) do nothing;
