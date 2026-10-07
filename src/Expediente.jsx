import { useEffect, useState } from 'react'
import { supabase } from './lib/supabase'
import { hoyLocal } from './lib/fechas'
import { Alerta } from './ui'
import {
  CATEGORIAS_EGRESO, FORMAS_COBRO, pesos, etiquetaCategoria, estadoComprobante, textoUtilidad,
  validarMovimiento, filaDeMovimiento, cargarResumen, cargarMovimientos, guardarMovimiento,
  borrarMovimiento, cerrarExpediente, reabrirExpediente, urlComprobante
} from './lib/expediente'

// ---------------------------------------------------------------------------
// Expediente de una cotización (SQL 61): ingreso, egresos, comprobantes y utilidad.
//
// El INGRESO es la cotización; cada COBRO se comprueba con su operación bancaria (foto o PDF).
// El MATERIAL no se captura: lo dicta la cotización, a costo real, y lo que no se use se queda
// en el almacén. Aquí se capturan gasolina, vehículo, técnicos, viáticos y otros gastos.
// Todas las cifras las calcula la base; esta pantalla solo las muestra.
// ---------------------------------------------------------------------------

const vacioCobro = () => ({ fecha: hoyLocal(), monto: '', forma: 'transferencia', referencia: '', notas: '' })
const vacioGasto = () => ({ fecha: hoyLocal(), categoria: 'tecnico', concepto: '', monto: '', iva: '', tecnico_id: '', notas: '' })

async function abrirComprobante(ruta) {
  // Se abre la ventana en el clic (antes de esperar) para que el navegador no la bloquee.
  const ventana = window.open('', '_blank')
  const url = await urlComprobante(ruta)
  if (url && ventana) ventana.location.href = url
  else if (ventana) ventana.close()
}

function Dato({ etiqueta, valor, fuerte }) {
  return (
    <div className="fila" style={{ justifyContent: 'space-between', gap: 12 }}>
      <span>{etiqueta}</span>
      {fuerte ? <strong>{valor}</strong> : <span>{valor}</span>}
    </div>
  )
}

function Comprobante({ m }) {
  return (
    <span>
      <span className={`estado ${m.archivo ? 'estado-aceptada' : 'estado-pendiente'}`}>{estadoComprobante(m)}</span>
      {m.archivo && (
        <button type="button" style={{ marginLeft: 6 }} onClick={() => abrirComprobante(m.archivo)}>Ver</button>
      )}
    </span>
  )
}

function FormMovimiento({ tipo, tecnicos, onGuardar }) {
  const [form, setForm] = useState(tipo === 'ingreso' ? vacioCobro() : vacioGasto())
  const [archivo, setArchivo] = useState(null)
  const [error, setError] = useState('')
  const [ocupado, setOcupado] = useState(false)
  const [version, setVersion] = useState(0)   // cambia la llave del input de archivo para vaciarlo
  const cambiar = (campo, valor) => setForm(f => ({ ...f, [campo]: valor }))
  const esCobro = tipo === 'ingreso'

  async function enviar(e) {
    e.preventDefault()
    const problema = validarMovimiento(form, tipo)
    if (problema) return setError(problema)
    setError(''); setOcupado(true)
    const texto = await onGuardar(form, archivo)
    setOcupado(false)
    if (texto) return setError(texto)
    setForm(esCobro ? vacioCobro() : vacioGasto()); setArchivo(null); setVersion(v => v + 1)
  }

  return (
    <form onSubmit={enviar}>
      {error && <Alerta tipo="error">{error}</Alerta>}
      <div className="rejilla-2">
        {!esCobro && (
          <label className="campo">
            <span>Tipo de gasto *</span>
            <select value={form.categoria} onChange={e => cambiar('categoria', e.target.value)}>
              {CATEGORIAS_EGRESO.map(([k, t]) => <option key={k} value={k}>{t}</option>)}
            </select>
          </label>
        )}
        {!esCobro && form.categoria === 'tecnico' && (
          <label className="campo">
            <span>Técnico *</span>
            <select value={form.tecnico_id} onChange={e => cambiar('tecnico_id', e.target.value)}>
              <option value="">— Elige —</option>
              {tecnicos.map(t => <option key={t.id} value={t.id}>{t.nombre}</option>)}
            </select>
          </label>
        )}
        {esCobro && (
          <label className="campo">
            <span>Forma de pago</span>
            <select value={form.forma} onChange={e => cambiar('forma', e.target.value)}>
              {FORMAS_COBRO.map(([k, t]) => <option key={k} value={k}>{t}</option>)}
            </select>
          </label>
        )}
        <label className="campo">
          <span>Fecha *</span>
          <input type="date" value={form.fecha} onChange={e => cambiar('fecha', e.target.value)} />
        </label>
        <label className="campo">
          <span>{esCobro ? 'Monto cobrado (con IVA) *' : 'Monto pagado *'}</span>
          <input type="number" inputMode="decimal" min="0" step="0.01" value={form.monto}
            onChange={e => cambiar('monto', e.target.value)} />
        </label>
        {!esCobro && (
          <label className="campo">
            <span>IVA de la factura (si la hay)</span>
            <input type="number" inputMode="decimal" min="0" step="0.01" value={form.iva}
              placeholder="Un ticket sin factura se deja vacío"
              onChange={e => cambiar('iva', e.target.value)} />
          </label>
        )}
        {esCobro ? (
          <label className="campo">
            <span>Referencia (clave de rastreo o folio)</span>
            <input value={form.referencia} onChange={e => cambiar('referencia', e.target.value)} />
          </label>
        ) : (
          <label className="campo">
            <span>{form.categoria === 'otro' ? 'Concepto *' : 'Concepto'}</span>
            <input value={form.concepto} placeholder="Ej. 35 L de diésel, casetas Mérida–Cancún"
              onChange={e => cambiar('concepto', e.target.value)} />
          </label>
        )}
      </div>
      <label className="campo">
        <span>{esCobro ? 'Comprobante bancario (foto o PDF)' : 'Ticket o comprobante (foto o PDF, opcional)'}</span>
        <input key={version} type="file" accept="image/*,application/pdf"
          onChange={e => setArchivo(e.target.files?.[0] || null)} />
      </label>
      <button type="submit" className="btn-primario" disabled={ocupado}>
        {ocupado ? 'Guardando…' : (esCobro ? 'Registrar cobro' : 'Registrar gasto')}
      </button>
    </form>
  )
}

export default function Expediente({ cotizacionId, onVolver }) {
  const [resumen, setResumen] = useState(null)
  const [movs, setMovs] = useState([])
  const [tecnicos, setTecnicos] = useState([])
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState('')
  const [avisosCierre, setAvisosCierre] = useState(null)   // avisos que impidieron cerrar sin confirmar
  const [reabriendo, setReabriendo] = useState(false)
  const [motivo, setMotivo] = useState('')
  const [ocupado, setOcupado] = useState(false)

  // Lee todo junto; aplicar() lo pone en pantalla. Se separan para que el efecto de arranque no
  // llame a setState directamente (solo dentro del .then) y para poder recargar tras cada cambio.
  async function leer() {
    const [r, m, t] = await Promise.all([
      cargarResumen(cotizacionId),
      cargarMovimientos(cotizacionId),
      supabase.from('perfiles').select('id, nombre').eq('rol', 'tecnico').order('nombre')
    ])
    return { r, m, t }
  }

  function aplicar({ r, m, t }) {
    if (r.error) return setError(r.error)
    if (m.error) return setError(m.error)
    setError('')
    setResumen(r.resumen)
    setMovs(m.movimientos)
    setTecnicos(t.data || [])
  }

  async function cargar() { aplicar(await leer()) }

  useEffect(() => {
    let vivo = true
    leer().then(d => { if (vivo) aplicar(d) })
    return () => { vivo = false }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cotizacionId])

  async function agregar(tipo, form, archivo) {
    setMensaje('')
    const quien = (await supabase.auth.getUser()).data.user?.email
    const fila = filaDeMovimiento(form, tipo, cotizacionId, quien)
    const r = await guardarMovimiento(fila, archivo)
    if (r.error) return r.error
    setAvisosCierre(null)
    setMensaje(tipo === 'ingreso' ? 'Cobro registrado.' : 'Gasto registrado.')
    await cargar()
    return null
  }

  async function quitar(m) {
    if (!window.confirm(`¿Quitar ${etiquetaCategoria(m.categoria).toLowerCase()} de ${pesos(m.monto)}?`)) return
    const r = await borrarMovimiento(m.id)
    if (r.error) return setError(r.error)
    setAvisosCierre(null); setMensaje('Movimiento quitado.')
    cargar()
  }

  async function cerrar(forzar) {
    setOcupado(true); setError(''); setMensaje('')
    const { respuesta, error: e } = await cerrarExpediente(cotizacionId, forzar)
    setOcupado(false)
    if (e) return setError(e)
    if (respuesta?.ok === false) return setAvisosCierre(respuesta.avisos || [])
    setAvisosCierre(null); setMensaje('Expediente cerrado: las cifras quedaron congeladas.')
    cargar()
  }

  async function reabrir() {
    setOcupado(true); setError('')
    const { error: e } = await reabrirExpediente(cotizacionId, motivo)
    setOcupado(false)
    if (e) return setError(e)
    setReabriendo(false); setMotivo(''); setMensaje('Expediente reabierto.')
    cargar()
  }

  if (!resumen) {
    return (
      <div>
        <button onClick={onVolver}>← Volver a la lista</button>
        {error ? <Alerta tipo="error">{error}</Alerta> : <p className="ayuda">Cargando el expediente…</p>}
      </div>
    )
  }

  const cerrado = resumen.cerrado
  const ing = resumen.ingreso
  const cobros = movs.filter(m => m.tipo === 'ingreso')
  const gastos = movs.filter(m => m.tipo === 'egreso')
  const material = resumen.material
  const utilidad = Number(resumen.utilidad)

  return (
    <div style={{ maxWidth: 900 }}>
      <div className="fila" style={{ justifyContent: 'space-between', flexWrap: 'wrap' }}>
        <button onClick={onVolver}>← Volver a la lista</button>
        <span className={`estado ${cerrado ? 'estado-aceptada' : 'estado-pendiente'}`}>
          {cerrado ? 'Expediente cerrado' : 'Expediente abierto'}
        </span>
      </div>
      <h3>Expediente · Cotización {resumen.folio}</h3>

      {error && <Alerta tipo="error">{error}</Alerta>}
      {mensaje && <Alerta tipo="ok" palabra="Listo">{mensaje}</Alerta>}

      {/* ---------------- INGRESO ---------------- */}
      <section className="tarjeta">
        <h3>Ingreso</h3>
        <p className="ayuda">El ingreso es la cotización. Cada cobro se comprueba con su operación bancaria.</p>
        <Dato etiqueta="Base de la cotización (sin IVA)" valor={pesos(ing.base)} />
        <Dato etiqueta="IVA" valor={pesos(ing.iva)} />
        <Dato etiqueta="Total de la cotización" valor={pesos(ing.total)} fuerte />
        <Dato etiqueta="Cobrado" valor={pesos(ing.cobrado)} />
        <Dato etiqueta="De eso, comprobado con el banco" valor={pesos(ing.comprobado)} />
        <Dato etiqueta="Por cobrar" valor={pesos(ing.por_cobrar)} fuerte />

        <div className="tabla-scroll" style={{ marginTop: 10 }}>
          <table>
            <thead>
              <tr><th>Fecha</th><th>Forma</th><th>Referencia</th><th>Monto</th><th>Comprobante</th>{!cerrado && <th></th>}</tr>
            </thead>
            <tbody>
              {cobros.map(m => (
                <tr key={m.id}>
                  <td>{m.fecha}</td>
                  <td>{FORMAS_COBRO.find(([k]) => k === m.forma)?.[1] || m.forma || '—'}</td>
                  <td>{m.referencia || '—'}</td>
                  <td align="right">{pesos(m.monto)}</td>
                  <td><Comprobante m={m} /></td>
                  {!cerrado && <td><button className="btn-peligro" onClick={() => quitar(m)}>Quitar</button></td>}
                </tr>
              ))}
              {cobros.length === 0 && <tr><td colSpan={6} className="ayuda">Todavía no hay cobros.</td></tr>}
            </tbody>
          </table>
        </div>

        {!cerrado && (
          <details className="tarjeta">
            <summary className="resumen">Registrar un cobro</summary>
            <FormMovimiento tipo="ingreso" tecnicos={tecnicos} onGuardar={(f, a) => agregar('ingreso', f, a)} />
          </details>
        )}
      </section>

      {/* ---------------- EGRESOS ---------------- */}
      <section className="tarjeta">
        <h3>Egresos</h3>

        <h4>Material (lo dicta la cotización)</h4>
        <p className="ayuda">
          Cantidad de cada pieza de la cotización por su costo real. Las facturas entran al almacén
          general en Compras; lo que no se use se queda ahí.
        </p>
        <div className="tabla-scroll">
          <table>
            <thead>
              <tr><th>SKU</th><th>Pieza</th><th>Cant.</th><th>Costo</th><th>Importe</th></tr>
            </thead>
            <tbody>
              {material.lineas.map(l => (
                <tr key={l.producto_id}>
                  <td>{l.sku}</td>
                  <td>{l.nombre}</td>
                  <td align="right">{l.cantidad}</td>
                  <td align="right">
                    {l.sin_costo ? <span className="estado estado-pendiente">Sin costo</span> : pesos(l.costo_unitario)}
                  </td>
                  <td align="right">{pesos(l.importe)}</td>
                </tr>
              ))}
              {material.lineas.length === 0 && (
                <tr><td colSpan={5} className="ayuda">La cotización no lleva piezas del catálogo.</td></tr>
              )}
            </tbody>
          </table>
        </div>
        <Dato etiqueta="Material" valor={pesos(material.total)} fuerte />
        {material.sin_costo > 0 && !cerrado && (
          <Alerta tipo="aviso" palabra="Falta el costo">
            {material.sin_costo} pieza(s) no tienen costo capturado y cuentan como cero: la utilidad sale
            inflada. Captura el costo en Inventario o registra la compra en Compras.
          </Alerta>
        )}

        <h4 style={{ marginTop: 16 }}>Otros gastos del trabajo</h4>
        <div className="tabla-scroll">
          <table>
            <thead>
              <tr><th>Fecha</th><th>Tipo</th><th>Detalle</th><th>Monto</th><th>IVA</th><th>Comprobante</th>{!cerrado && <th></th>}</tr>
            </thead>
            <tbody>
              {gastos.map(m => (
                <tr key={m.id}>
                  <td>{m.fecha}</td>
                  <td>{etiquetaCategoria(m.categoria)}</td>
                  <td>{[m.perfiles?.nombre, m.concepto].filter(Boolean).join(' · ') || '—'}</td>
                  <td align="right">{pesos(m.monto)}</td>
                  <td align="right">{Number(m.iva) > 0 ? pesos(m.iva) : '—'}</td>
                  <td><Comprobante m={m} /></td>
                  {!cerrado && <td><button className="btn-peligro" onClick={() => quitar(m)}>Quitar</button></td>}
                </tr>
              ))}
              {gastos.length === 0 && <tr><td colSpan={7} className="ayuda">Todavía no hay gastos capturados.</td></tr>}
            </tbody>
          </table>
        </div>
        <Dato etiqueta="Otros gastos (sin IVA)" valor={pesos(resumen.egresos.total_sin_iva)} fuerte />

        {!cerrado && (
          <details className="tarjeta">
            <summary className="resumen">Registrar un gasto (gasolina, vehículo, técnico, viáticos…)</summary>
            <FormMovimiento tipo="egreso" tecnicos={tecnicos} onGuardar={(f, a) => agregar('egreso', f, a)} />
          </details>
        )}
      </section>

      {/* ---------------- UTILIDAD ---------------- */}
      <section className="tarjeta">
        <h3>Utilidad</h3>
        <Dato etiqueta="Ingreso (base sin IVA)" valor={pesos(ing.base)} />
        <Dato etiqueta="− Material" valor={pesos(material.total)} />
        <Dato etiqueta="− Otros gastos (sin IVA)" valor={pesos(resumen.egresos.total_sin_iva)} />
        <div style={{ fontSize: 20, marginTop: 6 }}>
          <strong>{textoUtilidad(utilidad)}: {pesos(Math.abs(utilidad))}</strong>
          {resumen.margen_pct != null && <span> · margen {resumen.margen_pct} %</span>}
        </div>
        <p className="ayuda">
          Los tickets sin factura cuentan completos (su IVA no se recupera); un gasto con factura se
          cuenta sin su IVA.
        </p>
      </section>

      {/* ---------------- CIERRE ---------------- */}
      <section className="tarjeta">
        <h3>Cierre de la operación</h3>
        {cerrado ? (
          <>
            <p>Cerrado el {String(resumen.cerrado_en || '').slice(0, 10)}. Las cifras de arriba quedaron
              congeladas: un cambio de costo en el catálogo ya no las mueve, y los movimientos y las
              partidas de la cotización no se pueden cambiar.</p>
            {!reabriendo ? (
              <button onClick={() => setReabriendo(true)}>Reabrir…</button>
            ) : (
              <div>
                <label className="campo">
                  <span>¿Por qué se reabre? *</span>
                  <input value={motivo} onChange={e => setMotivo(e.target.value)} />
                </label>
                <div className="fila" style={{ flexWrap: 'wrap' }}>
                  <button className="btn-peligro" disabled={ocupado} onClick={reabrir}>Reabrir el expediente</button>
                  <button onClick={() => { setReabriendo(false); setMotivo('') }}>Cancelar</button>
                </div>
              </div>
            )}
          </>
        ) : (
          <>
            {avisosCierre && avisosCierre.length > 0 ? (
              <Alerta tipo="aviso" palabra="Antes de cerrar">
                <ul>{avisosCierre.map(a => <li key={a}>{a}</li>)}</ul>
                <div className="fila" style={{ flexWrap: 'wrap', marginTop: 8 }}>
                  <button className="btn-peligro" disabled={ocupado} onClick={() => cerrar(true)}>Cerrar de todos modos</button>
                  <button onClick={() => setAvisosCierre(null)}>Volver a revisar</button>
                </div>
              </Alerta>
            ) : (
              <>
                {resumen.avisos?.length > 0 && (
                  <>
                    <p className="ayuda">Esto falta o conviene revisar:</p>
                    <ul>{resumen.avisos.map(a => <li key={a}>{a}</li>)}</ul>
                  </>
                )}
                <button className="btn-primario" disabled={ocupado} onClick={() => cerrar(false)}>Cerrar el expediente</button>
              </>
            )}
          </>
        )}
      </section>
    </div>
  )
}
