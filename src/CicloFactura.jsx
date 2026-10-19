import { useEffect, useState } from 'react'
import { Alerta } from './ui'
import FacturaLeida from './FacturaLeida'
import {
  cargarContextoFactura, cargarCfdi, ligarFactura, desligarFactura, lecturaDesdeCfdi, pesos,
  textoCompra, textoCotizacion, textoAnticipo, sumaAnticipos, problemaDeAnticipos, avisoPagoDoble
} from './lib/facturaCiclo'

// ---------------------------------------------------------------------------
// La factura cierra el ciclo (SQL 86): de una factura recibida se ve su COMPRA (el material que entró
// al almacén), su COTIZACIÓN de proveedor y sus PAGOS. Lo seguro ya lo ligó la base; lo dudoso se ofrece
// con un toque, y lo que esté mal se suelta. Si es material que no ha entrado, se mete al almacén desde
// el mismo XML, sin volver a leerlo. En la bandeja, además, se eligen los anticipos que la pagan.
// ---------------------------------------------------------------------------

const fechaCorta = f => (/^\d{4}-\d{2}-\d{2}/.test(String(f || '')) ? String(f).slice(0, 10).split('-').reverse().join('/') : '')

export default function CicloFactura({ ctx, cfdi, pagado = false, anticipos = null, onAnticipos, onRecargar, onAviso }) {
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')
  const [almacen, setAlmacen] = useState(null)   // la lectura armada del XML, mientras se mete al almacén

  async function correr(promesa, texto) {
    setOcupado(true); setError('')
    const r = await promesa
    setOcupado(false)
    if (r.error) return setError(r.error)
    if (texto) onAviso?.(texto)
    onRecargar?.()
  }

  async function abrirAlmacen() {
    setError('')
    let fila = cfdi
    if (!fila?.conceptos) {
      setOcupado(true)
      const r = await cargarCfdi(ctx.factura.id)
      setOcupado(false)
      if (r.error) return setError(r.error)
      fila = r.data
    }
    setAlmacen(lecturaDesdeCfdi(fila, ctx.factura.proveedor))
  }

  if (!ctx) return null
  const f = ctx.factura
  const elegidos = anticipos || []
  const suma = sumaAnticipos(ctx, elegidos)
  const problema = problemaDeAnticipos(ctx, elegidos)
  const doble = avisoPagoDoble(ctx, pagado)
  const conAnticipos = !!onAnticipos && ctx.anticipos.length > 0

  function marcar(id, si) {
    const nuevos = si ? [...elegidos, id] : elegidos.filter(x => x !== id)
    onAnticipos(nuevos)
  }

  return (
    <div className="tarjeta" style={{ marginBottom: 12 }}>
      <h3 style={{ marginTop: 0 }}>Compra, cotización y pagos</h3>
      {error && <Alerta tipo="error">{error}</Alerta>}

      {/* La compra: el material de esta factura en el almacén */}
      {ctx.compra ? (
        <div style={{ marginBottom: 12 }}>
          <div className="fila" style={{ justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
            <strong>{textoCompra(ctx.compra)}</strong>
            <span className="estado estado-aprobado"><strong>Ligada</strong></span>
          </div>
          <p className="ayuda" style={{ margin: '4px 0 8px' }}>
            {ctx.compra.entro ? 'El material entró al almacén con esta compra.' : 'El material ya había entrado por su pedido; la compra guarda el costo.'}
          </p>
          <button type="button" disabled={ocupado}
            onClick={() => correr(desligarFactura(f.id, 'compra'), 'La factura ya no está ligada a esa compra.')}>
            No es esa compra
          </button>
        </div>
      ) : almacen ? (
        <div style={{ marginBottom: 12 }}>
          <h4 style={{ margin: '0 0 8px' }}>Meter al almacén con esta factura</h4>
          <FacturaLeida lecturaInicial={almacen}
            onRegistrada={t => { setAlmacen(null); onAviso?.(`${t} Quedó ligada a esta factura.`); onRecargar?.() }}
            onCancelar={() => setAlmacen(null)} />
        </div>
      ) : (
        <div style={{ marginBottom: 12 }}>
          <p style={{ margin: '0 0 8px' }}><strong>Sin compra en el almacén.</strong></p>
          {ctx.compras_posibles.length > 0 && (
            <>
              <p className="ayuda" style={{ margin: '0 0 6px' }}>¿Es una de estas compras de {f.proveedor || 'este proveedor'}?</p>
              <div className="buscador-lista" style={{ position: 'static', marginBottom: 8 }}>
                {ctx.compras_posibles.map(co => (
                  <button key={co.id} type="button" disabled={ocupado}
                    onClick={() => correr(ligarFactura(f.id, { compra: co.id }), `Factura ligada a la compra ${co.folio}.`)}>
                    Es la {textoCompra(co)}
                    <span className="ayuda">{[co.cuadra && 'cuadra el total', co.mismo_folio && 'mismo folio'].filter(Boolean).join(' · ') || 'otro total'}</span>
                  </button>
                ))}
              </div>
            </>
          )}
          <button type="button" disabled={ocupado} onClick={abrirAlmacen}>Meter al almacén con esta factura…</button>
          <p className="ayuda" style={{ margin: '6px 0 0' }}>Solo si es material. Un servicio o una renta no entra al almacén.</p>
        </div>
      )}

      {/* La cotización de proveedor */}
      {ctx.cotizacion ? (
        <div style={{ marginBottom: 12 }}>
          <div className="fila" style={{ justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
            <strong>De la cotización {textoCotizacion(ctx.cotizacion)}</strong>
            <span className="estado estado-aprobado"><strong>Ligada</strong></span>
          </div>
          {ctx.cotizacion.directa ? (
            <button type="button" disabled={ocupado} style={{ marginTop: 8 }}
              onClick={() => correr(desligarFactura(f.id, 'cotizacion'), 'La factura ya no está ligada a esa cotización.')}>
              No es de esa cotización
            </button>
          ) : <p className="ayuda" style={{ margin: '4px 0 0' }}>La heredó de su compra (sus pedidos salieron de esa cotización).</p>}
        </div>
      ) : ctx.cotizaciones_posibles.length > 0 && (
        <div style={{ marginBottom: 12 }}>
          <p className="ayuda" style={{ margin: '0 0 6px' }}>¿Es de una de estas cotizaciones de proveedor?</p>
          <div className="buscador-lista" style={{ position: 'static' }}>
            {ctx.cotizaciones_posibles.map(q => (
              <button key={q.id} type="button" disabled={ocupado}
                onClick={() => correr(ligarFactura(f.id, { cotizacion: q.id }), `Factura ligada a la cotización COTP-${q.folio}.`)}>
                Es de la {textoCotizacion(q)}
                <span className="ayuda">{q.cuadra ? 'cuadra el total' : 'otro total'}</span>
              </button>
            ))}
          </div>
        </div>
      )}

      {/* Lo ya pagado */}
      {ctx.pagos.length > 0 && (
        <div style={{ marginBottom: 12 }}>
          <p style={{ margin: '0 0 4px' }}><strong>Pagos de esta factura</strong></p>
          {ctx.pagos.map(p => (
            <div key={p.id} className="renglon-datos">
              {[pesos(p.monto), fechaCorta(p.fecha) && `el ${fechaCorta(p.fecha)}`, p.anticipo && 'anticipo', p.referencia && `ref. ${p.referencia}`].filter(Boolean).join(' · ')}
            </div>
          ))}
          <div className="renglon-datos"><strong>Falta: {pesos(f.saldo)}</strong></div>
        </div>
      )}

      {/* Anticipos que la pagan (solo al aprobar, en la bandeja) */}
      {conAnticipos && (
        <div>
          <p style={{ margin: '0 0 4px' }}><strong>Anticipos a {f.proveedor || 'este proveedor'} sin factura</strong></p>
          {ctx.anticipos.map(a => (
            <label key={a.movimiento_id} className="campo" style={{ marginBottom: 6 }}>
              <span>
                <input type="checkbox" disabled={!a.cabe} checked={elegidos.includes(a.movimiento_id)}
                  onChange={e => marcar(a.movimiento_id, e.target.checked)} />
                {' '}{textoAnticipo(a)}{a.de_su_cotizacion ? ' · de su cotización' : ''}{!a.cabe ? ' · es mayor que lo que se debe' : ''}
              </span>
            </label>
          ))}
          {elegidos.length > 0 && !problema && (
            <p className="ayuda" style={{ margin: '4px 0 0' }}>
              Al aprobar, la factura queda por pagar y estos anticipos la abonan ({pesos(suma)}):
              {' '}{Number(f.saldo) - suma > 0.01 ? `quedaría por pagar ${pesos(Number(f.saldo) - suma)}.` : 'queda pagada.'}
            </p>
          )}
          {problema && <Alerta tipo="aviso">{problema}</Alerta>}
        </div>
      )}
      {doble && <Alerta tipo="aviso" palabra="¿Ya está pagada?">{doble}</Alerta>}
    </div>
  )
}

// La misma vista para una factura que ya salió de la bandeja (Por pagar): se carga sola y no elige anticipos
// (esos se aplican en "Anticipos sin factura").
export function CicloFacturaSola({ cfdiId, onAviso }) {
  const [ctx, setCtx] = useState(null)
  const [error, setError] = useState('')
  const [vuelta, setVuelta] = useState(0)

  useEffect(() => {
    let vivo = true
    cargarContextoFactura(cfdiId).then(r => {
      if (!vivo) return
      if (r.error) setError(r.error)
      else setCtx(r.data)
    })
    return () => { vivo = false }
  }, [cfdiId, vuelta])

  if (error) return <Alerta tipo="error">{error}</Alerta>
  if (!ctx) return <p>Buscando su compra y sus pagos…</p>
  return <CicloFactura ctx={ctx} onRecargar={() => setVuelta(v => v + 1)} onAviso={onAviso} />
}
