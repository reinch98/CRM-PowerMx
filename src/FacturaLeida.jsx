import { useEffect, useMemo, useState } from 'react'
import { Alerta } from './ui'
import { totalesDeCompra, cambioDeCosto } from './lib/compras'
import {
  subirParaLeer, leerFactura, cargarVinculos, registrarCompraDeFactura, candidatos, decisionInicial,
  textoDeRazon, TEXTO_CERTEZA, costoSinIva, cuadre, proveedorSugerido, skuSugerido,
  problemasDeRevision
} from './lib/factura'

// ---------------------------------------------------------------------------
// Leer una factura de proveedor (foto o PDF) y meterla al almacén (SQL 62).
//
// La IA solo PROPONE. Cada línea se revisa aquí: se empata con una pieza del catálogo, se crea una
// pieza nueva ligada al proveedor y a su código, o se omite. Hasta pulsar "Registrar" no entra
// NADA al almacén: un precio o una cantidad mal leídos contaminarían el costo real de todo lo que
// se venda después.
// ---------------------------------------------------------------------------

const pesos = v => Number(v || 0).toLocaleString('es-MX', { style: 'currency', currency: 'MXN' })

const CATEGORIAS_NUEVAS = [
  ['refaccion', 'Refacciones'],
  ['accesorio_solar', 'Accesorios solares'],
  ['inversor', 'Inversores'],
  ['bateria', 'Baterías'],
  ['panel', 'Paneles'],
  ['generador', 'Generadores']
]

const cabeceraVacia = () => ({ proveedor: '', factura: '', uuid_fiscal: '', fecha: '', iva: '', notas: '' })

// Una línea leída lista para revisar, con su propuesta de pareja.
function armarLinea(l, i, ctx) {
  const cands = candidatos(l, ctx)
  const decision = decisionInicial(cands)
  const nuevo = { sku: skuSugerido(l.codigo), nombre: l.descripcion, categoria: 'refaccion', unidad: l.unidad || 'pieza' }
  const costo = costoSinIva(l.precio_unitario, ctx.preciosIncluyenIva)
  const elegido = decision.tipo === 'producto' ? ctx.productos.find(p => p.id === decision.producto_id) : null
  return {
    id: i,
    codigo: l.codigo,
    descripcion: l.descripcion,
    cantidad: l.cantidad,
    costo_unitario: costo,
    candidatos: cands,
    certeza: decision.certeza,
    decision: { tipo: decision.tipo, producto_id: decision.producto_id, nuevo },
    // El costo del catálogo se actualiza solo si la pieza no tenía ninguno; si ya tenía, se
    // pregunta (una compra de urgencia a sobreprecio no debe reescribirlo sin que alguien decida).
    actualizar_costo: elegido ? cambioDeCosto({ costo_unitario: costo }, elegido.costo).primero === true : false
  }
}

function valorDelSelect(d) {
  if (d.tipo === 'producto' && d.producto_id) return `p:${d.producto_id}`
  if (d.tipo === 'nuevo') return '__nuevo'
  if (d.tipo === 'omitir') return '__omitir'
  if (d.tipo === 'buscar') return '__buscar'
  return ''
}

function LineaFactura({ l, productos, onCambio }) {
  const [q, setQ] = useState('')
  const d = l.decision
  const elegido = d.tipo === 'producto' ? productos.find(p => p.id === d.producto_id) : null
  const cambio = elegido ? cambioDeCosto({ costo_unitario: l.costo_unitario }, elegido.costo) : null
  const encontrados = useMemo(() => {
    const t = q.trim().toLowerCase()
    if (d.tipo !== 'buscar' || t.length < 2) return []
    return productos.filter(p => `${p.sku} ${p.nombre}`.toLowerCase().includes(t)).slice(0, 8)
  }, [q, d.tipo, productos])

  function elegir(valor) {
    if (valor.startsWith('p:')) {
      const p = productos.find(x => x.id === valor.slice(2))
      onCambio(l.id, {
        decision: { ...d, tipo: 'producto', producto_id: valor.slice(2) },
        actualizar_costo: p ? cambioDeCosto({ costo_unitario: l.costo_unitario }, p.costo).primero === true : false
      })
    } else if (valor === '__nuevo') onCambio(l.id, { decision: { ...d, tipo: 'nuevo' }, actualizar_costo: true })
    else if (valor === '__omitir') onCambio(l.id, { decision: { ...d, tipo: 'omitir' } })
    else if (valor === '__buscar') onCambio(l.id, { decision: { ...d, tipo: 'buscar', producto_id: undefined } })
    else onCambio(l.id, { decision: { ...d, tipo: 'pendiente', producto_id: undefined } })
  }
  const cambiarNuevo = (campo, v) => onCambio(l.id, { decision: { ...d, nuevo: { ...d.nuevo, [campo]: v } } })

  const omitida = d.tipo === 'omitir'
  return (
    <div className="tarjeta" style={{ marginTop: 10, opacity: omitida ? 0.6 : 1 }}>
      <div className="fila" style={{ justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
        <strong>{l.descripcion}</strong>
        <span className="estado estado-pendiente">{omitida ? 'Omitida' : TEXTO_CERTEZA[l.certeza] || ''}</span>
      </div>
      {l.codigo && <div className="ayuda">Código del proveedor: {l.codigo}</div>}

      <label className="campo" style={{ marginTop: 8 }}>
        <span>¿Qué pieza es?</span>
        <select value={valorDelSelect(d)} onChange={e => elegir(e.target.value)}>
          <option value="">— Elige —</option>
          {l.candidatos.map(c => (
            <option key={c.producto.id} value={`p:${c.producto.id}`}>
              {c.producto.sku} — {c.producto.nombre} · {textoDeRazon(c)}
            </option>
          ))}
          {elegido && !l.candidatos.some(c => c.producto.id === elegido.id) && (
            <option value={`p:${elegido.id}`}>{elegido.sku} — {elegido.nombre}</option>
          )}
          <option value="__buscar">Buscar otra pieza del catálogo…</option>
          <option value="__nuevo">Crear una pieza nueva</option>
          <option value="__omitir">No es material (omitir)</option>
        </select>
      </label>

      {d.tipo === 'buscar' && (
        <div className="buscador">
          <input placeholder="Buscar por SKU o nombre" aria-label="Buscar pieza por SKU o nombre"
            value={q} onChange={e => setQ(e.target.value)} />
          {encontrados.length > 0 && (
            <div className="buscador-lista">
              {encontrados.map(p => (
                <button key={p.id} type="button" onClick={() => { elegir(`p:${p.id}`); setQ('') }}>
                  {p.sku} — {p.nombre}
                </button>
              ))}
            </div>
          )}
        </div>
      )}

      {d.tipo === 'nuevo' && (
        <div style={{ marginTop: 8 }}>
          <div className="rejilla-2">
            <label className="campo">
              <span>SKU de la pieza *</span>
              <input value={d.nuevo.sku} onChange={e => cambiarNuevo('sku', e.target.value)} />
            </label>
            <label className="campo">
              <span>Categoría *</span>
              <select value={d.nuevo.categoria} onChange={e => cambiarNuevo('categoria', e.target.value)}>
                {CATEGORIAS_NUEVAS.map(([k, t]) => <option key={k} value={k}>{t}</option>)}
              </select>
            </label>
            <label className="campo">
              <span>Nombre *</span>
              <input value={d.nuevo.nombre} onChange={e => cambiarNuevo('nombre', e.target.value)} />
            </label>
            <label className="campo">
              <span>Unidad</span>
              <input value={d.nuevo.unidad} onChange={e => cambiarNuevo('unidad', e.target.value)} />
            </label>
          </div>
          <p className="ayuda">
            Se crea sin publicar y sin precio, ligada a este proveedor
            {l.codigo ? ` con su código ${l.codigo}` : ' (la factura no trae código)'}.
          </p>
        </div>
      )}

      {!omitida && (
        <>
          <div className="rejilla-2" style={{ marginTop: 8 }}>
            <label className="campo">
              <span>Cantidad</span>
              <input type="number" min="0" step="any" value={l.cantidad}
                onChange={e => onCambio(l.id, { cantidad: e.target.value })} />
            </label>
            <label className="campo">
              <span>Costo unitario (sin IVA)</span>
              <input type="number" min="0" step="any" value={l.costo_unitario}
                onChange={e => onCambio(l.id, { costo_unitario: e.target.value })} />
            </label>
          </div>
          <div style={{ marginTop: 6 }}>
            Importe: <strong>{pesos(Number(l.cantidad || 0) * Number(l.costo_unitario || 0))}</strong>
          </div>
        </>
      )}

      {cambio?.hay && !omitida && (
        <Alerta tipo="aviso" palabra={cambio.subio ? 'Subió' : 'Bajó'}>
          El costo de esta pieza {cambio.texto} pesos.
          <label className="campo" style={{ marginTop: 8 }}>
            <span>
              <input type="checkbox" checked={!!l.actualizar_costo}
                onChange={e => onCambio(l.id, { actualizar_costo: e.target.checked })} />
              {' '}Actualizar el costo del catálogo
            </span>
          </label>
        </Alerta>
      )}
      {cambio?.primero && !omitida && (
        <Alerta tipo="info" palabra="Primera vez">
          Esta pieza no tenía costo capturado.
          <label className="campo" style={{ marginTop: 8 }}>
            <span>
              <input type="checkbox" checked={!!l.actualizar_costo}
                onChange={e => onCambio(l.id, { actualizar_costo: e.target.checked })} />
              {' '}Guardarlo como costo del catálogo
            </span>
          </label>
        </Alerta>
      )}
    </div>
  )
}

export default function FacturaLeida({ productos, proveedoresConocidos, onRegistrada }) {
  const [fase, setFase] = useState('inicio')   // inicio | leyendo | revision
  const [archivo, setArchivo] = useState(null)
  const [version, setVersion] = useState(0)
  const [ruta, setRuta] = useState('')
  const [lectura, setLectura] = useState(null)
  const [cab, setCab] = useState(cabeceraVacia)
  const [lineas, setLineas] = useState([])
  const [vinculos, setVinculos] = useState([])
  const [error, setError] = useState('')
  const [ocupado, setOcupado] = useState(false)

  useEffect(() => {
    let vivo = true
    cargarVinculos().then(r => { if (vivo && r.vinculos) setVinculos(r.vinculos) })
    return () => { vivo = false }
  }, [])

  const conocidos = useMemo(
    () => [...new Set([...(proveedoresConocidos || []), ...vinculos.map(v => v.proveedor)])].filter(Boolean),
    [proveedoresConocidos, vinculos]
  )
  const skuExistentes = useMemo(() => new Set(productos.map(p => String(p.sku).toUpperCase())), [productos])

  async function leer() {
    if (!archivo) return setError('Elige la foto o el PDF de la factura.')
    setError(''); setFase('leyendo')
    const sub = await subirParaLeer(archivo)
    if (sub.error) { setFase('inicio'); return setError(sub.error) }
    const r = await leerFactura(sub.ruta)
    if (r.error) { setFase('inicio'); return setError(r.error) }
    const l = r.lectura
    if (l.lineas.length === 0) {
      setFase('inicio')
      return setError(`No pude leer ninguna línea de producto.${l.notas ? ` ${l.notas}` : ''}`)
    }
    const proveedor = proveedorSugerido(l.proveedor, conocidos) || l.proveedor
    const ctx = { productos, vinculos, proveedor, preciosIncluyenIva: l.preciosIncluyenIva }
    setRuta(sub.ruta)
    setLectura(l)
    setCab({
      proveedor, factura: l.factura, uuid_fiscal: l.uuid_fiscal, fecha: l.fecha,
      iva: l.iva != null && !l.preciosIncluyenIva ? String(l.iva) : '', notas: ''
    })
    setLineas(l.lineas.map((x, i) => armarLinea(x, i, ctx)))
    setFase('revision')
  }

  function cambiarLinea(id, patch) {
    setLineas(ls => ls.map(x => (x.id === id ? { ...x, ...patch } : x)))
  }

  function descartar() {
    setFase('inicio'); setArchivo(null); setVersion(v => v + 1); setLectura(null); setLineas([]); setError('')
  }

  const activas = lineas.filter(l => l.decision.tipo !== 'omitir')
  const faltas = fase === 'revision'
    ? problemasDeRevision({ proveedor: cab.proveedor, lineas, skuExistentes })
    : []
  const totales = totalesDeCompra(activas, cab.iva)
  const ajuste = lectura ? cuadre(lineas, lectura.subtotal) : null

  async function registrar() {
    setError(''); setOcupado(true)
    const datos = {
      proveedor: cab.proveedor.trim(),
      factura: cab.factura.trim() || null,
      uuid_fiscal: cab.uuid_fiscal.trim() || null,
      fecha: cab.fecha || null,
      iva: cab.iva === '' ? null : Number(cab.iva),
      notas: cab.notas.trim() || null,
      archivo_pdf: ruta
    }
    const r = await registrarCompraDeFactura(datos, lineas)
    setOcupado(false)
    if (r.error) return setError(r.error)
    const d = r.datos
    const partes = [`Compra ${d.folio} registrada por ${pesos(d.total)}: ${d.entradas} pieza(s) entraron al almacén.`]
    if (d.productos_nuevos > 0) partes.push(`${d.productos_nuevos} pieza(s) nueva(s) creadas, sin publicar y sin precio.`)
    descartar()
    onRegistrada(partes.join(' '))
  }

  if (fase !== 'revision') {
    return (
      <div>
        <p className="ayuda">
          Sube la foto o el PDF de la factura. Se lee, se propone qué pieza es cada renglón y tú lo
          revisas antes de que entre algo al almacén.
        </p>
        {error && <Alerta tipo="error">{error}</Alerta>}
        <label className="campo">
          <span>Factura (foto o PDF)</span>
          <input key={version} type="file" accept="image/*,application/pdf" disabled={fase === 'leyendo'}
            onChange={e => setArchivo(e.target.files?.[0] || null)} />
        </label>
        <button type="button" className="btn-primario" disabled={fase === 'leyendo' || !archivo} onClick={leer}>
          {fase === 'leyendo' ? 'Leyendo la factura… (puede tardar un minuto)' : 'Leer la factura'}
        </button>
      </div>
    )
  }

  return (
    <div>
      <Alerta tipo="info" palabra="Revisa">
        Esto lo leyó la IA y puede equivocarse. Nada ha entrado al almacén: revisa cada línea y
        pulsa «Registrar» al final.
      </Alerta>
      {error && <Alerta tipo="error">{error}</Alerta>}
      {lectura.moneda === 'USD' && (
        <Alerta tipo="aviso" palabra="Dólares">
          La factura está en dólares y la compra se guarda en pesos: escribe los costos ya convertidos.
        </Alerta>
      )}
      {lectura.preciosIncluyenIva && (
        <Alerta tipo="info" palabra="IVA incluido">
          Los precios de este documento incluyen IVA; se dividieron entre 1.16 para guardar el costo sin IVA.
        </Alerta>
      )}
      {lectura.descartadas > 0 && (
        <Alerta tipo="aviso" palabra="Renglones sin leer">
          {lectura.descartadas} renglón(es) venían incompletos y no se incluyeron. Revisa la factura.
        </Alerta>
      )}
      {lectura.notas && <Alerta tipo="aviso" palabra="La IA anotó">{lectura.notas}</Alerta>}
      {ajuste?.cuadra === false && (
        <Alerta tipo="aviso" palabra="No cuadra">
          Las líneas suman {pesos(ajuste.suma)} y el subtotal de la factura es {pesos(ajuste.esperado)}
          {' '}(diferencia {pesos(ajuste.diferencia)}). Puede faltar o sobrar un renglón, o haber un precio mal leído.
        </Alerta>
      )}
      {ajuste?.cuadra === true && (
        <p className="ayuda">Las líneas suman el subtotal de la factura ({pesos(ajuste.esperado)}).</p>
      )}

      <div className="rejilla-2">
        <label className="campo">
          <span>Proveedor *</span>
          <input list="proveedores-factura" value={cab.proveedor}
            onChange={e => setCab({ ...cab, proveedor: e.target.value })} />
          <datalist id="proveedores-factura">
            {conocidos.map(p => <option key={p} value={p} />)}
          </datalist>
        </label>
        <label className="campo">
          <span>Factura</span>
          <input value={cab.factura} onChange={e => setCab({ ...cab, factura: e.target.value })} />
        </label>
        <label className="campo">
          <span>Fecha</span>
          <input type="date" value={cab.fecha} onChange={e => setCab({ ...cab, fecha: e.target.value })} />
        </label>
        <label className="campo">
          <span>UUID fiscal</span>
          <input value={cab.uuid_fiscal} onChange={e => setCab({ ...cab, uuid_fiscal: e.target.value })} />
        </label>
      </div>

      <h3 style={{ marginTop: 14 }}>Líneas de la factura</h3>
      {lineas.map(l => <LineaFactura key={l.id} l={l} productos={productos} onCambio={cambiarLinea} />)}

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
        <div>Subtotal: {pesos(totales.subtotal)}</div>
        <div>IVA: {pesos(totales.iva)}</div>
        <div style={{ fontSize: 20 }}><strong>Total: {pesos(totales.total)}</strong></div>
      </div>

      {faltas.length > 0 && <Alerta tipo="aviso" palabra="Falta">{faltas.join(' ')}</Alerta>}

      <div className="fila" style={{ flexWrap: 'wrap', marginTop: 10 }}>
        <button type="button" className="btn-primario btn-grande" disabled={ocupado || faltas.length > 0}
          onClick={registrar}>
          {ocupado ? 'Registrando…' : 'Registrar y meter al almacén'}
        </button>
        <button type="button" className="btn-grande" disabled={ocupado} onClick={descartar}>
          Descartar esta lectura
        </button>
      </div>
    </div>
  )
}
