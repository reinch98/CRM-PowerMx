-- ===========================================================================
-- 01 · PRODUCTOS E INVENTARIO (archivo histórico)
--
-- ⚠ NO CORRER EN LA BASE ACTUAL. Se guarda para saber cómo nació la estructura
-- de productos, no para repetirse:
--   · borra la tabla `refacciones` y la columna `refaccion_id` (pierde datos);
--   · `create table productos` falla si la tabla ya existe;
--   · recrea las vistas SIN el filtro por rol de 05_vistas_por_rol.sql y deja la
--     política "acceso_autenticado" que 03_roles.sql ya retiró.
-- Es la excepción a la regla de "scripts repetibles" porque es el origen.
--
-- Estado actual de lo que aquí se crea:
--   · políticas de `productos`            → 03_roles.sql
--   · vista `catalogo` (sin costo)        → 03_roles.sql
--   · permisos de las vistas              → 04_vistas_seguras.sql
--   · filtro por rol de las vistas        → 05_vistas_por_rol.sql
--
-- Falta en el repo: el esquema de clientes, equipos, citas, ordenes_servicio,
-- cotizaciones, datos_fiscales, catalogos, auditoria y movimientos_inventario
-- (esta última se crea antes de este archivo).
-- ===========================================================================

-- refacciones está vacía y queda absorbida por productos.
drop view if exists disponibles;
drop view if exists existencias;
drop view if exists resguardo_por_cliente;
drop table if exists refacciones cascade;

create table productos (
  id uuid primary key default gen_random_uuid(),
  sku text unique not null,
  categoria text not null,      -- generador, paquete_solar, bateria, panel, refaccion, renta
  nombre text not null,
  marca text,
  modelo text,
  descripcion text,

  precio numeric,               -- precio de lista
  costo numeric,                -- interno, NUNCA se publica
  moneda text default 'MXN',
  precios jsonb default '{}',   -- rentas (24hr/48hr/semana), paquetes (estandar/hibrido)

  clave_producto_sat text,
  clave_unidad_sat text default 'H87',
  unidad text default 'pieza',

  minimo int default 0,
  atributos jsonb default '{}',

  publicar boolean default true,
  activo boolean default true,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create index idx_productos_categoria on productos(categoria) where activo;
create index idx_productos_sku on productos(sku);

alter table movimientos_inventario drop column refaccion_id;
alter table movimientos_inventario
  add column producto_id uuid not null references productos(id);

create index idx_mov_producto on movimientos_inventario(producto_id);

alter table productos enable row level security;
create policy "acceso_autenticado" on productos
  for all to authenticated using (true) with check (true);

create view existencias as
select
  p.id, p.sku, p.categoria, p.nombre, p.marca, p.unidad, p.minimo,
  coalesce(sum(case m.tipo
    when 'entrada' then m.cantidad
    when 'salida_venta' then -m.cantidad
    when 'consumo_resguardo' then -m.cantidad
    when 'consumo_servicio' then -m.cantidad
    when 'ajuste' then m.cantidad
    else 0 end), 0) as fisico,
  coalesce(sum(case m.tipo
    when 'apartado' then m.cantidad
    when 'libera_apartado' then -m.cantidad
    when 'salida_venta' then -m.cantidad
    when 'a_resguardo' then -m.cantidad
    else 0 end), 0) as apartado,
  coalesce(sum(case m.tipo
    when 'a_resguardo' then m.cantidad
    when 'consumo_resguardo' then -m.cantidad
    else 0 end), 0) as resguardo
from productos p
left join movimientos_inventario m on m.producto_id = p.id
where p.activo
group by p.id;

create view disponibles as
select *, fisico - apartado - resguardo as disponible
from existencias;

create view resguardo_por_cliente as
select
  m.cliente_id, c.nombre as cliente, m.producto_id, p.sku, p.nombre as producto,
  sum(case m.tipo
    when 'a_resguardo' then m.cantidad
    when 'consumo_resguardo' then -m.cantidad
    else 0 end) as en_resguardo
from movimientos_inventario m
join productos p on p.id = m.producto_id
join clientes c on c.id = m.cliente_id
where m.tipo in ('a_resguardo', 'consumo_resguardo')
group by m.cliente_id, c.nombre, m.producto_id, p.sku, p.nombre
having sum(case m.tipo when 'a_resguardo' then m.cantidad else -m.cantidad end) > 0;

create view por_reordenar as
select * from disponibles
where minimo > 0 and disponible < minimo;
