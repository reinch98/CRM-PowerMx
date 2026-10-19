import { useEffect, useState } from 'react'
import { Alerta } from './ui'
import { fechaLegible } from './lib/finanzas'
import { cargarAnticipos, aplicarAnticipo } from './lib/pagosProveedor'

// ---------------------------------------------------------------------------
// Anticipos a proveedores: pagos que todavía no tienen factura (SQL 85). Cuando llega la factura de
// ese proveedor, aquí se le aplica y su saldo baja solo. Se usa en Finanzas → Por pagar (todos) y en
// la carpeta de un proveedor (`proveedorId`). Sin anticipos no dibuja nada si `ocultarVacio`.
// ---------------------------------------------------------------------------

const pesos = v => Number(v || 0).toLocaleString('es-MX', { style: 'currency', currency: 'MXN' })
const nombreFactura = f => [f?.serie, f?.folio].filter(Boolean).join(' ') || 'sin folio'

function Anticipo({ a, mostrarProveedor, onAplicado }) {
  const [cfdi, setCfdi] = useState(a.facturas[0]?.cfdi_id || '')
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')

  async function aplicar() {
    setOcupado(true); setError('')
    const r = await aplicarAnticipo(a.movimiento_id, cfdi)
    setOcupado(false)
    if (r.error) return setError(r.error)
    const f = a.facturas.find(x => x.cfdi_id === cfdi)
    onAplicado(`Anticipo de ${pesos(a.monto)} aplicado a la factura ${nombreFactura(f)}: ${Number(r.data?.saldo) > 0.01 ? `falta ${pesos(r.data.saldo)}` : 'quedó pagada'}.`)
  }

  return (
    <div className="renglon" style={{ display: 'grid', gap: 8 }}>
      <div className="fila" style={{ justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
        <div>
          <div className="renglon-titulo">{mostrarProveedor ? a.proveedor : (a.cotizacion_proveedor ? `Anticipo de ${a.cotizacion_proveedor}` : 'Anticipo')}</div>
          <div className="renglon-datos">
            {[fechaLegible(a.fecha), mostrarProveedor && a.cotizacion_proveedor, a.referencia && `ref. ${a.referencia}`].filter(Boolean).join(' · ')}
          </div>
        </div>
        <div className="renglon-lado"><span className="monto">{pesos(a.monto)}</span><span className="estado-revisa"><strong>Sin factura</strong></span></div>
      </div>
      {error && <Alerta tipo="error">{error}</Alerta>}
      {a.facturas.length === 0 ? (
        <p className="renglon-datos" style={{ margin: 0 }}>Todavía no hay una factura de este proveedor que lo cubra. Cuando llegue, aplícalo aquí.</p>
      ) : (
        <div className="fila" style={{ flexWrap: 'wrap', alignItems: 'flex-end' }}>
          <label className="campo" style={{ flex: '1 1 220px' }}>
            <span>Factura</span>
            <select value={cfdi} onChange={e => setCfdi(e.target.value)}>
              {a.facturas.map(f => (
                <option key={f.cfdi_id} value={f.cfdi_id}>
                  {nombreFactura(f)} · saldo {pesos(f.saldo)}{f.exacta ? ' · cuadra exacto' : ''}
                </option>
              ))}
            </select>
          </label>
          <button type="button" className="btn-primario" disabled={ocupado || !cfdi} onClick={aplicar}>
            {ocupado ? 'Aplicando…' : 'Aplicar a esta factura'}
          </button>
        </div>
      )}
    </div>
  )
}

export default function AnticiposProveedor({ proveedorId = null, vuelta = 0, onAviso, ocultarVacio = false }) {
  const [datos, setDatos] = useState(null)
  const [propia, setPropia] = useState(0)

  useEffect(() => {
    let vivo = true
    cargarAnticipos(proveedorId).then(r => { if (vivo) setDatos(r) })
    return () => { vivo = false }
  }, [proveedorId, vuelta, propia])

  if (!datos) return ocultarVacio ? null : <p>Cargando…</p>
  if (datos.error) return <Alerta tipo="error">{datos.error}</Alerta>
  const lista = datos.data || []
  if (lista.length === 0 && ocultarVacio) return null
  const total = lista.reduce((s, a) => s + Number(a.monto || 0), 0)
  return (
    <section className="tarjeta">
      <h3 style={{ marginTop: 0 }}>Anticipos sin factura ({lista.length})</h3>
      {lista.length === 0
        ? <p style={{ margin: 0 }}>No hay anticipos pendientes de factura.</p>
        : <p className="ayuda">Pagado sin factura todavía: {pesos(total)}. Cuando llegue la factura, aplícale su anticipo.</p>}
      {lista.map(a => (
        <Anticipo key={a.movimiento_id} a={a} mostrarProveedor={!proveedorId}
          onAplicado={t => { setPropia(v => v + 1); onAviso?.(t) }} />
      ))}
    </section>
  )
}
