# CRM PowerMx

CRM propio de PowerMx (Mérida, Yucatán): generadores eléctricos y sistemas solares
fotovoltaicos. Instalación, mantenimiento, pólizas y venta de equipo y refacciones.
Lo desarrolla y sostiene Caña, solo, con unas 10 horas a la semana. Respuestas en
español, concisas, con el paso siguiente claro.

## Stack

- React + Vite, JSX sin TypeScript. Sin router: `App.jsx` tiene un mapa `PANTALLAS`
  con los roles que ve cada pantalla, y cada una se carga con `lazy()` en su propio
  paquete (ver "Paquetes por pantalla").
- `jspdf` (fase 4): arma el PDF de la orden en el navegador del admin. Se carga con `import()`
  dentro de `lib/documentos.js`, nunca al arrancar la app (ver "Diseño"/Fase 4 en el flujo de
  servicio: arrastra `html2canvas` y `dompurify`, que aquí no se usan).
- Supabase, proyecto `crm-generadores`: Postgres, Auth, Storage (bucket `ordenes`),
  Edge Functions. Proyecto nuevo, con el sistema nuevo de llaves.
- Despliegue: Cloudflare Workers con static assets (`wrangler.jsonc`), en
  `https://crm.powermx.com.mx`. Cada push a `main` se publica solo.
  `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY` son **variables de construcción**
  en Cloudflare, no de ejecución.
- Repo privado: `reinch98/CRM-PowerMx`.

## Mapa de sistemas

- Este CRM es la fuente de verdad de clientes, equipos, productos e inventario.
- El sitio público vive aparte (repo `POWERMX-sitio`, otro proyecto de Supabase).
  Se publica desde un Excel con `convertir.js`. El CRM nunca escribe ahí.
  Al revés sí hay un puente: el formulario de cotizar del sitio escribe en el CRM, y **solo**
  por la Edge Function `solicitud-web` (ver "Solicitudes del sitio").

## Reglas del modelo de datos — no romper

- `equipos` es una sola tabla con `tipo` (generador, solar, bateria, otro) y
  `atributos jsonb` para lo específico. El formulario llena el JSON; nadie lo escribe a mano.
- Las órdenes se ligan a cliente y equipo. El técnico es `tecnico_id` (→ `perfiles`);
  la columna de texto `tecnico` es legado.
- Las partidas de una cotización se **copian** del catálogo al cotizar (`partidas jsonb`),
  para que un cambio de precio no altere cotizaciones viejas.
- **El inventario nunca se guarda como número.** Todo es `movimientos_inventario`,
  solo se inserta, y un error se corrige con otro movimiento. Tipos: `entrada`,
  `apartado`, `libera_apartado`, `salida_venta`, `a_resguardo`, `consumo_resguardo`,
  `consumo_servicio`, `ajuste` (único que acepta negativo).
  Vistas: `existencias`, `disponibles`, `por_reordenar`, `resguardo_por_cliente`.
  Disponible = físico − apartado − resguardo. Solo el disponible se puede prometer.
- Aceptar una cotización genera movimientos `apartado`; sacarla de aceptada genera
  `libera_apartado`. Lo hace la función SQL `cambiar_estado_cotizacion` en una sola
  transacción; el CRM no escribe esos movimientos por su cuenta.
- **Requisiciones de pedido** (`requisiciones`, una línea por producto): al aceptar una
  cotización sin material suficiente, la función la acepta igual, aparta y crea la
  requisición por lo que falta (faltante = pide − max(disponible, 0), menos lo ya
  pedido para esa cotización). Estados: `pendiente` → `pedida` → `recibida`, o
  `cancelada`. Marcar `recibida` inserta el movimiento `entrada` (referencia `REQ-n`)
  en la misma transacción: **no registrar esa entrada a mano**. Salir de "aceptada"
  cancela las requisiciones `pendiente`; las `pedida` no se cancelan solas, solo se
  avisa. Las cambia la función `cambiar_estado_requisicion`; solo admin.
- `productos`: `categoria`, `atributos jsonb`, `precios jsonb` (rentas y paquetes).
  `costo` es interno.
- Postgres no acepta `''` en columnas numéricas o de fecha: mandar `null`.
- Las fechas de captura se sacan con `hoyLocal()` de `src/lib/fechas.js`, nunca con
  `toISOString()`: en UTC, después de las 6 pm en Mérida ya es "mañana".

## Flujo de servicio — plan acordado con Caña el 19/09/2026 (aún sin construir)

**Roles:** admin · T1 (técnico responsable) · T2 (ayudante) · almacenista (rol nuevo) · cliente.

**Origen y reglas**
1. Dos caminos: (a) una **cotización aceptada** abre una cita y una orden; (b) una
   **cita agendada** en la Agenda abre su orden, y si es de **diagnóstico** también una
   cotización de diagnóstico (nueva o enlazada a una existente). Las citas de **póliza**
   (`equipos.en_poliza`, preventivo) abren **solo orden**, sin cotización. Correctivo,
   instalación y visita técnica agendadas a mano: cotización **opcional**, con aviso.
2. **Cita 1 : 1 orden** (una orden por visita). Una cotización puede tener varias citas.
3. Fecha, hora, duración, T1 y T2 se capturan **al cotizar como propuesta** y se vuelven
   cita real **al aceptar**. Sin fecha: cita `por_programar` (lista en la Agenda). Si la
   cotización ya tiene cita (nació de una), al aceptar se **enlaza a esa**; no se abre otra.
4. Aceptar abre cita y orden si el tipo es instalación, mantenimiento o diagnóstico, o si
   marcó `requiere_visita` (venta, refacciones, renta).
5. Rechazar o vencer cancela cita y orden si no tienen trabajo capturado; si ya lo hay,
   avisa. Rechazar la cotización de un diagnóstico cancela su cita (avisando antes).
6. **Orden dividida:** cada técnico escribe su parte (notas y fotos) en `orden_partes`
   (una fila por técnico y orden); solo edita la suya y ambos leen ambas. **Solo T1**
   cierra la orden y recoge la firma del cliente; al cerrar se juntan las partes y la
   cita pasa a `realizada`. El técnico nunca crea órdenes: nacen de una cita.
7. **Diagnóstico:** cotización con dos partidas **libres** (sin producto, así que no mueven
   inventario ni generan requisiciones): el **diagnóstico**, cuyo precio depende de la
   **clase** del equipo (gasolina 1.5–10 kW, gas LP 8–26 kW, diésel 30–500 kW) y de su
   **capacidad**, y el **servicio de traslado**, precio fijo por km que aplica a partir de
   los 40 km. Los precios viven en `tarifas_servicio` (solo admin; el técnico no ve
   precios) y se **copian** a la partida al cotizar. Cuando haya clientes ubicados por
   zonas, el traslado pasará a un esquema por zonas. Los km salen de `clientes.distancia_km`
   (propuesta). La clase sale de `equipos.atributos.combustible` (ya es un selector en
   `Equipos`: `gasolina`, `gas_lp`, `gas_natural`, `diesel`; el único equipo que había
   tenía el campo vacío) y la capacidad de `equipos.capacidad_kw`.
8. **Almacén (fases 2–3):** el almacenista entrega al T1, que **firma de recibido en su
   celular dentro del almacén** (con internet); solo T1 firma. Las refacciones aparecen
   en la orden **sin costo ni precio** (el técnico nunca los ve), con casilla vacía y
   contador si son varias. Lo no usado va a **pendientes de devolución** (T1 responsable,
   orden, T2 anotado; alerta por antigüedad; caja de observaciones). Material usado y no
   entregado: línea "adicional" sin descuento automático, marcada para conciliar
   (el costo al cliente es prácticamente fijo).
9. **Cierre (fase 4):** dos PDF: copia del **cliente** (solo el trabajo realizado; las
   piezas se ven en la cotización) y copia **interna** al expediente del cliente/equipo.
   Envío manual con "Enviar al cliente"; los PDF enviados se ordenan en **carpetas por
   semana** (ruta derivada de la fecha de envío, semana en hora de Mérida) más una tabla
   de envíos.
10. **Fase 5:** paquetes de mantenimiento por equipo que el agente va adaptando a partir de
    las piezas que se repiten; una cita de póliza puede precargarlos en la lista de
    surtido. Exige que las piezas usadas queden estructuradas (fase 3).

**Fases (cada una se publica sola; SQL antes que código):** 1a base de datos · 1b
cotizaciones abren cita y orden · 1c Agenda · 1d portal del técnico ("Mis trabajos"; la cola
sin señal pasa de insertar a actualizar órdenes que ya existen) · 1e retirar la creación
libre de órdenes (RLS) cuando los celulares vacíen sus colas · 2 almacén · 3 uso, cierre
y devoluciones · 4 PDF, envío y expediente · 5 control y paquetes.

**1a: corrida por Caña el 19/09/2026** (`supabase/sql/09_flujo_servicio_base.sql`;
falta anotar el resultado de su consulta de verificación). Columnas nuevas en `citas`,
`cotizaciones`, `ordenes_servicio` y `clientes`; tablas `orden_partes` y
`tarifas_servicio`; políticas de T2. Esquema real consultado ese día: ninguna de las tres
tablas tiene restricciones `check` (solo llaves); `ordenes_servicio` ya tenía `cita_id` y
`estado` con default `'abierta'`, y solo `cliente_id` es obligatorio, así que la orden
nace casi vacía; `citas.fecha` era obligatoria y ahora solo lo es fuera de `por_programar`.

**1b: aplicada y probada en la base el 20/09/2026** (`supabase/sql/10_cotizacion_abre_cita.sql`,
`Cotizaciones.jsx`, `Tarifas.jsx`, `Clientes.jsx`, `src/lib/tarifas.js`). Decisiones de
Caña: el traslado cobra **todos los km una vez rebasados los 40, solo ida**; el gas natural
va en la clase del gas LP; solares y baterías tienen tarifa propia de diagnóstico (clase
`solar`/`bateria`). La lógica de precios (`tarifas.js`) tiene 24 casos probados en Node.
Prueba con rollback: aceptar una cotización con fecha abre cita `programada` + orden
`abierta`; sin fecha, cita `por_programar`; aceptar de nuevo no abre nada; rechazar cancela
cita y orden. Las pantallas nuevas solo se vieron en el emulador (sin base).
La Agenda necesita la 1c para mostrar las citas `por_programar` (filtra por fecha).

**1c: aplicada y probada en la base el 20/09/2026** (`supabase/sql/11_agenda_citas.sql`, `Agenda.jsx`
reescrita con el diseño nuevo). La Agenda ya no inserta en `citas` desde el navegador: usa
`agendar_cita` (cita + orden; diagnóstico: crea o enlaza la cotización; póliza: solo
orden; otros tipos: cotización opcional), `programar_cita` (pone fecha/hora/técnicos a una
`por_programar`, o reprograma y reasigna; la orden abierta la sigue) y `cancelar_cita`
(cancela cita y orden si no hay trabajo). Avisa de empalmes de un técnico (no bloquea:
vuelve a llamar con `p_confirmar`). `lista_tecnicos()` (security definer) da id y nombre de
los técnicos: un técnico no puede leer el perfil de su compañero y necesita ver el nombre de
su ayudante. Muestra la lista "Por programar", ayudante, orden y cotización de cada cita.
La Agenda usa el rol de `cache_perfil` cuando no hay señal.
Prueba con rollback: agendar abre cita + orden; un horario que se empalma avisa y no crea
nada. Los folios de órdenes y cotizaciones **se saltan números**: las secuencias no se
revierten con `rollback`, así que cada prueba consume folios.

**Estado real de la base (20/09/2026):** los SQL `09` a `12` están **aplicados y probados**
con `begin/rollback` como admin, responsable, ayudante e intruso. Comprobado en la base:
el ayudante **no** puede cerrar la orden ni escribir la parte del responsable; el
responsable cierra y el reintento devuelve `sin_cambio`; ya cerrada nadie edita su parte;
el cierre junta las partes (la del responsable primero) y las fotos.

**1d: SQL aplicado y probado; pantalla probada solo en emulador** (`supabase/sql/12_cerrar_orden.sql`, `Trabajos.jsx`,
`src/lib/trabajos.js`, `src/lib/cola.js`, `Firma.jsx`). La pestaña "Órdenes" ahora abre
`Trabajos` ("Mis trabajos" para el técnico; para el admin, la lista de todas en solo
lectura). Lista las órdenes que nacen de una cita (abiertas y cerradas de los últimos 14
días); el detalle muestra cliente (Llamar / Cómo llegar), equipo, cita y **mi parte**
(notas y fotos que se guardan solas en el celular en cada cambio y suben a los 2 s o al
volver la señal), la parte del compañero de **solo lectura**, y —solo para T1— el cierre
(horómetro, observaciones, recomendaciones, seguimiento, refacciones manuales, firma o
"no pudo firmar"). `cerrar_orden` (SQL, security definer) junta las partes (la de T1
primero) y las fotos, guarda firma y datos, cierra la orden y marca la cita `realizada`;
es idempotente (un reintento devuelve `sin_cambio`). La orden libre de antes se retiró en la 1e.
Cola sin señal (`cola_trabajos`, reglas puras y probadas en `cola.js`): un elemento por
asunto (`parte:<orden>`, `cierre:<orden>`); guardar de nuevo REEMPLAZA (no apila); el
contador `n` evita perder lo que se escribe mientras sube; las partes suben antes que los
cierres, y un cierre espera a que su parte esté arriba. Otros datos locales:
`cache_mis_trabajos`, `cache_nombres_tecnicos`, `partes_locales` (las fotos, en IndexedDB).
Un fallo que no se arregla solo (orden cerrada o reasignada) ofrece "Tirar lo pendiente".
**Sin probar aún en un celular real:** subida real de fotos y firma a Storage, el guardado
de la parte desde la app (`upsert` con `onConflict`), `createSignedUrls` para ver las
fotos del compañero, y dos técnicos editando en dos celulares sin señal. La pantalla se
midió en el emulador: 0 textos de menos de 17 px, 0 contrastes bajo 4.5, 0 objetivos de
menos de 48 px.

**1e: aplicada y probada el 20/09/2026** (`supabase/sql/13_retirar_orden_libre.sql` y su prueba
`13_prueba_retirar_orden_libre.sql`). Quitó las políticas `tecnico_crea_ordenes` y
`tecnico_actualiza_sus_citas`: el técnico ya no crea órdenes ni toca citas (la cita pasa a
`realizada` con `cerrar_orden`, security definer; el botón "Realizada" de la Agenda es solo
admin). Prueba con rollback como técnico real: insertar orden rechazado, su cita intacta, la
sigue viendo. Las únicas políticas de escritura que quedan: `admin_citas`, `admin_ordenes`,
`admin_orden_partes` y las dos de T1/T2 sobre `orden_partes`. `Ordenes.jsx` (la orden libre) y
su `<details>` se retiraron del código. Un celular viejo puede conservar en localStorage
`ordenes_pendientes` y `cache_equipos`: ya nada los lee.
La prueba del flujo del técnico en un celular real (fotos, firma, parte del ayudante) la
hizo Caña el 20/09/2026: "todo en orden".

**2a: aplicada y probada en la base el 20/09/2026** (`supabase/sql/14_almacen_entregas.sql` y
`14_prueba_almacen.sql`; 11 pasos con rollback, todos "ok": aceptar aparta, la entrega pendiente
no mueve nada, pedir de más se rechaza, el almacén no firma, T1 firma → físico −3 / custodia +3 /
disponible igual, firmar dos veces no repite, rechazar libera solo lo que quedaba, entrega sin
firma exige motivo, el almacenista no lee tablas). En la prueba, usar `concat()` y no `||`:
un valor nulo anulaba todo el resultado.
Rol `almacenista` (`perfiles.rol` es texto; `movimientos_inventario.tipo` también, sin `check`).
El almacenista **no lee tablas**: trabaja con funciones security definer (`ordenes_por_surtir`,
`fijar_surtido`, `crear_entrega`, `cancelar_entrega`, `entregar_sin_firma`); T1 firma con
`firmar_entrega` (la firma va a `entregas/<id>.png` del bucket `ordenes`). Tablas `orden_surtido`
(se arma sola con las piezas de la cotización aceptada; copia sku/nombre: sin precios),
`entregas` y `entrega_lineas`; el técnico de la orden las lee. **El inventario no se mueve hasta
firmar:** `entrega_tecnico` (físico −, custodia +) más `libera_apartado` por lo entregado de la
cotización. `existencias` tiene `en_custodia`. Tipos reservados para la fase 3:
`devolucion_tecnico` (físico +, custodia −) y `consumo_tecnico` (custodia −).
`cambiar_estado_cotizacion` (copia de la de 10) ahora libera solo lo que aún queda apartado
(pedido − entregado) y cuenta el material entregado como "trabajo" para no cancelar la cita.
**Deuda:** `cancelar_cita` (11) todavía no mira el material entregado; se arregla en la fase 3
junto con la devolución. No poner al almacenista a operar en producción antes de la fase 3.

**2b: construida, sin publicar ni probar en celular real** (`src/Almacen.jsx`, `src/lib/almacen.js`,
`MaterialOrden` en `Trabajos.jsx`). Pantalla **Almacén** (roles `admin` y `almacenista`; el
almacenista solo ve esa pestaña): una tarjeta por orden abierta con cita programada, piezas con
pedida / entregada / por firmar / en el estante y estado con palabra, "Preparar entrega" (propone
lo que hay en el estante), entregas por firmar (cancelar, o "Entregar sin firma" con motivo) y
"Agregar una pieza a mano" (póliza o extra; busca en `existencias`, sin precios). Necesita señal:
no hay cola sin conexión para el almacén. En la orden del técnico, tarjeta **Material** (lista de
surtido y entregas, cacheadas con `cache_mis_trabajos`, así se ve sin señal): el T1 abre "Revisar y
firmar de recibido", firma en el canvas (`Firma` acepta `ayuda` y `etiqueta`), la imagen sube a
`entregas/<id>.png` del bucket `ordenes` y luego se llama `firmar_entrega`. T2 solo ve que está
pendiente. Probado en emulador con un Supabase falso (0 textos < 17 px, 0 contrastes < 4.5,
0 objetivos < 48 px, 0 px de desborde; las reglas puras de `almacen.js` con 17 casos en Node).
~~Crear la cuenta del almacenista~~ hecha: al 26/09/2026 la base tiene cinco perfiles activos,
uno por rol (`admin`, `tecnico`, `almacenista`, `cliente` y el `bot` de WhatsApp). Falta
probar las pantallas contra la base real con las cuentas de almacenista y técnico.

**3a: uso de material, cierre y devoluciones — aplicada y probada el 20/09/2026** (`supabase/sql/18_uso_y_devoluciones.sql`
y `18_prueba_uso_y_devoluciones.sql`; 10 pasos con rollback, todos "ok"). En plpgsql, **no llamar `s` al
alias de una tabla si la función tiene una variable `s`**: la primera versión de `recibir_devolucion` tronó
con «column reference "s.orden_id" is ambiguous» y solo la prueba lo encontró (alias `os`). Al cerrar, T1 declara cuánto **usó** de lo recibido (`p_uso`
= `[{producto_id, usadas}]`): sale del inventario como `consumo_tecnico` (custodia −). Lo que NO usó
queda **pendiente de devolución** = `entregada − usada − devuelta − diferencia` (columnas nuevas de
`orden_surtido`; no hay tabla aparte). Aparecen las órdenes **cerradas o canceladas** con pendiente:
así una cita cancelada con material entregado ya no es un hueco (se cierra la deuda de
`cancelar_cita`: no se bloquea, el material vuelve por aquí). `recibir_devolucion` (almacén/admin:
`devolucion_tecnico`, físico +, custodia −; si se devuelve menos de lo pendiente exige una
**observación**; queda en la tabla `devoluciones`), `resolver_diferencia` (**solo admin**: da por
consumido lo que nunca volvió, con motivo escrito) y `devoluciones_pendientes()` (con `dias` para la
alerta por antigüedad). Lo que T1 usó y NO le entregaron (`p_refacciones`) queda como **adicional por
conciliar** sin descuento automático (`adicionales_por_conciliar`, `conciliar_adicional`). `cerrar_orden`
gana `p_uso`; se BORRA la firma vieja para que PostgREST no vea dos funciones; los cierres viejos
en cola (sin `p_uso`) siguen sirviendo. Un cierre repetido no repite el consumo.

**3b: pantallas — construida, sin publicar ni probar en celular real** (`src/lib/material.js`,
`src/lib/almacen.js`, `Trabajos.jsx`, `Almacen.jsx`). **Técnico (T1) al cerrar:** sección "Material que
usé": una casilla "La usé" si recibió 1 pieza, un contador "Usadas ___ de N" si recibió varias, siempre
vacío al empezar (sin capturar = 0: lo seguro es devolver todo); avisa "Al cerrar, le debes al almacén:
…"; el cierre manda `p_uso` (recortado a lo recibido, nunca negativo) y sigue funcionando sin señal
porque el material viene en `cache_mis_trabajos`. La lista manual pasó a "Material usado que no me
entregaron" (adicional por conciliar). En una orden cerrada, "Material" muestra Usadas / Por devolver y
"Te falta devolver: …". **Almacén** ahora tiene pestañas con conteo: *Por entregar*, *Devoluciones*
(las más antiguas primero; antigüedad en palabra: Reciente / Por vencer desde 2 días / Atrasada desde 5;
propone recibir todo lo pendiente; la observación es obligatoria si se recibe menos; historial DEV-n;
solo el **admin** ve "Dar por consumido lo que no volvió", con motivo) y *Adicionales* (conciliar con nota).
Probado en emulador con un Supabase falso con los tres roles (0 textos < 17 px, 0 contrastes < 4.5, 0
objetivos < 48 px, 0 px de desborde; reglas puras con 25 casos en Node).

**Solicitud de material del técnico (SQL 19) — aplicada y probada el 21/09/2026**
(`supabase/sql/19_solicitudes_material.sql` y `19_prueba_solicitudes_material.sql`; 10 pasos con
rollback, todos "ok"). La base real solo tenía un admin y un técnico: la prueba usa un tercer
perfil que cambia de rol dentro de la transacción (primero sin rol de técnico, para probar que no
ve nada; luego técnico, como T2; al final almacenista), igual que las pruebas de la 14 y la 18.
El técnico pide una pieza que necesita (típicamente "para la siguiente visita") **sin ver costos ni
precios**. Es una **solicitud**, no una requisición: la requisición (`requisiciones`, solo admin,
ligada a una cotización) sigue siendo de compras; esta tabla (`solicitudes_material`) es de
coordinación y **no mueve inventario por sí sola**.
- Se pide **desde una orden** (el técnico debe ser T1 o T2: `soy_de_la_orden`); el trigger
  `_completar_solicitud_material` completa solos `equipo_id`/`cliente_id` desde la orden y copia
  `sku`/`nombre`/`unidad` del producto (o queda `descripcion_libre` si la pieza no está en el
  catálogo) — así el técnico lee su propia fila sin permiso sobre `productos`, igual que
  `orden_surtido`/`entrega_lineas`.
- RLS: el técnico crea la suya y lee las suyas y las de su compañero de la misma orden; puede
  cancelarla (pasar a "descartada") solo mientras sigue "pendiente", nunca la marca "atendida" él
  mismo. Almacén/admin (`_es_almacen()`) leen todas las pendientes con contexto
  (`solicitudes_material_pendientes`: técnico, cliente, equipo, orden, existencia física) y las
  resuelven con `atender_solicitud_material` (exige escribir cómo quedó: "se apartó en el
  almacén", "se generó REQ-12"…) o `descartar_solicitud_material` (exige motivo).
- Pantallas: en la orden del técnico (`Trabajos.jsx`), sección **"Pedir material"** (soyT1 o soyT2;
  necesita señal, sin cola offline) con el mismo buscador sin precios que el almacén
  (`cargarExistencias`, de `existencias`) o una descripción libre; lista sus solicitudes de esa
  orden con estado y, si ya se resolvió, la resolución. En `Almacen.jsx`, pestaña **"Solicitudes"**
  con las pendientes y los botones de atender/descartar. Reglas puras en `src/lib/solicitudes.js`
  (16 casos en Node); probado en emulador con un Supabase falso en los dos roles (0 textos < 17 px,
  0 contrastes < 4.5, 0 objetivos < 48 px, 0 px de desborde).
- Simplificado a propósito frente a la idea original: no hay apartado automático de inventario (lo
  decide una persona a mano, con las pantallas que ya existen) ni aviso por WhatsApp todavía. Sigue
  pendiente conectar con "Requiere seguimiento" y con la Fase 5 (paquetes de mantenimiento).

**Fase 4: PDF de la orden y su envío — construida y con el SQL aplicado y probado el 21/09/2026**
(`supabase/sql/20_pdf_orden.sql` y `20_prueba_pdf_orden.sql`; 5 pasos con rollback, todos "ok". En
la prueba: cuando el técnico no tiene NINGUNA política de `update` sobre una tabla —como
`ordenes_servicio` desde la 1e—, RLS no lanza una excepción, solo hace que el `update` no toque
ninguna fila; hay que revisar `row_count`, no solo esperar un error, a diferencia de un intento
que sí ve la fila pero falla el `with check`. `src/lib/documentos.js`,
`DocumentoOrden` en `Trabajos.jsx`, solo admin, cuando la orden está `cerrada`). El PDF se arma
**en el navegador del admin** con `jsPDF` (dependencia nueva; no hay CLI de Supabase para una
función, y el admin ya tiene todos los datos en pantalla): no cambia nada del flujo del técnico.
- **Dos copias**, en el bucket `ordenes` que ya existía: **cliente** (solo el trabajo realizado;
  las piezas se ven en la cotización, como se acordó) e **interna**, al expediente
  (`expedientes/<cliente_id>/OS-<folio>-<tipo>.pdf`; agrega el material usado, sin costos —
  `orden_surtido` nunca los tuvo). `ordenes_pdf` lleva un registro por tipo y orden (upsert: al
  regenerar, se reemplaza, no se duplica).
- **"Enviar al cliente" es manual** (sin la API de WhatsApp todavía): junta los contactos con
  `recibe_ordenes` del equipo (o de toda la empresa si no hay equipo), el admin ajusta a quién,
  y al confirmar sube una copia fechada a `enviados/<AAAA>-S<ss>/OS-<folio>-<marca de
  tiempo>.pdf` (semana ISO 8601 en hora del dispositivo, `semanaLocal()` de `fechas.js`, 8 casos
  probados en Node incluidos los cambios de año) y registra la fila en `envios_orden`
  (destinatarios, quién, cuándo). Por cada destinatario hay un enlace **"Abrir WhatsApp"**
  (reutiliza `enlaceWhatsApp` de `lib/avisos.js`) para encontrar el chat rápido; el PDF se
  descarga aparte y se adjunta a mano — wa.me no permite mandar un archivo por enlace.
- **"Enviar al cliente en cuanto se cierre"** (pedido de Caña el 21/09/2026): el admin marca una
  orden desde que existe, **abierta o cerrada** (`ordenes_servicio.enviar_al_cerrar`, admin ya
  tenía permiso de sobra en esa tabla). No es un envío automático de verdad — el PDF lo sigue
  generando el admin — pero al cerrarse la orden resalta con un aviso, el panel "Enviar al
  cliente" se abre solo (con los destinatarios ya cargados) y la lista de "Mis trabajos" muestra
  "Por enviar" en esa orden. La marca se apaga sola al registrar el envío
  (`registrarEnvio` en `documentos.js`).
- **`jsPDF` se carga con `import()` dentro de `construirPdfOrden`, no en el arranque**: arrastra
  `html2canvas` y `dompurify` (que aquí no se usan) y suma cerca de 970 kB sin comprimir. Cargado
  aparte, un técnico que nunca ve esta pantalla no lo descarga al abrir la app — aunque el
  service worker sí lo precachea en segundo plano en todos los celulares al instalar/actualizar
  (`vite.config.js` mete TODO el bundle a la lista, sin distinguir), así que no es gratis del
  todo. El resto del bundle ya se dividió por pantalla: ver "Paquetes por pantalla".
- **El PDF lleva el formato de mantenimiento (25/09/2026).** Ya no es solo "trabajo
  realizado": arma el documento completo desde `orden_revision`.
  - **Dictamen arriba de todo**, en un recuadro: es lo primero que el cliente quiere saber.
    Luego las condiciones de llegada (clima e irradiancia en solar; tipo de servicio,
    combustible y fases en generador).
  - **Los puntos, sección por sección**, con su calificación en palabra (no "B", que en el
    papel es un botón), sus datos numéricos y el hallazgo indentado cuando lo hay. Se
    imprimen **solo los contestados** y solo las secciones que aplican.
  - **Mediciones**: strings con su veredicto, parámetros AC y banco en solar; lecturas en
    vacío y con carga más la prueba de transferencia en generador.
  - **Anexo de evidencia**: las fotos van **dentro** del documento, dos por fila y con el
    punto del que son. Tope de `MAX_FOTOS_PDF` (12) para que quepa en WhatsApp; si hay más,
    lo dice. Un PDF de ejemplo con 3 páginas y 2 fotos pesó 120 kB y tardó 95 ms.
  - Pantalla y PDF comparten `contextoDeRevision`, `formatoDe` y `revisionDe` de
    `revision.js`: si cada uno dedujera por su cuenta qué aplica, el papel mostraría puntos
    que el técnico nunca vio.
  - **Dos defectos que solo aparecieron generando el PDF de verdad:**
    1. **Helvetica solo escribe WinAnsi.** Un carácter fuera de ahí no falla: sale en dos
       bytes y en el PDF se ve basura. Le pasó a la **Ω** de "Aislamiento (MΩ)". `paraPdf()`
       traduce los que usamos (Ω→ohm, Δ→delta, −→-, ±→+/-, →→->), deja pasar la puntuación
       que sí está en WinAnsi y marca con `?` lo que no reconoce (15 casos en Node).
    2. **jsPDF no valida las imágenes**: le das cualquier cosa con cara de JPEG y la
       incrusta, y el visor muestra un hueco. `fotoDataUrl` ahora la **decodifica** con
       `createImageBitmap` antes de entregarla; una foto corrupta se salta y el documento
       sigue completo (comprobado: 2 imágenes de 3, sin error y con la firma en su lugar).
- **No probado con datos reales:** la firma no se pudo insertar de verdad en el emulador (el
  Supabase falso no tiene un archivo de firma real que descargar), así que solo se comprobó la
  rama "El cliente no firmó esta orden." Falta ver un PDF real, con firma, abierto en un celular.
- Probado en emulador con un Supabase falso (0 textos < 17 px, 0 contrastes < 4.5, 0 objetivos <
  48 px, 0 px de desborde): se generaron las dos copias, la ruta y el `upsert` fueron los
  esperados, "Enviar" subió la copia fechada a la carpeta de la semana correcta y registró el
  envío, y la marca "enviar al cerrar" se guardó, se resaltó al cerrar y se apagó sola al enviar.

**Tarifas de catálogo con SKU propio (SQL 21) — aplicada y probada el 21/09/2026, pedido de
Caña** (`supabase/sql/21_tarifas_catalogo.sql` y `21_prueba_tarifas_catalogo.sql`; 6 pasos con
rollback, todos "ok"). `tarifas_servicio` ganó conceptos nuevos —`correctivo`, `preventivo`,
`instalacion_gas`, `instalacion_electrica`, `otro`— que, a diferencia de diagnóstico y traslado,
**no dependen de una fórmula**: cada uno tiene su propio `sku` (único) y se busca y se agrega a
una cotización **igual que un producto**, en el mismo cuadro de Cotizaciones. Clase y tramo de
kW siguen siendo opcionales para estos (una instalación no siempre depende de la clase del
equipo); `otro` exige un `nombre` propio porque no tiene etiqueta por defecto.
**Sigue siendo una partida LIBRE** (`producto_id` null), igual que el diagnóstico y el traslado:
no mueve inventario ni genera requisiciones, así que `cambiar_estado_cotizacion` no se tocó —esa
función ya solo actúa sobre partidas con `producto_id`. La restricción vieja del `concepto` no
tenía nombre explícito: el script la busca por su definición (`pg_get_constraintdef` sobre
`pg_constraint`) en vez de adivinar cómo la nombró Postgres, y la reemplaza por una con nombre
fijo para poder repetirse.
`src/lib/tarifas.js`: `esConceptoCatalogo`, `nombreTarifaCatalogo` (arma el nombre a mostrar:
usa el capturado, o concepto + clase + tramo), `tarifasDeCatalogo` (las que se pueden buscar:
activas, con sku, que no sean diagnóstico/traslado), `sugerirSkuTarifa` (propone un SKU tipo
`SRV-COR-GLP`; el admin lo puede editar, y desde que lo toca ya no se le pisa). 23 casos
probados en Node (antes 24 en total contando los ya existentes de diagnóstico/traslado).
`Tarifas.jsx`: sección nueva "Servicios (por SKU)" antes de Diagnóstico y Traslado, con su
propia tabla y su alta (SKU, concepto, clase opcional, nombre opcional, precio). `Cotizaciones.jsx`:
el buscador de partidas ahora junta productos y servicios de catálogo en una sola lista,
marcando "Servicio" en los resultados; al agregarlos arman la partida sin `producto_id`. Probado
en emulador con un Supabase falso (0 textos < 17 px, 0 contrastes < 4.5, 0 objetivos < 48 px,
0 px de desborde): un producto y un servicio conviven en la misma cotización, y solo el producto
dispara el aviso de "sin existencia suficiente".

**Corrección (SQL 17, 20/09/2026):** `citas_fecha_segun_estado` (de la 09) exigía fecha salvo en
`por_programar`, así que **cancelar una cita sin fecha tronaba** («violates check constraint»), igual
que rechazar/vencer una cotización cuya cita aún no tenía fecha. Ahora una cita sin fecha puede ser
`por_programar` o `cancelada` (`17_citas_canceladas_sin_fecha.sql`, con prueba). Lo detectó Caña en
producción: las pruebas de 1b/1c solo cancelaron citas CON fecha. Lección: al poner una restricción
por estado, probar TODAS las transiciones, incluida cancelar desde el estado sin datos.

**Contactos (SQL 15): aplicada y probada el 20/09/2026** (`supabase/sql/15_contactos.sql` y
`15_prueba_contactos.sql`; 11 pasos con rollback, todos "ok", incluidos otro cliente, mismo número
en dos clientes y el técnico sin acceso; migró 1 contacto). En la prueba, `concat()` escribe los
booleanos como `t`/`f`, y la tabla `clientes` exige `telefono` (al crear un cliente de prueba). Tablas `contactos` (una fila por persona-y-número, de un cliente;
`de_toda_la_empresa` para administración y similares) y `equipo_contactos` (rol `responsable` |
`encargado` | `administracion` | `solo_avisos` y permisos: pedir citas, recibir órdenes, recibir
cotizaciones; **un solo responsable por equipo**, índice único). Teléfonos comparados por sus
últimos 10 dígitos (`normalizar_telefono`, `telefono_norm`: WhatsApp da 521…). Un mismo número
puede estar en varios clientes, no dos veces en el mismo. `vincular_contacto` pone permisos por
rol y, al nombrar un responsable, baja al anterior a encargado; `identificar_telefono` devuelve
personas, clientes y equipos (con la serie) de un número; vista `contactos_por_equipo`
(invoker). Solo admin. La migración copia `contacto_nombre`, `telefono`, `telefono_alterno` y
`email` de cada ficha como contactos de toda la empresa, verificados. `clientes.telefono` sigue
siendo el de la ficha (el técnico lo usa para llamar).
Pantalla **Contactos** (`src/Contactos.jsx`, `src/lib/contactos.js`, solo admin), construida y probada
en emulador con un Supabase falso (0 textos < 17 px, 0 contrastes < 4.5, 0 objetivos < 48 px, 0 px de
desborde; reglas puras con 20 casos en Node): "Buscar por teléfono" (usa `identificar_telefono`,
sirve para comprobar que un número se reconoce en cualquier formato), personas por cliente (alta
plegable, editar, marcar verificado, quitar = `activo = false`, que libera el número) y, por
equipo, las personas a cargo con "Ligar a este equipo" (`vincular_contacto`; avisa si bajará al
responsable actual) y aviso "Sin responsable". Pendiente: que el técnico vea al responsable de su
orden; ligar contactos desde la pantalla Equipos.

**Avisos de cita (SQL 16): aplicada y probada el 20/09/2026** (`supabase/sql/16_avisos_de_cita.sql` y
`16_prueba_avisos.sql`; 11 pasos con rollback, todos "ok"). "Confirmar" una cita = que quede `programada` (agendada en la Agenda,
aceptando una cotización con horario, o programando una `por_programar`). Un **trigger en `citas`**
cubre todos esos caminos y pone en la cola `avisos` (un aviso pendiente por persona y cita) un
mensaje **al cliente** (sus contactos del equipo: el responsable y quien pueda pedir citas; sin
contactos, el teléfono de la ficha) y **a cada técnico** (T1 y T2, con `perfiles.telefono`: cliente,
contacto en sitio con teléfono, dirección, referencias, mapa, equipo con serie, horario y su papel;
**nunca precios ni costos**). Reprogramar o cambiar de técnico avisa del cambio; cancelar avisa,
pero solo a quien ya había recibido un mensaje de esa cita; un técnico recién asignado recibe una
confirmación, no un "cambio". El **texto se arma al leer** (`texto_aviso`, con los datos de ese
momento) y al enviarse se guarda copia (`texto_enviado`). `avisos_pendientes()` y
`marcar_aviso(id, 'enviado' | 'descartado')`, solo admin. **Salida**: hoy, el admin abre la cola en
la Agenda y pulsa "Enviar por WhatsApp" (enlace `wa.me/52<10 dígitos>?text=…`, un toque por
destinatario); después, una Edge Function con la API de WhatsApp leerá la misma cola y mandará
plantillas (fuera de las 24 h). Un técnico sin teléfono en su perfil aparece en la cola "sin número":
hay que capturarlo en Usuarios.
La cola está en la **Agenda** (`src/AvisosPendientes.jsx`, `src/lib/avisos.js`; solo admin, debajo de
"Por programar"): tarjetas por cita con un mensaje por persona, "Ver mensaje", **"Enviar por WhatsApp"**
(abre `wa.me/52<10 dígitos>?text=…` y marca el aviso `enviado`), "Copiar mensaje", "Descartar", "Falta el
teléfono" si no hay número, y "Avisos de los últimos 3 días" con "Enviar de nuevo" (no vuelve a marcar).
Se relee cada vez que la Agenda recarga. Probada en emulador con un Supabase falso (0 textos < 17 px,
0 contrastes < 4.5, 0 objetivos < 48 px, 0 px de desborde; reglas puras con 14 casos en Node). Ojo:
marcar al pulsar el enlace da por enviado algo que el admin podría no mandar; por eso queda "Enviar de
nuevo". Un cambio de técnico sin cambio de horario también manda "CAMBIO en el servicio" al cliente y
al técnico que no cambió (informativo, con el nuevo nombre).

**El recordatorio del día anterior (SQL 54, 01/10/2026) — aplicado, falta correr la
prueba y programar el cron.** Estaba en el plan original ("confirmación por plantilla →
recordatorio el día anterior → …") pero nunca se construyó: `avisos.tipo` solo aceptaba
confirmacion/reprogramacion/cancelacion. Se encontró el hueco preparando las plantillas
de Meta (Caña mandó su cuenta a revisión el 01/10/2026) — hacía falta un cuarto tipo de
aviso para poder redactar la plantilla `recordatorio_cita`.
- `generar_recordatorios()` (`supabase/sql/54_recordatorio_cita.sql`, revocada a todos:
  no es para la API) encola un aviso `recordatorio` **solo al cliente** (el técnico ya ve
  su agenda en la app) por cada cita `programada` cuya fecha sea **mañana** en hora de
  Mérida. Set-based como `_encolar_avisos`, no por cita una por una; idempotente de
  verdad — nunca inserta un segundo recordatorio para la misma cita y el mismo
  destinatario, sin importar cuántas veces se llame ni en qué estado haya quedado el
  anterior (el índice `un_aviso_pendiente` de la 16 solo cubre "pendiente").
  `texto_aviso()` se redefinió completa (misma técnica que la 29 con
  `paquete_preventivo`) con la rama nueva.
- **Falta programarlo:** `generar_recordatorios()` existe pero nada la llama todavía.
  Hace falta activar la extensión `pg_cron` desde Supabase → Database → Extensions (un
  clic) y correr una vez `select cron.schedule('recordatorios-de-cita', '0 14 * * *',
  $$select generar_recordatorios()$$);` (14:00 UTC = 08:00 Mérida, sin horario de
  verano) — los pasos exactos están comentados al final del archivo 54. Es la primera
  vez que el proyecto usa un cron de verdad dentro de la base.
  Prueba (`54_prueba_recordatorio_cita.sql`, SQL plano, sin plpgsql): dos citas de
  mañana (una con contacto de empresa, otra con el teléfono de la ficha) y una de
  pasado mañana como control. **Escrita; falta correrla en Supabase.**
- Sale igual que los demás en la cola "Avisos pendientes" de la Agenda, con su
  etiqueta propia (`TIPOS.recordatorio` en `src/lib/avisos.js`) — no hizo falta tocar
  la pantalla. Mientras no haya plantilla aprobada ni envío por la API, se manda a
  mano con el enlace de WhatsApp, como confirmación/reprogramación/cancelación.

**Datos que faltan capturar** (desde la pantalla Tarifas, no bloquean el código): tarifas
de diagnóstico por clase × tramo de kW, precio por km, y `distancia_km` de cada cliente
(se edita en la lista de Clientes).

## Equipo capturado en campo — acordado con Caña el 24/09/2026

**SQL 23 aplicado y probado el 24/09/2026** (`supabase/sql/23_equipo_en_campo.sql` y su prueba;
10 pasos con rollback, todos "ok"). Las pantallas van aparte.
- `equipos.numero_serie` **dejó de ser obligatorio**. Postgres permite varios nulos en un
  índice único, así que muchos equipos "sin serie" conviven sin chocar. Columna nueva
  `equipos.horas_uso_fecha`: un número de horas suelto no dice nada sin su fecha.
- `registrar_equipo_en_orden(orden, datos jsonb)` — el técnico (T1 **o T2**: el ayudante bien
  puede ser quien lee la placa) da de alta el equipo desde su orden y queda ligado a la orden
  y a la cita. **Si la serie ya existe para ese cliente, no duplica**: liga la que había y le
  llena solo los huecos vacíos. No toca nada comercial (`en_poliza`, frecuencia, próximo
  mantenimiento): eso es de la oficina.
- `equipo_de_orden(orden, equipo)` — elegir uno guardado. Un equipo de otro cliente se
  rechaza aunque el id venga bien escrito. Solo con la orden **abierta**.
- **El horómetro sube al equipo con un TRIGGER** (`horometro_al_equipo` sobre
  `ordenes_servicio`), no dentro de `cerrar_orden`: así también cubre una orden que el admin
  corrija desde la oficina, y no hay que volver a copiar entera la función de cierre (ya
  reescrita en la 12 y la 18). Un horómetro que **retrocede no se bloquea** (motor
  reemplazado, tablero nuevo o dedo equivocado): se guarda y queda el rastro en `auditoria`
  con el valor anterior y la marca `retrocede`.
- `equipos_sin_serie()` — la lista que la oficina va cerrando, con cliente y última visita.
- `_apunta(...)` escribe en `auditoria` (columnas reales: `tabla`, `registro_id`, `accion`,
  `valor_anterior`, `valor_nuevo`, `origen`, `usuario`; `origen` por defecto es `'agente'`,
  aquí se usa `'campo'`).
- **Tropiezo de la prueba:** `cerrar_orden` exige trabajo capturado, así que una prueba que
  cierra una orden tiene que insertar antes la parte del técnico en `orden_partes`.

**Pantallas (24/09/2026) — construidas, sin probar en celular real** (`src/lib/equipoCampo.js`,
`EquipoOrden` en `Trabajos.jsx`, `Equipos.jsx`).
- **Orden del técnico:** tarjeta **Equipo**. Sin equipo avisa "Falta" y ofrece "¿Qué equipo
  es?"; con equipo muestra descripción, serie (o "Serie pendiente") y el horómetro con su
  fecha, más "No es este equipo". Al elegir salen los equipos guardados del cliente como
  botones y "Es un equipo nuevo" abre el alta (tipo, marca, modelo, capacidad, combustible
  solo si es generador, serie y dónde está). **Necesita señal**, como pedir material: no hay
  cola sin conexión. T1 y T2, solo con la orden abierta.
- **Sin serie se guarda**, pero **algo** tiene que identificarlo (marca, modelo, serie o
  dónde está): si no, quedaría un equipo fantasma que nadie reconoce en la siguiente visita.
  Misma regla en el alta de la oficina, donde la serie dejó de llevar asterisco. La serie
  vacía se manda como **null**, nunca como `''`: `equipos_sin_serie()` busca nulos y una
  cadena vacía chocaría con la siguiente en el índice único.
- **Equipos (oficina):** columna **Horómetro** ("1,200 h al 01/08/26"), etiqueta "Serie
  pendiente" en lugar de la serie, y sección **"Les falta el número de serie"** con cliente,
  capacidad, dónde está y la última orden, para saber a quién preguntarle.
- **Lint:** en `Equipos.jsx`, `cargarEquipos` no puede llamar a otra función del componente
  o `react-hooks/exhaustive-deps` deja de considerarla estable y exige ponerla en las
  dependencias del efecto de arranque. Por eso la carga de "sin serie" va **dentro** de
  `cargarEquipos`, no en una función aparte.
- Probado en emulador con un Supabase falso, como técnico y como admin (0 textos < 17 px,
  0 contrastes < 4.5, 0 objetivos < 48 px, 0 px de desborde; 29 casos puros en Node).
  Comprobado que el JSON que sale a la base no lleva cadenas vacías y manda la capacidad
  como número.

El cliente casi nunca sabe el modelo ni la serie; el técnico sí, porque está parado frente
a la placa. Así que el equipo deja de ser un requisito para agendar y pasa a ser algo que la
base **aprende en cada visita**.

**Primer servicio, número desconocido**
1. Al pedir la cita se pregunta **capacidad, clase y dirección**. Con eso se da precio de
   visita de diagnóstico; si pide un mantenimiento concreto, se cotiza según capacidad.
   La clase hace falta además de la capacidad porque los rangos se traslapan entre 8 y 10 kW
   (gasolina 1.5–10, gas LP 8–26, diésel 30–500): hay que preguntar "¿gasolina, gas o diésel?".
2. **El cliente lo crea el admin**, no se crea solo desde WhatsApp: un número equivocado
   llenaría la base de basura. Al confirmar la cita `por_programar` ya revisa cada una.
3. **La orden nace sin equipo.** `agendar_cita` ya lo permite: solo valida `p_equipo` si no
   viene nulo. Esta parte no hay que construirla.
4. Al cerrar, el técnico captura la placa: marca, modelo, capacidad, combustible y serie.
   **Si no puede leer la serie, el equipo se crea igual** y queda en una lista de "serie
   pendiente" — una placa borrada no puede detener el trabajo.
5. El equipo queda ligado al cliente y a esa orden.

**Servicios siguientes:** al abrir la orden el técnico **elige entre los equipos guardados de
ese cliente o agrega uno nuevo**. Así la base se llena sola con cada visita.

**El horómetro sube al equipo.** Hoy se captura al cerrar (`ordenes_servicio.horas_equipo`,
SQL 12) pero **se queda encerrado ahí**: para saber las horas de un generador hay que ir a
buscar su última orden. Debe quedar también en el equipo, con su fecha. Aplica a todos los
equipos, no solo a los nuevos.

**Dos tipos de orden de servicio: generador y solar** (pedido de Caña el 24/09/2026). Son
trabajos distintos y no se capturan igual. Nota de diseño: `equipos.tipo` ya distingue
`generador`, `solar`, `bateria` y `otro`, así que el tipo de orden puede **salir del equipo**
en vez de ser un campo aparte; la excepción es la primera visita, cuando todavía no hay
equipo y hay que elegirlo a mano.

**El formato solar en papel** (`Formato_Mantenimiento_FV_BESS_PowerMx.pdf`, PMX-FR-MTTO-01
Rev. 2.0, 4 páginas, en el escritorio de Caña; el PDF trae fuentes subconjunto, así que para
leerlo hubo que juntar sus tablas `ToUnicode` — `scratchpad/leerpdf2.mjs`). Diez secciones:
1 datos del cliente y del servicio · 2 registro de equipos principales (módulos, inversores,
baterías/BESS, BMS: marca, modelo, serie, cantidad) · 3 seguridad y preparación (8 puntos;
**bloqueante**: un "NO" sin control compensatorio suspende el servicio) · 4 módulos y
estructura (10) · 5 inversores y controladores (9) · 6 BESS, banco y BMS (11) · 7 tableros,
protecciones DC/AC y tierra (7) · 8 mediciones de campo (strings con Voc/Isc/aislamiento,
parámetros AC, BESS/tierra) · 9 observaciones, refacciones y evidencia fotográfica ·
10 dictamen (Aprobado / Condicionado / No aprobado), próximo mantenimiento y dos firmas.
Los puntos se califican **B / R / M / N/A** (bueno, regular, malo, no aplica) y varios llevan
un dato numérico (torque, ΔT, SOC/SOH, ΔV, continuidad…).
**Caña pidió resumirlo para que sea más dinámico en sitio** — falta acordar los recortes.
Las secciones 1 y 2 **no se vuelven a capturar**: ya están en la orden, el cliente y el
equipo (la 2 es justo el registro de equipos de la 23).


**SQL 25/09/2026: `24_revision_orden.sql` aplicado y probado** (10 pasos con rollback, todos
"ok") **y la pantalla del técnico construida** (`src/lib/revision.js`, `RevisionOrden` en
`Trabajos.jsx`; 34 casos puros en Node; medida en el emulador: 0 textos < 17 px, 0 contrastes
< 4.5, 0 objetivos < 48 px, 0 px de desborde, plegada y abierta).
- Tabla **`orden_revision`**: una fila por orden con las respuestas en `jsonb`. Una fila y no
  una por punto porque esto se llena **sin señal** y sube de un golpe; veinte inserts podrían
  subir a medias. RLS como las partes: los dos técnicos escriben con la orden abierta,
  cerrada todos leen y nadie edita. El sello (quién y cuándo) lo pone la base.
- **El trigger `seguridad_antes_de_cerrar`** aplica la regla del formato: un punto de la
  sección 1 en "M" sin control compensatorio escrito **impide cerrar**. Va sobre
  `ordenes_servicio` y no dentro de `cerrar_orden`, por lo mismo que el horómetro. No es un
  callejón: basta escribir el control. **La foto obligatoria en los "M" NO se bloquea en la
  base** — se exige en la pantalla, porque una cámara que falla dejaría al técnico sin poder
  cerrar en el sitio.
- **Cola sin señal:** asunto nuevo `revision:<orden>` en `cola.js`, con peso **entre** la
  parte y el cierre (`PESO = {parte: 0, revision: 1, cierre: 2}`): el cierre necesita que la
  revisión ya esté arriba o el trigger lo rechaza. Datos locales: `revisiones_locales`.
  `revisionDeOrden()` prefiere lo del celular si está sucio, nunca al revés: un refresco
  pisaría lo que el técnico acaba de escribir.
- El catálogo de puntos vive en **`src/lib/revision.js`**, no en la base: es presentación,
  cambia con el formato en papel y lo comparten la pantalla y el PDF. Ahí están también
  `seguridadSinControl` (misma comprobación que el trigger, adelantada para avisar antes),
  `veredictoString` (propone Pasa / Revisar / No pasa), `dictamenSugerido` y `loQueFalta`.
- **Mediciones (25/09/2026): construidas** para los dos formatos. En el papel son tablas
  anchas con columnas fijas —seis strings aunque la instalación tenga dos, tres fases aunque
  el equipo sea monofásico—; aquí **los strings se agregan uno a uno** y **las fases que no
  existen no se preguntan** (casilla "el equipo es trifásico").
  - **Generador:** las 14 lecturas de la sección 4, cada una **en vacío y con carga**. En el
    **tipo A** no se pide la columna de carga: ese servicio es solo inspección con prueba en
    vacío. Luego la prueba de transferencia (cómo se probó, arranque, retransferencia,
    enfriamiento, aprobada o no).
  - **Solar:** strings con `veredictoString` proponiendo Pasa / Revisar / No pasa,
    parámetros AC del tablero y el bloque de banco y tierra (el banco solo con BESS).
  - **Avisos mientras el técnico sigue en el sitio** (`avisosMediciones`, no bloquean):
    frecuencia fuera de 60 ± 0.5, resistencia de tierra por encima de 10 Ω diciendo cuánto
    dio, strings que no pasan, y **wet stacking** — un diésel probado a menos del 30 % de
    carga acumula hollín, así que se avisa con el porcentaje capturado.
  - `loQueFalta` ahora también reclama las mediciones (un generador sin ninguna lectura, un
    solar sin strings). Sigue siendo aviso, no candado: lo único que impide cerrar es la
    seguridad.
  - 81 casos en Node; probado en el emulador con diésel trifásico y con solar.
- **Placas y evidencia por punto (25/09/2026): construidas.** SQL `25_placas_equipo.sql`
  (`guardar_placa`) y su prueba; `PLACAS_SOLAR`/`PLACAS_GENERADOR`/`placaGuardada` en
  `revision.js`; en `trabajos.js` `guardarFotoRevision`, `olvidarFotoRevision` y
  `subirFotosDeRevision`.
  - **La foto cuelga de SU punto.** En el papel todas caían en un montón y el formato solo
    apuntaba cuántas eran; aquí la del hot spot queda en el punto del hot spot. Por eso
    "No. de fotos" y "Carpeta" ya no se capturan: se cuentan solos. El botón aparece al
    marcar Regular o Malo, y en "Malo" se lee el recordatorio de que ese punto se documenta
    con fotografía (aviso en la pantalla, **no** candado en la base).
  - **Las placas cuelgan del EQUIPO**, no de la orden: identidad, no estado. Se toman una
    vez y en visitas siguientes la pantalla muestra lo que ya hay. Van a
    `placas/<equipo_id>/<rol>.jpg` y `guardar_placa` las escribe en
    `equipos.atributos.componentes` conservando lo que ese componente ya tuviera. Roles:
    solar `modulos`/`inversor_1`/`inversor_2`/`bateria`/`bms`; generador
    `generador`/`motor`/`alternador`/`tablero`. Exige que la orden ya tenga equipo.
  - **`destino` en IndexedDB** (`parte` | `revision` | `placa`): las tres clases de foto
    viven en la misma orden pero suben por caminos distintos. Sin eso, tirar la parte
    pendiente se llevaba por delante las fotos de la revisión, y `subirParte` habría
    subido una placa a la lista de la parte. `borrarFotosDeOrden` ahora acepta qué
    destinos tirar; al cerrar sí se tira todo, porque la revisión sube antes que el cierre.
  - Cada placa se marca `guardada` tras llamar a `guardar_placa`, para no repetir la
    llamada en cada sincronización.
  - Probado de punta a punta en el emulador: foto → IndexedDB → Storage
    (`placas/e1/motor.jpg`) → `guardar_placa` con los argumentos correctos → marcada.
    **Ojo al medir:** el panel del navegador aplica `pointer: coarse` **solo** con el
    preajuste `mobile`; en escritorio los botones miden 40 px a propósito y parecen
    fallos. Medido en celular: 0 textos < 17 px, 0 contrastes < 4.5, 0 objetivos < 48 px,
    0 px de desborde.

**Formato del generador (25/09/2026)** — de `PowerMx · Formato de Revisión y Servicio a
Generadores` (PMX-SRV, 9 páginas). `FORMATO_GENERADOR` en `revision.js`, **desglosado por
combustible** como pidió Caña. Diez secciones; los puntos comunes son los mismos y lo que
cambia es la sección 3:
- **Diésel (50 puntos):** trampa de agua drenada, filtros primario y secundario, edad del
  combustible (más de 6 meses se muestrea) y purga de aire tras cambiar filtros. **No tiene
  sección de encendido**: no lleva bujías.
- **Gasolina (51):** filtro único, barniz en el carburador por combustible viejo, válvula de
  paso, y sí lleva bujías y cables.
- **Gas LP (54) y natural (53):** regulador y presión de entrada, prueba de fugas con
  solución jabonosa, válvula de corte y solenoide, mangueras flexibles vigentes y detector
  de gas. El **vaporizador es solo de LP**. Ambos llevan bujías.
- El **servicio mayor (tipo C)** agrega el megóhmetro de devanados; el tipo se elige al
  empezar (A inspección · B preventivo · C mayor), del anexo de periodicidad del formato.
- El combustible sale de `equipos.atributos.combustible`; si el equipo no lo tiene
  capturado, el técnico lo elige ahí mismo y la pantalla avisa por qué importa.
- **La sección 1 (seguridad) NO viene en el formato en papel**: se agregó porque es la que
  bloquea el cierre y porque antes de arrancar una planta de gas hay que descartar fuga.
  **Convención:** la sección "1" es siempre la bloqueante, en cualquier formato — el trigger
  de la 24 busca las claves `1.%`.
- `aplica(item, ctx)` generaliza las condiciones: `solo: 'bess'|'plomo'|'mayor'` mira una
  bandera del contexto y `solo: ['diesel', ...]` filtra por combustible. Sin combustible
  conocido se muestran solo los puntos comunes: mejor preguntar de menos que inventar.
- Probado: 61 casos en Node y en el emulador con planta de gas y de diésel (las secciones y
  los puntos cambian en vivo al cambiar el combustible; 0 textos < 17 px, 0 contrastes <
  4.5, 0 objetivos < 48 px, 0 px de desborde).

**Formato solar resumido — propuesta del 24/09/2026.**
De ~55 puntos a **32**, más las mediciones. Tres reglas que hacen el ahorro:
la caja de hallazgo **solo aparece al marcar R o M**; las secciones van plegadas con su
contador ("Módulos 6/6"); y **BESS solo existe si el equipo tiene baterías**.
Cada punto se califica con cuatro botones grandes **B · R · M · N/A** y su dato numérico
va pegado al punto, no en una tabla aparte.

- **No se recaptura** (sale de la orden, el cliente y el equipo): datos del cliente y del
  sitio, contacto, técnicos, horario, y todo el registro de equipos principales.
- **Al llegar:** clima (despejado/parcial/nublado), irradiancia (W/m²) y temperatura
  ambiente. La irradiancia no es adorno: la termografía solo vale por encima de 600 W/m².
  Temp. de módulo y humedad quedan opcionales.
- **1. Seguridad (8, sin recortar)** — AST firmado · permisos vigentes · LOTO DC y AC ·
  ausencia de tensión (V residual) · EPP · área y extintor · instrumentos calibrados
  (cert.) · clima seguro. **Bloquea:** un "NO" sin control compensatorio escrito impide
  cerrar la orden. Es la regla del propio formato; no se recorta porque es lo que protege
  legalmente a PowerMx.
- **2. Módulos y estructura (10 → 6)** — estado del módulo (limpieza + vidrio/celdas +
  marco/backsheet, soiling %) · termografía IR (ΔT, módulos afectados) · estructura y
  anclajes (torque) · conectores MC4 y cableado · tierra de marcos y rieles (continuidad Ω) ·
  entorno y cubierta (sombreados nuevos + sellos + canalizaciones).
- **3. Inversores (9 → 6)** — ventilación y gabinete · terminales DC/AC (torque) · alarmas
  del log (códigos) · firmware y comunicación (versión) · pruebas de operación
  (seccionamiento DC, anti-isla, paro y rearranque; t reconexión) · monitoreo vs. medición
  local y parámetros de red (desviación %).
- **4. BESS (11 → 7, solo con baterías)** — estado físico · bornes (torque) · BMS (SOC/SOH) ·
  balance de celdas (ΔV) · ciclado y DoD · sala: ventilación, temperatura, sensores y contra
  incendio · pruebas: protecciones DC, transferencia y carga/descarga (t conmutación, I y T
  máx). El punto de **electrolito y densidad aparece solo si la tecnología es plomo inundado**.
- **5. Tableros, protecciones y tierra (7 → 5)** — SPD DC y AC · fusibles gPV e
  interruptores · torque en barras y peines · termografía de tableros (ΔT) · tierra y
  documentación (GFDI/RCD, paro de emergencia, electrodo y pozo, etiquetado y unifilar).
- **6. Mediciones** — strings como filas que se agregan ("+ String"), no seis fijas: MPPT,
  Voc teórico, Voc medido, Isc/Imp, aislamiento +/GND y −/GND, veredicto. El veredicto se
  puede **proponer solo** (aislamiento bajo 1 MΩ = no pasa; Voc fuera de ±10% del teórico =
  revisar) y el técnico lo confirma. AC: solo las fases que existan. BESS/tierra: V banco,
  I carga, I descarga, T máx celda, R tierra (avisa si pasa de 10 Ω), producción del día, PR.
- **7. Placas de identificación** (pedido de Caña el 25/09/2026). Apartado propio para la
  foto de la placa del **inversor**, los **paneles** y la **batería** (esta solo si hay
  BESS), más el BMS si existe. **No son fotos de evidencia:** no cuentan el estado sino la
  identidad, y por eso **cuelgan del equipo, no de la orden** — se toman una vez y se
  vuelven a pedir solo si falta alguna o si el técnico dice que el componente cambió. En
  visitas siguientes la pantalla muestra las que ya hay y no las vuelve a pedir.
  Son la entrada de "Leer la placa con fotos" (abajo) y llenan la sección 2 del papel.
  **Decisión de modelo:** un sistema solar tiene cuatro placas (módulos, inversor —a veces
  dos—, banco y BMS) pero `equipos` guarda **una sola serie**. No se parte en varios
  equipos, porque rompería el 1 cita : 1 orden : 1 equipo; los componentes van en
  **`equipos.atributos.componentes`**, que es exactamente para lo que existe ese jsonb:
  `[{rol: 'inversor_1'|'modulos'|'bateria'|'bms', marca, modelo, serie, cantidad, foto}]`.
  `equipos.numero_serie` sigue siendo la del equipo principal (el inversor, en solar).
  Las fotos van al bucket `ordenes`, en `placas/<equipo_id>/<rol>.jpg`.
- **8. Evidencia fotográfica (sección 9 del papel).** La orden ya guarda fotos por técnico
  en `orden_partes.fotos` y las junta al cerrar, pero van **sueltas**: nadie sabe de qué
  punto es cada una. En el celular la foto debe **colgar del punto** que la motivó (la del
  hot spot queda en 2.2, no en un montón), que es lo que el papel no puede hacer y por eso
  se conforma con "No. de fotos ___ / Carpeta ___". Con eso, "No. de fotos" y "Carpeta" ya
  no se capturan: se cuentan solos. Lo que **sí** falta traer del papel es la casilla
  **"Reporte térmico: Sí / No"**. Un punto en **"M" exige al menos una foto** y ofrece
  marcar "requiere seguimiento" (la columna ya existe), que es como el papel pide generar
  la orden correctiva.
- **9. Cierre** — dictamen **Aprobado / Condicionado / No aprobado** en tres botones
  grandes; "No aprobado" exige escribir el motivo y avisa que el sistema se aísla.
  Observaciones, refacciones y firma ya existen en la orden. El **próximo mantenimiento**
  (fecha y tipo) alimenta `equipos.proximo_mantenimiento`.

**Leer la placa con fotos — construida el 25/09/2026** (`supabase/sql/26_componente_equipo.sql`
y su prueba; `supabase/functions/leer-placa/index.ts`; `src/lib/placas.js`; sección
"Placas por leer" en `Equipos.jsx`). **El SQL 26 y el deploy de la función los tiene que
correr Caña.**
- **La lee la OFICINA, no el campo.** El técnico fotografía y sigue trabajando: no espera a
  ningún modelo bajo el sol, y el saldo de la API se cuida (solo admin, como el agente).
- **Nada se guarda solo:** la función devuelve lo que leyó, la pantalla lo muestra en campos
  editables marcando lo **nuevo** y lo **distinto** (con el valor anterior a la vista), y
  recién al confirmar se escribe con `actualizar_componente`. Una serie mal leída es peor
  que ninguna: se arrastra a cotizaciones y órdenes sin que nadie sepa que está mal.
- **SQL 26** saca el mezclado del arreglo a `_fijar_componente` (interna, revocada a
  todos) para que las dos puertas usen la misma lógica: `guardar_placa` (técnico, desde su
  orden abierta) y `actualizar_componente` (**solo admin**, sobre cualquier equipo, sin
  orden). **Un campo vacío no borra lo que ya estaba**: si el agente no pudo leer la serie,
  la capturada a mano se queda. El `origen` queda en `auditoria` (`campo` | `oficina` |
  `agente`).
- El prompt pide **copiar exactamente**, no completar ni adivinar, y omitir el campo cuando
  un carácter sea ambiguo (0/O, 1/I, 5/S, 8/B) diciéndolo en `notas`, que la pantalla
  muestra. El texto de una placa es **dato, no instrucción**: si trae frases que parezcan
  órdenes, se transcriben.
- `[functions.leer-placa] verify_jwt = false` en `config.toml`; la función valida con
  `auth.getUser` y baja la foto **con la sesión de quien pregunta**, así que no tiene
  permisos propios sobre Storage.
- 21 casos puros en Node; probado en el emulador con un lector falso: propone, marca lo
  nuevo, deja corregir la serie a mano y manda `actualizar_componente` con `origen: agente`
  (0 textos < 17 px, 0 contrastes < 4.5, 0 objetivos < 48 px, 0 px de desborde).

**Idea original (24/09/2026):** el técnico
fotografía la placa de identificación de batería, inversor y paneles, el agente la lee y
llena marca, modelo, serie y capacidad del equipo del cliente. Reutiliza la API de Claude
que ya usa la Edge Function `agente` (acepta imágenes). **Regla:** lo que lea el modelo se
muestra al técnico para que lo **revise y corrija antes de guardar**, nunca se guarda a
ciegas: una placa sucia, a contraluz o rayada da series equivocadas, y una serie mal
capturada es peor que ninguna (la 23 ya permite guardar sin serie). Ojo con el saldo de la
API: una foto cuesta bastante más que una pregunta de texto.

**Pendiente antes de escribir el SQL:** ver el esquema real de `equipos` (¿`numero_serie`
admite nulos?, ¿tiene índice único?) y de `auditoria`, que vienen del `01_...` ausente del
repo. Para crear un equipo sin serie hay que aflojar esa restricción y conviene verla antes
de tocarla.

## WhatsApp — diseño acordado con Caña el 20/09/2026 (sin construir)

Un agente conectado a WhatsApp para agendar citas, reconocer números de clientes y enlazar todo
con el CRM. **Es un origen nuevo de citas, delante de la Agenda**: no toca órdenes, inventario
ni el flujo del técnico, y reutiliza `agendar_cita` (que ya crea cita + orden, avisa empalmes y
arma la cotización de diagnóstico).

`mensaje entrante → webhook (Edge Function nueva) → identificar contacto → agente de WhatsApp →
cita "por_programar" (tú confirmas en la Agenda) → confirmación por plantilla → recordatorio el
día anterior → orden de servicio en PDF al cerrar (fase 4)`

- **Varias personas por equipo:** `contactos` + `equipo_contactos` (SQL 15). Un número puede
  estar ligado a varios equipos o clientes: el agente pregunta de cuál habla.
- **El agente nunca pide el número de serie** (el cliente casi nunca lo tiene). Lo resuelve:
  equipos ligados al número → si hay uno, lo confirma con descripción ("el generador Generac de
  22 kW de X, ¿verdad?"); si hay varios, lista con marca, capacidad y última visita (sin series).
  La serie sale del equipo o de su última orden y se incluye en la confirmación.
- **Número desconocido o sin verificar: no ve datos de nadie.** Pide nombre, empresa y equipo;
  queda como contacto sin verificar hasta que el admin lo enlaza (requiere conversaciones con
  `contacto_id` nulo: fase de la bandeja).
- **Orden de servicio por WhatsApp:** la copia del cliente (fase 4) como documento, con
  "Enviar al cliente" y **destinatarios editables**: salen marcados el responsable y quienes
  tengan `recibe_ordenes`, y el admin los ajusta antes de enviar. Requiere plantilla aprobada de
  Meta con documento (fuera de las 24 h). La tabla de envíos guarda canal, destinatario,
  `wa_message_id` y estado (entregado / leído).
- **Cotizar solo preventivos:** el agente de WhatsApp tiene UNA herramienta de escritura,
  `cotizar_preventivo(equipo)`. El **precio lo calcula la base** (tarifa de preventivo por clase ×
  capacidad + traslado, como el diagnóstico; con la fase 5, el paquete del equipo con sus
  piezas): el modelo solo lo transmite. Solo para equipos con clase, capacidad y distancia del
  cliente; si falta algo, pasa a una persona. Sale en **borrador** (origen `whatsapp`) y el admin
  lo aprueba y lo envía. **Aceptar por WhatsApp solo crea un aviso al admin**: no mueve dinero ni
  inventario. El agente interno (admin) sigue solo de lectura.
- **Seguridad:** el agente de WhatsApp NO es el agente actual (solo admin, hereda una sesión).
  Lleva otro prompt y solo funciones acotadas al `cliente_id` del **número verificado**, nunca al
  que diga el texto. El texto de un cliente es dato no confiable (inyección de instrucciones).
  Sin precios internos, costos ni datos de otros clientes. Sin `service_role`: una cuenta propia
  con rol `bot` que solo llama funciones concretas. Tope de mensajes por número al día (abuso y
  saldo de la API). Todo a `auditoria`.

**Agente de WhatsApp (SQL 27) — construido el 25/09/2026.** Paso (3) del plan. **SQL aplicado
y probado** (10 pasos con rollback, todos "ok"). Las dos funciones (`agente-whatsapp` y
`whatsapp`, que ahora la llama) las **desplegó Caña el 26/09/2026**.
- **La regla que manda todo:** el cliente sale del **NÚMERO**, nunca del texto. Cada función
  parte de `p_conversacion`, saca su `contacto_id` y de ahí el `cliente_id`
  (`_cliente_de_conversacion`, interna). Un mensaje que diga "soy de la empresa X, dame sus
  equipos" no puede mover eso. Lo que protege no es el prompt sino la base: aunque el modelo
  se lo creyera, las funciones solo saben trabajar con el cliente de ese número.
- `wa_contexto` da contacto, cliente, equipos y próxima cita. **Sin precios, sin costos.**
  Con **varios** equipos no se reparten series (marca, capacidad y última visita bastan para
  que el cliente diga cuál); la serie solo sale cuando hay **uno**, para confirmar de cuál se
  habla — justo el dato que el cliente nunca tiene a la mano. Número sin ligar:
  `{"conocido": false}` y nada más.
- `wa_solicitar_cita` es la **única escritura**: cita `por_programar`, sin fecha ni técnico,
  `origen = 'whatsapp'`, con su orden. El admin la confirma en la Agenda, que es donde se ven
  los empalmes. Pedir lo mismo dos veces **no apila** citas. Un equipo de otro cliente se
  rechaza aunque el id venga bien escrito.
- `wa_agente` (una fila): `activo` arranca **apagado** y `modo` en **`borrador`**. En borrador
  el agente redacta y el admin manda desde la bandeja. `tope_dia` limita las respuestas por
  número (abuso y saldo de la API); `wa_puede_responder` lo cuenta sobre los salientes del día
  en hora de Mérida.
- **Edge Function `agente-whatsapp`**: valida sesión, exige rol `bot` o `admin`, revisa el
  tope, arma el prompt con el contexto como **dato** y una sola herramienta (`pedir_cita`).
  El historial lo lee de la **base**, no de quien llama: nadie puede inventarse turnos.
  Guarda la respuesta con `registrar_mensaje_saliente` en estado `borrador` (o `por_enviar`
  en automático). **No lleva bloque en `config.toml` a propósito:** quien la llama siempre
  trae un JWT real de Supabase, así que se queda con `verify_jwt` encendido, que es más
  estricto — al revés que `agente`, `whatsapp` y `leer-placa`.
- El **webhook la despierta con `EdgeRuntime.waitUntil`** y contesta 200 de inmediato:
  pensar tarda segundos y Meta reintenta el aviso si no se le responde rápido.
- **Pantalla:** panel "Agente" plegable en WhatsApp (encendido, modo, tope, indicaciones
  extra; aviso al pasar a automático) y los borradores se ven como **"Borrador del agente ·
  sin enviar"** con "Mandar este borrador", que abre `wa.me` y lo marca enviado. Se marcan
  fuerte porque en la burbuja se ven igual que lo ya enviado.
- **Defecto de diseño encontrado al medir:** `.ayuda` dentro de `.burbuja-mia` daba **2.42**
  de contraste (gris pensado para fondo claro sobre azul noche). Arreglado en `index.css`.
- **El cotizador de preventivos: aplicado y probado el 27/09/2026**
  (`supabase/sql/37_wa_cotizar_preventivo.sql` y `37_prueba_wa_cotizar_preventivo.sql`,
  **13 de 13 "ok"** llamando como `bot`; `wa_cotizar_preventivo` es la **segunda y última**
  herramienta de escritura del agente). Se pudo hacer ahora porque el precio fijo ya vive en
  SQL desde la 28 y la 29 lo partió en piezas sin precio; cuando se diseñó, la fórmula solo
  existía en el navegador.
  Lo comprobado en la base: servicio 4,500 + traslado 900 = subtotal 5,400, IVA 864, total
  6,264; 3 partidas; estado `borrador` y `origen = 'whatsapp'`; la refacción en 0, `incluida`
  y **con `producto_id`**; **0 movimientos de `apartado`** (un borrador no mueve inventario);
  pedir dos veces devuelve el mismo folio; el equipo de otro cliente se rechaza; sin tarifa de
  mayor explica el motivo y no inventa precio; un número sin ligar no cotiza nada.
  **Y el traslado dio 900.00, el mismo número que `tarifas.js`** — era la comprobación de que
  las dos implementaciones de la regla coinciden.
  Ojo: la prueba consume folios de cotización, porque la secuencia no se revierte con el
  `rollback` (lo mismo que pasa con las pruebas de la 1b y la 1c).
  - **El agente NO dice el precio** (decisión de Caña, 27/09/2026): solo avisa que la
    cotización se está preparando. La función a propósito **no devuelve el total**, así que el
    modelo no lo sabe y no hay forma de que lo suelte. El admin la revisa y la manda.
  - Sale en **borrador** con `cotizaciones.origen = 'whatsapp'` (columna nueva), y en la lista
    de Cotizaciones aparece con la palabra **"Por revisar · WhatsApp"**. Un borrador **no
    mueve inventario**: apartar sigue siendo cosa de aceptar, y aceptar es del admin.
  - Lleva servicio + refacciones del paquete **a 0 y marcadas `incluida`** (pero con
    `producto_id`, que es lo único que mira el almacén, así que apartarán igual al aceptar) +
    **traslado desde los 40 km**.
  - **Si falta un dato no inventa un precio:** devuelve `{"ok": false, "falta": "…"}` y el
    agente pasa la conversación a una persona. Falta = sin combustible, sin capacidad, sin
    tarifa para esa clase y tramo, sin paquete, sin `distancia_km`, o con una línea del
    paquete sin ningún código disponible.
  - Pedir lo mismo dos veces **no apila** borradores: devuelve el folio que ya estaba. Se
    reconoce por la marca `servicio: 'preventivo_menor'|'preventivo_mayor'` de la partida y no
    por el sku, que en `tarifas_servicio` puede ser nulo.
  - **Fallo latente que este cambio destapó:** el bucle de herramientas de la Edge Function
    llamaba a `wa_solicitar_cita` para **cualquier** `tool_use`, sin mirar el nombre. Con una
    sola herramienta no se notaba; con dos, cotizar habría agendado. Ahora despacha por
    `uso.name` y una herramienta desconocida no se ejecuta.
- **El traslado del preventivo (27/09/2026).** Caña decidió que se cobre igual que en el
  diagnóstico: desde los 40 km, todos los km y solo ida. Se agregó **también a la pantalla de
  admin** (`partidasDePreventivo` recibe `{tarifas, cliente}`), porque si solo lo cobrara un
  canal el mismo servicio costaría distinto según por dónde entró la solicitud.
  La regla quedó en **un solo lugar en JS** (`partidaDeTraslado` de `tarifas.js`, que ahora
  usan el diagnóstico y el preventivo) y **otra en SQL** (`_precio_traslado`), que es
  inevitable: el bot no puede leer `tarifas_servicio` desde el navegador. **Las dos tienen que
  dar el mismo número** y eso se comprueba a los dos lados con el mismo caso: 60 km × 15 = 900.
  **Trampa que apareció al hacerlo:** marcar la partida del servicio con `servicio` hizo que el
  botón "Cargar diagnóstico" la borrara (su filtro quitaba todo lo que tuviera `servicio`),
  dejando las refacciones a $0 sin el servicio — una cotización en casi cero. Ahora el filtro
  nombra solo `diagnostico` y `traslado`.
- **Falta:** ver al agente contestar de verdad, que solo se puede con el número de Meta.

- **Orden de construcción:** (1) `contactos` y su pantalla — no depende de WhatsApp; (2) bandeja
  de conversaciones e identificación de números; (3) el agente propone citas `por_programar` y
  cotiza preventivos en borrador; (4) mensajes salientes por plantilla (confirmación, recordatorio,
  orden, cotización).
- **Lo lento no es el código:** la verificación del negocio en Meta, la aprobación de plantillas y
  un número dedicado que no esté activo en la app normal de WhatsApp tardan días o semanas.
  Conviene iniciar ese trámite antes que el código.
- **01/10/2026: la verificación del negocio en Meta ya está en revisión.** Mientras se resuelve,
  se redactaron y se están dando de alta **5 plantillas** (categoría Utilidad, español MX) en el
  Administrador de WhatsApp: `cita_confirmada`, `cita_reprogramada`, `cita_cancelada`,
  `recordatorio_cita` y `orden_servicio_lista` (esta con encabezado de documento, para el PDF de
  cierre). Meta usa **variables con nombre** (`{{nombre}}`, no `{{1}}`) — minúsculas y guión bajo,
  dos llaves; una variable vacía (`{{}}`) o en otro formato se rechaza. Son textos **fijos**
  a propósito, más simples que lo que arma `texto_aviso()` hoy (sin las líneas que aparecen o no
  según el caso): una plantilla no puede tener contenido condicional, así que cuando se mande por
  la API va a hacer falta una versión de cada mensaje recortada a lo fijo, aparte del texto libre
  que sigue usando el envío manual por `wa.me`.
  Redactarlas destapó que faltaba el tipo `recordatorio` en el código — ver el SQL 54 arriba.

**Bandeja de WhatsApp (SQL 22) — aplicada y probada el 22/09/2026** (10 pasos con rollback,
todos "ok"; la pantalla solo se vio en el emulador)
(`supabase/sql/22_whatsapp_bandeja.sql` y `22_prueba_whatsapp_bandeja.sql`; `src/WhatsApp.jsx`,
`src/lib/whatsapp.js`; pantalla nueva "WhatsApp", solo admin). Es el paso (2) del orden de
construcción: el registro de conversaciones y la identificación de números. **Todavía no hay
webhook**: hasta que Caña dé de alta el número en Meta, la bandeja está vacía y la pantalla
misma explica los cuatro pasos del trámite.
- `conversaciones`: una fila por número (`telefono_norm` generada, últimos 10 dígitos como en
  `contactos`), con `contacto_id`, `ventana_hasta`, `sin_leer` y `estado`. `mensajes_wa` guarda
  cada mensaje con `wa_message_id` **único**: el webhook de Meta reintenta, y sin ese índice el
  mismo mensaje entraría dos veces.
- El trigger `_ligar_conversacion_sola` liga el número a su contacto **solo si hay exactamente
  uno activo** con ese teléfono. Con varios (un número en dos clientes) queda sin ligar a
  propósito: el admin decide, y mientras tanto el agente no puede dar datos de nadie.
- **Lección (la encontró la prueba, pasos 1 y 9):** una columna `generated always as (...)
  stored` se calcula **después** de los triggers `before insert`, así que dentro del trigger
  llega en **null**. El trigger leía `new.telefono_norm` y nunca ligaba a nadie; ahora
  normaliza a mano con `normalizar_telefono(new.telefono)`. Vale para cualquier trigger
  `before` que quiera usar una columna generada.
- Funciones: `registrar_mensaje_entrante` (la usará el webhook; crea la conversación, corre la
  ventana 24 h y sube `sin_leer`), `registrar_mensaje_saliente`, `vincular_conversacion`,
  `marcar_conversacion_leida`, `cerrar_conversacion` y `bandeja_whatsapp` (lista con cliente,
  equipos y último texto). RLS: solo admin lee las tablas; el bot escribirá por funciones
  (`_es_bot_o_admin`).
- **Ventana de 24 horas:** WhatsApp solo deja texto libre durante 24 h desde el último mensaje
  del cliente; fuera de eso hace falta plantilla aprobada. La pantalla lo dice con palabras
  ("Puedes responder" / "Ventana cerrada") antes de que el envío falle.
- El envío sigue siendo **a mano**: "Guardar y abrir WhatsApp" deja la respuesta registrada en la
  conversación y abre `wa.me` con el texto listo, igual que los avisos de cita.
- Probado en emulador con un Supabase falso (0 textos < 17 px, 0 contrastes < 4.5, 0 objetivos <
  48 px, 0 px de desborde, en la lista, el hilo y el estado vacío; 21 casos puros en Node).
  **Falta:** ver la pantalla contra la base real.

**Webhook de WhatsApp — Edge Function `whatsapp`** (`supabase/functions/whatsapp/index.ts`,
**desplegada y probada de punta a punta el 22/09/2026**: Caña mandó un WhatsApp al número de
prueba desde su celular autorizado y apareció en la bandeja del CRM). Meta la llama cada vez
que alguien le escribe al número; ella solo guarda el mensaje con `registrar_mensaje_entrante`.
No contesta ni agenda nada: eso sigue siendo a mano desde la pantalla WhatsApp.
- **Nada de `service_role`:** entra con una cuenta propia de rol **`bot`** que solo puede llamar
  esas funciones. El rol `bot` **no sale en el menú** de la pantalla Usuarios (no es una persona
  y nadie debe asignarlo por error): se pone a mano con
  `update perfiles set rol = 'bot' where email = '…'`. La pantalla sí lo **muestra** —
  "Conector de WhatsApp", sin menú— porque un `<select>` sin esa opción se vería vacío y un
  guardado accidental le cambiaría el rol. Es la lista `ROLES_SISTEMA` de `Tecnicos.jsx`.
  No ponerle teléfono ni zona, y no desactivarla: apagada, el webhook no puede entrar y los
  mensajes que lleguen se pierden. Inicia sesión
  con `BOT_EMAIL`/`BOT_PASSWORD` y **guarda la sesión** mientras el contenedor vive; si algo
  falla, la tira para que el siguiente aviso vuelva a entrar.
- **Lo que autentica es la firma, no un token de Supabase:** `X-Hub-Signature-256` es un
  HMAC-SHA256 del cuerpo **crudo** con `WHATSAPP_APP_SECRET`. Por eso el cuerpo se lee con
  `req.text()` y nunca se vuelve a serializar: cambiaría la firma. "Verify JWT" va apagado
  (`[functions.whatsapp]` en `config.toml`).
- **Siempre responde 200**, incluso si algo truena por dentro: si Meta ve un error reintenta
  el mismo aviso durante horas. Lo que se pierde queda en el registro de la función. La
  repetición no duplica nada porque `wa_message_id` es único.
- `GET` sirve solo para el alta del webhook (`hub.challenge` contra `WHATSAPP_VERIFY_TOKEN`).
- Los acuses de entrega (`statuses`) todavía no se guardan: harán falta cuando el CRM mande
  por la API, no mientras se responda a mano.
- Secretos en Supabase → Edge Functions: `WHATSAPP_VERIFY_TOKEN` (lo inventa Caña y lo repite
  en Meta), `WHATSAPP_APP_SECRET` (Meta → Configuración → Básica), `BOT_EMAIL`, `BOT_PASSWORD`.
  `SUPABASE_URL` y `SUPABASE_ANON_KEY` las pone Supabase sola. Cambiar un secreto **no** exige
  volver a desplegar.
- **Alta en Meta** (22/09/2026): URL `https://<proyecto>.supabase.co/functions/v1/whatsapp`,
  el mismo token de verificación que el secreto, y suscribirse al campo **`messages`** —
  sin esa suscripción el webhook queda dado de alta pero Meta no le manda nada. El aviso de
  "verificar cuenta" que sale al suscribirse **no bloquea** el número de prueba entre celulares
  autorizados; la verificación del negocio hace falta para escribirle a clientes reales con un
  número propio y para plantillas fuera de las 24 h.
- Para probar el apretón de manos sin tocar Meta (en PowerShell va `curl.exe`, no `curl`):
  `curl.exe "…/functions/v1/whatsapp?hub.mode=subscribe&hub.verify_token=<el valor>&hub.challenge=12345"`
  debe devolver `12345` con 200. Un 403 con `no` es token equivocado o secreto sin guardar;
  un 401 sería "Verify JWT" encendido.
- El **token de Meta no interviene aquí**: recibir no lo usa. Que el token temporal de 24 h
  venza no apaga la bandeja; hará falta uno permanente cuando el CRM **mande** por la API.

## Envío por la API de WhatsApp — fase 3 (04/10/2026) — código escrito, sin desplegar

PowerMx quedó **verificado en Meta el 04/10/2026**. Lo que faltaba para que la cola de la 56 salga sola:
- **SQL 58** (`58_envio_whatsapp.sql` + prueba de solo lectura): política `ordenes_bot_lee_enviados` — el bot
  lee **solo** `ordenes/enviados/` (las copias que el admin ya decidió mandar), nada de fotos, firmas,
  expedientes ni placas; comprobado en PGlite (de tres objetos ve solo el de `enviados/`). Al final,
  comentados, los pasos de pg_cron + pg_net cada minuto con el secreto en el **Vault**
  (`enviar_whatsapp_cron`) y el mismo valor como `CRON_SECRET` en la función.
- **Edge Function `enviar-whatsapp`** (`[functions.enviar-whatsapp] verify_jwt = false`): entra como `bot`,
  `tomar_salida(20)`, manda a `graph.facebook.com/<versión>/<PHONE_ID>/messages`, `marcar_salida`. El PDF va
  como encabezado de documento con un **enlace firmado de 1 h** (Meta lo descarga), sin subir medios.
  La llama el reloj (`x-cron-secret`) o un admin con su sesión. Secretos nuevos: `WHATSAPP_TOKEN`
  (permanente, usuario del sistema), `WHATSAPP_PHONE_ID`, `CRON_SECRET`; opcional `WHATSAPP_API_VERSION`.
- **Reglas puras en `supabase/functions/_shared/whatsapp.js`** (JS plano: lo importan las dos funciones Deno
  y `pruebas/enviarWhatsapp.prueba.js`, 12 casos): `cuerpoMensaje` (variables **con nombre** →
  `parameter_name`), `leerRespuesta` (temporal: 429, 5xx, 130429, 131016…; permanente: 131047, 131026,
  132000, 132001, 190… con su explicación en palabras), `esBaja`, `errorDeAcuse`.
- **Webhook `whatsapp`**: guarda los acuses (`statuses` → `registrar_estado_wa`) y registra **BAJA** (texto
  "BAJA"/"STOP" o el botón de baja de Meta → `registrar_baja`); a quien pide baja no se le despierta al agente.
- Sin Deno en la PC: la sintaxis de las funciones se revisa con `node --check archivo.ts` (Node 24 quita los
  tipos); los tipos solo los ve el deploy.
- **Puesta en marcha (07/10/2026):** número real +52 999 648 5577 conectado (nombre "PowerMx" en revisión);
  usuario del sistema con la app `crm-powermx` y la cuenta de WhatsApp asignadas (sin activos asignados con
  "Administrar app" encendido, "Generar token" dice "No hay permisos disponibles"); secretos puestos; SQL 58
  y su prueba 5 de 5; las dos funciones desplegadas; pg_cron y pg_net activados; reloj `enviar-whatsapp`
  cada minuto y `recordatorios-de-cita` a las 14:00 UTC. El reloj respondió `200 {"apagado":true}`.
- **La contraseña de la cuenta `bot` estaba desfasada** de `BOT_PASSWORD` (`Invalid login credentials`): el
  webhook, `solicitud-web` y `convertir.js` entran con la misma cuenta, así que también estaban fallando. Se
  puso una nueva el 07/10/2026 con `update auth.users set encrypted_password = extensions.crypt(...)`.
  **Diagnóstico sin revelar secretos:** comparar `encode(sha256(convert_to(valor,'UTF8')),'hex')` con la columna
  DIGEST de Edge Functions → Secrets, y `encrypted_password = extensions.crypt(valor, encrypted_password)` para
  saber si la base acepta la clave. Hacer el cambio y la comprobación **en una sola consulta** (CTE +
  `returning`) para que la clave se escriba una vez: pegarla dos veces fue lo que dio "false" la primera vez.
  En un `update`, el editor de Supabase dice "No rows returned" aunque sí haya cambiado una fila.
- **El webhook no recibía nada del número real** (0 invocaciones): la cuenta de WhatsApp de PowerMx
  (WABA `1796756035003895`) **no estaba suscrita a la app**; el número de prueba vivía en otra cuenta que sí.
  Se arregló el 07/10/2026 con `POST https://graph.facebook.com/v23.0/<WABA_ID>/subscribed_apps` con el token
  del usuario del sistema → `{"success":true}`. Con `GET` al mismo endpoint se revisa (`{"data":[]}` = sin suscribir).
  Toda cuenta de WhatsApp nueva (p. ej. la de Dutton) necesita este paso; dar de alta el webhook en la app no basta.
- **Identificadores (no son secretos):** app `crm-powermx` 937584876092739 · cuenta de WhatsApp (WABA)
  1796756035003895, la del número real y la que tiene método de pago · número +52 999 648 5577 → **PHONE_ID
  1418656331321052** (`WHATSAPP_PHONE_ID`). Hay otra WABA "PowerMx" (1581244847351078) sin número real ni pago:
  no se usa. Para comprobar el token y el PHONE_ID: `GET /v23.0/<WABA_ID>/phone_numbers?fields=id,display_phone_number,status`.
  La app estaba **"Sin publicar"** (modo Desarrollo); se publicó el 07/10/2026 (Publicar → Publicar).
- **El webhook del 22/09 vivía en OTRA app** (la del número de prueba): `crm-powermx` no tenía URL de devolución
  de llamada. El 07/10/2026 se configuró en crm-powermx (WhatsApp → Configuración: URL de la función `whatsapp`,
  token de verificación nuevo, campo **messages** suscrito) y se reemplazaron `WHATSAPP_VERIFY_TOKEN` y
  `WHATSAPP_APP_SECRET` por los de crm-powermx (la firma se calcula con la clave secreta de la app que manda el
  aviso). **Mensajes del número real llegando a la bandeja desde el 07/10/2026, y la primera respuesta
  enviada por la API (cola → reloj → `enviar-whatsapp` → Meta) llegó al celular de Caña el mismo día.** Checklist para una cuenta nueva:
  (1) webhook en la app correcta + `messages`, (2) `subscribed_apps` de la WABA, (3) app publicada, (4) los
  secretos de ESA app.

## Campañas mensuales de WhatsApp (SQL 57, 03/10/2026) — aplicado y probado en Supabase el 03/10/2026 (9 de 9 "ok")

Sobre la cola de la 56. Solo clientes de PowerMx (los "PowerMx (confirmó)" de la hoja Asignación del
reporte; las campañas de Dutton van en su proyecto). Flujo: cargar el CSV del mes en `campana_envios`
(`campana_powermx_<AAAA-MM>.csv`, lo arma `campanas_csv.py` fuera del repo desde plan_servicio_mensual.xlsx)
→ `proponer_tanda(mes, 37)` → Caña revisa y quita (`quitar_de_tanda`) → `aprobar_tanda` mete cada envío a
`salida_wa` como marketing → `resultados_campana(mes)` calcula respondió / cita / BAJA (antes se llenaba a mano).
- Omite con motivo escrito: BAJA, marketing en los últimos `dias_entre_marketing` días, teléfono
  inválido, sin plantilla. Las reglas se revisan al proponer Y al aprobar.
- 6 plantillas de campaña sembradas en `borrador` (seguimiento_pendiente es Utilidad; las demás Marketing;
  maintenance_reminder en en_US). Hay que darlas de alta en Meta; lo aprobado espera en la cola hasta entonces.
- Las variables se aplanan (sin saltos de línea ni espacios seguidos) y se recortan: Meta las rechaza si no.

## Cola de salida de WhatsApp (SQL 56, 02/10/2026) — aplicado y probado en Supabase el 03/10/2026 (13 de 13 "ok")

Rediseño acordado con Caña: TODO lo que se manda por la API pasa por una sola cola, `salida_wa`, que vacía
una sola Edge Function (`enviar-whatsapp`, fase 3, sin construir; necesita el número real y el token
permanente). Decisiones de Caña: avisos de cita con interruptor `wa_config.avisos_automaticos`
(arranca apagado → "por aprobar"); el agente sigue en borrador hasta que se apruebe su funcionamiento;
las tandas de campaña las aprueba él (campañas = SQL 57, pendiente); la regla de traspaso Dutton/PowerMx
sigue pendiente.
- Entran a la cola: avisos de cita (trigger sobre `avisos`, si hay plantilla para `aviso:<tipo>:<destinatario>`),
  la orden en PDF (`encolar_orden(envio)`, una fila por destinatario) y respuestas de texto
  (`responder_whatsapp`, solo con la ventana de 24 h abierta; aprueba el borrador del agente).
- `wa_plantillas`: nombre, uso, `variables` (nombres EXACTOS de Meta) y estado. Las 5 de la revisión del
  01/10 están sembradas `en_revision` con variables SUPUESTAS: al aprobarse, corregirlas y marcar `aprobada`.
  Una fila con plantilla no aprobada espera sin error.
- `tomar_salida(n)` (bot) vuelve a revisar las reglas al salir (ventana, baja, plantilla, variables no
  vacías) y calcula las variables de los avisos con datos frescos (`_variables_aviso`, versión corta del
  texto). `marcar_salida` deja el mensaje en la conversación y marca el aviso `enviado` por `whatsapp_api`.
  Un aviso mandado a mano por wa.me cancela su fila de la cola: no sale dos veces.
- Lo que queda "enviando" más de 10 min pasa a `sin_confirmar` y NO se reintenta solo (Meta no tiene
  llave de idempotencia; reintentar podría duplicar). Errores temporales: hasta 3 intentos con espera.
- Acuses (`registrar_estado_wa`) solo avanzan: enviado → entregado → leído (o fallido).
- `wa_bajas` + `registrar_baja`: BAJA cancela el marketing pendiente de ese número; los avisos de su cita sí le llegan.
- Interruptor general `wa_config.envio_activo` (apagado).
- **Corrección del 03/10/2026:** `cola_whatsapp()` nació `stable` pero hace un `update` (pasa a
  `sin_confirmar` lo atorado), y Postgres lo rechaza en cuanto se llama ("UPDATE is not allowed in a
  non-volatile function"). La prueba original nunca la llamaba. Se quitó el `stable` en el mismo 56 y la
  prueba ganó el paso 13 (ahora 14 en total). Vuelto a correr en Supabase el 03/10/2026: 14 de 14 "ok".
  Lección: una función que escribe no puede ser `stable`, y toda función que la pantalla llame debe
  aparecer en la prueba.

**Pantalla (03/10/2026, construida y probada en emulador con un Supabase falso):** WhatsApp ganó
pestañas **Bandeja · Por enviar (n) · Campañas** (`src/SalidaWhatsApp.jsx`, `src/lib/salidaWa.js`, 14 casos
en `pruebas/salidaWa.prueba.js`).
- *Por enviar*: los dos interruptores (`envio_activo`, `avisos_automaticos`), "Por aprobar" con Aprobar /
  No mandar / Aprobar todos, "Con problema" (fallidos y sin confirmar: "Ya lo revisé, quitar"; no hay
  reintento desde la pantalla, a propósito), cuántos esperan a que Meta apruebe cada plantilla, y el editor
  de plantillas (variables y estado). El número de la pestaña = por aprobar + con problema.
- Las variables de una plantilla se separan **solo por comas**: la primera versión partía también por
  espacios y "nombre del cliente" se guardaba como tres variables válidas. Lo atrapó la prueba en el
  emulador, no la de Node.
- *Campañas*: mes (oct-2026 a sep-2027), resumen con % de respuesta, proponer tanda, Quitar / No
  escribirle, Aprobar / Cancelar tanda, y quién ya recibió o se omitió con su resultado en palabra.
- En la conversación, con `envio_activo` encendido: "Enviar" y "Aprobar y enviar" (el borrador del agente)
  van por `responder_whatsapp`; apagado, sigue el flujo de wa.me.
- Medido en celular (375 px, `pointer: coarse`): 0 textos < 17 px, 0 contrastes < 4.5, 0 px de desborde;
  los únicos objetivos < 48 px son las dos casillas (26 px) dentro de su etiqueta de 56 px.
- **Supabase falso para el emulador:** `VITE_SUPABASE_URL=http://prueba.localhost:5199` (así la llave de
  sesión es `sb-prueba-auth-token`) en un `.env.prueba.local` + `vite --mode prueba`, y un servidor Node
  que conteste PostgREST. Ojo: `maybeSingle()` de esta versión de supabase-js pide una **lista** y escoge
  el renglón; si el falso responde un objeto, la app cree que no hay perfil ("tu cuenta no tiene permisos").

## Clientes del historial de WhatsApp (SQL 55, 02/10/2026) — escrito y probado en PGlite (8 de 8), falta correrlo en Supabase

Del reporte del historial de WhatsApp Business de Dutton Hermanos (fuera del repo, en el escritorio de
Caña), solo entran al CRM los clientes que Caña marque "PowerMx (confirmó)" en la hoja Asignación.
- `importacion_whatsapp` es una **tabla de paso** (solo admin): el CSV `agente_powermx_contexto.csv` se
  sube ahí. **Nada entra a `contactos` sin que el admin lo acepte** con `aceptar_importacion_whatsapp(id,
  cliente?)`, porque el trigger de la 22 liga una conversación a cualquier contacto ACTIVO y desde ese
  momento el agente ve los datos del cliente. Aceptar crea el cliente (o usa uno existente), el contacto
  verificado y liga la conversación si ese número ya escribió. `descartar_importacion_whatsapp` exige motivo.
- `wa_contexto` se redefine (misma lógica de la 27, con asignación en lugar de `select ... into`) y gana
  `historial` (equipo, último servicio, pendiente) y `razon_social` (la de `datos_fiscales` manda).
- El agente de **Dutton** vive en otro proyecto de Supabase, fuera de este repo
  (`C:\Users\USER\Documents\dutton-whatsapp`). No se comparte nada entre los dos.
- PGlite para probar SQL (arnés de usar y tirar en el scratchpad de la sesión: `@electric-sql/pglite`
  0.2 + stubs de `auth.jwt()`/`auth.uid()` y los roles `anon`/`authenticated`): carga
  la foto del esquema por sentencias y en varias pasadas (las funciones de la foto aparecen antes que los
  tipos que usan) con `check_function_bodies = off`. Supabase concede privilegios a `authenticated` por
  defecto en cada tabla nueva y PGlite no: por eso la 55 lleva su `grant` explícito.

## Solicitudes del sitio (SQL 36, 27/09/2026) — SQL aplicado y probado; falta desplegar la función y publicar

**SQL 36 aplicado y probado el 27/09/2026** (`36_prueba_solicitudes_web.sql`, 11 pasos con rollback,
todos "ok": entra y sugiere cliente, el reintento no duplica, otro contenido crea otra, el bot y el
técnico ven 0, el admin ve las 3, resolver y reabrir dejan y borran autor y fecha, `anon` no toca
nada). Falta: `npx supabase functions deploy solicitud-web`, publicar CRM y sitio, y probar con una
solicitud real.

El formulario de `cotizar.html` (sitio) mandaba todo a un webhook de n8n (`webhook-test`, que
solo recibe con el editor abierto: se perdían leads) y a WhatsApp. Por decisión de Caña, **las
solicitudes llegan solo al CRM**; n8n ya no interviene. Primer puente real entre el sitio y el CRM.

`formulario → Edge Function solicitud-web → registrar_solicitud_web (SQL) → tabla solicitudes_web
→ pantalla "Solicitudes" (admin)`

- **Una solicitud NO crea cliente, cotización ni cita.** Un número equivocado o un bot llenaría la
  base de basura (misma decisión que en WhatsApp). El admin la ve, contesta por WhatsApp y decide.
  Lo único que la base hace sola es **sugerir** un cliente cuando el teléfono es de exactamente una
  persona activa de `contactos`.
- **Sin `service_role` y sin permisos a `anon`:** la función entra con la cuenta `bot` (la misma
  del webhook de WhatsApp) y solo puede llamar a `registrar_solicitud_web`. El bot **no lee** la
  tabla; solo el admin (RLS). Los mismos secretos `BOT_EMAIL`/`BOT_PASSWORD`.
- **La protección real es la base, no la función:** `registrar_solicitud_web` valida (nombre,
  10 dígitos, correo), recorta cada campo, pone topes (**60 por hora** en todo el sitio, **5 por día
  por número**; error `54000` → la función responde 429) y no duplica un reintento (mismo número y
  mismo contenido en 10 minutos devuelve la misma). Datos inválidos son `22023` → 400 con el mensaje
  para el cliente. Encima, en la función: campo trampa `sitio_web`, tiempo mínimo de llenado
  (2.5 s) —los dos contestan 200 sin guardar nada—, cuerpo máximo de 10 KB y CORS solo para
  `https://powermx.com.mx` y `www` (secreto opcional `SOLICITUD_ORIGENES`). **CORS no es seguridad**:
  un script lo ignora; por eso los topes viven en la base.
- **`[functions.solicitud-web] verify_jwt = false`** en `config.toml`: el sitio no tiene sesión.
- `resolver_solicitud_web(id, estado, nota, cliente)` (solo admin): `nueva` | `atendida` |
  `descartada`, con quién y cuándo; reabrir borra autor y fecha y conserva la nota.
- **Pantalla `Solicitudes`** (`src/Solicitudes.jsx`, `src/lib/solicitudesWeb.js`, solo admin): por
  omisión solo las nuevas; cada tarjeta muestra lo que marcó, avisa "Ya es cliente" si se sugirió
  uno, "Responder por WhatsApp" (`wa.me` con un saludo ya escrito), nota interna y atender /
  descartar / reabrir. 7 casos en Node. Sin ver aún en el emulador ni contra la base real.
- **El sitio** (`cotizar.html`): si la solicitud se registra, se abre WhatsApp como respaldo y se
  muestra el éxito; si el dato es inválido (400) se corrige sin abrir WhatsApp; si falla otra cosa
  (429, 500, sin red) **ya no dice "Recibimos tu cotización"**: avisa y abre WhatsApp con el
  resumen, que es la única vía que queda. Se quitó la promesa de "te enviamos un resumen por
  WhatsApp", que hacía n8n.
- **Para ponerlo en marcha, en este orden:** (1) correr `36_solicitudes_web.sql` y luego
  `36_prueba_solicitudes_web.sql` (11 pasos, todos "ok"); (2) `npx supabase functions deploy
  solicitud-web` (los secretos del bot ya existen); (3) publicar el CRM (pantalla nueva) y el sitio
  (`cotizar.html`); (4) mandar una solicitud de verdad desde powermx.com.mx y verla en el CRM.
  Antes de publicar el sitio, confirmar que ese sea el dominio real: si no, poner el correcto en
  `SOLICITUD_ORIGENES` o el navegador bloqueará el formulario.
- **Los rechazos** (nombre vacío, teléfono corto, correo malo, tope) lanzan excepción y no se
  pueden probar en el editor sin plpgsql: están descritos como pruebas manuales en el encabezado de
  `36_prueba_solicitudes_web.sql`.
- **Falta:** un contador de "nuevas" en el menú; crear el cliente desde la solicitud con los datos
  precargados (hoy manda a Clientes a darlo de alta a mano); y un límite de peticiones por IP en
  Cloudflare/Supabase si algún día hay abuso (hoy solo hay topes globales y por número).
- **`calculadora-consumo.html` tenía el MISMO problema, en su propio formulario** — se encontró el
  28/09/2026 al revisar "que la calculadora y el carrito sigan funcionando bien" tras publicar el
  cambio de arriba. Dos fallas juntas, las dos de antes de esta sesión:
  1. Mandaba su lead al mismo webhook de **prueba** de n8n (`webhook-test/...`) que ya se había
     corregido en `cotizar.html` — sus solicitudes también se perdían. Se conectó al mismo
     `solicitud-web`, con el mismo campo trampa y el mismo manejo de error (400 corrige sin abrir
     WhatsApp; cualquier otra falla abre WhatsApp con el resumen como respaldo).
  2. **Rompía el carrito de TODA la página**: declaraba su propia `const WA_NUMBER`, y `carrito.js`
     declara una constante con el mismo nombre — dos `const` iguales en scripts normales (no
     módulos) comparten el mismo scope global y truenan con «Identifier has already been
     declared». El error ocurre al **cargar** `carrito.js` (es la última línea del archivo), así
     que absolutamente nada de `carrito.js` se ejecutaba en esta página: sin `window.PowerMxCart`,
     sin carrito flotante, nada. El resto de las páginas usan `WA` para lo mismo y nunca chocan;
     aquí se renombró igual. Comprobado en el emulador: antes del cambio, la consola marcaba el
     error al entrar a la página; después, `window.PowerMxCart` existe y el carrito (agregar,
     cantidad, total, nota de "Mercado Pago aún no está configurado", confirmar por WhatsApp)
     funciona igual que en los catálogos. La calculadora de ahorro solar (`calculadora.html`) no
     tenía ninguno de los dos problemas.

## Catálogo público del sitio desde el CRM (SQL 38–39, 27/09/2026) — SQL aplicado y probado; falta publicar el sitio

Paso 3 de "unir CRM y sitio". Antes de tocar código se comparó `productos` (CRM) contra el Excel
del sitio con `38_comparar_catalogo.sql` (de solo lectura, se puede repetir): los 95 productos de
las seis categorías (generador, batería, panel, refacción, renta, paquete_solar) tienen el **mismo
SKU y el mismo precio** en los dos lados, incluidas las tarifas de renta (24h/48h/semana) y los dos
precios de cada paquete (estándar/híbrido) — nada se ha desincronizado desde la carga inicial
(`02_catalogo.sql`). El problema real sigue siendo el ya conocido: **51 de 52 refacciones no tienen
precio**; `0663860SRV` es la única con precio y costo capturados en el CRM (350) aunque el Excel
siga en 0 — un pendiente ya resuelto ahí sin que se notara. `productos.publicar` (por omisión
`true`) y `productos.moneda` ya existían en el esquema desde el principio pero ninguna pantalla los
tocaba; ahora `publicar` es lo que decide si un producto sale al catálogo público.

**Decisión de Caña (27/09/2026):** `convertir.js` (el mismo script de siempre, en modo nuevo) lee el
CRM en vez del Excel — no un endpoint público que el navegador de un visitante llame en vivo. Así no
hace falta abrir ninguna puerta nueva a `anon`: el script corre con la cuenta `bot`, igual de
confiable que el webhook de WhatsApp o `solicitud-web`. Las fotos y fichas técnicas se siguen
sirviendo desde `POWERMX-sitio/Inventario` como siempre — el CRM no las tiene.

**Decisión de Caña, el mismo 27/09/2026, tras ver la primera corrida:** "todo el catálogo debe
publicarse; lo que no tenga stock debe decir sobre pedido". Antes, `catalogo_publico()` y
`convertir.js` excluían lo que no tenía precio (49 de 52 refacciones no se publicaban), y el sitio
decía "No disponible" cuando el disponible daba 0. Se sentía mal esconder una refacción del
catálogo solo porque le faltaba capturar el precio — existe, se puede pedir, y "no disponible"
suena a que no se puede conseguir cuando en realidad solo no está en el estante ahora mismo.

- **`catalogo_publico()`** (`supabase/sql/39_catalogo_publico.sql`, **re-aplicada y re-probada el
  27/09/2026 tras quitarle el filtro de precio**: `39_prueba_catalogo_publico.sql`, 9 de 9 "ok",
  incluido el `p4` invertido: el producto sin precio ahora SÍ sale, con `precio` en `null`).
  Mismo patrón que `registrar_solicitud_web`: security definer, solo `_es_bot_o_admin()`, revocada
  a `anon`. Devuelve sku, categoría, nombre, marca, modelo, descripción, precio, `precios` jsonb
  (rentas y paquetes), moneda, unidad, atributos, claves SAT y **`disponible` en booleano** — nunca
  el costo ni el físico exacto, y nunca un producto con `publicar=false`. **Ahora SÍ publica sin
  precio** (con `precio` en `null`); lo único que sigue vetando la fila es `activo`/`publicar`.
  **Ojo con la fórmula de disponible:** son TRES sumas por separado (físico, apartado, resguardo) y
  luego se restan, igual que la vista `existencias` — juntarlas en una sola suma da un número
  equivocado, porque `salida_venta` resta de físico Y de apartado a la vez. La función no puede
  apoyarse en las vistas `existencias`/`disponibles` (son invoker: llamadas desde una función de la
  cuenta bot se verían vacías, el mismo aviso de "Modo de las vistas" de más abajo), así que calcula
  la fórmula directo contra `movimientos_inventario`. La prueba `39` incluye ese caso cruzado
  (entrada + apartado + venta) para no repetir el error, y ahora comprueba que el producto sin
  precio SÍ sale (antes comprobaba lo contrario).
- **`convertir.js`** (`POWERMX-sitio/Inventario/convertir.js`) ahora tiene dos fuentes:
  `node convertir.js` (Excel, como siempre, sin cambios de comportamiento — comprobado que produce
  el mismo JSON byte por byte) y `FUENTE_CATALOGO=crm node convertir.js` (nuevo: pide
  `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `BOT_EMAIL`, `BOT_PASSWORD` del entorno — las mismas
  credenciales del bot que ya usa `whatsapp`). `filasDesdeCRM()` traduce cada producto del CRM al
  mismo formato de fila que producía el Excel (un mapeo por categoría, comentado en el archivo:
  la mayoría sale de `atributos`, que ya usa los mismos nombres de columna del Excel porque el
  catálogo se sembró una vez desde ahí; rentas y paquetes sacan sus precios de `precios` jsonb; el
  "incluye" de un paquete sale de `descripcion`, pipe-separado, igual que en el Excel) — así el
  resto del pipeline (imágenes, comparación con lo anterior, escritura del JSON, quitar columnas
  privadas) no cambia una línea. `disponible` (booleano) se manda como `stock: 1 | 0`.
  **Probado de punta a punta en la compu de Caña, dos veces**, con `SUPABASE_URL`,
  `SUPABASE_ANON_KEY`, `BOT_EMAIL`, `BOT_PASSWORD` como variables de entorno: la primera corrida
  encontró "Invalid API key" (la llave que se puso al principio quedó vacía/corta — se resolvió
  volviendo a pegarla completa, todo en la misma ventana de PowerShell) y luego un eco de un solo
  ciclo (`RENT-GEN-4KVA-GASOLINA` marcado como "cambio de precio $400 → $400", por un campo
  `precio` de más que la primera versión de `filasDesdeCRM` le agregaba a las rentas sin que el
  Excel lo hubiera tenido nunca; se corrigió quitándolo del mapeo de renta, y desapareció al
  volver a correr). **"Paneles-Solares" no tiene equivalente en el CRM** (es costeo interno de
  paneles sueltos, nunca se publicó) y en modo `crm` simplemente no se toca.
  **Bug real atrapado antes de tocar la base:** la primera versión de `filasDesdeCRM` olvidaba el
  campo `precio` plano para generador/batería/refacción (esas categorías lo llevan aparte de
  `atributos`) — con eso, `procesarCatalogo()` habría marcado a TODOS como "sin precio" y no se
  habría publicado nada. Lo encontró una prueba en seco con datos falsos
  (`filasDesdeCRM` + el normalizador, sin tocar disco ni red) antes de escribirlo contra la base;
  quedó como lección de por qué probar el mapeo entero, no solo que compile.
  Se agregó `@supabase/supabase-js` a `Inventario/package.json` (única dependencia nueva; `npm
  install` ya corrido). Las otras dos vulnerabilidades que reporta `npm audit` (`sharp`, `xlsx`) ya
  estaban antes, sin relación con este cambio.
- **El sitio, tras "todo el catálogo debe publicarse":** en `catalogo-generadores.html`,
  `catalogo-solar-baterias.html` (paquetes y baterías), `catalogo-refacciones.html` y `renta.html`,
  `textoStock()` pasó de "Consulta disponibilidad"/"No disponible" a **"Disponible"/"Sobre
  pedido"** (ya no hace falta cubrirse con "consulta": el disponible es real, viene del CRM), y el
  color del que no tiene stock pasó de rojo a ámbar — "sobre pedido" no es un error. Cada tarjeta
  (`crearTarjeta`/`buildCard`/`buildBatCard`) revisa si `precio` es válido (`> 0`, no null/vacío);
  sin precio muestra **"Precio a consultar"** en vez de "$0" y cambia "Comprar ahora / Agregar al
  carrito" por un solo botón **"Cotizar por WhatsApp"** con un mensaje ya escrito. `renta.html`
  todavía mostraba el número crudo ("Quedan 3 disponibles") porque se quedó fuera del parche del
  20/09 que ya había limpiado los otros tres catálogos — parejo ahora.
  **De paso, un bug de antes se corrigió:** `catalogo-refacciones.html` tenía
  `WHATSAPP_NUMBER = "529990000000"`, un número de plantilla que nunca se reemplazó por el real
  (`529994755275`) — el botón de "¿Está disponible?" llevaba semanas apuntando a un número que no
  existe.
- **El CRM ya es la fuente por omisión (27/09/2026), pedido de Caña.** Probado dos veces a mano y
  con el SQL aplicado, seguir por omisión en Excel era justo el riesgo que se quería evitar: una
  ventana nueva sin las variables puestas habría publicado datos viejos sin que nadie se diera
  cuenta. Ahora `node convertir.js` **sin nada** lee el CRM, y si faltan `SUPABASE_URL`,
  `SUPABASE_ANON_KEY`, `BOT_EMAIL` o `BOT_PASSWORD` en el entorno, **se detiene** con el error de
  cuáles faltan — nunca cae en silencio al Excel. `FUENTE_CATALOGO=excel node convertir.js` queda
  como la opción explícita, para el costeo interno de "Paneles-Solares" (que no vive en el CRM) o
  si el CRM no responde y hace falta publicar algo de emergencia.
- **Falta:** publicar el sitio con estos cambios (commit + push, y el `productos-refacciones.json`
  regenerado con las 49 refacciones nuevas). Lo del robot de GitHub Actions es aparte: hoy sigue
  publicando desde el commit del Excel más el disparador cada 30 min, sin tocar el CRM directo —
  cambiarlo (que el propio robot corra en modo `crm`, con las 4 credenciales como secretos del
  repo) es la siguiente decisión, no parte de este cambio.
- **Ya no urge, pero sigue pendiente:** capturar las 49 refacciones sin precio (ver "Pendientes de
  datos") — ahora se publican igual con "Precio a consultar", así que no bloquea nada, pero cada
  una que se capture deja de mandar al cliente a WhatsApp y le muestra el precio y el botón de
  compra directo.

## Seguridad — lo más importante

- Storage: bucket `ordenes` (**minúscula**, privado; Storage distingue mayúsculas).
  Un bucket `Ordenes` con mayúscula rompió la subida de fotos y firmas hasta el
  19/09/2026. Políticas en `supabase/sql/06_storage_ordenes.sql`: solo admin y
  técnico ven, suben y actualizan; nadie borra desde el CRM.
- Roles en `perfiles`: `admin`, `tecnico`, `cliente`, `sin_rol`. Toda cuenta nueva
  entra como `sin_rol` (trigger) y el admin la promueve. Funciones SQL de apoyo:
  `mi_rol()`, `es_admin()`, `mi_cliente()`.
- RLS por rol en todas las tablas. El técnico lee clientes y equipos, **ve** sus citas
  y órdenes (como T1 o T2) y escribe solo su parte en `orden_partes`; no crea órdenes ni
  actualiza citas (13). **No** ve `productos`, `cotizaciones` ni
  `datos_fiscales`. El cliente solo ve lo suyo.
- El técnico lee el catálogo por la vista `catalogo`, que no trae `costo`.
- Todas las vistas tienen revocado `anon` y solo `select` para `authenticated`
  (`supabase/sql/04_vistas_seguras.sql`). Toda vista nueva lleva el mismo trato.
  Ojo: una vista simple sobre una sola tabla es escribible.
- **Modo de las vistas** (comprobado en la base el 19/09/2026): nacieron con
  `security_invoker = on`, o sea que aplican RLS de quien consulta. Como `productos`
  solo la lee el admin, el técnico las veía vacías. Por eso `existencias`,
  `resguardo_por_cliente` y `catalogo` están en **definer a propósito**
  (`security_invoker = off`) y se cierran ellas mismas con `mi_rol()`
  (`05_vistas_por_rol.sql`). `disponibles` y `por_reordenar` siguen en invoker y
  heredan. El asesor de Supabase marca esas tres como "Security Definer View":
  **no usar su botón de arreglo**, deja al técnico sin existencias ni catálogo.
  Verificar el modo con `select relname, reloptions from pg_class ...`.
  `create or replace view` no cambia el modo: hace falta `alter view ... set`.
- **El modo SE VOLTEÓ de verdad, y la foto del esquema lo agarró (26/09/2026).** El volcado
  de las 17:55 reportó `catalogo` y `resguardo_por_cliente` en `security_invoker = on`
  —contra lo que dice el párrafo de arriba y contra lo que deja `05_vistas_por_rol.sql`—
  mientras `existencias` seguía bien. Con `productos` cerrada a todos menos al admin (tiene
  UNA política, `admin_productos`), eso deja esas dos vistas **VACÍAS para quien no sea
  admin**: cero filas, sin error ni permiso denegado, y la rama de `cliente` del resguardo no
  puede dispararse nunca. **No se notaba** porque ninguna pantalla las lee (el código usa
  `disponibles` en Cotizaciones e Inventario, las dos de admin, y `existencias` en Almacén y
  en "Pedir material" del técnico); se habría notado en la función `agente` llamada por un
  técnico y en el portal del cliente.
  Arreglado con `30_modo_vistas.sql` (`alter view ... set (security_invoker = off)`, que es
  idempotente). Comprobado después con `31_comparar_modo_vistas.sql`: las tres lecturas
  —la expresión del volcado, una lectura directa por nombre de opción y el arreglo crudo—
  coinciden en las cinco vistas, así que `00_volcar_esquema.sql` **lee bien `reloptions`** y
  el archivo de esquema es de fiar. Modos correctos hoy: `existencias`, `catalogo` y
  `resguardo_por_cliente` en `off`; `disponibles` y `por_reordenar` en `on`.
  **La causa de que se voltearan no se determinó.** El botón "Security Definer View" del
  asesor de Supabase es el candidato obvio (hace exactamente eso, y por eso está la
  advertencia de arriba), pero no hay rastro que lo pruebe: el DDL no queda en `auditoria`.
  **La lección que sí queda:** una propiedad que vive en `reloptions` no se ve en el código,
  ni en el diff, ni en la pantalla — solo mirando el catálogo. Por eso conviene volver a
  tomar la foto del esquema de vez en cuando, y no solo cuando algo se rompe.
- **Estado comprobado (prueba 30, 8 de 8 "ok"):** el técnico ve 95 en `catalogo`, una cuenta
  sin rol ve 0, el almacenista ve 0 en `catalogo` (ahí van los precios) y 95 en
  `existencias`. El candado `mi_rol()` de las vistas definer funciona y el almacén no ve
  precios.
  **Riesgo de esa prueba, anotado para la próxima:** sus pasos 5 a 7 le cambian el rol a un
  perfil REAL (la base solo tiene un técnico) y cuentan con el `rollback` para devolverlo.
  Si esa ejecución se cerrara con un commit, el único técnico quedaría como almacenista y
  nadie lo sabría hasta que intentara trabajar en campo. `32_comprobar_roles.sql` lo revisa.
  Una prueba que toca `perfiles` debería crear su propio perfil desechable, como hace la
  prueba de la 19, en vez de reutilizar a una persona de verdad.
- La llave anon es pública por diseño; lo que protege es RLS. Nunca usar
  `service_role` ni en el front ni en el agente.
- El costo no sale nunca al sitio público ni a un técnico.
- Toda vista en modo definer (que se salta RLS) debe llevar dentro
  `where mi_rol() in (...)`. El agente sigue rechazando el rol `cliente` hasta
  que el portal de clientes exista y `05_vistas_por_rol.sql` esté probado con
  cuentas de técnico y cliente.

## Agente — Edge Function `agente`

- `supabase/functions/agente/index.ts`. Llama a la API de Claude (`claude-sonnet-5`)
  con diez herramientas de solo lectura, definidas en el arreglo `LISTA`.
- Consulta con la sesión del usuario, así que hereda sus permisos. "Verify JWT" está
  apagado en la función; la función valida con `auth.getUser(token)` y rechaza
  `sin_rol` **antes** de llamar a la API. Tope de 8 vueltas. "Hoy" se calcula en
  `America/Mexico_City`.
- `ANTHROPIC_API_KEY` es un secreto de Supabase, nunca va en el repo. El saldo de la
  API es chico: no cambiar a un modelo más caro sin avisar.
- **CLI de Supabase instalada el 22/09/2026** (`npx supabase`, proyecto ligado con
  `supabase/.temp/project-ref`). La función se despliega con
  `npx supabase functions deploy agente`, ya no pegándola en el editor web. Aun así,
  el archivo del repo es el que manda: un deploy **pisa** lo que esté en Supabase.
  El `WARNING: Docker is not running` del deploy **no importa**: Docker solo hace falta para
  la copia local de Supabase, y el deploy sube directo al proyecto real.
- **Los registros de una Edge Function NO se ven por CLI** (comprobado el 27/09/2026 con la
  v2.117.0: `functions` solo tiene `list`, `delete`, `download`, `deploy`, `new` y `serve`, y
  no hay un `logs` de primer nivel). Van en el dashboard:
  `https://supabase.com/dashboard/project/<ref>/functions` → la función → **Logs**. Ahí es
  donde aparece lo que el webhook se tragó, porque `whatsapp` **siempre responde 200** y los
  errores no salen por ningún otro lado.
- `supabase/config.toml` (de `supabase init`) describe una copia **local** de Supabase que
  aquí no se usa; el deploy de funciones no la aplica. **Nunca correr
  `npx supabase config push`**: eso sí empujaría esos ajustes al proyecto real y pondría
  `site_url = "http://127.0.0.1:3000"` en Auth, rompiendo el login de `crm.powermx.com.mx`.
  Lo único que de verdad importa de ese archivo es el bloque `[functions.agente]` con
  `verify_jwt = false`: sin él, `functions deploy` vuelve a encender la validación (el valor
  por defecto es `true`) y el agente deja de responder, porque él valida solo con
  `auth.getUser`. Toda función nueva que valide por su cuenta —como el webhook de
  WhatsApp— necesita su propio bloque.
- Rechaza el rol `cliente`, historial de más de 40 turnos y preguntas de más de
  2,000 caracteres. El historial lo manda el navegador: no se le tiene fe.
- Siguientes fases: ver "Ruta de mejora".

## Diseño

Los técnicos trabajan casi siempre **bajo el sol directo**. Eso manda:

- **Modo claro de alto contraste.** El fondo oscuro es peor al sol: refleja como espejo.
- Marca: azul noche `#0c1520`, ámbar `#f59e0b`, claro `#e8edf4`. Tipografía del
  logotipo: Chakra Petch. Ícono: hexágono con P. Archivos en `POWERMX-sitio/LOGOS`.
- Contrastes medidos sobre blanco: azul noche 18.4, ámbar **2.1**, `#888` **3.5**,
  `#475569` 7.6, `#92400e` 7.1. Azul noche sobre ámbar: 8.5.
- **El ámbar nunca es texto ni línea delgada sobre fondo claro.** Solo como fondo de
  botones y alertas, con texto azul noche encima.
- Nada de grises claros: texto secundario no más claro que `#475569`.
- Texto mínimo 17 px y pesos medios o gruesos. Chakra Petch 300 itálica solo en el
  logotipo, nunca en datos.
- Objetivos táctiles de 48 px o más (con `pointer: coarse`; con ratón, 40). En Órdenes
  todo mide 48 o más, medido en pantalla.
- Ningún estado se comunica solo con color: siempre con palabra o ícono.
- La marca entra por una barra superior azul noche con el hexágono ámbar.

**Estado de la pasada de diseño (19/09/2026):**

- **Hecho:** tokens y estilos base en `src/index.css` (un solo lugar; solo modo claro,
  sin la columna centrada de 1126 px ni el modo oscuro que traía la plantilla de Vite);
  piezas compartidas en `src/ui.jsx` (`Logo`, `Alerta` con ícono y palabra); barra de
  marca y pestañas en `App.jsx`; `Login`; y `Ordenes` rehecha (tarjetas numeradas,
  tipo de servicio con botones grandes, botón de guardar fijo abajo, pendientes con su
  motivo). Medido en pantalla: 0 objetivos de menos de 48 px, 0 textos de menos de
  17 px, 0 contrastes bajo 4.5.
- **Cómo aplicar el estilo:** los `<button>`, `<input>`, `<select>`, `<textarea>` y
  `<table>` ya salen con el estilo base sin hacer nada. Variantes por clase:
  `btn-primario` (ámbar con texto noche), `btn-peligro`, `btn-grande`. Estructura:
  `pagina`, `pagina-angosta`, `tarjeta`, `campo`, `fila`, `ayuda`. Mensajes: `<Alerta
  tipo="ok|error|info|aviso">`, no `<p style={{color:'crimson'}}>`.
- **Agenda: hecha** (19–20/09/2026, junto con la 1c): siete columnas que caben en celular,
  cada día es un botón con el número de citas (y "M" si hay mantenimiento por vencer, no solo
  color), estados con palabra. Medido: 0 textos de menos de 17 px, 0 contrastes bajo 4.5, 0
  objetivos de menos de 48 px. No definir componentes dentro de otros componentes (pierden el
  foco al escribir): usar componentes de nivel superior o funciones que devuelvan JSX.
- **Oficina: hecha** (20/09/2026): `Clientes`, `Equipos`, `Inventario`, `Cotizaciones`,
  `Requisiciones`, `Usuarios`, `Agente` y `Tarifas`. Medido en celular emulado en las ocho
  (y en cada pestaña de Inventario y Cotizaciones): 0 textos de menos de 17 px, 0 contrastes bajo
  4.5, 0 objetivos de menos de 48 px, 0 px de desborde horizontal. Convenciones nuevas en
  `index.css`: `.tabla-scroll` (toda tabla va dentro; se desplaza por dentro en vez de ensanchar
  la página), `<details className="tarjeta"><summary className="resumen">` para altas plegables
  (la lista es lo que más se usa), `.pestanas` + `.pestana[aria-pressed]` para pestañas de una
  pantalla, `.rejilla-2` (dos columnas que pasan a una), `.buscador` (lista de resultados con
  botones, no `div` con clic), `.estado-<nombre>` para estados con palabra, `.chat`.
  **Un `.campo` nunca empuja su columna** (`min-width: 0`, controles al 100%): un
  `<input type="number">` ensanchaba los formularios más allá del celular.
  Solo queda por revisar visualmente el escritorio ancho (el panel del navegador integrado mide
  375 px) y sustituir el marcador del logotipo.
- **Ícono/logotipo:** `Logo` (ui.jsx) y `public/icono.svg` son un marcador (hexágono
  ámbar con P). Sustituirlos por los de `POWERMX-sitio/LOGOS`, y regenerar los cuatro
  PNG de `public/`. Chakra Petch no está cargada (tampoco funcionaría sin señal):
  el nombre usa la fuente del sistema; si se quiere, servirla desde el propio sitio.
- **Probar la interfaz sin credenciales ni tocar producción:** levantar
  `VITE_SUPABASE_URL=http://127.0.0.1:9 VITE_SUPABASE_ANON_KEY=x npx vite --port 5174`
  (un servidor inexistente, así la app entra por el modo sin señal) y sembrar en el
  navegador `sb-prueba-auth-token` (sesión vencida con `user.id`), `cache_perfil`
  (con el `rol` a probar), `cache_mis_trabajos` y `cola_trabajos`. Para ver anchos de
  celular usar `resize_window` con el preajuste `mobile`; el panel de escritorio del
  navegador integrado mide 375 px, así que no sirve para anchos grandes.


## Editar clientes y equipos (25/09/2026)

Hasta hoy **solo se podía dar de alta**: en Clientes lo único editable era la columna de km,
y en Equipos nada. Corregir un teléfono obligaba a entrar al Table Editor de Supabase.

Las dos pantallas **reusan el MISMO formulario** del alta con un botón "Editar" por renglón:
así un campo nuevo se agrega una sola vez y no se olvida en la edición. El `<details>` pasa a
ser controlado (`open`), se abre al editar y al cerrarlo se cancela.

`src/lib/formularios.js`, compartido por las dos:
- `aFormulario(registro, vacio)` toma **solo las claves que el formulario conoce** (así `id`
  y `created_at` no viajan de vuelta en el `update`) y convierte `null` en `''`, porque un
  `<input value={null}` pasa a no controlado y React se queja.
- `paraGuardar(form, { numericas, fechas })` deshace la conversión: `''` se va como `null`,
  que es lo único que Postgres acepta en esas columnas.

**Lo delicado estaba en Equipos:** `atributos` guarda tanto los campos del formulario
(combustible, número de paneles…) como **`componentes`, que son las placas que el técnico
fotografió en campo** (SQL 25). Sobrescribir el jsonb entero al editar las habría borrado sin
que nadie se enterara. Al guardar se conservan las claves **ajenas al formulario** y se
reemplazan solo las suyas, de modo que vaciar un campo sí lo borra pero las placas quedan.
Comprobado en el emulador: tras editar la ubicación, `componentes` seguía con la serie del
motor y su foto, y el combustible intacto.

Medido en celular en las dos pantallas, lista y edición: 0 textos < 17 px, 0 contrastes <
4.5, 0 objetivos < 48 px, 0 px de desborde.

## Editar y dar de alta productos completos en Inventario (27/09/2026)

Con el CRM como fuente del catálogo del sitio, hacía falta poder editar y crear productos
**sin abrir el editor SQL de Supabase**. Hasta hoy, "Catálogo" solo dejaba tocar precio, costo,
mínimo y grupo equivalente por renglón; nombre, marca, atributos (kw, kwh, garantía…) y las
tarifas de rentas/paquetes (`precios` jsonb) solo se podían cambiar con SQL a mano.

Mismo patrón que **Editar clientes y equipos** (25/09/2026): un solo formulario para alta y
edición (`aFormulario`/`paraGuardar` de `src/lib/formularios.js`), con un botón "Editar" por
renglón en la tabla del Catálogo. La captura rápida de precio/costo/mínimo/grupo **se queda
igual**, para no perder lo más usado del día a día; el formulario grande es para todo lo demás
y para dar de alta.

- **Atributos por categoría** (`ATRIBUTOS`, igual idea que `ATRIBUTOS` de `Equipos.jsx`): cada
  categoría muestra sus propios campos, con los MISMOS nombres de columna que ya usa el
  catálogo (generador: segmento, combustible, kw, arranque, fase, voltaje, garantia_anios,
  ats; batería: segmento, kwh, quimica, ciclos, voltaje, dod, garantia_anios; panel:
  potencia_w; refacción: subcategoria; renta: kva, combustible; paquete: paneles, kw,
  ahorro_mensual, popular). `ats` y `popular` son casillas que se guardan como **"si"/"no"**
  (no `true`/`false`), porque así los dejó la carga original y así los lee `aBooleano()` del
  lado del sitio — si algún día se guardaran como booleano real tampoco se rompería nada
  (`aBooleano` reconoce las dos formas), pero se mantuvo la forma existente para no generar un
  diff artificial en todo el catálogo.
- **`precios` jsonb (tarifas) solo para renta y paquete_solar**, en su propio recuadro
  ("Tarifas"): 24h/48h/semana para renta, estándar/híbrido para paquete. **El campo "Precio"
  plano se oculta para estas dos categorías** (con un aviso de dónde sale) y se sincroniza
  solo al guardar (`precio = precios['24hr']` o `precios.estandar`) — si se dejara editable
  aparte, cambiar solo la tarifa habría dejado el precio plano desactualizado sin que nadie lo
  notara (ese campo lo siguen leyendo `convertir.js` y el conteo de "sin precio" de esta misma
  pantalla, aunque el sitio ya no lo usa directo para estas dos categorías).
- **"Qué incluye" de un paquete** es la columna `descripcion`, pipe-separada (`|`) — así la
  guardó la carga original, no hay columna aparte. El formulario la muestra como una lista,
  una línea por elemento, y la vuelve a unir con " | " al guardar. Por eso paquete_solar
  tampoco muestra marca, modelo ni claves SAT: son combos, no productos con ficha propia.
- **Igual que en Equipos: al editar se conservan las claves de `atributos` que este
  formulario no maneja** (por si algún día se guarda algo más ahí), y **cambiar la categoría
  durante la edición reinicia atributos y tarifas** (los de la categoría anterior ya no
  aplican).
- Probado en el emulador (`VITE_SUPABASE_URL=http://127.0.0.1:9`, con `cache_perfil` de admin
  sembrado a mano): el formulario cambia los campos correctos al cambiar de categoría en las
  cinco categorías con atributos propios (Precio se oculta y aparece el aviso en renta y
  paquete; SAT/marca/modelo desaparecen solo en paquete; "Qué incluye" reemplaza a
  "Descripción" solo en paquete). No se probó el guardado real (necesita la base), pero la
  lógica de fusión de `atributos` es la misma, ya probada, de `Equipos.jsx`. `npm test`
  (249, sin nuevas pruebas: la lógica queda dentro del componente, igual que en Equipos,
  no se extrajo a un `lib/*.js`), `npm run lint` y `npm run build` en verde.
- **Borrar un producto: ya se puede (ver SQL 43 abajo).** Antes: borrar un producto (no hay botón; se desactiva bajándole
  `activo` a mano en Supabase, o se agrega un botón después si hace falta) y renombrar el
  SKU de las 51 refacciones sin precio en lote (una por una sí se puede, incluidas las dos
  pendientes `22676`/`99727` a las que les falta el cero inicial).

## Navegación por áreas (27/09/2026)

Catorce pestañas en una fila se habían vuelto una tira que había que desplazar de lado. El
dato que cambió el diseño: **esas catorce las ve solo el admin** — el técnico ve dos (Agenda,
Órdenes) y el almacenista una (Almacén).

- **`GRUPOS` en `App.jsx`**, cinco áreas en el orden del trabajo, no alfabético: **Servicio**
  (Agenda, Órdenes) · **Clientes** (Solicitudes, WhatsApp, Clientes, Contactos, Equipos) ·
  **Ventas** (Cotizaciones, Precios) · **Almacén** (Almacén, Inventario, Pedidos) ·
  **Ajustes** (Usuarios, Agente).
- **El primer nivel solo aparece si el rol ve más de un área.** Es una regla, no una lista de
  excepciones por rol: `gruposDe(rol)` filtra las pantallas de cada grupo y tira los vacíos, y
  si queda uno solo se muestran sus pantallas directas. Comprobado en el emulador: técnico y
  almacenista siguen con **una sola fila**, sin un toque de más. Arreglarle la tira al admin no
  puede costarle un toque a quien trabaja bajo el sol.
- **El grupo abierto se DEDUCE de la pantalla**, no se guarda en su propio estado: así
  `irA('requisiciones')` desde Cotizaciones abre el área Almacén sin que nadie tenga que
  acordarse de mover también el grupo. Un estado menos que sincronizar.
- **Colores:** el área abierta va en `--claro` y la pantalla activa en `--ambar`. Dos niveles,
  dos tratamientos; si los dos fueran ámbar pelearían por el mismo significado.
- **La fila de áreas ENVUELVE, no se desplaza** (`flex-wrap: wrap`). Con cinco áreas a 17 px no
  caben en 375 px, y encoger la letra está prohibido (mínimo 17 px, se lee al sol). Desplazarse
  escondería un área entera, que es justo lo que se venía a arreglar. **Ojo:** la primera
  versión les puso `font-size: 16px` para que cupieran — violaba la regla del proyecto y lo
  atrapó la medición, no la vista.
- **Foco:** `.barra :focus-visible` pinta el contorno de blanco, invisible sobre la fila clara
  de pantallas; `.nav-pantallas :focus-visible` lo devuelve a azul noche.
- **Renombres:** `Requisiciones` → **Pedidos** (y su `<h2>` a "Pedidos a proveedor"), `Tarifas`
  → **Precios** ("Precios de servicio"). Eran nombres de tabla, no del trabajo. Las **claves**
  de `PANTALLAS` no cambian (`requisiciones`, `tarifas`), así que ningún `irA()` se rompe.
- Medido en celular con `pointer: coarse` real: 0 textos < 17 px, 0 contrastes < 4.5, 0 px de
  desborde, y los 8 botones de la barra a 48 px o más en **los dos lados**. Los 32 objetivos
  estrechos que salen al medir son de antes y están **fuera** de la barra: las flechas `‹ ›` y
  las celdas de día del calendario de la Agenda (41 y 46 px de ancho).
### Contadores en las pestañas (SQL 40, 27/09/2026) — SQL escrito, falta correrlo

Era el paso 2 de la propuesta y ya estaba anotado como pendiente ("indicador de pendientes en
el menú"). Sin esto agrupar solo **acomoda**; con esto la barra **avisa**.

- **`pendientes_admin()`** devuelve un jsonb con el conteo por pantalla, con las mismas claves
  que `PANTALLAS`. **Una sola llamada, no ocho**: la barra se dibuja en todas las pantallas.
  Cuenta solo lo que alguien tiene que **atender**, no el tamaño de las tablas — un contador
  que siempre marca 40 deja de leerse a la semana. `agenda` junta citas `por_programar` +
  avisos sin mandar (las dos se atienden ahí; `avisos` no tiene pestaña propia), `almacen`
  junta entregas por firmar + pendientes de devolución + solicitudes de material + adicionales
  por conciliar, y `requisiciones` cuenta solo las `pendiente` (una `pedida` está con el
  proveedor, no es trabajo del admin).
- **Solo para el admin**, y no solo por diseño: `App.jsx` documenta que una consulta con el
  token vencido y sin señal se queda esperando la renovación (medido, 5.5 s), así que **no se
  le agrega una al arranque del técnico por un adorno**. Si la llamada falla —sin señal, o el
  SQL 40 sin correr— se queda en `{}` y la barra se dibuja sin globos.
- Se vuelve a pedir **al cambiar de pantalla**: después de atender algo y salir de ahí, el
  número baja solo. El globo de un área es la **suma** de sus pantallas.
- El filtro por rol va en el render (`rol === 'admin' ? …`) y no borrando el estado dentro del
  efecto: `react-hooks/set-state-in-effect` marca el `setState` síncrono en un efecto.
- **Un fallo que lint, build y las 249 pruebas no podían ver:** `perfilServidor?.id === uid ?
  perfilServidor.datos : copia` — al arrancar, `perfilServidor` y `uid` son los dos
  `undefined`, y `undefined === undefined` es **cierto**, así que leía `.datos` de null y **la
  app no arrancaba para nadie**. Lo atrapó abrirla en el emulador, nada más. Va con `?.`.
- Medido en celular: 0 textos < 17 px, 0 contrastes < 4.5, 0 botones < 48 px, 0 px de desborde,
  y los globos suman bien (Servicio 5 = agenda 4 + órdenes 1; Almacén 9 = 7 + 2). El área sin
  pendientes no dibuja globo. `aria-label` dice la frase completa ("Ventas: 1 pendiente",
  singular incluido) y el globo va `aria-hidden` para que el lector no lea "Almacén 9" suelto.
- **Segunda vez con el mismo tropiezo:** al globo le puse `font-size: 15px` y a los botones de
  área `16px` — las dos veces por debajo del mínimo de 17, y las dos las atrapó la medición, no
  la vista. **Al agregar cualquier adorno chico a la interfaz, medir antes de darlo por bueno.**

- **Falta de esta tanda** (ver el artefacto "Navegación del CRM PowerMx"): un inicio que diga
  qué atender, y la barra inferior en el celular — en ese orden.

### Inicio del admin (SQL 42, 29/09/2026) — SQL aplicado y probado

Paso 4 de la propuesta de interfaz. Antes el admin entraba a la Agenda, que muestra el calendario
pero **no lo que está esperando**; ahora entra a **Inicio** (primera pantalla del área Servicio,
solo admin) y el técnico y el almacenista siguen entrando a su lista.

- **`inicio_admin()`** (solo admin; a otro rol le devuelve `{}`) da `fecha`, `hoy` (citas del día,
  sin canceladas) y `urgente`: avisos con `clave`, `nivel`, `pantalla`, `n` y `texto` ya armado.
  Nada viene en cero. Niveles: **alto** = devoluciones atrasadas, avisos sin mandar, solicitudes
  del sitio y WhatsApp sin ver · **medio** = entregas por firmar, citas por programar, cotizaciones
  de WhatsApp por revisar, cotizaciones por vencer, órdenes por enviar, mantenimientos vencidos o a
  7 días, material solicitado · **bajo** = pedidos por recibir.
- `src/Inicio.jsx` / `src/lib/inicio.js`: el nivel se dice con palabra ("Atender hoy", "Esta
  semana", "Cuando se pueda"), cada aviso es un **botón** que abre su pantalla, y una cita sin
  técnico lo dice en vez de callarlo. La fecha se lee como local (`new Date('2026-09-28')` en UTC
  mostraría el día anterior en Mérida).
- Medido en celular con mock del RPC: 0 textos < 17 px, 0 contrastes < 4.5, 0 objetivos < 48 px,
  0 px de desborde; el clic lleva a la pantalla correcta y como técnico no aparece Inicio.
  12 casos en Node (`pruebas/inicio.prueba.js`).
- **Aplicado y probado por Caña el 29/09/2026** (`42_inicio_admin.sql` y su prueba; el paso 2 se corrigió
  porque el trigger de citas ya crea su propio aviso, así que "subió 2" era lo correcto).

## Sincronización con el proveedor (SQL 44, 29/09/2026) — SQL aplicado y probado en Supabase

Precios y existencias de **XLStore (Exel Solar)** entran al CRM con márgenes y candados. Decisión
(opción A): **no hay segunda tabla `productos`**; el CRM sigue siendo la fuente de verdad y el
sync es otra puerta hacia `precio` y `costo`. Tablas: `proveedor_productos` (lo que dijo el
proveedor), `reglas_margen`, `historial_precios`, `cola_revision`, `sync_corridas`, `tipos_cambio`;
`productos` gana `proveedor`, `proveedor_sku`, `precio_auto`, `precio_sync_en`. **Solo se toca un
producto vinculado (`vincular_producto_proveedor`) y con `precio_auto`**: leer 900 productos no
publica ninguno.
- **El precio se calcula en la base** (`_precio_venta`), no en el script: mayor entre
  costo×(1+margen) y costo+mínimo, redondeado **hacia arriba**. La regla más específica gana
  (marca+categoría > marca > categoría > general). Una sola fórmula, sin copia en JS.
- **Candados, todos en SQL:** nunca bajo costo+mínimo; cambio > ±15 % o producto sin precio
  previo → `cola_revision` (no se publica); SKU vinculado que desaparece → cola; lectura con menos
  de la mitad de filas que la anterior → corrida `fallida`, nada se aplica. Aprobar en la cola
  **recalcula** con el costo y FIX más recientes (nunca aplica un precio viejo guardado).
- Flujo: `sync_iniciar` → `sync_recibir_lote` (de 200 en 200) → `sync_cerrar_lectura` →
  `sync_aplicar(tipo_cambio)`. Cuenta `bot` o admin; `resolver_revision(es)` y vincular, solo admin.
- **Script** `scripts/proveedor/sync.js` (`--archivo x.xlsx`, `--seco` lee sin tocar la base);
  adaptador aislado en `scripts/proveedor/adaptadores/` (`excel.js` + `normalizar.js` puro; para
  otro proveedor o un feed, otro adaptador registrado en `index.js`); `banxico.js` (FIX serie
  SF43718, `BANXICO_TOKEN`, o `TIPO_CAMBIO` a mano; sin ninguno **no inventa** uno).
- **Pantalla `Proveedor`** (`src/Proveedor.jsx`, `src/lib/proveedor.js`; área Almacén, solo admin;
  29/09/2026): tres pestañas. **Por aprobar** (la cola: lo urgente primero; "Aprobar todos los
  primeros precios" con confirmación; "Retirar del sitio" va en rojo, no como botón principal;
  `sin_regla` y `sin_costo` no se aprueban, solo se dan por vistos), **Vínculos** (busca en
  `proveedor_productos`; vincular NO activa el precio automático, es un segundo paso) y **Reglas de
  margen** (alta, edición y apagar; avisa si falta la regla general y ofrece **"Crear regla general del
  30 %"** del precio de venta —era 35 % sobre el costo hasta la 51—, un clic, como punto de partida: sin mínimo, al peso, editable
  y una regla por marca o categoría le gana). Arriba, el resultado de la
  última lectura, con el motivo si falló. Aquí no se calcula ningún precio: lo muestra la base.
  11 casos en Node (`pruebas/proveedor-pantalla.prueba.js`); medida en celular con un Supabase
  falso: 0 textos < 17 px, 0 contrastes < 4.5, 0 objetivos < 48 px, 0 px de desborde. **Falta:**
  verla contra la base real, y el globo de pendientes en la pestaña (habría que ampliar
  `pendientes_admin` e `inicio_admin` para contar `cola_revision`).
- **Traer los productos del proveedor al catálogo (SQL 45, 29/09/2026) — aplicado y probado en
  Supabase, 11 de 11 "ok" (también en PGlite)** (`45_importar_productos_proveedor.sql` y su
  prueba). Caña notó que el sync no dejaba nada visible en Inventario: solo llena
  `proveedor_productos`. `importar_productos_proveedor(proveedor, categorias)` crea el producto en
  `productos` con **SKU = código de XLStore**, ya vinculado, **sin publicar y sin precio**
  (decisión de Caña: se publica cuando tenga precio). No duplica (salta por SKU o por vínculo) y una
  categoría sin equivalente no se importa. Mapeo (`_categoria_crm`): paneles → `panel`; baterías,
  controladores y generadores → `bateria` **sin subdividir** (el nombre los mezcla y adivinar por
  palabras se equivocaba); inversores y microinversores → `inversor` (subcategoría en `atributos`);
  monitoreo, suministros, montaje y kits → `accesorio_solar` (subcategoría en `atributos`). Imagen y
  documentos del proveedor quedan en `atributos.imagen_proveedor` / `documentos_proveedor`, para la
  tarea de descargarlos. `activar_precio_automatico(proveedor, categoria)` lo enciende por categoría
  (con 900 productos, uno por uno no es un flujo) y **no publica nada**. `proveedor_resumen` alimenta
  la pestaña nueva **Traer productos** de la pantalla Proveedor. Categorías nuevas también en
  Inventario y en las reglas de margen.
  **El sitio todavía no las muestra:** Caña quiere dividirlo en refacciones de generación y producto
  solar (paneles, baterías/controladores/generadores, inversores y microinversores, monitoreo/
  suministros/montaje/kits). `convertir.js` solo lee las categorías que conoce, así que lo nuevo
  queda fuera del sitio hasta esa tarea.
- **Sitio dividido en Generación y Energía solar (30/09/2026, repo `POWERMX-sitio`).** El inicio
  tiene dos grupos: **Generación** (generadores, refacciones, renta) y **Energía solar** (sistemas
  completos y **componentes**). Página nueva `catalogo-solar.html` con cuatro secciones —paneles;
  baterías, controladores y generadores; inversores y microinversores; monitoreo, suministros, montaje
  y kits—, buscador, subsecciones, "mostrar más" de 24 en 24 y enlace directo (`#paneles`). Sin
  componentes publicados todavía ofrece cotizar por WhatsApp en vez de quedar vacía. **`convertir.js`:**
  catálogo nuevo `solar` (`productos-solar.json`, **solo en modo CRM**) con las categorías `panel`,
  `inversor`, `accesorio_solar` y la `bateria` que trae `atributos.origen = 'proveedor'`; esas baterías
  **salen** del catálogo `baterias` de siempre para no mezclarse con las propias. **Convención para la
  tarea de descargar imágenes y documentos:** `imagenes-productos/Solar/<SKU>.<ext>` y
  `documentos-productos/Solar/<SKU>-ficha-tecnica.pdf` (también `-manual.pdf`), con el SKU = código de
  XLStore; sin archivo, la tarjeta muestra un ícono y `convertir.js` avisa en UNA línea cuántas faltan.
  **Descargado el 30/09/2026** con `Inventario/descargar-proveedor.js` (lee los enlaces del Excel del
  proveedor; se puede cortar y repetir): **901 imágenes** comprimidas a 1,200 px (326 MB → 36 MB) y
  **813 fichas técnicas** (1.1 GB; faltan 7 por enlaces caídos o que no eran PDF). **Los manuales NO se
  bajaron** (2.7 GB, y uno pesa 47 MB: Cloudflare no sirve archivos de más de 25 MB); decisión de Caña.
  Todo vive en `Inventario/`; **`convertir.js` copia a `sitio-publicar` solo los archivos de los productos
  que se publican** (poda) — sin eso cada corrida del robot subiría 1.1 GB de productos que nadie ve. Un
  catálogo solo-CRM sin productos publicados se escribe como `[]` (no deja el JSON viejo apuntando a
  archivos podados). Ojo con el peso: el repo pasa de ~170 MB a ~1.3 GB; subirlo en tandas de unos 300 MB
  (un push de más de 2 GB lo rechaza GitHub).
  Probado con los 908 productos reales del Excel como muestra (sección, subsección, búsqueda, "mostrar
  más", nombres con comillas y `<` sin romper la tarjeta, carrito) en escritorio y celular. **SQL 46**
  (`46_publicar_al_aprobar_precio.sql`, **aplicado y probado en Supabase, 4 de 4 "ok"**): aprobar el
  **primer precio** de un producto del proveedor lo publica (`_aplicar_precio`); uno retirado con
  precio no se republica solo y uno de PowerMx de siempre nunca se publica desde ahí. Sin el 46,
  nada del proveedor llegaría al sitio. **Ojo:** el robot de GitHub Actions
  (`actualizar-catalogo.yml`) no tiene credenciales y `convertir.js` lee del CRM por omisión, así que
  **se detiene con error en cada corrida** desde que el CRM pasó a ser la fuente (27/09/2026): hacen
  falta los secretos `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `BOT_EMAIL` y `BOT_PASSWORD` en el repo y un
  bloque `env:` en ese paso. **El bloque `env:` (y un `concurrency` para que no corran dos robots a la vez) ya está en
  el flujo (30/09/2026); faltan los cuatro secretos en GitHub → Settings → Secrets and variables →
  Actions del repo `POWERMX-sitio`, que los pone Caña (con `BOT_PASSWORD` nuevo, rotado).** Mientras
  no estén, el sitio solo se actualiza corriendo `convertir.js` a mano.
- **Supabase corta toda consulta a 1,000 filas en silencio** (dato que este cambio volvió real:
  el catálogo pasa de ~95 a ~1,000 productos). `src/lib/paginar.js` (`todasLasFilas`, 5 pruebas) pide
  de mil en mil y ahora lo usan Inventario, Cotizaciones, Tarifas, Compras y Almacén; **cualquier
  consulta nueva al catálogo completo debe usarlo**, con un orden que no se repita (SKU o id). La
  pestaña Vínculos busca en el servidor (60 por vez, con conteo exacto). `catalogo_publico()` no se
  afecta: devuelve un solo jsonb.
- **Leer XLStore con tu sesión: C y D (30/09/2026, escrito y probado, sin commit al anotar esto).**
  `scripts/proveedor/xlstore/` (ver su `LEEME.md`). **`extraer.js`** es una sola pieza (recibe `fetch`
  y `DOMParser` de afuera) que sirve a dos caminos: **C**, `xlstore-descargar.js` (GENERADO de `extraer.js`
  con `crear-herramienta.js`; se pega en la consola de Chrome y baja `xlstore_catalogo.csv`), y **D**, el
  adaptador `adaptadores/xlstore.js` (`sync.js --adaptador xlstore`, con la cookie de la sesión de Caña y
  `linkedom`). No salta ningún captcha: la sesión la inicia una persona. Candados: verifica la sesión al
  empezar Y al terminar, rechaza la lectura si trae pocos productos, casi sin precios o sin existencias,
  4 peticiones a la vez, nunca imprime la cookie. Por omisión NO pide fichas ni manuales y **SQL 50**
  (aplicado y probado en PGlite; **falta correrlo en Supabase**) hace que una lectura sin documentos no
  borre los que ya había. `adaptadores/excel.js` ahora también lee `.csv` (`csv.js`). `powermx.ps1` ganó las
  opciones 4–8 (leer con sesión, guardar cookie, programar cada 12 h con el Programador de tareas, quitar,
  copiar la herramienta); cookie, conector y token de Banxico se guardan **cifrados con DPAPI** en
  `%USERPROFILE%\.powermx`; el modo `auto` no hace preguntas y deja registro sin secretos. **Límites
  reales:** la sesión CADUCA (no se sabe cuánto dura: hay que probar unos días; cuando pasa, la lectura
  falla y el CRM lo muestra como "última lectura falló"); la compu debe estar encendida; y reutilizar la
  sesión automáticamente puede ir contra los términos de XLStore. **Falta:** probarlo contra el XLStore
  REAL (la sesión del navegador caducó antes de poder hacerlo; todo se probó con un XLStore de mentira
  con la misma forma de HTML: 25 pruebas en `pruebas/xlstore.prueba.js`).
- **Límite conocido:** el login de XLStore lleva reCAPTCHA v3, así que **no hay cron posible**
  hasta que Exel Solar dé un feed; hoy el archivo sale de una lectura hecha con la sesión de Caña
  en el navegador. Pendiente: pantalla para vincular y aprobar la cola, paquetes solares
  recalculados, publicar disponibilidad "inmediata" con `stock_local`.
- Probado: la migración se aplica dos veces sin error y la prueba (`44_prueba_sync_proveedor.sql`,
  12 pasos) pasa en **PGlite** (Postgres en WebAssembly, stubs de `es_admin`, `_apunta`…) y **en
  Supabase, 12 de 12 "ok" (29/09/2026)**. `npm test` (289), lint y build en verde; el adaptador leyó el Excel real
  (908 productos, 12 sin costo).

## Segundo proveedor: Solarama (SQL 51, 01/10/2026) — aplicado y probado en Supabase (9 de 9; el conteo del paso 3 contó también los 27 repetidos reales, ya corregido en la prueba)

Pedido de Caña: "agregar Solarama como proveedor y sus productos al almacén; conservar los artículos repetidos,
mostrar el precio más caro al público, poner como costo el del proveedor más barato y ponerlo como opción 1;
margen de productos del 30 %". Solarama manda una **lista de precios en PDF** (`LISTA DE PRECIOS SOLARAMA
<MES> <AÑO>.pdf`, dólares MÁS IVA, sin existencias ni imágenes); Caña la carga **cada que se la dan, más o
menos cada 5 meses**.

- **Lector del PDF** (`scripts/proveedor/adaptadores/solarama.js`, `pdfjs-dist` como devDependency, solo para
  scripts: no entra al bundle). El PDF no es una tabla: cada texto viene suelto con su posición, y en varias
  páginas la descripción va en dos renglones, uno arriba y otro abajo del código y el precio. Se juntan los
  textos por renglón (y por ancho: lo que se toca va pegado, "MIN 6000TL" + "-" + "X2"), se reconoce cada
  producto por su código (izquierda) y su precio (derecha), y cada renglón suelto de descripción se pega al
  producto más cercano (±16 puntos). Cada página se reconoce por su título (`FORMAS`); una página que no se
  reconozca, una que no dé productos, un precio fuera de rango o menos de 300 productos **detienen** la lectura
  con el número de página, en vez de entregar precios equivocados. Paneles: se toma "Menor a 1 pallet" por
  pieza; si solo se vende por pallet, el de 1 pallet y el nombre lo dice. Guiones tipográficos (‐) se vuelven
  "-". La lista de septiembre de 2026 dio **429 productos** (408 con precio; 21 de carport "sujeto a
  proyecto"). 10 pruebas en `pruebas/solarama.prueba.js`.
- **Cómo se lee:** `powermx.ps1` opción **9** (toma el PDF más reciente con "SOLARAMA" en el nombre, en Descargas
  o el Escritorio; primero lo lee en seco y pregunta) o
  `node scripts/proveedor/sync.js --proveedor solarama --archivo "<pdf>"` (con `--proveedor solarama` el
  adaptador se elige solo).
- **Varios proveedores por producto:** tabla `producto_proveedores` (producto, proveedor, código, `opcion`,
  `costo_mxn`). `_calcular_precio` mira a todos los ligados con lectura **vigente** y costo: **costo = el más
  barato (opción 1, a quien se le compra); precio = el que daría el más caro**. Empate: se queda la opción 1
  que ya tenía. `productos.proveedor`/`proveedor_sku` quedan como **espejo** de la opción 1 (lo que ya los
  leía sigue funcionando) y un **disparador** (`espejo_a_vinculos`) crea el vínculo si alguien los escribe
  directo. `sync_aplicar` recorre los productos ligados al proveedor de la corrida y reordena opciones aunque
  el precio no cambie. **Si un proveedor deja de listar un producto que el otro sigue vendiendo, no va a "Ya
  no lo lista"**: el costo pasa al que queda.
- **Los 27 repetidos** (Growatt MIN 5000/6000/10000, TPM-E y TPM-CT-E, pedestal AXE; Huawei SUN2000 de 3 a
  150 kW, SmartLogger y SDongle; Victron MultiPlus-II 3 y 5 kW, Quattro 10 kVA, Ekrano, Lynx Power In y
  Distributor, MK3-USB, portafusible Mega) se ligan en la 51 por modelo exacto. Se dejaron fuera a
  propósito los dudosos: SmartSolar 250/100 y RS 450/200 (variantes Tr/MC4 o VE.Can), Mega fuse (Solarama
  vende paquete de 5), Cerbo GX (XLStore tiene el MK2), DTSU666 (otra corriente). **Ojo:** el pedestal AXE
  cuesta 21.65 USD en XLStore y 65 en Solarama: con la regla "precio del más caro" el precio se triplica y el
  candado del ±15 % lo manda a "Por aprobar". Revisarlo a mano.
- **SKU del CRM** (`_sku_crm`): XLStore y cualquier otro, su código tal cual (como la 45); **Solarama lleva
  `SLR-`** y va sin acentos, espacios ni símbolos (`KIT1X4A10°` → `SLR-KIT1X4A10`, `MIN 3600TL-X2` →
  `SLR-MIN-3600TL-X2`), porque sus códigos traen espacios, "°" y algunos son solo números, y el SKU nombra la
  imagen y la ficha en el sitio. Comprobado con las 429 filas reales: 426 nuevos, 3 repetidos saltados, 0 SKU
  raros, todas con categoría equivalente.
- **Margen: 30 % SOBRE EL COSTO** (decisión final de Caña, 01/10/2026: precio = costo × 1.30). La 51 lo
  había puesto sobre el precio de venta por error de interpretación; la **52** lo corrige. Queda la columna
  `reglas_margen.sobre` (`costo` | `precio`) por si alguna regla se quiere sobre el precio (con `precio`,
  precio = costo ÷ (1 − margen)); la pantalla dice siempre cuál es y su equivalente.
- **Parámetros de costeo** (`parametros_costeo`, solo admin; `fijar_parametro_costeo` deja rastro en
  `auditoria`): mano de obra por panel 800, fija 2,500, trámite CFE 1,500, respaldo 2,500, imprevistos 3 %,
  metros incluidos 30 y 10. Son los estimados del borrador de paquetes; Caña los corrige en **Precios →
  "Costeo de paquetes solares"**. Todavía no los usa nada: son para el armado de paquetes (siguiente paso).
- **Pantalla Proveedor:** arriba la última lectura de cada proveedor; "Traer productos" con selector XLStore /
  Solarama; en "Vínculos" cada producto lista sus proveedores con costo, existencias, "opción 1" y "Quitar",
  y "Agregar Solarama"/"Agregar XLStore"; en la cola, un repetido dice el costo de la opción 1 y "Precio
  calculado con" el más caro; las reglas tienen "El margen es sobre: el precio de venta / el costo".
- **Probado:** la 51 se aplica dos veces sin error y las pruebas 44, 45, 46 y 50 siguen dando lo esperado con
  la 51 encima (PGlite). `51_prueba_segundo_proveedor.sql`, 9 pasos, todos "ok" en PGlite (fórmula, dos
  proveedores, sync que aplica y reordena, proveedor que deja de listar, traer de Solarama con SKU SLR-,
  quitar un proveedor sin apagar el automático, parámetros con auditoría, técnico sin acceso). Ensayo con las
  429 filas reales: MIN 6000 quedó con costo de Solarama (7,825.50) y precio con XLStore (11,341). `npm test`
  (348), lint y build en verde; pantallas medidas en celular con un Supabase falso (0 textos < 17 px, 0
  contrastes < 4.5, 0 objetivos < 48 px, 0 px de desborde).
- **Para ponerlo en marcha, en este orden:** (1) correr `51_segundo_proveedor.sql` y luego su prueba en
  Supabase; (2) publicar el CRM (pantallas nuevas); (3) `powermx.ps1` opción 9 (lee el PDF de Solarama y
  sincroniza); (4) Proveedor → Traer productos → Solarama → traer; (5) activar el precio automático por
  categoría y aprobar los primeros precios; (6) volver a sincronizar XLStore para que tome el 30 %.
- **Falta / pendiente:** imágenes de Solarama (no las da; se publican sin foto); que Compras y Pedidos
  propongan al proveedor de la opción 1; volver a leer el PDF cada mes (si cambia el formato, la lectura lo
  dice y hay que ajustar `FORMAS`).

## Disponibilidad y "En promoción" (SQL 52, 01/10/2026) — aplicado y probado en Supabase (6 de 6)

Pedido de Caña: "el margen es sobre el costo; agrega las existencias de la última lectura de XLStore a la
página; lo de Solarama será bajo pedido; los que comparten proveedor, el precio más caro; y un apartado EN
PROMOCIÓN, con un margen considerable pero comprándolo en Solarama".

- **Regla general → 30 % sobre el costo** (solo si seguía en 30 % sobre el precio de la 51).
- **Disponibilidad y existencias del proveedor en el sitio** (`catalogo_publico()` gana `disponibilidad`, `existencia_merida` y `existencia_nacional`): **'inmediata'**
  = existencia propia (la fórmula de la 39) o del proveedor en Mérida (`stock_local` de XLStore, la lectura
  vigente); **'proveedor'** = solo en su existencia nacional; **'pedido'** = nada de eso, o sea todo lo de
  Solarama. `disponible` sigue existiendo (= no es 'pedido'). En el sitio: "Disponible" / "Disponible en unos
  días" / "Sobre pedido", y debajo del código **las piezas de XLStore** de su última lectura ("12 en existencia
  en Mérida · 40 en el país"): Caña pidió que se vieran (01/10/2026). La cantidad del almacén **propio** de PowerMx
  sigue sin publicarse (regla de siempre del sitio).
- **Precio de promoción** (`productos.precio_promocion`, `_precio_promocion`): solo para un artículo con dos
  proveedores donde el más barato (opción 1) no es el que marca el precio normal. Precio = costo del barato ×
  (1 + `promo_margen_pct`, 40 %), redondeado como su regla, y **solo si baja al menos
  `promo_descuento_minimo_pct` (5 %)** contra el precio publicado y si la lista de ese proveedor tiene menos
  de `promo_vigencia_lista_dias` (200; Solarama manda la suya cada ~5 meses). Los tres se editan en Precios →
  "Promociones del sitio". Se recalcula en cada sincronización (en `_ordenar_proveedores`), se apaga si el
  cálculo falla, al quitar un proveedor o al pasar a precio manual. El precio normal del CRM (el que usa
  Cotizaciones) no cambia: la promoción es del sitio. Con las listas actuales solo califican el Huawei
  SUN2000-3KTL-L1 (9,133 → 7,097, −22 %) y el portafusible Mega de Victron (−21 %).
- **`sync_aplicar` recalcula todo lo que tiene proveedor y precio automático**, no solo lo del proveedor de
  la corrida: lo que solo vende Solarama (lista cada ~5 meses) sigue el tipo de cambio de cada lectura de
  XLStore. "Ya no lo lista" sigue siendo solo del proveedor de la corrida. La corrida guarda `en_promocion`.
- **CRM:** pestaña **"En promoción"** en Proveedor (precio normal, promoción, descuento y a quién se le
  compra); Precios separa "Costeo de paquetes solares" de "Promociones del sitio"; la lectura de un proveedor
  con más de 150 días sale como aviso ("pide la nueva").
- **Sitio** (repo `POWERMX-sitio`): `convertir.js` pasa `disponibilidad` y, si hay promoción, `precio` =
  el de promoción (es el que cobra el carrito), `precio_antes` = el normal y `en_promocion`.
  `catalogo-solar.html`: etiqueta "En promoción" y precio normal tachado en la tarjeta, sección "En
  promoción (n)" en las pastillas (enlace directo `#promocion`), enlace "Ver lo que está en promoción" en el
  encabezado, y orden: promoción, luego lo que se entrega antes. Probado con un catálogo de mentira en
  escritorio y celular (0 px de desborde; el carrito guarda 7,097).
- **Probado:** la 52 se aplica dos veces sin error; su prueba (6 pasos) y las de la 44, 45, 46, 50 y 51 dan
  lo esperado en PGlite. `npm test` (350), lint y build en verde. **En Supabase, 6 de 6 "ok" (01/10/2026)**,
  incluido el catálogo: P52A inmediata con promoción 1,960 y existencia 3/40, P52B "proveedor" con 12 en el país,
  P52C sobre pedido, y 0 campos privados (ni `costo` ni `stock_local`/`stock_proveedor`).
- **Para ponerlo en marcha:** ~~(1) correr `52_disponibilidad_y_promociones.sql` y su prueba~~ hecho; ~~(2) publicar el
  CRM y el sitio (`convertir.js` y `catalogo-solar.html`)~~ hecho (commits `6875a18` y `27335f3`); (3) sincronizar XLStore (`powermx.ps1` opción 1
  o 4): aplica el 30 % sobre el costo (los precios bajan ~3.7 % contra el 35 % de antes, o ~9 % si ya se había
  sincronizado con la 51) y calcula las promociones; (4) opción 2 para actualizar el sitio.

## Paquetes solares — borrador y decisiones (30/09 y 01/10/2026)

- **Borrador** en el escritorio de Caña: `Borrador paquetes solares PowerMx.xlsx` (4 a 14 paneles JA 630 W,
  inversores Growatt MIC 3300 / MIN 6000 / MIN 10000, estructura Aluminext reforzada de 215 km/h, revisión
  eléctrica de cada arreglo, híbrido A = interconectado + respaldo LUX con batería, híbrido B = todo en LUX
  sin inyección). El generador vive en el scratchpad de esa sesión; las reglas se pasarán a
  `src/lib/armado.js` con los 6 paquetes del Excel como prueba de regresión.
- **Decisiones de Caña (01/10/2026):** margen de los productos **30 % sobre el costo** (el borrador usaba 30 %
  sobre el precio; al armar los paquetes en el CRM usarán la regla de margen); la mano de obra del borrador
  como valor inicial, editable (`parametros_costeo`, SQL 51).
- **Pendiente: promociones en paquetes para reducir ese margen** (pedido de Caña, 01/10/2026). Idea: una
  regla de margen de categoría `paquete_solar` más baja, o un descuento con vigencia, sin tocar el margen
  de los productos sueltos.
- **Siguiente paso acordado:** SQL de recetas de paquete (`paquete_solar_lineas`, producto o grupo
  equivalente por línea; el precio lo recalcula la base con cada sync, con el mismo candado del ±15 %) +
  `armado.js` + pantalla "Paquetes solares"; luego "Sistema a la medida" en Cotizaciones.
- **Siguen sin decidir:** si el precio publicado incluye IVA, y el híbrido A o B.

## Cotizaciones: editar, PDF, pago y garantía, eliminar (05/10/2026)

Cuatro cosas que no existían y que Caña pidió al usar el CRM de verdad. **SQL 59 y 60 aplicados y
probados por Caña el 05/10/2026** (la prueba de la 60 es de 8 pasos con rollback).

- **Editar** (`Cotizaciones.jsx`, botón en "Ver"): usa el MISMO formulario del alta, así que un campo
  nuevo se agrega una sola vez. **Solo `borrador` y `enviada`** (`sePuedeEditar` en `cotizacionPdf.js`):
  una aceptada ya apartó inventario con sus partidas, y cambiarlas por debajo dejaría el apartado en otra
  cantidad; para editarla se pasa antes a Borrador. El `update` lleva `.in('estado', ['borrador','enviada'])`
  y pide `select('id')`: si alguien la aceptó mientras se editaba, no toca ninguna fila y la pantalla lo dice.
  Estado y `creada_por` no se tocan al editar.
- **Forma de pago y garantía** (SQL 59, `cotizaciones.forma_pago` y `garantia`, texto libre y opcional).
  Estaban en el formato de Excel de PowerMx pero en el CRM solo existían dentro de `condiciones`. La forma de
  pago nueva trae de inicio "Anticipo del 60% para iniciar, saldo contra entrega." y esa línea **salió** de las
  condiciones por omisión para no imprimirse dos veces; una cotización vieja que la lleve en las condiciones la
  sigue mostrando ahí hasta que se edite. Un campo vacío no imprime su fila.
- **PDF de la cotización** (`src/lib/cotizacionPdf.js`, botón "Descargar PDF"): conserva el formato de Excel que
  PowerMx ya usaba —encabezado "PowerMx — Soluciones de Energía" con su contacto, título "COTIZACIÓN — <TIPO>",
  datos del cliente, datos del equipo, conceptos, totales y condiciones— y lo mejora: **solo imprime los datos
  que existen** (nada de "[ ]"), repite el encabezado de la tabla en cada hoja, numera las páginas y arma el
  folio como `PMX-COT-AAAAMMDD-0001` (fecha + folio con ceros; es solo de presentación, no se guarda).
  Una refacción **incluida** en el servicio (precio 0) se lee "Incluido", no "$0.00". **Nunca** sale
  `notas_internas` ni costos; las partidas son las copiadas al cotizar, no el precio de hoy. El teléfono y el
  correo del encabezado están fijos en `CONTACTO_EMPRESA` de `pdfEstilo.js`.
- **Eliminar una cotización de prueba con sus citas y órdenes** (SQL 60, `eliminar_cotizacion(id, p_ejecutar)`,
  solo admin). **Siempre en dos pasos:** sin `p_ejecutar` solo devuelve una vista previa (qué se borraría y qué
  lo impide) y la pantalla pide confirmación antes del borrado de verdad. Cadena: cotización → citas
  (`citas.cotizacion_id`) → órdenes (`ordenes_servicio.cita_id`; la orden no guarda la cotización). Borra
  también sus pedidos, entregas sin firmar, surtido, solicitudes de material y los avisos de WhatsApp de la cita
  que **aún no salieron** (`salida_wa` no tiene llave foránea hacia `avisos`: sin quitarlos saldría un mensaje
  de una cita inexistente). **Se niega** si ya hubo efectos reales: entrega firmada o sin firma, devoluciones,
  cualquier movimiento de inventario que no sea apartar/liberar, pedidos ya pedidos o recibidos o ligados a una
  compra, una orden enviada al cliente, o un aviso de WhatsApp ya mandado. **Lo único del inventario que se
  borra** son los `apartado`/`libera_apartado` de esa cotización, y solo si por producto quedan en cero: es la
  única excepción a "el inventario solo se inserta", y el borrado queda en `auditoria` con el resumen. Una
  cotización todavía Aceptada se cambia antes a Borrador (así libera lo apartado). Los archivos de Storage no se
  borran. **No se probó en PGlite** (no había arnés a la mano): solo la corrida con rollback de Caña.
  Reglas puras de la pantalla en `src/lib/eliminarCotizacion.js` (5 casos en Node).

### PDF de la orden: formato nuevo (05/10/2026)

El PDF de la orden (`construirPdfOrden` en `documentos.js`) se rehizo con el mismo estilo que la cotización.
Las piezas de estilo viven en **`src/lib/pdfEstilo.js`** (`crearLienzo`: encabezado de dos bandas, título,
barras de sección, rejilla de datos, **tablas con líneas en todas las celdas**, cajas de texto, pie con página).
Recibe `paraPdf` como parámetro para no importar `documentos.js` y evitar un ciclo. **La cotización todavía trae
su propio código de dibujo (copia del mismo estilo): conviene migrarla a `pdfEstilo.js`** para que no diverjan.
- Los puntos de revisión van en tabla por sección (No. · Punto · Resultado · Datos y hallazgos); strings,
  parámetros, banco, lecturas del generador y prueba de transferencia también. El dictamen va en recuadro propio.
- **Fotos:** en marcos del mismo tamaño (4:3), dos por fila, con su leyenda "Foto N — punto". La foto se
  **ajusta dentro sin deformarse** (`ajustarEn`; antes se estiraba a 4:3 y una vertical salía chueca) y para eso
  `fotoDataUrl` ahora devuelve `{ url, w, h }`. Una foto que no abre deja su marco con "Foto no disponible".
  Sin fotos, la sección no se imprime. Tope de 12 (`MAX_FOTOS_PDF`).
- Firma: dos cajas (cliente y técnico responsable con su nombre).
- Si generar el PDF falla con «mime type application/pdf is not supported», es el bucket `ordenes`, que nació
  solo para imágenes: `53_bucket_ordenes_pdf.sql` le agrega `application/pdf` y sube el tope a 10 MB.
- **Cómo se verificó sin verlo:** este entorno no puede rasterizar un PDF (no hay `pdftoppm` y el panel del
  navegador no deja capturar uno local). Se generó con `node --import ./pruebas/registra.js` (necesita un
  `FileReader` y `createImageBitmap` falsos para las fotos) y se leyeron las posiciones del texto con
  `pdfjs-dist`: contenido, orden, 0 elementos fuera de la hoja y totales iguales a los del Excel. **El aspecto
  real lo tiene que mirar una persona.**

Dos tropiezos de esta tanda, por si se repiten: (1) en una prueba SQL, una función que escribe y la
comprobación de lo que escribió **no pueden ir en la misma sentencia** (la sentencia no ve los cambios que la
función hace dentro de ella; salió "existe aún: t" cuando ya estaba borrado); (2) en el Bash de esta
herramienta, un heredoc largo con comillas y backticks puede romperse con «unexpected EOF»: crear el archivo con
la herramienta de escritura y no con `cat <<`.

## Expediente de ingresos y egresos por cotización (SQL 61, 07/10/2026)

Pedido de Caña: por cada cotización, un flujo de ingresos y egresos con comprobantes, y al cerrar la
operación, la utilidad. **SQL 61 aplicado y probado por Caña el 07/10/2026** (9 pasos con rollback).
Pantalla `src/Expediente.jsx` (botón "Expediente" en el detalle de una cotización), reglas y llamadas en
`src/lib/expediente.js` (36 casos en Node). Solo admin: aquí vive el dinero.

**Decisiones de Caña, que mandan todo el cálculo:**
- **El ingreso es la cotización** (su base sin IVA, `total − iva`), no lo cobrado. Los **cobros** se registran uno
  por uno y se comprueban con la operación bancaria (foto o PDF); "cobrado", "comprobado con el banco" y
  "por cobrar" se ven aparte de la utilidad.
- **El material NO se captura en el expediente: lo dicta la cotización.** Cada partida con `producto_id` ×
  `productos.costo` (el costo real). Las facturas de compra entran al **almacén general** (Compras) y lo que
  no se use se queda ahí; a la cotización se le carga solo lo que ella pide. Una pieza sin costo capturado
  cuenta como cero y **se avisa** ("la utilidad sale inflada").
- **Sin IVA:** utilidad = base − material − otros egresos sin IVA. Un ticket sin factura cuenta **completo**
  (su IVA no se recupera); un gasto con factura registra su IVA aparte (`iva`) y se cuenta sin él.
- **Pago de técnicos y uso del vehículo: manuales** (monto escrito por Caña). Más adelante se puede sugerir
  una tarifa; hoy no hay.
- Otros egresos: gasolina, viáticos, otro, cada uno con su ticket (foto o PDF) opcional.

**Cómo está hecho:** tabla `expediente_movimientos` (ingreso = categoría `cobro`; egreso = `gasolina`,
`vehiculo`, `tecnico`, `viaticos`, `otro`), bucket `finanzas` privado y solo admin. **Todas las cifras las
calcula la base** (`expediente_resumen`), una sola fórmula; la pantalla solo las muestra.
- **Cerrar** (`cerrar_expediente`) congela una foto de las cifras en `cotizaciones.expediente_cierre`: un cambio
  de costo en el catálogo ya no mueve la utilidad de un trabajo cerrado. Con avisos pendientes (falta cobrar,
  cobros sin comprobante, piezas sin costo, sin pago de técnicos, cotización no aceptada) **no cierra salvo
  que se pida** ("Cerrar de todos modos"): cerrar con algo sin comprobar es una decisión, no un descuido.
- Cerrado, **dos triggers** impiden tocar sus movimientos y las partidas/importes de la cotización
  (`_expediente_cerrado_bloquea`, `_cotizacion_cerrada_bloquea`). Se **reabre** con un motivo (obligatorio)
  que queda en `auditoria`. Cerrar y reabrir también quedan ahí.
- Borrar una cotización de prueba (SQL 60) arrastra sus movimientos por `on delete cascade`.
- **Tropiezo del SQL:** `v_avisos := v_avisos || 'texto'` con un texto literal sin tipo falla («malformed array
  literal»): Postgres lo lee como un arreglo. Con `format(...)` sí funciona (devuelve texto); con un literal va
  `array_append(arr, 'texto'::text)`. La prueba lo atrapó al primer intento.
- **Tropiezo de React:** cargar datos con `useEffect(() => { cargar() }, [])` donde `cargar` hace `setState` marca
  `react-hooks/set-state-in-effect`; el patrón que pasa el lint es `leer().then(d => { if (vivo) aplicar(d) })`
  (como en `Inicio.jsx`).
- Medido en celular: 0 textos < 17 px, 0 contrastes < 4.5, 0 objetivos < 48 px, 0 px de desborde.

### La cobranza se cierra sola con el comprobante leído (SQL 63, 07/10/2026) — escrito; falta correrlo

Pedido de Caña: "la cotización se cierra cuando la IA lee el comprobante y se cuadra con la cotización".
**Se entendió como el lado del INGRESO** (la cobranza); **no cierra el expediente**, porque ese lleva la utilidad y
necesita los gastos (`cerrar_expediente` sigue siendo aparte). **No toca `cotizaciones.estado`** (aceptada, etc.):
esa columna mueve inventario y es otra cosa; la cobranza es una dimensión nueva (`cobranza_estado`).
- Cada cobro guarda además el **monto que leyó la IA** (`monto_leido`, `leido_ia`). Un cobro está **verificado** si
  tiene archivo, lo leyó la IA y lo capturado coincide con lo leído (±1 centavo): así un monto tecleado mal, o un
  comprobante que no es de ese pago, no cierran nada.
- **`liquidada`** = lo verificado alcanza el total de la cotización (con IVA, ±$1); **`parcial`** = hay cobros pero lo
  verificado no alcanza; **`pendiente`** = sin cobros. **Lo recalcula la BASE sola** (triggers sobre los movimientos y
  sobre el total de la cotización): borrar el cobro que la cerraba la vuelve a abrir. Un cobro en efectivo o con el
  comprobante sin leer suma a "parcial" pero **no puede liquidar solo**.
- **Una diferencia legítima** (una retención de ISR o IVA, un descuento acordado) se da por liquidada **a mano con motivo
  escrito** (`liquidar_cobranza`); esa decisión no se recalcula sola hasta `reabrir_cobranza`. Con el expediente
  cerrado no se puede cambiar la cobranza (reábrelo primero).
- Pantalla: "Cobranza: Sin cobros / Cobro parcial / Cobrada" con palabra, en el Expediente y en la lista de Cotizaciones;
  cada cobro dice "Verificado con el comprobante", "Comprobante sin verificar" o "Sin comprobante"; al capturar, una
  línea en vivo dice **"Verificado / No cuadra / Sin leer"** comparando lo tecleado con lo que leyó la IA, y avisa si el
  cobro es mayor que lo que falta. Una **clave de rastreo repetida** pide confirmación (una misma transferencia contada
  dos veces haría pasar por cobrado lo que no se cobró); solo avisa, porque un pago puede repartirse.
- `expediente_resumen` (redefinida en la 63) trae `ingreso.cobranza` y `ingreso.verificado`, y avisos nuevos: cobrado de
  más y cobros con comprobante sin leer o que no cuadran.
- Pruebas: 12 pasos SQL (`63_prueba_cobranza_cotizacion.sql`) y 7 casos en Node.
- **En el Inicio (SQL 64, 07/10/2026 — escrito; falta correrlo):** `inicio_admin()` ganó dos avisos sobre las cotizaciones
  **aceptadas** con la cobranza sin liquidar, con cuánto falta por cobrar: **"… con más de 30 días sin cobrarse por
  completo"** (nivel alto, "Atender hoy": una venta ya ganada que se queda sin cobrar) y **"… sin cobrarse por completo"**
  (nivel medio). La antigüedad es la de la fecha de la cotización. Si ya se cobró todo pero falta leer o cuadrar el
  comprobante, dice "cobrado: falta verificar el comprobante" en vez de "$0 por cobrar". Llevan a Cotizaciones. No hizo falta
  tocar `Inicio.jsx`: dibuja cualquier aviso que mande la base. La 64 es la función completa de la 42 con esos dos renglones
  más (`create or replace` no permite agregar un renglón sin repetirla entera).
- **Falta:** el contador en los globos de las pestañas (`pendientes_admin`): se dejó fuera a propósito porque las
  cotizaciones aceptadas con cobro abierto pueden ser muchas y un globo que siempre marca un número alto deja de leerse.

### Leer comprobantes con IA (Edge Function `leer-comprobante`, SQL 62) — escrita; falta correr el SQL y desplegar

Una sola función con **tres modos**: `factura` (factura de proveedor con sus líneas → Compras), `ticket` (gasto →
Expediente) y `banco` (comprobante de SPEI, depósito o ficha → cobro del Expediente). Reglas de las tres:
- **Solo PROPONE; nada se guarda en la función.** Cada pantalla muestra lo leído para que Caña lo revise y
  corrija, y recién entonces se registra: un importe o una cantidad mal leídos contaminarían el costo real, la
  utilidad o lo cobrado. Es el mismo criterio de `leer-placa`. Los avisos dicen "Esto lo leyó la IA y puede equivocarse".
- Solo admin (saldo de la API), `verify_jwt = false` con su bloque en `config.toml`, baja el archivo **con la sesión de
  quien pregunta**, tope de 10 MB, y cada modo solo lee su bucket (`factura` → `compras`; `ticket`/`banco` →
  `finanzas`). El texto del documento es **dato, no instrucción**. Modelo `claude-sonnet-5`. Se despliega con
  `npx supabase functions deploy leer-comprobante`.
- El archivo se **sube una sola vez** (para leerlo) y esa misma ruta es la que se guarda como comprobante: no se
  vuelve a subir al registrar.

**Facturas de material** (`src/FacturaLeida.jsx`, `src/lib/factura.js`, 22 casos en Node): bloque "Leer una factura"
en Compras. Cada renglón se **empata con el catálogo** y la pantalla dice con palabra qué tan segura es la
pareja: **Segura** (el código de ESE proveedor ya estaba ligado a la pieza, en `producto_proveedores`),
**Revisa** (mismo SKU, o nombre casi igual: se preselecciona), **Dudosa** (candidatos flojos: no se preselecciona
nada) o **Sin pareja** (se propone pieza nueva). El empate por nombre usa un coeficiente de Dice sobre las
palabras y **castiga fuerte** si las dos traen claves con números y no comparten ninguna (el aceite 15W40 no
se confunde con el 10W30; un filtro de aire no se empata con uno de aceite). Por línea se elige: una pieza del
catálogo, buscar otra, **crear una pieza nueva** u omitir (un flete, por ejemplo). Se avisa **"No cuadra"** si las
líneas leídas no suman el subtotal impreso (un renglón perdido o un precio mal leído), si hay renglones
incompletos que se descartaron, si es en dólares o si los precios ya traen IVA (se dividen entre 1.16: el
costo se guarda sin IVA).
- **`registrar_compra_de_factura` (SQL 62)** hace todo en **una sola transacción**: crea las piezas nuevas,
  guarda el código del proveedor de cada pieza (así la próxima factura de ese proveedor se empata sola) y
  llama a `registrar_compra` (SQL 41). Si algo falla —un SKU repetido, una cantidad en cero— no queda NADA a
  medias. Una pieza nueva nace **sin publicar y sin precio** (`publicar` es `true` por omisión en la tabla: se
  fuerza a `false`), ligada al proveedor y a su código (`productos.proveedor` / `proveedor_sku`, y de ahí el
  trigger de la 51 llena `producto_proveedores`). El SKU propuesto es el código del proveedor; si no hay,
  se escribe a mano.
- **El costo del catálogo:** se actualiza solo si la pieza no tenía ninguno o si Caña marca la casilla (una
  compra de urgencia a sobreprecio no reescribe el costo sin que alguien lo decida); una pieza nueva siempre
  toma el de la factura.
- El nombre del proveedor se reconoce aunque cambie cómo viene impreso ("CUMMINS MEXICO S.A. DE C.V." →
  "Cummins México") para no partir un proveedor en dos; el campo ofrece los ya conocidos.
- El bucket `compras` ahora acepta también fotos; el archivo leído queda en `compras.archivo_pdf` (la columna se
  llama "pdf" pero guarda también la foto).
- **Gasolina, viáticos y otros gastos por foto** (Expediente → "Registrar un gasto"): el botón "Leer el
  comprobante y llenar los datos" propone tipo, fecha, monto, IVA si viene desglosado, litros y combustible,
  y guarda el folio del ticket como referencia. **Lo que el ticket no trae no pisa lo ya capturado.** Un cobro
  hace lo mismo con el comprobante bancario (monto, fecha, forma, clave de rastreo y banco).
- **No probado con documentos reales:** todo se vio en el emulador con una función simulada. Falta correr la
  prueba del SQL 62 en Supabase, desplegar la función y probar con facturas y tickets de verdad (cómo lee
  tus PDF y fotos, y cuánto saldo gasta cada lectura).
- **Expedientes por cerrar en el Inicio (SQL 65, 07/10/2026 — escrito; falta correrlo):** `inicio_admin()` avisa de las
  cotizaciones **aceptadas ya cobradas** (cobranza liquidada, SQL 63) cuyo expediente sigue **abierto**: faltan los
  gastos y cerrar para conocer la utilidad. **"… cobradas hace más de 15 días con el expediente sin cerrar"** es nivel
  alto ("Atender hoy": una operación que terminó de cobrarse y de la que nadie sabe cuánto dejó) y **"… con el
  expediente por cerrar"** es nivel medio. Los días cuentan desde que se liquidó la cobranza. Cerrar el expediente la
  saca de la lista. Es la función completa de la 64 con dos renglones más. Probado con la diferencia antes/después
  (`65_prueba_inicio_expedientes.sql`, 4 pasos).
- **Falta:** una tarifa sugerida para técnicos y vehículo, y contar estos avisos en los globos de las pestañas (se dejó
  fuera a propósito: ver arriba).

## Compras (SQL 41, 27/09/2026) — SQL escrito, falta correrlo

La mitad que le faltaba al inventario. Se sabía qué salió y por qué; lo que **entraba**
aparecía sin proveedor, sin costo real y sin respaldo, y `productos.costo` era un número
escrito a mano. Pedido de Caña al ver la propuesta de interfaz: "un área de compras, después
de requisiciones, donde se agreguen las refacciones y se liguen las facturas".

**CÓMO NO SE CUENTA DOBLE — y aquí leer el código cambió el plan.** La propuesta inicial era
que la factura fuera lo único que mueve inventario y quitarle esa tarea a la requisición. **No
hizo falta: el candado ya existía.** `cambiar_estado_requisicion` se niega a tocar una
requisición que ya está `recibida` o `cancelada`, y la tabla guarda el `movimiento_id` de su
entrada. Así que las dos puertas conviven y cada una cubre un caso real:

| lo que pasa | quién mete la entrada |
|---|---|
| Llega el material **con** factura | la compra (`COMPRA-n`), y marca el pedido `recibida` |
| Llega **sin** factura todavía | la requisición, como siempre (`REQ-n`) |
| La factura llega **después** de recibir | **nadie**: la compra solo liga y guarda el costo |
| Compra directa, sin pedido | la compra (reponer el estante, el caso común) |

`cambiar_estado_requisicion` **no se tocó** (aplicada y probada desde la 08).

- **Tablas `compras` y `compra_lineas`**, solo admin (aquí vive el costo: ni el técnico ni el
  almacenista entran), con su `revoke` a `anon` como toda tabla desde la 14. Índice único por
  proveedor + factura: una factura no se captura dos veces (solo sobre las no canceladas).
- **`registrar_compra(datos, lineas)`** calcula el subtotal **de las líneas**: un total
  capturado a mano que no cuadre con sus renglones es un error esperando a que lo descubran.
  El IVA es 16% salvo que se capture otro (exento, retenciones).
- **El costo del catálogo no se pisa solo.** Cada línea guarda lo que costó de verdad, y
  `productos.costo` se actualiza **solo si la línea lo pide** (`actualizar_costo`, una casilla
  por pieza). Una compra de urgencia a sobreprecio no debe reescribir el costo de referencia
  sin que alguien lo decida. El cambio queda en `auditoria` con el valor anterior.
- **`cancelar_compra` no borra:** mete `ajuste` en negativo —el único tipo que lo acepta— con
  la referencia de la compra. El inventario se corrige con otro movimiento, regla del
  proyecto. Cancelar dos veces devuelve `sin_cambio`. **Deuda anotada:** los pedidos ligados
  siguen marcados como recibidos; la función lo avisa por escrito en vez de deshacerlo sola.
- **La factura va a un bucket propio `compras`**, privado y **solo admin**. En `ordenes` la
  leerían los técnicos (su política es admin + técnico) y ahí van costos.
- **Pantalla `Compras`** (`src/Compras.jsx`, `src/lib/compras.js`, área Almacén, solo admin):
  "Pedidos por recibir" como botones que precargan pieza, cantidad y costo de referencia;
  buscador del catálogo; aviso **"El costo de esta pieza subió de 285 a 310 pesos"** con la
  casilla para actualizarlo; totales en vivo; XML y PDF del CFDI. En la lista, cada renglón
  dice **"Entró" o "Ya había entrado"** — con palabra, que es la diferencia entre mover
  inventario y solo guardar el costo.
- **Los totales se calculan en los dos lados y tienen que coincidir.** `totalesDeCompra` de
  `compras.js` reproduce lo que hace el SQL, y la prueba en Node usa **el mismo caso** que la
  prueba SQL (10×310 + 4×310 + 3×300 = 5,240 / 838.40 / 6,078.40). Si se separaran, la
  pantalla prometería un total y la base guardaría otro, y nadie se enteraría hasta cuadrar
  con el proveedor.
- **Los archivos se suben DESPUÉS de registrar**, porque la ruta cuelga del id de la compra.
  Si la subida falla, la compra ya quedó bien y el mensaje lo dice: se vuelve a adjuntar.
- 18 casos en Node. Medido en celular: 0 textos < 17 px, 0 contrastes < 4.5, 0 px de desborde.
  **Tres objetivos por debajo de 48 px** —la casilla de actualizar costo (26) y los dos
  `input[type=file]` (21 de alto)— pero los tres van **envueltos en su `<label>`**, de 61 y
  53 px, que es lo que de verdad se toca: hacer clic en la etiqueta marca la casilla y abre el
  selector de archivo.
- **Falta:** correr `41_compras.sql` y `41_prueba_compras.sql` (13 pasos), y dar de alta una
  pieza nueva desde la propia compra (hoy manda a Inventario y de regreso).

- **Quitar un producto (SQL 43, 29/09/2026):** botón "Quitar" en Inventario → Catálogo, que llama a `quitar_producto(id)` (solo admin, queda en `auditoria`). **Borra de verdad solo si el producto nunca se movió** (ningún movimiento, entrega, surtido, paquete, pedido, solicitud ni compra lo toca); con historia lo **desactiva** (`activo` y `publicar` en false) porque las llaves foráneas impiden borrarlo y el inventario es un libro de movimientos. Se reactiva editando el producto. **Aplicado y probado el 29/09/2026** (`43_quitar_producto.sql`, 4 de 4 "ok").

## Pantallas

`Agenda` (calendario, por programar, empalmes) · `Trabajos` (pestaña "Órdenes"; móvil,
funciona sin señal; ver 1d: cola en localStorage, fotos encogidas en IndexedDB, firma en
canvas) · `Almacen` (admin y almacenista; ver 2b) · `Clientes` ·
`Contactos` · `WhatsApp` (bandeja; solo admin) ·
`Equipos` · `Inventario` · `Cotizaciones` · `Requisiciones` · `Tarifas` (ambas solo admin) ·
`Tecnicos` (pestaña "Usuarios") · `Agente` · `Login`. Las pantallas reciben la
prop `irA(clave)` de `App.jsx` para saltar a otra pantalla. El portal del cliente es un aviso de "en construcción".

## Paquetes por pantalla (21/09/2026)

`App.jsx` carga cada pantalla con `lazy(() => import('./Pantalla'))` y las envuelve en un
`<Suspense>`; solo `Login` se queda en el arranque, porque hace falta antes de saber quién
entra. El paquete principal bajó de **611 kB a 445 kB** (127 kB comprimido) y cada pantalla
quedó en su propio archivo: Trabajos 42 kB, Agenda 22 kB, Cotizaciones 20 kB, Almacén 18 kB,
Contactos 13 kB, Inventario 13 kB, Tarifas 12 kB, y el resto por debajo de 7 kB. Comprobado
en el emulador con un técnico: al entrar solo descarga `Agenda.jsx`, y `Trabajos.jsx` hasta
que abre "Órdenes" — nunca baja Cotizaciones, Tarifas, Contactos ni el Agente.

**Ojo con el uso sin señal:** el service worker precarga **todos** los archivos del bundle
(`vite.config.js` los lista completos), así que las pantallas que el técnico necesita
desconectado siguen guardadas en el celular y una pantalla nueva no rompe el modo sin señal.
Si alguna vez se filtra esa lista para ahorrar datos, hay que dejar dentro `Agenda` y
`Trabajos` o el técnico se quedará sin poder abrirlas offline.
El respaldo del `<Suspense>` va sin `<main>` propio: ya está dentro del `<main>` de la app
(dos `<main>` anidados son HTML inválido).

## Sin señal (Trabajos)

- **Service worker** (`sw/plantilla.js` → `dist/sw.js`): guarda la app al instalarse.
  La página de inicio va primero a la red y a los 4 s cae a la copia; los archivos
  con hash salen de la copia. **Nunca** toca lo que no sea del propio sitio: Supabase
  va directo a la red. Solo se registra en producción (`main.jsx`).
- El plugin de `vite.config.js` mete en la lista los archivos del *bundle* y unos
  pocos de `public/` **escritos a mano** (manifest, favicon y los íconos). Si algo
  nuevo de `public/` debe abrir sin señal, agregarlo a `publicos` ahí. Si
  quedan marcadores `__VERSION__`/`__PRECACHE__` sin reemplazar, la construcción falla
  a propósito.
- Los archivos de `public/` no llevan hash: si cambian sin que cambie el código, el
  celular puede seguir mostrando el viejo hasta la siguiente versión.
- **Sesión sin señal:** con el token vencido (dura 1 h) y sin red, `getSession()` de
  Supabase devuelve `null` aunque la sesión siga guardada. `App.jsx` cae a
  `usuarioLocal()` (lee `sb-*-auth-token`) y guarda el perfil en `cache_perfil` (se
  borra al salir). Eso solo decide qué botones se ven; el servidor sigue exigiendo un
  token válido, que Supabase renueva solo al volver la señal.
- El `tecnico_id` de una orden sale de `usuarioLocal()` primero: `getUser()` pide red
  y `getSession()` puede quedarse esperando la renovación con señal mala.
- **El perfil se lee de la copia guardada al instante** y se refresca por detrás
  (`App.jsx`). Antes la app esperaba a la red: medido, 5.5 s mostrando un falso "tu
  cuenta no tiene permisos" y ~7 s hasta entrar, porque supabase-js reintenta la
  renovación del token vencido con esperas crecientes. Cualquier `supabase.from(...)`
  con el token vencido y sin señal sufre esa misma espera: no poner un dato crítico
  de campo detrás de una consulta.
- Probar con la versión **construida** (`npm run build` + `npx vite preview`), en
  Chrome → DevTools → Application → Service Workers → Offline. El navegador integrado
  de Claude Code no admite service workers.

## Registro de scripts aplicados (`_migraciones`, SQL 68, 09/10/2026)

**La tabla `_migraciones` manda sobre las notas de este archivo.** Si una nota dice "falta
correrlo" y la tabla dice que está, vale la tabla: `select numero, archivo, aplicada_en from
_migraciones order by numero;`. Cada script nuevo **termina** con
`insert into _migraciones (archivo, tipo) values ('NN_nombre.sql', 'esquema') on conflict (archivo) do nothing;`
(las pruebas y las consultas de solo lectura no se registran). El 68 hizo el inventario de 01–63
buscando en la base un objeto propio de cada script, sin dar nada por aplicado a ciegas.
- **Estado al 09/10/2026:** 59 registrados. Corridos ese día, con su prueba en Supabase: **30**
  (las tres vistas se habían vuelto a voltear a `invoker`: técnico y almacén veían vacío),
  **54** (8/8; el cron `recordatorios-de-cita` llevaba días llamando a una función que no
  existía), **55** (8/8), **64** (4/4), **65** (4/4), **66** (10/10) y **67** (12/12).
- **Sin registrar:** 05 (ya corrido; vuelve a correr el 68 y se registra solo), 47–49 (datos de
  una sola vez: regístralos a mano si corrieron) y **34**, que se detiene a propósito porque
  hay **un perfil con rol `cliente` sin `cliente_id`**: ligarlo en Usuarios y volver a correrlo.
- **El 64 y el 65 estaban dañados en el repo** y por eso nunca corrieron: donde iba
  `concat(' · $', to_char(…))` había `' · ` + `end $fn$;` + `, to_char…`. Es lo que deja un
  `String.replace` de JavaScript con `$'` en el texto de reemplazo (`$'` = "lo que sigue a la
  coincidencia"). **Al generar SQL con `replace`, usar una función de reemplazo
  (`s.replace(x, () => nuevo)`), nunca una cadena con `$`.**
- De paso, `inicio_admin()` (65) arma bien los plurales: "cotizaciones", "conversaciones",
  "devoluciones", "órdenes" (antes pegaba "es": "cotizaciónes").
- **Foto del esquema renovada el 09/10/2026** (59 tablas, 158 funciones, 91 políticas) y
  **sin deriva**: cada función de la base está en algún script y viceversa (la única que no,
  `unaccent_inmutable`, viene del esquema original). Qué es cada archivo: `supabase/sql/INDICE.md`.
  Para bajar la foto: Export → Download CSV en el editor y quitarle las comillas del CSV (la
  celda en pantalla aplana los saltos de línea).
- **Cargar un script largo en el editor de Supabase:** la página no deja leer de `localhost`
  (CSP), así que se pega con `monaco.editor.getModels()[0].setValue(...)` y se compara la
  longitud con el archivo. Una consulta que devuelve muchas columnas se lee mejor como una sola
  (`row_to_json(t)::text` o `concat_ws`): la rejilla del editor no dibuja las columnas fuera de
  la vista.

## Forma de trabajar y tropiezos conocidos

- La interfaz, los nombres y los comentarios van en español.
- Windows no distingue mayúsculas en nombres de archivo; Cloudflare sí. El archivo
  debe llamarse exactamente como su `import` (componentes en PascalCase). Para
  renombrar solo la mayúscula: `git mv` en dos pasos, pasando por un nombre temporal.
- Correr `npm test`, `npm run lint` y `npm run build` antes de cada push. Los tres están
  en verde: si algo nuevo los rompe, se arregla, no se ignora.
- En `Trabajos` (offline) no usar nada que pida red para datos de la orden:
  `getSession()` sí, `getUser()` no.
- Los scripts SQL van numerados en `supabase/sql/` y deben poder repetirse sin
  tronar (`if not exists`, `drop policy if exists`).
- Git se usa desde la terminal de VS Code; en cmd como administrador no está en el PATH.
- **Pruebas en el editor SQL de Supabase:** solo muestra el resultado de la **última**
  sentencia. `begin; ... rollback;` sí deshace los cambios. Para ver resultados de
  varios pasos, guardar cada uno con `set_config('app.x', valor::text, true)` y leerlos
  en el `select` final (las tablas temporales no funcionaron ahí). Para probar como un
  usuario: `set local role authenticated` + `set_config('request.jwt.claims', ...)`.
  Correr **siempre** el bloque completo: una línea suelta de una prueba puede tocar
  datos reales si el usuario simulado no la frena.
- **El editor de Supabase MUTILA los bloques plpgsql (27/09/2026). Para una prueba nueva,
  escribirla en SQL plano.** Dos formas distintas de romperse, las dos vistas el mismo día con
  `33_prueba_rol_cliente.sql`:
  1. inyectó `ALTER TABLE <variable> ENABLE ROW LEVEL SECURITY` en medio del bloque (ver abajo);
  2. quitada esa causa, **truncó el script** justo después de un comentario a mitad del bloque
     y pegó sus propios `-- source: dashboard` / `-- user:` / `-- date:`, dejando las comillas
     de dólar sin cerrar («unterminated dollar-quoted string»).
  **No es un límite de tamaño:** `00_volcar_esquema.sql` tiene 15,952 bytes y 340 líneas y
  corre completo, y `30_prueba_modo_vistas.sql` sí tiene bloque plpgsql y corrió. La causa del
  truncado no se determinó, y no vale seguir adivinando.
  **La salida:** escribir la prueba **sin bloque plpgsql**. Se puede: los valores intermedios
  van en `app.*` con `set_config(...)`, lo condicional se hace con `insert ... select ... where`
  y `update ... where`, y los uuid con `nullif(current_setting('app.x'), '')::uuid` para que un
  valor vacío no truene el cast. `33_prueba_rol_cliente.sql` quedó así y no tiene ni una comilla
  de dólar, ni en los comentarios.
- **NO usar `select ... into` ni `execute ... into` dentro de un bloque plpgsql (27/09/2026).**
  El editor de Supabase trae una función que le activa RLS a las "tablas nuevas" de un
  script, y lee `select id into v_producto from productos` como la **sintaxis vieja de
  `create table as`**: cree que `v_producto` es una tabla y agrega
  `ALTER TABLE v_producto ENABLE ROW LEVEL SECURITY` **en medio del bloque**, que queda
  sin cerrar y truena con «unterminated dollar-quoted string». Se ve clarísimo en cuáles
  marca: solo las variables que aparecen como primer destino de un `into`.
  En su lugar, asignación: `v_n := (select count(*) from catalogo);`. Hace lo mismo y no se
  puede confundir con crear una tabla. Para insertar, generar el uuid antes
  (`v_id := gen_random_uuid()`) en vez de `insert ... returning id into`.
  Una lectura normal (sin `execute`) sigue siendo válida después de `set local role`: Postgres
  marca los planes que dependen de RLS y los vuelve a planear al cambiar el usuario.
  **Ojo:** 19 de los archivos `*_prueba_*.sql` del repo traen el patrón viejo. Corrieron sin
  problema entre el 20 y el 25/09, así que parece una función nueva del dashboard; quedan como
  minas para quien los vuelva a correr. Se arreglan cuando haga falta repetirlos, no antes.

## Pruebas (26/09/2026)

`npm test` — 232 casos con el corredor de Node (`node:test`), sin dependencias nuevas, en
menos de un segundo. Antes existían "24 casos probados en Node", "81 casos", "34 casos"…
pero vivían en **scripts de usar y tirar**: nada impedía que un cambio rompiera el cálculo
de un total o el orden de la cola sin que nadie se enterara. Ahora están en el repo.

- Cubre las **reglas puras**: `revision` (50), `tarifas` (27), `preventivo` (22),
  `equipoCampo`+`solicitudes` (19), `material` (17), `documentos` (17), `whatsapp`+`avisos`
  (15), `cola` (14), `formularios` (14), `almacen` (12), `contactos` (12), `errores` (8),
  `fechas` (5). Lo que dinero e inventario tocan, que es lo que pedía la ruta de mejora:
  el traslado de 40 km, el disponible, la cola sin señal.
- **No cubre** la base ni las pantallas: eso se prueba como siempre (`begin/rollback` en el
  editor SQL y el emulador). El doble de `pruebas/falso/supabase.js` **revienta a
  propósito** si una prueba llama a la red: significa que el cálculo está enredado con la
  consulta y hay que sacarlo.
- **Dos cosas que el arnés tiene que arreglar** (`pruebas/enlaces.js`, con
  `node:module.register`):
  1. `src/lib/supabase.js` usa `import.meta.env`, que solo existe dentro de Vite y truena
     al cargarlo en Node: se desvía al doble. Ojo con no atrapar `@supabase/supabase-js`,
     que también lleva "supabase" en el nombre.
  2. En el código conviven `from './errores'` y `from './fechas.js'` porque **Vite resuelve
     la extensión y Node no**. El enlace le agrega `.js` al que no la trae, en vez de
     obligar a tocar 26 imports que ya funcionan en producción.
- Las pruebas se llaman `pruebas/<lib>.prueba.js` y el `npm test` las pasa por glob (el
  corredor de Node no las encontraría solas: busca `*.test.js`). `eslint.config.js` tiene
  un bloque para `pruebas/**` con las globales de Node.
- **Dos veces la prueba estaba mal, no el código:** `paraPdf` recorre por **puntos de
  código**, así que un emoji deja UN interrogante y no dos; y el tipo `solar` se llama
  "Sistema solar", no "Solar". Vale anotarlo: al escribir una prueba sobre código que ya
  funciona, la primera sospecha es la prueba.

## Foto del esquema (`00_volcar_esquema.sql`, 26/09/2026)

**El problema:** los scripts 09 a 29 son casi todos `alter table` sobre tablas que **nunca
estuvieron en el repo**. `01_productos.sql` crea `productos` y `03_roles.sql` crea
`perfiles`, pero `clientes`, `equipos`, `citas`, `ordenes_servicio`, `cotizaciones`,
`movimientos_inventario`, `auditoria` y `datos_fiscales` solo existen dentro de Supabase.
Si el proyecto se pierde, se pierde el esquema.

**Por qué no sirve `npx supabase db dump`:** corre `pg_dump` **dentro de Docker**, y en la
máquina de Caña no hay Docker, ni Podman, ni `pg_dump`, ni `psql`. El único camino sin
instalar nada es leer los catálogos desde el editor SQL.

`supabase/sql/00_volcar_esquema.sql` es un `select` (no cambia nada, se puede repetir) que
arma el DDL con `pg_get_functiondef`, `pg_get_indexdef`, `pg_get_constraintdef`,
`pg_get_viewdef` y `pg_get_triggerdef`. Devuelve **una sola fila** para que el editor no
corte ni reordene, y de ahí se guarda como `supabase/sql/00_esquema_base.sql`.

- **El orden está pensado para poder correrse en una base vacía:** tipos → funciones →
  secuencias → tablas → defaults → restricciones → índices → vistas → triggers → RLS →
  políticas → permisos. Las **funciones van antes de las tablas** porque hay columnas
  generadas que las llaman (`conversaciones.telefono_norm` usa `normalizar_telefono`), y
  los **defaults van después** por lo contrario: un default puede llamar a una función que
  todavía no existiría. Aun así es una foto, no una migración.
- **Las vistas salen con su `reloptions`**, así que conservan `security_invoker`.
  Reconstruir `existencias`, `resguardo_por_cliente` o `catalogo` en invoker dejaría al
  técnico sin existencias ni catálogo (ver "Seguridad").
- **Lo revocado también se escribe.** Un listado de `grant` no puede mostrar que a `anon`
  se le quitó todo, ni que `_fijar_componente` está revocada a PUBLIC: en este proyecto eso
  es una promesa de seguridad, así que el script emite los `revoke` explícitos.
- **PUBLIC no es un rol:** `has_function_privilege('public', …)` falla y `format('%I',
  'PUBLIC')` crearía un rol que no existe. Se lee el ACL con `aclexplode` buscando el
  otorgado `0`, que es PUBLIC; `proacl` nulo significa el permiso por defecto.
- **Corrida por Caña el 26/09/2026, a la primera:** `supabase/sql/00_esquema_base.sql`, 4,885
  líneas — **30 tablas, 6 vistas, 74 funciones, 60 políticas**, 12 triggers, 63 índices, 136
  restricciones y 84 `revoke`. Ahí quedaron por fin `clientes`, `equipos`, `citas`,
  `ordenes_servicio`, `cotizaciones`, `movimientos_inventario`, `auditoria` y
  `datos_fiscales`. Ese archivo **no se edita a mano**: se vuelve a correr el script y se
  reemplaza entero.
- **Encontró TRES cosas reales**, ninguna visible en el código, en el diff ni en la pantalla.
  Es el argumento para volver a tomar la foto cada tanto y no solo cuando algo se rompe:
  1. `catalogo` y `resguardo_por_cliente` en `security_invoker = on`, o sea vacías para quien
     no fuera admin (ver "El modo SE VOLTEÓ de verdad" en Seguridad).
  2. `catalogos` con `insert`/`update` abiertos a cualquier rol, y `auditoria` con el `insert`
     abierto a cualquier rol — un rastro de auditoría que cualquiera podía alimentar con
     renglones falsos.
  3. `anon` con todos los privilegios, incluido `truncate`, sobre las 11 tablas del esquema
     original. Las dos últimas las arregló `35_cerrar_escritura.sql`.
- La sección de vistas quedó **auditada** con `31_comparar_modo_vistas.sql`: tres lecturas
  distintas de `reloptions` coinciden en las cinco vistas.

## Ruta de mejora

Actualizada el 19/09/2026 tras una revisión completa del código. Con 10 horas a la
semana, el orden importa: cada fase cierra un riesgo antes de abrir funciones nuevas.

**Hecho en esa revisión:** `borrar()` de Clientes movido dentro del componente (no
refrescaba la lista); `tecnico_id` de las órdenes offline desde la sesión guardada
(`usuarioLocal()`); fechas en hora local; cotización que sale de "aceptada" a
cualquier estado libera el apartado; candado real contra sincronizaciones dobles en
Órdenes; agente cierra el rol `cliente` y limita historial y pregunta (ya pegado en
Supabase); lint en cero.

1. **Cerrar seguridad de datos** (antes de cualquier portal de cliente)
   **Cerrado el 27/09/2026**, salvo probar las pantallas con la cuenta de técnico (que es
   trabajo en la app, no en la base) y la opción a futuro de mover `costo` a
   `productos_costos`. Lo que se cerró ese día: el rol `cliente` probado de verdad (33), la
   escritura de `catalogos` y `auditoria` (35) y los privilegios de `anon` (35).
   - ~~Vistas por rol.~~ Hecho y probado el 19/09/2026 (`05_vistas_por_rol.sql`):
     técnico ve 95 en `disponibles` y `catalogo` y 0 en `productos`; una cuenta sin
     rol ve 0 en todo; los modos quedaron definer/invoker como se describe arriba.
     ~~Falta probar con una cuenta de cliente.~~ **Probado el 27/09/2026 con
     `33_prueba_rol_cliente.sql`: 9 de 9 "ok".** El cliente ve **0** en `catalogo`
     (precios), `productos` (costo), `existencias` y `cotizaciones`; **1** ficha en
     `clientes`, la suya; y **1** renglón en `resguardo_por_cliente`, el suyo, **0 de otros
     clientes**. Con eso la rama de cliente de esa vista
     (`mi_rol() = 'cliente' and m.cliente_id = mi_cliente()`) **se ejecutó por primera vez**
     y filtra bien.
     La prueba **fabrica su escenario** (cliente de prueba, enlace temporal del perfil y
     resguardo de dos clientes) porque la base no tenía ni `cliente_id` en el perfil ni un
     solo movimiento `a_resguardo`; deshace el enlace **a mano** además del `rollback`.
     Ojo con la trampa que distingue a propósito: sin `cliente_id`, `mi_cliente()` devuelve
     null y el cliente ve 0 — lo mismo que se vería con el filtro mal escrito. Un 0 ahí no
     prueba nada, y por eso la primera corrida se detuvo en vez de dar siete "ok" falsos.
     **Lo que ya no bloquea al rol `cliente` en el agente es RLS**, que quedó comprobada; lo
     que queda es que no existe el portal y que el agente se limita a admin por el saldo de
     la API.
   - **`rol = 'cliente'` sin `cliente_id` era posible** y había un perfil así. La pantalla
     Usuarios ya lo impedía ("Un usuario con rol cliente necesita tener un cliente
     asignado"), pero la validación vivía solo en el navegador y ese perfil se creó desde
     el Table Editor. Con la columna en null la cuenta **no ve nada**: falla cerrada, que
     para la seguridad está bien, pero el día del portal sería una pantalla en blanco y el
     error no estaría donde se busca. `34_cliente_necesita_cliente_id.sql` lo vuelve un
     `check` de la base, en los dos sentidos (y suelta el `cliente_id` de quien no es
     cliente). **Lección:** una regla que solo vive en el formulario no existe para quien
     entra por el Table Editor o por la API.
   - Opción limpia a futuro: mover `costo` a una tabla solo-admin
     (`productos_costos`) y dar al técnico lectura de `productos`. Así todas las
     vistas quedan en invoker, sin `mi_rol()` en cada una y sin el aviso del
     asesor. Toca Inventario, Cotizaciones y el agente: hacerlo con calma.
   - ~~RLS de citas y órdenes del técnico.~~ Hecho con la 13 (1e): se quitaron las
     políticas de escritura. ~~Falta restringir escritura en `catalogos` y `auditoria`.~~
     **Aplicada y probada el 27/09/2026** (`35_cerrar_escritura.sql` y
     `35_prueba_cerrar_escritura.sql`; 10 de 10 "ok": el técnico lee `catalogos` pero no la
     modifica ni la borra, no ve ni altera `auditoria`, el admin sí mantiene el catálogo y sí
     lee la auditoría, quedan 0 políticas de escritura con la condición en `true` y 0
     privilegios de `anon` en el esquema público).
     Lo que la foto del esquema destapó al ir a arreglarlo:
     · **`catalogos`** tenía tres políticas para `authenticated` sin comprobar rol
       (`select/insert/update` con la condición en `true`), o sea que un técnico, un
       almacenista, un cliente o una cuenta `sin_rol` podían insertar y modificar. Y el
       código **no usa esa tabla** (no aparece en `src/` ni en las Edge Functions): era
       superficie de ataque sin nada a cambio. Ahora leer sigue abierto y escribir pide
       `es_admin()`.
     · **`auditoria`** tenía `todos_escriben_auditoria` (`insert with check (true)`):
       cualquier cuenta autenticada podía **inventar renglones de auditoría**. No hacía
       falta para nada, porque lo único que escribe ahí es `_apunta`, que es security
       definer y ya está revocada a PUBLIC. Leer ya era solo del admin y no había update ni
       delete, que es lo que más importa: un rastro que se puede editar no es rastro.
     · **`anon` tenía TODOS los privilegios sobre las 11 tablas del esquema original**
       (auditoria, catalogos, citas, clientes, cotizaciones, datos_fiscales, equipos,
       movimientos_inventario, ordenes_servicio, perfiles, productos). Las tablas creadas
       desde la 14 sí llevan su revoke, y las vistas también (04): estas once se quedaron
       atrás. **Con precisión: hoy no es una puerta abierta** — `select`, `insert`, `update`
       y `delete` sí pasan por RLS y ninguna política es `to anon`, así que una petición
       anónima no toca una fila. Pero **`truncate` no pasa por RLS** (es la única operación
       que se le escapa) y `references`/`trigger` no son cosa de un rol público. No es
       alcanzable por la API (PostgREST nunca emite un `truncate`) ni se puede abrir sesión
       como `anon`, que es `nologin`: es un privilegio de más, no un agujero. Se quita
       porque contradice la doctrina del proyecto — si lo que protege es RLS, entonces lo
       que RLS no cubre no puede estar concedido.
     **Ojo con las tablas futuras:** Supabase tiene `alter default privileges` que vuelve a
     conceder a `anon` en cada tabla nueva, así que el script de cada tabla nueva tiene que
     traer su propio revoke.
   - Probar las pantallas con una cuenta de técnico (Agenda, Órdenes) y, cuando
     exista el portal, con una de cliente. El agente es solo de admin.
2. **Confiabilidad del campo**
   - ~~Que se vea por qué una orden no sube.~~ Hecho: cada orden en cola lleva
     `sync` (motivo en español, si es temporal, intentos), se muestra en "Pendientes
     por subir" y se reintenta cada minuto. `sync` se quita antes del insert. Los
     motivos salen de `src/lib/errores.js`; ahí se agregan casos nuevos. Probado por
     Caña el 19/09/2026 (una orden con fotos subió de punta a punta tras arreglar el
     bucket). Sin probar aún con una cuenta de técnico real: señal mala y permiso
     denegado.
   - ~~PWA: que Órdenes abra al recargar sin señal.~~ Hecho y publicado; probado por
     Caña el 19/09/2026 ("quedó bien"). Sin probar de forma explícita: recargar
     sin señal **con el token ya vencido** (más de 1 h). Service worker propio (`sw/plantilla.js`, generado a
     `dist/sw.js` por un plugin en `vite.config.js`), `manifest.webmanifest` y
     sesión/perfil guardados en el celular (`src/lib/local.js`). Ver "Sin señal".
     Íconos PNG (192, 512, maskable 512 y `apple-touch-icon` de 180 para iPhone)
     generados desde `public/icono.svg`, que es un **marcador** (hexágono ámbar con P
     sobre azul noche): sustituir por el logotipo real de `POWERMX-sitio/LOGOS` en la
     pasada de diseño, regenerando los cuatro PNG. Las pantallas distintas de Órdenes
     siguen necesitando red (Agenda, etc.).
   - ~~Cambio de estado de cotización + inventario en una sola operación.~~ Hecho
     (`supabase/sql/07_cotizacion_estado.sql`, función `cambiar_estado_cotizacion`;
     `Cotizaciones.jsx` la llama con `supabase.rpc`). Corrido y probado en la base el
     19/09/2026 como admin: aceptar aparta, rechazar libera en la misma cantidad, el
     estado vuelve a cambiar y quien no es admin es rechazado. Los movimientos
     anteriores a la función tienen `usuario` vacío: los hacía el código viejo del CRM.
   - **Requisiciones de pedido** (`supabase/sql/08_requisiciones.sql`, `Requisiciones.jsx`):
     escrito, **falta correr el SQL y probarlo**. Reemplaza la pregunta "¿aceptar de
     todos modos?" por la generación automática de la requisición. Pendiente para
     después: entregas parciales (hoy se recibe la cantidad completa; una parcial se
     resuelve con una `entrada` en Inventario y cancelando la línea), una herramienta
     de solo lectura del agente para consultar requisiciones, e indicador de
     pendientes en el menú.
     **Orden de despliegue de cualquier función nueva: primero el SQL, después el
     código que la llama.**
   - Recuperar el esquema base (`clientes`, `equipos`, `citas`, `ordenes_servicio`,
     `cotizaciones`, `movimientos_inventario`, `auditoria`, `datos_fiscales`: ninguna se
     crea en el repo) para poder reconstruir la base desde cero. Herramienta escrita el
     26/09/2026: ver "Foto del esquema" abajo. **Falta que Caña corra el script.**
3. **Diseño** (ver sección Diseño): ~~tokens y componentes compartidos → Órdenes →
   `Login` → Agenda → oficina~~ hecho. ~~Dividir el bundle por pantalla.~~ Hecho el
   21/09/2026 (ver "Paquetes por pantalla" abajo). Además: quitar `react-router-dom`
   si no se va a usar; y
   `signOut()` sin señal no cierra la sesión local (supabase-js devuelve el error de
   red sin borrarla): decidir si "Salir" debe funcionar desconectado.
4. **Agente fase 3:** escritura con confirmación explícita y registro en `auditoria`.
   ~~Instalar la CLI de Supabase para dejar de pegar la función a mano.~~ Hecha el
   22/09/2026 (ver "Agente").
5. **Portal del cliente** (solo tras la fase 1): equipos, historial y cotizaciones.
6. **Integraciones:** Google Calendar y correo; luego Facturama (CFDI 4.0).
7. **Calidad:** ~~pruebas mínimas de lo que dinero e inventario tocan (totales de
   cotización, disponible, cola offline)~~ hecho el 26/09/2026 (ver "Pruebas" abajo).
   Falta reescribir el README.

**Envío de refacciones en línea** (al final, junto con Mercado Pago; anotado 20/09/2026)
- Un solo precio público por refacción, igual en mostrador, sitio y cotizaciones.
  Lo que cuesta vender en línea (comisión de MP, empaque, paquetería) se cubre
  con el cargo de envío. Recoger en tienda: sin cargo.
- **El cargo no es un porcentaje sobre el pedido:** la paquetería cobra por peso,
  volumen y zona, no por el valor (una pieza cara y ligera pagaría de más; un aceite
  o una batería pesados no cubrirían su envío). Dos partes:
  - **Paquetería:** por zona y rango de peso, con mínimo y, si se quiere, envío
    gratis a partir de cierto monto. Pide `peso_kg` por producto (puede ir en
    `atributos jsonb`).
  - **Comisión de MP:** un porcentaje pequeño sobre el total, **por definir**.
  Tabla propia `tarifas_envio` (zona, rango de peso, monto), solo admin escribe.
  No mezclarla con `tarifas_servicio` (traslado de técnicos). Alternativa simple si
  no se captura el peso: tabla de zona × rango de monto, sin porcentaje.
- **El sitio no lee la tabla directo:** sale por la misma función pública del catálogo
  (columnas seguras, sin acceso `anon` a la tabla).
- **El Worker de Mercado Pago recalcula todo:** el navegador solo manda SKUs y
  cantidades; el Worker toma precio, disponible (nunca el físico) y tarifa de envío
  del CRM y calcula el cobro. Hoy `carrito.js` arma el pedido con precios del
  navegador: no confiar en ellos.
- Definir antes: si el envío se reembolsa en devoluciones (verificar en la cuenta de MP
  si devuelve su comisión al reembolsar; normalmente no), y que el CFDI lo lleve
  como concepto aparte (Facturama).
- Depende de activar Mercado Pago: `WORKER_URL` vacío en `carrito.js`. Las
  credenciales de MP ya las tiene Caña.
- Mientras tanto, refacciones se cotizan por WhatsApp y el envío se suma a mano.

## Pendientes de datos

- Capturar 49 precios de refacciones y todos los costos; conteo físico real
  (el 5 que traen muchos productos es relleno de la plantilla).
- Claves del SAT por producto.
- SKUs a corregir: `22676` y `99727` (les falta el cero inicial), `REF-FILTRO-CAT-001`
  (datos del ejemplo original), `LIQ-34` contra la foto `LIQ-32.jpg`.
- Que `convertir.js` del sitio lea del CRM en vez del Excel.
- Decisión (19/09/2026): el agente es **solo para admin** (`PANTALLAS.agente` en
  `App.jsx`) para cuidar el saldo de la API. La función igual acepta al técnico por
  llamada directa; el costo solo sale si el rol es `admin`. Si algún día se abre al
  técnico, probar antes que no dé costos ni cotizaciones.

## Cotizador de preventivos (SQL 28, 25/09/2026)

Cómo lo quiso Caña: el precio de **mantenimiento menor y mayor es FIJO**, tabulado por
**clase y capacidad** (no es una fórmula como el diagnóstico). El cliente ve **un solo
precio** y las refacciones van incluidas, pero por dentro **sí apartan inventario**. Lo que
cambia de un equipo a otro no es el precio sino **qué código se usa**: hay material genérico
que sirve igual.

**Eso salió gratis.** Apartar inventario y armar la lista del almacén (SQL 14) solo miran
`producto_id` y `cantidad` — **el precio nunca entra**. Así que la refacción entra como
partida normal con `precio_unitario: 0` y la marca `incluida`, se aparta igual y llega al
almacén, **sin tocar una línea** de `cambiar_estado_cotizacion` ni del almacén. En la lista
de partidas se marca "Incluida en el servicio": una pieza a $0 sin etiqueta parecería un
precio que se olvidó capturar.

- **`tarifas_servicio`** gana los conceptos `preventivo_menor` y `preventivo_mayor` (la 21 ya
  daba SKU propio, clase y tramo opcionales). `preventivo` a secas se queda para lo viejo.
- **`productos.grupo_equivalente`**: una etiqueta que se escribe igual en el original y en el
  genérico, y con eso son intercambiables. Una columna, no un catálogo de equivalencias: más
  fácil de capturar y de entender. Se edita en Inventario → Catálogo, por renglón; vacía se
  guarda como **null**, o todos los productos sin grupo se agruparían entre sí.
- **`paquetes_mantenimiento` + `paquete_lineas`**: qué lleva un preventivo. General (clase +
  tramo) o del **modelo exacto**, y al buscar **gana el específico**. Se capturan en Tarifas.
- **`paquete_preventivo(equipo, tipo)`** devuelve el precio fijo y cada línea con **todos los
  códigos que sirven y cuánto hay de cada uno**. Cuando no se puede cotizar dice **por qué,
  en palabras** ("captura el combustible", "no hay tarifa para esa clase") y **nunca inventa
  un precio**.
- `src/lib/preventivo.js`: `opcionSugerida` (la preferida si alcanza, si no la que tenga con
  qué cumplir), `problemasDelPaquete`, `faltantes` (avisa qué habrá que pedir; no bloquea,
  porque al aceptar la cotización se genera la requisición sola) y `partidasDePreventivo`.
  24 casos en Node.
- Probado de punta a punta en el emulador: crear paquete → agregarle una pieza → cotizar.
  Salió servicio $4,500 + refacción $0 marcada como incluida, total $5,220 (solo IVA sobre el
  servicio). 0 textos < 17 px, 0 contrastes < 4.5, 0 objetivos < 48 px, 0 px de desborde.
- **Falta (fase 5):** que el paquete se aprenda de lo que de verdad se usó en visitas
  anteriores. Ya tiene de dónde: `orden_surtido.cantidad_usada` guarda las piezas
  estructuradas desde la 18.

## Fase 5 · el paquete se aprende y precarga el surtido (SQL 29, 25/09/2026)

**SQL aplicado y probado** (10 pasos con rollback, todos "ok"). Las dos cosas que el plan
dejó para el final porque exigían que las piezas usadas quedaran estructuradas (la 18).

- **`surtido_desde_paquete(orden, tipo)`** llena la lista del almacén con el paquete del
  equipo. Hace falta porque **una cita de póliza abre orden sin cotización**, y la lista se
  armaba de las partidas de la cotización aceptada: el almacén no tenía nada que preparar.
  De cada línea toma el código con **más existencia** (puede proponer el genérico en vez del
  original); lo que ya estaba **no se toca**, así que llamarla dos veces no duplica ni pisa
  lo que el almacén ajustó a mano. Avisa qué línea quedó fuera por no tener códigos.
- **`piezas_que_se_repiten(...)`** mira las órdenes **cerradas** de equipos parecidos (clase
  y tramo, o marca y modelo) y cuenta **en cuántas VISITAS apareció** cada pieza, no cuántas
  piezas salieron. Esa distinción es el fondo del asunto: una pieza en 9 de 10 visitas es
  parte del mantenimiento; 20 piezas en una sola visita fue una reparación. Por eso devuelve
  también `de_visitas`, y `queTanSeguido()` lo traduce ("casi siempre", "seguido", "de vez
  en cuando", "todavía son pocas" con menos de 3 visitas). **Propone; no decide.**
- **Fallo de diseño corregido al escribirlo:** la primera versión hacía que
  `surtido_desde_paquete` llamara a `paquete_preventivo`. Eso revienta con el almacenista
  —esa función exige `es_admin()`— y aflojarle el permiso **le habría abierto los precios**,
  que es justo lo que el sistema promete que nunca ve. La parte común (qué códigos sirven y
  cuánto hay) se sacó a `_paquete_de_equipo` y `_codigos_de_linea`, **sin precio**, y
  `paquete_preventivo` les agrega el precio encima. Por eso la 29 **redefine** esa función
  de la 28: una sola lógica, dos puertas con permisos distintos. El paso 10 de la prueba
  comprueba exactamente eso.
- **Tropiezos de la prueba:** `orden_surtido_uso_no_excede` (18) impide declarar uso sin
  entrega, así que un histórico de prueba tiene que entregar antes de usar; y el almacenista
  **no puede crear órdenes**, así que las suyas se crean en la preparación.
- **Pantallas:** en Almacén, cuando una orden no trae piezas salen "Preparar mantenimiento
  menor / mayor"; en Tarifas, cada paquete tiene "¿Qué se ha usado en equipos así?" con las
  piezas, su frecuencia en palabras y la cantidad típica, y un botón para agregarlas.
  10 casos en Node; medido en celular: 0 textos < 17 px, 0 contrastes < 4.5, 0 objetivos <
  48 px, 0 px de desborde.

## ERP · F1: finanzas, CFDI y pago a técnicos (SQL 66–67, 09/10/2026) — escrito, falta correrlo

**Decisiones de Caña (09/10/2026) que mandan el diseño:**
- **RESICO persona física (626) con IVA mensual.** ISR sobre lo COBRADO e IVA por flujo de efectivo:
  un movimiento se fecha el día que se pagó o cobró, no el de la factura. "Deducible" no aplica en
  RESICO; lo que importa es si el IVA es **acreditable** (con CFDI y pagado). Tasas y límite anual:
  validarlas con el contador antes de construir el reporte (F3).
- **Lo personal NO vive en el CRM** (BBVA es personal; Banorte, el negocio). Solo existen
  `retiro_dueno` (egreso) y `aportacion` (ingreso), que **no** cuentan como gasto ni ingreso del negocio.
- **Técnicos sin alta en el IMSS, pago fijo por tipo de servicio.** No hay nómina legal (ISR, IMSS,
  aguinaldo, timbrado): es control interno. `tecnicos_pago` ya guarda esquema y `alta_imss` por si un día
  hace falta. Riesgo laboral y cómo se documenta el pago: pendiente con el contador.
- **Facturas desde el portal del SAT** (sin PAC). El CRM recibe el XML. Para timbrar desde el CRM hace
  falta un PAC + CSD + claves SAT de productos y servicios + complemento de pago si es PPD.
- **Contador con el software del SAT:** el entregable será un paquete mensual (resumen + XML), no pólizas.
- Dutton queda fuera. ~50 documentos de gasto al mes.

**SQL 66 — pago a técnicos.** `tecnicos_pago`, `tarifas_pago_tecnico` (tipo de servicio × rol
responsable/ayudante, general o por persona, con vigencia: cambiar un monto = tarifa nueva con fecha),
`pagos_tecnico` (propuesto → aprobado → pagado | cancelado; un solo borrador por técnico) y
`pagos_tecnico_lineas` (copian la tarifa del momento; **una orden se paga una vez por técnico**, índice
único sobre líneas activas). `proponer_pago_tecnico` junta órdenes CERRADAS sin pagar; **sin tarifa no se
paga ni se inventa**, se avisa. `ajustar_` (bono/descuento/anticipo), `quitar_linea_`, `aprobar_`,
`cancelar_` y `por_pagar_tecnicos()`. Prueba: `66_prueba_pago_tecnicos.sql` (10 pasos).

**SQL 67 — libro único, documentos, CFDI y comisiones.**
- `expediente_movimientos` **es el libro único**: `cotizacion_id` ya es opcional (gastos generales) y gana
  `cuenta_id`, `cfdi_id`, `documento_id`, `compra_id`. Categorías nuevas (material, herramienta, renta,
  servicios, software, comisiones bancarias, impuestos, publicidad, pago a proveedor, retiro, aportación,
  otro ingreso) con restricciones con nombre; **un cobro siempre lleva cotización** (la cobranza y la
  utilidad cuelgan de ahí). El Expediente de una cotización no cambia: solo suma su `cotizacion_id`.
  **Costo del trabajo ≠ flujo de caja:** pagar la factura de un proveedor es `pago_proveedor` sin
  cotización; el material ya se cuenta en la utilidad por `productos.costo`.
- `empresa_fiscal` (una fila: tu RFC; **decide el sentido** de un CFDI y rechaza los que no son tuyos),
  `cuentas_financieras` (siembra Banorte negocio y Efectivo), `cfdi` (UUID único, en minúsculas),
  `documentos` (bandeja y bitácora: huella SHA-256 única, lo extraído, la propuesta, la corrección del
  admin, quién aprobó) y `reglas_clasificacion` (RFC del proveedor → categoría, aprendida al aprobar).
  CFDI y documentos **no se borran** desde el CRM (sin política de delete).
- `registrar_documento`, `registrar_cfdi`, `aprobar_documento` (gasto pagado → movimiento; "aún no la
  pago" → sin movimiento, queda por pagar para la F4; archivar → solo respaldo), `rechazar_documento`,
  `sugerir_cotizaciones_para_cfdi` y `ligar_cfdi_cotizacion` (facturas emitidas).
- `registrar_pago_tecnico` se **reemplaza** (6 argumentos, con `p_cuenta`): además de cargar al expediente
  de cada cotización, carga al libro general lo que no tiene cotización (pólizas, bonos, descuentos).
- **`mis_comisiones()`** (técnico, solo lo suyo por `auth.uid()`): orden cerrada = "En revisión" **sin
  monto**; con el pago aprobado = "Aprobada" con su monto; registrado = "Pagada". Bonos y descuentos
  aprobados también se ven. Nunca precios ni datos de la cotización.
- Bucket `finanzas` acepta XML. Prueba: `67_prueba_libro_financiero.sql` (12 pasos).

**Orden para ponerlo en marcha:** `68_registro_migraciones.sql` (de otra sesión; los 64–67 terminan con su
registro) → `66` y su prueba → `67` y su prueba → publicar el CRM → Finanzas → Ajustes: capturar el RFC
→ Pago a técnicos → Tarifas: capturar los montos (y decidir si el ayudante cobra).

**Pantallas (construidas y medidas en el emulador con un Supabase falso; sin ver contra la base real):**
- **Finanzas** (área nueva, admin): *Por revisar* — zona para soltar varios archivos; el XML se lee **en el
  navegador sin IA** (`src/lib/cfdi.js`); PDF y fotos se leen con IA bajo pedido (reusa
  `leer-comprobante` modo ticket). Cada tarjeta propone categoría con su **confianza en palabra**
  (Seguro / Revisa / Elige tú, según CÓMO se decidió: regla aprendida, clave SAT o palabras) y con
  confianza alta se aprueba **con un toque**. Avisos: no cuadra, PPD, moneda extranjera, retenciones.
  *Libro del mes* — ingresos, gastos, resultado e IVA acreditable (solo gastos con CFDI), retiros y
  aportaciones aparte, desglose por categoría y movimientos sin documento. *Ajustes* — RFC y cuentas.
- **Pago a técnicos** (admin): Por pagar (armar el pago por periodo) · Pagos (bonos, quitar, aprobar,
  registrar con cuenta, cancelar con motivo) · Tarifas.
- **Comisiones** (técnico; su barra queda Agenda · Órdenes · Comisiones): por cobrar, pagado este mes,
  en revisión; filtros por estado; agrupado por mes; copia local `cache_comisiones` para verlas sin señal
  (probado apagando el falso: muestra lo guardado con aviso).
- Medido en celular (375 px): 0 textos < 17 px, 0 contrastes < 4.5, 0 objetivos < 48 px, 0 px de
  desborde en las tres pantallas y todas sus pestañas. Pruebas en Node: `cfdi` (10), `finanzas` (19),
  `comisiones` (6); `npm test` 484, lint y build en verde.
- **linkedom no soporta `getElementsByTagName('*')` en XML**: el lector recorre `childNodes` (igual en el
  navegador).
- Patrones de otros CRM del giro que se adoptaron: estado de la comisión separado del de la orden
  ("cerrada" no es "aprobada para pago"), bonos y descuentos visibles como en ServiceTitan, y mostrar
  solo lo que la tarea necesita (las tarjetas seguras van plegadas).
- **Falta (F2–F3):** contar documentos por revisar y pagos por aprobar en Inicio y en los globos;
  ZIP del SAT (hoy se eligen los XML sueltos); cuentas por pagar con los CFDI aprobados sin movimiento;
  el reporte mensual RESICO y el paquete para el contador.
