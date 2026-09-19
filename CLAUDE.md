# CRM PowerMx

CRM propio de PowerMx (Mérida, Yucatán): generadores eléctricos y sistemas solares
fotovoltaicos. Instalación, mantenimiento, pólizas y venta de equipo y refacciones.
Lo desarrolla y sostiene Caña, solo, con unas 10 horas a la semana. Respuestas en
español, concisas, con el paso siguiente claro.

## Stack

- React + Vite, JSX sin TypeScript. Sin router: `App.jsx` tiene un mapa `PANTALLAS`
  con los roles que ve cada pantalla.
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

## Seguridad — lo más importante

- Storage: bucket `ordenes` (**minúscula**, privado; Storage distingue mayúsculas).
  Un bucket `Ordenes` con mayúscula rompió la subida de fotos y firmas hasta el
  19/09/2026. Políticas en `supabase/sql/06_storage_ordenes.sql`: solo admin y
  técnico ven, suben y actualizan; nadie borra desde el CRM.
- Roles en `perfiles`: `admin`, `tecnico`, `cliente`, `sin_rol`. Toda cuenta nueva
  entra como `sin_rol` (trigger) y el admin la promueve. Funciones SQL de apoyo:
  `mi_rol()`, `es_admin()`, `mi_cliente()`.
- RLS por rol en todas las tablas. El técnico lee clientes y equipos, ve y actualiza
  sus citas, crea y lee sus órdenes. **No** ve `productos`, `cotizaciones` ni
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
- No hay CLI de Supabase instalada: la función se despliega pegando el archivo en el
  editor web de Supabase. Al cambiarla, el archivo del repo y el de Supabase deben
  quedar iguales.
- Rechaza el rol `cliente`, historial de más de 40 turnos y preguntas de más de
  2,000 caracteres. El historial lo manda el navegador: no se le tiene fe.
- Siguientes fases: ver "Ruta de mejora".

## Diseño — pasada pendiente

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
- Objetivos táctiles de 48 px o más.
- Ningún estado se comunica solo con color: siempre con palabra o ícono.
- La marca entra por una barra superior azul noche con el hexágono ámbar.
- Hoy las pantallas usan estilos en línea. Orden de trabajo: primero tokens y
  componentes compartidos en un solo lugar, luego Órdenes (la pantalla de campo),
  luego Agenda, luego las de oficina.

## Pantallas

`Agenda` (calendario, mantenimientos por vencer) · `Ordenes` (móvil, funciona sin
señal: cola en localStorage, fotos encogidas en IndexedDB, firma en canvas, el `id`
lo genera el celular y el código `23505` significa "ya existía") · `Clientes` ·
`Equipos` · `Inventario` · `Cotizaciones` · `Requisiciones` (solo admin) ·
`Tecnicos` (pestaña "Usuarios") · `Agente` · `Login`. Las pantallas reciben la
prop `irA(clave)` de `App.jsx` para saltar a otra pantalla. El portal del cliente es un aviso de "en construcción".

## Sin señal (Órdenes)

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
- En `Ordenes` (offline) no usar nada que pida red para datos de la orden:
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
   - RLS: `with check` en `tecnico_actualiza_sus_citas` (que no reasigne la cita);
     en `tecnico_crea_ordenes` exigir `tecnico_id = auth.uid()` **solo después** de
     vaciar la cola offline de los celulares, o las órdenes con `tecnico_id` nulo
     se quedarían atoradas; restringir escritura en `catalogos` y `auditoria`.
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
3. **Diseño** (ver sección Diseño): tokens y componentes compartidos → Órdenes →
   Agenda → oficina. De paso: `Login` con estilo y marca; dividir el bundle
   (500 kB) con `import()` por pantalla; quitar `react-router-dom` si no se va a usar.
4. **Agente fase 3:** escritura con confirmación explícita y registro en `auditoria`.
   Instalar la CLI de Supabase para dejar de pegar la función a mano.
5. **Portal del cliente** (solo tras la fase 1): equipos, historial y cotizaciones.
6. **Integraciones:** Google Calendar y correo; luego Facturama (CFDI 4.0).
7. **Calidad:** pruebas mínimas de lo que dinero e inventario tocan (totales de
   cotización, disponible, cola offline); reescribir el README.

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
