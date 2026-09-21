import { useEffect, useState } from 'react'
import { Alerta } from './ui'
import {
  pendiente, sugerido, estadoLinea, lineasParaEntrega,
  cargarPorSurtir, cargarExistencias, fijarSurtido, crearEntrega, cancelarEntrega, entregarSinFirma
} from './lib/almacen'

const NOMBRE_TIPO = {
  preventivo: 'Preventivo', correctivo: 'Correctivo', instalacion: 'Instalación',
  diagnostico: 'Diagnóstico', visita_tecnica: 'Visita técnica'
}
const ESTADO_ENTREGA = { pendiente: 'Por firmar', firmada: 'Firmada', sin_firma: 'Sin firma' }
const cuando = o => `${o.fecha || ''}${o.hora ? ' ' + o.hora.slice(0, 5) : ''}`

// ---------------------------------------------------------------------------
// Una orden por surtir. Componente de nivel superior (no dentro de otro) para que los
// campos no pierdan el foco al escribir.
// ---------------------------------------------------------------------------
function TarjetaOrden({ orden, piezas, onRecargar, onNecesitoPiezas }) {
  const [capturado, setCapturado] = useState({})     // producto_id → texto; sin tocar = lo sugerido
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState('')
  const [motivo, setMotivo] = useState({})           // entrega_id → texto (entregar sin firma)
  const [buscar, setBuscar] = useState('')
  const [elegida, setElegida] = useState(null)
  const [cantidadNueva, setCantidadNueva] = useState('1')

  const lineas = orden.lineas || []
  const entregas = orden.entregas || []
  const aEntregar = lineasParaEntrega(lineas, capturado)
  const porFirmar = entregas.filter(e => e.estado === 'pendiente')
  const hechas = entregas.filter(e => e.estado !== 'pendiente')

  async function correr(tarea, ok) {
    setOcupado(true); setError(''); setMensaje('')
    const r = await tarea()
    setOcupado(false)
    if (!r.ok) { setError(r.texto); return false }
    setMensaje(ok)
    setCapturado({})
    await onRecargar()
    return true
  }

  const preparar = () => correr(
    () => crearEntrega(orden.orden_id, aEntregar),
    'Entrega lista. El técnico responsable la firma en su celular y ahí se descuenta del inventario.'
  )

  const cancelar = e => {
    if (!confirm(`¿Cancelar la entrega ENT-${e.folio}?\n\nNo se ha movido nada del inventario.`)) return
    return correr(() => cancelarEntrega(e.id), `Entrega ENT-${e.folio} cancelada.`)
  }

  function sinFirma(e) {
    const texto = (motivo[e.id] || '').trim()
    if (!texto) return setError('Escribe por qué no se firmó.')
    if (!confirm(`¿Entregar ENT-${e.folio} sin firma?\n\nEl material sale del almacén ahora y queda a nombre de ${orden.tecnico1 || 'el técnico'}.`)) return
    return correr(() => entregarSinFirma(e.id, texto), `Entrega ENT-${e.folio} registrada sin firma.`)
  }

  const quitar = l => {
    if (!confirm(`¿Quitar ${l.sku} de la lista de esta orden?`)) return
    return correr(() => fijarSurtido(orden.orden_id, l.producto_id, 0), 'Pieza quitada de la lista.')
  }

  const agregar = () => {
    const n = Number(cantidadNueva)
    if (!elegida) return setError('Elige la pieza.')
    if (!(n > 0)) return setError('La cantidad debe ser mayor que cero.')
    const actual = lineas.find(l => l.producto_id === elegida.id)
    return correr(
      () => fijarSurtido(orden.orden_id, elegida.id, (actual ? Number(actual.pedida) : 0) + n),
      `${elegida.sku} agregado a la lista.`
    ).then(listo => { if (listo) { setElegida(null); setBuscar(''); setCantidadNueva('1') } })
  }

  const encontrados = buscar.trim().length >= 2
    ? piezas.filter(p => `${p.sku} ${p.nombre}`.toLowerCase().includes(buscar.trim().toLowerCase())).slice(0, 8)
    : []

  const faltantes = lineas.filter(l => pendiente(l) > 0).length
  const resumen = lineas.length === 0
    ? 'Sin piezas'
    : faltantes === 0 ? 'Todo entregado o por firmar' : `${faltantes} por entregar`

  return (
    <details className="tarjeta" onToggle={e => { if (e.currentTarget.open) onNecesitoPiezas() }}>
      <summary className="resumen">
        <span>
          <strong>OS-{orden.folio} · {orden.cliente || 'Cliente'}</strong>
          <span className="ayuda" style={{ display: 'block' }}>
            {cuando(orden)} · {NOMBRE_TIPO[orden.tipo_servicio] || orden.tipo_servicio} · {resumen}
          </span>
        </span>
      </summary>

      <p className="ayuda">
        {orden.equipo && <>{orden.equipo} · </>}
        Responsable: {orden.tecnico1 || <strong>sin asignar</strong>}
        {orden.tecnico2 && <> · Ayudante: {orden.tecnico2}</>}
      </p>
      {!orden.tecnico1 && (
        <Alerta tipo="aviso" palabra="Falta">
          Esta orden no tiene técnico responsable: no se puede entregar material hasta que el
          administrador lo asigne en la Agenda.
        </Alerta>
      )}

      {error && <Alerta tipo="error">{error}</Alerta>}
      {mensaje && <Alerta tipo="ok" palabra="Listo">{mensaje}</Alerta>}

      <h3>Piezas</h3>
      {lineas.length === 0 && (
        <p className="ayuda">Esta orden no trae piezas de una cotización. Si lleva material, agrégalo abajo.</p>
      )}
      {lineas.map(l => {
        const pend = pendiente(l)
        const valor = capturado[l.producto_id] ?? String(sugerido(l))
        return (
          <div key={l.producto_id} className="linea-surtido">
            <div className="fila" style={{ justifyContent: 'space-between' }}>
              <strong>{l.sku} — {l.nombre}</strong>
              <span className="etiqueta">{estadoLinea(l)}</span>
            </div>
            <div className="ayuda">
              Pedida {l.pedida} · Entregada {l.entregada}
              {Number(l.en_entrega) > 0 && <> · Por firmar {l.en_entrega}</>}
              {' · '}En el estante {l.fisico}{l.unidad ? ` ${l.unidad}` : ''}
              {l.origen === 'manual' && ' · agregada a mano'}
            </div>
            {pend > 0 && orden.tecnico1 && (
              <label className="fila">
                <span>Entregar ahora</span>
                <input type="number" inputMode="decimal" min="0" step="any" style={{ width: 104 }}
                  aria-label={`Cantidad a entregar de ${l.sku}`}
                  value={valor}
                  onChange={e => setCapturado({ ...capturado, [l.producto_id]: e.target.value })} />
              </label>
            )}
            {l.origen === 'manual' && Number(l.entregada) === 0 && Number(l.en_entrega) === 0 && (
              <button type="button" className="btn-peligro" onClick={() => quitar(l)} disabled={ocupado}>
                Quitar de la lista
              </button>
            )}
          </div>
        )
      })}

      {orden.tecnico1 && lineas.some(l => pendiente(l) > 0) && (
        <button type="button" className="btn-primario btn-grande" onClick={preparar}
          disabled={ocupado || aEntregar.length === 0} style={{ marginBottom: 16 }}>
          {ocupado ? 'Un momento…' : `Preparar entrega (${aEntregar.length} pieza${aEntregar.length === 1 ? '' : 's'})`}
        </button>
      )}

      {porFirmar.map(e => (
        <div key={e.id} className="conjunto">
          <strong>ENT-{e.folio} · esperando la firma de {orden.tecnico1}</strong>
          <ul>
            {e.lineas.map((x, i) => <li key={i}>{x.cantidad} × {x.sku} — {x.nombre}</li>)}
          </ul>
          <p className="ayuda">
            El inventario no se mueve hasta que firme. Debe abrir esta orden en su celular, en
            Órdenes → Material.
          </p>
          <div className="fila">
            <button type="button" className="btn-peligro" onClick={() => cancelar(e)} disabled={ocupado}>
              Cancelar entrega
            </button>
          </div>
          <label className="campo" style={{ marginTop: 10 }}>
            <span>¿No puede firmar? Motivo</span>
            <input value={motivo[e.id] || ''} placeholder="Ej. no traía su celular"
              onChange={ev => setMotivo({ ...motivo, [e.id]: ev.target.value })} />
          </label>
          <button type="button" onClick={() => sinFirma(e)} disabled={ocupado}>Entregar sin firma</button>
        </div>
      ))}

      {hechas.length > 0 && (
        <>
          <h3>Entregas hechas</h3>
          {hechas.map(e => (
            <p key={e.id} className="ayuda">
              <strong>ENT-{e.folio} · {ESTADO_ENTREGA[e.estado] || e.estado}:</strong>{' '}
              {e.lineas.map(x => `${x.cantidad} × ${x.sku}`).join(', ')}
            </p>
          ))}
        </>
      )}

      <h3>Agregar una pieza a mano</h3>
      <p className="ayuda">Para material que no viene en la cotización (una póliza, un extra).</p>
      <div className="buscador">
        <input placeholder="Buscar por SKU o nombre" aria-label="Buscar pieza por SKU o nombre"
          value={elegida ? `${elegida.sku} — ${elegida.nombre}` : buscar}
          onChange={ev => { setElegida(null); setBuscar(ev.target.value) }} />
        {!elegida && encontrados.length > 0 && (
          <div className="buscador-lista">
            {encontrados.map(p => (
              <button key={p.id} type="button" onClick={() => setElegida(p)}>
                <strong>{p.sku}</strong> — {p.nombre}
                <span className="ayuda">En el estante {p.fisico}{p.unidad ? ` ${p.unidad}` : ''}</span>
              </button>
            ))}
          </div>
        )}
      </div>
      <div className="fila">
        <label className="fila">Cantidad
          <input type="number" inputMode="decimal" min="0" step="any" style={{ width: 96 }}
            value={cantidadNueva} onChange={ev => setCantidadNueva(ev.target.value)} />
        </label>
        <button type="button" onClick={agregar} disabled={ocupado || !elegida}>＋ Agregar a la lista</button>
      </div>
    </details>
  )
}

// ---------------------------------------------------------------------------
// Pantalla
// ---------------------------------------------------------------------------
export default function Almacen() {
  const [ordenes, setOrdenes] = useState(null)         // null = aún no carga
  const [error, setError] = useState('')
  const [piezas, setPiezas] = useState([])
  const [piezasCargadas, setPiezasCargadas] = useState(false)
  const [enLinea, setEnLinea] = useState(navigator.onLine)

  async function recargar() {
    const r = await cargarPorSurtir()
    if (r.ok) { setOrdenes(r.ordenes); setError('') }
    else setError(r.texto)
  }

  // Las piezas para agregar a mano se piden la primera vez que se abre una orden.
  async function traerPiezas() {
    if (piezasCargadas) return
    setPiezasCargadas(true)
    const r = await cargarExistencias()
    if (r.ok) setPiezas(r.piezas)
    else setPiezasCargadas(false)
  }

  useEffect(() => {
    function alConectar() { setEnLinea(true); recargar() }
    function alDesconectar() { setEnLinea(false) }
    window.addEventListener('online', alConectar)
    window.addEventListener('offline', alDesconectar)
    // Carga inicial: el estado se cambia después de esperar a la red, no al montar.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    if (navigator.onLine) recargar()
    return () => {
      window.removeEventListener('online', alConectar)
      window.removeEventListener('offline', alDesconectar)
    }
  }, [])

  const porEntregar = (ordenes || []).filter(o => (o.lineas || []).some(l => pendiente(l) > 0))
  const otras = (ordenes || []).filter(o => !porEntregar.includes(o))

  return (
    <div className="pagina pagina-angosta">
      <div className="fila" style={{ justifyContent: 'space-between' }}>
        <h2 style={{ margin: 0 }}>Almacén</h2>
        <button onClick={recargar} disabled={!enLinea}>Actualizar</button>
      </div>
      <p className="ayuda">
        Órdenes abiertas con cita programada. Prepara la entrega; el técnico responsable la firma
        de recibido en su celular y es entonces cuando el material sale del inventario.
      </p>

      {!enLinea && (
        <Alerta tipo="aviso" palabra="Sin señal">
          El almacén necesita conexión: cada entrega mueve el inventario.
        </Alerta>
      )}
      {error && <Alerta tipo="error">{error}</Alerta>}
      {ordenes === null && !error && enLinea && <p>Cargando…</p>}

      {ordenes && ordenes.length === 0 && (
        <p className="ayuda">No hay órdenes abiertas con cita programada.</p>
      )}

      {ordenes && ordenes.length > 0 && (
        <h3>Órdenes ({ordenes.length}) · {porEntregar.length} con piezas por entregar</h3>
      )}
      {/* Una sola lista: si una orden pasara de una a otra, se cerraría y perdería su aviso. */}
      {[...porEntregar, ...otras].map(o => (
        <TarjetaOrden key={o.orden_id} orden={o} piezas={piezas} onRecargar={recargar} onNecesitoPiezas={traerPiezas} />
      ))}
    </div>
  )
}
