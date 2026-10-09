# Índice de `supabase/sql/`

Estado al **09/10/2026**. Lo que manda es la tabla `_migraciones` de la base (SQL 68), no este
archivo: `select numero, archivo, aplicada_en from _migraciones order by numero;`. Este índice
dice **qué es** cada archivo y **cómo se usa**; actualízalo cuando agregues un script.

## Reglas

- **Numeración:** `NN_nombre.sql`. No se renumera ni se mueve nada que ya se corrió: la
  documentación lo cita por número.
- **Cada script de esquema o de datos termina con su registro:**
  `insert into _migraciones (archivo, tipo) values ('NN_nombre.sql', 'esquema') on conflict (archivo) do nothing;`
- **Pruebas** (`NN_prueba_*.sql`): `begin … rollback`, SQL plano (sin bloques plpgsql: el
  editor de Supabase los rompe). No se registran. Consumen folios: las secuencias no se revierten.
- **Consultas** (solo leen) y **datos de una sola vez**: no se repiten a ciegas; los de datos
  dicen en su encabezado si son destructivos.
- **Orden de despliegue:** primero el SQL, después el código que lo llama.

Tipos: **E** esquema · **D** datos de una sola vez · **C** consulta de solo lectura · **F** foto.
Estado: ✔ aplicado y registrado (todos al 09/10/2026).

## Foto y herramientas

| Archivo | Tipo | Qué es |
|---|---|---|
| `00_volcar_esquema.sql` | C | Genera la foto del esquema `public` (un `select`; se corre en el editor y se baja con Export → Download CSV). |
| `00_esquema_base.sql` | F | La foto. **No se edita a mano**: se vuelve a correr el 00 y se reemplaza. Última: 09/10/2026 (59 tablas, 6 vistas, 158 funciones, 91 políticas). |
| `31_comparar_modo_vistas.sql` | C | Compara tres lecturas de `reloptions` (¿miente el volcado o cambió la base?). |
| `32_comprobar_roles.sql` | C | ¿Los roles quedaron como estaban tras una prueba? |
| `38_comparar_catalogo.sql` | C | `productos` del CRM contra el Excel del sitio. |
| `48_ver_baterias_y_paneles_fuera_del_excel.sql` | C | Paso 1 de 2 del 48. |
| `49_ver_historia_de_productos_desactivados.sql` | C | Paso 1 de 2 del 49. |

## Scripts

| N.º | Archivo | Tipo | Estado | Prueba | Qué hace |
|---|---|---|---|---|---|
| 01 | `productos` | E | ✔ | — | Productos e inventario (histórico). |
| 02 | `catalogo` | D | ✔ | — | Carga inicial del catálogo desde el Excel. |
| 03 | `roles` | E | ✔ | — | Roles y perfiles. |
| 04 | `vistas_seguras` | E | ✔ | — | Cierra las vistas a `anon`. |
| 05 | `vistas_por_rol` | E | ✔ | — | Vistas por rol. |
| 06 | `storage_ordenes` | E | ✔ | — | Bucket `ordenes` y sus políticas. |
| 07 | `cotizacion_estado` | E | ✔ | — | Cambio de estado de cotización en una operación. |
| 08 | `requisiciones` | E | ✔ | — | Requisiciones de pedido. |
| 09 | `flujo_servicio_base` | E | ✔ | — | Fase 1a: base del flujo de servicio. |
| 10 | `cotizacion_abre_cita` | E | ✔ | — | Fase 1b: aceptar abre cita y orden. |
| 11 | `agenda_citas` | E | ✔ | — | Fase 1c: Agenda. |
| 12 | `cerrar_orden` | E | ✔ | — | Fase 1d: cerrar una orden. |
| 13 | `retirar_orden_libre` | E | ✔ | sí | Fase 1e: el técnico ya no crea órdenes. |
| 14 | `almacen_entregas` | E | ✔ | `14_prueba_almacen` | Fase 2a: surtido y entrega al técnico. |
| 15 | `contactos` | E | ✔ | sí | Contactos por cliente y equipo. |
| 16 | `avisos_de_cita` | E | ✔ | `16_prueba_avisos` | Avisos al confirmar una cita. |
| 17 | `citas_canceladas_sin_fecha` | E | ✔ | sí | Corrección: cancelar una cita sin fecha. |
| 18 | `uso_y_devoluciones` | E | ✔ | sí | Fase 3a: uso de material y devoluciones. |
| 19 | `solicitudes_material` | E | ✔ | sí | Solicitudes de material del técnico. |
| 20 | `pdf_orden` | E | ✔ | sí | Fase 4: PDF de la orden y su envío. |
| 21 | `tarifas_catalogo` | E | ✔ | sí | Tarifas de servicio con SKU propio. |
| 22 | `whatsapp_bandeja` | E | ✔ | sí | Bandeja de conversaciones. |
| 23 | `equipo_en_campo` | E | ✔ | sí | El equipo se captura en campo. |
| 24 | `revision_orden` | E | ✔ | sí | Formato de mantenimiento en el celular. |
| 25 | `placas_equipo` | E | ✔ | sí | Placas por componente. |
| 26 | `componente_equipo` | E | ✔ | sí | Componentes desde la oficina. |
| 27 | `agente_whatsapp` | E | ✔ | sí | Herramientas del agente de WhatsApp. |
| 28 | `paquetes_preventivo` | E | ✔ | sí | Paquetes de mantenimiento preventivo. |
| 29 | `fase5_paquetes` | E | ✔ | sí | El paquete se aprende y precarga el surtido. |
| 30 | `modo_vistas` | E | ✔ | sí | Vistas `catalogo`, `existencias`, `resguardo_por_cliente` en definer. **Se ha volteado dos veces**: revisar con la foto. |
| 33 | — | — | — | `33_prueba_rol_cliente` | Prueba suelta: lo que ve una cuenta `cliente`. |
| 34 | `cliente_necesita_cliente_id` | E | ✔ | — | Un perfil `cliente` debe tener `cliente_id` (y solo él). Aplicado el 09/10/2026. |
| 35 | `cerrar_escritura` | E | ✔ | sí | Cierra escritura de `catalogos`/`auditoria` y privilegios de `anon`. |
| 36 | `solicitudes_web` | E | ✔ | sí | Solicitudes del sitio al CRM. |
| 37 | `wa_cotizar_preventivo` | E | ✔ | sí | El agente cotiza preventivos en borrador. |
| 39 | `catalogo_publico` | E | ✔ | sí | Catálogo del sitio desde el CRM. |
| 40 | `pendientes_admin` | E | ✔ | sí | Contadores de la barra. |
| 41 | `compras` | E | ✔ | sí | Compras y facturas de proveedor. |
| 42 | `inicio_admin` | E | ✔ | sí | Inicio del admin (redefinido por 64 y 65). |
| 43 | `quitar_producto` | E | ✔ | sí | Quitar un artículo. |
| 44 | `sync_proveedor` | E | ✔ | sí | Sincronización con XLStore. |
| 45 | `importar_productos_proveedor` | E | ✔ | sí | Traer productos del proveedor. |
| 46 | `publicar_al_aprobar_precio` | E | ✔ | sí | El primer precio aprobado publica. |
| 47 | `refacciones_subcategoria` | D | ✔ | — | Restaura subcategorías de refacciones. |
| 48 | `quitar_baterias_y_paneles_fuera_del_excel` | D | ✔ | — | Paso 2 de 2: desactiva productos. **No repetir.** |
| 49 | `borrar_definitivamente_baterias_y_paneles` | D | ✔ | — | Paso 2 de 2: **borra** productos. **No repetir.** |
| 50 | `sync_conserva_documentos` | E | ✔ | sí | Una lectura sin documentos no borra los anteriores. |
| 51 | `segundo_proveedor` | E | ✔ | sí | Solarama y varios proveedores por producto. |
| 52 | `disponibilidad_y_promociones` | E | ✔ | sí | Disponibilidad y promociones del sitio. |
| 53 | `bucket_ordenes_pdf` | E | ✔ | — | El bucket `ordenes` acepta PDF. |
| 54 | `recordatorio_cita` | E | ✔ | sí | Recordatorio del día anterior (cron `recordatorios-de-cita`). |
| 55 | `importar_clientes_whatsapp` | E | ✔ | sí | Clientes del historial de WhatsApp. |
| 56 | `salida_whatsapp` | E | ✔ | sí | Cola de salida de WhatsApp. |
| 57 | `campanas_whatsapp` | E | ✔ | sí | Campañas mensuales. |
| 58 | `envio_whatsapp` | E | ✔ | sí | Envío por la API (cron `enviar-whatsapp`). |
| 59 | `cotizacion_pago_garantia` | E | ✔ | — | Forma de pago y garantía. |
| 60 | `eliminar_cotizacion` | E | ✔ | sí | Borrar una cotización de prueba en cadena. |
| 61 | `expediente_cotizacion` | E | ✔ | sí | Expediente de ingresos y egresos. |
| 62 | `compra_de_factura` | E | ✔ | sí | Compra leída de una factura. |
| 63 | `cobranza_cotizacion` | E | ✔ | sí | La cobranza se cierra con el comprobante leído. |
| 64 | `inicio_cobranza` | E | ✔ | sí | Inicio: cobranza pendiente. |
| 65 | `inicio_expedientes` | E | ✔ | sí | Inicio: expedientes por cerrar (versión vigente de `inicio_admin`). |
| 66 | `pago_tecnicos` | E | ✔ | sí | Pago a técnicos por servicio. |
| 67 | `libro_financiero` | E | ✔ | sí | Libro único, CFDI, documentos y comisiones (redefine `registrar_pago_tecnico`). |
| 68 | `registro_migraciones` | E | ✔ | — | Tabla `_migraciones` e inventario de 01–63. |
| 69 | `foto_esquema_mensual` | E | ✔ | — | Foto del esquema cada mes en `esquema_fotos`, con lo que cambió y alerta de vistas en invoker. Su consulta se genera del 00: `node scripts/generar_foto_esquema.mjs`. |

## Funciones y cron en Supabase (fuera de esta carpeta)

- Edge Functions en `supabase/functions/`: `agente`, `agente-whatsapp`, `enviar-whatsapp`,
  `leer-comprobante`, `leer-placa`, `solicitud-web`, `whatsapp`. Lo desplegado debe coincidir con
  esta lista (el 09/10/2026 se borró `leer-factura`, la versión vieja de `leer-comprobante`).
- Cron (`cron.job`): `recordatorios-de-cita` (14:00 UTC), `enviar-whatsapp` (cada minuto) y
  `foto-esquema` (día 1 de cada mes, 15:00 UTC).
