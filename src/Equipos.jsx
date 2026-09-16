import { useEffect, useState } from 'react'
import { supabase } from './lib/supabase'

// Campos que cambian según el tipo de equipo. Se guardan dentro de atributos (jsonb).
const ATRIBUTOS = {
  generador: [
    ['combustible', 'Combustible'],
    ['capacidad_tanque_l', 'Capacidad del tanque (L)'],
    ['tipo_arranque', 'Tipo de arranque'],
    ['tipo_transferencia', 'Tipo de transferencia']
  ],
  solar: [
    ['numero_paneles', 'Número de paneles'],
    ['marca_paneles', 'Marca de paneles'],
    ['modelo_paneles', 'Modelo de paneles'],
    ['potencia_panel_w', 'Potencia por panel (W)'],
    ['marca_inversor', 'Marca del inversor'],
    ['modelo_inversor', 'Modelo del inversor'],
    ['potencia_inversor_kw', 'Potencia del inversor (kW)'],
    ['numero_strings', 'Número de strings'],
    ['paneles_por_string', 'Paneles por string']
  ],
  bateria: [
    ['quimica', 'Química'],
    ['capacidad_kwh', 'Capacidad (kWh)'],
    ['voltaje', 'Voltaje'],
    ['modulos', 'Número de módulos'],
    ['profundidad_descarga', 'Profundidad de descarga (%)'],
    ['ciclos', 'Ciclos']
  ],
  otro: []
}

const vacio = {
  cliente_id: '',
  numero_serie: '',
  tipo: 'generador',
  marca: '',
  modelo: '',
  capacidad_kw: '',
  anio: '',
  fecha_instalacion: '',
  ubicacion_equipo: '',
  horas_uso: '',
  tipo_mantenimiento: '',
  frecuencia_meses: '',
  proximo_mantenimiento: '',
  en_poliza: false,
  estado: 'activo',
  numero_servicio_cfe: '',
  numero_medidor: '',
  notas: ''
}

// Columnas numéricas y de fecha: Postgres no acepta cadena vacía, hay que mandar null.
const NUMERICAS = ['capacidad_kw', 'anio', 'horas_uso', 'frecuencia_meses']
const FECHAS = ['fecha_instalacion', 'proximo_mantenimiento']

export default function Equipos() {
  const [clientes, setClientes] = useState([])
  const [equipos, setEquipos] = useState([])
  const [form, setForm] = useState(vacio)
  const [atributos, setAtributos] = useState({})
  const [guardando, setGuardando] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => { cargarClientes(); cargarEquipos() }, [])

  async function cargarClientes() {
    const { data, error } = await supabase
      .from('clientes')
      .select('id, nombre')
      .order('nombre')
    if (error) setError(error.message)
    else setClientes(data)
  }

  async function cargarEquipos() {
    const { data, error } = await supabase
      .from('equipos')
      .select('*, clientes(nombre)')
      .order('created_at', { ascending: false })
    if (error) setError(error.message)
    else setEquipos(data)
  }

  function cambiar(campo, valor) {
    setForm({ ...form, [campo]: valor })
  }

  function cambiarTipo(nuevoTipo) {
    setForm({ ...form, tipo: nuevoTipo })
    setAtributos({}) // los atributos del tipo anterior ya no aplican
  }

  function cambiarAtributo(campo, valor) {
    setAtributos({ ...atributos, [campo]: valor })
  }

  async function guardar(e) {
    e.preventDefault()
    if (!form.cliente_id) { setError('Elige un cliente'); return }
    if (!form.numero_serie.trim()) { setError('El número de serie es obligatorio'); return }

    // Limpia el payload: cadenas vacías -> null en numéricos y fechas.
    const payload = { ...form }
    for (const campo of [...NUMERICAS, ...FECHAS]) {
      if (payload[campo] === '') payload[campo] = null
    }

    // Los atributos vacíos no se guardan.
    const limpios = Object.fromEntries(
      Object.entries(atributos).filter(([, v]) => v !== '' && v != null)
    )
    payload.atributos = limpios

    setGuardando(true)
    setError('')
    const { error } = await supabase.from('equipos').insert([payload])
    setGuardando(false)

    if (error) setError(error.message)
    else {
      setForm(vacio)
      setAtributos({})
      cargarEquipos()
    }
  }

  async function borrar(id) {
    if (!confirm('¿Borrar este equipo?')) return
    const { error } = await supabase.from('equipos').delete().eq('id', id)
    if (error) setError(error.message)
    else cargarEquipos()
  }

  const camposTexto = [
    ['numero_serie', 'Número de serie *'],
    ['marca', 'Marca'],
    ['modelo', 'Modelo'],
    ['capacidad_kw', 'Capacidad (kW)'],
    ['anio', 'Año'],
    ['ubicacion_equipo', 'Ubicación del equipo'],
    ['horas_uso', 'Horas de uso'],
    ['tipo_mantenimiento', 'Tipo de mantenimiento'],
    ['frecuencia_meses', 'Frecuencia (meses)'],
    ['numero_servicio_cfe', 'Número de servicio CFE'],
    ['numero_medidor', 'Número de medidor'],
    ['notas', 'Notas']
  ]

  return (
    <div style={{ padding: 20, fontFamily: 'system-ui' }}>
      <h2>Equipos</h2>

      <form onSubmit={guardar} style={{ display: 'grid', gap: 8, maxWidth: 480, marginBottom: 32 }}>
        <label>
          Cliente *<br />
          <select
            value={form.cliente_id}
            onChange={e => cambiar('cliente_id', e.target.value)}
            style={{ width: '100%' }}
          >
            <option value="">— Elige un cliente —</option>
            {clientes.map(c => (
              <option key={c.id} value={c.id}>{c.nombre}</option>
            ))}
          </select>
        </label>

        <label>
          Tipo de equipo<br />
          <select value={form.tipo} onChange={e => cambiarTipo(e.target.value)}>
            <option value="generador">Generador</option>
            <option value="solar">Solar</option>
            <option value="bateria">Batería</option>
            <option value="otro">Otro</option>
          </select>
        </label>

        {camposTexto.map(([campo, etiqueta]) => (
          <label key={campo}>
            {etiqueta}<br />
            <input
              value={form[campo]}
              onChange={e => cambiar(campo, e.target.value)}
              style={{ width: '100%' }}
            />
          </label>
        ))}

        <label>
          Fecha de instalación<br />
          <input
            type="date"
            value={form.fecha_instalacion}
            onChange={e => cambiar('fecha_instalacion', e.target.value)}
          />
        </label>

        <label>
          Próximo mantenimiento<br />
          <input
            type="date"
            value={form.proximo_mantenimiento}
            onChange={e => cambiar('proximo_mantenimiento', e.target.value)}
          />
        </label>

        <label>
          <input
            type="checkbox"
            checked={form.en_poliza}
            onChange={e => cambiar('en_poliza', e.target.checked)}
          />
          {' '}En póliza
        </label>

        <label>
          Estado<br />
          <select value={form.estado} onChange={e => cambiar('estado', e.target.value)}>
            <option value="activo">Activo</option>
            <option value="baja">Baja</option>
            <option value="en_renta">En renta</option>
          </select>
        </label>

        {ATRIBUTOS[form.tipo].length > 0 && (
          <fieldset style={{ border: '1px solid #ccc', padding: 12 }}>
            <legend>Datos de {form.tipo}</legend>
            <div style={{ display: 'grid', gap: 8 }}>
              {ATRIBUTOS[form.tipo].map(([campo, etiqueta]) => (
                <label key={campo}>
                  {etiqueta}<br />
                  <input
                    value={atributos[campo] || ''}
                    onChange={e => cambiarAtributo(campo, e.target.value)}
                    style={{ width: '100%' }}
                  />
                </label>
              ))}
            </div>
          </fieldset>
        )}

        <button type="submit" disabled={guardando}>
          {guardando ? 'Guardando…' : 'Guardar equipo'}
        </button>
        {error && <p style={{ color: 'crimson' }}>{error}</p>}
      </form>

      <h3>Registrados ({equipos.length})</h3>
      <table border="1" cellPadding="6" style={{ borderCollapse: 'collapse' }}>
        <thead>
          <tr>
            <th>Número de serie</th>
            <th>Tipo</th>
            <th>Cliente</th>
            <th>Marca</th>
            <th>Modelo</th>
            <th>Próx. mtto.</th>
            <th>Póliza</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          {equipos.map(eq => (
            <tr key={eq.id}>
              <td>{eq.numero_serie}</td>
              <td>{eq.tipo}</td>
              <td>{eq.clientes?.nombre}</td>
              <td>{eq.marca}</td>
              <td>{eq.modelo}</td>
              <td>{eq.proximo_mantenimiento}</td>
              <td>{eq.en_poliza ? 'Sí' : 'No'}</td>
              <td><button onClick={() => borrar(eq.id)}>Borrar</button></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
