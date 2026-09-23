import { lazy, Suspense, useEffect, useMemo, useState } from 'react'
import { supabase } from './lib/supabase'
import { leerLocal, escribirLocal, borrarLocal, usuarioLocal } from './lib/local'
import { Logo, Alerta } from './ui'
import Login from './Login'

// Cada pantalla es su propio paquete, que el celular descarga solo la primera vez que se
// abre: un técnico nunca baja el código de Cotizaciones, Tarifas o el Agente, ni un
// almacenista el de Contactos. Login se queda fuera de esto porque hace falta de
// inmediato, antes de saber quién entra.
const Agenda = lazy(() => import('./Agenda'))
const Clientes = lazy(() => import('./Clientes'))
const Contactos = lazy(() => import('./Contactos'))
const WhatsApp = lazy(() => import('./WhatsApp'))
const Equipos = lazy(() => import('./Equipos'))
const Trabajos = lazy(() => import('./Trabajos'))
const Almacen = lazy(() => import('./Almacen'))
const Inventario = lazy(() => import('./Inventario'))
const Cotizaciones = lazy(() => import('./Cotizaciones'))
const Requisiciones = lazy(() => import('./Requisiciones'))
const Tarifas = lazy(() => import('./Tarifas'))
const Tecnicos = lazy(() => import('./Tecnicos'))
const Agente = lazy(() => import('./Agente'))

// Qué pantallas ve cada rol. El menú y el contenido salen de aquí, así que
// agregar una pantalla es agregar un renglón, no tocar el resto.
const PANTALLAS = {
  agenda:       { titulo: 'Agenda',       componente: Agenda,       roles: ['admin', 'tecnico'] },
  ordenes:      { titulo: 'Órdenes',      componente: Trabajos,     roles: ['admin', 'tecnico'] },
  almacen:      { titulo: 'Almacén',      componente: Almacen,      roles: ['admin', 'almacenista'] },
  clientes:     { titulo: 'Clientes',     componente: Clientes,     roles: ['admin'] },
  contactos:    { titulo: 'Contactos',    componente: Contactos,    roles: ['admin'] },
  whatsapp:     { titulo: 'WhatsApp',     componente: WhatsApp,     roles: ['admin'] },
  equipos:      { titulo: 'Equipos',      componente: Equipos,      roles: ['admin'] },
  inventario:   { titulo: 'Inventario',   componente: Inventario,   roles: ['admin'] },
  cotizaciones: { titulo: 'Cotizaciones', componente: Cotizaciones, roles: ['admin'] },
  requisiciones:{ titulo: 'Requisiciones',componente: Requisiciones,roles: ['admin'] },
  tarifas:      { titulo: 'Tarifas',      componente: Tarifas,      roles: ['admin'] },
  usuarios:     { titulo: 'Usuarios',     componente: Tecnicos,     roles: ['admin'] },
  agente:       { titulo: 'Agente',       componente: Agente,       roles: ['admin'] },
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
  const [pantalla, setPantalla] = useState(() => (navigator.onLine ? 'agenda' : 'ordenes'))

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
      {permitidas.length > 0 && (
        <nav className="nav" aria-label="Pantallas">
          {permitidas.map(([k, p]) => (
            <button key={k} onClick={() => setPantalla(k)} aria-current={k === clave ? 'page' : undefined}>
              {p.titulo}
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
