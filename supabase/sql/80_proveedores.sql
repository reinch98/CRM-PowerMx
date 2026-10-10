-- ===========================================================================
-- 80 · Proveedores: la carpeta de cada proveedor (parte A del ciclo de compras, 10/10/2026)
--
-- Hasta hoy el proveedor era un TEXTO escrito en cuatro lugares (compras.proveedor,
-- requisiciones.proveedor, producto_proveedores.proveedor, cfdi.nombre_emisor), cada uno a su
-- manera: "xlstore", "Exel Solar", "EXEL SOLAR S.A.P.I. DE C.V.". Sin una ficha única no se puede
-- juntar lo de un proveedor: sus cotizaciones, facturas, pagos y saldo. Las partes B (cotizaciones
-- de proveedor), C (comprobantes de pago y anticipos) y D (la factura cierra el ciclo) cuelgan
-- de esta tabla.
--
-- · `proveedores`: nombre, RFC único, `clave` de la sincronización ('xlstore', 'solarama') y
--   `alias` (cómo viene impreso en las facturas). El nombre se compara por `nombre_clave`: sin
--   acentos, sin puntuación y sin "S.A. de C.V." / "S.A.P.I." / "México", de modo que
--   "EXEL SOLAR S.A.P.I. DE C.V." y "Exel Solar" son el mismo.
-- · Las tablas de siempre ganan `proveedor_id` y un disparador lo llena SOLO desde el texto
--   (o desde el RFC, en una factura recibida). El texto se queda: es lo que venía impreso y lo
--   que leen las pantallas y la sincronización de hoy. Un proveedor que no existía se crea solo.
-- · Lo que la base no puede saber —que "Cummins" y "Distribuidora Cummins" son el mismo— lo
--   decide el admin con `unir_proveedores` (se mueve todo y queda en `auditoria`), y
--   `proveedores_parecidos` le propone las parejas. "No son el mismo" se recuerda.
-- · Un RFC genérico (XAXX010101000, XEXX010101000) no identifica a nadie: se trata como vacío.
--
-- Solo admin: aquí viven costos y saldos. SQL plano fuera de las funciones, sin `select ... into`
-- (ver CLAUDE.md). Repetible.
-- ===========================================================================

-- 1. Cómo se comparan nombres y RFC -----------------------------------------------------------

create or replace function _clave_proveedor(p text) returns text
language sql immutable parallel safe set search_path = public as $fn$
  select coalesce(string_agg(w, '' order by o), '')
    from unnest(regexp_split_to_array(
           trim(regexp_replace(lower(unaccent_inmutable(replace(coalesce(p, ''), '.', ''))), '[^a-z0-9]+', ' ', 'g')),
           ' ')) with ordinality as t(w, o)
   where w <> ''
     and w not in ('sa', 'sapi', 'sab', 'cv', 'de', 'rl', 'srl', 's', 'sas', 'sc', 'ac', 'mexico', 'mx')
$fn$;

create or replace function _rfc_valido(p text) returns text
language sql immutable parallel safe as $fn$
  select case
           when r ~ '^[A-ZÑ&]{3,4}[0-9]{6}[A-Z0-9]{3}$' and r not in ('XAXX010101000', 'XEXX010101000') then r
         end
    from (select upper(regexp_replace(coalesce(p, ''), '[\s-]', '', 'g')) as r) x
$fn$;

-- 2. La tabla ---------------------------------------------------------------------------------

create table if not exists proveedores (
  id            uuid primary key default gen_random_uuid(),
  clave         text unique,                -- la de la sincronización: 'xlstore', 'solarama'
  nombre        text not null check (trim(nombre) <> ''),
  nombre_clave  text generated always as (_clave_proveedor(nombre)) stored,
  rfc           text check (rfc is null or rfc ~ '^[A-ZÑ&]{3,4}[0-9]{6}[A-Z0-9]{3}$'),
  alias         text[] not null default '{}',
  contacto      text,
  telefono      text,
  email         text,
  notas         text,
  activo        boolean not null default true,
  creado_por    text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create unique index if not exists proveedores_rfc on proveedores (rfc) where rfc is not null;
create unique index if not exists proveedores_nombre_clave on proveedores (nombre_clave) where nombre_clave <> '';

-- Parejas que el admin ya revisó y NO son el mismo proveedor (para no volver a proponerlas).
create table if not exists proveedores_distintos (
  a uuid not null references proveedores (id) on delete cascade,
  b uuid not null references proveedores (id) on delete cascade,
  marcado_por text,
  created_at timestamptz not null default now(),
  primary key (a, b),
  check (a < b)
);

alter table proveedores enable row level security;
alter table proveedores_distintos enable row level security;
drop policy if exists admin_proveedores on proveedores;
create policy admin_proveedores on proveedores
  for all to authenticated using (es_admin()) with check (es_admin());
drop policy if exists admin_proveedores_distintos on proveedores_distintos;
create policy admin_proveedores_distintos on proveedores_distintos
  for all to authenticated using (es_admin()) with check (es_admin());
revoke all on proveedores, proveedores_distintos from anon;

-- Los dos de la sincronización. XLStore es la tienda de Exel Solar: sus facturas llegan como
-- "EXEL SOLAR S.A.P.I. DE C.V." y así se reconocen solas.
insert into proveedores (clave, nombre, alias, notas, creado_por)
values ('xlstore', 'Exel Solar', array['XLStore'], 'Tienda en línea XLStore. Precios y existencias por sincronización.', 'crm'),
       ('solarama', 'Solarama', '{}', 'Lista de precios en PDF (dólares más IVA), cada ~5 meses.', 'crm')
on conflict (clave) do nothing;

-- 3. Encontrar (o crear) al proveedor de un texto ---------------------------------------------
-- Busca por RFC, luego por la clave de sincronización y luego por el nombre o sus alias
-- normalizados. Al encontrarlo aprende: el RFC si no lo tenía y la forma impresa del nombre.

create or replace function _proveedor_id(p_nombre text, p_rfc text default null, p_crear boolean default true)
returns uuid
language plpgsql security definer set search_path = public as $fn$
declare
  v_rfc    text := _rfc_valido(p_rfc);
  v_nombre text := nullif(trim(regexp_replace(coalesce(p_nombre, ''), '\s+', ' ', 'g')), '');
  v_clave  text := _clave_proveedor(p_nombre);
  v_id     uuid;
begin
  if v_rfc is not null then
    v_id := (select id from proveedores where rfc = v_rfc);
  end if;
  if v_id is null and v_nombre is not null then
    v_id := (select p.id from proveedores p
              where p.clave = lower(v_nombre)
                 or (v_clave <> '' and (p.nombre_clave = v_clave
                     or exists (select 1 from unnest(p.alias) a where _clave_proveedor(a) = v_clave)))
              order by (p.clave = lower(v_nombre)) desc nulls last, p.created_at
              limit 1);
  end if;

  if v_id is null then
    if not p_crear then
      return null;
    end if;
    if v_nombre is null or v_clave = '' then
      -- Sin nombre utilizable pero con RFC: se crea con el RFC como nombre (se corrige en la ficha).
      if v_rfc is null then
        return null;
      end if;
      v_nombre := v_rfc;
    end if;
    v_id := gen_random_uuid();
    insert into proveedores (id, nombre, rfc, creado_por)
    values (v_id, v_nombre, v_rfc, coalesce(auth.jwt() ->> 'email', 'crm'));
    return v_id;
  end if;

  update proveedores p
     set rfc = coalesce(p.rfc, v_rfc),
         alias = case
                   when v_nombre is null or lower(v_nombre) = lower(p.nombre) or lower(v_nombre) = p.clave
                     or exists (select 1 from unnest(p.alias) a where lower(a) = lower(v_nombre))
                   then p.alias
                   else p.alias || v_nombre
                 end,
         updated_at = now()
   where p.id = v_id
     and ((v_rfc is not null and p.rfc is null)
          or (v_nombre is not null and lower(v_nombre) <> lower(p.nombre) and lower(v_nombre) is distinct from p.clave
              and not exists (select 1 from unnest(p.alias) a where lower(a) = lower(v_nombre))));
  return v_id;
end $fn$;
revoke execute on function _proveedor_id(text, text, boolean) from public, anon, authenticated;

-- 4. proveedor_id en las tablas de siempre ------------------------------------------------------

alter table compras                add column if not exists proveedor_id uuid references proveedores (id);
alter table requisiciones          add column if not exists proveedor_id uuid references proveedores (id);
alter table producto_proveedores   add column if not exists proveedor_id uuid references proveedores (id);
alter table cfdi                   add column if not exists proveedor_id uuid references proveedores (id);
alter table expediente_movimientos add column if not exists proveedor_id uuid references proveedores (id);
create index if not exists idx_compras_proveedor_id        on compras (proveedor_id);
create index if not exists idx_requisiciones_proveedor_id  on requisiciones (proveedor_id);
create index if not exists idx_prod_prov_proveedor_id      on producto_proveedores (proveedor_id);
create index if not exists idx_cfdi_proveedor_id           on cfdi (proveedor_id);
create index if not exists idx_exp_mov_proveedor_id        on expediente_movimientos (proveedor_id);

-- Compras, pedidos y vínculos de catálogo: del texto `proveedor`. Si quien inserta ya trae el
-- proveedor_id (las partes B a D lo harán), se respeta.
create or replace function _fijar_proveedor_texto() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  if tg_op = 'INSERT' then
    if new.proveedor_id is null and new.proveedor is not null then
      new.proveedor_id := _proveedor_id(new.proveedor, null, true);
    end if;
  elsif new.proveedor is distinct from old.proveedor then
    new.proveedor_id := case when new.proveedor is null then null else _proveedor_id(new.proveedor, null, true) end;
  end if;
  return new;
end $fn$;

drop trigger if exists fijar_proveedor on compras;
create trigger fijar_proveedor before insert or update of proveedor on compras
  for each row execute function _fijar_proveedor_texto();
drop trigger if exists fijar_proveedor on requisiciones;
create trigger fijar_proveedor before insert or update of proveedor on requisiciones
  for each row execute function _fijar_proveedor_texto();
drop trigger if exists fijar_proveedor on producto_proveedores;
create trigger fijar_proveedor before insert or update of proveedor on producto_proveedores
  for each row execute function _fijar_proveedor_texto();

-- Factura recibida: del RFC del emisor (y su nombre). Una emitida no tiene proveedor.
create or replace function _fijar_proveedor_cfdi() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  if new.sentido <> 'recibido' then
    new.proveedor_id := null;
  elsif new.proveedor_id is null
     or (tg_op = 'UPDATE' and new.rfc_emisor is distinct from old.rfc_emisor) then
    new.proveedor_id := _proveedor_id(new.nombre_emisor, new.rfc_emisor, true);
  end if;
  return new;
end $fn$;
drop trigger if exists fijar_proveedor on cfdi;
create trigger fijar_proveedor before insert or update of rfc_emisor, nombre_emisor, sentido on cfdi
  for each row execute function _fijar_proveedor_cfdi();

-- Movimiento del libro: el de su factura o el de su compra, si no se lo dieron.
create or replace function _fijar_proveedor_movimiento() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  if new.proveedor_id is null and new.cfdi_id is not null then
    new.proveedor_id := (select proveedor_id from cfdi where id = new.cfdi_id);
  end if;
  if new.proveedor_id is null and new.compra_id is not null then
    new.proveedor_id := (select proveedor_id from compras where id = new.compra_id);
  end if;
  return new;
end $fn$;
drop trigger if exists fijar_proveedor on expediente_movimientos;
create trigger fijar_proveedor before insert or update of cfdi_id, compra_id on expediente_movimientos
  for each row execute function _fijar_proveedor_movimiento();

-- Un expediente cerrado no deja tocar sus movimientos (61). Saber de qué proveedor es un pago no
-- cambia ninguna cifra: si lo ÚNICO que cambia es proveedor_id (al llenarlo o al unir dos
-- proveedores), se deja pasar. Todo lo demás sigue bloqueado igual que antes.
create or replace function _expediente_cerrado_bloquea() returns trigger
language plpgsql as $fn$
declare
  v_cot uuid;
begin
  if tg_op = 'UPDATE' and (to_jsonb(new) - 'proveedor_id') = (to_jsonb(old) - 'proveedor_id') then
    return new;
  end if;
  v_cot := coalesce(new.cotizacion_id, old.cotizacion_id);
  if (select expediente_cerrado_en from cotizaciones where id = v_cot) is not null then
    raise exception 'El expediente está cerrado. Reábrelo para cambiar sus movimientos.' using errcode = '22023';
  end if;
  return coalesce(new, old);
end $fn$;

-- Lo que ya había.
update producto_proveedores set proveedor_id = _proveedor_id(proveedor, null, true)
 where proveedor_id is null;
update compras set proveedor_id = _proveedor_id(proveedor, null, true)
 where proveedor_id is null;
update requisiciones set proveedor_id = _proveedor_id(proveedor, null, true)
 where proveedor_id is null and proveedor is not null;
update cfdi set proveedor_id = _proveedor_id(nombre_emisor, rfc_emisor, true)
 where proveedor_id is null and sentido = 'recibido';
update expediente_movimientos m
   set proveedor_id = coalesce((select f.proveedor_id from cfdi f where f.id = m.cfdi_id),
                               (select c.proveedor_id from compras c where c.id = m.compra_id))
 where m.proveedor_id is null and (m.cfdi_id is not null or m.compra_id is not null);

-- 5. Lo que ve la pantalla ----------------------------------------------------------------------

create or replace function _hoy_merida() returns date
language sql stable as $fn$ select (now() at time zone 'America/Merida')::date $fn$;

create or replace function _resumen_proveedor(p_id uuid) returns jsonb
language sql stable security definer set search_path = public as $fn$
  select jsonb_build_object(
    'compras', (select count(*) from compras c where c.proveedor_id = p_id and c.estado <> 'cancelada'),
    'comprado_12m', coalesce((select sum(c.total) from compras c
                               where c.proveedor_id = p_id and c.estado <> 'cancelada'
                                 and c.fecha >= _hoy_merida() - 365), 0),
    'facturas', (select count(*) from cfdi f where f.proveedor_id = p_id and f.estado_sat <> 'cancelado'),
    'por_pagar', coalesce((select sum(_saldo_cfdi(f.id)) from cfdi f
                            where f.proveedor_id = p_id and f.por_pagar and f.estado_sat <> 'cancelado'), 0),
    'vencido', coalesce((select sum(_saldo_cfdi(f.id)) from cfdi f
                          where f.proveedor_id = p_id and f.por_pagar and f.estado_sat <> 'cancelado'
                            and f.vence < _hoy_merida()), 0),
    'pagado_12m', coalesce((select sum(m.monto) from expediente_movimientos m
                             where m.proveedor_id = p_id and m.tipo = 'egreso'
                               and m.fecha >= _hoy_merida() - 365), 0),
    'productos', (select count(*) from producto_proveedores pp where pp.proveedor_id = p_id),
    'pedidos_abiertos', (select count(*) from requisiciones r
                          where r.proveedor_id = p_id and r.estado in ('pendiente', 'pedida')),
    'ultima', greatest((select max(c.fecha) from compras c where c.proveedor_id = p_id),
                       (select max(f.fecha)::date from cfdi f where f.proveedor_id = p_id),
                       (select max(m.fecha) from expediente_movimientos m where m.proveedor_id = p_id),
                       (select max(r.created_at)::date from requisiciones r where r.proveedor_id = p_id))
  )
$fn$;
revoke execute on function _resumen_proveedor(uuid) from public, anon, authenticated;

create or replace function _ficha_proveedor(p proveedores) returns jsonb
language sql stable as $fn$
  select jsonb_build_object('id', p.id, 'clave', p.clave, 'nombre', p.nombre, 'rfc', p.rfc, 'alias', to_jsonb(p.alias),
                            'contacto', p.contacto, 'telefono', p.telefono, 'email', p.email, 'notas', p.notas,
                            'activo', p.activo, 'created_at', p.created_at)
$fn$;

-- La lista: los activos primero, luego lo que más se debe.
create or replace function proveedores_resumen() returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
begin
  if not es_admin() then
    raise exception 'Solo el administrador ve los proveedores.' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(x.f || jsonb_build_object('resumen', x.r)
                     order by x.activo desc, (x.r ->> 'por_pagar')::numeric desc, lower(x.nombre))
      from (select _ficha_proveedor(p) as f, _resumen_proveedor(p.id) as r, p.activo, p.nombre
              from proveedores p) x
  ), '[]'::jsonb);
end $fn$;

-- La carpeta: todo lo de un proveedor en una sola llamada.
create or replace function carpeta_proveedor(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare
  v_p proveedores;
begin
  if not es_admin() then
    raise exception 'Solo el administrador ve los proveedores.' using errcode = '42501';
  end if;
  v_p := (select p from proveedores p where p.id = p_id);
  if v_p.id is null then
    raise exception 'Ese proveedor no existe.' using errcode = '22023';
  end if;
  return jsonb_build_object(
    'proveedor', _ficha_proveedor(v_p),
    'resumen', _resumen_proveedor(p_id),
    'facturas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', f.id, 'serie', f.serie, 'folio', f.folio, 'uuid_fiscal', f.uuid_fiscal, 'fecha', f.fecha::date,
               'total', f.total, 'moneda', f.moneda, 'saldo', _saldo_cfdi(f.id), 'por_pagar', f.por_pagar,
               'vence', f.vence, 'estado_sat', f.estado_sat, 'metodo_pago', f.metodo_pago)
             order by f.fecha desc)
        from (select * from cfdi where proveedor_id = p_id order by fecha desc limit 60) f), '[]'::jsonb),
    'pagos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', m.id, 'fecha', m.fecha, 'monto', m.monto, 'iva', m.iva, 'categoria', m.categoria,
               'concepto', m.concepto, 'forma', m.forma, 'referencia', m.referencia, 'cfdi_id', m.cfdi_id,
               'factura', (select nullif(concat_ws(' ', f.serie, f.folio), '') from cfdi f where f.id = m.cfdi_id),
               'archivo', m.archivo)
             order by m.fecha desc, m.created_at desc)
        from (select * from expediente_movimientos
               where proveedor_id = p_id and tipo = 'egreso'
               order by fecha desc, created_at desc limit 60) m), '[]'::jsonb),
    'compras', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'folio', c.folio, 'factura', c.factura, 'fecha', c.fecha, 'total', c.total,
               'estado', c.estado, 'proveedor_texto', c.proveedor)
             order by c.fecha desc, c.folio desc)
        from (select * from compras where proveedor_id = p_id order by fecha desc, folio desc limit 40) c), '[]'::jsonb),
    'pedidos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', r.id, 'folio', r.folio, 'estado', r.estado, 'cantidad', r.cantidad,
               'sku', pr.sku, 'producto', pr.nombre, 'referencia', r.referencia,
               'fecha_pedido', r.fecha_pedido, 'fecha_recibida', r.fecha_recibida)
             order by (r.estado in ('pendiente', 'pedida')) desc, r.created_at desc)
        from (select * from requisiciones
               where proveedor_id = p_id
                 and (estado in ('pendiente', 'pedida') or created_at >= now() - interval '120 days')
               order by created_at desc limit 60) r
        join productos pr on pr.id = r.producto_id), '[]'::jsonb),
    'productos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pr.id, 'sku', pr.sku, 'nombre', pr.nombre, 'codigo', pp.proveedor_sku,
               'opcion', pp.opcion, 'costo', pp.costo_mxn)
             order by pp.opcion nulls last, pr.sku)
        from (select * from producto_proveedores where proveedor_id = p_id
               order by opcion nulls last, proveedor_sku limit 40) pp
        join productos pr on pr.id = pp.producto_id), '[]'::jsonb)
  );
end $fn$;

-- 6. Editar, unir y separar ---------------------------------------------------------------------

create or replace function guardar_proveedor(p_id uuid, p_datos jsonb) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_nombre  text := nullif(trim(regexp_replace(coalesce(p_datos ->> 'nombre', ''), '\s+', ' ', 'g')), '');
  v_rfc_txt text := nullif(upper(regexp_replace(coalesce(p_datos ->> 'rfc', ''), '[\s-]', '', 'g')), '');
  v_rfc     text := _rfc_valido(p_datos ->> 'rfc');
  v_alias   text[];
  v_otro    proveedores;
  v_antes   proveedores;
  v_id      uuid := p_id;
begin
  if not es_admin() then
    raise exception 'Solo el administrador edita proveedores.' using errcode = '42501';
  end if;
  if v_nombre is null or _clave_proveedor(v_nombre) = '' then
    raise exception 'Escribe el nombre del proveedor.' using errcode = '22023';
  end if;
  if v_rfc_txt in ('XAXX010101000', 'XEXX010101000') then
    raise exception 'Ese es el RFC genérico del SAT: déjalo vacío.' using errcode = '22023';
  end if;
  if v_rfc_txt is not null and v_rfc is null then
    raise exception 'El RFC no tiene el formato del SAT (12 o 13 caracteres, como ABC010101XY1).' using errcode = '22023';
  end if;

  if v_rfc is not null then
    v_otro := (select p from proveedores p where p.rfc = v_rfc and p.id is distinct from p_id);
    if v_otro.id is not null then
      raise exception 'Ese RFC ya es de "%". Si son el mismo proveedor, únelos.', v_otro.nombre using errcode = '22023';
    end if;
  end if;
  v_otro := (select p from proveedores p
              where p.nombre_clave = _clave_proveedor(v_nombre) and p.id is distinct from p_id);
  if v_otro.id is not null then
    raise exception 'Ya existe un proveedor con ese nombre: "%".', v_otro.nombre using errcode = '22023';
  end if;

  v_alias := coalesce((
    select array_agg(distinct a order by a)
      from (select nullif(trim(x), '') as a
              from jsonb_array_elements_text(coalesce(p_datos -> 'alias', '[]'::jsonb)) x) s
     where a is not null and lower(a) <> lower(v_nombre)), '{}');

  if p_id is null then
    v_id := gen_random_uuid();
    insert into proveedores (id, nombre, rfc, alias, contacto, telefono, email, notas, activo, creado_por)
    values (v_id, v_nombre, v_rfc, v_alias,
            nullif(trim(p_datos ->> 'contacto'), ''), nullif(trim(p_datos ->> 'telefono'), ''),
            nullif(trim(p_datos ->> 'email'), ''), nullif(trim(p_datos ->> 'notas'), ''),
            coalesce((p_datos ->> 'activo')::boolean, true), coalesce(auth.jwt() ->> 'email', 'crm'));
    perform _apunta('proveedores', v_id, 'alta', null,
                    (select to_jsonb(p) from proveedores p where p.id = v_id), 'oficina');
  else
    v_antes := (select p from proveedores p where p.id = p_id);
    if v_antes.id is null then
      raise exception 'Ese proveedor no existe.' using errcode = '22023';
    end if;
    update proveedores
       set nombre = v_nombre, rfc = v_rfc, alias = v_alias,
           contacto = nullif(trim(p_datos ->> 'contacto'), ''), telefono = nullif(trim(p_datos ->> 'telefono'), ''),
           email = nullif(trim(p_datos ->> 'email'), ''), notas = nullif(trim(p_datos ->> 'notas'), ''),
           activo = coalesce((p_datos ->> 'activo')::boolean, activo), updated_at = now()
     where id = p_id;
    perform _apunta('proveedores', p_id, 'editar', to_jsonb(v_antes),
                    (select to_jsonb(p) from proveedores p where p.id = p_id), 'oficina');
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $fn$;

-- Junta dos fichas en una: todo lo de `p_se_va` pasa a `p_queda` y `p_se_va` desaparece. Su
-- nombre queda como alias (así su siguiente factura se reconoce sola). Dos RFC distintos son dos
-- empresas distintas: no se unen.
create or replace function unir_proveedores(p_queda uuid, p_se_va uuid) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_q proveedores;
  v_s proveedores;
  v_n jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador une proveedores.' using errcode = '42501';
  end if;
  if p_queda is null or p_se_va is null or p_queda = p_se_va then
    raise exception 'Elige dos proveedores distintos.' using errcode = '22023';
  end if;
  v_q := (select p from proveedores p where p.id = p_queda);
  v_s := (select p from proveedores p where p.id = p_se_va);
  if v_q.id is null or v_s.id is null then
    raise exception 'Uno de los dos proveedores ya no existe.' using errcode = '22023';
  end if;
  if v_q.rfc is not null and v_s.rfc is not null and v_q.rfc <> v_s.rfc then
    raise exception 'Tienen RFC distintos (% y %): son dos empresas, no se pueden unir.', v_q.rfc, v_s.rfc
      using errcode = '22023';
  end if;
  if v_q.clave is not null and v_s.clave is not null then
    raise exception 'Los dos vienen de una sincronización (% y %): son proveedores distintos.', v_q.clave, v_s.clave
      using errcode = '22023';
  end if;

  v_n := jsonb_build_object(
    'compras', (select count(*) from compras where proveedor_id = p_se_va),
    'pedidos', (select count(*) from requisiciones where proveedor_id = p_se_va),
    'productos', (select count(*) from producto_proveedores where proveedor_id = p_se_va),
    'facturas', (select count(*) from cfdi where proveedor_id = p_se_va),
    'pagos', (select count(*) from expediente_movimientos where proveedor_id = p_se_va));

  update compras                set proveedor_id = p_queda where proveedor_id = p_se_va;
  update requisiciones          set proveedor_id = p_queda where proveedor_id = p_se_va;
  update producto_proveedores   set proveedor_id = p_queda where proveedor_id = p_se_va;
  update cfdi                   set proveedor_id = p_queda where proveedor_id = p_se_va;
  update expediente_movimientos set proveedor_id = p_queda where proveedor_id = p_se_va;

  delete from proveedores where id = p_se_va;   -- primero, para liberar su RFC, clave y nombre
  update proveedores p
     set clave = coalesce(p.clave, v_s.clave),
         rfc = coalesce(p.rfc, v_s.rfc),
         alias = (select coalesce(array_agg(distinct a order by a), '{}')
                    from unnest(p.alias || v_s.alias || v_s.nombre) a
                   where lower(a) <> lower(p.nombre)),
         contacto = coalesce(p.contacto, v_s.contacto),
         telefono = coalesce(p.telefono, v_s.telefono),
         email = coalesce(p.email, v_s.email),
         notas = nullif(concat_ws(E'\n', p.notas, v_s.notas), ''),
         updated_at = now()
   where p.id = p_queda;

  perform _apunta('proveedores', p_queda, 'unir', to_jsonb(v_s),
                  jsonb_build_object('queda', (select to_jsonb(p) from proveedores p where p.id = p_queda), 'movidos', v_n),
                  'oficina');
  return jsonb_build_object('ok', true, 'id', p_queda, 'movidos', v_n);
end $fn$;

-- La primera palabra de un nombre, para proponer parejas ("cummins" en "Cummins" y
-- "Cummins Sales and Service").
create or replace function _primera_palabra(p text) returns text
language sql immutable parallel safe set search_path = public as $fn$
  select split_part(trim(regexp_replace(lower(unaccent_inmutable(coalesce(p, ''))), '[^a-z0-9]+', ' ', 'g')), ' ', 1)
$fn$;

-- Parejas que PARECEN el mismo proveedor: un nombre empieza con el otro, o comparten la primera
-- palabra (de 4 letras o más). Nunca dos con RFC distinto, dos de sincronización, ni una pareja
-- ya marcada como distinta.
create or replace function proveedores_parecidos() returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
begin
  if not es_admin() then
    raise exception 'Solo el administrador ve los proveedores.' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('a', _ficha_proveedor(a), 'b', _ficha_proveedor(b)) order by lower(a.nombre))
      from proveedores a
      join proveedores b on a.id < b.id
     where a.nombre_clave <> '' and b.nombre_clave <> ''
       and not (a.rfc is not null and b.rfc is not null and a.rfc <> b.rfc)
       and not (a.clave is not null and b.clave is not null)
       and not exists (select 1 from proveedores_distintos d where d.a = a.id and d.b = b.id)
       and ((length(a.nombre_clave) >= 4 and b.nombre_clave like a.nombre_clave || '%')
         or (length(b.nombre_clave) >= 4 and a.nombre_clave like b.nombre_clave || '%')
         or (length(_primera_palabra(a.nombre)) >= 4 and _primera_palabra(a.nombre) = _primera_palabra(b.nombre)))
  ), '[]'::jsonb);
end $fn$;

create or replace function marcar_proveedores_distintos(p_a uuid, p_b uuid) returns jsonb
language plpgsql security definer set search_path = public as $fn$
begin
  if not es_admin() then
    raise exception 'Solo el administrador edita proveedores.' using errcode = '42501';
  end if;
  if p_a is null or p_b is null or p_a = p_b then
    raise exception 'Elige dos proveedores distintos.' using errcode = '22023';
  end if;
  insert into proveedores_distintos (a, b, marcado_por)
  values (least(p_a, p_b), greatest(p_a, p_b), coalesce(auth.jwt() ->> 'email', 'crm'))
  on conflict do nothing;
  return jsonb_build_object('ok', true);
end $fn$;

revoke execute on function proveedores_resumen(), carpeta_proveedor(uuid), guardar_proveedor(uuid, jsonb),
  unir_proveedores(uuid, uuid), proveedores_parecidos(), marcar_proveedores_distintos(uuid, uuid)
  from public, anon;
grant execute on function proveedores_resumen(), carpeta_proveedor(uuid), guardar_proveedor(uuid, jsonb),
  unir_proveedores(uuid, uuid), proveedores_parecidos(), marcar_proveedores_distintos(uuid, uuid)
  to authenticated;
revoke execute on function _ficha_proveedor(proveedores) from public, anon, authenticated;

insert into _migraciones (archivo, tipo) values ('80_proveedores.sql', 'esquema')
on conflict (archivo) do nothing;
