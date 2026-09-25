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
Falta: probar contra la base real con cuentas de almacenista y técnico, y crear la cuenta del
almacenista (Authentication → Add user, luego rol "Almacenista" en Usuarios).

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
- **Orden de construcción:** (1) `contactos` y su pantalla — no depende de WhatsApp; (2) bandeja
  de conversaciones e identificación de números; (3) el agente propone citas `por_programar` y
  cotiza preventivos en borrador; (4) mensajes salientes por plantilla (confirmación, recordatorio,
  orden, cotización).
- **Lo lento no es el código:** la verificación del negocio en Meta, la aprobación de plantillas y
  un número dedicado que no esté activo en la app normal de WhatsApp tardan días o semanas.
  Conviene iniciar ese trámite antes que el código.

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

## Forma de trabajar y tropiezos conocidos

- La interfaz, los nombres y los comentarios van en español.
- Windows no distingue mayúsculas en nombres de archivo; Cloudflare sí. El archivo
  debe llamarse exactamente como su `import` (componentes en PascalCase). Para
  renombrar solo la mayúscula: `git mv` en dos pasos, pasando por un nombre temporal.
- Correr `npm run lint` y `npm run build` antes de cada push. El lint está en cero:
  si algo nuevo lo rompe, se arregla, no se ignora.
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
   - ~~Vistas por rol.~~ Hecho y probado el 19/09/2026 (`05_vistas_por_rol.sql`):
     técnico ve 95 en `disponibles` y `catalogo` y 0 en `productos`; una cuenta sin
     rol ve 0 en todo; los modos quedaron definer/invoker como se describe arriba.
     Falta probar con una cuenta de **cliente** real cuando exista el portal; hasta
     entonces el agente sigue rechazando ese rol.
   - Opción limpia a futuro: mover `costo` a una tabla solo-admin
     (`productos_costos`) y dar al técnico lectura de `productos`. Así todas las
     vistas quedan en invoker, sin `mi_rol()` en cada una y sin el aviso del
     asesor. Toca Inventario, Cotizaciones y el agente: hacerlo con calma.
   - ~~RLS de citas y órdenes del técnico.~~ Hecho con la 13 (1e): se quitaron las
     políticas de escritura. Falta restringir escritura en `catalogos` y `auditoria`.
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
   - Recuperar `supabase/sql/01_...` (esquema base, hoy ausente del repo) para poder
     reconstruir la base desde cero.
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
7. **Calidad:** pruebas mínimas de lo que dinero e inventario tocan (totales de
   cotización, disponible, cola offline); reescribir el README.

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
