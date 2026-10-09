-- ============================================================================
-- 68 · Registro de scripts aplicados (`_migraciones`)
--
-- Hasta hoy lo único que decía qué script se había corrido eran notas en CLAUDE.md,
-- y ya fallaban: el 09/10/2026 la 64 y la 65 estaban en `main` sin aplicarse.
--
-- Desde la 64, cada script de esquema o de datos TERMINA con su propio registro:
--
--   insert into _migraciones (archivo, tipo) values ('NN_nombre.sql', 'esquema')
--   on conflict (archivo) do nothing;
--
-- Las pruebas (`*_prueba_*`) y las consultas de solo lectura NO se registran: no
-- cambian la base.
--
-- Este script además hace el INVENTARIO de 01–63: por cada archivo busca un objeto
-- que solo ese script crea (una tabla, una función, una restricción, un texto
-- dentro de una función…) y lo registra solo si lo encuentra. No da nada por
-- aplicado a ciegas. Los que no se pueden comprobar (scripts de datos de una sola
-- vez) salen como "sin verificar": regístralos a mano si sabes que corrieron.
--
-- SQL plano, sin bloques plpgsql (el editor de Supabase los rompe). Se puede
-- repetir: la tabla es `if not exists` y el inventario usa `on conflict do nothing`.
-- No toca datos de ninguna otra tabla.
--
-- Orden: correr la 68 ANTES que la 64–67, que ya traen su registro al final.
-- ============================================================================

create table if not exists _migraciones (
  archivo     text primary key,
  numero      int  generated always as ((substring(archivo from '^[0-9]+'))::int) stored,
  tipo        text not null default 'esquema',
  aplicada_en timestamptz not null default now(),
  por         text not null default current_user,
  nota        text,
  constraint _migraciones_tipo check (tipo in ('esquema', 'datos')),
  constraint _migraciones_nombre check (archivo ~ '^[0-9]{2,}_[a-z0-9_]+\.sql$')
);

comment on table _migraciones is
  'Scripts de supabase/sql/ aplicados a esta base. Cada script se registra solo al final. Ver 68_registro_migraciones.sql.';

-- Solo el admin la lee desde la app; se escribe desde el editor SQL (rol postgres,
-- que no pasa por RLS). Supabase concede todo a anon y authenticated en cada tabla
-- nueva: se quita.
alter table _migraciones enable row level security;
revoke all on _migraciones from anon, authenticated;
grant select on _migraciones to authenticated;
drop policy if exists admin_lee_migraciones on _migraciones;
create policy admin_lee_migraciones on _migraciones for select to authenticated using (es_admin());

-- Registro del propio 68 (va antes del inventario para que el resultado de abajo
-- sea lo último que muestre el editor).
insert into _migraciones (archivo, tipo) values ('68_registro_migraciones.sql', 'esquema')
on conflict (archivo) do nothing;

-- ----------------------------------------------------------------------------
-- Inventario de 01–63. Clases de marca:
--   tabla         public.<nombre> existe
--   funcion       hay una función public.<nombre>
--   texto         la función <f> contiene <texto>          (nombre = 'f:texto')
--   columna       <tabla>.<columna> existe                 (nombre = 'tabla.columna')
--   restriccion   hay una restricción con ese nombre
--   restr_texto   la restricción <r> contiene <texto>      (nombre = 'r:texto')
--   politica      hay una política con ese nombre
--   sin_politica  la política ya NO existe (scripts que quitaron una)
--   vista_definer la vista está en security_invoker = off
--   sin_anon      anon no puede leer esa vista
--   bucket        existe el bucket de Storage
--   bucket_mime   el bucket acepta ese tipo                (nombre = 'bucket:tipo')
--   hay_filas     el catálogo tiene al menos un producto
--   manual        no hay forma fiable de comprobarlo
-- Las consultas de solo lectura (31, 32, 38, 48_ver, 49_ver) no van: no cambian nada.
-- ----------------------------------------------------------------------------
with m (archivo, tipo, clase, nombre) as (values
  ('01_productos.sql',                                  'esquema', 'tabla',         'productos'),
  ('02_catalogo.sql',                                   'datos',   'hay_filas',     'productos'),
  ('03_roles.sql',                                      'esquema', 'tabla',         'perfiles'),
  ('04_vistas_seguras.sql',                             'esquema', 'sin_anon',      'catalogo'),
  ('05_vistas_por_rol.sql',                             'esquema', 'vista_definer', 'existencias'),
  ('06_storage_ordenes.sql',                            'esquema', 'bucket',        'ordenes'),
  ('07_cotizacion_estado.sql',                          'esquema', 'funcion',       'cambiar_estado_cotizacion'),
  ('08_requisiciones.sql',                              'esquema', 'tabla',         'requisiciones'),
  ('09_flujo_servicio_base.sql',                        'esquema', 'tabla',         'orden_partes'),
  ('10_cotizacion_abre_cita.sql',                       'esquema', 'texto',         'cambiar_estado_cotizacion:por_programar'),
  ('11_agenda_citas.sql',                               'esquema', 'funcion',       'agendar_cita'),
  ('12_cerrar_orden.sql',                               'esquema', 'funcion',       'cerrar_orden'),
  ('13_retirar_orden_libre.sql',                        'esquema', 'sin_politica',  'tecnico_crea_ordenes'),
  ('14_almacen_entregas.sql',                           'esquema', 'tabla',         'orden_surtido'),
  ('15_contactos.sql',                                  'esquema', 'tabla',         'contactos'),
  ('16_avisos_de_cita.sql',                             'esquema', 'tabla',         'avisos'),
  ('17_citas_canceladas_sin_fecha.sql',                 'esquema', 'restr_texto',   'citas_fecha_segun_estado:cancelada'),
  ('18_uso_y_devoluciones.sql',                         'esquema', 'tabla',         'devoluciones'),
  ('19_solicitudes_material.sql',                       'esquema', 'tabla',         'solicitudes_material'),
  ('20_pdf_orden.sql',                                  'esquema', 'tabla',         'ordenes_pdf'),
  ('21_tarifas_catalogo.sql',                           'esquema', 'restriccion',   'tarifas_servicio_sku_si_catalogo'),
  ('22_whatsapp_bandeja.sql',                           'esquema', 'tabla',         'conversaciones'),
  ('23_equipo_en_campo.sql',                            'esquema', 'funcion',       'equipos_sin_serie'),
  ('24_revision_orden.sql',                             'esquema', 'tabla',         'orden_revision'),
  ('25_placas_equipo.sql',                              'esquema', 'funcion',       'guardar_placa'),
  ('26_componente_equipo.sql',                          'esquema', 'funcion',       'actualizar_componente'),
  ('27_agente_whatsapp.sql',                            'esquema', 'tabla',         'wa_agente'),
  ('28_paquetes_preventivo.sql',                        'esquema', 'tabla',         'paquetes_mantenimiento'),
  ('29_fase5_paquetes.sql',                             'esquema', 'funcion',       'piezas_que_se_repiten'),
  ('30_modo_vistas.sql',                                'esquema', 'vista_definer', 'catalogo'),
  ('34_cliente_necesita_cliente_id.sql',                'esquema', 'restriccion',   'perfiles_cliente_ligado'),
  ('35_cerrar_escritura.sql',                           'esquema', 'politica',      'admin_catalogos'),
  ('36_solicitudes_web.sql',                            'esquema', 'tabla',         'solicitudes_web'),
  ('37_wa_cotizar_preventivo.sql',                      'esquema', 'funcion',       'wa_cotizar_preventivo'),
  ('39_catalogo_publico.sql',                           'esquema', 'funcion',       'catalogo_publico'),
  ('40_pendientes_admin.sql',                           'esquema', 'funcion',       'pendientes_admin'),
  ('41_compras.sql',                                    'esquema', 'tabla',         'compras'),
  ('42_inicio_admin.sql',                               'esquema', 'funcion',       'inicio_admin'),
  ('43_quitar_producto.sql',                            'esquema', 'funcion',       'quitar_producto'),
  ('44_sync_proveedor.sql',                             'esquema', 'tabla',         'proveedor_productos'),
  ('45_importar_productos_proveedor.sql',               'esquema', 'funcion',       'importar_productos_proveedor'),
  ('46_publicar_al_aprobar_precio.sql',                 'esquema', 'funcion',       '_aplicar_precio'),
  ('47_refacciones_subcategoria.sql',                   'datos',   'manual',        null),
  ('48_quitar_baterias_y_paneles_fuera_del_excel.sql',  'datos',   'manual',        null),
  ('49_borrar_definitivamente_baterias_y_paneles.sql',  'datos',   'manual',        null),
  ('50_sync_conserva_documentos.sql',                   'esquema', 'texto',         'sync_recibir_lote:excluded.documentos'),
  ('51_segundo_proveedor.sql',                          'esquema', 'tabla',         'producto_proveedores'),
  ('52_disponibilidad_y_promociones.sql',               'esquema', 'columna',       'productos.precio_promocion'),
  ('53_bucket_ordenes_pdf.sql',                         'esquema', 'bucket_mime',   'ordenes:application/pdf'),
  ('54_recordatorio_cita.sql',                          'esquema', 'funcion',       'generar_recordatorios'),
  ('55_importar_clientes_whatsapp.sql',                 'esquema', 'tabla',         'importacion_whatsapp'),
  ('56_salida_whatsapp.sql',                            'esquema', 'tabla',         'wa_config'),
  ('57_campanas_whatsapp.sql',                          'esquema', 'tabla',         'campana_tandas'),
  ('58_envio_whatsapp.sql',                             'esquema', 'politica',      'ordenes_bot_lee_enviados'),
  ('59_cotizacion_pago_garantia.sql',                   'esquema', 'columna',       'cotizaciones.forma_pago'),
  ('60_eliminar_cotizacion.sql',                        'esquema', 'funcion',       'eliminar_cotizacion'),
  ('61_expediente_cotizacion.sql',                      'esquema', 'tabla',         'expediente_movimientos'),
  ('62_compra_de_factura.sql',                          'esquema', 'funcion',       'registrar_compra_de_factura'),
  ('63_cobranza_cotizacion.sql',                        'esquema', 'columna',       'expediente_movimientos.leido_ia')
),
v as (
  select m.*,
    case m.clase
      when 'tabla' then to_regclass('public.' || m.nombre) is not null
      when 'funcion' then exists (
        select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = m.nombre)
      when 'texto' then exists (
        select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = split_part(m.nombre, ':', 1)
          and p.prosrc like '%' || split_part(m.nombre, ':', 2) || '%')
      when 'columna' then exists (
        select 1 from information_schema.columns
        where table_schema = 'public'
          and table_name = split_part(m.nombre, '.', 1)
          and column_name = split_part(m.nombre, '.', 2))
      when 'restriccion' then exists (select 1 from pg_constraint where conname = m.nombre)
      when 'restr_texto' then exists (
        select 1 from pg_constraint
        where conname = split_part(m.nombre, ':', 1)
          and pg_get_constraintdef(oid) like '%' || split_part(m.nombre, ':', 2) || '%')
      when 'politica' then exists (select 1 from pg_policies where policyname = m.nombre)
      when 'sin_politica' then not exists (select 1 from pg_policies where policyname = m.nombre)
      when 'vista_definer' then exists (
        select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relname = m.nombre
          and 'security_invoker=off' = any (coalesce(c.reloptions, '{}')))
      when 'sin_anon' then not has_table_privilege('anon', 'public.' || m.nombre, 'select')
      when 'bucket' then exists (select 1 from storage.buckets where id = m.nombre)
      when 'bucket_mime' then exists (
        select 1 from storage.buckets
        where id = split_part(m.nombre, ':', 1)
          and split_part(m.nombre, ':', 2) = any (allowed_mime_types))
      when 'hay_filas' then exists (select 1 from productos)
      else null
    end as ok
  from m
),
ins as (
  insert into _migraciones (archivo, tipo, nota)
  select archivo, tipo, 'inventario del 68: se encontró ' || clase || ' ' || nombre
  from v where ok
  on conflict (archivo) do nothing
  returning archivo
)
select v.archivo,
       case when v.ok then 'registrado'
            when v.ok is null then 'SIN VERIFICAR (regístralo a mano si corrió)'
            else 'NO ENCONTRADO: revisar' end as resultado,
       v.clase, v.nombre
from v
order by (v.ok is true), v.archivo;

-- Para registrar a mano uno que corrió y no se pudo comprobar (47, 48, 49):
--   insert into _migraciones (archivo, tipo, nota)
--   values ('47_refacciones_subcategoria.sql', 'datos', 'registrado a mano')
--   on conflict (archivo) do nothing;
--
-- Consultar: select numero, archivo, tipo, aplicada_en from _migraciones order by numero, archivo;
