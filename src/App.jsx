import { lazy, Suspense, useEffect, useMemo, useState } from 'react'
import { supabase } from './lib/supabase'
import { leerLocal, escribirLocal, borrarLocal, usuarioLocal } from './lib/local'
import { Logo, Alerta } from './ui'
import Login from './Login'

// Cada pantalla es su propio paquete, que el celular descarga solo la primera vez que se
// abre: un técnico nunca baja el código de Cotizaciones, Tarifas o el Agente, ni un
// almacenista el de Contactos. Login se queda fuera de esto porque hace falta de
// inmediato, antes de saber quién entra.
const Inicio = lazy(() => import('./Inicio'))
const Agenda = lazy(() => import('./Agenda'))
const Clientes = lazy(() => import('./Clientes'))
const Contactos = lazy(() => import('./Contactos'))
const WhatsApp = lazy(() => import('./WhatsApp'))
const Solicitudes = lazy(() => import('./Solicitudes'))
const Equipos = lazy(() => import('./Equipos'))
const Trabajos = lazy(() => import('./Trabajos'))
const Almacen = lazy(() => import('./Almacen'))
const Inventario = lazy(() => import('./Inventario'))
const Cotizaciones = lazy(() => import('./Cotizaciones'))
const Requisiciones = lazy(() => import('./Requisiciones'))
const Compras = lazy(() => import('./Compras'))
const Proveedor = lazy(() => import('./Proveedor'))
const Tarifas = lazy(() => import('./Tarifas'))
const Tecnicos = lazy(() => import('./Tecnicos'))
const Agente = lazy(() => import('./Agente'))
const Finanzas = lazy(() => import('./Finanzas'))
const Tablero = lazy(() => import('./Tablero'))
const PagosTecnicos = lazy(() => import('./PagosTecnicos'))
const Comisiones = lazy(() => import('./Comisiones'))

// Qué pantallas ve cada rol. El menú y el contenido salen de aquí, así que
// agregar una pantalla es agregar un renglón, no tocar el resto.
const PANTALLAS = {
  inicio:       { titulo: 'Inicio',       componente: Inicio,       roles: ['admin'] },
  agenda:       { titulo: 'Agenda',       componente: Agenda,       roles: ['admin', 'tecnico'] },
  ordenes:      { titulo: 'Órdenes',      componente: Trabajos,     roles: ['admin', 'tecnico'] },
  almacen:      { titulo: 'Almacén',      componente: Almacen,      roles: ['admin', 'almacenista'] },
  clientes:     { titulo: 'Clientes',     componente: Clientes,     roles: ['admin'] },
  contactos:    { titulo: 'Contactos',    componente: Contactos,    roles: ['admin'] },
  solicitudes:  { titulo: 'Solicitudes',  componente: Solicitudes,  roles: ['admin'] },
  whatsapp:     { titulo: 'WhatsApp',     componente: WhatsApp,     roles: ['admin'] },
  equipos:      { titulo: 'Equipos',      componente: Equipos,      roles: ['admin'] },
  inventario:   { titulo: 'Inventario',   componente: Inventario,   roles: ['admin'] },
  cotizaciones: { titulo: 'Cotizaciones', componente: Cotizaciones, roles: ['admin'] },
  requisiciones:{ titulo: 'Pedidos',      componente: Requisiciones,roles: ['admin'] },
  compras:      { titulo: 'Compras',      componente: Compras,      roles: ['admin'] },
  proveedor:    { titulo: 'Proveedor',    componente: Proveedor,    roles: ['admin'] },
  tarifas:      { titulo: 'Precios',      componente: Tarifas,      roles: ['admin'] },
  usuarios:     { titulo: 'Usuarios',     componente: Tecnicos,     roles: ['admin'] },
  agente:       { titulo: 'Agente',       componente: Agente,       roles: ['admin'] },
  tablero:      { titulo: 'Tablero',      componente: Tablero,      roles: ['admin'] },
  finanzas:     { titulo: 'Finanzas',     componente: Finanzas,     roles: ['admin'] },
  pagos:        { titulo: 'Pago a técnicos', componente: PagosTecnicos, roles: ['admin'] },
  // Solo el técnico: el admin ve lo mismo, con montos y acciones, en "Pago a técnicos".
  comisiones:   { titulo: 'Comisiones',   componente: Comisiones,   roles: ['tecnico'] },
}

// ---------------------------------------------------------------------------
// Las pantallas repartidas en áreas. Catorce pestañas en una fila se volvían una tira que
// había que desplazar de lado — pero eso le pasa SOLO al admin: el técnico ve dos pantallas
// y el almacenista una.
//
// Por eso el primer nivel (los grupos) **solo aparece cuando hay más de un grupo visible**.
// Al técnico y al almacenista se les siguen mostrando sus pantallas directas, sin un toque de
// más: arreglarle la vista al admin no puede costarle un toque a quien trabaja bajo el sol.
// La regla es automática, no una lista de excepciones por rol.
//
// El orden es el del trabajo, no el alfabético: lo del día primero, lo que se toca una vez al
// mes al final.
// ---------------------------------------------------------------------------
const GRUPOS = [
  { clave: 'servicio', titulo: 'Servicio', pantallas: ['inicio', 'agenda', 'ordenes', 'comisiones'] },
  { clave: 'clientes', titulo: 'Clientes', pantallas: ['solicitudes', 'whatsapp', 'clientes', 'contactos', 'equipos'] },
  { clave: 'ventas',   titulo: 'Ventas',   pantallas: ['cotizaciones', 'tarifas'] },
  { clave: 'almacen',  titulo: 'Almacén',  pantallas: ['almacen', 'inventario', 'requisiciones', 'compras', 'proveedor'] },
  { clave: 'finanzas', titulo: 'Finanzas', pantallas: ['tablero', 'finanzas', 'pagos'] },
  { clave: 'ajustes',  titulo: 'Ajustes',  pantallas: ['usuarios', 'agente'] },
]

// El número de cosas que esperan en una pestaña. Sin nada pendiente no se dibuja: un globo en
// cero es ruido. Va con número y no con un punto de color, como todo estado del proyecto.
function Globo({ n }) {
  if (!n) return null
  return <span className="globo" aria-hidden="true">{n > 99 ? '99+' : n}</span>
}

// El globo es `aria-hidden` para que el lector no lea "Almacén 3" sin contexto; el botón lleva
// la frase completa.
const etiquetaConPendientes = (titulo, n) =>
  n ? `${titulo}: ${n} ${n === 1 ? 'pendiente' : 'pendientes'}` : titulo

// Los grupos que ese rol puede ver, ya con sus pantallas filtradas. Un grupo sin pantallas
// permitidas no se muestra.
function gruposDe(rol) {
  return GRUPOS
    .map(g => ({ ...g, pantallas: g.pantallas.filter(k => PANTALLAS[k]?.roles.includes(rol)) }))
    .filter(g => g.pantallas.length > 0)
}

const ETIQUETA_ROL = {
  admin: 'Administrador', tecnico: 'Técnico', almacenista: 'Almacén', cliente: 'Cliente', sin_rol: 'Sin permisos'
}

const CACHE_PERFIL = 'cache_perfil'

function Cargando({ texto = 'Cargando…' }) {
  return (
    <main className="centro" style={{ textAlign: 'center', paddingTop: 64 }}>
      <Logo tam={72} sobreClaro />
      <p style={{ marginTop: 16 }}>{texto}</p>
    </main>
  )
}

export default function App() {
  const [sesion, setSesion] = useState(null)
  const [perfilServidor, setPerfilServidor] = useState(null)   // { id, datos } lo último que dijo el servidor
  const [falloPerfil, setFalloPerfil] = useState(false)
  const [intento, setIntento] = useState(0)
  const [cargando, setCargando] = useState(true)
  // Sin señal el técnico llega a lo que puede usar: la agenda no funciona
  // desconectada, las órdenes sí.
  // El admin entra al Inicio, que dice qué está esperando. Para los demás no hace falta una
  // excepción: `inicio` es solo de admin, así que `clave` cae sola a su primera pantalla
  // permitida (el técnico a la Agenda, el almacenista a Almacén). Sin señal se entra directo a
  // Órdenes, que es la única que funciona desconectada.
  const [pantalla, setPantalla] = useState(() => (navigator.onLine ? 'inicio' : 'ordenes'))
  // Cuántas cosas esperan en cada pantalla. Sin esto, agrupar las catorce pantallas solo
  // acomoda; con esto la barra avisa. `{}` mientras no se sepa: un globo que no está no
  // estorba, y si la consulta falla la barra se dibuja igual.
  const [pendientes, setPendientes] = useState({})

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      if (data.session) {
        setSesion(data.session)
      } else {
        // Sin señal y con el token vencido, getSession() dice "nadie" aunque la
        // sesión sigue guardada. Se entra con lo guardado; cuando vuelva la
        // señal, Supabase renueva el token y esta sesión se reemplaza sola.
        const usuario = usuarioLocal()
        setSesion(usuario ? { user: usuario, sinConexion: true } : null)
      }
      setCargando(false)
    })
    const { data: sub } = supabase.auth.onAuthStateChange((evento, s) => {
      // Al arrancar sin señal este evento llega con null; getSession() de arriba
      // ya resolvió qué hacer, y pisarlo mandaría al Login.
      if (evento === 'INITIAL_SESSION' && !s) return
      if (evento === 'SIGNED_OUT') borrarLocal(CACHE_PERFIL)
      setSesion(s)
    })
    return () => sub.subscription.unsubscribe()
  }, [])

  const uid = sesion?.user.id

  // Copia del perfil guardada en el celular. Con ella la app abre al instante,
  // sin esperar a la red: con señal mala esa espera eran varios segundos de
  // pantalla en blanco o, peor, de un falso "no tienes permisos".
  const copia = useMemo(() => {
    const c = uid ? leerLocal(CACHE_PERFIL, null) : null
    return c?.id === uid ? c : null
  }, [uid])

  // El perfil trae el rol. Se pregunta al servidor por detrás para enterarse de
  // cambios; solo decide qué botones se ven, el servidor sigue aplicando los
  // permisos de verdad.
  useEffect(() => {
    if (!uid) return
    let vigente = true
    supabase.from('perfiles').select('*').eq('id', uid).maybeSingle()
      .then(({ data, error }) => {
        if (!vigente) return
        if (error) { setFalloPerfil(true); return }
        setFalloPerfil(false)
        if (data) escribirLocal(CACHE_PERFIL, data)
        else borrarLocal(CACHE_PERFIL)
        setPerfilServidor({ id: uid, datos: data })
      })
    return () => { vigente = false }
  }, [uid, intento])

  // El rol, antes de los returns de abajo, para poder decidir aquí si se piden los contadores.
  // OJO con el `?.` de `perfilServidor?.datos`: al arrancar, `perfilServidor` y `uid` son los
  // dos `undefined`, y `undefined === undefined` es CIERTO — sin él se leía `.datos` de null y
  // la app no arrancaba para nadie. Lint, build y las pruebas pasaban; lo atrapó abrirla.
  const rolTemprano = (perfilServidor?.id === uid ? perfilServidor?.datos : copia)?.rol

  // ---------------------------------------------------------------------------
  // Los contadores de la barra. UNA sola llamada (`pendientes_admin`), y **solo para el
  // admin**: es el único rol con áreas, y `App.jsx` ya documenta que una consulta con el
  // token vencido y sin señal se queda esperando la renovación —medido, 5.5 s—, así que no se
  // le agrega una al arranque del técnico por un adorno.
  //
  // Si falla (sin señal, o el SQL 40 todavía sin correr) se queda en `{}` y la barra se dibuja
  // sin globos. Un contador es un aviso, nunca un dato del que dependa el trabajo.
  //
  // Se vuelve a pedir al cambiar de pantalla: así, después de atender algo y salir de ahí, el
  // número baja solo.
  // ---------------------------------------------------------------------------
  useEffect(() => {
    if (rolTemprano !== 'admin') return
    let vigente = true
    supabase.rpc('pendientes_admin').then(({ data, error }) => {
      if (!vigente) return
      setPendientes(!error && data && typeof data === 'object' ? data : {})
    })
    return () => { vigente = false }
  }, [rolTemprano, pantalla])

  if (cargando) return <Cargando />
  if (!sesion) return <Login />

  // Solo vale el perfil de la sesión actual: si alguien sale y entra otra
  // cuenta, no se dibuja por un instante el menú de la anterior.
  const delServidor = perfilServidor?.id === uid ? perfilServidor : null
  const perfil = delServidor ? delServidor.datos : copia
  const resuelto = !!delServidor || !!copia

  if (!resuelto) {
    if (!falloPerfil) return <Cargando texto="Cargando tu cuenta…" />
    return (
      <main className="centro">
        <h2>No pude cargar tu cuenta</h2>
        <Alerta tipo="aviso">
          Parece que no hay señal y esta es la primera vez que entras en este celular.
          Conéctate una vez para descargar tu perfil.
        </Alerta>
        <div className="fila">
          <button className="btn-primario" onClick={() => { setFalloPerfil(false); setIntento(n => n + 1) }}>
            Reintentar
          </button>
          <button onClick={() => supabase.auth.signOut()}>Salir</button>
        </div>
      </main>
    )
  }

  const rol = perfil?.rol
  const permitidas = Object.entries(PANTALLAS).filter(([, p]) => p.roles.includes(rol))
  // Si el rol no alcanza para la pantalla elegida, cae a la primera permitida.
  const clave = PANTALLAS[pantalla]?.roles.includes(rol) ? pantalla : permitidas[0]?.[0]

  // El grupo abierto se deduce de la pantalla, no se guarda aparte: así `irA('requisiciones')`
  // desde Cotizaciones abre Almacén sin que nadie tenga que acordarse de mover también el grupo.
  const grupos = gruposDe(rol)
  const porGrupos = grupos.length > 1
  const grupoAbierto = grupos.find(g => g.pantallas.includes(clave)) ?? grupos[0]
  const enElGrupo = porGrupos ? grupoAbierto?.pantallas ?? [] : permitidas.map(([k]) => k)

  // El globo de un área es la suma de sus pantallas. Se filtra por rol aquí y no borrando el
  // estado dentro del efecto: los contadores son del admin, y si alguien cambia de cuenta sin
  // recargar, los de la anterior no se asoman.
  const pendientesDe = k => (rol === 'admin' ? pendientes[k] : 0) || 0
  const pendientesDelGrupo = g => g.pantallas.reduce((n, k) => n + pendientesDe(k), 0)

  const barra = (
    <header className="barra">
      <div className="barra-fila">
        <div className="marca"><Logo /> PowerMx</div>
        <div className="barra-usuario">
          <span>{perfil?.nombre || sesion.user.email}</span>
          {rol && <small>{ETIQUETA_ROL[rol] ?? rol}</small>}
        </div>
        <button onClick={() => supabase.auth.signOut()}>Salir</button>
      </div>
      {porGrupos && (
        <nav className="nav nav-grupos" aria-label="Áreas">
          {grupos.map(g => (
            <button key={g.clave} aria-pressed={g.clave === grupoAbierto?.clave}
              aria-label={etiquetaConPendientes(g.titulo, pendientesDelGrupo(g))}
              onClick={() => setPantalla(g.pantallas[0])}>
              {g.titulo}<Globo n={pendientesDelGrupo(g)} />
            </button>
          ))}
        </nav>
      )}
      {enElGrupo.length > 0 && (
        <nav className={porGrupos ? 'nav nav-pantallas' : 'nav'} aria-label="Pantallas">
          {enElGrupo.map(k => (
            <button key={k} onClick={() => setPantalla(k)} aria-current={k === clave ? 'page' : undefined}
              aria-label={etiquetaConPendientes(PANTALLAS[k].titulo, pendientesDe(k))}>
              {PANTALLAS[k].titulo}<Globo n={pendientesDe(k)} />
            </button>
          ))}
        </nav>
      )}
    </header>
  )

  if (!perfil || rol === 'sin_rol' || perfil.activo === false) {
    return (
      <>
        {barra}
        <main className="centro">
          <h2>Tu cuenta todavía no tiene permisos</h2>
          <Alerta tipo="info">
            {perfil?.activo === false
              ? 'Esta cuenta está desactivada. Pide que la reactiven.'
              : 'Entraste bien, pero falta que te asignen un rol. Avísale al administrador.'}
          </Alerta>
        </main>
      </>
    )
  }

  if (rol === 'cliente') {
    return (
      <>
        {barra}
        <main className="centro">
          <h2>Portal del cliente</h2>
          <Alerta tipo="info">
            Tu cuenta ya quedó ligada. Las pantallas de equipos, historial de
            servicio y cotizaciones están en construcción.
          </Alerta>
        </main>
      </>
    )
  }

  const Actual = clave ? PANTALLAS[clave].componente : null

  return (
    <>
      {barra}
      <main>
        {Actual ? (
          // El respaldo va sin <main> propio: ya estamos dentro del <main> de la app.
          <Suspense fallback={<div className="centro" style={{ textAlign: 'center', paddingTop: 48 }}>Cargando la pantalla…</div>}>
            <Actual irA={setPantalla} />
          </Suspense>
        ) : (
          <div className="centro"><Alerta tipo="info">No hay pantallas disponibles para tu rol.</Alerta></div>
        )}
      </main>
    </>
  )
}
