-- ============================================================================
-- 83 · Liquid Cooled (uno solo) y "Equipos diésel": equipos que se cotizan por separado
--
-- Pedido de Caña (18/10/2026): de los LIQUIDCOOLED solo debe quedar UNO por omisión, y manda a una
-- cotización aparte (sin precio en el catálogo); y un producto nuevo, "Equipos diésel", que también
-- se cotiza por separado.
--
--   · LIQ-32 queda como el único "Liquid Cooled": sin precio y sin los datos que eran de relleno
--     (kW, fase, voltaje y garantía de un modelo concreto; la descripción hablaba de 55 kW en un equipo
--     de 32). La capacidad se define con cada proyecto.
--   · LIQ-34 se desactiva y se quita del sitio (tiene un movimiento de inventario, así que no se borra).
--   · GEN-DIESEL es el producto nuevo. Sin precio: el sitio lo muestra como "se cotiza por separado" y manda
--     a cotizar por WhatsApp; en Cotizaciones se agrega como partida libre con el precio del proyecto.
-- Se puede repetir sin problema: fija valores, no suma.
-- ============================================================================

update productos set
  nombre      = 'Liquid Cooled',
  modelo      = 'Liquid Cooled',
  descripcion = 'Plantas de emergencia enfriadas por líquido para uso comercial e industrial. La capacidad y el tablero de transferencia se definen según el proyecto: se cotiza por separado.',
  precio      = null,
  atributos   = (atributos - 'kw' - 'fase' - 'voltaje' - 'garantia_anios')
                || jsonb_build_object('segmento', 'industrial', 'combustible', 'gas')
where sku = 'LIQ-32' and categoria = 'generador';

update productos set activo = false, publicar = false
where sku = 'LIQ-34' and categoria = 'generador';

insert into productos (sku, nombre, modelo, categoria, descripcion, precio, moneda, unidad, atributos, activo, publicar)
values (
  'GEN-DIESEL', 'Equipos diésel', 'Equipos diésel', 'generador',
  'Plantas de emergencia a diésel. El equipo se define según la carga y el proyecto: se cotiza por separado.',
  null, 'MXN', 'pieza',
  jsonb_build_object('segmento', 'industrial', 'combustible', 'diesel'),
  true, true
)
on conflict (sku) do update set
  nombre = excluded.nombre, modelo = excluded.modelo, descripcion = excluded.descripcion,
  precio = null, atributos = excluded.atributos, activo = true, publicar = true;

insert into _migraciones (archivo, tipo) values ('83_liquidcooled_y_diesel.sql', 'datos')
on conflict (archivo) do nothing;
