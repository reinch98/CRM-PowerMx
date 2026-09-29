-- ---------------------------------------------------------------------------
-- 41_compras.sql — lo que entra al almacén, de quién se compró y a cómo.
--
-- Hoy el recorrido se corta a la mitad. Una requisición pasa a `pedida`, luego a `recibida`,
-- y en ese momento `cambiar_estado_requisicion` mete la entrada al inventario. Ahí se acaba:
-- **no hay dónde guardar el proveedor, el costo real ni la factura**. El inventario sabe qué
-- salió y por qué; no sabe qué entró ni a cómo. `productos.costo` es un número escrito a mano
-- sin nada que lo respalde.
--
-- CÓMO NO CONTAR DOBLE — y aquí la lectura del código cambió el plan. La idea inicial era que
-- la factura fuera lo ÚNICO que mueve inventario y quitarle esa tarea a la requisición. No
-- hace falta: **el candado ya existe.** `cambiar_estado_requisicion` se niega a tocar una
-- requisición que ya está `recibida` o `cancelada`, y la tabla guarda el `movimiento_id` de su
-- entrada. Así que las dos puertas conviven sin pisarse, y cada una cubre un caso real:
--
--   · Llega el material CON factura      → se registra la compra: ella mete la entrada
--                                          (referencia `COMPRA-n`) y marca la requisición
--                                          `recibida` apuntando a ese movimiento.
--   · Llega el material SIN factura      → se marca la requisición `recibida` como siempre
--     (todavía no la mandan)                (entrada `REQ-n`); la factura se captura después.
--   · La factura llega DESPUÉS de haber  → la compra **no** mete otra entrada para esa línea:
--     recibido el material                 solo la liga y guarda el costo. El inventario ya
--                                          se movió y moverlo otra vez sería contarlo doble.
--   · Compra directa, sin requisición     → la compra mete la entrada. Es el caso común al
--     (reponer refacciones)                 surtir el estante.
--
-- No se cambia `cambiar_estado_requisicion`, que ya está aplicada y probada desde la 08.
--
-- CANCELAR NO BORRA. El inventario nunca se borra: un error se corrige con otro movimiento
-- (regla del proyecto). `cancelar_compra` mete `ajuste` en negativo —el único tipo que lo
-- acepta— con la referencia de la compra, y deja la compra en `cancelada` con su motivo.
--
-- EL COSTO NO SE PISA SOLO. Cada línea guarda lo que de verdad costó, y `productos.costo` se
-- actualiza **solo si la línea lo pide** (`actualizar_costo`). Una compra de urgencia a
-- sobreprecio no debe reescribir el costo de referencia sin que alguien lo decida.
--
-- LA FACTURA VA A SU PROPIO BUCKET. En `ordenes` la leerían los técnicos (su política es
-- admin + técnico) y ahí van costos: **el costo no sale nunca a un técnico**. Bucket `compras`
-- nuevo, privado y solo admin.
--
-- SQL plano fuera de las funciones, sin `select ... into` (ver CLAUDE.md). Repetible.
-- ---------------------------------------------------------------------------

-- ---- tablas ----

create table if not exists compras (
  id            uuid primary key default gen_random_uuid(),
  folio         bigint generated always as identity,
  proveedor     text not null,
  factura       text,                       -- serie y folio del proveedor, como venga
  uuid_fiscal   text,                       -- el UUID del CFDI, si lo hay
  fecha         date not null default current_date,
  subtotal      numeric not null default 0,
  iva           numeric not null default 0,
  total         numeric not null default 0,
  moneda        text not null default 'MXN',
  estado        text not null default 'registrada'
                check (estado in ('registrada', 'cancelada')),
  motivo_cancelacion text,
  notas         text,
  archivo_xml   text,                       -- ruta en el bucket `compras`
  archivo_pdf   text,
  creada_por    text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- Una factura no se captura dos veces. `factura` puede venir vacía (una nota de mostrador sin
-- folio), y varios nulos conviven en un índice único, así que eso no estorba.
create unique index if not exists compras_proveedor_factura
  on compras (lower(trim(proveedor)), lower(trim(factura)))
  where factura is not null and estado <> 'cancelada';

create table if not exists compra_lineas (
  id             uuid primary key default gen_random_uuid(),
  compra_id      uuid not null references compras(id) on delete cascade,
  producto_id    uuid not null references productos(id),
  requisicion_id uuid references requisiciones(id),
  cantidad       numeric not null check (cantidad > 0),
  costo_unitario numeric not null check (costo_unitario >= 0),
  importe        numeric not null default 0,
  movimiento_id  uuid,                      -- la entrada que metió esta línea, si metió una
  created_at     timestamptz not null default now()
);

create index if not exists idx_compra_lineas_compra    on compra_lineas(compra_id);
create index if not exists idx_compra_lineas_producto  on compra_lineas(producto_id);

alter table compras       enable row level security;
alter table compra_lineas enable row level security;

drop policy if exists admin_compras        on compras;
drop policy if exists admin_compra_lineas  on compra_lineas;

-- Solo el admin. Aquí vive el costo: ni el técnico ni el almacenista entran.
create policy admin_compras on compras
  for all to authenticated using (es_admin()) with check (es_admin());
create policy admin_compra_lineas on compra_lineas
  for all to authenticated using (es_admin()) with check (es_admin());

-- Las tablas nuevas nacen con los privilegios que Supabase concede por omisión: se quitan,
-- como en toda tabla desde la 14 (ver "35_cerrar_escritura.sql").
revoke all on compras, compra_lineas from anon;

-- ---- el bucket de las facturas ----

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('compras', 'compras', false, 10485760,
        array['application/xml', 'text/xml', 'application/pdf'])
on conflict (id) do update
  set file_size_limit   = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "compras_lee"       on storage.objects;
drop policy if exists "compras_sube"      on storage.objects;
drop policy if exists "compras_actualiza" on storage.objects;

create policy "compras_lee" on storage.objects for select to authenticated
  using (bucket_id = 'compras' and public.es_admin());
create policy "compras_sube" on storage.objects for insert to authenticated
  with check (bucket_id = 'compras' and public.es_admin());
-- Se sube con upsert para que un reintento tras un corte no falle.
create policy "compras_actualiza" on storage.objects for update to authenticated
  using (bucket_id = 'compras' and public.es_admin())
  with check (bucket_id = 'compras' and public.es_admin());

-- ---------------------------------------------------------------------------
-- registrar_compra(datos, lineas)
--
-- `p_datos`  : {proveedor, factura, uuid_fiscal, fecha, iva, moneda, notas,
--               archivo_xml, archivo_pdf}
-- `p_lineas` : [{producto_id, cantidad, costo_unitario, requisicion_id?,
--                actualizar_costo?}]
--
-- El subtotal y el total los calcula la base a partir de las líneas: un total capturado a
-- mano que no cuadre con sus renglones es un error esperando a que alguien lo descubra.
-- ---------------------------------------------------------------------------
create or replace function registrar_compra(p_datos jsonb, p_lineas jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
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
end $fn$;

revoke all on function registrar_compra(jsonb, jsonb) from public;
grant execute on function registrar_compra(jsonb, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- cancelar_compra(id, motivo) — devuelve el inventario con movimientos, no borrando.
-- ---------------------------------------------------------------------------
create or replace function cancelar_compra(p_compra uuid, p_motivo text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
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
end $fn$;

revoke all on function cancelar_compra(uuid, text) from public;
grant execute on function cancelar_compra(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- compras_recientes(dias) — la lista de la pantalla, con sus líneas.
-- ---------------------------------------------------------------------------
create or replace function compras_recientes(p_dias int default 90)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $fn$
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
$fn$;

revoke all on function compras_recientes(int) from public;
grant execute on function compras_recientes(int) to authenticated;

-- ---------------------------------------------------------------------------
-- pedidos_por_recibir() — lo que la pantalla de Compras ofrece ligar: los pedidos que ya se
-- pusieron al proveedor y todavía no llegan. Lleva el costo de referencia para poder avisar
-- si el de la factura cambió.
-- ---------------------------------------------------------------------------
create or replace function pedidos_por_recibir()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $fn$
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
$fn$;

revoke all on function pedidos_por_recibir() from public;
grant execute on function pedidos_por_recibir() to authenticated;

notify pgrst, 'reload schema';
