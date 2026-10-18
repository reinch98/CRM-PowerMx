import { useEffect, useMemo, useState } from 'react'
import { Alerta } from './ui'
import { hoyLocal } from './lib/fechas'
import { totalesDeCompra, cargarProductos } from './lib/compras'
import { cargarVinculos, cuadre, proveedorSugerido, armarLinea } from './lib/factura'
import { LineaFactura } from './FacturaLeida'
import {
  subirCotizacion, leerCotizacion, ultimoTipoCambio, registrarCotizacion, problemasDeCotizacion, dinero
} from './lib/cotizacionesProveedor'

// ---------------------------------------------------------------------------
// Leer una cotización de proveedor (foto o PDF) y registrarla (SQL 84).
//
// Dos puertas: en Compras se sube el archivo; desde la bandeja de Finanzas llega `origen` con el
// archivo que ya estaba ahí (y al registrarla, sale de la bandeja). La IA solo PROPONE: cada renglón
// se empata con el catálogo, se crea una pieza nueva o se omite, igual que una factura. Registrar
// una cotización NO mueve inventario: los pedidos salen al aceptarla.
// ---------------------------------------------------------------------------

const cabeceraVacia = () => ({
  proveedor: '', numero: '', fecha: '', vigencia: '', moneda: 'MXN', tipo_cambio: '', iva: '', notas: ''
})

export default function CotizacionProveedorLeida({ productos: productosDados, proveedoresConocidos, origen, onRegistrada, onCancelar }) {
  const [fase, setFase] = useState('inicio')   // inicio | leyendo | revision
  const [archivo, setArchivo] = useState(null)
  const [version, setVersion] = useState(0)
  const [subido, setSubido] = useState(null)   // { ruta, bucket, hash }
  const [lectura, setLectura] = useState(null)
  const [cab, setCab] = useState(cabeceraVacia)
  const [lineas, setLineas] = useState([])
  const [vinculos, setVinculos] = useState([])
  const [productosCargados, setProductosCargados] = useState([])
  const [tc, setTc] = useState(null)
  const [error, setError] = useState('')
  const [ocupado, setOcupado] = useState(false)
  const productos = productosDados || productosCargados

  useEffect(() => {
    let vivo = true
    cargarVinculos().then(r => { if (vivo && r.vinculos) setVinculos(r.vinculos) })
    ultimoTipoCambio().then(t => { if (vivo) setTc(t) })
    // Desde Finanzas no llega el catálogo: se carga aquí.
    if (!productosDados) cargarProductos().then(r => { if (vivo && r.ok) setProductosCargados(r.productos) })
    return () => { vivo = false }
  }, [productosDados])

  const conocidos = useMemo(
    () => [...new Set([...(proveedoresConocidos || []), ...vinculos.map(v => v.proveedor)])].filter(Boolean),
    [proveedoresConocidos, vinculos]
  )
  const skuExistentes = useMemo(() => new Set(productos.map(p => String(p.sku).toUpperCase())), [productos])
  const factor = cab.moneda === 'USD' ? Number(cab.tipo_cambio) || 0 : 1

  async function leer() {
    setError('')
    let sub = origen ? { ruta: origen.ruta, bucket: origen.bucket, hash: origen.hash } : subido
    if (!sub) {
      if (!archivo) return setError('Elige la foto o el PDF de la cotización.')
      setFase('leyendo')
      const r = await subirCotizacion(archivo)
      if (r.error) { setFase('inicio'); return setError(r.error) }
      sub = r
      setSubido(r)
    }
    setFase('leyendo')
    const r = await leerCotizacion(sub.ruta, sub.bucket)
    if (r.error) { setFase('inicio'); return setError(r.error) }
    const l = r.lectura
    if (l.lineas.length === 0) {
      setFase('inicio')
      return setError(`No pude leer ninguna línea de producto.${l.notas ? ` ${l.notas}` : ''}`)
    }
    const proveedor = proveedorSugerido(l.proveedor, conocidos) || l.proveedor
    const tipoCambio = l.moneda === 'USD' && tc?.valor ? String(tc.valor) : ''
    const ctx = { productos, vinculos, proveedor, preciosIncluyenIva: l.preciosIncluyenIva, factor: l.moneda === 'USD' ? Number(tipoCambio) || 1 : 1 }
    setLectura(l)
    setCab({
      proveedor, numero: l.numero, fecha: l.fecha || hoyLocal(), vigencia: l.vigencia, moneda: l.moneda,
      tipo_cambio: tipoCambio, iva: l.iva != null && !l.preciosIncluyenIva ? String(l.iva) : '',
      notas: [l.tiempo_entrega && `Entrega: ${l.tiempo_entrega}`].filter(Boolean).join(' ')
    })
    setLineas(l.lineas.map((x, i) => armarLinea(x, i, ctx)))
    setFase('revision')
  }

  function cambiarLinea(id, patch) {
    setLineas(ls => ls.map(x => (x.id === id ? { ...x, ...patch } : x)))
  }

  function descartar() {
    setFase('inicio'); setArchivo(null); setVersion(v => v + 1); setLectura(null); setLineas([]); setError('')
    if (onCancelar) onCancelar()
  }

  const activas = lineas.filter(l => l.decision.tipo !== 'omitir')
  const faltas = fase === 'revision'
    ? problemasDeCotizacion({ proveedor: cab.proveedor, moneda: cab.moneda, tipo_cambio: cab.tipo_cambio, lineas, skuExistentes })
    : []
  const totales = totalesDeCompra(activas, cab.iva)
  const ajuste = lectura ? cuadre(lineas, lectura.subtotal) : null

  async function registrar() {
    setError(''); setOcupado(true)
    const sub = origen || subido || {}
    const datos = {
      proveedor: cab.proveedor.trim(),
      numero: cab.numero.trim() || null,
      fecha: cab.fecha || null,
      vigencia: cab.vigencia || null,
      moneda: cab.moneda,
      tipo_cambio: cab.moneda === 'USD' ? Number(cab.tipo_cambio) : null,
      iva: cab.iva === '' ? null : Number(cab.iva),
      notas: cab.notas.trim() || null,
      archivo: sub.ruta || null,
      archivo_bucket: sub.bucket || null,
      archivo_hash: sub.hash || null,
      documento_id: origen?.documentoId || null
    }
    const r = await registrarCotizacion(datos, lineas)
    setOcupado(false)
    if (r.error) return setError(r.error)
    const d = r.data
    const partes = [`Cotización COTP-${d.folio} de ${d.proveedor} registrada por ${dinero(d.total, d.moneda)}. No movió inventario: acéptala para pedir.`]
    if (d.productos_nuevos > 0) partes.push(`${d.productos_nuevos} pieza(s) nueva(s) en el catálogo, sin publicar y sin precio.`)
    if (d.costos_actualizados > 0) partes.push(`Se actualizó el costo de ${d.costos_actualizados} pieza(s).`)
    for (const a of d.avisos || []) partes.push(a)
    setFase('inicio'); setArchivo(null); setVersion(v => v + 1); setLectura(null); setLineas([]); setSubido(null)
    onRegistrada(partes.join(' '))
  }

  if (fase !== 'revision') {
    return (
      <div>
        <p className="ayuda">
          {origen
            ? 'Se lee este mismo archivo como cotización de proveedor: propone el proveedor, el número, la vigencia y qué pieza es cada renglón. Tú lo revisas antes de guardar.'
            : 'Sube la foto o el PDF de la cotización. Se lee, se propone qué pieza es cada renglón y tú lo revisas. Registrarla no mueve inventario.'}
        </p>
        {error && <Alerta tipo="error">{error}</Alerta>}
        {!origen && (
          <label className="campo">
            <span>Cotización (foto o PDF)</span>
            <input key={version} type="file" accept="image/*,application/pdf" disabled={fase === 'leyendo'}
              onChange={e => { setArchivo(e.target.files?.[0] || null); setSubido(null) }} />
          </label>
        )}
        <div className="fila" style={{ flexWrap: 'wrap' }}>
          <button type="button" className="btn-primario" disabled={fase === 'leyendo' || (!origen && !archivo)} onClick={leer}>
            {fase === 'leyendo' ? 'Leyendo la cotización… (puede tardar un minuto)' : 'Leer la cotización'}
          </button>
          {onCancelar && <button type="button" disabled={fase === 'leyendo'} onClick={onCancelar}>Cancelar</button>}
        </div>
      </div>
    )
  }

  return (
    <div>
      <Alerta tipo="info" palabra="Revisa">
        Esto lo leyó la IA y puede equivocarse. Nada se ha guardado: revisa cada renglón y pulsa
        «Registrar cotización» al final. No mueve inventario.
      </Alerta>
      {error && <Alerta tipo="error">{error}</Alerta>}
      {lectura.preciosIncluyenIva && (
        <Alerta tipo="info" palabra="IVA incluido">
          Los precios de este documento incluyen IVA; se dividieron entre 1.16 para guardarlos sin IVA.
        </Alerta>
      )}
      {lectura.descartadas > 0 && (
        <Alerta tipo="aviso" palabra="Renglones sin leer">
          {lectura.descartadas} renglón(es) venían incompletos y no se incluyeron. Revisa la cotización.
        </Alerta>
      )}
      {lectura.notas && <Alerta tipo="aviso" palabra="La IA anotó">{lectura.notas}</Alerta>}
      {ajuste?.cuadra === false && (
        <Alerta tipo="aviso" palabra="No cuadra">
          Los renglones suman {dinero(ajuste.suma, cab.moneda)} y el subtotal de la cotización es {dinero(ajuste.esperado, cab.moneda)}
          {' '}(diferencia {dinero(ajuste.diferencia, cab.moneda)}). Puede faltar un renglón o haber un precio mal leído.
        </Alerta>
      )}

      <div className="rejilla-2">
        <label className="campo">
          <span>Proveedor *</span>
          <input list="proveedores-cotizacion" value={cab.proveedor}
            onChange={e => setCab({ ...cab, proveedor: e.target.value })} />
          <datalist id="proveedores-cotizacion">
            {conocidos.map(p => <option key={p} value={p} />)}
          </datalist>
        </label>
        <label className="campo">
          <span>Número de la cotización</span>
          <input value={cab.numero} onChange={e => setCab({ ...cab, numero: e.target.value })} />
        </label>
        <label className="campo">
          <span>Fecha</span>
          <input type="date" value={cab.fecha} onChange={e => setCab({ ...cab, fecha: e.target.value })} />
        </label>
        <label className="campo">
          <span>Vigente hasta</span>
          <input type="date" value={cab.vigencia} onChange={e => setCab({ ...cab, vigencia: e.target.value })} />
        </label>
        <label className="campo">
          <span>Moneda</span>
          <select value={cab.moneda} onChange={e => setCab({
            ...cab, moneda: e.target.value,
            tipo_cambio: e.target.value === 'USD' && !cab.tipo_cambio && tc?.valor ? String(tc.valor) : cab.tipo_cambio
          })}>
            <option value="MXN">Pesos (MXN)</option>
            <option value="USD">Dólares (USD)</option>
          </select>
        </label>
        {cab.moneda === 'USD' && (
          <label className="campo">
            <span>Tipo de cambio *</span>
            <input type="number" min="0" step="any" value={cab.tipo_cambio}
              onChange={e => setCab({ ...cab, tipo_cambio: e.target.value })} />
          </label>
        )}
      </div>
      {cab.moneda === 'USD' && tc && (
        <p className="ayuda">Propuesto: el último tipo de cambio guardado ({tc.valor} del {tc.fecha}). El costo del catálogo se guarda en pesos con este valor.</p>
      )}

      <h3 style={{ marginTop: 14 }}>Renglones de la cotización</h3>
      {lineas.map(l => (
        <LineaFactura key={l.id} l={l} productos={productos} onCambio={cambiarLinea} moneda={cab.moneda} factor={factor} />
      ))}

      <div className="rejilla-2" style={{ marginTop: 14 }}>
        <label className="campo">
          <span>IVA (vacío = 16%)</span>
          <input type="number" min="0" step="any" value={cab.iva}
            onChange={e => setCab({ ...cab, iva: e.target.value })} />
        </label>
        <label className="campo">
          <span>Notas</span>
          <input value={cab.notas} onChange={e => setCab({ ...cab, notas: e.target.value })} />
        </label>
      </div>

      <div style={{ textAlign: 'right', lineHeight: 1.8, marginTop: 10 }}>
        <div>Subtotal: {dinero(totales.subtotal, cab.moneda)}</div>
        <div>IVA: {dinero(totales.iva, cab.moneda)}</div>
        <div style={{ fontSize: 20 }}><strong>Total: {dinero(totales.total, cab.moneda)}</strong></div>
      </div>

      {faltas.length > 0 && <Alerta tipo="aviso" palabra="Falta">{faltas.join(' ')}</Alerta>}

      <div className="fila" style={{ flexWrap: 'wrap', marginTop: 10 }}>
        <button type="button" className="btn-primario btn-grande" disabled={ocupado || faltas.length > 0} onClick={registrar}>
          {ocupado ? 'Registrando…' : 'Registrar cotización'}
        </button>
        <button type="button" className="btn-grande" disabled={ocupado} onClick={descartar}>
          Descartar esta lectura
        </button>
      </div>
    </div>
  )
}
