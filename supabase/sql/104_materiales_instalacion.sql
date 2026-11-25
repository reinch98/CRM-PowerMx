-- ---------------------------------------------------------------------------
-- 104 — Lista de materiales y mano de obra para cotizar instalaciones (pedido de Caña, 24/11/2026).
--
-- Hasta hoy las instalaciones (eléctrica y de gas de un generador, base de concreto, tanque,
-- transferencia) se cotizaban en el Excel ESTRUCTURA.xlsx: las hojas "INSTALACIÓN ELECTRICA" e
-- "INSTALACIÓN GAS" tienen los precios y la hoja "INSTALACIONES" las cotizaciones de antes. Ninguno
-- de esos materiales está en el catálogo (`productos`), así que NO mueven inventario: entran a la
-- cotización como partidas LIBRES (sin `producto_id`), igual que el diagnóstico y el traslado.
--
-- Cada renglón dice cuánto se usa según la distancia (metros del generador al interruptor
-- principal, o al tanque):
--     cantidad = cantidad_fija + por_metro × max(0, metros − metros_incluidos), hacia arriba.
-- `grupo` junta las opciones que se excluyen entre sí (cable calibre 2 o calibre 4; tubo cédula 40
-- o pared delgada): el cotizador deja elegir una y empieza con la `predeterminada`.
-- Las cantidades sembradas son un PUNTO DE PARTIDA (el Excel solo traía las de 15 m); Caña las
-- corrige en la pantalla Instalaciones → "Materiales y mano de obra", y en cada cotización se
-- pueden cambiar a mano.
--
-- `precio` es el precio al cliente SIN IVA (como en el Excel: la cotización suma el IVA).
-- `costo` es interno y opcional (el Excel lo traía como "costo × 1.56" en varios renglones).
-- Solo admin. Repetible: la siembra usa `on conflict (clave) do nothing`, así que correrlo otra
-- vez no pisa lo que Caña ya corrigió.
-- ---------------------------------------------------------------------------

create table if not exists materiales_instalacion (
  id uuid primary key default gen_random_uuid(),
  clave text not null unique,
  bloque text not null,
  tipo text not null default 'material',
  nombre text not null,
  descripcion text,
  unidad text not null default 'pza',
  costo numeric check (costo is null or costo >= 0),
  precio numeric not null check (precio >= 0),
  cantidad_fija numeric not null default 0 check (cantidad_fija >= 0),
  por_metro numeric not null default 0 check (por_metro >= 0),
  metros_incluidos numeric not null default 0 check (metros_incluidos >= 0),
  grupo text,
  predeterminado boolean not null default false,
  orden int not null default 0,
  activo boolean not null default true,
  actualizado_en timestamptz not null default now(),
  actualizado_por text
);

alter table materiales_instalacion drop constraint if exists materiales_instalacion_bloque;
alter table materiales_instalacion add constraint materiales_instalacion_bloque
  check (bloque in ('electrica', 'gas', 'base', 'otro'));
alter table materiales_instalacion drop constraint if exists materiales_instalacion_tipo;
alter table materiales_instalacion add constraint materiales_instalacion_tipo
  check (tipo in ('material', 'mano_obra'));

comment on table materiales_instalacion is
  'Materiales y mano de obra para cotizar instalaciones, con su regla de cantidad por metro (SQL 104). Partidas libres: no mueven inventario.';

-- Quién y cuándo lo cambió: lo pone la base, no el navegador.
create or replace function _sello_material_instalacion()
returns trigger
language plpgsql
set search_path to 'public'
as $fn$
begin
  new.actualizado_en := now();
  new.actualizado_por := coalesce(auth.jwt() ->> 'email', new.actualizado_por, 'crm');
  return new;
end $fn$;

drop trigger if exists sello_material_instalacion on materiales_instalacion;
create trigger sello_material_instalacion
  before insert or update on materiales_instalacion
  for each row execute function _sello_material_instalacion();

alter table materiales_instalacion enable row level security;
drop policy if exists admin_materiales_instalacion on materiales_instalacion;
create policy admin_materiales_instalacion on materiales_instalacion
  for all to authenticated using (es_admin()) with check (es_admin());
revoke all on materiales_instalacion from anon;
grant select, insert, update, delete on materiales_instalacion to authenticated;

-- Siembra desde ESTRUCTURA.xlsx (24/11/2026). Precios tal cual; cantidades por metro supuestas.
insert into materiales_instalacion
  (clave, bloque, tipo, nombre, descripcion, unidad, costo, precio, cantidad_fija, por_metro, metros_incluidos, grupo, predeterminado, orden)
values
  -- Eléctrica: dos fases y un neutro del calibre de fuerza (3 × metros + holgura).
  ('ele_cable_cal2', 'electrica', 'material', 'Cable cal. 2 AWG', null, 'm', 121, 188.76, 6, 3, 0, 'cable_fuerza', true, 10),
  ('ele_cable_cal4', 'electrica', 'material', 'Cable cal. 4 AWG', null, 'm', null, 111.633, 6, 3, 0, 'cable_fuerza', false, 11),
  ('ele_cable_cal5', 'electrica', 'material', 'Cable cal. 5', null, 'm', null, 78, 6, 3, 0, 'cable_fuerza', false, 12),
  ('ele_cable_cal14', 'electrica', 'material', 'Cable de señal cal. 14', null, 'm', null, 13.44, 8, 4, 0, null, false, 20),
  ('ele_tubo_ced40', 'electrica', 'material', 'Tubo pared gruesa 2" cédula 40 gris (3 m)', null, 'pza', 125, 175, 0, 0.3333, 0, 'tuberia', true, 30),
  ('ele_tubo_pd112', 'electrica', 'material', 'Tubo pared delgada 1 1/2" (3 m)', null, 'pza', 313, 488.28, 0, 0.3333, 0, 'tuberia', false, 31),
  ('ele_conduit_114', 'electrica', 'material', 'Conduit ligero verde 1 1/4" (3 m)', null, 'pza', null, 65.7, 0, 0.3333, 0, 'tuberia', false, 32),
  ('ele_cople_2', 'electrica', 'material', 'Cople 2"', null, 'pza', null, 25, 0, 0.3333, 0, null, false, 40),
  ('ele_codo_2', 'electrica', 'material', 'Codo 90° 2"', null, 'pza', 110, 171.6, 4, 0, 0, null, false, 41),
  ('ele_conector_pvc_2', 'electrica', 'material', 'Conector recto PVC gris 2"', null, 'pza', null, 15, 2, 0, 0, null, false, 42),
  ('ele_olb_2', 'electrica', 'material', 'Condulet OLB-OLL-OLR 2"', null, 'pza', 147, 229.32, 2, 0, 0, null, false, 43),
  ('ele_flexible_2', 'electrica', 'material', 'Tubo flexible de acero forrado PVC 2"', null, 'm', 221.21, 345.0876, 2, 0, 0, null, false, 44),
  ('ele_liquatite_2', 'electrica', 'material', 'Conector recto liquatite 2"', null, 'pza', 94.27, 147.0612, 2, 0, 0, null, false, 45),
  ('ele_abrazadera_2', 'electrica', 'material', 'Abrazadera 2"', null, 'pza', 13.24, 20.6544, 4, 0, 0, null, false, 46),
  ('ele_canal_u', 'electrica', 'material', 'Canal U', null, 'pza', 300, 468, 0, 0, 0, null, false, 47),
  ('ele_taquetes', 'electrica', 'material', 'Taquetes', null, 'pza', 76, 118.56, 1, 0, 0, null, false, 48),
  ('ele_tornillos', 'electrica', 'material', 'Tornillos', null, 'pza', null, 195, 1, 0, 0, null, false, 49),
  ('ele_empalme_gen', 'electrica', 'material', 'Conexiones de empalme a generador', null, 'pza', null, 500, 1, 0, 0, null, false, 50),
  -- Eléctrica opcional (cantidad 0: se sube a mano cuando el trabajo lo lleva).
  ('ele_gabinete', 'electrica', 'material', 'Gabinete eléctrico', null, 'pza', null, 1200, 0, 0, 0, null, false, 60),
  ('ele_gabinete_6040', 'electrica', 'material', 'Gabinete eléctrico 60×40', null, 'pza', null, 2650, 0, 0, 0, null, false, 61),
  ('ele_bloque_dist', 'electrica', 'material', 'Bloque distribuidor', null, 'pza', null, 6000, 0, 0, 0, null, false, 62),
  ('ele_gabinete_dist', 'electrica', 'material', 'Gabinete para distribuidor', null, 'pza', null, 1100, 0, 0, 0, null, false, 63),
  ('ele_terminal_dist', 'electrica', 'material', 'Terminal distribuidor', null, 'pza', null, 7000, 0, 0, 0, null, false, 64),
  ('ele_barra_neutros', 'electrica', 'material', 'Barra de neutros', null, 'pza', null, 1000, 0, 0, 0, null, false, 65),
  ('ele_barra_tierras', 'electrica', 'material', 'Barra de tierras', null, 'pza', null, 500, 0, 0, 0, null, false, 66),
  ('ele_mano_obra', 'electrica', 'mano_obra', 'Mano de obra de instalación eléctrica',
   'Mano de obra de instalación eléctrica: canalización en tubería, servicio de conexión y cableado a transferencia automática.',
   'servicio', null, 9000, 1, 0, 10, null, false, 90),
  ('ele_mano_obra_metro', 'electrica', 'mano_obra', 'Mano de obra eléctrica, por metro después de 10 m',
   'Canalización adicional por metro, después de los primeros 10 m.',
   'm', null, 370, 0, 1, 10, null, false, 91),
  -- Gas (el Excel trae 30 m de Durman para 15 m de distancia: 2 por metro).
  ('gas_durman', 'gas', 'material', 'Tubería PE-AL-PE (Durman)', null, 'm', null, 80, 0, 2, 0, null, false, 10),
  ('gas_codo', 'gas', 'material', 'Codo 90°', null, 'pza', null, 250, 5, 0, 0, null, false, 20),
  ('gas_reg_alta', 'gas', 'material', 'Regulador de alta', null, 'pza', null, 1800, 1, 0, 0, null, false, 21),
  ('gas_reg_baja', 'gas', 'material', 'Regulador de baja', null, 'pza', null, 1800, 1, 0, 0, null, false, 22),
  ('gas_punta_pol', 'gas', 'material', 'Punta POL', null, 'pza', null, 150, 1, 0, 0, null, false, 23),
  ('gas_con_macho', 'gas', 'material', 'Conector macho 3/4"', null, 'pza', null, 250, 8, 0, 0, null, false, 24),
  ('gas_con_hembra', 'gas', 'material', 'Conector hembra 3/4"', null, 'pza', null, 250, 8, 0, 0, null, false, 25),
  ('gas_bushing', 'gas', 'material', 'Bushing 3/4" – 1/4"', null, 'pza', null, 150, 2, 0, 0, null, false, 26),
  ('gas_te', 'gas', 'material', 'Te', null, 'pza', null, 250, 0, 0, 0, null, false, 27),
  ('gas_manometro', 'gas', 'material', 'Manómetro', null, 'pza', null, 800, 2, 0, 0, null, false, 28),
  ('gas_mano_obra', 'gas', 'mano_obra', 'Mano de obra de tubería de gas',
   'Mano de obra para tubería de gas: conexiones para alimentación de combustible a generador de emergencia.',
   'servicio', null, 7500, 1, 0, 0, null, false, 90),
  -- Base y extras (de las cotizaciones de la hoja INSTALACIONES).
  ('base_concreto', 'base', 'mano_obra', 'Base de concreto para generador y tanque',
   'Materiales y mano de obra para base de concreto de generador y tanque.',
   'servicio', null, 3200, 1, 0, 0, null, false, 10),
  ('otro_ats_100', 'otro', 'material', 'Transferencia automática 100 A', null, 'pza', null, 16500, 1, 0, 0, null, false, 10),
  ('otro_tanque_300', 'otro', 'material', 'Tanque estacionario 300 L, incluye maniobra a techo', null, 'pza', null, 12500, 1, 0, 0, null, false, 20)
on conflict (clave) do nothing;

insert into _migraciones (archivo, tipo) values ('104_materiales_instalacion.sql', 'esquema')
on conflict (archivo) do nothing;
