import { useEffect, useState } from 'react'
import { Alerta } from './ui'
import { pesos, pesosRedondos } from './lib/finanzas'
import {
  cargarTablero, nombreLinea, mesCorto, mesLargo, topeEje, pesosCortos, margenTotal
} from './lib/tablero'

// ---------------------------------------------------------------------------
// Tablero de dirección (SQL 74). Solo admin. Lo que dirección necesita ver sin abrir cinco pantallas:
// cuánto entró y salió mes a mes, cuánto deja cada línea de negocio, quién debe, cuánto cuesta cada
// técnico contra lo que factura y cómo va la operación. Todas las cifras salen de la base.
//
// Gráficas (guía de visualización): un solo eje, barras delgadas con extremo redondeado anclado a la
// base, 2 px entre barras, leyenda con palabra, detalle al pasar o tocar y vista de tabla. Colores
// validados para daltonismo (azul/naranja, ΔE 24.7); el texto nunca va en el color de la serie.
// ---------------------------------------------------------------------------

const PERIODOS = [[3, '3 meses'], [6, '6 meses'], [12, '12 meses']]

// Barra con las esquinas de arriba redondeadas (4 px) y la base recta sobre el eje.
function barra(x, y, w, h) {
  if (h <= 0) return ''
  const r = Math.min(4, h, w / 2)
  return `M${x},${y + h}V${y + r}Q${x},${y} ${x + r},${y}H${x + w - r}Q${x + w},${y} ${x + w},${y + r}V${y + h}Z`
}

function GraficaMensual({ mensual }) {
  const [sel, setSel] = useState(mensual.length - 1)
  const [tabla, setTabla] = useState(false)
  const W = 340, H = 220, izq = 62, der = 6, arriba = 12, abajo = 32
  const ancho = W - izq - der, alto = H - arriba - abajo
  const tope = topeEje(Math.max(...mensual.map(m => Math.max(m.ingresos, m.gastos)), 0))
  const y = v => arriba + alto - (v / tope) * alto
  const gw = ancho / Math.max(mensual.length, 1)
  const bw = Math.max(4, Math.min(18, (gw - 10) / 2))
  const m = mensual[sel] || mensual[mensual.length - 1]
  const verEtiqueta = i => mensual.length <= 6 || i % 2 === (mensual.length - 1) % 2

  return (
    <section className="tarjeta" aria-label="Ingresos y gastos mes a mes">
      <div className="fila" style={{ justifyContent: 'space-between' }}>
        <h3 style={{ margin: 0 }}>Mes a mes</h3>
        <button type="button" onClick={() => setTabla(t => !t)}>{tabla ? 'Ver gráfica' : 'Ver como tabla'}</button>
      </div>
      <div className="fila" style={{ margin: '8px 0' }} aria-hidden="true">
        <span className="fila" style={{ gap: 6 }}><span className="muestra" style={{ background: 'var(--serie-1)' }} /> Ingresos</span>
        <span className="fila" style={{ gap: 6 }}><span className="muestra" style={{ background: 'var(--serie-2)' }} /> Gastos</span>
      </div>

      {m && (
        <p className="detalle-grafica" aria-live="polite">
          <strong style={{ textTransform: 'capitalize' }}>{mesLargo(m.mes)}</strong>: entró {pesos(m.ingresos)}, salió {pesos(m.gastos)}
          {' '}— {m.ingresos - m.gastos >= 0 ? 'quedó a favor' : 'faltó'} {pesos(Math.abs(m.ingresos - m.gastos))}
        </p>
      )}

      {tabla ? (
        <div className="tabla-scroll">
          <table>
            <thead><tr><th>Mes</th><th>Ingresos</th><th>Gastos</th><th>Resultado</th></tr></thead>
            <tbody>
              {mensual.map(x => (
                <tr key={x.mes}>
                  <td style={{ textTransform: 'capitalize' }}>{mesLargo(x.mes)}</td>
                  <td className="monto">{pesos(x.ingresos)}</td>
                  <td className="monto">{pesos(x.gastos)}</td>
                  <td className="monto">{pesos(x.ingresos - x.gastos)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <svg viewBox={`0 0 ${W} ${H}`} width="100%" className="grafica" role="img"
          aria-label={`Ingresos y gastos de ${mensual.length} meses. Usa "Ver como tabla" para leer las cifras.`}>
          {[0, 0.5, 1].map(f => (
            <g key={f}>
              <line x1={izq} x2={W - der} y1={y(tope * f)} y2={y(tope * f)} stroke="var(--linea)" strokeWidth="1" />
              <text x={izq - 6} y={y(tope * f) + 6} textAnchor="end" className="eje">{pesosCortos(tope * f)}</text>
            </g>
          ))}
          {mensual.map((x, i) => {
            const cx = izq + gw * i + gw / 2
            return (
              <g key={x.mes}>
                {i === sel && <rect x={izq + gw * i + 1} y={arriba} width={gw - 2} height={alto} fill="var(--claro)" rx="4" />}
                <path d={barra(cx - bw - 1, y(x.ingresos), bw, arriba + alto - y(x.ingresos))} fill="var(--serie-1)" />
                <path d={barra(cx + 1, y(x.gastos), bw, arriba + alto - y(x.gastos))} fill="var(--serie-2)" />
                {verEtiqueta(i) && <text x={cx} y={H - 8} textAnchor="middle" className="eje">{mesCorto(x.mes)}</text>}
                {/* Zona para tocar: más grande que las barras, todo el alto del mes. */}
                <rect x={izq + gw * i} y={arriba} width={gw} height={alto + abajo} fill="transparent" tabIndex={0}
                  aria-label={`${mesLargo(x.mes)}: ingresos ${pesos(x.ingresos)}, gastos ${pesos(x.gastos)}`}
                  onMouseEnter={() => setSel(i)} onFocus={() => setSel(i)} onClick={() => setSel(i)} />
              </g>
            )
          })}
          <line x1={izq} x2={W - der} y1={arriba + alto} y2={arriba + alto} stroke="var(--borde)" strokeWidth="1" />
        </svg>
      )}
    </section>
  )
}

function MargenPorLinea({ lineas }) {
  if (lineas.length === 0) {
    return (
      <section className="tarjeta" aria-label="Margen por línea de negocio">
        <h3>Margen por línea</h3>
        <p style={{ margin: 0 }}>No hay cotizaciones aceptadas en el periodo.</p>
      </section>
    )
  }
  return (
    <section className="tarjeta" aria-label="Margen por línea de negocio">
      <h3>Margen por línea</h3>
      <p className="ayuda">Real = lo que dejó después de material y gastos del expediente. Cotizado = venta menos material.</p>
      {lineas.map(l => {
        const real = l.margen_real == null ? null : Number(l.margen_real)
        return (
          <div key={l.linea} style={{ marginBottom: 14 }}>
            <div className="fila" style={{ justifyContent: 'space-between' }}>
              <strong>{nombreLinea(l.linea)}</strong>
              <span className="monto">{real == null ? '—' : real < 0 ? `Pérdida ${Math.abs(real)}%` : `${real}%`}</span>
            </div>
            <div className="barra-desglose" aria-hidden="true">
              <span style={{ width: `${Math.max(0, Math.min(100, real || 0))}%`, background: 'var(--serie-1)' }} />
            </div>
            <div className="renglon-datos">
              {l.cotizaciones} {Number(l.cotizaciones) === 1 ? 'cotización' : 'cotizaciones'} · venta {pesos(l.venta)} · dejó {pesos(l.utilidad)}
              {l.margen_cotizado != null && ` · cotizado ${l.margen_cotizado}%`}
              {Number(l.cerradas) < Number(l.cotizaciones) && ` · ${Number(l.cotizaciones) - Number(l.cerradas)} sin cerrar el expediente`}
            </div>
            {l.linea === 'otros' && <div className="renglon-datos">Liga el equipo a esas cotizaciones para clasificarlas.</div>}
          </div>
        )
      })}
    </section>
  )
}

function Cobranza({ cxc }) {
  return (
    <section className="tarjeta" aria-label="Por cobrar">
      <h3>Por cobrar</h3>
      <div className="fila" style={{ justifyContent: 'space-between' }}>
        <span>Total pendiente</span><strong className="monto">{pesos(cxc.total)}</strong>
      </div>
      <div className="fila" style={{ justifyContent: 'space-between' }}>
        <span>Vencido (más de 30 días)</span><strong className="monto">{pesos(cxc.vencido)}</strong>
      </div>
      {cxc.mayores.length > 0 && (
        <>
          <h4>Quién debe más</h4>
          <ul style={{ listStyle: 'none', margin: 0, padding: 0 }}>
            {cxc.mayores.map(c => (
              <li key={c.folio} className="renglon">
                <div>
                  <div className="renglon-titulo">{c.cliente}</div>
                  <div className="renglon-datos">Cotización {c.folio} · hace {c.dias} {Number(c.dias) === 1 ? 'día' : 'días'}</div>
                </div>
                <div className="renglon-lado">
                  <span className={`estado ${Number(c.dias) > 30 ? 'estado-error' : 'estado-revisa'}`}>{Number(c.dias) > 30 ? 'Vencido' : 'Al corriente'}</span>
                  <span className="monto">{pesos(c.saldo)}</span>
                </div>
              </li>
            ))}
          </ul>
        </>
      )}
    </section>
  )
}

function Tecnicos({ tecnicos }) {
  return (
    <section className="tarjeta" aria-label="Técnicos">
      <h3>Técnicos</h3>
      <p className="ayuda">Lo que se le pagó contra lo que facturaron los servicios que hizo como responsable.</p>
      {tecnicos.length === 0 ? <p style={{ margin: 0 }}>No hay técnicos activos.</p> : (
        <ul style={{ listStyle: 'none', margin: 0, padding: 0 }}>
          {tecnicos.map(t => (
            <li key={t.tecnico_id} className="renglon">
              <div>
                <div className="renglon-titulo">{t.nombre}</div>
                <div className="renglon-datos">
                  {t.ordenes} {Number(t.ordenes) === 1 ? 'orden cerrada' : 'órdenes cerradas'} · facturó {pesos(t.ingreso)}
                </div>
              </div>
              <div className="renglon-lado">
                <span className="monto">{pesos(t.pago)}</span>
                <span className="ayuda">{t.pago_pct == null ? 'Sin facturación' : `${t.pago_pct}% de lo facturado`}</span>
              </div>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}

function Operacion({ o }) {
  const alDia = Number(o.en_poliza) > 0 ? Math.round((1 - Number(o.polizas_vencidas) / Number(o.en_poliza)) * 100) : null
  return (
    <section className="tarjeta" aria-label="Operación">
      <h3>Operación</h3>
      <div className="fila" style={{ justifyContent: 'space-between' }}><span>Órdenes cerradas en el periodo</span><strong>{o.cerradas ?? 0}</strong></div>
      <div className="fila" style={{ justifyContent: 'space-between' }}>
        <span>Días de la cita a la orden cerrada</span><strong>{o.dias_respuesta == null ? '—' : o.dias_respuesta}</strong>
      </div>
      <div className="fila" style={{ justifyContent: 'space-between' }}><span>Citas por programar</span><strong>{o.por_programar ?? 0}</strong></div>
      <div className="fila" style={{ justifyContent: 'space-between' }}>
        <span>Pólizas al día</span>
        <strong>{alDia == null ? 'Sin equipos en póliza' : `${alDia}% (${o.en_poliza - o.polizas_vencidas} de ${o.en_poliza})`}</strong>
      </div>
    </section>
  )
}

export default function Tablero() {
  const [meses, setMeses] = useState(6)
  const [leido, setLeido] = useState({ meses: 0, tablero: null, error: '' })
  const cargando = leido.meses !== meses

  useEffect(() => {
    let vivo = true
    cargarTablero(meses).then(r => { if (vivo) setLeido({ meses, tablero: r.tablero || null, error: r.error || '' }) })
    return () => { vivo = false }
  }, [meses])

  const t = leido.tablero
  const margen = t ? margenTotal(t.lineas) : null

  return (
    <div className="pagina pagina-angosta">
      <h2>Tablero</h2>
      <div className="pestanas" role="group" aria-label="Periodo">
        {PERIODOS.map(([k, txt]) => (
          <button key={k} type="button" className="pestana" aria-pressed={meses === k} onClick={() => setMeses(k)}>{txt}</button>
        ))}
      </div>
      {leido.error && !cargando && <Alerta tipo="error">{leido.error}</Alerta>}
      {cargando && !t && <p>Calculando…</p>}

      {t && (
        <div aria-busy={cargando}>
          <div className="kpis">
            <div className="kpi kpi-principal kpi-ancho">
              <span className="kpi-nombre">{t.resumen.resultado >= 0 ? 'Quedó a favor' : 'Faltó'} en {t.periodo.meses} meses</span>
              <span className="kpi-valor">{pesosRedondos(Math.abs(t.resumen.resultado))}</span>
              <span className="kpi-nota">Entró {pesosRedondos(t.resumen.ingresos)} · salió {pesosRedondos(t.resumen.gastos)}</span>
            </div>
            <div className="kpi">
              <span className="kpi-nombre">Margen real</span>
              <span className="kpi-valor">{margen == null ? '—' : `${margen}%`}</span>
              <span className="kpi-nota">De lo vendido</span>
            </div>
            <div className="kpi">
              <span className="kpi-nombre">Por cobrar vencido</span>
              <span className="kpi-valor">{pesosRedondos(t.cxc.vencido)}</span>
              <span className="kpi-nota">{t.cxc.vencidas} {t.cxc.vencidas === 1 ? 'cotización' : 'cotizaciones'}</span>
            </div>
            <div className="kpi">
              <span className="kpi-nombre">Órdenes abiertas</span>
              <span className="kpi-valor">{t.operacion.ordenes_abiertas ?? 0}</span>
              <span className="kpi-nota">{t.operacion.mas_antigua_dias == null ? 'Ninguna' : `La más antigua: ${t.operacion.mas_antigua_dias} días`}</span>
            </div>
            <div className="kpi">
              <span className="kpi-nombre">Por cobrar</span>
              <span className="kpi-valor">{pesosRedondos(t.cxc.total)}</span>
              <span className="kpi-nota">Total pendiente</span>
            </div>
          </div>

          <GraficaMensual key={`${meses}-${t.mensual.length}`} mensual={t.mensual} />
          <MargenPorLinea lineas={t.lineas} />
          <Cobranza cxc={t.cxc} />
          <Tecnicos tecnicos={t.tecnicos} />
          <Operacion o={t.operacion} />
        </div>
      )}
    </div>
  )
}
