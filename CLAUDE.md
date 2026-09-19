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
  `libera_apartado`.
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
`Equipos` · `Inventario` · `Cotizaciones` · `Tecnicos` (pestaña "Usuarios") ·
`Agente` · `Login`. El portal del cliente es un aviso de "en construcción".

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

## Ruta de mejora

Actualizada el 19/09/2026 tras una revisión completa del código. Con 10 horas a la
semana, el orden importa: cada fase cierra un riesgo antes de abrir funciones nuevas.

**Hecho en esa revisión:** `borrar()` de Clientes movido dentro del componente (no
refrescaba la lista); `tecnico_id` de las órdenes offline con `getSession()`; fechas
en hora local; cotización que sale de "aceptada" a cualquier estado libera el
apartado; candado real contra sincronizaciones dobles en Órdenes; agente cierra el
rol `cliente` y limita historial y pregunta; lint en cero.
**Por desplegar:** pegar `agente/index.ts` en el editor de Supabase.

1. **Cerrar seguridad de datos** (antes de cualquier portal de cliente)
   - Vistas por rol: `supabase/sql/05_vistas_por_rol.sql` (ya corrido una vez; la
     versión con `alter view ... security_invoker = off` y filtro en `catalogo`
     **falta correrla y probarla**). Prueba de técnico: existencias y catálogo
     iguales a las del admin, `productos_directo` en 0. Prueba de cliente/sin rol:
     todo en 0. Con eso, decidir si se quita el bloqueo del rol `cliente` en el
     agente (no hasta que exista el portal).
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
     motivos salen de `src/lib/errores.js`; ahí se agregan casos nuevos.
     Falta: probarlo en el celular con un técnico real (sin señal, señal mala, y
     una orden con permiso denegado).
   - PWA: manifest y service worker, para que Órdenes abra al recargar sin señal.
   - Cambio de estado de cotización + movimientos de inventario en **una** función
     RPC transaccional, no dos escrituras desde el navegador.
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
