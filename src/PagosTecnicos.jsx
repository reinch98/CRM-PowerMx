import { useEffect, useState } from 'react'
import { Alerta } from './ui'
import { hoyLocal } from './lib/fechas'
import { listarCuentas } from './lib/finanzas'
import {
  porPagarTecnicos, proponerPago, ajustarPago, quitarLinea, aprobarPago, registrarPago, cancelarPago,
  reabrirPago, fijarMontoLinea, textoReabierto, corregirFormaPago, textoFormaCorregida, FORMAS_PAGO_TECNICO, etiquetaForma,
  cargarPagos, cargarTarifas, guardarTarifa, nombresTecnicos, infoOrdenes, cargarCorte, guardarCorte,
  ESTADOS_PAGO, TIPOS_SERVICIO, nombreServicio, etiquetaRol, fechaCorta, pesos
} from './lib/comisiones'

// ---------------------------------------------------------------------------
// Pago a técnicos (SQL 66–67). Solo admin.
//
// Tres pasos y un responsable: el sistema ARMA el pago con las órdenes cerradas y su tarifa; tú
// lo revisas (bonos, descuentos, quitar una orden) y lo APRUEBAS; cuando le pagas, lo REGISTRAS.
// Al aprobar, el técnico ya ve el monto de cada orden en "Mis comisiones".
// Nada se paga solo, y una orden no se le paga dos veces a la misma persona.
// ---------------------------------------------------------------------------

async function leerTodo() {
  const [porPagar, pagos, tarifas, nombres, cuentas, corte] = await Promise.all([
    porPagarTecnicos(), cargarPagos(), cargarTarifas(), nombresTecnicos(), listarCuentas(), cargarCorte()
  ])
  const ids = (pagos.pagos || []).flatMap(p => p.lineas.map(l => l.orden_id))
  return {
    porPagar: porPagar.data || [], pagos: pagos.pagos || [], tarifas: tarifas.tarifas || [],
    pagarDesde: corte.pagar_desde || '',
    nombres, cuentas: (cuentas.cuentas || []).filter(c => c.activa),
    ordenes: await infoOrdenes(ids),
    error: porPagar.error || pagos.error || tarifas.error || ''
  }
}

function PorPagar({ lista, nombres, onArmado }) {
  const [periodos, setPeriodos] = useState({})
  const [ocupado, setOcupado] = useState('')
  const [error, setError] = useState('')
  const periodo = t => periodos[t.tecnico_id] || { desde: t.mas_antigua, hasta: hoyLocal() }
  const cambiar = (id, campo, valor, base) => setPeriodos(p => ({ ...p, [id]: { ...base, [campo]: valor } }))

  async function armar(t) {
    setError(''); setOcupado(t.tecnico_id)
    const p = periodo(t)
    const r = await proponerPago(t.tecnico_id, p.desde, p.hasta)
    setOcupado('')
    if (r.error) return setError(r.error)
    onArmado(r.data, nombres[t.tecnico_id] || t.nombre)
  }

  if (lista.length === 0) {
    return <div className="tarjeta"><p style={{ margin: 0 }}>No hay órdenes cerradas pendientes de pagar.</p></div>
  }
  return (
    <>
      {error && <Alerta tipo="error">{error}</Alerta>}
      {lista.map(t => {
        const p = periodo(t)
        return (
          <section key={t.tecnico_id} className="tarjeta">
            <div className="renglon" style={{ paddingTop: 0 }}>
              <div>
                <div className="renglon-titulo">{nombres[t.tecnico_id] || t.nombre || 'Técnico'}</div>
                <div className="renglon-datos">
                  {t.ordenes} {t.ordenes === 1 ? 'orden cerrada' : 'órdenes cerradas'} sin pagar · la más antigua del {fechaCorta(t.mas_antigua)}
                </div>
              </div>
              <div className="renglon-lado">
                <span className="kpi-nombre">Estimado</span>
                <span className="monto">{pesos(t.estimado)}</span>
              </div>
            </div>
            {t.sin_tarifa > 0 && (
              <Alerta tipo="aviso">
                {t.sin_tarifa === 1
                  ? '1 orden no tiene tarifa: no se pagará hasta que la captures en la pestaña Tarifas.'
                  : `${t.sin_tarifa} órdenes no tienen tarifa: no se pagarán hasta que la captures en la pestaña Tarifas.`}
              </Alerta>
            )}
            <div className="rejilla-2">
              <label className="campo">
                <span>Desde</span>
                <input type="date" value={p.desde || ''} onChange={e => cambiar(t.tecnico_id, 'desde', e.target.value, p)} />
              </label>
              <label className="campo">
                <span>Hasta</span>
                <input type="date" value={p.hasta || ''} onChange={e => cambiar(t.tecnico_id, 'hasta', e.target.value, p)} />
              </label>
            </div>
            <button type="button" className="btn-primario" disabled={!!ocupado} onClick={() => armar(t)}>
              {ocupado === t.tecnico_id ? 'Armando…' : 'Armar el pago'}
            </button>
          </section>
        )
      })}
    </>
  )
}

function TarjetaPago({ pago, nombre, ordenes, cuentas, onCambio, onAviso }) {
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')
  const [ajuste, setAjuste] = useState({ concepto: '', monto: '', signo: 'bono' })
  const [pagoForm, setPagoForm] = useState({ forma: 'transferencia', fecha: hoyLocal(), referencia: '', cuenta_id: '' })
  const [cancelando, setCancelando] = useState(false)
  const [motivo, setMotivo] = useState('')
  const [corrigiendo, setCorrigiendo] = useState(false)
  const [motivoCorr, setMotivoCorr] = useState('')
  const [montoLinea, setMontoLinea] = useState({ id: '', monto: '' })
  // Corregir la forma de un pago ya registrado (null = cerrado); arranca con lo que está guardado.
  const [formaCorr, setFormaCorr] = useState(null)
  const e = ESTADOS_PAGO[pago.estado]
  const nombreCuenta = id => cuentas.find(c => c.id === id)?.nombre
  const editable = pago.estado === 'propuesto'

  async function correr(fn) {
    setError(''); setOcupado(true)
    const r = await fn()
    setOcupado(false)
    if (r?.error) return setError(r.error)
    onCambio()
  }

  const servicios = pago.lineas.filter(l => l.clase === 'servicio')
  const ajustes = pago.lineas.filter(l => l.clase === 'ajuste')

  return (
    <section className="tarjeta">
      <div className="renglon" style={{ paddingTop: 0 }}>
        <div>
          <div className="renglon-titulo">{nombre} · PAGO-{pago.folio}</div>
          <div className="renglon-datos">
            Del {fechaCorta(pago.periodo_desde)} al {fechaCorta(pago.periodo_hasta)}
            {pago.estado === 'pagado' && pago.fecha_pago && ` · pagado el ${fechaCorta(pago.fecha_pago)}`}
          </div>
          {pago.estado === 'pagado' && (
            <div className="renglon-datos">
              {[etiquetaForma(pago.forma), nombreCuenta(pago.cuenta_id) || 'sin cuenta', pago.referencia && `Ref. ${pago.referencia}`]
                .filter(Boolean).join(' · ')}
            </div>
          )}
        </div>
        <div className="renglon-lado">
          <span className={`estado ${e.clase}`}>{e.etiqueta}</span>
          <span className="monto" style={{ fontSize: 22 }}>{pesos(pago.total)}</span>
        </div>
      </div>

      {error && <Alerta tipo="error">{error}</Alerta>}

      <ul style={{ listStyle: 'none', margin: 0, padding: 0 }}>
        {servicios.map(l => {
          const o = ordenes[l.orden_id]
          const enEdicion = editable && montoLinea.id === l.id
          return (
            <li key={l.id}>
              <div className="renglon">
                <div>
                  <div className="renglon-titulo">OS-{o?.folio ?? '—'} · {nombreServicio(l.tipo_servicio)}</div>
                  <div className="renglon-datos">
                    {[o?.cliente?.nombre, o && fechaCorta(o.fecha), etiquetaRol(l.rol), !l.cotizacion_id && 'sin cotización'].filter(Boolean).join(' · ')}
                  </div>
                </div>
                <div className="renglon-lado">
                  <span className="monto">{pesos(l.monto)}</span>
                </div>
              </div>
              {/* Los botones van en su propio renglón: al lado del monto aplastaban la descripción en el celular. */}
              {editable && !enEdicion && (
                <div className="fila" style={{ justifyContent: 'flex-end', paddingBottom: 10 }}>
                  <button type="button" disabled={ocupado} onClick={() => setMontoLinea({ id: l.id, monto: String(l.monto) })}
                    aria-label={`Cambiar el monto de la orden OS-${o?.folio ?? ''}`}>Cambiar monto</button>
                  <button type="button" disabled={ocupado} onClick={() => correr(() => quitarLinea(l.id))}
                    aria-label={`Quitar la orden OS-${o?.folio ?? ''} de este pago`}>Quitar</button>
                </div>
              )}
              {enEdicion && (
                <div className="fila" style={{ alignItems: 'flex-end', paddingBottom: 12 }}>
                  <label className="campo" style={{ flex: '1 1 160px', marginBottom: 0 }}>
                    <span>Monto de esta orden</span>
                    <input type="number" inputMode="decimal" min="0" step="0.01" value={montoLinea.monto} autoFocus
                      onChange={ev => setMontoLinea(m => ({ ...m, monto: ev.target.value }))} />
                  </label>
                  <button type="button" className="btn-primario" disabled={ocupado || montoLinea.monto === '' || Number(montoLinea.monto) < 0}
                    onClick={() => correr(async () => {
                      const r = await fijarMontoLinea(l.id, montoLinea.monto)
                      if (!r.error) setMontoLinea({ id: '', monto: '' })
                      return r
                    })}>Guardar</button>
                  <button type="button" onClick={() => setMontoLinea({ id: '', monto: '' })}>Cancelar</button>
                </div>
              )}
            </li>
          )
        })}
        {ajustes.map(l => (
          <li key={l.id} className="renglon">
            <div>
              <div className="renglon-titulo">{l.concepto}</div>
              <div className="renglon-datos">{Number(l.monto) < 0 ? 'Descuento' : 'Bono'}</div>
            </div>
            <div className="renglon-lado">
              <span className={`monto ${Number(l.monto) < 0 ? 'monto-salida' : ''}`}>{pesos(Math.abs(Number(l.monto)))}</span>
              {editable && <button type="button" disabled={ocupado} onClick={() => correr(() => quitarLinea(l.id))}>Quitar</button>}
            </div>
          </li>
        ))}
        {pago.lineas.length === 0 && <li className="ayuda">Este pago no tiene líneas.</li>}
      </ul>

      {editable && (
        <details className="tarjeta" style={{ marginTop: 12 }}>
          <summary className="resumen">Agregar un bono, descuento o anticipo</summary>
          <div className="opciones" role="radiogroup" aria-label="Tipo de ajuste" style={{ margin: '12px 0' }}>
            {[['bono', 'Bono (suma)'], ['descuento', 'Descuento o anticipo (resta)']].map(([k, t]) => (
              <button key={k} type="button" role="radio" className="opcion" aria-checked={ajuste.signo === k}
                onClick={() => setAjuste(a => ({ ...a, signo: k }))}>{t}</button>
            ))}
          </div>
          <div className="rejilla-2">
            <label className="campo">
              <span>Concepto *</span>
              <input value={ajuste.concepto} onChange={ev => setAjuste(a => ({ ...a, concepto: ev.target.value }))} placeholder="Bono por puntualidad" />
            </label>
            <label className="campo">
              <span>Monto *</span>
              <input type="number" inputMode="decimal" min="0" step="0.01" value={ajuste.monto}
                onChange={ev => setAjuste(a => ({ ...a, monto: ev.target.value }))} />
            </label>
          </div>
          <button type="button" disabled={ocupado || !ajuste.concepto.trim() || !(Number(ajuste.monto) > 0)}
            onClick={() => correr(async () => {
              const r = await ajustarPago(pago.id, ajuste.concepto.trim(), (ajuste.signo === 'descuento' ? -1 : 1) * Number(ajuste.monto))
              if (!r.error) setAjuste({ concepto: '', monto: '', signo: 'bono' })
              return r
            })}>Agregar</button>
        </details>
      )}

      {pago.estado === 'aprobado' && (
        <div className="tarjeta" style={{ marginTop: 12, background: 'var(--claro)' }}>
          <h3 style={{ marginTop: 0 }}>Registrar que ya le pagaste</h3>
          <div className="rejilla-2">
            <label className="campo">
              <span>Forma</span>
              <select value={pagoForm.forma} onChange={ev => setPagoForm(f => ({ ...f, forma: ev.target.value }))}>
                <option value="transferencia">Transferencia</option>
                <option value="efectivo">Efectivo</option>
                <option value="otro">Otra</option>
              </select>
            </label>
            <label className="campo">
              <span>Cuenta de donde salió</span>
              <select value={pagoForm.cuenta_id} onChange={ev => setPagoForm(f => ({ ...f, cuenta_id: ev.target.value }))}>
                <option value="">— Sin especificar —</option>
                {cuentas.map(c => <option key={c.id} value={c.id}>{c.nombre}</option>)}
              </select>
            </label>
            <label className="campo">
              <span>Fecha del pago</span>
              <input type="date" value={pagoForm.fecha} onChange={ev => setPagoForm(f => ({ ...f, fecha: ev.target.value }))} />
            </label>
            <label className="campo">
              <span>Referencia (opcional)</span>
              <input value={pagoForm.referencia} onChange={ev => setPagoForm(f => ({ ...f, referencia: ev.target.value }))} placeholder="Clave de rastreo" />
            </label>
          </div>
          <button type="button" className="btn-primario btn-grande" disabled={ocupado}
            onClick={() => correr(() => registrarPago(pago.id, pagoForm))}>
            Registrar pago de {pesos(pago.total)}
          </button>
          <p className="ayuda">Se carga como egreso al expediente de cada cotización; lo que no tiene cotización va al libro general.</p>
        </div>
      )}

      {editable && (
        <button type="button" className="btn-primario btn-grande" style={{ marginTop: 12 }}
          disabled={ocupado || !(Number(pago.total) > 0)} onClick={() => correr(() => aprobarPago(pago.id))}>
          Aprobar {pesos(pago.total)}
        </button>
      )}
      {editable && <p className="ayuda">Al aprobar, {nombre} verá el monto de cada orden en sus comisiones.</p>}

      {pago.estado === 'pagado' && (
        formaCorr ? (
          <div className="tarjeta" style={{ marginTop: 12 }}>
            <h3 style={{ marginTop: 0 }}>Corregir la forma de pago</h3>
            <p className="ayuda">El pago sigue registrado: se corrige aquí y en sus egresos del libro. El monto no cambia.</p>
            <div className="rejilla-2">
              <label className="campo">
                <span>Forma</span>
                <select value={formaCorr.forma} onChange={ev => setFormaCorr(f => ({ ...f, forma: ev.target.value }))}>
                  {FORMAS_PAGO_TECNICO.map(([k, t]) => <option key={k} value={k}>{t}</option>)}
                </select>
              </label>
              <label className="campo">
                <span>Cuenta de donde salió</span>
                <select value={formaCorr.cuenta_id} onChange={ev => setFormaCorr(f => ({ ...f, cuenta_id: ev.target.value }))}>
                  <option value="">— Sin especificar —</option>
                  {cuentas.map(c => <option key={c.id} value={c.id}>{c.nombre}</option>)}
                </select>
              </label>
              <label className="campo">
                <span>Fecha del pago</span>
                <input type="date" value={formaCorr.fecha} onChange={ev => setFormaCorr(f => ({ ...f, fecha: ev.target.value }))} />
              </label>
              <label className="campo">
                <span>Referencia (opcional)</span>
                <input value={formaCorr.referencia} onChange={ev => setFormaCorr(f => ({ ...f, referencia: ev.target.value }))} placeholder="Clave de rastreo" />
              </label>
            </div>
            <label className="campo">
              <span>¿Por qué? (opcional)</span>
              <input value={formaCorr.motivo} onChange={ev => setFormaCorr(f => ({ ...f, motivo: ev.target.value }))} placeholder="Se pagó en efectivo, no por transferencia" />
            </label>
            {formaCorr.cuenta_id !== (pago.cuenta_id || '') && (
              <p className="ayuda">Cambia la cuenta: si ya estaba conciliado con el banco, ese renglón vuelve a "por conciliar".</p>
            )}
            <div className="fila">
              <button type="button" className="btn-primario" disabled={ocupado || !formaCorr.fecha}
                onClick={() => correr(async () => {
                  const r = await corregirFormaPago(pago.id, formaCorr)
                  if (!r.error) { setFormaCorr(null); onAviso?.(textoFormaCorregida(r.data, pago.folio)) }
                  return r
                })}>Guardar corrección</button>
              <button type="button" onClick={() => setFormaCorr(null)}>No, dejarlo</button>
            </div>
          </div>
        ) : !corrigiendo && (
          <button type="button" style={{ marginTop: 12, marginRight: 8 }}
            onClick={() => setFormaCorr({ forma: pago.forma || 'transferencia', cuenta_id: pago.cuenta_id || '',
              fecha: pago.fecha_pago || hoyLocal(), referencia: pago.referencia || '', motivo: '' })}>
            Corregir forma de pago…
          </button>
        )
      )}

      {(pago.estado === 'aprobado' || pago.estado === 'pagado') && !formaCorr && (
        corrigiendo ? (
          <div className="tarjeta" style={{ marginTop: 12 }}>
            <h3 style={{ marginTop: 0 }}>Corregir este pago</h3>
            <p className="ayuda">
              {pago.estado === 'pagado'
                ? 'Vuelve a borrador para cambiar montos u órdenes. Se quitan los egresos que dejó en el libro y en los expedientes; después lo apruebas y lo registras otra vez.'
                : 'Vuelve a borrador para cambiar montos u órdenes; después lo apruebas otra vez.'}
            </p>
            <label className="campo">
              <span>¿Qué se corrige? *</span>
              <input value={motivoCorr} onChange={ev => setMotivoCorr(ev.target.value)} placeholder="El monto de la OS-12 estaba mal" />
            </label>
            <div className="fila">
              <button type="button" className="btn-primario" disabled={ocupado || !motivoCorr.trim()}
                onClick={() => correr(async () => {
                  const r = await reabrirPago(pago.id, motivoCorr.trim())
                  if (!r.error) {
                    setCorrigiendo(false); setMotivoCorr('')
                    onAviso?.(textoReabierto(r.data, pago.folio))
                  }
                  return r
                })}>Regresar a borrador</button>
              <button type="button" onClick={() => { setCorrigiendo(false); setMotivoCorr('') }}>No, dejarlo</button>
            </div>
          </div>
        ) : (
          <button type="button" style={{ marginTop: 12, marginRight: 8 }} onClick={() => setCorrigiendo(true)}>
            {pago.estado === 'pagado' ? 'Corregir monto u órdenes…' : 'Corregir este pago…'}
          </button>
        )
      )}

      {(pago.estado === 'propuesto' || pago.estado === 'aprobado') && (
        cancelando ? (
          <div style={{ marginTop: 12 }}>
            <label className="campo">
              <span>¿Por qué se cancela? *</span>
              <input value={motivo} onChange={ev => setMotivo(ev.target.value)} />
            </label>
            <div className="fila">
              <button type="button" className="btn-peligro" disabled={ocupado || !motivo.trim()}
                onClick={() => correr(() => cancelarPago(pago.id, motivo.trim()))}>Cancelar el pago</button>
              <button type="button" onClick={() => { setCancelando(false); setMotivo('') }}>No, dejarlo</button>
            </div>
          </div>
        ) : (
          <button type="button" className="btn-peligro" style={{ marginTop: 12 }} onClick={() => setCancelando(true)}>
            Cancelar…
          </button>
        )
      )}
    </section>
  )
}

// El ayudante cobra al menos 300 por servicio (Caña, 09/10/2026); el SQL 66 ya siembra esa base.
const vacioTarifa = () => ({ tipo_servicio: 'preventivo', rol: 'responsable', monto: '', vigente_desde: hoyLocal() })

// Desde cuándo las órdenes se pagan por aquí. Lo anterior se pagó a mano antes del sistema y no
// aparece ni al admin ni al técnico.
function Corte({ pagarDesde, onCambio }) {
  const [fecha, setFecha] = useState(pagarDesde)
  const [msg, setMsg] = useState(null)
  const [ocupado, setOcupado] = useState(false)

  async function guardar(e) {
    e.preventDefault(); setOcupado(true)
    const r = await guardarCorte(fecha)
    setOcupado(false)
    setMsg(r.error ? { tipo: 'error', texto: r.error } : { tipo: 'ok', texto: 'Fecha guardada.' })
    if (!r.error) onCambio()
  }

  return (
    <form className="tarjeta" onSubmit={guardar}>
      <h3>Desde cuándo se paga por aquí</h3>
      <p className="ayuda">
        Las órdenes cerradas antes de esta fecha se dan por pagadas a mano: no salen por pagar ni en las
        comisiones del técnico. Muévela hacia atrás si quedaron órdenes recientes sin pagar.
      </p>
      {msg && <Alerta tipo={msg.tipo}>{msg.texto}</Alerta>}
      <label className="campo">
        <span>Pagar órdenes desde</span>
        <input type="date" value={fecha} onChange={e => setFecha(e.target.value)} />
      </label>
      <button type="submit" disabled={ocupado || !fecha || fecha === pagarDesde}>{ocupado ? 'Guardando…' : 'Guardar fecha'}</button>
    </form>
  )
}

function Tarifas({ tarifas, onCambio }) {
  const [form, setForm] = useState(vacioTarifa())
  const [error, setError] = useState('')
  const [ok, setOk] = useState('')
  const [ocupado, setOcupado] = useState(false)
  const hoy = hoyLocal()
  const vigente = t => t.vigente_desde <= hoy && (!t.vigente_hasta || t.vigente_hasta >= hoy)

  async function guardar(ev) {
    ev.preventDefault()
    setError(''); setOk(''); setOcupado(true)
    const r = await guardarTarifa(form)
    setOcupado(false)
    if (r.error) return setError(r.error)
    setOk('Tarifa guardada.'); setForm(vacioTarifa()); onCambio()
  }

  return (
    <>
      <div className="tarjeta">
        <h3>Tarifas por servicio</h3>
        <p className="ayuda">Cuánto se le paga al técnico por cada orden cerrada, según el tipo de servicio y su papel. Para cambiar un monto, agrega una tarifa nueva con la fecha desde la que aplica: los pagos pasados no cambian.</p>
        {tarifas.length === 0 ? <p>Aún no hay tarifas. Sin tarifa, una orden no se paga.</p> : (
          <div className="tabla-scroll">
            <table>
              <thead><tr><th>Servicio</th><th>Rol</th><th>Monto</th><th>Desde</th><th>Estado</th></tr></thead>
              <tbody>
                {tarifas.map(t => (
                  <tr key={t.id}>
                    <td>{nombreServicio(t.tipo_servicio)}</td>
                    <td>{etiquetaRol(t.rol)}</td>
                    <td className="monto">{pesos(t.monto)}</td>
                    <td>{fechaCorta(t.vigente_desde)}</td>
                    <td>{vigente(t) ? 'Vigente' : 'Anterior'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
      <form className="tarjeta" onSubmit={guardar}>
        <h3>Agregar tarifa</h3>
        {error && <Alerta tipo="error">{error}</Alerta>}
        {ok && <Alerta tipo="ok">{ok}</Alerta>}
        <div className="rejilla-2">
          <label className="campo">
            <span>Servicio</span>
            <select value={form.tipo_servicio} onChange={e => setForm(f => ({ ...f, tipo_servicio: e.target.value }))}>
              {Object.entries(TIPOS_SERVICIO).map(([k, t]) => <option key={k} value={k}>{t}</option>)}
            </select>
          </label>
          <label className="campo">
            <span>Rol</span>
            <select value={form.rol} onChange={e => setForm(f => ({ ...f, rol: e.target.value }))}>
              <option value="responsable">Responsable (T1)</option>
              <option value="ayudante">Ayudante (T2)</option>
            </select>
          </label>
          <label className="campo">
            <span>Monto por orden *</span>
            <input type="number" inputMode="decimal" min="0" step="0.01" value={form.monto} onChange={e => setForm(f => ({ ...f, monto: e.target.value }))} />
          </label>
          <label className="campo">
            <span>Aplica desde</span>
            <input type="date" value={form.vigente_desde} onChange={e => setForm(f => ({ ...f, vigente_desde: e.target.value }))} />
          </label>
        </div>
        <button type="submit" className="btn-primario" disabled={ocupado}>{ocupado ? 'Guardando…' : 'Guardar tarifa'}</button>
      </form>
    </>
  )
}

export default function PagosTecnicos() {
  const [datos, setDatos] = useState(null)
  const [pestana, setPestana] = useState('por_pagar')
  const [vuelta, setVuelta] = useState(0)
  const [mensaje, setMensaje] = useState(null)

  useEffect(() => {
    let vivo = true
    leerTodo().then(d => { if (vivo) setDatos(d) })
    return () => { vivo = false }
  }, [vuelta])

  const recargar = () => setVuelta(v => v + 1)
  const avisar = texto => { setMensaje({ tipo: 'ok', texto }); window.scrollTo?.({ top: 0, behavior: 'smooth' }) }
  const abiertos = (datos?.pagos || []).filter(p => p.estado !== 'pagado')
  const pagados = (datos?.pagos || []).filter(p => p.estado === 'pagado')

  function trasArmar(r, nombre) {
    const sin = r?.sin_tarifa?.length || 0
    setMensaje({
      tipo: sin ? 'aviso' : 'ok',
      texto: `Pago de ${nombre} armado con ${r?.servicios || 0} ${r?.servicios === 1 ? 'orden' : 'órdenes'}: ${pesos(r?.total)}.` +
        (sin ? ` ${sin} sin tarifa no se incluyeron.` : ' Revísalo y apruébalo.')
    })
    setPestana('pagos'); recargar()
  }

  const PESTANAS = [
    ['por_pagar', `Por pagar (${datos?.porPagar.length ?? 0})`],
    ['pagos', `Pagos (${abiertos.length})`],
    ['tarifas', 'Tarifas']
  ]

  return (
    <div className="pagina pagina-angosta">
      <h2>Pago a técnicos</h2>
      <p className="ayuda">El sistema arma el pago con las órdenes cerradas; tú lo apruebas y lo registras cuando pagas.</p>
      {datos?.error && <Alerta tipo="error">{datos.error}</Alerta>}
      {mensaje && <Alerta tipo={mensaje.tipo}>{mensaje.texto}</Alerta>}

      <div className="pestanas">
        {PESTANAS.map(([k, t]) => (
          <button key={k} type="button" className="pestana" aria-pressed={pestana === k} onClick={() => { setPestana(k); setMensaje(null) }}>{t}</button>
        ))}
      </div>

      {!datos && <p>Cargando…</p>}

      {datos && pestana === 'por_pagar' && <PorPagar lista={datos.porPagar} nombres={datos.nombres} onArmado={trasArmar} />}

      {datos && pestana === 'pagos' && (
        <>
          {abiertos.length === 0 && <div className="tarjeta"><p style={{ margin: 0 }}>No hay pagos por aprobar ni por registrar.</p></div>}
          {abiertos.map(p => (
            <TarjetaPago key={p.id} pago={p} nombre={datos.nombres[p.tecnico_id] || 'Técnico'}
              ordenes={datos.ordenes} cuentas={datos.cuentas} onCambio={recargar} onAviso={avisar} />
          ))}
          {pagados.length > 0 && (
            <details className="tarjeta">
              <summary className="resumen">Pagados recientes ({pagados.length})</summary>
              <p className="ayuda">Para corregir uno ya registrado, ábrelo con "Corregir este pago…": vuelve a borrador.</p>
              {pagados.map(p => (
                <TarjetaPago key={p.id} pago={p} nombre={datos.nombres[p.tecnico_id] || 'Técnico'}
                  ordenes={datos.ordenes} cuentas={datos.cuentas} onCambio={recargar} onAviso={avisar} />
              ))}
            </details>
          )}
        </>
      )}

      {datos && pestana === 'tarifas' && (
        <>
          <Corte key={datos.pagarDesde} pagarDesde={datos.pagarDesde} onCambio={recargar} />
          <Tarifas tarifas={datos.tarifas} onCambio={recargar} />
        </>
      )}
    </div>
  )
}
