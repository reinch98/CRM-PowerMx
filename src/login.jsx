import { useState } from 'react'
import { supabase } from './lib/supabase'

export default function Login() {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')

  async function entrar(e) {
    e.preventDefault()
    setError('')
    const { error } = await supabase.auth.signInWithPassword({ email, password })
    if (error) setError(error.message)
  }

  return (
    <form onSubmit={entrar}>
      <h1>PowerMx CRM</h1>
      <input value={email} onChange={e => setEmail(e.target.value)} placeholder="Correo" />
      <input type="password" value={password} onChange={e => setPassword(e.target.value)} placeholder="Contraseña" />
      <button type="submit">Entrar</button>
      {error && <p>{error}</p>}
    </form>
  )
}