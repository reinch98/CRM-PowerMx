-- ---------------------------------------------------------------------------
-- 49 (1 de 2) — VER la historia de los 20 productos desactivados (18 baterías y 2 paneles propios). Solo lee.
--
-- Se quitaron con el archivo 48 y quedaron DESACTIVADOS porque tenían historia. Esto dice cuál: cuántos
-- renglones tiene cada uno en cada tabla que lo referencia. Si solo tienen movimientos de inventario (lo que
-- deja la carga inicial), el archivo 2 los puede borrar. Si alguno sale en compras, pedidos o entregas, el
-- archivo 2 NO lo toca.
-- ---------------------------------------------------------------------------

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
)
select p.sku, p.activo,
       (select count(*) from movimientos_inventario x where x.producto_id = p.id) as movimientos,
       (select count(*) from compra_lineas x where x.producto_id = p.id) as compra_lineas,
       (select count(*) from requisiciones x where x.producto_id = p.id) as requisiciones,
       (select count(*) from entrega_lineas x where x.producto_id = p.id) as entrega_lineas,
       (select count(*) from orden_surtido x where x.producto_id = p.id) as orden_surtido,
       (select count(*) from paquete_lineas x where x.producto_id = p.id) as paquete_lineas,
       (select count(*) from solicitudes_material x where x.producto_id = p.id) as solicitudes_material
  from lista l
  join productos p on p.sku = l.sku
 order by p.sku;
