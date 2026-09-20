import { useState } from 'react'
import { supabase } from './lib/supabase'
import { Logo, Alerta } from './ui'

export default function Login() {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [entrando, setEntrando] = useState(false)

  async function entrar(e) {
    e.preventDefault()
    setError('')
    setEntrando(true)
    const { error } = await supabase.auth.signInWithPassword({ email, password })
    setEntrando(false)
    if (error) setError(error.message)
  }

  return (
    <main className="centro" style={{ paddingTop: 40 }}>
      <div style={{ textAlign: 'center', marginBottom: 20 }}>
        <Logo tam={80} sobreClaro />
        <h1 style={{ marginTop: 12 }}>PowerMx CRM</h1>
      </div>

      <form onSubmit={entrar} className="tarjeta">
        <label className="campo">
          <span>Correo</span>
          <input
            type="email" autoComplete="username" inputMode="email"
            value={email} onChange={e => setEmail(e.target.value)} required
          />
        </label>
        <label className="campo">
          <span>Contraseña</span>
          <input
            type="password" autoComplete="current-password"
            value={password} onChange={e => setPassword(e.target.value)} required
          />
        </label>

        {error && <Alerta tipo="error">{error}</Alerta>}

        <button type="submit" className="btn-primario btn-grande" disabled={entrando}>
          {entrando ? 'Entrando…' : 'Entrar'}
        </button>
      </form>
    </main>
  )
}
