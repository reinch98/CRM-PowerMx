import { useEffect, useState } from 'react'
import { Alerta } from './ui'
import { leerLocal } from './lib/local'
import {
  pendiente, sugerido, estadoLinea, lineasParaEntrega,
  cargarPorSurtir, cargarExistencias, fijarSurtido, crearEntrega, cancelarEntrega, entregarSinFirma,
  cargarDevoluciones, recibirDevolucion, resolverDiferencia, cargarAdicionales, conciliarAdicional
} from './lib/almacen'
import { aRecibir, quedaPendiente, nivelAntiguedad, haceCuanto } from './lib/material'
import { nombrePieza, cargarSolicitudesPendientes, atenderSolicitud, descartarSolicitud } from './lib/solicitudes'

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
// Una orden cerrada (o cancelada) con material que el técnico aún debe devolver.
// ---------------------------------------------------------------------------
function TarjetaDevolucion({ dev, esAdmin, onRecargar }) {
  const [capturado, setCapturado] = useState({})     // producto_id → texto; sin tocar = todo lo pendiente
  const [observaciones, setObservaciones] = useState('')
  const [motivo, setMotivo] = useState({})           // producto_id → motivo (dar por consumido)
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState('')

  const pendientes = (dev.lineas || []).filter(l => Number(l.pendiente) > 0)
  const recibir = aRecibir(pendientes, capturado)
  const falta = quedaPendiente(pendientes, recibir)
  const nivel = nivelAntiguedad(dev.dias)

  async function correr(tarea, ok) {
    setOcupado(true); setError(''); setMensaje('')
    const r = await tarea()
    setOcupado(false)
    if (!r.ok) return setError(r.texto)
    setMensaje(ok)
    setCapturado({}); setObservaciones('')
    await onRecargar()
  }

  const recibirTodo = () => {
    if (falta && !observaciones.trim()) return setError('Escribe una observación: no se devuelve todo lo pendiente.')
    return correr(() => recibirDevolucion(dev.orden_id, recibir, observaciones), 'Devolución registrada: el material volvió al estante.')
  }

  function darPorConsumido(l) {
    const texto = (motivo[l.producto_id] || '').trim()
    if (!texto) return setError('Escribe el motivo.')
    if (!confirm(`¿Dar por consumidas ${l.pendiente} de ${l.sku}?\n\nSale del inventario y queda escrito el motivo. No se puede deshacer.`)) return
    return correr(() => resolverDiferencia(dev.orden_id, l.producto_id, texto), `${l.sku}: la diferencia quedó cerrada.`)
  }

  return (
    <details className="tarjeta">
      <summary className="resumen">
        <span>
          <strong>OS-{dev.folio} · {dev.cliente}</strong>
          <span className="ayuda" style={{ display: 'block' }}>
            {dev.estado === 'cancelada' ? 'Cancelada' : 'Cerrada'} {haceCuanto(dev.dias)} · {nivel}
            {' · '}{pendientes.length} pieza{pendientes.length === 1 ? '' : 's'} por devolver
          </span>
        </span>
      </summary>

      <p className="ayuda">
        Responsable: {dev.tecnico1 || 'sin asignar'}
        {dev.tecnico2 && <> · Ayudante: {dev.tecnico2}</>}
      </p>
      {nivel !== 'Reciente' && (
        <Alerta tipo="aviso" palabra={nivel}>
          El material lleva {dev.dias} días fuera. Pídele a {dev.tecnico1 || 'el responsable'} que lo devuelva.
        </Alerta>
      )}

      {error && <Alerta tipo="error">{error}</Alerta>}
      {mensaje && <Alerta tipo="ok" palabra="Listo">{mensaje}</Alerta>}

      <h3>Piezas</h3>
      {(dev.lineas || []).map(l => (
        <div key={l.producto_id} className="linea-surtido">
          <div className="fila" style={{ justifyContent: 'space-between' }}>
            <strong>{l.sku} — {l.nombre}</strong>
            <span className="etiqueta">{Number(l.pendiente) > 0 ? 'Por devolver' : 'Saldada'}</span>
          </div>
          <div className="ayuda">
            Entregada {l.entregada} · Usada {l.usada} · Devuelta {l.devuelta}
            {Number(l.diferencia) > 0 && <> · Dada por consumida {l.diferencia}</>}
            {Number(l.pendiente) > 0 && <> · <strong>Pendiente {l.pendiente}{l.unidad ? ` ${l.unidad}` : ''}</strong></>}
          </div>
          {Number(l.pendiente) > 0 && (
            <label className="fila">
              <span>Recibo ahora</span>
              <input type="number" inputMode="decimal" min="0" step="any" style={{ width: 104 }}
                aria-label={`Cantidad que se recibe de ${l.sku}`}
                value={capturado[l.producto_id] ?? String(l.pendiente)}
                onChange={e => setCapturado({ ...capturado, [l.producto_id]: e.target.value })} />
            </label>
          )}
          {esAdmin && Number(l.pendiente) > 0 && (
            <details>
              <summary className="resumen">Dar por consumido lo que no volvió</summary>
              <label className="campo">
                <span>Motivo</span>
                <input value={motivo[l.producto_id] || ''} placeholder="Ej. se dañó en el sitio"
                  onChange={e => setMotivo({ ...motivo, [l.producto_id]: e.target.value })} />
              </label>
              <button type="button" className="btn-peligro" disabled={ocupado} onClick={() => darPorConsumido(l)}>
                Dar por consumidas {l.pendiente}
              </button>
            </details>
          )}
        </div>
      ))}

      {pendientes.length > 0 && (
        <>
          <label className="campo">
            <span>Observaciones{falta ? ' (obligatorias: no se devuelve todo)' : ''}</span>
            <textarea rows={2} value={observaciones} placeholder="Ej. faltó 1 filtro; el técnico dice que se quedó en el sitio"
              onChange={e => setObservaciones(e.target.value)} />
          </label>
          <button type="button" className="btn-primario btn-grande" onClick={recibirTodo}
            disabled={ocupado || recibir.length === 0}>
            {ocupado ? 'Un momento…' : `Recibir devolución (${recibir.length} pieza${recibir.length === 1 ? '' : 's'})`}
          </button>
        </>
      )}

      {(dev.devoluciones || []).length > 0 && (
        <>
          <h3 style={{ marginTop: 16 }}>Devoluciones anteriores</h3>
          {dev.devoluciones.map(d => (
            <p key={d.folio} className="ayuda">
              <strong>DEV-{d.folio}</strong> · {String(d.fecha).slice(0, 10)}
              {d.observaciones && <> · {d.observaciones}</>}
            </p>
          ))}
        </>
      )}
    </details>
  )
}

// ---------------------------------------------------------------------------
// Lo que el técnico usó y no le entregaron: se concilia con el almacén.
// ---------------------------------------------------------------------------
function TarjetaAdicional({ adicional, onRecargar }) {
  const [nota, setNota] = useState('')
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')

  async function conciliar() {
    setOcupado(true); setError('')
    const r = await conciliarAdicional(adicional.orden_id, nota)
    setOcupado(false)
    if (!r.ok) return setError(r.texto)
    await onRecargar()
  }

  return (
    <div className="tarjeta">
      <strong>OS-{adicional.folio} · {adicional.cliente}</strong>
      <div className="ayuda">Responsable: {adicional.tecnico1 || 'sin asignar'} · {adicional.fecha}</div>
      <ul>
        {(adicional.items || []).map((x, i) => <li key={i}>{x.cantidad} × {x.descripcion}</li>)}
      </ul>
      <label className="campo">
        <span>Nota (opcional)</span>
        <input value={nota} placeholder="Ej. ya se repuso del estante / se cobró aparte"
          onChange={e => setNota(e.target.value)} />
      </label>
      {error && <Alerta tipo="error">{error}</Alerta>}
      <button type="button" className="btn-primario" onClick={conciliar} disabled={ocupado}>
        {ocupado ? 'Un momento…' : 'Marcar como conciliado'}
      </button>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Una pieza que un técnico pidió (para esta visita o la próxima). No mueve inventario:
// solo coordina. "Atender" exige contar cómo quedó (p. ej. "Se apartó en el almacén" o
// "Se generó REQ-12"); "Descartar" exige el motivo.
// ---------------------------------------------------------------------------
function TarjetaSolicitud({ s, onRecargar }) {
  const [resolucion, setResolucion] = useState('')
  const [motivo, setMotivo] = useState('')
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')

  async function atender() {
    if (!resolucion.trim()) return setError('Escribe cómo se resolvió.')
    setOcupado(true); setError('')
    const r = await atenderSolicitud(s.id, resolucion)
    setOcupado(false)
    if (!r.ok) return setError(r.texto)
    await onRecargar()
  }

  async function descartar() {
    if (!motivo.trim()) return setError('Escribe el motivo.')
    if (!confirm('¿Descartar este pedido?')) return
    setOcupado(true); setError('')
    const r = await descartarSolicitud(s.id, motivo)
    setOcupado(false)
    if (!r.ok) return setError(r.texto)
    await onRecargar()
  }

  return (
    <div className="tarjeta">
      <div className="fila" style={{ justifyContent: 'space-between' }}>
        <strong>{s.cantidad} × {nombrePieza(s)}</strong>
        {s.fisico != null && <span className="etiqueta">En el estante {s.fisico}</span>}
      </div>
      <div className="ayuda">
        Pidió: {s.tecnico}{s.cliente && <> · {s.cliente}</>}{s.equipo && <> · {s.equipo}</>}
        {s.orden_folio && <> · OS-{s.orden_folio}</>}
      </div>
      {s.nota && <div className="ayuda">{s.nota}</div>}

      <label className="campo">
        <span>Cómo se resolvió</span>
        <input value={resolucion} placeholder="Ej. se apartó en el almacén para la próxima visita"
          onChange={e => setResolucion(e.target.value)} />
      </label>
      {error && <Alerta tipo="error">{error}</Alerta>}
      <div className="fila">
        <button type="button" className="btn-primario" onClick={atender} disabled={ocupado}>
          {ocupado ? 'Un momento…' : 'Marcar como atendida'}
        </button>
      </div>

      <details style={{ marginTop: 8 }}>
        <summary className="resumen">Descartar</summary>
        <label className="campo">
          <span>Motivo</span>
          <input value={motivo} placeholder="Ej. ya no hace falta"
            onChange={e => setMotivo(e.target.value)} />
        </label>
        <button type="button" className="btn-peligro" onClick={descartar} disabled={ocupado}>Descartar pedido</button>
      </details>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Pantalla
// ---------------------------------------------------------------------------
export default function Almacen() {
  const [pestana, setPestana] = useState('entregas')   // entregas | devoluciones | adicionales | solicitudes
  const [ordenes, setOrdenes] = useState(null)         // null = aún no carga
  const [devoluciones, setDevoluciones] = useState(null)
  const [adicionales, setAdicionales] = useState(null)
  const [solicitudes, setSolicitudes] = useState(null)
  const [error, setError] = useState('')
  const [piezas, setPiezas] = useState([])
  const [piezasCargadas, setPiezasCargadas] = useState(false)
  const [enLinea, setEnLinea] = useState(navigator.onLine)
  const esAdmin = leerLocal('cache_perfil', null)?.rol === 'admin'

  async function recargar() {
    const [a, b, c, d] = await Promise.all([
      cargarPorSurtir(), cargarDevoluciones(), cargarAdicionales(), cargarSolicitudesPendientes()
    ])
    if (a.ok) setOrdenes(a.ordenes)
    if (b.ok) setDevoluciones(b.devoluciones)
    if (c.ok) setAdicionales(c.adicionales)
    if (d.ok) setSolicitudes(d.solicitudes)
    const fallo = [a, b, c, d].find(r => !r.ok)
    setError(fallo ? fallo.texto : '')
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
      {!enLinea && (
        <Alerta tipo="aviso" palabra="Sin señal">
          El almacén necesita conexión: cada movimiento cambia el inventario.
        </Alerta>
      )}
      {error && <Alerta tipo="error">{error}</Alerta>}

      <div className="pestanas" role="group" aria-label="Secciones del almacén">
        <button className="pestana" aria-pressed={pestana === 'entregas'} onClick={() => setPestana('entregas')}>
          Por entregar{ordenes ? ` (${porEntregar.length})` : ''}
        </button>
        <button className="pestana" aria-pressed={pestana === 'devoluciones'} onClick={() => setPestana('devoluciones')}>
          Devoluciones{devoluciones ? ` (${devoluciones.length})` : ''}
        </button>
        <button className="pestana" aria-pressed={pestana === 'adicionales'} onClick={() => setPestana('adicionales')}>
          Adicionales{adicionales ? ` (${adicionales.length})` : ''}
        </button>
        <button className="pestana" aria-pressed={pestana === 'solicitudes'} onClick={() => setPestana('solicitudes')}>
          Solicitudes{solicitudes ? ` (${solicitudes.length})` : ''}
        </button>
      </div>
      {ordenes === null && !error && enLinea && <p>Cargando…</p>}

      {pestana === 'entregas' && (
        <>
          <p className="ayuda">
            Órdenes abiertas con cita programada. Prepara la entrega; el técnico responsable la firma
            de recibido en su celular y es entonces cuando el material sale del inventario.
          </p>
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
        </>
      )}

      {pestana === 'devoluciones' && (
        <>
          <p className="ayuda">
            Material que el técnico recibió y no usó. Cuando lo devuelva, cuéntalo aquí y vuelve al
            estante. Si falta algo, escribe qué pasó. Las más antiguas van primero.
          </p>
          {devoluciones && devoluciones.length === 0 && (
            <Alerta tipo="ok" palabra="Al día">No hay material pendiente de devolución.</Alerta>
          )}
          {(devoluciones || []).map(d => (
            <TarjetaDevolucion key={d.orden_id} dev={d} esAdmin={esAdmin} onRecargar={recargar} />
          ))}
        </>
      )}

      {pestana === 'adicionales' && (
        <>
          <p className="ayuda">
            Material que el técnico dice haber usado y que no le entregó el almacén. No descuenta
            inventario solo: revísalo y márcalo como conciliado.
          </p>
          {adicionales && adicionales.length === 0 && (
            <Alerta tipo="ok" palabra="Al día">No hay adicionales por conciliar.</Alerta>
          )}
          {(adicionales || []).map(a => (
            <TarjetaAdicional key={a.orden_id} adicional={a} onRecargar={recargar} />
          ))}
        </>
      )}

      {pestana === 'solicitudes' && (
        <>
          <p className="ayuda">
            Piezas que un técnico pidió, para esta orden o para la próxima visita. No mueve
            inventario por sí solo: si hay en el estante, apártala a mano; si no, conviértela en
            requisición desde Requisiciones.
          </p>
          {solicitudes && solicitudes.length === 0 && (
            <Alerta tipo="ok" palabra="Al día">No hay pedidos pendientes.</Alerta>
          )}
          {(solicitudes || []).map(s => (
            <TarjetaSolicitud key={s.id} s={s} onRecargar={recargar} />
          ))}
        </>
      )}
    </div>
  )
}
