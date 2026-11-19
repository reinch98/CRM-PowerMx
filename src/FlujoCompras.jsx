import { useEffect, useState } from 'react'
import { Alerta } from './ui'
import { cargarFlujo, contarEtapas, pasosDe, ETAPAS, cerrarSinFactura, reabrirSinFactura } from './lib/flujoCompras'
import { urlDeArchivo } from './lib/compras'
import { fechaLegible } from './lib/finanzas'

// ---------------------------------------------------------------------------
// Pedido → Nota → Factura, a la vista. Cada tarjeta es una compra (la nota del proveedor) con
// los pedidos que recibió, o un pedido que todavía espera su nota. Solo lee: registrar sigue
// siendo cosa de Compras (la nota) y de Finanzas (el XML).
// ---------------------------------------------------------------------------

const FILTROS = [
  ['todos', 'Todos'],
  ['nota', ETAPAS.nota],
  ['factura', ETAPAS.factura],
  ['completo', ETAPAS.completo],
  ['sin_factura', ETAPAS.sin_factura],
]

// Un ticket que no va a tener factura (mostrador, compra chica) se cierra con un motivo escrito
// (SQL 101). No mueve inventario ni dinero; si el XML llega después, la factura manda.
function CerrarSinFactura({ compra, onHecho }) {
  const [abierto, setAbierto] = useState(false)
  const [motivo, setMotivo] = useState('')
  const [guardando, setGuardando] = useState(false)
  const [error, setError] = useState('')

  if (!abierto) {
    return <button onClick={() => setAbierto(true)}>Cerrar sin factura…</button>
  }
  async function cerrar(e) {
    e.preventDefault()
    if (!motivo.trim()) { setError('Escribe por qué se cierra sin factura.'); return }
    setGuardando(true)
    const r = await cerrarSinFactura(compra.id, motivo.trim())
    setGuardando(false)
    if (!r.ok) { setError(r.texto); return }
    onHecho(`COMPRA-${compra.folio} cerrada sin factura.`)
  }
  return (
    <form onSubmit={cerrar} className="flujo-cerrar">
      <label className="campo">
        <span>¿Por qué se cierra sin factura?</span>
        <input value={motivo} autoFocus onChange={e => { setMotivo(e.target.value); setError('') }}
          placeholder="Ticket de mostrador, no se pidió factura" />
      </label>
      {error && <Alerta tipo="error">{error}</Alerta>}
      <div className="fila">
        <button type="submit" className="btn-primario" disabled={guardando}>
          {guardando ? 'Cerrando…' : 'Cerrar sin factura'}
        </button>
        <button type="button" onClick={() => { setAbierto(false); setMotivo(''); setError('') }}>Cancelar</button>
      </div>
    </form>
  )
}

const pesos = n => Number(n || 0).toLocaleString('es-MX', { style: 'currency', currency: 'MXN' })

function Paso({ paso, ultimo }) {
  return (
    <li className={paso.hecho ? 'flujo-paso flujo-hecho' : 'flujo-paso flujo-falta'}>
      <span className="flujo-icono" aria-hidden="true">{paso.hecho ? '✓' : '…'}</span>
      <span className="flujo-texto">
        <small>{paso.nombre} · {paso.hecho ? 'listo' : 'pendiente'}</small>
        <strong>{paso.titulo}</strong>
        {paso.nota && <span>{paso.nota}</span>}
      </span>
      {!ultimo && <span className="flujo-flecha" aria-hidden="true">→</span>}
    </li>
  )
}

function Tarjeta({ flujo, irA, abrir, onCambio, onError }) {
  const pasos = pasosDe(flujo)
  const { compra, pedidos } = flujo
  return (
    <article className="tarjeta flujo">
      <div className="fila" style={{ justifyContent: 'space-between', alignItems: 'baseline' }}>
        <strong>{fechaLegible(flujo.fecha)}</strong>
        <span className={`estado estado-${flujo.etapa === 'completo' ? 'recibida' : flujo.etapa === 'sin_factura' ? 'cancelada' : 'pendiente'}`}>
          {ETAPAS[flujo.etapa]}
        </span>
      </div>

      <ol className="flujo-pasos" aria-label="Pedido, nota y factura">
        {pasos.map((p, i) => <Paso key={p.clave} paso={p} ultimo={i === pasos.length - 1} />)}
      </ol>

      {pedidos.length > 0 && (
        <ul className="flujo-lista">
          {pedidos.map(r => (
            <li key={r.id}>
              REQ-{r.folio}: {r.cantidad} × {r.sku}{r.nombre ? ` — ${r.nombre}` : ''}
              {r.cotizacion && <> · para COT-{r.cotizacion}{r.cliente ? ` (${r.cliente})` : ''}</>}
            </li>
          ))}
        </ul>
      )}

      {compra && (
        <details>
          <summary className="resumen">Lo que entró con la nota · {pesos(compra.total)}</summary>
          <ul className="flujo-lista">
            {compra.lineas.map((l, i) => <li key={i}>{l.cantidad} × {l.sku} — {l.nombre}</li>)}
          </ul>
          {compra.notas && <p className="ayuda">{compra.notas}</p>}
        </details>
      )}

      <div className="fila">
        {compra?.archivo_pdf && <button onClick={() => abrir(compra.archivo_pdf)}>Ver la nota</button>}
        {flujo.etapa === 'factura' && <button onClick={() => irA?.('finanzas')}>Subir la factura en Finanzas</button>}
        {flujo.etapa === 'nota' && <button onClick={() => irA?.('compras')}>Registrar la nota en Compras</button>}
        {flujo.etapa === 'sin_factura' && (
          <button onClick={async () => {
            const r = await reabrirSinFactura(compra.id)
            if (r.ok) onCambio(`COMPRA-${compra.folio} vuelve a esperar su factura.`)
            else onError(r.texto)
          }}>Reabrir: sí tendrá factura</button>
        )}
      </div>
      {flujo.etapa === 'factura' && <CerrarSinFactura compra={compra} onHecho={onCambio} />}
    </article>
  )
}

export default function FlujoCompras({ irA }) {
  const [flujos, setFlujos] = useState(null)
  const [error, setError] = useState('')
  const [filtro, setFiltro] = useState('todos')
  const [mensaje, setMensaje] = useState('')
  const [vuelta, setVuelta] = useState(0)

  useEffect(() => {
    let vivo = true
    cargarFlujo(90).then(r => {
      if (!vivo) return
      if (r.ok) setFlujos(r.flujos)
      else setError(r.texto)
    })
    return () => { vivo = false }
  }, [vuelta])

  const alCambiar = texto => { setError(''); setMensaje(texto); setVuelta(v => v + 1) }

  async function abrir(ruta) {
    const url = await urlDeArchivo(ruta)
    if (url) window.open(url, '_blank', 'noopener')
    else setError('No se pudo abrir la nota.')
  }

  const n = flujos ? contarEtapas(flujos) : null
  const visibles = (flujos || []).filter(f => filtro === 'todos' || f.etapa === filtro)

  return (
    <div className="pagina">
      <h2>Pedido → nota → factura</h2>
      <p className="ayuda">
        Cada compra de los últimos 90 días con el pedido que la originó y la factura que la respalda.
        Aquí solo se ve el avance: la nota se registra en Compras y la factura (XML) en Finanzas.
      </p>

      {error && <Alerta tipo="error">{error}</Alerta>}
      {mensaje && <Alerta tipo="ok">{mensaje}</Alerta>}
      {!flujos && !error && <p>Cargando…</p>}

      {n && (
        <div className="pestanas" role="group" aria-label="Filtrar por etapa">
          {FILTROS.map(([k, t]) => (
            <button key={k} className="pestana" aria-pressed={filtro === k} onClick={() => setFiltro(k)}>
              {t} ({n[k]})
            </button>
          ))}
        </div>
      )}

      {flujos && visibles.length === 0 && <Alerta tipo="info">No hay nada en esta etapa.</Alerta>}
      {visibles.map(f => (
        <Tarjeta key={f.clave} flujo={f} irA={irA} abrir={abrir}
          onCambio={alCambiar} onError={t => { setMensaje(''); setError(t) }} />
      ))}
    </div>
  )
}
