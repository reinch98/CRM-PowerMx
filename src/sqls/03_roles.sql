-- ===========================================================================
-- ROLES Y PERFILES
-- Hasta ahora cualquier usuario autenticado veía todo. Esto separa por rol:
-- admin (tú), tecnico (campo) y cliente (a futuro, su propio portal).
-- Correr completo en el SQL Editor de crm-generadores.
-- ===========================================================================

create table perfiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nombre text,
  email text,
  rol text not null default 'sin_rol',   -- admin, tecnico, cliente, sin_rol
  telefono text,
  zona text,
  cliente_id uuid references clientes(id),  -- solo para rol cliente
  activo boolean default true,
  created_at timestamptz default now()
);

create index idx_perfiles_rol on perfiles(rol) where activo;

-- Todo usuario nuevo entra sin permisos. Tú lo promueves desde la pantalla
-- de Técnicos. Así nadie se da de alta y ve la operación completa.
create or replace function crear_perfil()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into perfiles (id, email, nombre)
  values (new.id, new.email, split_part(new.email, '@', 1))
  on conflict (id) do nothing;
  return new;
end $$;

create trigger al_crear_usuario
  after insert on auth.users
  for each row execute function crear_perfil();

-- Los usuarios que ya existían
insert into perfiles (id, email, nombre)
select id, email, split_part(email, '@', 1) from auth.users
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Funciones de apoyo. security definer para que puedan leer perfiles aunque
-- la política de perfiles todavía no le permita al usuario ver esa fila.
-- ---------------------------------------------------------------------------
create or replace function mi_rol() returns text
language sql stable security definer set search_path = public as $$
  select rol from perfiles where id = auth.uid() and activo
$$;

create or replace function es_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select rol from perfiles where id = auth.uid() and activo) = 'admin', false)
$$;

create or replace function mi_cliente() returns uuid
language sql stable security definer set search_path = public as $$
  select cliente_id from perfiles where id = auth.uid() and activo
$$;

-- ---------------------------------------------------------------------------
-- El técnico ahora es una referencia, no un texto suelto. Las columnas de
-- texto se quedan con lo ya capturado; las nuevas son las que cuentan.
-- ---------------------------------------------------------------------------
alter table citas add column if not exists tecnico_id uuid references perfiles(id);
alter table ordenes_servicio add column if not exists tecnico_id uuid references perfiles(id);

create index idx_citas_tecnico on citas(tecnico_id, fecha);
create index idx_citas_fecha on citas(fecha);
create index idx_ordenes_tecnico on ordenes_servicio(tecnico_id, fecha);

-- ===========================================================================
-- POLÍTICAS
-- Fuera las viejas de "todo para todos".
-- ===========================================================================
drop policy if exists "acceso_autenticado" on clientes;
drop policy if exists "acceso_autenticado" on equipos;
drop policy if exists "acceso_autenticado" on citas;
drop policy if exists "acceso_autenticado" on ordenes_servicio;
drop policy if exists "acceso_autenticado" on cotizaciones;
drop policy if exists "acceso_autenticado" on datos_fiscales;
drop policy if exists "acceso_autenticado" on catalogos;
drop policy if exists "acceso_autenticado" on productos;
drop policy if exists "lectura_autenticada" on movimientos_inventario;
drop policy if exists "insercion_autenticada" on movimientos_inventario;
drop policy if exists "lectura_autenticada" on auditoria;
drop policy if exists "insercion_autenticada" on auditoria;

alter table perfiles enable row level security;

-- Cada quien ve su propio perfil; el admin los ve y edita todos.
create policy "ve_su_perfil" on perfiles for select to authenticated
  using (id = auth.uid() or es_admin());
create policy "admin_edita_perfiles" on perfiles for all to authenticated
  using (es_admin()) with check (es_admin());

-- CLIENTES: el admin todo. El técnico solo lee (necesita nombre y dirección
-- para llegar). El cliente, solo su propia ficha.
create policy "admin_clientes" on clientes for all to authenticated
  using (es_admin()) with check (es_admin());
create policy "tecnico_lee_clientes" on clientes for select to authenticated
  using (mi_rol() = 'tecnico');
create policy "cliente_ve_lo_suyo" on clientes for select to authenticated
  using (mi_rol() = 'cliente' and id = mi_cliente());

-- EQUIPOS
create policy "admin_equipos" on equipos for all to authenticated
  using (es_admin()) with check (es_admin());
create policy "tecnico_lee_equipos" on equipos for select to authenticated
  using (mi_rol() = 'tecnico');
create policy "cliente_ve_sus_equipos" on equipos for select to authenticated
  using (mi_rol() = 'cliente' and cliente_id = mi_cliente());

-- CITAS: el técnico ve y actualiza solo las suyas.
create policy "admin_citas" on citas for all to authenticated
  using (es_admin()) with check (es_admin());
create policy "tecnico_ve_sus_citas" on citas for select to authenticated
  using (mi_rol() = 'tecnico' and tecnico_id = auth.uid());
create policy "tecnico_actualiza_sus_citas" on citas for update to authenticated
  using (mi_rol() = 'tecnico' and tecnico_id = auth.uid());
create policy "cliente_ve_sus_citas" on citas for select to authenticated
  using (mi_rol() = 'cliente' and cliente_id = mi_cliente());

-- ÓRDENES: el técnico registra las suyas y las relee, pero no las edita
-- después. Lo firmado por el cliente no se retoca.
create policy "admin_ordenes" on ordenes_servicio for all to authenticated
  using (es_admin()) with check (es_admin());
create policy "tecnico_crea_ordenes" on ordenes_servicio for insert to authenticated
  with check (mi_rol() = 'tecnico');
create policy "tecnico_ve_sus_ordenes" on ordenes_servicio for select to authenticated
  using (mi_rol() = 'tecnico' and tecnico_id = auth.uid());
create policy "cliente_ve_sus_ordenes" on ordenes_servicio for select to authenticated
  using (mi_rol() = 'cliente' and cliente_id = mi_cliente());

-- PRODUCTOS: solo el admin. El técnico usa la vista de abajo, que no trae
-- costo. RLS filtra renglones, no columnas; por eso se necesita la vista.
create policy "admin_productos" on productos for all to authenticated
  using (es_admin()) with check (es_admin());

create or replace view catalogo as
select id, sku, categoria, nombre, marca, modelo, descripcion,
       precio, precios, unidad, minimo, atributos, clave_producto_sat, clave_unidad_sat
from productos
where activo;

-- MOVIMIENTOS
create policy "admin_movimientos" on movimientos_inventario for all to authenticated
  using (es_admin()) with check (es_admin());
create policy "tecnico_lee_movimientos" on movimientos_inventario for select to authenticated
  using (mi_rol() = 'tecnico');

-- COTIZACIONES y DATOS FISCALES: nada para el técnico.
create policy "admin_cotizaciones" on cotizaciones for all to authenticated
  using (es_admin()) with check (es_admin());
create policy "cliente_ve_sus_cotizaciones" on cotizaciones for select to authenticated
  using (mi_rol() = 'cliente' and cliente_id = mi_cliente());

create policy "admin_datos_fiscales" on datos_fiscales for all to authenticated
  using (es_admin()) with check (es_admin());

-- CATÁLOGOS de autocompletado: los usa cualquiera que capture.
create policy "lee_catalogos" on catalogos for select to authenticated using (true);
create policy "escribe_catalogos" on catalogos for insert to authenticated with check (true);
create policy "actualiza_catalogos" on catalogos for update to authenticated using (true);

-- AUDITORÍA: se escribe siempre, se lee solo el admin, nadie la edita.
create policy "admin_lee_auditoria" on auditoria for select to authenticated
  using (es_admin());
create policy "todos_escriben_auditoria" on auditoria for insert to authenticated
  with check (true);

-- ===========================================================================
-- IMPORTANTE: date rol de admin a ti mismo o te quedas fuera de todo.
-- Cambia el correo si usas otra cuenta.
-- ===========================================================================
update perfiles set rol = 'admin', activo = true
where email = 'pablocana98@gmail.com';

-- Verifica antes de cerrar la pestaña:
select email, rol, activo from perfiles order by rol;
