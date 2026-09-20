import { useEffect, useMemo, useState } from 'react'
import { supabase } from './lib/supabase'
import { CLASES } from './lib/tarifas'
import { Alerta } from './ui'

// Tarifas de servicio (solo admin; el técnico nunca ve precios). Se COPIAN a la
// partida al cotizar, así que cambiar una tarifa no altera cotizaciones viejas.
//
//   diagnóstico: por clase de equipo y tramo de capacidad (kW; kWh en baterías).
//   traslado:    precio por km, solo ida, desde los km indicados; una vez rebasados
//                se cobran todos los km.

const NOMBRE_CLASE = Object.fromEntries(CLASES)

const vacia = {
  concepto: 'diagnostico', clase: 'gasolina',
  kw_desde: '', kw_hasta: '', km_desde: '40', precio: '', notas: ''
}

const aNumero = v => (v === '' || v == null ? null : Number(v))

export default function Tarifas() {
  const [filas, setFilas] = useState([])
  const [nueva, setNueva] = useState(vacia)
  const [edicion, setEdicion] = useState({})    // { [id]: { campo: valor } }
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState('')

  useEffect(() => { cargar() }, [])

  async function cargar() {
    const { data, error } = await supabase
      .from('tarifas_servicio').select('*')
      .order('concepto').order('clase').order('kw_desde')
    if (error) return setError(error.message)
    setFilas(data || [])
  }

  const diagnostico = useMemo(() => filas.filter(f => f.concepto === 'diagnostico'), [filas])
  const traslado = useMemo(() => filas.filter(f => f.concepto === 'traslado'), [filas])

  function validar(f) {
    if (f.precio === '' || f.precio == null || Number(f.precio) < 0) return 'Falta el precio'
    if (f.concepto === 'diagnostico') {
      if (!f.clase) return 'Elige la clase del equipo'
      const d = aNumero(f.kw_desde), h = aNumero(f.kw_hasta)
      if (d != null && h != null && d > h) return 'El tramo está al revés: "desde" es mayor que "hasta"'
    }
    return ''
  }

  async function agregar(e) {
    e.preventDefault()
    setError(''); setMensaje('')
    const motivo = validar(nueva)
    if (motivo) return setError(motivo)
    const esDiag = nueva.concepto === 'diagnostico'
    const { error } = await supabase.from('tarifas_servicio').insert([{
      concepto: nueva.concepto,
      clase: esDiag ? nueva.clase : null,
      kw_desde: esDiag ? aNumero(nueva.kw_desde) : null,
      kw_hasta: esDiag ? aNumero(nueva.kw_hasta) : null,
      km_desde: esDiag ? null : aNumero(nueva.km_desde),
      precio: Number(nueva.precio),
      notas: nueva.notas || null
    }])
    if (error) return setError(error.message)
    setNueva({ ...vacia, concepto: nueva.concepto })
    setMensaje('Tarifa agregada.')
    cargar()
  }

  function editar(id, campo, valor) {
    setEdicion({ ...edicion, [id]: { ...(edicion[id] || {}), [campo]: valor } })
  }

  const valor = (f, campo) => (campo in (edicion[f.id] || {}) ? edicion[f.id][campo] : (f[campo] ?? ''))

  async function guardarFila(f) {
    const cambios = edicion[f.id]
    if (!cambios) return
    setError(''); setMensaje('')
    const merged = { ...f, ...cambios }
    const motivo = validar(merged)
    if (motivo) return setError(motivo)

    const payload = {}
    for (const c of Object.keys(cambios)) {
      payload[c] = ['kw_desde', 'kw_hasta', 'km_desde', 'precio'].includes(c) ? aNumero(cambios[c]) : cambios[c]
    }
    const { error } = await supabase.from('tarifas_servicio').update(payload).eq('id', f.id)
    if (error) return setError(error.message)
    const { [f.id]: _, ...resto } = edicion
    setEdicion(resto)
    setMensaje('Tarifa actualizada.')
    cargar()
  }

  async function quitar(f) {
    if (!confirm('¿Quitar esta tarifa? Las cotizaciones ya hechas no cambian: llevan su precio copiado.')) return
    const { error } = await supabase.from('tarifas_servicio').delete().eq('id', f.id)
    if (error) return setError(error.message)
    cargar()
  }

  // Tramos de la misma clase que se empalman: no se bloquea, se avisa.
  const empalmes = useMemo(() => {
    const avisos = []
    const activas = diagnostico.filter(f => f.activo)
    for (let i = 0; i < activas.length; i++) {
      for (let j = i + 1; j < activas.length; j++) {
        const a = activas[i], b = activas[j]
        if (a.clase !== b.clase) continue
        const ad = a.kw_desde ?? -Infinity, ah = a.kw_hasta ?? Infinity
        const bd = b.kw_desde ?? -Infinity, bh = b.kw_hasta ?? Infinity
        if (ad < bh && bd < ah) {
          avisos.push(`${NOMBRE_CLASE[a.clase] || a.clase}: los tramos ${a.kw_desde ?? '…'}–${a.kw_hasta ?? '…'} y ${b.kw_desde ?? '…'}–${b.kw_hasta ?? '…'} se empalman. Gana el que empieza más arriba.`)
        }
      }
    }
    return avisos
  }, [diagnostico])

  const esDiag = nueva.concepto === 'diagnostico'

  // Función y NO componente: un componente definido aquí adentro se recrearía en cada
  // tecla y el campo perdería el foco mientras se escribe.
  function filaTarifa(f) {
    const diag = f.concepto === 'diagnostico'
    return (
      <tr key={f.id} style={f.activo ? undefined : { opacity: 0.6 }}>
        {diag && <td>{NOMBRE_CLASE[f.clase] || f.clase}</td>}
        {diag ? (
          <>
            <td><input type="number" step="any" style={{ width: 90 }} aria-label="kW desde"
              value={valor(f, 'kw_desde')} onChange={e => editar(f.id, 'kw_desde', e.target.value)} /></td>
            <td><input type="number" step="any" style={{ width: 90 }} aria-label="kW hasta"
              value={valor(f, 'kw_hasta')} onChange={e => editar(f.id, 'kw_hasta', e.target.value)} /></td>
          </>
        ) : (
          <td><input type="number" step="any" style={{ width: 90 }} aria-label="Km desde"
            value={valor(f, 'km_desde')} onChange={e => editar(f.id, 'km_desde', e.target.value)} /></td>
        )}
        <td><input type="number" step="any" min="0" style={{ width: 110 }} aria-label="Precio"
          value={valor(f, 'precio')} onChange={e => editar(f.id, 'precio', e.target.value)} /></td>
        <td align="center">
          <input type="checkbox" aria-label="Activa" checked={!!valor(f, 'activo')}
            onChange={e => editar(f.id, 'activo', e.target.checked)} />
          {' '}{valor(f, 'activo') ? 'Sí' : 'No'}
        </td>
        <td>
          {edicion[f.id] && <button onClick={() => guardarFila(f)}>Guardar</button>}
          {' '}<button className="btn-peligro" onClick={() => quitar(f)}>Quitar</button>
        </td>
      </tr>
    )
  }

  return (
    <div className="pagina">
      <h2>Tarifas de servicio</h2>
      <p className="ayuda" style={{ maxWidth: 680 }}>
        Precios del diagnóstico y del traslado. Al cotizar se copian a la partida: cambiar una
        tarifa aquí no altera las cotizaciones que ya hiciste.
      </p>

      {error && <Alerta tipo="error">{error}</Alerta>}
      {mensaje && <Alerta tipo="ok" palabra="Listo">{mensaje}</Alerta>}
      {empalmes.map((a, i) => <Alerta key={i} tipo="aviso" palabra="Ojo">{a}</Alerta>)}

      <section className="tarjeta">
        <h3>Diagnóstico</h3>
        <p className="ayuda">
          Por clase de equipo y tramo de capacidad. El tramo incluye sus dos extremos. En baterías
          la capacidad se mide en kWh.
        </p>
        <div style={{ overflowX: 'auto' }}>
          <table>
            <thead>
              <tr><th>Clase</th><th>Desde (kW)</th><th>Hasta (kW)</th><th>Precio</th><th>Activa</th><th></th></tr>
            </thead>
            <tbody>
              {diagnostico.map(filaTarifa)}
              {diagnostico.length === 0 && (
                <tr><td colSpan={6} className="ayuda">Todavía no hay tarifas de diagnóstico.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      <section className="tarjeta">
        <h3>Traslado</h3>
        <p className="ayuda">
          Precio por kilómetro, solo ida. Desde los km indicados se cobran <strong>todos</strong> los km
          (a 55 km y con desde = 40, se cobran 55).
        </p>
        <div style={{ overflowX: 'auto' }}>
          <table>
            <thead>
              <tr><th>Desde (km)</th><th>Precio por km</th><th>Activa</th><th></th></tr>
            </thead>
            <tbody>
              {traslado.map(filaTarifa)}
              {traslado.length === 0 && (
                <tr><td colSpan={4} className="ayuda">Todavía no hay tarifa de traslado.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      <section className="tarjeta">
        <h3>Agregar tarifa</h3>
        <form onSubmit={agregar} style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr)', gap: 10, maxWidth: 520 }}>
          <label className="campo">
            <span>Concepto</span>
            <select value={nueva.concepto} onChange={e => setNueva({ ...nueva, concepto: e.target.value })}>
              <option value="diagnostico">Diagnóstico</option>
              <option value="traslado">Traslado (por km)</option>
            </select>
          </label>

          {esDiag ? (
            <>
              <label className="campo">
                <span>Clase de equipo</span>
                <select value={nueva.clase} onChange={e => setNueva({ ...nueva, clase: e.target.value })}>
                  {CLASES.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
                </select>
              </label>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, minmax(0, 1fr))', gap: 10 }}>
                <label className="campo">
                  <span>Desde (kW)</span>
                  <input type="number" step="any" min="0" value={nueva.kw_desde}
                    onChange={e => setNueva({ ...nueva, kw_desde: e.target.value })} />
                </label>
                <label className="campo">
                  <span>Hasta (kW)</span>
                  <input type="number" step="any" min="0" value={nueva.kw_hasta}
                    onChange={e => setNueva({ ...nueva, kw_hasta: e.target.value })} />
                </label>
              </div>
            </>
          ) : (
            <label className="campo">
              <span>A partir de (km)</span>
              <input type="number" step="any" min="0" value={nueva.km_desde}
                onChange={e => setNueva({ ...nueva, km_desde: e.target.value })} />
            </label>
          )}

          <label className="campo">
            <span>{esDiag ? 'Precio del diagnóstico' : 'Precio por km'}</span>
            <input type="number" step="any" min="0" value={nueva.precio}
              onChange={e => setNueva({ ...nueva, precio: e.target.value })} />
          </label>

          <button type="submit" className="btn-primario">Agregar</button>
        </form>
      </section>
    </div>
  )
}
