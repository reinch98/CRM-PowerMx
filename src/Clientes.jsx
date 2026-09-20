import { useEffect, useState } from 'react'
import { supabase } from './lib/supabase'
import { Alerta } from './ui'

const vacio = {
  nombre: '', nombre_comercial: '', tipo_cliente: 'residencial',
  rfc: '', telefono: '', telefono_alterno: '', email: '',
  contacto_nombre: '', direccion: '', colonia: '', municipio: '',
  estado_geo: 'Yucatán', codigo_postal: '', zona: '',
  maps_url: '', referencias: '', origen: '', notas: '',
  distancia_km: ''
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

  async function borrar(id) {
    if (!confirm('¿Borrar este cliente?')) return
    const { error } = await supabase.from('clientes').delete().eq('id', id)
    if (error) setError(error.message)
    else cargar()
  }

  async function guardarKm(c, valor) {
    const km = valor === '' ? null : Number(valor)
    if (km === (c.distancia_km ?? null)) return          // no cambió: no se toca la base
    setError('')
    const { error } = await supabase.from('clientes').update({ distancia_km: km }).eq('id', c.id)
    if (error) return setError(error.message)
    cargar()
  }

  function cambiar(campo, valor) {
    setForm({ ...form, [campo]: valor })
  }

  async function guardar(e) {
    e.preventDefault()
    if (!form.nombre.trim()) { setError('El nombre es obligatorio'); return }
    setGuardando(true)
    setError('')
    // Postgres no acepta '' en una columna numérica: vacío se manda como null.
    const payload = { ...form, distancia_km: form.distancia_km === '' ? null : Number(form.distancia_km) }
    const { error } = await supabase.from('clientes').insert([payload])
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
    ['distancia_km', 'Distancia a la oficina (km, solo ida; para el traslado)'],
    ['referencias', 'Referencias'],
    ['origen', 'Origen'],
    ['notas', 'Notas']
  ]

  return (
    <div className="pagina">
      <h2>Clientes</h2>

      {error && <Alerta tipo="error">{error}</Alerta>}

      <details className="tarjeta">
        <summary className="resumen">＋ Agregar cliente</summary>
        <form onSubmit={guardar} style={{ maxWidth: 520, marginTop: 12 }}>
          <label className="campo">
            <span>Tipo de cliente</span>
            <select value={form.tipo_cliente} onChange={e => cambiar('tipo_cliente', e.target.value)}>
              <option value="residencial">Residencial</option>
              <option value="comercial">Comercial</option>
              <option value="industrial">Industrial</option>
              <option value="gobierno">Gobierno</option>
            </select>
          </label>

          {campos.map(([campo, etiqueta]) => (
            <label key={campo} className="campo">
              <span>{etiqueta}</span>
              <input
                type={campo === 'distancia_km' ? 'number' : 'text'}
                min={campo === 'distancia_km' ? 0 : undefined}
                step={campo === 'distancia_km' ? 'any' : undefined}
                value={form[campo]}
                onChange={e => cambiar(campo, e.target.value)}
              />
            </label>
          ))}

          <button type="submit" className="btn-primario" disabled={guardando}>
            {guardando ? 'Guardando…' : 'Guardar cliente'}
          </button>
        </form>
      </details>

      <h3>Registrados ({clientes.length})</h3>
      <div className="tabla-scroll">
        <table>
          <thead>
            <tr>
              <th>Nombre</th><th>Tipo</th><th>Teléfono</th><th>Zona</th><th>Municipio</th><th>Km</th><th></th>
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
                <td>
                  {/* Se guarda al salir del campo. Hace falta para el cargo de traslado. */}
                  <input
                    type="number" min="0" step="any" style={{ width: 96 }}
                    aria-label={`Distancia en km de ${c.nombre}`}
                    defaultValue={c.distancia_km ?? ''}
                    onBlur={e => guardarKm(c, e.target.value)}
                  />
                </td>
                <td><button className="btn-peligro" onClick={() => borrar(c.id)}>Borrar</button></td>
              </tr>
            ))}
            {clientes.length === 0 && (
              <tr><td colSpan={7} className="ayuda">Todavía no hay clientes.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}
