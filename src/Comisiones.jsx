import { useEffect, useMemo, useState } from 'react'
import { Alerta } from './ui'
import {
  cargarMisComisiones, copiaLocal, agruparPorMes, filtrar, FILTROS, ESTADOS_COMISION,
  nombreServicio, etiquetaRol, fechaCorta, pesos
} from './lib/comisiones'

// ---------------------------------------------------------------------------
// Mis comisiones (técnico). Lo que se le paga por cada orden que cerró.
//
// Tres estados, siempre con palabra: "En revisión" (la orden cerró pero el administrador aún no
// aprueba el pago: sin cifra, para no prometer un monto que puede ajustarse), "Aprobada" (con su
// monto, por pagar) y "Pagada". Solo ve lo suyo: la base filtra por la sesión, no la pantalla.
// Se guarda una copia en el celular para poder verlas sin señal.
// ---------------------------------------------------------------------------

function Indicadores({ resumen }) {
  return (
    <div className="kpis">
      <div className="kpi kpi-principal kpi-ancho">
        <span className="kpi-nombre">Por cobrar</span>
        <span className="kpi-valor">{pesos(resumen.por_cobrar)}</span>
        <span className="kpi-nota">Aprobado, aún sin pagar</span>
      </div>
      <div className="kpi">
        <span className="kpi-nombre">Pagado este mes</span>
        <span className="kpi-valor">{pesos(resumen.pagado_mes)}</span>
      </div>
      <div className="kpi">
        <span className="kpi-nombre">En revisión</span>
        <span className="kpi-valor">{resumen.en_revision} {resumen.en_revision === 1 ? 'orden' : 'órdenes'}</span>
        <span className="kpi-nota">Esperan aprobación</span>
      </div>
    </div>
  )
}

function RenglonOrden({ o }) {
  const e = ESTADOS_COMISION[o.estado]
  return (
    <li className="renglon">
      <div>
        <div className="renglon-titulo">OS-{o.folio} · {nombreServicio(o.tipo_servicio)}</div>
        <div className="renglon-datos">
          {[o.cliente, fechaCorta(o.fecha), etiquetaRol(o.rol)].filter(Boolean).join(' · ')}
        </div>
      </div>
      <div className="renglon-lado">
        <span className={`estado ${e.clase}`}>{e.etiqueta}</span>
        {o.estado === 'en_revision'
          ? <span className="ayuda">Monto por aprobar</span>
          : <span className="monto">{pesos(o.monto)}</span>}
      </div>
    </li>
  )
}

const textoGuardado = iso =>
  new Date(iso).toLocaleString('es-MX', { dateStyle: 'medium', timeStyle: 'short' })

export default function Comisiones() {
  const inicial = useMemo(() => copiaLocal(), [])
  const [datos, setDatos] = useState(inicial)
  const [aviso, setAviso] = useState('')
  const [cargando, setCargando] = useState(true)
  const [filtro, setFiltro] = useState('todas')
  const [vuelta, setVuelta] = useState(0)

  useEffect(() => {
    let vivo = true
    cargarMisComisiones().then(r => {
      if (!vivo) return
      setCargando(false)
      if (r.datos) setDatos(r.datos)
      if (!r.error) setAviso('')
      else if (r.datos?.guardado_en) setAviso(`Sin conexión: estás viendo lo guardado el ${textoGuardado(r.datos.guardado_en)}`)
      else setAviso(r.error)
    })
    return () => { vivo = false }
  }, [vuelta])

  const ordenes = datos?.ordenes || []
  const conteo = estado => (estado === 'todas' ? ordenes.length : ordenes.filter(o => o.estado === estado).length)
  const grupos = agruparPorMes(filtrar(ordenes, filtro))

  return (
    <div className="pagina pagina-angosta">
      <div className="fila" style={{ justifyContent: 'space-between' }}>
        <h2 style={{ margin: 0 }}>Mis comisiones</h2>
        <button type="button" onClick={() => { setCargando(true); setVuelta(v => v + 1) }} disabled={cargando}>
          {cargando ? 'Actualizando…' : 'Actualizar'}
        </button>
      </div>
      <p className="ayuda">Lo que se te paga por cada orden que cerraste. El monto aparece cuando el administrador lo aprueba.</p>

      {aviso && <Alerta tipo="aviso">{aviso}</Alerta>}

      {!datos && cargando && <p>Cargando…</p>}

      {datos && (
        <>
          <Indicadores resumen={datos.resumen} />

          <div className="pestanas" role="group" aria-label="Filtrar por estado">
            {FILTROS.map(([k, t]) => (
              <button key={k} type="button" className="pestana" aria-pressed={filtro === k} onClick={() => setFiltro(k)}>
                {t} ({conteo(k)})
              </button>
            ))}
          </div>

          {grupos.length === 0 && (
            <div className="tarjeta">
              <p style={{ margin: 0 }}>
                {ordenes.length === 0
                  ? 'Aún no tienes órdenes cerradas en los últimos cuatro meses.'
                  : 'No hay órdenes con ese estado.'}
              </p>
            </div>
          )}

          {grupos.map(g => (
            <section key={g.mes} className="tarjeta" aria-label={g.titulo}>
              <div className="encabezado-grupo" style={{ marginTop: 0 }}>
                <span>{g.titulo}</span>
                <span>
                  Ganado {pesos(g.total)}
                  {g.en_revision > 0 && ` · ${g.en_revision} en revisión`}
                </span>
              </div>
              <ul style={{ listStyle: 'none', margin: 0, padding: 0 }}>
                {g.ordenes.map(o => <RenglonOrden key={`${o.orden_id}-${o.rol}`} o={o} />)}
              </ul>
            </section>
          ))}

          {datos.ajustes.length > 0 && (
            <section className="tarjeta" aria-label="Bonos y descuentos">
              <h3>Bonos y descuentos</h3>
              <ul style={{ listStyle: 'none', margin: 0, padding: 0 }}>
                {datos.ajustes.map((a, i) => {
                  const e = ESTADOS_COMISION[a.estado]
                  const negativo = Number(a.monto) < 0
                  return (
                    <li key={i} className="renglon">
                      <div>
                        <div className="renglon-titulo">{a.concepto}</div>
                        <div className="renglon-datos">
                          {negativo ? 'Descuento' : 'Bono'} · PAGO-{a.pago_folio}{a.fecha_pago ? ` · ${fechaCorta(a.fecha_pago)}` : ''}
                        </div>
                      </div>
                      <div className="renglon-lado">
                        <span className={`estado ${e?.clase || ''}`}>{e?.etiqueta || a.estado}</span>
                        <span className={`monto ${negativo ? 'monto-salida' : ''}`}>{pesos(Math.abs(Number(a.monto)))}</span>
                      </div>
                    </li>
                  )
                })}
              </ul>
            </section>
          )}
        </>
      )}
    </div>
  )
}
