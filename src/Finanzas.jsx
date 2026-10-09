import { useEffect, useState } from 'react'
import { Alerta } from './ui'
import { hoyLocal } from './lib/fechas'
import { etiquetaTipoComprobante, etiquetaFormaPagoSat } from './lib/cfdi'
import Impuestos from './Impuestos'
import {
  CATEGORIAS_GASTO, CATEGORIAS_CAPITAL, FORMAS_PAGO, ETIQUETA_CONFIANZA,
  etiquetaCategoria, esIngreso, pesos, pesosRedondos, fechaMerida, fechaLegible, avisosDeCfdi, formularioDeAprobacion,
  validarAprobacion, resumenLibro, rangoDeMes, mesAnterior, nombreDeMes, validarMovimientoLibre,
  subirDocumento, leerDocumentoConIA, listarBandeja, aprobarDocumento, rechazarDocumento,
  sugerirCotizaciones, ligarCfdiCotizacion, urlDocumento, cargarLibro, guardarMovimientoLibre,
  listarCuentas, guardarCuenta, cargarEmpresaFiscal, guardarEmpresaFiscal,
  estadoVencimiento, validarPagoCfdi, cargarPorPagar, pagarCfdi, programarPagoCfdi
} from './lib/finanzas'

// ---------------------------------------------------------------------------
// Finanzas (SQL 67). Solo admin.
//
// · Por revisar: subes XML, PDF o fotos; el sistema los lee (el XML sin IA), propone de qué es
//   cada uno y tú apruebas con un toque. Nada entra al libro sin tu aprobación.
// · Libro: todo lo que entró y salió en el mes, con ingresos y gastos del negocio separados de lo
//   que pones o sacas tú (retiros y aportaciones).
// · Ajustes: tu RFC (decide si un CFDI es emitido o recibido) y tus cuentas.
// ---------------------------------------------------------------------------

async function abrirArchivo(ruta) {
  // La ventana se abre en el clic (antes de esperar) para que el navegador no la bloquee.
  const ventana = window.open('', '_blank')
  const url = await urlDocumento(ruta)
  if (url && ventana) ventana.location.href = url
  else if (ventana) ventana.close()
}

const CLASE_CONFIANZA = { alta: 'estado-aprobado', media: 'estado-revisa', baja: 'estado-error' }

function tituloDocumento(doc) {
  const c = doc.cfdi
  if (c) {
    const tipo = etiquetaTipoComprobante(c.tipo_comprobante)
    const folio = [c.serie, c.folio].filter(Boolean).join('-')
    return {
      tipo: c.sentido === 'emitido' ? `${tipo} emitida` : `${tipo} recibida`,
      nombre: (c.sentido === 'emitido' ? c.nombre_receptor || c.rfc_receptor : c.nombre_emisor || c.rfc_emisor) || '—',
      datos: [fechaLegible(fechaMerida(c.fecha)), folio && `Folio ${folio}`, c.metodo_pago, c.forma_pago && etiquetaFormaPagoSat(c.forma_pago)].filter(Boolean).join(' · '),
      total: c.total
    }
  }
  return {
    tipo: doc.tipo === 'ticket' ? 'Foto de ticket' : 'PDF',
    nombre: doc.propuesta?.concepto || doc.nombre_original || 'Documento',
    datos: doc.metodo === 'ia' ? 'Leído con IA: revisa los datos' : 'Sin leer todavía',
    total: doc.propuesta?.monto
  }
}

function Campo({ etiqueta, children }) {
  return <label className="campo"><span>{etiqueta}</span>{children}</label>
}

function FormGasto({ form, cambiar, cuentas, conCfdi }) {
  return (
    <>
      <Campo etiqueta="¿De qué es? *">
        <select value={form.categoria} onChange={e => cambiar('categoria', e.target.value)}>
          {CATEGORIAS_GASTO.map(([k, t]) => <option key={k} value={k}>{t}</option>)}
          <option value="retiro_dueno">Retiro del dueño (no es gasto del negocio)</option>
        </select>
      </Campo>
      {conCfdi && (
        <div className="opciones" role="radiogroup" aria-label="¿Ya se pagó?" style={{ marginBottom: 14 }}>
          {[[true, 'Ya la pagué'], [false, 'Aún no la pago']].map(([v, t]) => (
            <button key={t} type="button" role="radio" className="opcion" aria-checked={form.pagado === v} onClick={() => cambiar('pagado', v)}>{t}</button>
          ))}
        </div>
      )}
      {form.pagado ? (
        <div className="rejilla-2">
          <Campo etiqueta="Monto pagado *">
            <input type="number" inputMode="decimal" min="0" step="0.01" value={form.monto} onChange={e => cambiar('monto', e.target.value)} />
          </Campo>
          <Campo etiqueta="IVA incluido">
            <input type="number" inputMode="decimal" min="0" step="0.01" value={form.iva} onChange={e => cambiar('iva', e.target.value)} />
          </Campo>
          <Campo etiqueta="Fecha del pago *">
            <input type="date" value={form.fecha} onChange={e => cambiar('fecha', e.target.value)} />
          </Campo>
          <Campo etiqueta="Cuenta">
            <select value={form.cuenta_id} onChange={e => cambiar('cuenta_id', e.target.value)}>
              <option value="">— Sin especificar —</option>
              {cuentas.map(c => <option key={c.id} value={c.id}>{c.nombre}</option>)}
            </select>
          </Campo>
          <Campo etiqueta="Forma de pago">
            <select value={form.forma} onChange={e => cambiar('forma', e.target.value)}>
              {FORMAS_PAGO.map(([k, t]) => <option key={k} value={k}>{t}</option>)}
            </select>
          </Campo>
          <Campo etiqueta="Concepto">
            <input value={form.concepto} onChange={e => cambiar('concepto', e.target.value)} />
          </Campo>
        </div>
      ) : (
        <>
          <Campo etiqueta="Vence">
            <input type="date" value={form.vence} onChange={e => cambiar('vence', e.target.value)} />
          </Campo>
          <p className="ayuda">Se guarda como <strong>por pagar</strong>: no entra al libro ni acredita IVA hasta que la pagues. La verás en la pestaña Por pagar.</p>
        </>
      )}
    </>
  )
}

function LigarCotizacion({ cfdi, onLigada }) {
  const [lista, setLista] = useState(null)
  const [error, setError] = useState('')
  const [ocupado, setOcupado] = useState(false)

  async function buscar() {
    setError(''); setOcupado(true)
    const r = await sugerirCotizaciones(cfdi.id)
    setOcupado(false)
    if (r.error) return setError(r.error)
    setLista(r.cotizaciones)
  }
  async function ligar(id) {
    setError(''); setOcupado(true)
    const r = await ligarCfdiCotizacion(cfdi.id, id)
    setOcupado(false)
    if (r.error) return setError(r.error)
    onLigada(id)
  }

  if (cfdi.cotizacion_id) return <Alerta tipo="ok">Ligada a su cotización.</Alerta>
  return (
    <div style={{ marginBottom: 12 }}>
      {error && <Alerta tipo="error">{error}</Alerta>}
      {!lista && <button type="button" disabled={ocupado} onClick={buscar}>{ocupado ? 'Buscando…' : '¿De qué cotización es? Buscar'}</button>}
      {lista && lista.length === 0 && <p className="ayuda">No encontré cotizaciones aceptadas de ese cliente ni con ese total.</p>}
      {lista && lista.length > 0 && (
        <div className="buscador-lista" style={{ position: 'static' }}>
          {lista.map(q => (
            <button key={q.cotizacion_id} type="button" disabled={ocupado} onClick={() => ligar(q.cotizacion_id)}>
              Cotización {q.folio} · {q.cliente} · {pesos(q.total)}
              <span className="ayuda">{[q.coincide_total && 'mismo total', q.mismo_cliente && 'mismo cliente'].filter(Boolean).join(' · ') || 'parecida'}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

function TarjetaDocumento({ doc, cuentas, onListo }) {
  const [form, setForm] = useState(() => formularioDeAprobacion(doc, doc.cfdi, doc.propuesta))
  const confianza = doc.propuesta?.confianza
  const [abierto, setAbierto] = useState(() => !(confianza === 'alta' || formularioDeAprobacion(doc, doc.cfdi, doc.propuesta).accion === 'archivar'))
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')
  const [rechazando, setRechazando] = useState(false)
  const [motivo, setMotivo] = useState('')
  const [cfdi, setCfdi] = useState(doc.cfdi)
  const cambiar = (k, v) => setForm(f => ({ ...f, [k]: v }))
  const t = tituloDocumento(doc)
  const avisos = [...(doc.validaciones || []).map(a => a?.texto || String(a)), ...avisosDeCfdi(cfdi)]
  const sinLeer = !cfdi && doc.metodo !== 'ia'

  async function aprobar() {
    const problema = validarAprobacion(form)
    if (problema) { setAbierto(true); return setError(problema) }
    setError(''); setOcupado(true)
    const r = await aprobarDocumento(doc.id, form)
    setOcupado(false)
    if (r.error) { setAbierto(true); return setError(r.error) }
    onListo(form.accion === 'archivar'
      ? 'Guardado como respaldo.'
      : form.pagado ? `Registrado: ${etiquetaCategoria(form.categoria)} por ${pesos(form.monto)}.` : 'Guardada como por pagar.')
  }
  async function leerIA() {
    setError(''); setOcupado(true)
    const r = await leerDocumentoConIA(doc)
    setOcupado(false)
    if (r.error) return setError(`${r.error} Captura los datos a mano.`)
    setForm(formularioDeAprobacion({ ...doc, metodo: 'ia', propuesta: r.propuesta }, null, null))
    setAbierto(true)
  }
  async function rechazar() {
    setError(''); setOcupado(true)
    const r = await rechazarDocumento(doc.id, motivo.trim())
    setOcupado(false)
    if (r.error) return setError(r.error)
    onListo('Documento rechazado.')
  }

  const accionRapida = form.accion === 'archivar' ? 'Guardar como respaldo' : `Aprobar como ${etiquetaCategoria(form.categoria)}`

  return (
    <section className="tarjeta" aria-label={`${t.tipo}: ${t.nombre}`}>
      <div className="renglon" style={{ paddingTop: 0 }}>
        <div>
          <span className="etiqueta" style={{ marginTop: 0 }}>{t.tipo}</span>
          <div className="renglon-titulo" style={{ marginTop: 6 }}>{t.nombre}</div>
          <div className="renglon-datos">{t.datos}</div>
        </div>
        <div className="renglon-lado">
          {t.total != null && t.total !== '' && <span className="monto" style={{ fontSize: 22 }}>{pesos(t.total)}</span>}
          {confianza && form.accion === 'gasto' && (
            <span className={`estado ${CLASE_CONFIANZA[confianza]}`}>{ETIQUETA_CONFIANZA[confianza]}</span>
          )}
        </div>
      </div>

      {doc.propuesta?.motivo && form.accion === 'gasto' && (
        <p className="ayuda">Propuesta: {etiquetaCategoria(doc.propuesta.categoria)}. {doc.propuesta.motivo}</p>
      )}
      {avisos.map((a, i) => <Alerta key={i} tipo="aviso">{a}</Alerta>)}
      {error && <Alerta tipo="error">{error}</Alerta>}

      {cfdi?.sentido === 'emitido' && <LigarCotizacion cfdi={cfdi} onLigada={id => setCfdi(c => ({ ...c, cotizacion_id: id }))} />}

      {sinLeer && (
        <button type="button" className="btn-grande" disabled={ocupado} onClick={leerIA} style={{ marginBottom: 12 }}>
          {ocupado ? 'Leyendo…' : 'Leer con IA y llenar los datos'}
        </button>
      )}

      {abierto && (
        <div style={{ marginTop: 8 }}>
          <div className="opciones" role="radiogroup" aria-label="¿Qué hago con este documento?" style={{ marginBottom: 14 }}>
            {[['gasto', 'Registrar como gasto'], ['archivar', 'Solo guardar como respaldo']].map(([k, tx]) => (
              <button key={k} type="button" role="radio" className="opcion" aria-checked={form.accion === k} onClick={() => cambiar('accion', k)}>{tx}</button>
            ))}
          </div>
          {form.accion === 'gasto' && <FormGasto form={form} cambiar={cambiar} cuentas={cuentas} conCfdi={!!cfdi} />}
        </div>
      )}

      <div className="fila" style={{ marginTop: 8 }}>
        <button type="button" className="btn-primario" disabled={ocupado} onClick={aprobar}>
          {ocupado ? 'Guardando…' : abierto ? 'Aprobar' : accionRapida}
        </button>
        {!abierto && <button type="button" onClick={() => setAbierto(true)}>Revisar</button>}
        <button type="button" onClick={() => abrirArchivo(doc.archivo)}>Ver archivo</button>
        {!rechazando && <button type="button" className="btn-peligro" onClick={() => setRechazando(true)}>Rechazar…</button>}
      </div>
      {rechazando && (
        <div style={{ marginTop: 12 }}>
          <Campo etiqueta="¿Por qué se rechaza? *">
            <input value={motivo} onChange={e => setMotivo(e.target.value)} placeholder="Es personal, está repetido…" />
          </Campo>
          <div className="fila">
            <button type="button" className="btn-peligro" disabled={ocupado || !motivo.trim()} onClick={rechazar}>Rechazar</button>
            <button type="button" onClick={() => { setRechazando(false); setMotivo('') }}>No</button>
          </div>
        </div>
      )}
    </section>
  )
}

const TEXTO_RESULTADO = { nuevo: 'Registrado', duplicado: 'Ya estaba', error: 'No se pudo' }
const CLASE_RESULTADO = { nuevo: 'estado-aprobado', duplicado: 'estado-revisa', error: 'estado-error' }

function Bandeja({ documentos, cuentas, sinRfc, irAAjustes, onCambio }) {
  const [arrastrando, setArrastrando] = useState(false)
  const [subiendo, setSubiendo] = useState(null)   // { hecho, total }
  const [resultados, setResultados] = useState([])
  const [mensaje, setMensaje] = useState('')

  async function procesar(lista) {
    const archivos = Array.from(lista || [])
    if (!archivos.length) return
    setMensaje(''); setResultados([]); setSubiendo({ hecho: 0, total: archivos.length })
    const salida = []
    for (const [i, a] of archivos.entries()) {
      const r = await subirDocumento(a)
      salida.push({ nombre: a.name, ...r, estado: r.estado || 'error' })
      setResultados([...salida])
      setSubiendo({ hecho: i + 1, total: archivos.length })
    }
    setSubiendo(null)
    onCambio()
  }

  return (
    <>
      {sinRfc && (
        <Alerta tipo="aviso">
          Captura tu RFC en Ajustes antes de subir XML: con él se sabe si una factura la emitiste o la recibiste.{' '}
          <button type="button" onClick={irAAjustes}>Ir a Ajustes</button>
        </Alerta>
      )}
      <label className="zona-subida" data-arrastrando={arrastrando}
        onDragOver={e => { e.preventDefault(); setArrastrando(true) }}
        onDragLeave={() => setArrastrando(false)}
        onDrop={e => { e.preventDefault(); setArrastrando(false); procesar(e.dataTransfer.files) }}>
        <input type="file" multiple accept=".xml,text/xml,application/xml,application/pdf,image/jpeg,image/png,image/webp"
          className="oculto-accesible" onChange={e => { procesar(e.target.files); e.target.value = '' }} disabled={!!subiendo} />
        <strong>{subiendo ? `Subiendo ${subiendo.hecho} de ${subiendo.total}…` : 'Sube facturas y tickets'}</strong>
        <span className="ayuda">XML del SAT (se leen sin IA), PDF o fotos. Elige varios a la vez o arrástralos aquí.</span>
      </label>

      {resultados.length > 0 && (
        <div className="tarjeta" style={{ marginTop: 12 }} aria-live="polite">
          <ul style={{ listStyle: 'none', margin: 0, padding: 0 }}>
            {resultados.map((r, i) => (
              <li key={i} className="renglon">
                <div>
                  <div className="renglon-titulo">{r.nombre}</div>
                  {r.error && <div className="renglon-datos">{r.error}</div>}
                  {r.estado === 'duplicado' && <div className="renglon-datos">Ese archivo ya se había subido.</div>}
                </div>
                <span className={`estado ${CLASE_RESULTADO[r.estado]}`}>{TEXTO_RESULTADO[r.estado]}</span>
              </li>
            ))}
          </ul>
        </div>
      )}

      {mensaje && <Alerta tipo="ok">{mensaje}</Alerta>}

      <h3 style={{ marginTop: 20 }}>Por revisar ({documentos.length})</h3>
      {documentos.length === 0 && (
        <div className="tarjeta"><p style={{ margin: 0 }}>Nada por revisar. Lo que subas aparece aquí con una propuesta.</p></div>
      )}
      {documentos.map(d => (
        <TarjetaDocumento key={d.id} doc={d} cuentas={cuentas}
          onListo={texto => { setMensaje(texto); onCambio() }} />
      ))}
    </>
  )
}

// ---- cuentas por pagar (SQL 72) ----

function TarjetaPorPagar({ c, cuentas, onListo }) {
  const [modo, setModo] = useState('')   // '' | 'pagar' | 'vence'
  const [form, setForm] = useState({ monto: String(c.saldo), fecha: hoyLocal(), cuenta_id: '', forma: 'transferencia', referencia: '' })
  const [vence, setVence] = useState(c.vence || '')
  const [error, setError] = useState('')
  const [ocupado, setOcupado] = useState(false)
  const cambiar = (k, v) => setForm(f => ({ ...f, [k]: v }))
  const e = estadoVencimiento(c.dias)
  const folio = [c.serie, c.folio].filter(Boolean).join('-')

  async function pagar() {
    const problema = validarPagoCfdi(form, c.saldo)
    if (problema) return setError(problema)
    setError(''); setOcupado(true)
    const r = await pagarCfdi(c.cfdi_id, form)
    setOcupado(false)
    if (r.error) return setError(r.error)
    onListo(r.saldo > 0.01
      ? `Pago registrado. A ${c.proveedor} todavía le debes ${pesos(r.saldo)}.`
      : `Factura de ${c.proveedor} pagada por completo.`)
  }
  async function guardarVence() {
    if (!vence) return setError('Escribe la fecha de vencimiento.')
    setError(''); setOcupado(true)
    const r = await programarPagoCfdi(c.cfdi_id, vence, null)
    setOcupado(false)
    if (r.error) return setError(r.error)
    onListo('Vencimiento actualizado.')
  }

  return (
    <section className="tarjeta" aria-label={`${c.proveedor}: ${e.etiqueta}`}>
      {/* El nombre del proveedor va a todo lo ancho: los de las facturas son largos ("… SA de CV"). */}
      <div className="renglon-titulo">{c.proveedor}</div>
      <div className="renglon-datos">
        {[folio && `Folio ${folio}`, fechaLegible(c.fecha), etiquetaCategoria(c.categoria), c.metodo_pago].filter(Boolean).join(' · ')}
      </div>
      {Number(c.pagado) > 0 && <div className="renglon-datos">Pagado {pesos(c.pagado)} de {pesos(c.total)}</div>}
      <div className="fila" style={{ justifyContent: 'space-between', marginTop: 8 }}>
        <span className={`estado ${e.clase}`}>{e.etiqueta}</span>
        <span className="monto" style={{ fontSize: 22 }}>{pesos(c.saldo)}</span>
      </div>
      {error && <Alerta tipo="error">{error}</Alerta>}

      {modo === 'pagar' && (
        <div style={{ marginTop: 8 }}>
          <div className="rejilla-2">
            <Campo etiqueta="Monto pagado *">
              <input type="number" inputMode="decimal" min="0" step="0.01" value={form.monto} onChange={ev => cambiar('monto', ev.target.value)} />
            </Campo>
            <Campo etiqueta="Fecha del pago *">
              <input type="date" value={form.fecha} onChange={ev => cambiar('fecha', ev.target.value)} />
            </Campo>
            <Campo etiqueta="Cuenta">
              <select value={form.cuenta_id} onChange={ev => cambiar('cuenta_id', ev.target.value)}>
                <option value="">— Sin especificar —</option>
                {cuentas.map(x => <option key={x.id} value={x.id}>{x.nombre}</option>)}
              </select>
            </Campo>
            <Campo etiqueta="Forma">
              <select value={form.forma} onChange={ev => cambiar('forma', ev.target.value)}>
                {FORMAS_PAGO.map(([k, t]) => <option key={k} value={k}>{t}</option>)}
              </select>
            </Campo>
            <Campo etiqueta="Referencia (opcional)">
              <input value={form.referencia} onChange={ev => cambiar('referencia', ev.target.value)} placeholder="Clave de rastreo" />
            </Campo>
          </div>
          <p className="ayuda">Puede ser un pago parcial. El IVA se acredita en proporción a lo que pagas.</p>
          <div className="fila">
            <button type="button" className="btn-primario" disabled={ocupado} onClick={pagar}>
              {ocupado ? 'Guardando…' : `Registrar pago de ${pesos(form.monto)}`}
            </button>
            <button type="button" onClick={() => { setModo(''); setError('') }}>Cancelar</button>
          </div>
        </div>
      )}

      {modo === 'vence' && (
        <div style={{ marginTop: 8 }}>
          <Campo etiqueta="Nueva fecha de vencimiento">
            <input type="date" value={vence} onChange={ev => setVence(ev.target.value)} />
          </Campo>
          <div className="fila">
            <button type="button" className="btn-primario" disabled={ocupado} onClick={guardarVence}>Guardar fecha</button>
            <button type="button" onClick={() => { setModo(''); setError('') }}>Cancelar</button>
          </div>
        </div>
      )}

      {!modo && (
        <div className="fila" style={{ marginTop: 8 }}>
          <button type="button" className="btn-primario" onClick={() => setModo('pagar')}>Registrar pago</button>
          <button type="button" onClick={() => setModo('vence')}>Cambiar vencimiento</button>
          {c.archivo && <button type="button" onClick={() => abrirArchivo(c.archivo)}>Ver factura</button>}
        </div>
      )}
    </section>
  )
}

function PorPagar({ datos, cuentas, onCambio }) {
  const [mensaje, setMensaje] = useState('')
  const vencidas = datos.cuentas.filter(c => Number(c.dias) < 0).length
  return (
    <>
      <div className="kpis">
        <div className="kpi kpi-principal">
          <span className="kpi-nombre">Por pagar</span>
          <span className="kpi-valor">{pesosRedondos(datos.total)}</span>
          <span className="kpi-nota">{datos.cuentas.length} {datos.cuentas.length === 1 ? 'factura' : 'facturas'}</span>
        </div>
        <div className="kpi">
          <span className="kpi-nombre">Vencido</span>
          <span className="kpi-valor">{pesosRedondos(datos.vencido)}</span>
          <span className="kpi-nota">{vencidas} {vencidas === 1 ? 'factura vencida' : 'facturas vencidas'}</span>
        </div>
      </div>
      {mensaje && <Alerta tipo="ok">{mensaje}</Alerta>}
      {datos.cuentas.length === 0 && (
        <div className="tarjeta">
          <p style={{ margin: 0 }}>No debes nada a proveedores. Una factura queda aquí cuando la apruebas como "Aún no la pago".</p>
        </div>
      )}
      {datos.cuentas.map(c => (
        <TarjetaPorPagar key={`${c.cfdi_id}-${c.saldo}-${c.vence}`} c={c} cuentas={cuentas}
          onListo={t => { setMensaje(t); onCambio() }} />
      ))}
    </>
  )
}

const OPCIONES_LIBRE = [
  ['gasto', 'Gasto'], ['retiro_dueno', 'Retiro del dueño'], ['aportacion', 'Aportación del dueño'], ['otro_ingreso', 'Otro ingreso']
]
const vacioLibre = () => ({ clase: 'gasto', categoria: 'gasolina', monto: '', iva: '', fecha: hoyLocal(), cuenta_id: '', forma: 'transferencia', concepto: '', notas: '' })

function MovimientoLibre({ cuentas, onGuardado }) {
  const [f, setF] = useState(vacioLibre())
  const [error, setError] = useState('')
  const [ocupado, setOcupado] = useState(false)
  const cambiar = (k, v) => setF(x => ({ ...x, [k]: v }))
  const categoria = f.clase === 'gasto' ? f.categoria : f.clase

  async function guardar(e) {
    e.preventDefault()
    const datos = { ...f, categoria, iva: f.clase === 'gasto' ? f.iva : '' }
    const problema = validarMovimientoLibre(datos)
    if (problema) return setError(problema)
    setError(''); setOcupado(true)
    const r = await guardarMovimientoLibre(datos)
    setOcupado(false)
    if (r.error) return setError(r.error)
    setF(vacioLibre()); onGuardado()
  }

  return (
    <details className="tarjeta">
      <summary className="resumen">Registrar un movimiento sin documento</summary>
      <form onSubmit={guardar} style={{ marginTop: 12 }}>
        {error && <Alerta tipo="error">{error}</Alerta>}
        <div className="opciones" role="radiogroup" aria-label="Tipo de movimiento" style={{ marginBottom: 14 }}>
          {OPCIONES_LIBRE.map(([k, t]) => (
            <button key={k} type="button" role="radio" className="opcion" aria-checked={f.clase === k} onClick={() => cambiar('clase', k)}>{t}</button>
          ))}
        </div>
        {f.clase === 'retiro_dueno' && <p className="ayuda">Dinero que sacas del negocio para ti. No es gasto: no cuenta en la utilidad.</p>}
        {f.clase === 'aportacion' && <p className="ayuda">Dinero tuyo que metes al negocio. No es venta: no cuenta como ingreso.</p>}
        <div className="rejilla-2">
          {f.clase === 'gasto' && (
            <Campo etiqueta="¿De qué es? *">
              <select value={f.categoria} onChange={e => cambiar('categoria', e.target.value)}>
                {CATEGORIAS_GASTO.map(([k, t]) => <option key={k} value={k}>{t}</option>)}
              </select>
            </Campo>
          )}
          <Campo etiqueta="Monto *">
            <input type="number" inputMode="decimal" min="0" step="0.01" value={f.monto} onChange={e => cambiar('monto', e.target.value)} />
          </Campo>
          {f.clase === 'gasto' && (
            <Campo etiqueta="IVA incluido (si hay factura)">
              <input type="number" inputMode="decimal" min="0" step="0.01" value={f.iva} onChange={e => cambiar('iva', e.target.value)} />
            </Campo>
          )}
          <Campo etiqueta="Fecha *">
            <input type="date" value={f.fecha} onChange={e => cambiar('fecha', e.target.value)} />
          </Campo>
          <Campo etiqueta="Cuenta">
            <select value={f.cuenta_id} onChange={e => cambiar('cuenta_id', e.target.value)}>
              <option value="">— Sin especificar —</option>
              {cuentas.map(c => <option key={c.id} value={c.id}>{c.nombre}</option>)}
            </select>
          </Campo>
          <Campo etiqueta="Forma">
            <select value={f.forma} onChange={e => cambiar('forma', e.target.value)}>
              {FORMAS_PAGO.map(([k, t]) => <option key={k} value={k}>{t}</option>)}
            </select>
          </Campo>
          <Campo etiqueta="Concepto">
            <input value={f.concepto} onChange={e => cambiar('concepto', e.target.value)} />
          </Campo>
        </div>
        <button type="submit" className="btn-primario" disabled={ocupado}>{ocupado ? 'Guardando…' : 'Guardar'}</button>
      </form>
    </details>
  )
}

function Libro({ cuentas }) {
  const [mes, setMes] = useState(hoyLocal().slice(0, 7))
  const [vuelta, setVuelta] = useState(0)
  const [leido, setLeido] = useState({ clave: '', filas: [], error: '', recortado: false })
  const clave = `${mes}#${vuelta}`
  const cargando = leido.clave !== clave

  useEffect(() => {
    let vivo = true
    const { desde, hasta } = rangoDeMes(mes)
    cargarLibro(desde, hasta).then(r => {
      if (vivo) setLeido({ clave: `${mes}#${vuelta}`, filas: r.filas || [], error: r.error || '', recortado: !!r.recortado })
    })
    return () => { vivo = false }
  }, [mes, vuelta])

  const r = resumenLibro(leido.filas)
  const maxCat = Math.max(1, ...r.por_categoria.map(c => c.monto))
  const esMesActual = mes === hoyLocal().slice(0, 7)

  return (
    <>
      <div className="cambio-mes">
        <button type="button" onClick={() => setMes(m => mesAnterior(m, 1))} aria-label="Mes anterior">‹</button>
        <strong>{nombreDeMes(mes)}</strong>
        <button type="button" onClick={() => setMes(m => mesAnterior(m, -1))} disabled={esMesActual} aria-label="Mes siguiente">›</button>
      </div>
      {leido.error && <Alerta tipo="error">{leido.error}</Alerta>}
      {leido.recortado && <Alerta tipo="aviso">Hay más de 1,000 movimientos este mes: solo se muestran los primeros.</Alerta>}

      <div className="kpis" aria-busy={cargando}>
        <div className="kpi">
          <span className="kpi-nombre">Ingresos</span>
          <span className="kpi-valor">{pesosRedondos(r.ingresos)}</span>
          <span className="kpi-nota">Cobrado en el mes</span>
        </div>
        <div className="kpi">
          <span className="kpi-nombre">Gastos</span>
          <span className="kpi-valor">{pesosRedondos(r.gastos)}</span>
          <span className="kpi-nota">Pagado en el mes</span>
        </div>
        <div className="kpi kpi-principal">
          <span className="kpi-nombre">{r.resultado >= 0 ? 'Quedó a favor' : 'Faltó'}</span>
          <span className="kpi-valor">{pesosRedondos(Math.abs(r.resultado))}</span>
          <span className="kpi-nota">Ingresos menos gastos</span>
        </div>
        <div className="kpi">
          <span className="kpi-nombre">IVA acreditable</span>
          <span className="kpi-valor">{pesosRedondos(r.iva_acreditable)}</span>
          <span className="kpi-nota">De gastos pagados con CFDI</span>
        </div>
      </div>
      {(r.retiros > 0 || r.aportaciones > 0) && (
        <p className="ayuda">Aparte del negocio: retiraste {pesos(r.retiros)} y aportaste {pesos(r.aportaciones)}.</p>
      )}

      {r.por_categoria.length > 0 && (
        <section className="tarjeta" aria-label="Gastos por tipo">
          <h3>¿En qué se gastó?</h3>
          {r.por_categoria.map(c => (
            <div key={c.categoria} style={{ marginBottom: 10 }}>
              <div className="fila" style={{ justifyContent: 'space-between' }}>
                <span>{etiquetaCategoria(c.categoria)}</span>
                <span className="monto">{pesos(c.monto)}</span>
              </div>
              <div className="barra-desglose" aria-hidden="true"><span style={{ width: `${(c.monto / maxCat) * 100}%` }} /></div>
            </div>
          ))}
        </section>
      )}

      <MovimientoLibre cuentas={cuentas} onGuardado={() => setVuelta(v => v + 1)} />

      <section className="tarjeta" aria-label="Movimientos del mes">
        <h3>Movimientos ({leido.filas.length})</h3>
        <p className="ayuda">Los cobros de una cotización se registran en su Expediente y aparecen aquí solos.</p>
        {cargando && <p>Cargando…</p>}
        {!cargando && leido.filas.length === 0 && <p>Sin movimientos en {nombreDeMes(mes)}.</p>}
        <ul style={{ listStyle: 'none', margin: 0, padding: 0 }}>
          {leido.filas.map(m => {
            const entrada = esIngreso(m.categoria)
            return (
              <li key={m.id} className="renglon">
                <div>
                  <div className="renglon-titulo">{m.concepto || etiquetaCategoria(m.categoria)}</div>
                  <div className="renglon-datos">
                    {[fechaLegible(m.fecha), etiquetaCategoria(m.categoria), m.cuenta?.nombre, m.cotizacion?.folio && `Cotización ${m.cotizacion.folio}`, m.cfdi_id && 'con CFDI'].filter(Boolean).join(' · ')}
                  </div>
                </div>
                <div className="renglon-lado">
                  <span className="ayuda">{entrada ? 'Entrada' : 'Salida'}</span>
                  <span className={`monto ${entrada ? 'monto-entrada' : 'monto-salida'}`}>{pesos(m.monto)}</span>
                </div>
              </li>
            )
          })}
        </ul>
      </section>
    </>
  )
}

const NOMBRE_TIPO_CUENTA = { banco: 'Banco', efectivo: 'Efectivo', tarjeta: 'Tarjeta', otra: 'Otra' }

function Ajustes({ empresa, cuentas, onCambio }) {
  const [e, setE] = useState({
    rfc: empresa?.rfc || '', razon_social: empresa?.razon_social || '',
    regimen_fiscal: empresa?.regimen_fiscal || '626', cp_expedicion: empresa?.cp_expedicion || ''
  })
  const [msgE, setMsgE] = useState(null)
  const [c, setC] = useState({ nombre: '', tipo: 'banco', banco: '', ultimos4: '' })
  const [msgC, setMsgC] = useState(null)
  const [ocupado, setOcupado] = useState(false)

  async function guardarE(ev) {
    ev.preventDefault(); setOcupado(true)
    const r = await guardarEmpresaFiscal(e)
    setOcupado(false)
    setMsgE(r.error ? { tipo: 'error', texto: r.error } : { tipo: 'ok', texto: 'Datos fiscales guardados.' })
    if (!r.error) onCambio()
  }
  async function guardarC(ev) {
    ev.preventDefault(); setOcupado(true)
    const r = await guardarCuenta(c)
    setOcupado(false)
    setMsgC(r.error ? { tipo: 'error', texto: r.error } : { tipo: 'ok', texto: 'Cuenta agregada.' })
    if (!r.error) { setC({ nombre: '', tipo: 'banco', banco: '', ultimos4: '' }); onCambio() }
  }

  return (
    <>
      <form className="tarjeta" onSubmit={guardarE}>
        <h3>Mi RFC</h3>
        <p className="ayuda">Con tu RFC el sistema sabe si una factura la emitiste tú o te la emitieron, y rechaza las que no son tuyas.</p>
        {msgE && <Alerta tipo={msgE.tipo}>{msgE.texto}</Alerta>}
        <div className="rejilla-2">
          <Campo etiqueta="RFC *">
            <input value={e.rfc} onChange={x => setE(v => ({ ...v, rfc: x.target.value.toUpperCase() }))} maxLength={13} autoCapitalize="characters" />
          </Campo>
          <Campo etiqueta="Nombre como aparece en tu constancia">
            <input value={e.razon_social} onChange={x => setE(v => ({ ...v, razon_social: x.target.value }))} />
          </Campo>
          <Campo etiqueta="Régimen fiscal">
            <select value={e.regimen_fiscal} onChange={x => setE(v => ({ ...v, regimen_fiscal: x.target.value }))}>
              <option value="626">626 · RESICO</option>
              <option value="612">612 · Actividad empresarial y profesional</option>
            </select>
          </Campo>
          <Campo etiqueta="Código postal fiscal">
            <input value={e.cp_expedicion} inputMode="numeric" maxLength={5} onChange={x => setE(v => ({ ...v, cp_expedicion: x.target.value }))} />
          </Campo>
        </div>
        <button type="submit" className="btn-primario" disabled={ocupado}>Guardar</button>
      </form>

      <div className="tarjeta">
        <h3>Cuentas</h3>
        <p className="ayuda">De dónde sale o a dónde entra el dinero del negocio. Lo personal no va aquí.</p>
        <ul style={{ listStyle: 'none', margin: 0, padding: 0 }}>
          {cuentas.map(x => (
            <li key={x.id} className="renglon">
              <div>
                <div className="renglon-titulo">{x.nombre}</div>
                <div className="renglon-datos">{[NOMBRE_TIPO_CUENTA[x.tipo] || x.tipo, x.banco, x.ultimos4 && `termina en ${x.ultimos4}`].filter(Boolean).join(' · ')}</div>
              </div>
              <span className={`estado ${x.activa ? 'estado-aprobado' : 'estado-cancelada'}`}>{x.activa ? 'Activa' : 'Inactiva'}</span>
            </li>
          ))}
        </ul>
        <form onSubmit={guardarC} style={{ marginTop: 12 }}>
          <h4>Agregar cuenta</h4>
          {msgC && <Alerta tipo={msgC.tipo}>{msgC.texto}</Alerta>}
          <div className="rejilla-2">
            <Campo etiqueta="Nombre *">
              <input value={c.nombre} onChange={x => setC(v => ({ ...v, nombre: x.target.value }))} placeholder="Tarjeta Banorte" />
            </Campo>
            <Campo etiqueta="Tipo">
              <select value={c.tipo} onChange={x => setC(v => ({ ...v, tipo: x.target.value }))}>
                {Object.entries(NOMBRE_TIPO_CUENTA).map(([k, t]) => <option key={k} value={k}>{t}</option>)}
              </select>
            </Campo>
            <Campo etiqueta="Banco">
              <input value={c.banco} onChange={x => setC(v => ({ ...v, banco: x.target.value }))} />
            </Campo>
            <Campo etiqueta="Últimos 4 dígitos">
              <input value={c.ultimos4} inputMode="numeric" maxLength={4} onChange={x => setC(v => ({ ...v, ultimos4: x.target.value }))} />
            </Campo>
          </div>
          <button type="submit" disabled={ocupado}>Agregar cuenta</button>
        </form>
      </div>
      <p className="ayuda">{CATEGORIAS_CAPITAL.map(([, t]) => t).join(' y ')} no cuentan como gasto ni como ingreso del negocio.</p>
    </>
  )
}

async function leerBase() {
  const [b, c, e, p] = await Promise.all([listarBandeja(), listarCuentas(), cargarEmpresaFiscal(), cargarPorPagar()])
  return {
    documentos: b.documentos || [], cuentas: c.cuentas || [], empresa: e.empresa || {},
    porPagar: p.error ? { total: 0, vencido: 0, cuentas: [] } : p,
    error: b.error || c.error || e.error || p.error || ''
  }
}

export default function Finanzas() {
  const [datos, setDatos] = useState(null)
  const [pestana, setPestana] = useState('bandeja')
  const [vuelta, setVuelta] = useState(0)

  useEffect(() => {
    let vivo = true
    leerBase().then(d => { if (vivo) setDatos(d) })
    return () => { vivo = false }
  }, [vuelta])

  const recargar = () => setVuelta(v => v + 1)
  const cuentasActivas = (datos?.cuentas || []).filter(c => c.activa)
  const PESTANAS = [
    ['bandeja', `Por revisar (${datos?.documentos.length ?? 0})`],
    ['por_pagar', `Por pagar (${datos?.porPagar.cuentas.length ?? 0})`],
    ['libro', 'Libro del mes'],
    ['impuestos', 'Impuestos'],
    ['ajustes', 'Ajustes']
  ]

  return (
    <div className="pagina pagina-angosta">
      <h2>Finanzas</h2>
      {datos?.error && <Alerta tipo="error">{datos.error}</Alerta>}
      <div className="pestanas">
        {PESTANAS.map(([k, t]) => (
          <button key={k} type="button" className="pestana" aria-pressed={pestana === k} onClick={() => setPestana(k)}>{t}</button>
        ))}
      </div>
      {!datos && <p>Cargando…</p>}
      {datos && pestana === 'bandeja' && (
        <Bandeja documentos={datos.documentos} cuentas={cuentasActivas} sinRfc={!datos.empresa?.rfc}
          irAAjustes={() => setPestana('ajustes')} onCambio={recargar} />
      )}
      {datos && pestana === 'por_pagar' && <PorPagar datos={datos.porPagar} cuentas={cuentasActivas} onCambio={recargar} />}
      {datos && pestana === 'libro' && <Libro cuentas={cuentasActivas} />}
      {datos && pestana === 'impuestos' && <Impuestos empresa={datos.empresa} />}
      {datos && pestana === 'ajustes' && (
        <Ajustes key={datos.empresa?.updated_at || 'vacio'} empresa={datos.empresa} cuentas={datos.cuentas} onCambio={recargar} />
      )}
    </div>
  )
}
