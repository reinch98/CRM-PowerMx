import { useEffect, useState } from 'react'
import { Alerta } from './ui'
import { cargarProveedores } from './lib/proveedores'
import {
  leerComprobantePago, cargarOpcionesPago, registrarPagoProveedor, destinoInicial, textoOpcionFactura,
  textoOpcionCotizacion, problemasDePago, paraRegistrar, textoRegistrado
} from './lib/pagosProveedor'

// ---------------------------------------------------------------------------
// Un comprobante de pago a proveedor que está en la bandeja de Finanzas (SQL 85).
//
// Se lee con la IA como comprobante bancario, se busca qué le debemos a ese proveedor y se elige a qué
// se aplica: una factura por pagar (la que cuadra exacto sale primero), un anticipo de una cotización
// suya, o un anticipo suelto. Si la base ve un pago parecido (misma clave de rastreo, o mismo monto en
// la semana) no registra nada hasta que se confirme. Los cobros de clientes NO van aquí: van al
// Expediente de su cotización.
// ---------------------------------------------------------------------------

const FORMAS = [['transferencia', 'Transferencia'], ['deposito', 'Depósito'], ['cheque', 'Cheque'], ['efectivo', 'Efectivo']]

function Campo({ etiqueta, children }) {
  return <label className="campo"><span>{etiqueta}</span>{children}</label>
}

export default function PagoProveedorLeido({ doc, cuentas = [], onListo, onCancelar }) {
  const [form, setForm] = useState(() => ({
    proveedor: doc?.extraido?.proveedor || '', proveedor_id: '',
    monto: doc?.propuesta?.monto ?? doc?.extraido?.total ?? '',
    fecha: doc?.propuesta?.fecha || doc?.extraido?.fecha || '',
    forma: 'transferencia', referencia: '', cuenta_id: '', notas: ''
  }))
  const [opciones, setOpciones] = useState(null)
  const [destino, setDestino] = useState({ tipo: 'anticipo', id: null })
  const [conocidos, setConocidos] = useState([])
  const [leyendo, setLeyendo] = useState(false)
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')
  const [notaIA, setNotaIA] = useState('')
  const [parecidos, setParecidos] = useState([])   // avisos de pagos que parecen el mismo

  useEffect(() => {
    let vivo = true
    cargarProveedores().then(r => { if (vivo && r.data) setConocidos(r.data.map(p => p.nombre)) })
    return () => { vivo = false }
  }, [])

  const cambiar = (campo, valor) => {
    setForm(f => ({ ...f, [campo]: valor, ...(campo === 'proveedor' ? { proveedor_id: '' } : {}) }))
    if (campo === 'proveedor' || campo === 'monto') { setOpciones(null); setParecidos([]) }
  }

  async function buscar(f = form) {
    setError('')
    if (!String(f.proveedor).trim()) return setError('Escribe a qué proveedor se le pagó.')
    const r = await cargarOpcionesPago(f.proveedor, f.monto)
    if (r.error) return setError(r.error)
    setOpciones(r.data)
    setDestino(destinoInicial(r.data))
    if (r.data?.proveedor) setForm(x => ({ ...x, proveedor_id: r.data.proveedor.id, proveedor: r.data.proveedor.nombre }))
  }

  async function leer() {
    setError(''); setLeyendo(true)
    const r = await leerComprobantePago(doc.archivo)
    setLeyendo(false)
    if (r.error) return setError(`${r.error} Captura los datos a mano.`)
    const l = r.lectura
    const nuevo = {
      ...form,
      proveedor: l.beneficiario || form.proveedor, proveedor_id: l.beneficiario ? '' : form.proveedor_id,
      monto: l.monto ?? form.monto, fecha: l.fecha || form.fecha, forma: l.forma || form.forma,
      referencia: l.referencia || form.referencia, notas: l.concepto ? `Concepto: ${l.concepto}` : form.notas
    }
    setForm(nuevo)
    setNotaIA(l.notas)
    setOpciones(null); setParecidos([])
    if (nuevo.proveedor) buscar(nuevo)
  }

  const faltas = problemasDePago(form, destino, opciones)

  async function registrar(confirmar = false) {
    setError(''); setOcupado(true)
    const r = await registrarPagoProveedor(paraRegistrar(form, destino, doc.id), confirmar)
    setOcupado(false)
    if (r.error) return setError(r.error)
    if (r.data?.requiere_confirmar) return setParecidos(r.data.avisos || [])
    onListo(textoRegistrado(r.data))
  }

  const opcionesLista = opciones ? [
    ...opciones.facturas.map(f => ({ clave: `f:${f.cfdi_id}`, destino: { tipo: 'factura', id: f.cfdi_id }, texto: textoOpcionFactura(f, form.monto) })),
    ...opciones.cotizaciones.map(c => ({ clave: `c:${c.id}`, destino: { tipo: 'cotizacion', id: c.id }, texto: textoOpcionCotizacion(c) })),
    { clave: 'a', destino: { tipo: 'anticipo', id: null }, texto: 'Anticipo sin factura ni cotización (se aplica cuando llegue la factura)' }
  ] : []
  const elegida = o => o.destino.tipo === destino.tipo && (o.destino.id || null) === (destino.id || null)

  return (
    <div>
      <p className="ayuda">
        Se registra como pago a un proveedor: paga una factura suya o queda como anticipo. Un cobro de un
        cliente no va aquí: regístralo en el Expediente de su cotización.
      </p>
      {error && <Alerta tipo="error">{error}</Alerta>}
      {notaIA && <Alerta tipo="aviso" palabra="La IA anotó">{notaIA}</Alerta>}

      <button type="button" disabled={leyendo || ocupado} onClick={leer} style={{ marginBottom: 12 }}>
        {leyendo ? 'Leyendo el comprobante…' : 'Leer el comprobante con IA'}
      </button>

      <div className="rejilla-2">
        <Campo etiqueta="Proveedor (quien recibió el pago) *">
          <input list="proveedores-pago" value={form.proveedor} onChange={e => cambiar('proveedor', e.target.value)} />
          <datalist id="proveedores-pago">{conocidos.map(p => <option key={p} value={p} />)}</datalist>
        </Campo>
        <Campo etiqueta="Monto pagado *">
          <input type="number" min="0" step="any" value={form.monto} onChange={e => cambiar('monto', e.target.value)} />
        </Campo>
        <Campo etiqueta="Fecha del pago *">
          <input type="date" value={form.fecha} onChange={e => cambiar('fecha', e.target.value)} />
        </Campo>
        <Campo etiqueta="Forma">
          <select value={form.forma} onChange={e => cambiar('forma', e.target.value)}>
            {FORMAS.map(([k, t]) => <option key={k} value={k}>{t}</option>)}
          </select>
        </Campo>
        <Campo etiqueta="Clave de rastreo o referencia">
          <input value={form.referencia} onChange={e => cambiar('referencia', e.target.value)} />
        </Campo>
        <Campo etiqueta="Cuenta de donde salió">
          <select value={form.cuenta_id} onChange={e => cambiar('cuenta_id', e.target.value)}>
            <option value="">— Sin especificar —</option>
            {cuentas.map(c => <option key={c.id} value={c.id}>{c.nombre}</option>)}
          </select>
        </Campo>
      </div>
      <Campo etiqueta="Notas">
        <input value={form.notas} onChange={e => cambiar('notas', e.target.value)} />
      </Campo>

      {!opciones && (
        <div className="fila" style={{ flexWrap: 'wrap', marginTop: 10 }}>
          <button type="button" className="btn-primario" disabled={ocupado} onClick={() => buscar()}>Ver a qué se aplica</button>
          {onCancelar && <button type="button" disabled={ocupado} onClick={onCancelar}>Cancelar</button>}
        </div>
      )}

      {opciones && (
        <div style={{ marginTop: 12 }}>
          {!opciones.proveedor && (
            <Alerta tipo="aviso" palabra="Proveedor nuevo">
              No reconozco a «{form.proveedor}»: se dará de alta al registrar y el pago quedará como anticipo.
            </Alerta>
          )}
          {opciones.proveedor && opciones.facturas.length === 0 && (
            <p className="ayuda">{opciones.proveedor.nombre} no tiene facturas por pagar: el pago quedará como anticipo.</p>
          )}
          <h3 style={{ marginTop: 6 }}>¿A qué se aplica?</h3>
          <div role="radiogroup" aria-label="¿A qué se aplica el pago?" style={{ display: 'grid', gap: 8 }}>
            {opcionesLista.map(o => (
              <button key={o.clave} type="button" role="radio" aria-checked={elegida(o)}
                className={elegida(o) ? 'btn-primario' : ''} style={{ textAlign: 'left' }}
                onClick={() => { setDestino(o.destino); setParecidos([]) }}>
                {elegida(o) ? '✓ ' : ''}{o.texto}
              </button>
            ))}
          </div>

          {faltas.length > 0 && <Alerta tipo="aviso" palabra="Falta">{faltas.join(' ')}</Alerta>}

          {parecidos.length > 0 && (
            <Alerta tipo="aviso" palabra="¿Repetido?">
              {parecidos.join(' ')} Si es otro pago distinto, confírmalo; si es el mismo, no lo registres.
            </Alerta>
          )}

          <div className="fila" style={{ flexWrap: 'wrap', marginTop: 10 }}>
            {parecidos.length > 0 ? (
              <button type="button" className="btn-primario" disabled={ocupado || faltas.length > 0} onClick={() => registrar(true)}>
                {ocupado ? 'Registrando…' : 'Sí, es otro pago: registrarlo'}
              </button>
            ) : (
              <button type="button" className="btn-primario" disabled={ocupado || faltas.length > 0} onClick={() => registrar(false)}>
                {ocupado ? 'Registrando…' : 'Registrar el pago'}
              </button>
            )}
            {onCancelar && <button type="button" disabled={ocupado} onClick={onCancelar}>Cancelar</button>}
          </div>
        </div>
      )}
    </div>
  )
}
