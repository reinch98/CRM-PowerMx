import { useEffect, useState } from 'react'
import { supabase } from './lib/supabase'
import Login from './Login'
import Agenda from './Agenda'
import Clientes from './Clientes'
import Equipos from './Equipos'
import Ordenes from './Ordenes'
import Inventario from './Inventario'
import Cotizaciones from './Cotizaciones'
import Tecnicos from './Tecnicos'
import Agente from './Agente'

// Qué pantallas ve cada rol. El menú y el contenido salen de aquí, así que
// agregar una pantalla es agregar un renglón, no tocar el resto.
const PANTALLAS = {
  agenda:       { titulo: 'Agenda',       componente: Agenda,       roles: ['admin', 'tecnico'] },
  ordenes:      { titulo: 'Órdenes',      componente: Ordenes,      roles: ['admin', 'tecnico'] },
  clientes:     { titulo: 'Clientes',     componente: Clientes,     roles: ['admin'] },
  equipos:      { titulo: 'Equipos',      componente: Equipos,      roles: ['admin'] },
  inventario:   { titulo: 'Inventario',   componente: Inventario,   roles: ['admin'] },
  cotizaciones: { titulo: 'Cotizaciones', componente: Cotizaciones, roles: ['admin'] },
  usuarios:     { titulo: 'Usuarios',     componente: Tecnicos,     roles: ['admin'] },
  agente:       { titulo: 'Agente',       componente: Agente,       roles: ['admin'] },
}

export default function App() {
  const [sesion, setSesion] = useState(null)
  const [perfilCargado, setPerfil] = useState(null)
  const [cargando, setCargando] = useState(true)
  const [pantalla, setPantalla] = useState('agenda')

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSesion(data.session)
      setCargando(false)
    })
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => setSesion(s))
    return () => sub.subscription.unsubscribe()
  }, [])

  // El perfil trae el rol. Sin perfil no se dibuja menú: más vale no mostrar
  // nada que mostrar botones que van a tronar contra las políticas.
  useEffect(() => {
    if (!sesion) return
    let vigente = true
    supabase.from('perfiles').select('*').eq('id', sesion.user.id).maybeSingle()
      .then(({ data }) => { if (vigente) setPerfil(data) })
    return () => { vigente = false }
  }, [sesion])

  if (cargando) return <p style={{ padding: 20 }}>Cargando…</p>
  if (!sesion) return <Login />

  // Solo vale el perfil de la sesión actual: si alguien sale y entra otra
  // cuenta, no se dibuja por un instante el menú de la anterior.
  const perfil = perfilCargado?.id === sesion.user.id ? perfilCargado : null
  const rol = perfil?.rol
  const permitidas = Object.entries(PANTALLAS).filter(([, p]) => p.roles.includes(rol))

  const barra = (
    <div style={{
      padding: 10, background: '#eee', display: 'flex', gap: 8,
      alignItems: 'center', flexWrap: 'wrap', fontFamily: 'system-ui'
    }}>
      {permitidas.map(([clave, p]) => (
        <button
          key={clave}
          onClick={() => setPantalla(clave)}
          style={{
            padding: '6px 12px', cursor: 'pointer', borderRadius: 5,
            border: '1px solid #bbb',
            background: pantalla === clave ? '#333' : '#fff',
            color: pantalla === clave ? '#fff' : '#333'
          }}
        >
          {p.titulo}
        </button>
      ))}
      <span style={{ marginLeft: 'auto', fontSize: 13, color: '#555' }}>
        {perfil?.nombre || sesion.user.email}{rol && ` · ${rol}`}
      </span>
      <button onClick={() => supabase.auth.signOut()}>Salir</button>
    </div>
  )

  if (!perfil || rol === 'sin_rol' || perfil.activo === false) {
    return (
      <div>
        {barra}
        <div style={{ padding: 40, fontFamily: 'system-ui', maxWidth: 520 }}>
          <h2>Tu cuenta todavía no tiene permisos</h2>
          <p style={{ color: '#666' }}>
            {perfil?.activo === false
              ? 'Esta cuenta está desactivada. Pide que la reactiven.'
              : 'Entraste bien, pero falta que te asignen un rol. Avísale al administrador.'}
          </p>
        </div>
      </div>
    )
  }

  if (rol === 'cliente') {
    return (
      <div>
        {barra}
        <div style={{ padding: 40, fontFamily: 'system-ui', maxWidth: 520 }}>
          <h2>Portal del cliente</h2>
          <p style={{ color: '#666' }}>
            Tu cuenta ya quedó ligada. Las pantallas de equipos, historial de
            servicio y cotizaciones están en construcción.
          </p>
        </div>
      </div>
    )
  }

  // Si el rol no alcanza para la pantalla elegida, cae a la primera permitida.
  const clave = PANTALLAS[pantalla]?.roles.includes(rol) ? pantalla : permitidas[0]?.[0]
  const Actual = clave ? PANTALLAS[clave].componente : null

  return (
    <div>
      {barra}
      {Actual ? <Actual /> : <p style={{ padding: 20 }}>No hay pantallas disponibles para tu rol.</p>}
    </div>
  )
}
