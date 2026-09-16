import { useEffect, useState } from 'react'
import { supabase } from './lib/supabase'
import Login from './Login'
import Clientes from './Clientes'
import Equipos from './Equipos'

export default function App() {
  const [sesion, setSesion] = useState(null)
  const [cargando, setCargando] = useState(true)
  const [pantalla, setPantalla] = useState('clientes')

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSesion(data.session)
      setCargando(false)
    })
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => setSesion(s))
    return () => sub.subscription.unsubscribe()
  }, [])

  if (cargando) return <p>Cargando…</p>
  if (!sesion) return <Login />

     return (
    <div>
      <div style={{ padding: 10, background: '#eee' }}>
        <button onClick={() => setPantalla('clientes')}>Clientes</button>
        <button onClick={() => setPantalla('equipos')} style={{ marginLeft: 8 }}>Equipos</button>
        <span style={{ marginLeft: 20 }}>{sesion.user.email}</span>
        <button onClick={() => supabase.auth.signOut()} style={{ marginLeft: 12 }}>Salir</button>
      </div>
      {pantalla === 'clientes' ? <Clientes /> : <Equipos />}
    </div>
  )
}