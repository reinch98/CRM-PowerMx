import { useEffect, useState } from 'react'
import { Alerta } from './ui'
import { fechaLegible } from './lib/finanzas'
import {
  cargarCotizaciones, aceptarCotizacion, cambiarEstadoCotizacion, estadoCotizacion, dinero, textoAceptada,
  urlDeCotizacion
} from './lib/cotizacionesProveedor'

// ---------------------------------------------------------------------------
// Las cotizaciones de proveedor (SQL 84), con lo que se puede hacer con cada una. Se usa en Compras
// (todas) y en la carpeta de un proveedor (`proveedorId`). `vuelta` la recarga desde fuera.
//
// Aceptar crea los pedidos; por eso pide confirmación y dice cuántos. Cancelar una aceptada no
// cancela los pedidos que ya están con el proveedor: lo avisa.
// ---------------------------------------------------------------------------

function Tarjeta({ c, mostrarProveedor, onCambio, onAviso }) {
  const [accion, setAccion] = useState('')   // '' | 'aceptar' | 'rechazada' | 'cancelada'
  const [motivo, setMotivo] = useState('')
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')
  const e = estadoCotizacion(c)
  const piezas = c.lineas?.length || 0

  async function hacer() {
    setOcupado(true); setError('')
    const r = accion === 'aceptar'
      ? await aceptarCotizacion(c.id)
      : await cambiarEstadoCotizacion(c.id, accion, motivo)
    setOcupado(false)
    if (r.error) return setError(r.error)
    let texto
    if (accion === 'aceptar') {
      texto = [textoAceptada(r.data), ...(r.data?.avisos || [])].join(' ')
    } else if (accion === 'cancelada' && Number(r.data?.pedidos_vivos) > 0) {
      texto = `COTP-${c.folio} cancelada. Sus ${r.data.pedidos_vivos} pedido(s) siguen como "pedida": si ya no vienen, cancélalos en Pedidos.`
    } else {
      texto = `COTP-${c.folio} ${accion}.`
    }
    setAccion(''); setMotivo('')
    onAviso(texto); onCambio()
  }

  async function volverAVigente() {
    setOcupado(true); setError('')
    const r = await cambiarEstadoCotizacion(c.id, 'vigente')
    setOcupado(false)
    if (r.error) return setError(r.error)
    onAviso(`COTP-${c.folio} vuelve a estar vigente.`); onCambio()
  }

  async function abrir() {
    const url = await urlDeCotizacion(c.archivo, c.archivo_bucket || 'compras')
    if (url) window.open(url, '_blank', 'noopener')
    else setError('No se pudo abrir el archivo.')
  }

  return (
    <div className="renglon" style={{ display: 'grid', gap: 8 }}>
      <div className="fila" style={{ justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
        <div>
          <div className="renglon-titulo">
            COTP-{c.folio}{mostrarProveedor ? ` · ${c.proveedor}` : ''}{c.numero ? ` · núm. ${c.numero}` : ''}
          </div>
          <div className="renglon-datos">
            {fechaLegible(c.fecha)}
            {c.vigencia && ` · vigente hasta ${fechaLegible(c.vigencia)}`}
            {` · ${piezas} ${piezas === 1 ? 'pieza' : 'piezas'}`}
            {c.moneda === 'USD' && c.tipo_cambio && ` · TC ${c.tipo_cambio}`}
            {Number(c.pedidos) > 0 && ` · ${c.pedidos} pedido(s), ${c.pedidos_recibidos} recibido(s)`}
          </div>
          {c.motivo && c.estado !== 'vigente' && <div className="renglon-datos">Motivo: {c.motivo}</div>}
        </div>
        <div className="renglon-lado">
          <span className="monto">{dinero(c.total, c.moneda)}</span>
          <span className={e.clase}><strong>{e.etiqueta}</strong></span>
        </div>
      </div>

      {piezas > 0 && (
        <details>
          <summary style={{ padding: '12px 0', fontWeight: 600, cursor: 'pointer' }}>Ver las piezas</summary>
          {c.lineas.map((l, i) => (
            <div key={i} className="renglon-datos" style={{ padding: '4px 0' }}>
              {l.cantidad} × {l.nombre} ({l.sku}{l.codigo && l.codigo !== l.sku ? `, su código ${l.codigo}` : ''}) — {dinero(l.precio_unitario, c.moneda)} c/u
            </div>
          ))}
        </details>
      )}

      {error && <Alerta tipo="error">{error}</Alerta>}

      {accion === 'aceptar' && (
        <Alerta tipo="aviso" palabra="Confirma">
          Se pedirán al proveedor las {piezas} piezas de esta cotización (primero se toman los pedidos que
          estaban pendientes de esas mismas piezas). No mueve inventario hasta recibirlas.
          {c.vencida && ' Su vigencia ya pasó: confirma el precio con el proveedor.'}
        </Alerta>
      )}
      {(accion === 'rechazada' || accion === 'cancelada') && (
        <label className="campo">
          <span>¿Por qué? *</span>
          <input value={motivo} onChange={ev => setMotivo(ev.target.value)} />
        </label>
      )}

      {accion ? (
        <div className="fila" style={{ flexWrap: 'wrap' }}>
          <button type="button" className={accion === 'aceptar' ? 'btn-primario' : 'btn-peligro'}
            disabled={ocupado || (accion !== 'aceptar' && !motivo.trim())} onClick={hacer}>
            {ocupado ? 'Guardando…'
              : accion === 'aceptar' ? 'Aceptar y pedir'
                : accion === 'rechazada' ? 'Rechazar' : 'Cancelar la cotización'}
          </button>
          <button type="button" disabled={ocupado} onClick={() => { setAccion(''); setMotivo(''); setError('') }}>No</button>
        </div>
      ) : (
        <div className="fila" style={{ flexWrap: 'wrap' }}>
          {c.estado === 'vigente' && <button type="button" className="btn-primario" onClick={() => setAccion('aceptar')}>Aceptar y pedir…</button>}
          {c.estado === 'vigente' && <button type="button" onClick={() => setAccion('rechazada')}>Rechazar…</button>}
          {['vigente', 'aceptada'].includes(c.estado) && <button type="button" onClick={() => setAccion('cancelada')}>Cancelar…</button>}
          {c.estado === 'rechazada' && <button type="button" disabled={ocupado} onClick={volverAVigente}>Volver a vigente</button>}
          {c.archivo && <button type="button" onClick={abrir}>Ver el archivo</button>}
        </div>
      )}
    </div>
  )
}

export default function CotizacionesProveedor({ proveedorId = null, vuelta = 0, onAviso }) {
  const [datos, setDatos] = useState(null)
  const [propia, setPropia] = useState(0)

  useEffect(() => {
    let vivo = true
    cargarCotizaciones(proveedorId).then(r => { if (vivo) setDatos(r) })
    return () => { vivo = false }
  }, [proveedorId, vuelta, propia])

  if (!datos) return <p>Cargando…</p>
  if (datos.error) return <Alerta tipo="error">{datos.error}</Alerta>
  const lista = datos.data || []
  if (lista.length === 0) {
    return <p style={{ margin: 0 }}>Todavía no hay cotizaciones de proveedor{proveedorId ? ' de este proveedor' : ''}.</p>
  }
  return lista.map(c => (
    <Tarjeta key={c.id} c={c} mostrarProveedor={!proveedorId}
      onCambio={() => setPropia(v => v + 1)} onAviso={t => onAviso?.(t)} />
  ))
}
