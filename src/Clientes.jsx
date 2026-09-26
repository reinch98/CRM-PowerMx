import { useEffect, useState } from 'react'
import { supabase } from './lib/supabase'
import { aFormulario, paraGuardar } from './lib/formularios'
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
  const [editando, setEditando] = useState(null)   // id del cliente que se está editando
  const [abierto, setAbierto] = useState(false)

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

  // Editar reusa el MISMO formulario del alta: un campo nuevo se agrega una sola vez y
  // sirve para las dos cosas.
  function editar(c) {
    setForm(aFormulario(c, vacio))
    setEditando(c.id)
    setAbierto(true)
    setError('')
    window.scrollTo({ top: 0, behavior: 'smooth' })
  }

  function cancelar() {
    setForm(vacio); setEditando(null); setError('')
  }

  async function guardar(e) {
    e.preventDefault()
    if (!form.nombre.trim()) { setError('El nombre es obligatorio'); return }
    setGuardando(true)
    setError('')
    // Postgres no acepta '' en una columna numérica: vacío se manda como null.
    const payload = paraGuardar(form, { numericas: ['distancia_km'] })
    const { error } = editando
      ? await supabase.from('clientes').update(payload).eq('id', editando)
      : await supabase.from('clientes').insert([payload])
    setGuardando(false)
    if (error) setError(error.message)
    else { setForm(vacio); setEditando(null); setAbierto(false); cargar() }
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

      <details className="tarjeta" open={abierto}
        onToggle={e => { setAbierto(e.target.open); if (!e.target.open && editando) cancelar() }}>
        <summary className="resumen">
          {editando ? '✎ Editando un cliente' : '＋ Agregar cliente'}
        </summary>
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

          <div className="fila">
            <button type="submit" className="btn-primario" disabled={guardando}>
              {guardando ? 'Guardando…' : editando ? 'Guardar cambios' : 'Guardar cliente'}
            </button>
            {editando && <button type="button" onClick={cancelar}>Cancelar</button>}
          </div>
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
                <td>
                  <div className="fila">
                    <button onClick={() => editar(c)}>Editar</button>
                    <button className="btn-peligro" onClick={() => borrar(c.id)}>Borrar</button>
                  </div>
                </td>
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
