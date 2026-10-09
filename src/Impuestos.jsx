import { useEffect, useState } from 'react'
import { Alerta } from './ui'
import { hoyLocal } from './lib/fechas'
import { pesos, pesosRedondos, nombreDeMes, fechaLegible, etiquetaCategoria } from './lib/finanzas'
import {
  mesesDisponibles, mesPorOmision, porcentaje, resultadoIva, csvContador,
  cargarReporte, cargarTasas, guardarTasa
} from './lib/resico'

// ---------------------------------------------------------------------------
// Impuestos: reporte mensual RESICO (SQL 73). Las cifras salen de la base; esto es un ESTIMADO para
// revisar con el contador, no una declaración. Lo primero que se ve es lo que hay que pagar y cuándo.
// ---------------------------------------------------------------------------

function Dato({ etiqueta, valor, fuerte }) {
  return (
    <div className="fila" style={{ justifyContent: 'space-between', gap: 12, padding: '4px 0' }}>
      <span>{etiqueta}</span>
      {fuerte ? <strong className="monto">{valor}</strong> : <span className="monto" style={{ fontWeight: 600 }}>{valor}</span>}
    </div>
  )
}

function descargar(texto, nombre) {
  const url = URL.createObjectURL(new Blob([texto], { type: 'text/csv;charset=utf-8' }))
  const a = document.createElement('a')
  a.href = url
  a.download = nombre
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}

function Tasas({ anio }) {
  const [leido, setLeido] = useState({ anio: null, tasas: [], error: '' })
  const [editadas, setEditadas] = useState({})
  const [msg, setMsg] = useState(null)
  const [vuelta, setVuelta] = useState(0)

  useEffect(() => {
    let vivo = true
    cargarTasas(anio).then(r => { if (vivo) setLeido({ anio, tasas: r.tasas || [], error: r.error || '' }) })
    return () => { vivo = false }
  }, [anio, vuelta])

  async function guardar(t) {
    const r = await guardarTasa(anio, t.desde, editadas[t.desde])
    setMsg(r.error ? { tipo: 'error', texto: r.error } : { tipo: 'ok', texto: 'Tasa guardada.' })
    if (!r.error) { setEditadas(e => ({ ...e, [t.desde]: undefined })); setVuelta(v => v + 1) }
  }

  return (
    <details className="tarjeta">
      <summary className="resumen">Tasas de ISR RESICO {anio}</summary>
      <p className="ayuda">La tasa se aplica al total de ingresos del mes (sin IVA) según el tramo en que cae. Confírmalas con tu contador.</p>
      {leido.error && <Alerta tipo="error">{leido.error}</Alerta>}
      {msg && <Alerta tipo={msg.tipo}>{msg.texto}</Alerta>}
      {leido.anio === anio && leido.tasas.length === 0 && <p>No hay tasas capturadas para {anio}.</p>}
      <ul style={{ listStyle: 'none', margin: 0, padding: 0 }}>
        {leido.tasas.map(t => {
          const valor = editadas[t.desde] ?? String(Math.round(Number(t.tasa) * 10000) / 100)
          return (
            <li key={t.desde} className="renglon">
              <div>
                <div className="renglon-titulo">{pesos(t.desde)} a {pesos(t.hasta)}</div>
                <label className="campo" style={{ marginBottom: 0 }}>
                  <span>Tasa en %</span>
                  <input type="number" inputMode="decimal" min="0" step="0.01" value={valor}
                    onChange={e => setEditadas(x => ({ ...x, [t.desde]: e.target.value }))} />
                </label>
              </div>
              <button type="button" disabled={editadas[t.desde] == null} onClick={() => guardar(t)}>Guardar</button>
            </li>
          )
        })}
      </ul>
    </details>
  )
}

export default function Impuestos({ empresa }) {
  const hoy = hoyLocal()
  const meses = mesesDisponibles(empresa?.resico_desde || hoy, hoy)
  const [mes, setMes] = useState(() => mesPorOmision(hoy, meses))
  const [leido, setLeido] = useState({ mes: '', reporte: null, error: '' })
  const cargando = leido.mes !== mes

  useEffect(() => {
    let vivo = true
    if (!mes) return undefined
    cargarReporte(mes).then(r => { if (vivo) setLeido({ mes, reporte: r.reporte || null, error: r.error || '' }) })
    return () => { vivo = false }
  }, [mes])

  if (!mes) return <Alerta tipo="aviso">Captura tus datos fiscales en Ajustes para ver el reporte.</Alerta>

  const r = leido.reporte
  const i = meses.indexOf(mes)
  const iva = resultadoIva(r?.iva)

  return (
    <>
      <div className="cambio-mes">
        <button type="button" onClick={() => setMes(meses[i + 1])} disabled={i >= meses.length - 1} aria-label="Mes anterior">‹</button>
        <strong>{nombreDeMes(mes)}</strong>
        <button type="button" onClick={() => setMes(meses[i - 1])} disabled={i <= 0} aria-label="Mes siguiente">›</button>
      </div>

      {leido.error && !cargando && <Alerta tipo="error">{leido.error}</Alerta>}
      {cargando && <p>Calculando…</p>}

      {r && !cargando && (
        <>
          <Alerta tipo="info">
            Estimado para revisar con tu contador. Se paga a más tardar el {fechaLegible(r.periodo.limite_pago)}.
          </Alerta>

          <div className="kpis">
            <div className="kpi kpi-principal">
              <span className="kpi-nombre">ISR estimado a pagar</span>
              <span className="kpi-valor">{pesosRedondos(r.isr.a_pagar)}</span>
              <span className="kpi-nota">Tasa {porcentaje(r.isr.tasa)}</span>
            </div>
            <div className="kpi">
              <span className="kpi-nombre">{iva.etiqueta}</span>
              <span className="kpi-valor">{pesosRedondos(iva.monto)}</span>
              <span className="kpi-nota">{iva.aFavor ? 'Se puede acreditar o pedir en devolución' : 'Por pagar'}</span>
            </div>
            <div className="kpi">
              <span className="kpi-nombre">Ingresos sin IVA</span>
              <span className="kpi-valor">{pesosRedondos(r.ingresos.base)}</span>
              <span className="kpi-nota">Cobrado en el periodo</span>
            </div>
            <div className="kpi">
              <span className="kpi-nombre">Acumulado del año</span>
              <span className="kpi-valor">{pesosRedondos(r.anual.acumulado)}</span>
              <span className="kpi-nota">{r.anual.pct}% del tope de RESICO</span>
            </div>
          </div>

          {r.avisos.map((a, k) => <Alerta key={k} tipo="aviso">{a}</Alerta>)}

          <div className="rejilla-2">
            <section className="tarjeta" aria-label="Cálculo del ISR">
              <h3>ISR</h3>
              <Dato etiqueta="Cobrado (con IVA)" valor={pesos(r.ingresos.cobrado)} />
              <Dato etiqueta="IVA de lo cobrado" valor={pesos(r.ingresos.iva)} />
              <Dato etiqueta="Base (sin IVA)" valor={pesos(r.ingresos.base)} />
              <Dato etiqueta={`Tasa ${porcentaje(r.isr.tasa)}`} valor={pesos(r.isr.causado)} />
              <Dato etiqueta="Te retuvieron" valor={pesos(r.isr.retenido)} />
              <Dato etiqueta="A pagar" valor={pesos(r.isr.a_pagar)} fuerte />
            </section>
            <section className="tarjeta" aria-label="Cálculo del IVA">
              <h3>IVA</h3>
              <Dato etiqueta="Trasladado (de lo cobrado)" valor={pesos(r.iva.trasladado)} />
              <Dato etiqueta="Acreditable (gastos con CFDI)" valor={pesos(r.iva.acreditable)} />
              <Dato etiqueta="Te retuvieron" valor={pesos(r.iva.retenido)} />
              <Dato etiqueta={iva.etiqueta} valor={pesos(iva.monto)} fuerte />
            </section>
          </div>

          <button type="button" className="btn-primario btn-grande" style={{ marginBottom: 16 }}
            onClick={() => descargar(csvContador(r, empresa?.razon_social), `RESICO-${mes}.csv`)}>
            Descargar para el contador (CSV)
          </button>

          <details className="tarjeta">
            <summary className="resumen">Ingresos del periodo ({r.ingresos.detalle.length})</summary>
            {r.ingresos.detalle.length === 0 && <p>Sin cobros en el periodo.</p>}
            <ul style={{ listStyle: 'none', margin: 0, padding: 0 }}>
              {r.ingresos.detalle.map((x, k) => (
                <li key={k} className="renglon">
                  <div>
                    <div className="renglon-titulo">{x.cliente || x.concepto || 'Ingreso'}</div>
                    <div className="renglon-datos">
                      {[fechaLegible(x.fecha), x.cotizacion && `Cotización ${x.cotizacion}`, x.factura ? 'Con factura' : 'Sin factura'].filter(Boolean).join(' · ')}
                    </div>
                  </div>
                  <div className="renglon-lado">
                    <span className="monto">{pesos(x.monto)}</span>
                    <span className="ayuda">IVA {pesos(x.iva)}</span>
                  </div>
                </li>
              ))}
            </ul>
          </details>

          <details className="tarjeta">
            <summary className="resumen">Gastos del periodo ({r.gastos.detalle.length})</summary>
            {r.gastos.detalle.length === 0 && <p>Sin gastos en el periodo.</p>}
            <ul style={{ listStyle: 'none', margin: 0, padding: 0 }}>
              {r.gastos.detalle.map((x, k) => (
                <li key={k} className="renglon">
                  <div>
                    <div className="renglon-titulo">{x.proveedor || x.concepto || etiquetaCategoria(x.categoria)}</div>
                    <div className="renglon-datos">
                      {[fechaLegible(x.fecha), etiquetaCategoria(x.categoria), x.con_cfdi ? 'Con CFDI' : 'Sin CFDI'].join(' · ')}
                    </div>
                  </div>
                  <div className="renglon-lado">
                    <span className="monto">{pesos(x.monto)}</span>
                    <span className="ayuda">IVA {pesos(x.iva)}</span>
                  </div>
                </li>
              ))}
            </ul>
          </details>

          <Tasas anio={Number(mes.slice(0, 4))} />
        </>
      )}
    </>
  )
}
