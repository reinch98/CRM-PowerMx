-- ---------------------------------------------------------------------------
-- 49 (2 de 2) — BORRAR DEFINITIVAMENTE los 20 productos desactivados (18 baterías y 2 paneles propios).
--
-- Pedido de Caña (30/09/2026). IRREVERSIBLE. Corre antes el archivo 1 y revisa la historia de cada uno.
--
--   · Solo borra un producto que YA está desactivado y que no aparece en compras, pedidos, entregas, listas de
--     surtido, paquetes ni solicitudes de material. A los que sí aparecen NO los toca y lo dice en el resultado.
--   · Lo único que borra de su historia son los MOVIMIENTOS DE INVENTARIO (las foreign keys no dejan borrar el
--     producto con ellos). Ese es el libro del inventario, que normalmente solo se inserta: por eso cada
--     movimiento borrado queda COPIADO completo en `auditoria` (valor_anterior), junto con el producto.
--   · El historial de precios y la cola de revisión del sync se van solos con el producto (on delete cascade).
--   · Las cotizaciones viejas no se alteran: copian los datos del producto en sus partidas.
--
-- Correr el bloque completo.
-- ---------------------------------------------------------------------------

begin;

with lista(sku) as (values
  ('BAT-BYD-BATTERY-BOX-5KWH'),
  ('BAT-BYD-BATTERY-BOX-PREMIUM-15KWH'),
  ('BAT-BYD-MC-CUBE-T'),
  ('BAT-CATL-ENERC-100KWH'),
  ('BAT-CATL-ENERONE-50KWH'),
  ('BAT-DYNESS-INDUSTRIAL-75KWH'),
  ('BAT-DYNESS-POWERRACK-B4850'),
  ('BAT-GROWATT-ARK-2-56H'),
  ('BAT-GROWATT-ARK-HV-20KWH'),
  ('BAT-GROWATT-SPF-3000TL-HV'),
  ('BAT-PYLONTECH-FORCE-H2'),
  ('BAT-PYLONTECH-POWERCUBE-X-RC15'),
  ('BAT-PYLONTECH-US2000C'),
  ('BAT-PYLONTECH-US3000C'),
  ('BAT-SOFAR-BTS-E20-DS5'),
  ('BAT-SOLIS-RHI-BAT-6KWH'),
  ('BAT-TROJAN-T-105-AGM'),
  ('BAT-VISION-HF12-200A-AGM'),
  ('SOL-PAN-CANADIAN-440W'),
  ('SOL-PAN-JINKO-450W')
), objetivo as (
  select p.id, p.sku, to_jsonb(p) as producto
    from productos p
    join lista l on l.sku = p.sku
   where not p.activo
     and not exists (select 1 from compra_lineas x where x.producto_id = p.id)
     and not exists (select 1 from requisiciones x where x.producto_id = p.id)
     and not exists (select 1 from entrega_lineas x where x.producto_id = p.id)
     and not exists (select 1 from orden_surtido x where x.producto_id = p.id)
     and not exists (select 1 from paquete_lineas x where x.producto_id = p.id)
     and not exists (select 1 from solicitudes_material x where x.producto_id = p.id)
), movs as (
  delete from movimientos_inventario m
   where m.producto_id in (select id from objetivo)
  returning m.producto_id, to_jsonb(m) as movimiento
), rastro as (
  insert into auditoria (tabla, registro_id, accion, valor_anterior, valor_nuevo, origen, usuario)
  select 'productos', o.id, 'eliminar_definitivo',
         jsonb_build_object('producto', o.producto,
                            'movimientos', coalesce((select jsonb_agg(mv.movimiento) from movs mv where mv.producto_id = o.id), '[]'::jsonb)),
         null, 'oficina', 'crm'
    from objetivo o
  returning registro_id
), borrados as (
  delete from productos p where p.id in (select id from objetivo)
  returning p.sku
)
select l.sku,
       case when b.sku is not null then 'BORRADO'
            when p.id is null then 'ya no existía'
            when p.activo then 'NO se borró: sigue activo'
            else 'NO se borró: aparece en compras, pedidos, entregas, surtido, paquetes o solicitudes' end as resultado,
       (select count(*) from movs mv where mv.producto_id = p.id) as movimientos_borrados
  from lista l
  left join productos p on p.sku = l.sku
  left join borrados b on b.sku = l.sku
 order by l.sku;

commit;
