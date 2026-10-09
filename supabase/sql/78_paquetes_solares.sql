-- ============================================================================
-- 78 · Paquetes solares armados en el CRM (recetas, costo y precio en la base)
--
-- Requiere el 44/51/52 (proveedor, reglas de margen, parametros_costeo). Decisiones de Caña (09/10/2026):
--   · El precio publicado INCLUYE IVA, redondeado hacia arriba a miles y terminado en 999.
--   · Se ofrecen las DOS variantes con batería además del interconectado:
--       interconectado  = la receta "interconectado"                      → productos.precios.estandar
--       hibrido_a       = "interconectado" + "respaldo" (LUX 3 kW + PGEM)   → productos.precios.hibrido
--       hibrido_b       = la receta "hibrido_b" (todo en LUX 6 kW, no inyecta) → productos.precios.hibrido_b
--   · El margen es el de la REGLA DE MARGEN (categoría paquete_solar si existe; si no, la general), con
--     la misma fórmula de los productos sueltos (_precio_venta). No hay copia de la fórmula en JS.
--
-- Una receta es una lista de líneas por paquete y variante. Cada línea cuesta lo que diga:
--   · un PRODUCTO del catálogo (productos.costo, que mantiene la sincronización con el proveedor), o
--   · un PARÁMETRO de parametros_costeo (mano de obra, trámite, material eléctrico de compra local), o
--   · un costo fijo escrito en la línea.
-- costo = Σ(cantidad × unitario) × (1 + imprevistos). Recetas sembradas desde el "Borrador paquetes
-- solares PowerMx.xlsx" (30/09/2026), hoja Materiales: 373 líneas.
--
-- Candado (el mismo de los productos sueltos): un precio nuevo que mueve el publicado ±15 % o menos se
-- aplica solo al recalcular; más que eso, o un precio que nunca se publicó, espera a que el admin lo
-- publique. La PRIMERA publicación de cada variante desde la receta es siempre a mano
-- (atributos.receta_publicada), porque también cambia lo que el sitio dice del paquete.
-- recalcular_paquetes() lo llama la sincronización con el proveedor al terminar.
-- ============================================================================

create table if not exists paquete_solar_lineas (
  id           uuid primary key default gen_random_uuid(),
  paquete_id   uuid not null references productos(id) on delete cascade,
  variante     text not null check (variante in ('interconectado', 'respaldo', 'hibrido_b')),
  orden        int not null default 0,
  grupo        text,
  producto_id  uuid references productos(id),
  parametro    text references parametros_costeo(clave),
  costo_fijo   numeric(12, 2) check (costo_fijo is null or costo_fijo >= 0),
  concepto     text not null,
  cantidad     numeric(12, 4) not null check (cantidad > 0),
  tipo_costo   text not null check (tipo_costo in ('equipo', 'material_local', 'mano_obra')),
  created_at   timestamptz not null default now(),
  -- De dónde sale el costo: exactamente una fuente.
  constraint paquete_linea_una_fuente check (
    (producto_id is not null)::int + (parametro is not null)::int + (costo_fijo is not null)::int = 1)
);
create index if not exists idx_paquete_lineas on paquete_solar_lineas (paquete_id, variante, orden);

alter table paquete_solar_lineas enable row level security;
drop policy if exists admin_paquete_solar_lineas on paquete_solar_lineas;
create policy admin_paquete_solar_lineas on paquete_solar_lineas
  for all to authenticated using (es_admin()) with check (es_admin());
revoke all on paquete_solar_lineas from anon;
grant select, insert, update, delete on paquete_solar_lineas to authenticated;

-- La última foto del cálculo (la guarda recalcular_paquetes; la pantalla calcula en vivo).
alter table productos add column if not exists paquete_calculo jsonb;

-- Material eléctrico de compra local y datos del paquete (valores del borrador; "Confirmar" = estimado).
insert into parametros_costeo (clave, etiqueta, valor, unidad, nota, orden) values
  ('cable_ca_10awg_m', 'Cable THW-LS 10 AWG', 20, 'MXN/m', 'Precio estimado del borrador. Inversor de 3.3 kW.', 8),
  ('cable_ca_8awg_m', 'Cable THW-LS 8 AWG', 35, 'MXN/m', 'Precio estimado del borrador. Inversor de 6 kW y respaldo de 3 kW.', 9),
  ('cable_ca_6awg_m', 'Cable THW-LS 6 AWG', 55, 'MXN/m', 'Precio estimado del borrador. Inversor de 10 kW y LUX de 6 kW.', 10),
  ('cable_tierra_10awg_m', 'Cable de tierra 10 AWG (del arreglo al inversor)', 20, 'MXN/m', 'Precio estimado del borrador.', 11),
  ('conduit_m', 'Tubería conduit con accesorios', 45, 'MXN/m', 'Precio estimado del borrador.', 12),
  ('varilla_tierra', 'Varilla de tierra con conector', 450, 'MXN', 'Precio estimado del borrador. Por instalación.', 13),
  ('material_tablero', 'Interruptor en el tablero del cliente, zapatas y cinchos', 400, 'MXN', 'Precio estimado del borrador. Por instalación.', 14),
  ('centro_carga_esenciales', 'Centro de carga de cargas esenciales con interruptores', 1500, 'MXN', 'Precio estimado del borrador. Solo híbridos.', 15),
  ('cables_bateria', 'Cables de batería con terminales', 800, 'MXN', 'Precio estimado del borrador. Si la batería ya los trae, pon 0.', 16),
  ('potencia_panel_w', 'Potencia del panel de los paquetes', 630, 'W', 'Para decir los kWp del paquete en el sitio. Cámbiala si cambias el panel de las recetas.', 17),
  ('ahorro_kwp_min', 'Ahorro al mes por kWp, mínimo', 333, 'MXN', 'Para el "ahorro estimado" del sitio.', 18),
  ('ahorro_kwp_max', 'Ahorro al mes por kWp, máximo', 500, 'MXN', null, 19),
  ('paquete_redondeo', 'Redondear el precio de los paquetes a múltiplos de', 1000, 'MXN', 'Hacia arriba, ya con IVA.', 23),
  ('paquete_terminacion', 'Y restarle (para terminar en 999)', 1, 'MXN', 'Pon 0 para precios cerrados.', 24)
on conflict (clave) do nothing;

-- ---- recetas del borrador (solo en paquetes que aún no tienen ninguna línea) ----
insert into paquete_solar_lineas (paquete_id, variante, orden, grupo, producto_id, parametro, concepto, cantidad, tipo_costo)
select pk.id, v.variante, v.orden, v.grupo, pr.id, v.parametro, v.concepto, v.cantidad, v.tipo
  from (values
  ('PKG-STARTER', 'interconectado', 1, 'Paneles', 'PSOJAS1S207', null, 'Panel solar 630 W bifacial N-type', 4.0, 'equipo'),
  ('PKG-STARTER', 'interconectado', 2, 'Inversor', 'INVGROWS4', null, 'Inversor interconectado 3.3 kW', 1.0, 'equipo'),
  ('PKG-STARTER', 'interconectado', 3, 'Estructura', 'SMOALM1S520', null, 'Estructura reforzada 4 paneles, 1 fila', 1.0, 'equipo'),
  ('PKG-STARTER', 'interconectado', 4, 'Estructura', 'SMOPVA1S289', null, 'Taquetes expansivos para concreto', 2.0, 'equipo'),
  ('PKG-STARTER', 'interconectado', 5, 'Cableado de CD', 'SINPVA1S341', null, 'Cable fotovoltaico 10 AWG rojo', 0.3, 'equipo'),
  ('PKG-STARTER', 'interconectado', 6, 'Cableado de CD', 'SINPVA1S342', null, 'Cable fotovoltaico 10 AWG negro', 0.3, 'equipo'),
  ('PKG-STARTER', 'interconectado', 7, 'Cableado de CD', 'SINPVA1S298', null, 'Conectores MC4 (5 pares)', 1.0, 'equipo'),
  ('PKG-STARTER', 'interconectado', 8, 'Protecciones de CD', 'PYMSUT1S112', null, 'Interruptor de CD 2P 32 A', 1.0, 'equipo'),
  ('PKG-STARTER', 'interconectado', 9, 'Protecciones de CD', 'PYM1033685S102', null, 'Supresor de picos de CD', 1.0, 'equipo'),
  ('PKG-STARTER', 'interconectado', 10, 'Protecciones de CD', 'SINOMN1S102', null, 'Caja IP65 de 6 módulos', 1.0, 'equipo'),
  ('PKG-STARTER', 'interconectado', 11, 'Etiquetas', 'SINPVA1S309', null, 'Etiquetas "Sistema fotovoltaico"', 0.1, 'equipo'),
  ('PKG-STARTER', 'interconectado', 12, 'Etiquetas', 'SINPVA1S306', null, 'Etiquetas "Desconectador principal"', 0.1, 'equipo'),
  ('PKG-STARTER', 'interconectado', 13, 'Etiquetas', 'SINPVA1S304', null, 'Etiquetas "Peligro de descarga"', 0.1, 'equipo'),
  ('PKG-STARTER', 'interconectado', 14, 'Etiquetas', 'SINPVA1S308', null, 'Etiquetas "Desconectador de CA"', 0.1, 'equipo'),
  ('PKG-STARTER', 'interconectado', 15, 'Etiquetas', 'SINPVA1S305', null, 'Etiquetas "Fuente de energía FV"', 0.1, 'equipo'),
  ('PKG-STARTER', 'interconectado', 16, 'Etiquetas', 'SINPVA1S307', null, 'Etiquetas "Desconectador de CD"', 0.1, 'equipo'),
  ('PKG-STARTER', 'interconectado', 17, 'Material local', null, 'cable_tierra_10awg_m', 'Cable de tierra 10 AWG del arreglo al inversor', 30.0, 'material_local'),
  ('PKG-STARTER', 'interconectado', 18, 'Material local', null, 'conduit_m', 'Tubería conduit con accesorios (CD + CA)', 40.0, 'material_local'),
  ('PKG-STARTER', 'interconectado', 19, 'Material local', null, 'varilla_tierra', 'Varilla de tierra con conector', 1.0, 'material_local'),
  ('PKG-STARTER', 'interconectado', 20, 'Material local', null, 'material_tablero', 'Interruptor en el tablero del cliente, zapatas y cinchos', 1.0, 'material_local'),
  ('PKG-STARTER', 'interconectado', 21, 'Mano de obra', null, 'mano_obra_panel', 'Instalación por panel', 4.0, 'mano_obra'),
  ('PKG-STARTER', 'interconectado', 22, 'Mano de obra', null, 'mano_obra_fija', 'Conexión, arranque y monitoreo', 1.0, 'mano_obra'),
  ('PKG-STARTER', 'interconectado', 23, 'Protecciones de CA', 'SINOMN1S107', null, 'Interruptor de CA 2P 32 A', 1.0, 'equipo'),
  ('PKG-STARTER', 'interconectado', 24, 'Protecciones de CA', 'SINOMN1S101', null, 'Caja IP65 de 4 módulos', 1.0, 'equipo'),
  ('PKG-STARTER', 'interconectado', 25, 'Material local', null, 'cable_ca_10awg_m', 'Cable de CA 10 AWG, inversor a conexión', 30.0, 'material_local'),
  ('PKG-STARTER', 'interconectado', 26, 'Mano de obra', null, 'tramite_cfe', 'Trámite ante CFE y diagrama unifilar', 1.0, 'mano_obra'),
  ('PKG-STARTER', 'respaldo', 1, 'Respaldo', 'INVLUXLS101', null, 'Inversor cargador 3 kW, 120 V (respaldo)', 1.0, 'equipo'),
  ('PKG-STARTER', 'respaldo', 2, 'Respaldo', 'INVLUXS128', null, 'Antena Wi-Fi para inversores LUX', 1.0, 'equipo'),
  ('PKG-STARTER', 'respaldo', 3, 'Respaldo', 'BATLUXS107', null, 'Batería de litio 5.12 kWh', 1.0, 'equipo'),
  ('PKG-STARTER', 'respaldo', 4, 'Material local', null, 'centro_carga_esenciales', 'Centro de carga de cargas esenciales con interruptores', 1.0, 'material_local'),
  ('PKG-STARTER', 'respaldo', 5, 'Material local', null, 'cables_bateria', 'Cables de batería con terminales', 1.0, 'material_local'),
  ('PKG-STARTER', 'respaldo', 6, 'Material local', null, 'cable_ca_8awg_m', 'Cable de CA 8 AWG (entrada y salida del respaldo)', 30.0, 'material_local'),
  ('PKG-STARTER', 'respaldo', 7, 'Material local', null, 'conduit_m', 'Tubería conduit con accesorios', 10.0, 'material_local'),
  ('PKG-STARTER', 'respaldo', 8, 'Mano de obra', null, 'mano_obra_respaldo', 'Instalación del respaldo con batería', 1.0, 'mano_obra'),
  ('PKG-STARTER', 'hibrido_b', 1, 'Paneles', 'PSOJAS1S207', null, 'Panel solar 630 W bifacial N-type', 4.0, 'equipo'),
  ('PKG-STARTER', 'hibrido_b', 2, 'Inversor', 'INVLUXS109', null, 'Inversor cargador 6 kW, 120/240 V', 1.0, 'equipo'),
  ('PKG-STARTER', 'hibrido_b', 3, 'Inversor', 'INVLUXS128', null, 'Antena Wi-Fi para inversores LUX', 1.0, 'equipo'),
  ('PKG-STARTER', 'hibrido_b', 4, 'Batería', 'BATLUXS107', null, 'Batería de litio 5.12 kWh', 1.0, 'equipo'),
  ('PKG-STARTER', 'hibrido_b', 5, 'Estructura', 'SMOALM1S520', null, 'Estructura reforzada 4 paneles, 1 fila', 1.0, 'equipo'),
  ('PKG-STARTER', 'hibrido_b', 6, 'Estructura', 'SMOPVA1S289', null, 'Taquetes expansivos para concreto', 2.0, 'equipo'),
  ('PKG-STARTER', 'hibrido_b', 7, 'Cableado de CD', 'SINPVA1S341', null, 'Cable fotovoltaico 10 AWG rojo', 0.3, 'equipo'),
  ('PKG-STARTER', 'hibrido_b', 8, 'Cableado de CD', 'SINPVA1S342', null, 'Cable fotovoltaico 10 AWG negro', 0.3, 'equipo'),
  ('PKG-STARTER', 'hibrido_b', 9, 'Cableado de CD', 'SINPVA1S298', null, 'Conectores MC4 (5 pares)', 1.0, 'equipo'),
  ('PKG-STARTER', 'hibrido_b', 10, 'Protecciones de CD', 'PYMSUT1S112', null, 'Interruptor de CD 2P 32 A', 1.0, 'equipo'),
  ('PKG-STARTER', 'hibrido_b', 11, 'Protecciones de CD', 'PYM1033685S102', null, 'Supresor de picos de CD', 1.0, 'equipo'),
  ('PKG-STARTER', 'hibrido_b', 12, 'Protecciones de CD', 'SINOMN1S102', null, 'Caja IP65 de 6 módulos', 1.0, 'equipo'),
  ('PKG-STARTER', 'hibrido_b', 13, 'Etiquetas', 'SINPVA1S309', null, 'Etiquetas "Sistema fotovoltaico"', 0.1, 'equipo'),
  ('PKG-STARTER', 'hibrido_b', 14, 'Etiquetas', 'SINPVA1S306', null, 'Etiquetas "Desconectador principal"', 0.1, 'equipo'),
  ('PKG-STARTER', 'hibrido_b', 15, 'Etiquetas', 'SINPVA1S304', null, 'Etiquetas "Peligro de descarga"', 0.1, 'equipo'),
  ('PKG-STARTER', 'hibrido_b', 16, 'Etiquetas', 'SINPVA1S308', null, 'Etiquetas "Desconectador de CA"', 0.1, 'equipo'),
  ('PKG-STARTER', 'hibrido_b', 17, 'Etiquetas', 'SINPVA1S305', null, 'Etiquetas "Fuente de energía FV"', 0.1, 'equipo'),
  ('PKG-STARTER', 'hibrido_b', 18, 'Etiquetas', 'SINPVA1S307', null, 'Etiquetas "Desconectador de CD"', 0.1, 'equipo'),
  ('PKG-STARTER', 'hibrido_b', 19, 'Material local', null, 'cable_tierra_10awg_m', 'Cable de tierra 10 AWG del arreglo al inversor', 30.0, 'material_local'),
  ('PKG-STARTER', 'hibrido_b', 20, 'Material local', null, 'conduit_m', 'Tubería conduit con accesorios (CD + CA)', 40.0, 'material_local'),
  ('PKG-STARTER', 'hibrido_b', 21, 'Material local', null, 'varilla_tierra', 'Varilla de tierra con conector', 1.0, 'material_local'),
  ('PKG-STARTER', 'hibrido_b', 22, 'Material local', null, 'material_tablero', 'Interruptor en el tablero del cliente, zapatas y cinchos', 1.0, 'material_local'),
  ('PKG-STARTER', 'hibrido_b', 23, 'Mano de obra', null, 'mano_obra_panel', 'Instalación por panel', 4.0, 'mano_obra'),
  ('PKG-STARTER', 'hibrido_b', 24, 'Mano de obra', null, 'mano_obra_fija', 'Conexión, arranque y monitoreo', 1.0, 'mano_obra'),
  ('PKG-STARTER', 'hibrido_b', 25, 'Material local', null, 'centro_carga_esenciales', 'Centro de carga de respaldo con interruptores', 1.0, 'material_local'),
  ('PKG-STARTER', 'hibrido_b', 26, 'Material local', null, 'cables_bateria', 'Cables de batería con terminales', 1.0, 'material_local'),
  ('PKG-STARTER', 'hibrido_b', 27, 'Material local', null, 'cable_ca_6awg_m', 'Cable de CA 6 AWG (2 fases + neutro + tierra)', 40.0, 'material_local'),
  ('PKG-STARTER', 'hibrido_b', 28, 'Mano de obra', null, 'mano_obra_respaldo', 'Instalación de baterías', 1.0, 'mano_obra'),
  ('PKG-ESSENTIAL', 'interconectado', 1, 'Paneles', 'PSOJAS1S207', null, 'Panel solar 630 W bifacial N-type', 6.0, 'equipo'),
  ('PKG-ESSENTIAL', 'interconectado', 2, 'Inversor', 'INVGROWS4', null, 'Inversor interconectado 3.3 kW', 1.0, 'equipo'),
  ('PKG-ESSENTIAL', 'interconectado', 3, 'Estructura', 'SMOALM1S522', null, 'Estructura reforzada 6 paneles, 1 fila', 1.0, 'equipo'),
  ('PKG-ESSENTIAL', 'interconectado', 4, 'Estructura', 'SMOPVA1S289', null, 'Taquetes expansivos para concreto', 3.0, 'equipo'),
  ('PKG-ESSENTIAL', 'interconectado', 5, 'Cableado de CD', 'SINPVA1S341', null, 'Cable fotovoltaico 10 AWG rojo', 0.3, 'equipo'),
  ('PKG-ESSENTIAL', 'interconectado', 6, 'Cableado de CD', 'SINPVA1S342', null, 'Cable fotovoltaico 10 AWG negro', 0.3, 'equipo'),
  ('PKG-ESSENTIAL', 'interconectado', 7, 'Cableado de CD', 'SINPVA1S298', null, 'Conectores MC4 (5 pares)', 1.0, 'equipo'),
  ('PKG-ESSENTIAL', 'interconectado', 8, 'Protecciones de CD', 'PYMSUT1S112', null, 'Interruptor de CD 2P 32 A', 1.0, 'equipo'),
  ('PKG-ESSENTIAL', 'interconectado', 9, 'Protecciones de CD', 'PYM1033685S102', null, 'Supresor de picos de CD', 1.0, 'equipo'),
  ('PKG-ESSENTIAL', 'interconectado', 10, 'Protecciones de CD', 'SINOMN1S102', null, 'Caja IP65 de 6 módulos', 1.0, 'equipo'),
  ('PKG-ESSENTIAL', 'interconectado', 11, 'Etiquetas', 'SINPVA1S309', null, 'Etiquetas "Sistema fotovoltaico"', 0.1, 'equipo'),
  ('PKG-ESSENTIAL', 'interconectado', 12, 'Etiquetas', 'SINPVA1S306', null, 'Etiquetas "Desconectador principal"', 0.1, 'equipo'),
  ('PKG-ESSENTIAL', 'interconectado', 13, 'Etiquetas', 'SINPVA1S304', null, 'Etiquetas "Peligro de descarga"', 0.1, 'equipo'),
  ('PKG-ESSENTIAL', 'interconectado', 14, 'Etiquetas', 'SINPVA1S308', null, 'Etiquetas "Desconectador de CA"', 0.1, 'equipo'),
  ('PKG-ESSENTIAL', 'interconectado', 15, 'Etiquetas', 'SINPVA1S305', null, 'Etiquetas "Fuente de energía FV"', 0.1, 'equipo'),
  ('PKG-ESSENTIAL', 'interconectado', 16, 'Etiquetas', 'SINPVA1S307', null, 'Etiquetas "Desconectador de CD"', 0.1, 'equipo'),
  ('PKG-ESSENTIAL', 'interconectado', 17, 'Material local', null, 'cable_tierra_10awg_m', 'Cable de tierra 10 AWG del arreglo al inversor', 30.0, 'material_local'),
  ('PKG-ESSENTIAL', 'interconectado', 18, 'Material local', null, 'conduit_m', 'Tubería conduit con accesorios (CD + CA)', 40.0, 'material_local'),
  ('PKG-ESSENTIAL', 'interconectado', 19, 'Material local', null, 'varilla_tierra', 'Varilla de tierra con conector', 1.0, 'material_local'),
  ('PKG-ESSENTIAL', 'interconectado', 20, 'Material local', null, 'material_tablero', 'Interruptor en el tablero del cliente, zapatas y cinchos', 1.0, 'material_local'),
  ('PKG-ESSENTIAL', 'interconectado', 21, 'Mano de obra', null, 'mano_obra_panel', 'Instalación por panel', 6.0, 'mano_obra'),
  ('PKG-ESSENTIAL', 'interconectado', 22, 'Mano de obra', null, 'mano_obra_fija', 'Conexión, arranque y monitoreo', 1.0, 'mano_obra'),
  ('PKG-ESSENTIAL', 'interconectado', 23, 'Protecciones de CA', 'SINOMN1S107', null, 'Interruptor de CA 2P 32 A', 1.0, 'equipo'),
  ('PKG-ESSENTIAL', 'interconectado', 24, 'Protecciones de CA', 'SINOMN1S101', null, 'Caja IP65 de 4 módulos', 1.0, 'equipo'),
  ('PKG-ESSENTIAL', 'interconectado', 25, 'Material local', null, 'cable_ca_10awg_m', 'Cable de CA 10 AWG, inversor a conexión', 30.0, 'material_local'),
  ('PKG-ESSENTIAL', 'interconectado', 26, 'Mano de obra', null, 'tramite_cfe', 'Trámite ante CFE y diagrama unifilar', 1.0, 'mano_obra'),
  ('PKG-ESSENTIAL', 'respaldo', 1, 'Respaldo', 'INVLUXLS101', null, 'Inversor cargador 3 kW, 120 V (respaldo)', 1.0, 'equipo'),
  ('PKG-ESSENTIAL', 'respaldo', 2, 'Respaldo', 'INVLUXS128', null, 'Antena Wi-Fi para inversores LUX', 1.0, 'equipo'),
  ('PKG-ESSENTIAL', 'respaldo', 3, 'Respaldo', 'BATLUXS107', null, 'Batería de litio 5.12 kWh', 1.0, 'equipo'),
  ('PKG-ESSENTIAL', 'respaldo', 4, 'Material local', null, 'centro_carga_esenciales', 'Centro de carga de cargas esenciales con interruptores', 1.0, 'material_local'),
  ('PKG-ESSENTIAL', 'respaldo', 5, 'Material local', null, 'cables_bateria', 'Cables de batería con terminales', 1.0, 'material_local'),
  ('PKG-ESSENTIAL', 'respaldo', 6, 'Material local', null, 'cable_ca_8awg_m', 'Cable de CA 8 AWG (entrada y salida del respaldo)', 30.0, 'material_local'),
  ('PKG-ESSENTIAL', 'respaldo', 7, 'Material local', null, 'conduit_m', 'Tubería conduit con accesorios', 10.0, 'material_local'),
  ('PKG-ESSENTIAL', 'respaldo', 8, 'Mano de obra', null, 'mano_obra_respaldo', 'Instalación del respaldo con batería', 1.0, 'mano_obra'),
  ('PKG-ESSENTIAL', 'hibrido_b', 1, 'Paneles', 'PSOJAS1S207', null, 'Panel solar 630 W bifacial N-type', 6.0, 'equipo'),
  ('PKG-ESSENTIAL', 'hibrido_b', 2, 'Inversor', 'INVLUXS109', null, 'Inversor cargador 6 kW, 120/240 V', 1.0, 'equipo'),
  ('PKG-ESSENTIAL', 'hibrido_b', 3, 'Inversor', 'INVLUXS128', null, 'Antena Wi-Fi para inversores LUX', 1.0, 'equipo'),
  ('PKG-ESSENTIAL', 'hibrido_b', 4, 'Batería', 'BATLUXS107', null, 'Batería de litio 5.12 kWh', 1.0, 'equipo'),
  ('PKG-ESSENTIAL', 'hibrido_b', 5, 'Estructura', 'SMOALM1S522', null, 'Estructura reforzada 6 paneles, 1 fila', 1.0, 'equipo'),
  ('PKG-ESSENTIAL', 'hibrido_b', 6, 'Estructura', 'SMOPVA1S289', null, 'Taquetes expansivos para concreto', 3.0, 'equipo'),
  ('PKG-ESSENTIAL', 'hibrido_b', 7, 'Cableado de CD', 'SINPVA1S341', null, 'Cable fotovoltaico 10 AWG rojo', 0.3, 'equipo'),
  ('PKG-ESSENTIAL', 'hibrido_b', 8, 'Cableado de CD', 'SINPVA1S342', null, 'Cable fotovoltaico 10 AWG negro', 0.3, 'equipo'),
  ('PKG-ESSENTIAL', 'hibrido_b', 9, 'Cableado de CD', 'SINPVA1S298', null, 'Conectores MC4 (5 pares)', 1.0, 'equipo'),
  ('PKG-ESSENTIAL', 'hibrido_b', 10, 'Protecciones de CD', 'PYMSUT1S112', null, 'Interruptor de CD 2P 32 A', 1.0, 'equipo'),
  ('PKG-ESSENTIAL', 'hibrido_b', 11, 'Protecciones de CD', 'PYM1033685S102', null, 'Supresor de picos de CD', 1.0, 'equipo'),
  ('PKG-ESSENTIAL', 'hibrido_b', 12, 'Protecciones de CD', 'SINOMN1S102', null, 'Caja IP65 de 6 módulos', 1.0, 'equipo'),
  ('PKG-ESSENTIAL', 'hibrido_b', 13, 'Etiquetas', 'SINPVA1S309', null, 'Etiquetas "Sistema fotovoltaico"', 0.1, 'equipo'),
  ('PKG-ESSENTIAL', 'hibrido_b', 14, 'Etiquetas', 'SINPVA1S306', null, 'Etiquetas "Desconectador principal"', 0.1, 'equipo'),
  ('PKG-ESSENTIAL', 'hibrido_b', 15, 'Etiquetas', 'SINPVA1S304', null, 'Etiquetas "Peligro de descarga"', 0.1, 'equipo'),
  ('PKG-ESSENTIAL', 'hibrido_b', 16, 'Etiquetas', 'SINPVA1S308', null, 'Etiquetas "Desconectador de CA"', 0.1, 'equipo'),
  ('PKG-ESSENTIAL', 'hibrido_b', 17, 'Etiquetas', 'SINPVA1S305', null, 'Etiquetas "Fuente de energía FV"', 0.1, 'equipo'),
  ('PKG-ESSENTIAL', 'hibrido_b', 18, 'Etiquetas', 'SINPVA1S307', null, 'Etiquetas "Desconectador de CD"', 0.1, 'equipo'),
  ('PKG-ESSENTIAL', 'hibrido_b', 19, 'Material local', null, 'cable_tierra_10awg_m', 'Cable de tierra 10 AWG del arreglo al inversor', 30.0, 'material_local'),
  ('PKG-ESSENTIAL', 'hibrido_b', 20, 'Material local', null, 'conduit_m', 'Tubería conduit con accesorios (CD + CA)', 40.0, 'material_local'),
  ('PKG-ESSENTIAL', 'hibrido_b', 21, 'Material local', null, 'varilla_tierra', 'Varilla de tierra con conector', 1.0, 'material_local'),
  ('PKG-ESSENTIAL', 'hibrido_b', 22, 'Material local', null, 'material_tablero', 'Interruptor en el tablero del cliente, zapatas y cinchos', 1.0, 'material_local'),
  ('PKG-ESSENTIAL', 'hibrido_b', 23, 'Mano de obra', null, 'mano_obra_panel', 'Instalación por panel', 6.0, 'mano_obra'),
  ('PKG-ESSENTIAL', 'hibrido_b', 24, 'Mano de obra', null, 'mano_obra_fija', 'Conexión, arranque y monitoreo', 1.0, 'mano_obra'),
  ('PKG-ESSENTIAL', 'hibrido_b', 25, 'Material local', null, 'centro_carga_esenciales', 'Centro de carga de respaldo con interruptores', 1.0, 'material_local'),
  ('PKG-ESSENTIAL', 'hibrido_b', 26, 'Material local', null, 'cables_bateria', 'Cables de batería con terminales', 1.0, 'material_local'),
  ('PKG-ESSENTIAL', 'hibrido_b', 27, 'Material local', null, 'cable_ca_6awg_m', 'Cable de CA 6 AWG (2 fases + neutro + tierra)', 40.0, 'material_local'),
  ('PKG-ESSENTIAL', 'hibrido_b', 28, 'Mano de obra', null, 'mano_obra_respaldo', 'Instalación de baterías', 1.0, 'mano_obra'),
  ('PKG-COMFORT', 'interconectado', 1, 'Paneles', 'PSOJAS1S207', null, 'Panel solar 630 W bifacial N-type', 8.0, 'equipo'),
  ('PKG-COMFORT', 'interconectado', 2, 'Inversor', 'INVGROWS11', null, 'Inversor interconectado 6 kW', 1.0, 'equipo'),
  ('PKG-COMFORT', 'interconectado', 3, 'Estructura', 'SMOALM1S520', null, 'Estructura reforzada 4 paneles, 1 fila', 2.0, 'equipo'),
  ('PKG-COMFORT', 'interconectado', 4, 'Estructura', 'SMOPVA1S289', null, 'Taquetes expansivos para concreto', 4.0, 'equipo'),
  ('PKG-COMFORT', 'interconectado', 5, 'Cableado de CD', 'SINPVA1S341', null, 'Cable fotovoltaico 10 AWG rojo', 0.6, 'equipo'),
  ('PKG-COMFORT', 'interconectado', 6, 'Cableado de CD', 'SINPVA1S342', null, 'Cable fotovoltaico 10 AWG negro', 0.6, 'equipo'),
  ('PKG-COMFORT', 'interconectado', 7, 'Cableado de CD', 'SINPVA1S298', null, 'Conectores MC4 (5 pares)', 1.0, 'equipo'),
  ('PKG-COMFORT', 'interconectado', 8, 'Protecciones de CD', 'PYMSUT1S112', null, 'Interruptor de CD 2P 32 A', 2.0, 'equipo'),
  ('PKG-COMFORT', 'interconectado', 9, 'Protecciones de CD', 'PYM1033685S102', null, 'Supresor de picos de CD', 2.0, 'equipo'),
  ('PKG-COMFORT', 'interconectado', 10, 'Protecciones de CD', 'SINOMN1S104', null, 'Caja IP65 de 12 módulos', 1.0, 'equipo'),
  ('PKG-COMFORT', 'interconectado', 11, 'Etiquetas', 'SINPVA1S309', null, 'Etiquetas "Sistema fotovoltaico"', 0.1, 'equipo'),
  ('PKG-COMFORT', 'interconectado', 12, 'Etiquetas', 'SINPVA1S306', null, 'Etiquetas "Desconectador principal"', 0.1, 'equipo'),
  ('PKG-COMFORT', 'interconectado', 13, 'Etiquetas', 'SINPVA1S304', null, 'Etiquetas "Peligro de descarga"', 0.1, 'equipo'),
  ('PKG-COMFORT', 'interconectado', 14, 'Etiquetas', 'SINPVA1S308', null, 'Etiquetas "Desconectador de CA"', 0.1, 'equipo'),
  ('PKG-COMFORT', 'interconectado', 15, 'Etiquetas', 'SINPVA1S305', null, 'Etiquetas "Fuente de energía FV"', 0.1, 'equipo'),
  ('PKG-COMFORT', 'interconectado', 16, 'Etiquetas', 'SINPVA1S307', null, 'Etiquetas "Desconectador de CD"', 0.1, 'equipo'),
  ('PKG-COMFORT', 'interconectado', 17, 'Material local', null, 'cable_tierra_10awg_m', 'Cable de tierra 10 AWG del arreglo al inversor', 30.0, 'material_local'),
  ('PKG-COMFORT', 'interconectado', 18, 'Material local', null, 'conduit_m', 'Tubería conduit con accesorios (CD + CA)', 40.0, 'material_local'),
  ('PKG-COMFORT', 'interconectado', 19, 'Material local', null, 'varilla_tierra', 'Varilla de tierra con conector', 1.0, 'material_local'),
  ('PKG-COMFORT', 'interconectado', 20, 'Material local', null, 'material_tablero', 'Interruptor en el tablero del cliente, zapatas y cinchos', 1.0, 'material_local'),
  ('PKG-COMFORT', 'interconectado', 21, 'Mano de obra', null, 'mano_obra_panel', 'Instalación por panel', 8.0, 'mano_obra'),
  ('PKG-COMFORT', 'interconectado', 22, 'Mano de obra', null, 'mano_obra_fija', 'Conexión, arranque y monitoreo', 1.0, 'mano_obra'),
  ('PKG-COMFORT', 'interconectado', 23, 'Protecciones de CA', 'SINOMN1S108', null, 'Interruptor de CA 2P 40 A', 1.0, 'equipo'),
  ('PKG-COMFORT', 'interconectado', 24, 'Protecciones de CA', 'SINOMN1S101', null, 'Caja IP65 de 4 módulos', 1.0, 'equipo'),
  ('PKG-COMFORT', 'interconectado', 25, 'Material local', null, 'cable_ca_8awg_m', 'Cable de CA 8 AWG, inversor a conexión', 30.0, 'material_local'),
  ('PKG-COMFORT', 'interconectado', 26, 'Mano de obra', null, 'tramite_cfe', 'Trámite ante CFE y diagrama unifilar', 1.0, 'mano_obra'),
  ('PKG-COMFORT', 'respaldo', 1, 'Respaldo', 'INVLUXLS101', null, 'Inversor cargador 3 kW, 120 V (respaldo)', 1.0, 'equipo'),
  ('PKG-COMFORT', 'respaldo', 2, 'Respaldo', 'INVLUXS128', null, 'Antena Wi-Fi para inversores LUX', 1.0, 'equipo'),
  ('PKG-COMFORT', 'respaldo', 3, 'Respaldo', 'BATLUXS107', null, 'Batería de litio 5.12 kWh', 1.0, 'equipo'),
  ('PKG-COMFORT', 'respaldo', 4, 'Material local', null, 'centro_carga_esenciales', 'Centro de carga de cargas esenciales con interruptores', 1.0, 'material_local'),
  ('PKG-COMFORT', 'respaldo', 5, 'Material local', null, 'cables_bateria', 'Cables de batería con terminales', 1.0, 'material_local'),
  ('PKG-COMFORT', 'respaldo', 6, 'Material local', null, 'cable_ca_8awg_m', 'Cable de CA 8 AWG (entrada y salida del respaldo)', 30.0, 'material_local'),
  ('PKG-COMFORT', 'respaldo', 7, 'Material local', null, 'conduit_m', 'Tubería conduit con accesorios', 10.0, 'material_local'),
  ('PKG-COMFORT', 'respaldo', 8, 'Mano de obra', null, 'mano_obra_respaldo', 'Instalación del respaldo con batería', 1.0, 'mano_obra'),
  ('PKG-COMFORT', 'hibrido_b', 1, 'Paneles', 'PSOJAS1S207', null, 'Panel solar 630 W bifacial N-type', 8.0, 'equipo'),
  ('PKG-COMFORT', 'hibrido_b', 2, 'Inversor', 'INVLUXS109', null, 'Inversor cargador 6 kW, 120/240 V', 1.0, 'equipo'),
  ('PKG-COMFORT', 'hibrido_b', 3, 'Inversor', 'INVLUXS128', null, 'Antena Wi-Fi para inversores LUX', 1.0, 'equipo'),
  ('PKG-COMFORT', 'hibrido_b', 4, 'Batería', 'BATLUXS107', null, 'Batería de litio 5.12 kWh', 1.0, 'equipo'),
  ('PKG-COMFORT', 'hibrido_b', 5, 'Estructura', 'SMOALM1S520', null, 'Estructura reforzada 4 paneles, 1 fila', 2.0, 'equipo'),
  ('PKG-COMFORT', 'hibrido_b', 6, 'Estructura', 'SMOPVA1S289', null, 'Taquetes expansivos para concreto', 4.0, 'equipo'),
  ('PKG-COMFORT', 'hibrido_b', 7, 'Cableado de CD', 'SINPVA1S341', null, 'Cable fotovoltaico 10 AWG rojo', 0.6, 'equipo'),
  ('PKG-COMFORT', 'hibrido_b', 8, 'Cableado de CD', 'SINPVA1S342', null, 'Cable fotovoltaico 10 AWG negro', 0.6, 'equipo'),
  ('PKG-COMFORT', 'hibrido_b', 9, 'Cableado de CD', 'SINPVA1S298', null, 'Conectores MC4 (5 pares)', 1.0, 'equipo'),
  ('PKG-COMFORT', 'hibrido_b', 10, 'Protecciones de CD', 'PYMSUT1S112', null, 'Interruptor de CD 2P 32 A', 2.0, 'equipo'),
  ('PKG-COMFORT', 'hibrido_b', 11, 'Protecciones de CD', 'PYM1033685S102', null, 'Supresor de picos de CD', 2.0, 'equipo'),
  ('PKG-COMFORT', 'hibrido_b', 12, 'Protecciones de CD', 'SINOMN1S104', null, 'Caja IP65 de 12 módulos', 1.0, 'equipo'),
  ('PKG-COMFORT', 'hibrido_b', 13, 'Etiquetas', 'SINPVA1S309', null, 'Etiquetas "Sistema fotovoltaico"', 0.1, 'equipo'),
  ('PKG-COMFORT', 'hibrido_b', 14, 'Etiquetas', 'SINPVA1S306', null, 'Etiquetas "Desconectador principal"', 0.1, 'equipo'),
  ('PKG-COMFORT', 'hibrido_b', 15, 'Etiquetas', 'SINPVA1S304', null, 'Etiquetas "Peligro de descarga"', 0.1, 'equipo'),
  ('PKG-COMFORT', 'hibrido_b', 16, 'Etiquetas', 'SINPVA1S308', null, 'Etiquetas "Desconectador de CA"', 0.1, 'equipo'),
  ('PKG-COMFORT', 'hibrido_b', 17, 'Etiquetas', 'SINPVA1S305', null, 'Etiquetas "Fuente de energía FV"', 0.1, 'equipo'),
  ('PKG-COMFORT', 'hibrido_b', 18, 'Etiquetas', 'SINPVA1S307', null, 'Etiquetas "Desconectador de CD"', 0.1, 'equipo'),
  ('PKG-COMFORT', 'hibrido_b', 19, 'Material local', null, 'cable_tierra_10awg_m', 'Cable de tierra 10 AWG del arreglo al inversor', 30.0, 'material_local'),
  ('PKG-COMFORT', 'hibrido_b', 20, 'Material local', null, 'conduit_m', 'Tubería conduit con accesorios (CD + CA)', 40.0, 'material_local'),
  ('PKG-COMFORT', 'hibrido_b', 21, 'Material local', null, 'varilla_tierra', 'Varilla de tierra con conector', 1.0, 'material_local'),
  ('PKG-COMFORT', 'hibrido_b', 22, 'Material local', null, 'material_tablero', 'Interruptor en el tablero del cliente, zapatas y cinchos', 1.0, 'material_local'),
  ('PKG-COMFORT', 'hibrido_b', 23, 'Mano de obra', null, 'mano_obra_panel', 'Instalación por panel', 8.0, 'mano_obra'),
  ('PKG-COMFORT', 'hibrido_b', 24, 'Mano de obra', null, 'mano_obra_fija', 'Conexión, arranque y monitoreo', 1.0, 'mano_obra'),
  ('PKG-COMFORT', 'hibrido_b', 25, 'Material local', null, 'centro_carga_esenciales', 'Centro de carga de respaldo con interruptores', 1.0, 'material_local'),
  ('PKG-COMFORT', 'hibrido_b', 26, 'Material local', null, 'cables_bateria', 'Cables de batería con terminales', 1.0, 'material_local'),
  ('PKG-COMFORT', 'hibrido_b', 27, 'Material local', null, 'cable_ca_6awg_m', 'Cable de CA 6 AWG (2 fases + neutro + tierra)', 40.0, 'material_local'),
  ('PKG-COMFORT', 'hibrido_b', 28, 'Mano de obra', null, 'mano_obra_respaldo', 'Instalación de baterías', 1.0, 'mano_obra'),
  ('PKG-PLUS', 'interconectado', 1, 'Paneles', 'PSOJAS1S207', null, 'Panel solar 630 W bifacial N-type', 10.0, 'equipo'),
  ('PKG-PLUS', 'interconectado', 2, 'Inversor', 'INVGROWS11', null, 'Inversor interconectado 6 kW', 1.0, 'equipo'),
  ('PKG-PLUS', 'interconectado', 3, 'Estructura', 'SMOALM1S521', null, 'Estructura reforzada 5 paneles, 1 fila', 2.0, 'equipo'),
  ('PKG-PLUS', 'interconectado', 4, 'Estructura', 'SMOPVA1S289', null, 'Taquetes expansivos para concreto', 4.0, 'equipo'),
  ('PKG-PLUS', 'interconectado', 5, 'Cableado de CD', 'SINPVA1S341', null, 'Cable fotovoltaico 10 AWG rojo', 0.6, 'equipo'),
  ('PKG-PLUS', 'interconectado', 6, 'Cableado de CD', 'SINPVA1S342', null, 'Cable fotovoltaico 10 AWG negro', 0.6, 'equipo'),
  ('PKG-PLUS', 'interconectado', 7, 'Cableado de CD', 'SINPVA1S298', null, 'Conectores MC4 (5 pares)', 1.0, 'equipo'),
  ('PKG-PLUS', 'interconectado', 8, 'Protecciones de CD', 'PYMSUT1S112', null, 'Interruptor de CD 2P 32 A', 2.0, 'equipo'),
  ('PKG-PLUS', 'interconectado', 9, 'Protecciones de CD', 'PYM1033685S102', null, 'Supresor de picos de CD', 2.0, 'equipo'),
  ('PKG-PLUS', 'interconectado', 10, 'Protecciones de CD', 'SINOMN1S104', null, 'Caja IP65 de 12 módulos', 1.0, 'equipo'),
  ('PKG-PLUS', 'interconectado', 11, 'Etiquetas', 'SINPVA1S309', null, 'Etiquetas "Sistema fotovoltaico"', 0.1, 'equipo'),
  ('PKG-PLUS', 'interconectado', 12, 'Etiquetas', 'SINPVA1S306', null, 'Etiquetas "Desconectador principal"', 0.1, 'equipo'),
  ('PKG-PLUS', 'interconectado', 13, 'Etiquetas', 'SINPVA1S304', null, 'Etiquetas "Peligro de descarga"', 0.1, 'equipo'),
  ('PKG-PLUS', 'interconectado', 14, 'Etiquetas', 'SINPVA1S308', null, 'Etiquetas "Desconectador de CA"', 0.1, 'equipo'),
  ('PKG-PLUS', 'interconectado', 15, 'Etiquetas', 'SINPVA1S305', null, 'Etiquetas "Fuente de energía FV"', 0.1, 'equipo'),
  ('PKG-PLUS', 'interconectado', 16, 'Etiquetas', 'SINPVA1S307', null, 'Etiquetas "Desconectador de CD"', 0.1, 'equipo'),
  ('PKG-PLUS', 'interconectado', 17, 'Material local', null, 'cable_tierra_10awg_m', 'Cable de tierra 10 AWG del arreglo al inversor', 30.0, 'material_local'),
  ('PKG-PLUS', 'interconectado', 18, 'Material local', null, 'conduit_m', 'Tubería conduit con accesorios (CD + CA)', 40.0, 'material_local'),
  ('PKG-PLUS', 'interconectado', 19, 'Material local', null, 'varilla_tierra', 'Varilla de tierra con conector', 1.0, 'material_local'),
  ('PKG-PLUS', 'interconectado', 20, 'Material local', null, 'material_tablero', 'Interruptor en el tablero del cliente, zapatas y cinchos', 1.0, 'material_local'),
  ('PKG-PLUS', 'interconectado', 21, 'Mano de obra', null, 'mano_obra_panel', 'Instalación por panel', 10.0, 'mano_obra'),
  ('PKG-PLUS', 'interconectado', 22, 'Mano de obra', null, 'mano_obra_fija', 'Conexión, arranque y monitoreo', 1.0, 'mano_obra'),
  ('PKG-PLUS', 'interconectado', 23, 'Protecciones de CA', 'SINOMN1S108', null, 'Interruptor de CA 2P 40 A', 1.0, 'equipo'),
  ('PKG-PLUS', 'interconectado', 24, 'Protecciones de CA', 'SINOMN1S101', null, 'Caja IP65 de 4 módulos', 1.0, 'equipo'),
  ('PKG-PLUS', 'interconectado', 25, 'Material local', null, 'cable_ca_8awg_m', 'Cable de CA 8 AWG, inversor a conexión', 30.0, 'material_local'),
  ('PKG-PLUS', 'interconectado', 26, 'Mano de obra', null, 'tramite_cfe', 'Trámite ante CFE y diagrama unifilar', 1.0, 'mano_obra'),
  ('PKG-PLUS', 'respaldo', 1, 'Respaldo', 'INVLUXLS101', null, 'Inversor cargador 3 kW, 120 V (respaldo)', 1.0, 'equipo'),
  ('PKG-PLUS', 'respaldo', 2, 'Respaldo', 'INVLUXS128', null, 'Antena Wi-Fi para inversores LUX', 1.0, 'equipo'),
  ('PKG-PLUS', 'respaldo', 3, 'Respaldo', 'BATLUXS107', null, 'Batería de litio 5.12 kWh', 2.0, 'equipo'),
  ('PKG-PLUS', 'respaldo', 4, 'Material local', null, 'centro_carga_esenciales', 'Centro de carga de cargas esenciales con interruptores', 1.0, 'material_local'),
  ('PKG-PLUS', 'respaldo', 5, 'Material local', null, 'cables_bateria', 'Cables de batería con terminales', 1.0, 'material_local'),
  ('PKG-PLUS', 'respaldo', 6, 'Material local', null, 'cable_ca_8awg_m', 'Cable de CA 8 AWG (entrada y salida del respaldo)', 30.0, 'material_local'),
  ('PKG-PLUS', 'respaldo', 7, 'Material local', null, 'conduit_m', 'Tubería conduit con accesorios', 10.0, 'material_local'),
  ('PKG-PLUS', 'respaldo', 8, 'Mano de obra', null, 'mano_obra_respaldo', 'Instalación del respaldo con batería', 1.0, 'mano_obra'),
  ('PKG-PLUS', 'hibrido_b', 1, 'Paneles', 'PSOJAS1S207', null, 'Panel solar 630 W bifacial N-type', 10.0, 'equipo'),
  ('PKG-PLUS', 'hibrido_b', 2, 'Inversor', 'INVLUXS109', null, 'Inversor cargador 6 kW, 120/240 V', 1.0, 'equipo'),
  ('PKG-PLUS', 'hibrido_b', 3, 'Inversor', 'INVLUXS128', null, 'Antena Wi-Fi para inversores LUX', 1.0, 'equipo'),
  ('PKG-PLUS', 'hibrido_b', 4, 'Batería', 'BATLUXS107', null, 'Batería de litio 5.12 kWh', 2.0, 'equipo'),
  ('PKG-PLUS', 'hibrido_b', 5, 'Estructura', 'SMOALM1S521', null, 'Estructura reforzada 5 paneles, 1 fila', 2.0, 'equipo'),
  ('PKG-PLUS', 'hibrido_b', 6, 'Estructura', 'SMOPVA1S289', null, 'Taquetes expansivos para concreto', 4.0, 'equipo'),
  ('PKG-PLUS', 'hibrido_b', 7, 'Cableado de CD', 'SINPVA1S341', null, 'Cable fotovoltaico 10 AWG rojo', 0.6, 'equipo'),
  ('PKG-PLUS', 'hibrido_b', 8, 'Cableado de CD', 'SINPVA1S342', null, 'Cable fotovoltaico 10 AWG negro', 0.6, 'equipo'),
  ('PKG-PLUS', 'hibrido_b', 9, 'Cableado de CD', 'SINPVA1S298', null, 'Conectores MC4 (5 pares)', 1.0, 'equipo'),
  ('PKG-PLUS', 'hibrido_b', 10, 'Protecciones de CD', 'PYMSUT1S112', null, 'Interruptor de CD 2P 32 A', 2.0, 'equipo'),
  ('PKG-PLUS', 'hibrido_b', 11, 'Protecciones de CD', 'PYM1033685S102', null, 'Supresor de picos de CD', 2.0, 'equipo'),
  ('PKG-PLUS', 'hibrido_b', 12, 'Protecciones de CD', 'SINOMN1S104', null, 'Caja IP65 de 12 módulos', 1.0, 'equipo'),
  ('PKG-PLUS', 'hibrido_b', 13, 'Etiquetas', 'SINPVA1S309', null, 'Etiquetas "Sistema fotovoltaico"', 0.1, 'equipo'),
  ('PKG-PLUS', 'hibrido_b', 14, 'Etiquetas', 'SINPVA1S306', null, 'Etiquetas "Desconectador principal"', 0.1, 'equipo'),
  ('PKG-PLUS', 'hibrido_b', 15, 'Etiquetas', 'SINPVA1S304', null, 'Etiquetas "Peligro de descarga"', 0.1, 'equipo'),
  ('PKG-PLUS', 'hibrido_b', 16, 'Etiquetas', 'SINPVA1S308', null, 'Etiquetas "Desconectador de CA"', 0.1, 'equipo'),
  ('PKG-PLUS', 'hibrido_b', 17, 'Etiquetas', 'SINPVA1S305', null, 'Etiquetas "Fuente de energía FV"', 0.1, 'equipo'),
  ('PKG-PLUS', 'hibrido_b', 18, 'Etiquetas', 'SINPVA1S307', null, 'Etiquetas "Desconectador de CD"', 0.1, 'equipo'),
  ('PKG-PLUS', 'hibrido_b', 19, 'Material local', null, 'cable_tierra_10awg_m', 'Cable de tierra 10 AWG del arreglo al inversor', 30.0, 'material_local'),
  ('PKG-PLUS', 'hibrido_b', 20, 'Material local', null, 'conduit_m', 'Tubería conduit con accesorios (CD + CA)', 40.0, 'material_local'),
  ('PKG-PLUS', 'hibrido_b', 21, 'Material local', null, 'varilla_tierra', 'Varilla de tierra con conector', 1.0, 'material_local'),
  ('PKG-PLUS', 'hibrido_b', 22, 'Material local', null, 'material_tablero', 'Interruptor en el tablero del cliente, zapatas y cinchos', 1.0, 'material_local'),
  ('PKG-PLUS', 'hibrido_b', 23, 'Mano de obra', null, 'mano_obra_panel', 'Instalación por panel', 10.0, 'mano_obra'),
  ('PKG-PLUS', 'hibrido_b', 24, 'Mano de obra', null, 'mano_obra_fija', 'Conexión, arranque y monitoreo', 1.0, 'mano_obra'),
  ('PKG-PLUS', 'hibrido_b', 25, 'Material local', null, 'centro_carga_esenciales', 'Centro de carga de respaldo con interruptores', 1.0, 'material_local'),
  ('PKG-PLUS', 'hibrido_b', 26, 'Material local', null, 'cables_bateria', 'Cables de batería con terminales', 1.0, 'material_local'),
  ('PKG-PLUS', 'hibrido_b', 27, 'Material local', null, 'cable_ca_6awg_m', 'Cable de CA 6 AWG (2 fases + neutro + tierra)', 40.0, 'material_local'),
  ('PKG-PLUS', 'hibrido_b', 28, 'Mano de obra', null, 'mano_obra_respaldo', 'Instalación de baterías', 1.0, 'mano_obra'),
  ('PKG-PREMIUM', 'interconectado', 1, 'Paneles', 'PSOJAS1S207', null, 'Panel solar 630 W bifacial N-type', 12.0, 'equipo'),
  ('PKG-PREMIUM', 'interconectado', 2, 'Inversor', 'INVGROWS11', null, 'Inversor interconectado 6 kW', 1.0, 'equipo'),
  ('PKG-PREMIUM', 'interconectado', 3, 'Estructura', 'SMOALM1S522', null, 'Estructura reforzada 6 paneles, 1 fila', 2.0, 'equipo'),
  ('PKG-PREMIUM', 'interconectado', 4, 'Estructura', 'SMOPVA1S289', null, 'Taquetes expansivos para concreto', 6.0, 'equipo'),
  ('PKG-PREMIUM', 'interconectado', 5, 'Cableado de CD', 'SINPVA1S341', null, 'Cable fotovoltaico 10 AWG rojo', 0.6, 'equipo'),
  ('PKG-PREMIUM', 'interconectado', 6, 'Cableado de CD', 'SINPVA1S342', null, 'Cable fotovoltaico 10 AWG negro', 0.6, 'equipo'),
  ('PKG-PREMIUM', 'interconectado', 7, 'Cableado de CD', 'SINPVA1S298', null, 'Conectores MC4 (5 pares)', 1.0, 'equipo'),
  ('PKG-PREMIUM', 'interconectado', 8, 'Protecciones de CD', 'PYMSUT1S112', null, 'Interruptor de CD 2P 32 A', 2.0, 'equipo'),
  ('PKG-PREMIUM', 'interconectado', 9, 'Protecciones de CD', 'PYM1033685S102', null, 'Supresor de picos de CD', 2.0, 'equipo'),
  ('PKG-PREMIUM', 'interconectado', 10, 'Protecciones de CD', 'SINOMN1S104', null, 'Caja IP65 de 12 módulos', 1.0, 'equipo'),
  ('PKG-PREMIUM', 'interconectado', 11, 'Etiquetas', 'SINPVA1S309', null, 'Etiquetas "Sistema fotovoltaico"', 0.1, 'equipo'),
  ('PKG-PREMIUM', 'interconectado', 12, 'Etiquetas', 'SINPVA1S306', null, 'Etiquetas "Desconectador principal"', 0.1, 'equipo'),
  ('PKG-PREMIUM', 'interconectado', 13, 'Etiquetas', 'SINPVA1S304', null, 'Etiquetas "Peligro de descarga"', 0.1, 'equipo'),
  ('PKG-PREMIUM', 'interconectado', 14, 'Etiquetas', 'SINPVA1S308', null, 'Etiquetas "Desconectador de CA"', 0.1, 'equipo'),
  ('PKG-PREMIUM', 'interconectado', 15, 'Etiquetas', 'SINPVA1S305', null, 'Etiquetas "Fuente de energía FV"', 0.1, 'equipo'),
  ('PKG-PREMIUM', 'interconectado', 16, 'Etiquetas', 'SINPVA1S307', null, 'Etiquetas "Desconectador de CD"', 0.1, 'equipo'),
  ('PKG-PREMIUM', 'interconectado', 17, 'Material local', null, 'cable_tierra_10awg_m', 'Cable de tierra 10 AWG del arreglo al inversor', 30.0, 'material_local'),
  ('PKG-PREMIUM', 'interconectado', 18, 'Material local', null, 'conduit_m', 'Tubería conduit con accesorios (CD + CA)', 40.0, 'material_local'),
  ('PKG-PREMIUM', 'interconectado', 19, 'Material local', null, 'varilla_tierra', 'Varilla de tierra con conector', 1.0, 'material_local'),
  ('PKG-PREMIUM', 'interconectado', 20, 'Material local', null, 'material_tablero', 'Interruptor en el tablero del cliente, zapatas y cinchos', 1.0, 'material_local'),
  ('PKG-PREMIUM', 'interconectado', 21, 'Mano de obra', null, 'mano_obra_panel', 'Instalación por panel', 12.0, 'mano_obra'),
  ('PKG-PREMIUM', 'interconectado', 22, 'Mano de obra', null, 'mano_obra_fija', 'Conexión, arranque y monitoreo', 1.0, 'mano_obra'),
  ('PKG-PREMIUM', 'interconectado', 23, 'Protecciones de CA', 'SINOMN1S108', null, 'Interruptor de CA 2P 40 A', 1.0, 'equipo'),
  ('PKG-PREMIUM', 'interconectado', 24, 'Protecciones de CA', 'SINOMN1S101', null, 'Caja IP65 de 4 módulos', 1.0, 'equipo'),
  ('PKG-PREMIUM', 'interconectado', 25, 'Material local', null, 'cable_ca_8awg_m', 'Cable de CA 8 AWG, inversor a conexión', 30.0, 'material_local'),
  ('PKG-PREMIUM', 'interconectado', 26, 'Mano de obra', null, 'tramite_cfe', 'Trámite ante CFE y diagrama unifilar', 1.0, 'mano_obra'),
  ('PKG-PREMIUM', 'respaldo', 1, 'Respaldo', 'INVLUXLS101', null, 'Inversor cargador 3 kW, 120 V (respaldo)', 1.0, 'equipo'),
  ('PKG-PREMIUM', 'respaldo', 2, 'Respaldo', 'INVLUXS128', null, 'Antena Wi-Fi para inversores LUX', 1.0, 'equipo'),
  ('PKG-PREMIUM', 'respaldo', 3, 'Respaldo', 'BATLUXS107', null, 'Batería de litio 5.12 kWh', 2.0, 'equipo'),
  ('PKG-PREMIUM', 'respaldo', 4, 'Material local', null, 'centro_carga_esenciales', 'Centro de carga de cargas esenciales con interruptores', 1.0, 'material_local'),
  ('PKG-PREMIUM', 'respaldo', 5, 'Material local', null, 'cables_bateria', 'Cables de batería con terminales', 1.0, 'material_local'),
  ('PKG-PREMIUM', 'respaldo', 6, 'Material local', null, 'cable_ca_8awg_m', 'Cable de CA 8 AWG (entrada y salida del respaldo)', 30.0, 'material_local'),
  ('PKG-PREMIUM', 'respaldo', 7, 'Material local', null, 'conduit_m', 'Tubería conduit con accesorios', 10.0, 'material_local'),
  ('PKG-PREMIUM', 'respaldo', 8, 'Mano de obra', null, 'mano_obra_respaldo', 'Instalación del respaldo con batería', 1.0, 'mano_obra'),
  ('PKG-PREMIUM', 'hibrido_b', 1, 'Paneles', 'PSOJAS1S207', null, 'Panel solar 630 W bifacial N-type', 12.0, 'equipo'),
  ('PKG-PREMIUM', 'hibrido_b', 2, 'Inversor', 'INVLUXS109', null, 'Inversor cargador 6 kW, 120/240 V', 1.0, 'equipo'),
  ('PKG-PREMIUM', 'hibrido_b', 3, 'Inversor', 'INVLUXS128', null, 'Antena Wi-Fi para inversores LUX', 1.0, 'equipo'),
  ('PKG-PREMIUM', 'hibrido_b', 4, 'Batería', 'BATLUXS107', null, 'Batería de litio 5.12 kWh', 2.0, 'equipo'),
  ('PKG-PREMIUM', 'hibrido_b', 5, 'Estructura', 'SMOALM1S522', null, 'Estructura reforzada 6 paneles, 1 fila', 2.0, 'equipo'),
  ('PKG-PREMIUM', 'hibrido_b', 6, 'Estructura', 'SMOPVA1S289', null, 'Taquetes expansivos para concreto', 6.0, 'equipo'),
  ('PKG-PREMIUM', 'hibrido_b', 7, 'Cableado de CD', 'SINPVA1S341', null, 'Cable fotovoltaico 10 AWG rojo', 0.6, 'equipo'),
  ('PKG-PREMIUM', 'hibrido_b', 8, 'Cableado de CD', 'SINPVA1S342', null, 'Cable fotovoltaico 10 AWG negro', 0.6, 'equipo'),
  ('PKG-PREMIUM', 'hibrido_b', 9, 'Cableado de CD', 'SINPVA1S298', null, 'Conectores MC4 (5 pares)', 1.0, 'equipo'),
  ('PKG-PREMIUM', 'hibrido_b', 10, 'Protecciones de CD', 'PYMSUT1S112', null, 'Interruptor de CD 2P 32 A', 2.0, 'equipo'),
  ('PKG-PREMIUM', 'hibrido_b', 11, 'Protecciones de CD', 'PYM1033685S102', null, 'Supresor de picos de CD', 2.0, 'equipo'),
  ('PKG-PREMIUM', 'hibrido_b', 12, 'Protecciones de CD', 'SINOMN1S104', null, 'Caja IP65 de 12 módulos', 1.0, 'equipo'),
  ('PKG-PREMIUM', 'hibrido_b', 13, 'Etiquetas', 'SINPVA1S309', null, 'Etiquetas "Sistema fotovoltaico"', 0.1, 'equipo'),
  ('PKG-PREMIUM', 'hibrido_b', 14, 'Etiquetas', 'SINPVA1S306', null, 'Etiquetas "Desconectador principal"', 0.1, 'equipo'),
  ('PKG-PREMIUM', 'hibrido_b', 15, 'Etiquetas', 'SINPVA1S304', null, 'Etiquetas "Peligro de descarga"', 0.1, 'equipo'),
  ('PKG-PREMIUM', 'hibrido_b', 16, 'Etiquetas', 'SINPVA1S308', null, 'Etiquetas "Desconectador de CA"', 0.1, 'equipo'),
  ('PKG-PREMIUM', 'hibrido_b', 17, 'Etiquetas', 'SINPVA1S305', null, 'Etiquetas "Fuente de energía FV"', 0.1, 'equipo'),
  ('PKG-PREMIUM', 'hibrido_b', 18, 'Etiquetas', 'SINPVA1S307', null, 'Etiquetas "Desconectador de CD"', 0.1, 'equipo'),
  ('PKG-PREMIUM', 'hibrido_b', 19, 'Material local', null, 'cable_tierra_10awg_m', 'Cable de tierra 10 AWG del arreglo al inversor', 30.0, 'material_local'),
  ('PKG-PREMIUM', 'hibrido_b', 20, 'Material local', null, 'conduit_m', 'Tubería conduit con accesorios (CD + CA)', 40.0, 'material_local'),
  ('PKG-PREMIUM', 'hibrido_b', 21, 'Material local', null, 'varilla_tierra', 'Varilla de tierra con conector', 1.0, 'material_local'),
  ('PKG-PREMIUM', 'hibrido_b', 22, 'Material local', null, 'material_tablero', 'Interruptor en el tablero del cliente, zapatas y cinchos', 1.0, 'material_local'),
  ('PKG-PREMIUM', 'hibrido_b', 23, 'Mano de obra', null, 'mano_obra_panel', 'Instalación por panel', 12.0, 'mano_obra'),
  ('PKG-PREMIUM', 'hibrido_b', 24, 'Mano de obra', null, 'mano_obra_fija', 'Conexión, arranque y monitoreo', 1.0, 'mano_obra'),
  ('PKG-PREMIUM', 'hibrido_b', 25, 'Material local', null, 'centro_carga_esenciales', 'Centro de carga de respaldo con interruptores', 1.0, 'material_local'),
  ('PKG-PREMIUM', 'hibrido_b', 26, 'Material local', null, 'cables_bateria', 'Cables de batería con terminales', 1.0, 'material_local'),
  ('PKG-PREMIUM', 'hibrido_b', 27, 'Material local', null, 'cable_ca_6awg_m', 'Cable de CA 6 AWG (2 fases + neutro + tierra)', 40.0, 'material_local'),
  ('PKG-PREMIUM', 'hibrido_b', 28, 'Mano de obra', null, 'mano_obra_respaldo', 'Instalación de baterías', 1.0, 'mano_obra'),
  ('PKG-ELITE', 'interconectado', 1, 'Paneles', 'PSOJAS1S207', null, 'Panel solar 630 W bifacial N-type', 14.0, 'equipo'),
  ('PKG-ELITE', 'interconectado', 2, 'Inversor', 'INVGROWS3', null, 'Inversor interconectado 10 kW', 1.0, 'equipo'),
  ('PKG-ELITE', 'interconectado', 3, 'Estructura', 'SMOALM1S523', null, 'Estructura reforzada 7 paneles, 1 fila', 2.0, 'equipo'),
  ('PKG-ELITE', 'interconectado', 4, 'Estructura', 'SMOPVA1S289', null, 'Taquetes expansivos para concreto', 6.0, 'equipo'),
  ('PKG-ELITE', 'interconectado', 5, 'Cableado de CD', 'SINPVA1S341', null, 'Cable fotovoltaico 10 AWG rojo', 0.6, 'equipo'),
  ('PKG-ELITE', 'interconectado', 6, 'Cableado de CD', 'SINPVA1S342', null, 'Cable fotovoltaico 10 AWG negro', 0.6, 'equipo'),
  ('PKG-ELITE', 'interconectado', 7, 'Cableado de CD', 'SINPVA1S298', null, 'Conectores MC4 (5 pares)', 1.0, 'equipo'),
  ('PKG-ELITE', 'interconectado', 8, 'Protecciones de CD', 'PYMSUT1S112', null, 'Interruptor de CD 2P 32 A', 2.0, 'equipo'),
  ('PKG-ELITE', 'interconectado', 9, 'Protecciones de CD', 'PYM1033685S102', null, 'Supresor de picos de CD', 2.0, 'equipo'),
  ('PKG-ELITE', 'interconectado', 10, 'Protecciones de CD', 'SINOMN1S104', null, 'Caja IP65 de 12 módulos', 1.0, 'equipo'),
  ('PKG-ELITE', 'interconectado', 11, 'Etiquetas', 'SINPVA1S309', null, 'Etiquetas "Sistema fotovoltaico"', 0.1, 'equipo'),
  ('PKG-ELITE', 'interconectado', 12, 'Etiquetas', 'SINPVA1S306', null, 'Etiquetas "Desconectador principal"', 0.1, 'equipo'),
  ('PKG-ELITE', 'interconectado', 13, 'Etiquetas', 'SINPVA1S304', null, 'Etiquetas "Peligro de descarga"', 0.1, 'equipo'),
  ('PKG-ELITE', 'interconectado', 14, 'Etiquetas', 'SINPVA1S308', null, 'Etiquetas "Desconectador de CA"', 0.1, 'equipo'),
  ('PKG-ELITE', 'interconectado', 15, 'Etiquetas', 'SINPVA1S305', null, 'Etiquetas "Fuente de energía FV"', 0.1, 'equipo'),
  ('PKG-ELITE', 'interconectado', 16, 'Etiquetas', 'SINPVA1S307', null, 'Etiquetas "Desconectador de CD"', 0.1, 'equipo'),
  ('PKG-ELITE', 'interconectado', 17, 'Material local', null, 'cable_tierra_10awg_m', 'Cable de tierra 10 AWG del arreglo al inversor', 30.0, 'material_local'),
  ('PKG-ELITE', 'interconectado', 18, 'Material local', null, 'conduit_m', 'Tubería conduit con accesorios (CD + CA)', 40.0, 'material_local'),
  ('PKG-ELITE', 'interconectado', 19, 'Material local', null, 'varilla_tierra', 'Varilla de tierra con conector', 1.0, 'material_local'),
  ('PKG-ELITE', 'interconectado', 20, 'Material local', null, 'material_tablero', 'Interruptor en el tablero del cliente, zapatas y cinchos', 1.0, 'material_local'),
  ('PKG-ELITE', 'interconectado', 21, 'Mano de obra', null, 'mano_obra_panel', 'Instalación por panel', 14.0, 'mano_obra'),
  ('PKG-ELITE', 'interconectado', 22, 'Mano de obra', null, 'mano_obra_fija', 'Conexión, arranque y monitoreo', 1.0, 'mano_obra'),
  ('PKG-ELITE', 'interconectado', 23, 'Protecciones de CA', 'SINOMN1S109', null, 'Interruptor de CA 2P 63 A', 1.0, 'equipo'),
  ('PKG-ELITE', 'interconectado', 24, 'Protecciones de CA', 'SINOMN1S101', null, 'Caja IP65 de 4 módulos', 1.0, 'equipo'),
  ('PKG-ELITE', 'interconectado', 25, 'Material local', null, 'cable_ca_6awg_m', 'Cable de CA 6 AWG, inversor a conexión', 30.0, 'material_local'),
  ('PKG-ELITE', 'interconectado', 26, 'Mano de obra', null, 'tramite_cfe', 'Trámite ante CFE y diagrama unifilar', 1.0, 'mano_obra'),
  ('PKG-ELITE', 'respaldo', 1, 'Respaldo', 'INVLUXLS101', null, 'Inversor cargador 3 kW, 120 V (respaldo)', 1.0, 'equipo'),
  ('PKG-ELITE', 'respaldo', 2, 'Respaldo', 'INVLUXS128', null, 'Antena Wi-Fi para inversores LUX', 1.0, 'equipo'),
  ('PKG-ELITE', 'respaldo', 3, 'Respaldo', 'BATLUXS107', null, 'Batería de litio 5.12 kWh', 2.0, 'equipo'),
  ('PKG-ELITE', 'respaldo', 4, 'Material local', null, 'centro_carga_esenciales', 'Centro de carga de cargas esenciales con interruptores', 1.0, 'material_local'),
  ('PKG-ELITE', 'respaldo', 5, 'Material local', null, 'cables_bateria', 'Cables de batería con terminales', 1.0, 'material_local'),
  ('PKG-ELITE', 'respaldo', 6, 'Material local', null, 'cable_ca_8awg_m', 'Cable de CA 8 AWG (entrada y salida del respaldo)', 30.0, 'material_local'),
  ('PKG-ELITE', 'respaldo', 7, 'Material local', null, 'conduit_m', 'Tubería conduit con accesorios', 10.0, 'material_local'),
  ('PKG-ELITE', 'respaldo', 8, 'Mano de obra', null, 'mano_obra_respaldo', 'Instalación del respaldo con batería', 1.0, 'mano_obra'),
  ('PKG-ELITE', 'hibrido_b', 1, 'Paneles', 'PSOJAS1S207', null, 'Panel solar 630 W bifacial N-type', 14.0, 'equipo'),
  ('PKG-ELITE', 'hibrido_b', 2, 'Inversor', 'INVLUXS109', null, 'Inversor cargador 6 kW, 120/240 V', 2.0, 'equipo'),
  ('PKG-ELITE', 'hibrido_b', 3, 'Inversor', 'INVLUXS128', null, 'Antena Wi-Fi para inversores LUX', 2.0, 'equipo'),
  ('PKG-ELITE', 'hibrido_b', 4, 'Batería', 'BATLUXS107', null, 'Batería de litio 5.12 kWh', 2.0, 'equipo'),
  ('PKG-ELITE', 'hibrido_b', 5, 'Estructura', 'SMOALM1S523', null, 'Estructura reforzada 7 paneles, 1 fila', 2.0, 'equipo'),
  ('PKG-ELITE', 'hibrido_b', 6, 'Estructura', 'SMOPVA1S289', null, 'Taquetes expansivos para concreto', 6.0, 'equipo'),
  ('PKG-ELITE', 'hibrido_b', 7, 'Cableado de CD', 'SINPVA1S341', null, 'Cable fotovoltaico 10 AWG rojo', 0.9, 'equipo'),
  ('PKG-ELITE', 'hibrido_b', 8, 'Cableado de CD', 'SINPVA1S342', null, 'Cable fotovoltaico 10 AWG negro', 0.9, 'equipo'),
  ('PKG-ELITE', 'hibrido_b', 9, 'Cableado de CD', 'SINPVA1S298', null, 'Conectores MC4 (5 pares)', 2.0, 'equipo'),
  ('PKG-ELITE', 'hibrido_b', 10, 'Protecciones de CD', 'PYMSUT1S112', null, 'Interruptor de CD 2P 32 A', 3.0, 'equipo'),
  ('PKG-ELITE', 'hibrido_b', 11, 'Protecciones de CD', 'PYM1033685S102', null, 'Supresor de picos de CD', 3.0, 'equipo'),
  ('PKG-ELITE', 'hibrido_b', 12, 'Protecciones de CD', 'SINOMN1S104', null, 'Caja IP65 de 12 módulos', 1.0, 'equipo'),
  ('PKG-ELITE', 'hibrido_b', 13, 'Protecciones de CD', 'SINOMN1S102', null, 'Caja IP65 de 6 módulos', 1.0, 'equipo'),
  ('PKG-ELITE', 'hibrido_b', 14, 'Etiquetas', 'SINPVA1S309', null, 'Etiquetas "Sistema fotovoltaico"', 0.1, 'equipo'),
  ('PKG-ELITE', 'hibrido_b', 15, 'Etiquetas', 'SINPVA1S306', null, 'Etiquetas "Desconectador principal"', 0.1, 'equipo'),
  ('PKG-ELITE', 'hibrido_b', 16, 'Etiquetas', 'SINPVA1S304', null, 'Etiquetas "Peligro de descarga"', 0.1, 'equipo'),
  ('PKG-ELITE', 'hibrido_b', 17, 'Etiquetas', 'SINPVA1S308', null, 'Etiquetas "Desconectador de CA"', 0.1, 'equipo'),
  ('PKG-ELITE', 'hibrido_b', 18, 'Etiquetas', 'SINPVA1S305', null, 'Etiquetas "Fuente de energía FV"', 0.1, 'equipo'),
  ('PKG-ELITE', 'hibrido_b', 19, 'Etiquetas', 'SINPVA1S307', null, 'Etiquetas "Desconectador de CD"', 0.1, 'equipo'),
  ('PKG-ELITE', 'hibrido_b', 20, 'Material local', null, 'cable_tierra_10awg_m', 'Cable de tierra 10 AWG del arreglo al inversor', 30.0, 'material_local'),
  ('PKG-ELITE', 'hibrido_b', 21, 'Material local', null, 'conduit_m', 'Tubería conduit con accesorios (CD + CA)', 40.0, 'material_local'),
  ('PKG-ELITE', 'hibrido_b', 22, 'Material local', null, 'varilla_tierra', 'Varilla de tierra con conector', 1.0, 'material_local'),
  ('PKG-ELITE', 'hibrido_b', 23, 'Material local', null, 'material_tablero', 'Interruptor en el tablero del cliente, zapatas y cinchos', 1.0, 'material_local'),
  ('PKG-ELITE', 'hibrido_b', 24, 'Mano de obra', null, 'mano_obra_panel', 'Instalación por panel', 14.0, 'mano_obra'),
  ('PKG-ELITE', 'hibrido_b', 25, 'Mano de obra', null, 'mano_obra_fija', 'Conexión, arranque y monitoreo', 1.0, 'mano_obra'),
  ('PKG-ELITE', 'hibrido_b', 26, 'Material local', null, 'centro_carga_esenciales', 'Centro de carga de respaldo con interruptores', 1.0, 'material_local'),
  ('PKG-ELITE', 'hibrido_b', 27, 'Material local', null, 'cables_bateria', 'Cables de batería con terminales', 1.0, 'material_local'),
  ('PKG-ELITE', 'hibrido_b', 28, 'Material local', null, 'cable_ca_6awg_m', 'Cable de CA 6 AWG (2 fases + neutro + tierra)', 40.0, 'material_local'),
  ('PKG-ELITE', 'hibrido_b', 29, 'Mano de obra', null, 'mano_obra_respaldo', 'Instalación de baterías', 1.0, 'mano_obra')
  ) as v(paquete, variante, orden, grupo, sku, parametro, concepto, cantidad, tipo)
  join productos pk on pk.sku = v.paquete and pk.categoria = 'paquete_solar'
  left join productos pr on pr.sku = v.sku
 where (v.sku is null or pr.id is not null)
   and not exists (select 1 from paquete_solar_lineas l where l.paquete_id = pk.id);

-- Lo que el sitio dirá del paquete (inversor, arreglo, "incluye"…). Se usa al publicar el interconectado.
update productos p
   set atributos = coalesce(p.atributos, '{}'::jsonb) || jsonb_build_object('receta', v.receta)
  from (values
  ('PKG-STARTER', '{"inversor": "Growatt MIC 3300TL-X2 (3.3 kW)", "arreglo": "1 cadena de 4", "estructura": "1 × 4 paneles, 1 fila", "respaldo": "LUX SNA 3 kW a 120 V + 1 batería PGEM", "inversor_hibrido_b": "LUX SNA-US-6K", "arreglo_hibrido_b": "1 cadena de 4", "incluye": ["Paneles JA Solar 630 W bifaciales", "Inversor Growatt con monitoreo Wi-Fi", "Estructura de aluminio para vientos de 215 km/h", "Hasta 30 m de cable del techo al inversor y 10 m a tu conexión", "Protecciones de CD y CA", "Instalación con personal certificado", "Trámite ante CFE"], "incluye_hibrido_a": "Respaldo LUX de 3 kW con 5.12 kWh de batería de litio para tus aparatos esenciales cuando se va la luz"}'::jsonb),
  ('PKG-ESSENTIAL', '{"inversor": "Growatt MIC 3300TL-X2 (3.3 kW)", "arreglo": "1 cadena de 6", "estructura": "1 × 6 paneles, 1 fila", "respaldo": "LUX SNA 3 kW a 120 V + 1 batería PGEM", "inversor_hibrido_b": "LUX SNA-US-6K", "arreglo_hibrido_b": "1 cadena de 6", "incluye": ["Paneles JA Solar 630 W bifaciales", "Inversor Growatt con monitoreo Wi-Fi", "Estructura de aluminio para vientos de 215 km/h", "Hasta 30 m de cable del techo al inversor y 10 m a tu conexión", "Protecciones de CD y CA", "Instalación con personal certificado", "Trámite ante CFE"], "incluye_hibrido_a": "Respaldo LUX de 3 kW con 5.12 kWh de batería de litio para tus aparatos esenciales cuando se va la luz"}'::jsonb),
  ('PKG-COMFORT', '{"inversor": "Growatt MIN 6000TL-X2 (6 kW)", "arreglo": "2 cadenas de 4", "estructura": "2 × 4 paneles, 1 fila", "respaldo": "LUX SNA 3 kW a 120 V + 1 batería PGEM", "inversor_hibrido_b": "LUX SNA-US-6K", "arreglo_hibrido_b": "2 cadenas de 4", "incluye": ["Paneles JA Solar 630 W bifaciales", "Inversor Growatt con monitoreo Wi-Fi", "Estructura de aluminio para vientos de 215 km/h", "Hasta 30 m de cable del techo al inversor y 10 m a tu conexión", "Protecciones de CD y CA", "Instalación con personal certificado", "Trámite ante CFE"], "incluye_hibrido_a": "Respaldo LUX de 3 kW con 5.12 kWh de batería de litio para tus aparatos esenciales cuando se va la luz"}'::jsonb),
  ('PKG-PLUS', '{"inversor": "Growatt MIN 6000TL-X2 (6 kW)", "arreglo": "2 cadenas de 5", "estructura": "2 × 5 paneles, 1 fila", "respaldo": "LUX SNA 3 kW a 120 V + 2 baterías PGEM", "inversor_hibrido_b": "LUX SNA-US-6K", "arreglo_hibrido_b": "2 cadenas de 5", "incluye": ["Paneles JA Solar 630 W bifaciales", "Inversor Growatt con monitoreo Wi-Fi", "Estructura de aluminio para vientos de 215 km/h", "Hasta 30 m de cable del techo al inversor y 10 m a tu conexión", "Protecciones de CD y CA", "Instalación con personal certificado", "Trámite ante CFE"], "incluye_hibrido_a": "Respaldo LUX de 3 kW con 10.24 kWh de batería de litio para tus aparatos esenciales cuando se va la luz"}'::jsonb),
  ('PKG-PREMIUM', '{"inversor": "Growatt MIN 6000TL-X2 (6 kW)", "arreglo": "2 cadenas de 6", "estructura": "2 × 6 paneles, 1 fila", "respaldo": "LUX SNA 3 kW a 120 V + 2 baterías PGEM", "inversor_hibrido_b": "LUX SNA-US-6K", "arreglo_hibrido_b": "2 cadenas de 6", "incluye": ["Paneles JA Solar 630 W bifaciales", "Inversor Growatt con monitoreo Wi-Fi", "Estructura de aluminio para vientos de 215 km/h", "Hasta 30 m de cable del techo al inversor y 10 m a tu conexión", "Protecciones de CD y CA", "Instalación con personal certificado", "Trámite ante CFE"], "incluye_hibrido_a": "Respaldo LUX de 3 kW con 10.24 kWh de batería de litio para tus aparatos esenciales cuando se va la luz"}'::jsonb),
  ('PKG-ELITE', '{"inversor": "Growatt MIN 10000TL-X2 (10 kW)", "arreglo": "2 cadenas de 7", "estructura": "2 × 7 paneles, 1 fila", "respaldo": "LUX SNA 3 kW a 120 V + 2 baterías PGEM", "inversor_hibrido_b": "2 × LUX SNA-US-6K", "arreglo_hibrido_b": "2 cadenas de 4 | 1 cadena de 6", "incluye": ["Paneles JA Solar 630 W bifaciales", "Inversor Growatt con monitoreo Wi-Fi", "Estructura de aluminio para vientos de 215 km/h", "Hasta 30 m de cable del techo al inversor y 10 m a tu conexión", "Protecciones de CD y CA", "Instalación con personal certificado", "Trámite ante CFE"], "incluye_hibrido_a": "Respaldo LUX de 3 kW con 10.24 kWh de batería de litio para tus aparatos esenciales cuando se va la luz"}'::jsonb)
  ) as v(sku, receta)
 where p.sku = v.sku and p.categoria = 'paquete_solar' and p.atributos -> 'receta' is null;

-- ---------------------------------------------------------------------------
-- _costear_variante: cuánto cuesta un conjunto de variantes de la receta (interna).
-- ---------------------------------------------------------------------------
create or replace function _costear_variante(p_paquete uuid, p_variantes text[]) returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with lineas as (
    select l.*, p.sku, p.nombre as producto, p.activo,
           case when l.producto_id is not null then p.costo
                when l.parametro is not null then pc.valor
                else l.costo_fijo end as unitario,
           (l.producto_id is not null and (not coalesce(p.activo, false) or coalesce(p.costo, 0) <= 0))
             or (l.parametro is not null and pc.valor is null) as falta,
           (select pp.stock_local from proveedor_productos pp
             where pp.proveedor = p.proveedor and pp.sku_proveedor = p.proveedor_sku and pp.vigente limit 1) as stock_local
      from paquete_solar_lineas l
      left join productos p on p.id = l.producto_id
      left join parametros_costeo pc on pc.clave = l.parametro
     where l.paquete_id = p_paquete and l.variante = any(p_variantes)
  )
  select jsonb_build_object(
    'lineas', count(*),
    'equipo', coalesce(round(sum(cantidad * unitario) filter (where tipo_costo = 'equipo'), 2), 0),
    'material_local', coalesce(round(sum(cantidad * unitario) filter (where tipo_costo = 'material_local'), 2), 0),
    'mano_obra', coalesce(round(sum(cantidad * unitario) filter (where tipo_costo = 'mano_obra'), 2), 0),
    'base', coalesce(round(sum(cantidad * coalesce(unitario, 0)), 2), 0),
    'faltan', coalesce(jsonb_agg(jsonb_build_object('concepto', concepto, 'sku', sku,
                                 'motivo', case when parametro is not null then 'sin parámetro'
                                                when not coalesce(activo, false) then 'producto desactivado'
                                                else 'sin costo en el catálogo' end))
                       filter (where falta), '[]'::jsonb),
    -- Cuántos paquetes completos alcanzan con lo que el proveedor tiene en Mérida.
    'alcanza', min(floor(stock_local / cantidad)) filter (where producto_id is not null and tipo_costo = 'equipo'
                                                         and stock_local is not null))
    from lineas;
$$;
revoke execute on function _costear_variante(uuid, text[]) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- costear_paquete: costo, precio calculado, precio publicado y qué pasaría con cada variante.
-- ---------------------------------------------------------------------------
create or replace function costear_paquete(p_paquete uuid) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_p productos%rowtype;
  v_regla reglas_margen;
  v_imp numeric;
  v_red numeric;
  v_resta numeric;
  v_paneles numeric;
  v_kwp numeric;
  v_out jsonb := '{}'::jsonb;
  v_c jsonb;
  v_costo numeric;
  v_sin_iva numeric;
  v_precio numeric;
  v_pub numeric;
  v_cambio numeric;
  v_estado text;
  v_primera boolean;
  r record;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador ve el costo de los paquetes.' using errcode = '42501';
  end if;
  v_p := (select p from productos p where p.id = p_paquete);
  if v_p.id is null or v_p.categoria <> 'paquete_solar' then
    raise exception 'Ese producto no es un paquete solar.' using errcode = '22023';
  end if;
  v_regla := _regla_margen('paquete_solar', null);
  v_imp := coalesce((select valor from parametros_costeo where clave = 'imprevistos_pct'), 0);
  v_red := greatest(coalesce((select valor from parametros_costeo where clave = 'paquete_redondeo'), 1), 1);
  v_resta := coalesce((select valor from parametros_costeo where clave = 'paquete_terminacion'), 0);
  v_paneles := coalesce((select sum(cantidad) from paquete_solar_lineas
                          where paquete_id = p_paquete and variante = 'interconectado' and grupo = 'Paneles'), 0);
  v_kwp := round(v_paneles * coalesce((select valor from parametros_costeo where clave = 'potencia_panel_w'), 0) / 1000, 2);

  for r in
    select * from (values ('interconectado', 'estandar', array['interconectado'], 'interconectado'),
                          ('hibrido_a', 'hibrido', array['interconectado', 'respaldo'], 'respaldo'),
                          ('hibrido_b', 'hibrido_b', array['hibrido_b'], 'hibrido_b')) as t(variante, clave, vars, requiere)
  loop
    -- Una variante existe si su receta tiene líneas propias (el híbrido A, si hay respaldo).
    continue when not exists (select 1 from paquete_solar_lineas where paquete_id = p_paquete and variante = r.requiere);
    v_c := _costear_variante(p_paquete, r.vars);
    v_costo := round((v_c ->> 'base')::numeric * (1 + v_imp / 100), 2);
    v_sin_iva := case when v_regla.id is null then null else _precio_venta(v_costo, v_regla) end;
    v_precio := case when v_sin_iva is null or jsonb_array_length(v_c -> 'faltan') > 0 then null
                     else ceil(v_sin_iva * 1.16 / v_red) * v_red - v_resta end;
    v_pub := nullif(v_p.precios ->> r.clave, '')::numeric;
    v_cambio := case when v_pub > 0 and v_precio is not null then round((v_precio - v_pub) / v_pub * 100, 1) end;
    -- La PRIMERA vez que una variante se publica desde la receta es siempre a mano: cambia también lo que
    -- el sitio dice del paquete (kWp, "incluye"), y no debe pasar en un paquete sí y en otro no.
    v_primera := not coalesce(v_p.atributos -> 'receta_publicada' ? r.clave, false);
    v_estado := case when jsonb_array_length(v_c -> 'faltan') > 0 then 'falta_costo'
                     when v_regla.id is null then 'sin_regla'
                     when v_pub is null or v_pub <= 0 or v_primera then 'por_aprobar'
                     when v_precio = v_pub then 'al_dia'
                     when abs(v_cambio) <= 15 then 'automatico'
                     else 'por_aprobar' end;
    v_out := v_out || jsonb_build_object(r.variante, v_c || jsonb_build_object(
               'clave', r.clave, 'imprevistos', round(v_costo - (v_c ->> 'base')::numeric, 2), 'costo', v_costo,
               'precio_sin_iva', v_sin_iva, 'precio', v_precio, 'publicado', v_pub, 'cambio_pct', v_cambio,
               'primera', v_primera, 'estado', v_estado));
  end loop;

  return jsonb_build_object(
    'paquete_id', v_p.id, 'sku', v_p.sku, 'nombre', v_p.nombre, 'publicar', v_p.publicar, 'activo', v_p.activo,
    'paneles', v_paneles, 'kwp', v_kwp,
    'ahorro_mensual', case when v_kwp > 0 then format('$%s–$%s',
        to_char(round(v_kwp * coalesce((select valor from parametros_costeo where clave = 'ahorro_kwp_min'), 0), -2), 'FM999,999'),
        to_char(round(v_kwp * coalesce((select valor from parametros_costeo where clave = 'ahorro_kwp_max'), 0), -2), 'FM999,999')) end,
    'regla', case when v_regla.id is null then null
                  else jsonb_build_object('categoria', v_regla.categoria, 'margen_pct', v_regla.margen_pct, 'sobre', v_regla.sobre) end,
    'imprevistos_pct', v_imp,
    'receta', v_p.atributos -> 'receta',
    'variantes', v_out,
    'calculado_en', now());
end;
$$;
revoke execute on function costear_paquete(uuid) from public, anon;
grant execute on function costear_paquete(uuid) to authenticated;

-- Todos los paquetes, calculados en vivo (para la pantalla).
create or replace function paquetes_solares() returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not es_admin() then
    raise exception 'Solo el administrador ve los paquetes.' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(case when exists (select 1 from paquete_solar_lineas l where l.paquete_id = p.id)
                          then costear_paquete(p.id)
                          else jsonb_build_object('paquete_id', p.id, 'sku', p.sku, 'nombre', p.nombre,
                                                  'publicar', p.publicar, 'activo', p.activo, 'sin_receta', true,
                                                  'variantes', '{}'::jsonb) end
                     order by coalesce((p.atributos ->> 'paneles')::numeric, 0), p.sku)
      from productos p where p.categoria = 'paquete_solar' and p.activo), '[]'::jsonb);
end;
$$;
revoke execute on function paquetes_solares() from public, anon;
grant execute on function paquetes_solares() to authenticated;

-- Aplica el precio de UNA variante al producto (interna). El del interconectado también actualiza lo
-- que el sitio dice del paquete: kWp, paneles, ahorro estimado y la lista "incluye" de la receta.
create or replace function _publicar_variante_paquete(p_paquete uuid, p_calc jsonb, p_variante text, p_origen text)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_v jsonb := p_calc -> 'variantes' -> p_variante;
  v_clave text;
  v_precio numeric;
  v_antes jsonb;
  v_incluye text;
  v_pubs jsonb;
begin
  v_clave := v_v ->> 'clave';
  v_precio := nullif(v_v ->> 'precio', '')::numeric;
  if v_v is null or v_clave is null then raise exception 'Ese paquete no tiene la variante %.', p_variante using errcode = '22023'; end if;
  if v_precio is null then
    raise exception 'No se puede publicar: %.', case v_v ->> 'estado' when 'sin_regla' then 'falta la regla de margen'
                                                                     else 'a la receta le faltan costos' end
      using errcode = '22023';
  end if;
  v_antes := (select jsonb_build_object('precios', precios, 'precio', precio, 'costo', costo) from productos where id = p_paquete);
  v_incluye := (select string_agg(x, ' | ') from jsonb_array_elements_text(p_calc -> 'receta' -> 'incluye') as x);
  -- Qué variantes ya se publicaron alguna vez desde la receta (la primera es siempre a mano).
  v_pubs := (select coalesce(jsonb_agg(distinct s.x order by s.x), '[]'::jsonb)
               from (select jsonb_array_elements_text(coalesce(p.atributos -> 'receta_publicada', '[]'::jsonb)) as x
                       from productos p where p.id = p_paquete
                     union select v_clave) s);

  update productos
     set precios = coalesce(precios, '{}'::jsonb) || jsonb_build_object(v_clave, v_precio),
         precio = case when v_clave = 'estandar' then v_precio else precio end,
         costo = case when v_clave = 'estandar' then (v_v ->> 'costo')::numeric else costo end,
         atributos = case when v_clave = 'estandar'
                          then coalesce(atributos, '{}'::jsonb) || jsonb_build_object(
                                 'kw', (p_calc ->> 'kwp')::numeric, 'paneles', (p_calc ->> 'paneles')::numeric,
                                 'ahorro_mensual', p_calc ->> 'ahorro_mensual')
                          else coalesce(atributos, '{}'::jsonb) end
                     || jsonb_build_object('receta_publicada', v_pubs),
         descripcion = case when v_clave = 'estandar' and v_incluye is not null then v_incluye else descripcion end
   where id = p_paquete;
  perform _apunta('productos', p_paquete, 'publicar_precio_paquete', v_antes,
                  jsonb_build_object('variante', p_variante, 'precio', v_precio, 'costo', v_v -> 'costo', 'origen', p_origen),
                  'oficina');
  return v_precio;
end;
$$;
revoke execute on function _publicar_variante_paquete(uuid, jsonb, text, text) from public, anon, authenticated;

-- El admin publica el precio calculado de una variante (lo que esperaba aprobación).
create or replace function publicar_precio_paquete(p_paquete uuid, p_variante text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_precio numeric;
begin
  if not es_admin() then
    raise exception 'Solo el administrador publica precios.' using errcode = '42501';
  end if;
  -- Siempre con el cálculo de este momento, nunca con uno guardado.
  v_precio := _publicar_variante_paquete(p_paquete, costear_paquete(p_paquete), p_variante, 'admin');
  update productos set paquete_calculo = costear_paquete(p_paquete) where id = p_paquete;
  return jsonb_build_object('ok', true, 'precio', v_precio);
end;
$$;
revoke execute on function publicar_precio_paquete(uuid, text) from public, anon;
grant execute on function publicar_precio_paquete(uuid, text) to authenticated;

-- Recalcula todos los paquetes: aplica solo lo que se mueve ±15 % o menos; lo demás espera.
create or replace function recalcular_paquetes() returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v jsonb;
  k text;
  v_paq int := 0;
  v_apl int := 0;
  v_pend int := 0;
  v_falta int := 0;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector recalculan paquetes.' using errcode = '42501';
  end if;
  for r in select p.id from productos p
            where p.categoria = 'paquete_solar' and p.activo
              and exists (select 1 from paquete_solar_lineas l where l.paquete_id = p.id)
  loop
    v_paq := v_paq + 1;
    v := costear_paquete(r.id);
    for k in select jsonb_object_keys(v -> 'variantes') loop
      if v -> 'variantes' -> k ->> 'estado' = 'automatico' then
        perform _publicar_variante_paquete(r.id, v, k, 'recalculo');
        v_apl := v_apl + 1;
      elsif v -> 'variantes' -> k ->> 'estado' = 'por_aprobar' then
        v_pend := v_pend + 1;
      elsif v -> 'variantes' -> k ->> 'estado' in ('falta_costo', 'sin_regla') then
        v_falta := v_falta + 1;
      end if;
    end loop;
    update productos set paquete_calculo = costear_paquete(r.id) where id = r.id;
  end loop;
  return jsonb_build_object('ok', true, 'paquetes', v_paq, 'aplicados', v_apl, 'por_aprobar', v_pend, 'faltan', v_falta);
end;
$$;
revoke execute on function recalcular_paquetes() from public, anon;
grant execute on function recalcular_paquetes() to authenticated;

insert into _migraciones (archivo, tipo) values ('78_paquetes_solares.sql', 'esquema') on conflict (archivo) do nothing;
