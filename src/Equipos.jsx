import { useEffect, useState } from 'react'
import { supabase } from './lib/supabase'
import { Alerta } from './ui'
import { textoHorometro, cargarEquiposSinSerie } from './lib/equipoCampo'

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

// Campos de atributos que son una lista cerrada en vez de texto libre. El combustible
// decide la clase de precio del diagnóstico (gasolina, gas, diésel): escrito a mano
// ("Gas LP", "gas", "Diésel") no se podría calcular solo. Se guarda la clave.
const OPCIONES = {
  combustible: [
    ['gasolina', 'Gasolina'],
    ['gas_lp', 'Gas LP'],
    ['gas_natural', 'Gas natural'],
    ['diesel', 'Diésel']
  ]
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
  const [sinSerie, setSinSerie] = useState([])

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

    // La lista de "serie pendiente" va aquí dentro y no en su propia función: si
    // `cargarEquipos` llama a otra función del componente, deja de ser estable y el
    // efecto de arranque tendría que depender de ella.
    const r = await cargarEquiposSinSerie()
    if (r.ok) setSinSerie(r.equipos)
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
    // La serie ya NO es obligatoria (SQL 23): un equipo dado de alta en campo con la placa
    // borrada entra sin ella y queda en la lista de "serie pendiente". Pero algo tiene que
    // identificarlo, o nadie lo reconoce en la siguiente visita.
    if (!form.numero_serie.trim() && !form.marca.trim() && !form.modelo.trim() && !form.ubicacion_equipo.trim()) {
      setError('Sin número de serie, escribe al menos la marca, el modelo o dónde está el equipo')
      return
    }

    // Limpia el payload: cadenas vacías -> null en numéricos y fechas.
    const payload = { ...form }
    for (const campo of [...NUMERICAS, ...FECHAS]) {
      if (payload[campo] === '') payload[campo] = null
    }
    // La serie vacía tiene que irse como null, no como '': `equipos_sin_serie()` busca
    // nulos, y una cadena vacía además chocaría con la siguiente en el índice único.
    if (payload.numero_serie.trim() === '') payload.numero_serie = null

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
    ['numero_serie', 'Número de serie'],
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
    <div className="pagina">
      <h2>Equipos</h2>

      {error && <Alerta tipo="error">{error}</Alerta>}

      <details className="tarjeta">
        <summary className="resumen">＋ Agregar equipo</summary>
        <form onSubmit={guardar} style={{ maxWidth: 520, marginTop: 12 }}>
          <label className="campo">
            <span>Cliente *</span>
            <select value={form.cliente_id} onChange={e => cambiar('cliente_id', e.target.value)}>
              <option value="">— Elige un cliente —</option>
              {clientes.map(c => (
                <option key={c.id} value={c.id}>{c.nombre}</option>
              ))}
            </select>
          </label>

          <label className="campo">
            <span>Tipo de equipo</span>
            <select value={form.tipo} onChange={e => cambiarTipo(e.target.value)}>
              <option value="generador">Generador</option>
              <option value="solar">Solar</option>
              <option value="bateria">Batería</option>
              <option value="otro">Otro</option>
            </select>
          </label>

          {camposTexto.map(([campo, etiqueta]) => (
            <label key={campo} className="campo">
              <span>{etiqueta}</span>
              <input value={form[campo]} onChange={e => cambiar(campo, e.target.value)} />
            </label>
          ))}

          <label className="campo">
            <span>Fecha de instalación</span>
            <input type="date" value={form.fecha_instalacion}
              onChange={e => cambiar('fecha_instalacion', e.target.value)} />
          </label>

          <label className="campo">
            <span>Próximo mantenimiento</span>
            <input type="date" value={form.proximo_mantenimiento}
              onChange={e => cambiar('proximo_mantenimiento', e.target.value)} />
          </label>

          <label className="casilla">
            <input type="checkbox" checked={form.en_poliza}
              onChange={e => cambiar('en_poliza', e.target.checked)} />
            En póliza
          </label>

          <label className="campo">
            <span>Estado</span>
            <select value={form.estado} onChange={e => cambiar('estado', e.target.value)}>
              <option value="activo">Activo</option>
              <option value="baja">Baja</option>
              <option value="en_renta">En renta</option>
            </select>
          </label>

          {ATRIBUTOS[form.tipo].length > 0 && (
            <fieldset className="conjunto">
              <legend>Datos de {form.tipo}</legend>
              {ATRIBUTOS[form.tipo].map(([campo, etiqueta]) => (
                <label key={campo} className="campo">
                  <span>{etiqueta}</span>
                  {OPCIONES[campo] ? (
                    <select value={atributos[campo] || ''} onChange={e => cambiarAtributo(campo, e.target.value)}>
                      <option value="">— Elige —</option>
                      {OPCIONES[campo].map(([v, t]) => <option key={v} value={v}>{t}</option>)}
                    </select>
                  ) : (
                    <input value={atributos[campo] || ''} onChange={e => cambiarAtributo(campo, e.target.value)} />
                  )}
                </label>
              ))}
            </fieldset>
          )}

          <button type="submit" className="btn-primario" disabled={guardando}>
            {guardando ? 'Guardando…' : 'Guardar equipo'}
          </button>
        </form>
      </details>

      {/* Los que el técnico dio de alta en campo con la placa ilegible. La última visita
          dice a quién preguntarle por la serie. */}
      {sinSerie.length > 0 && (
        <section className="tarjeta">
          <h3>Les falta el número de serie ({sinSerie.length})</h3>
          <p className="ayuda">
            Se dieron de alta durante una visita sin poder leer la placa. Consigue la serie y
            complétala arriba; mientras tanto el equipo funciona igual para agendar y cotizar.
          </p>
          {sinSerie.map(s => (
            <div key={s.equipo_id} className="refaccion">
              <strong>{[s.marca, s.modelo].filter(Boolean).join(' ') || s.tipo}</strong>
              <span className="ayuda">
                {s.cliente}
                {s.capacidad_kw && ` · ${s.capacidad_kw} kW`}
                {s.ubicacion_equipo && ` · ${s.ubicacion_equipo}`}
              </span>
              <span className="ayuda">
                {s.ultima_orden
                  ? `Última visita: OS-${s.ultima_orden}${s.ultima_visita ? ` del ${s.ultima_visita}` : ''}`
                  : 'Todavía sin visitas registradas'}
              </span>
            </div>
          ))}
        </section>
      )}

      <h3>Registrados ({equipos.length})</h3>
      <div className="tabla-scroll">
        <table>
          <thead>
            <tr>
              <th>Número de serie</th><th>Tipo</th><th>Cliente</th><th>Marca</th><th>Modelo</th>
              <th>Horómetro</th><th>Próx. mtto.</th><th>Póliza</th><th></th>
            </tr>
          </thead>
          <tbody>
            {equipos.map(eq => (
              <tr key={eq.id}>
                <td>
                  {eq.numero_serie || <span className="etiqueta etiqueta-aviso">Serie pendiente</span>}
                </td>
                <td>{eq.tipo}</td>
                <td>{eq.clientes?.nombre}</td>
                <td>{eq.marca}</td>
                <td>{eq.modelo}</td>
                <td>{textoHorometro(eq) || '—'}</td>
                <td>{eq.proximo_mantenimiento}</td>
                <td>{eq.en_poliza ? 'Sí' : 'No'}</td>
                <td><button className="btn-peligro" onClick={() => borrar(eq.id)}>Borrar</button></td>
              </tr>
            ))}
            {equipos.length === 0 && (
              <tr><td colSpan={9} className="ayuda">Todavía no hay equipos.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}
