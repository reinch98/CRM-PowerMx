import { useEffect, useState } from 'react'
import { supabase } from './lib/supabase'

  async function borrar(id) {
    if (!confirm('¿Borrar este cliente?')) return
    const { error } = await supabase.from('clientes').delete().eq('id', id)
    if (error) setError(error.message)
    else cargar()
  }

const vacio = {
  nombre: '', nombre_comercial: '', tipo_cliente: 'residencial',
  rfc: '', telefono: '', telefono_alterno: '', email: '',
  contacto_nombre: '', direccion: '', colonia: '', municipio: '',
  estado_geo: 'Yucatán', codigo_postal: '', zona: '',
  maps_url: '', referencias: '', origen: '', notas: ''
}

export default function Clientes() {
  const [clientes, setClientes] = useState([])
  const [form, setForm] = useState(vacio)
  const [guardando, setGuardando] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => { cargar() }, [])

  async function cargar() {
    const { data, error } = await supabase
      .from('clientes')
      .select('*')
      .order('created_at', { ascending: false })
    if (error) setError(error.message)
    else setClientes(data)
  }

  function cambiar(campo, valor) {
    setForm({ ...form, [campo]: valor })
  }

  async function guardar(e) {
    e.preventDefault()
    if (!form.nombre.trim()) { setError('El nombre es obligatorio'); return }
    setGuardando(true)
    setError('')
    const { error } = await supabase.from('clientes').insert([form])
    setGuardando(false)
    if (error) setError(error.message)
    else { setForm(vacio); cargar() }
  }

  const campos = [
    ['nombre', 'Nombre *'],
    ['nombre_comercial', 'Nombre comercial'],
    ['rfc', 'RFC'],
    ['telefono', 'Teléfono'],
    ['telefono_alterno', 'Teléfono alterno'],
    ['email', 'Correo'],
    ['contacto_nombre', 'Persona de contacto'],
    ['direccion', 'Dirección'],
    ['colonia', 'Colonia'],
    ['municipio', 'Municipio'],
    ['estado_geo', 'Estado'],
    ['codigo_postal', 'Código postal'],
    ['zona', 'Zona'],
    ['maps_url', 'Enlace de Google Maps'],
    ['referencias', 'Referencias'],
    ['origen', 'Origen'],
    ['notas', 'Notas']
  ]

  return (
    <div style={{ padding: 20, fontFamily: 'system-ui' }}>
      <h2>Clientes</h2>

      <form onSubmit={guardar} style={{ display: 'grid', gap: 8, maxWidth: 480, marginBottom: 32 }}>
        <label>
          Tipo de cliente<br />
          <select value={form.tipo_cliente} onChange={e => cambiar('tipo_cliente', e.target.value)}>
            <option value="residencial">Residencial</option>
            <option value="comercial">Comercial</option>
            <option value="industrial">Industrial</option>
            <option value="gobierno">Gobierno</option>
          </select>
        </label>

        {campos.map(([campo, etiqueta]) => (
          <label key={campo}>
            {etiqueta}<br />
            <input
              value={form[campo]}
              onChange={e => cambiar(campo, e.target.value)}
              style={{ width: '100%' }}
            />
          </label>
        ))}

        <button type="submit" disabled={guardando}>
          {guardando ? 'Guardando…' : 'Guardar cliente'}
        </button>
        {error && <p style={{ color: 'crimson' }}>{error}</p>}
      </form>

      <h3>Registrados ({clientes.length})</h3>
      <table border="1" cellPadding="6" style={{ borderCollapse: 'collapse' }}>
        <thead>
          <tr>
            <th>Nombre</th><th>Tipo</th><th>Teléfono</th><th>Zona</th><th>Municipio</th><th></th>
          </tr>
        </thead>
        <tbody>
          {clientes.map(c => (
            <tr key={c.id}>
              <td>{c.nombre}</td>
              <td>{c.tipo_cliente}</td>
              <td>{c.telefono}</td>
              <td>{c.zona}</td>
              <td>{c.municipio}</td>
              <td><button onClick={() => borrar(c.id)}>Borrar</button></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}