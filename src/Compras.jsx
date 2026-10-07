import { useEffect, useMemo, useState } from 'react'
import { Alerta } from './ui'
import FacturaLeida from './FacturaLeida'
import {
  cargarCompras, cargarPedidosPorRecibir, cargarProductos, registrarCompra, cancelarCompra,
  adjuntarArchivo, urlDeArchivo, totalesDeCompra, problemasDeCompra, cambioDeCosto,
  importeLinea, lineaDesdePedido, lineaNueva,
} from './lib/compras'

// ---------------------------------------------------------------------------
// Compras: de quién se compró, a cómo y con qué factura (SQL 41).
//
// Es la mitad que le faltaba al inventario. Hasta ahora se sabía qué salió y por qué; lo que
// entraba aparecía sin proveedor, sin costo real y sin respaldo, y `productos.costo` era un
// número escrito a mano.
//
// **Quién mueve el inventario lo decide la base**, no esta pantalla: una línea ligada a un
// pedido que ya se recibió solo aporta costo y factura, porque su entrada ya existe. La
// pantalla lo dice con palabras al mostrar la compra ya guardada.
// ---------------------------------------------------------------------------

const pesos = v =>
  Number(v || 0).toLocaleString('es-MX', { style: 'currency', currency: 'MXN' })

const vacio = () => ({
  proveedor: '', factura: '', uuid_fiscal: '',
  fecha: new Date().toISOString().slice(0, 10),
  iva: '', notas: '',
})

export default function Compras() {
  const [compras, setCompras] = useState([])
  const [pedidos, setPedidos] = useState([])
  const [productos, setProductos] = useState([])
  const [form, setForm] = useState(vacio)
  const [lineas, setLineas] = useState([])
  const [buscar, setBuscar] = useState('')
  const [abierto, setAbierto] = useState(false)
  const [leyendo, setLeyendo] = useState(false)
  const [guardando, setGuardando] = useState(false)
  const [cancelando, setCancelando] = useState('')
  const [motivo, setMotivo] = useState('')
  const [xml, setXml] = useState(null)
  const [pdf, setPdf] = useState(null)
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState('')

  useEffect(() => { cargarTodo() }, [])

  async function cargarTodo() {
    setError('')
    const [c, p, pr] = await Promise.all([
      cargarCompras(), cargarPedidosPorRecibir(), cargarProductos(),
    ])
    if (!c.ok) return setError(c.texto)
    setCompras(c.compras)
    if (p.ok) setPedidos(p.pedidos)
    if (pr.ok) setProductos(pr.productos)
  }

  const costoDe = useMemo(
    () => Object.fromEntries(productos.map(p => [p.id, p.costo])),
    [productos]
  )

  const encontrados = useMemo(() => {
    const q = buscar.trim().toLowerCase()
    if (q.length < 2) return []
    return productos
      .filter(p => `${p.sku} ${p.nombre}`.toLowerCase().includes(q))
      .slice(0, 8)
  }, [buscar, productos])

  const totales = totalesDeCompra(lineas, form.iva)
  const faltas = problemasDeCompra({ proveedor: form.proveedor, lineas })

  // Los pedidos que ya se metieron a esta compra no se vuelven a ofrecer.
  const yaLigados = new Set(lineas.map(l => l.requisicion_id).filter(Boolean))
  const pedidosLibres = pedidos.filter(p => !yaLigados.has(p.requisicion_id))

  function cambiar(i, campo, valor) {
    setLineas(ls => ls.map((l, n) => (n === i ? { ...l, [campo]: valor } : l)))
  }

  function agregarProducto(p) {
    setLineas(ls => [...ls, lineaNueva(p)])
    setBuscar('')
    setAbierto(true)
  }

  function agregarPedido(p) {
    setLineas(ls => [...ls, lineaDesdePedido(p)])
    setAbierto(true)
  }

  async function guardar(e) {
    e.preventDefault()
    setError(''); setMensaje('')
    if (faltas.length > 0) return setError(faltas.join(' '))

    setGuardando(true)
    const r = await registrarCompra({
      proveedor: form.proveedor.trim(),
      factura: form.factura.trim() || null,
      uuid_fiscal: form.uuid_fiscal.trim() || null,
      fecha: form.fecha || null,
      iva: form.iva === '' ? null : Number(form.iva),
      notas: form.notas.trim() || null,
    }, lineas)

    if (!r.ok) { setGuardando(false); return setError(r.texto) }

    // Los archivos van después: su ruta cuelga del id de la compra. Si alguno falla, la compra
    // ya quedó bien y se puede volver a adjuntar.
    const problemas = []
    if (xml) {
      const a = await adjuntarArchivo(r.datos.id, xml, 'xml')
      if (!a.ok) problemas.push(`el XML no se subió (${a.texto})`)
    }
    if (pdf) {
      const a = await adjuntarArchivo(r.datos.id, pdf, 'pdf')
      if (!a.ok) problemas.push(`el PDF no se subió (${a.texto})`)
    }

    setGuardando(false)
    setForm(vacio()); setLineas([]); setXml(null); setPdf(null); setAbierto(false)
    setMensaje([
      `Compra ${r.datos.folio} registrada por ${pesos(r.datos.total)}.`,
      r.datos.aviso,
      problemas.length ? `Pero ${problemas.join(' y ')}.` : null,
    ].filter(Boolean).join(' '))
    cargarTodo()
  }

  async function cancelar(c) {
    setError(''); setMensaje('')
    if (!motivo.trim()) return setError('Escribe por qué se cancela.')
    const r = await cancelarCompra(c.id, motivo.trim())
    if (!r.ok) return setError(r.texto)
    setCancelando(''); setMotivo('')
    setMensaje(r.datos?.sin_cambio
      ? 'Esa compra ya estaba cancelada.'
      : `Compra ${r.datos.folio} cancelada. ${r.datos.aviso}`)
    cargarTodo()
  }

  async function abrirArchivo(ruta) {
    const url = await urlDeArchivo(ruta)
    if (url) window.open(url, '_blank', 'noopener')
    else setError('No se pudo abrir el archivo.')
  }

  return (
    <div className="pagina">
      <h2>Compras</h2>
      <p className="ayuda">
        Lo que entra al almacén, de quién se compró y a cómo. El costo que se captura aquí es el
        que respalda la factura.
      </p>

      {error && <Alerta tipo="error">{error}</Alerta>}
      {mensaje && <Alerta tipo="ok">{mensaje}</Alerta>}

      {/* ---- leer una factura (foto o PDF) ---- */}
      <details className="tarjeta" open={leyendo} onToggle={e => setLeyendo(e.currentTarget.open)}>
        <summary className="resumen">📄 Leer una factura (foto o PDF)</summary>
        <div style={{ marginTop: 12 }}>
          <FacturaLeida
            productos={productos}
            proveedoresConocidos={[...new Set(compras.map(c => c.proveedor))]}
            onRegistrada={texto => { setMensaje(texto); setLeyendo(false); cargarTodo() }} />
        </div>
      </details>

      {/* ---- registrar ---- */}
      <details className="tarjeta" open={abierto}
        onToggle={e => setAbierto(e.currentTarget.open)}>
        <summary className="resumen">＋ Registrar una compra</summary>

        <form onSubmit={guardar} style={{ marginTop: 12 }}>
          <div className="rejilla-2">
            <label className="campo">
              <span>Proveedor *</span>
              <input value={form.proveedor} required
                onChange={e => setForm({ ...form, proveedor: e.target.value })} />
            </label>
            <label className="campo">
              <span>Factura</span>
              <input value={form.factura} placeholder="Serie y folio del proveedor"
                onChange={e => setForm({ ...form, factura: e.target.value })} />
            </label>
            <label className="campo">
              <span>Fecha</span>
              <input type="date" value={form.fecha}
                onChange={e => setForm({ ...form, fecha: e.target.value })} />
            </label>
            <label className="campo">
              <span>UUID fiscal</span>
              <input value={form.uuid_fiscal}
                onChange={e => setForm({ ...form, uuid_fiscal: e.target.value })} />
            </label>
          </div>

          {/* pedidos que se pueden recibir con esta factura */}
          {pedidosLibres.length > 0 && (
            <div style={{ marginTop: 14 }}>
              <h3>Pedidos por recibir</h3>
              <p className="ayuda">
                Al agregar uno, esta compra lo marca recibido y mete su entrada al inventario.
              </p>
              <div className="fila" style={{ flexWrap: 'wrap' }}>
                {pedidosLibres.map(p => (
                  <button key={p.requisicion_id} type="button" onClick={() => agregarPedido(p)}>
                    Pedido {p.folio} · {p.sku} · {p.cantidad} {p.unidad || 'pza'}
                  </button>
                ))}
              </div>
            </div>
          )}

          <div style={{ marginTop: 14 }}>
            <h3>Lo que llegó</h3>
            <div className="buscador">
              <input
                placeholder="Buscar pieza por SKU o nombre"
                aria-label="Buscar pieza por SKU o nombre"
                value={buscar} onChange={e => setBuscar(e.target.value)} />
              {encontrados.length > 0 && (
                <div className="buscador-lista">
                  {encontrados.map(p => (
                    <button key={p.id} type="button" onClick={() => agregarProducto(p)}>
                      {p.sku} — {p.nombre}
                      {p.costo > 0 ? ` · costo ${pesos(p.costo)}` : ' · sin costo capturado'}
                    </button>
                  ))}
                </div>
              )}
            </div>
            <p className="ayuda">
              ¿No está en el catálogo? Date de alta la pieza en Inventario y vuelve aquí.
            </p>
          </div>

          {lineas.length === 0 && (
            <Alerta tipo="info">Agrega las piezas que trae la factura.</Alerta>
          )}

          {lineas.map((l, i) => {
            const cambio = cambioDeCosto(l, costoDe[l.producto_id])
            return (
              <div key={i} className="tarjeta" style={{ marginTop: 10 }}>
                <strong>{l.sku} — {l.nombre}</strong>
                {l.pedido && <div className="ayuda">Viene del pedido {l.pedido}</div>}
                <div className="rejilla-2" style={{ marginTop: 8 }}>
                  <label className="campo">
                    <span>Cantidad</span>
                    <input type="number" min="0" step="any" value={l.cantidad}
                      onChange={e => cambiar(i, 'cantidad', e.target.value)} />
                  </label>
                  <label className="campo">
                    <span>Costo unitario</span>
                    <input type="number" min="0" step="any" value={l.costo_unitario}
                      onChange={e => cambiar(i, 'costo_unitario', e.target.value)} />
                  </label>
                </div>
                <div style={{ marginTop: 6 }}>Importe: <strong>{pesos(importeLinea(l))}</strong></div>

                {cambio.hay && (
                  <Alerta tipo="aviso" palabra={cambio.subio ? 'Subió' : 'Bajó'}>
                    El costo de esta pieza {cambio.texto} pesos.
                    <label className="campo" style={{ marginTop: 8 }}>
                      <span>
                        <input type="checkbox" checked={!!l.actualizar_costo}
                          onChange={e => cambiar(i, 'actualizar_costo', e.target.checked)} />
                        {' '}Actualizar el costo del catálogo
                      </span>
                    </label>
                  </Alerta>
                )}
                {cambio.primero && Number(l.costo_unitario) > 0 && (
                  <Alerta tipo="info" palabra="Primera vez">
                    Esta pieza no tenía costo capturado.
                    <label className="campo" style={{ marginTop: 8 }}>
                      <span>
                        <input type="checkbox" checked={!!l.actualizar_costo}
                          onChange={e => cambiar(i, 'actualizar_costo', e.target.checked)} />
                        {' '}Guardarlo como costo del catálogo
                      </span>
                    </label>
                  </Alerta>
                )}

                <button type="button" className="btn-peligro" style={{ marginTop: 8 }}
                  onClick={() => setLineas(ls => ls.filter((_, n) => n !== i))}>
                  Quitar
                </button>
              </div>
            )
          })}

          <div className="rejilla-2" style={{ marginTop: 14 }}>
            <label className="campo">
              <span>IVA (vacío = 16%)</span>
              <input type="number" min="0" step="any" value={form.iva}
                onChange={e => setForm({ ...form, iva: e.target.value })} />
            </label>
            <label className="campo">
              <span>Notas</span>
              <input value={form.notas}
                onChange={e => setForm({ ...form, notas: e.target.value })} />
            </label>
          </div>

          <div className="rejilla-2">
            <label className="campo">
              <span>XML del CFDI</span>
              <input type="file" accept=".xml,text/xml,application/xml"
                onChange={e => setXml(e.target.files?.[0] || null)} />
            </label>
            <label className="campo">
              <span>PDF de la factura</span>
              <input type="file" accept=".pdf,application/pdf"
                onChange={e => setPdf(e.target.files?.[0] || null)} />
            </label>
          </div>

          <div style={{ textAlign: 'right', lineHeight: 1.8, marginTop: 10 }}>
            <div>Subtotal: {pesos(totales.subtotal)}</div>
            <div>IVA: {pesos(totales.iva)}</div>
            <div style={{ fontSize: 20 }}><strong>Total: {pesos(totales.total)}</strong></div>
          </div>

          {faltas.length > 0 && <Alerta tipo="aviso" palabra="Falta">{faltas.join(' ')}</Alerta>}

          <button type="submit" className="btn-primario btn-grande"
            disabled={guardando || faltas.length > 0}>
            {guardando ? 'Registrando…' : 'Registrar la compra'}
          </button>
        </form>
      </details>

      {/* ---- lo ya comprado ---- */}
      <h3 style={{ marginTop: 20 }}>Últimas compras</h3>
      {compras.length === 0 && <p className="ayuda">Todavía no hay compras registradas.</p>}

      {compras.map(c => (
        <div key={c.id} className="tarjeta" style={{ marginTop: 10 }}>
          <div className="fila" style={{ justifyContent: 'space-between', flexWrap: 'wrap' }}>
            <strong>
              Compra {c.folio} · {c.proveedor}
              {c.factura ? ` · factura ${c.factura}` : ''}
            </strong>
            <span className={`estado estado-${c.estado}`}>
              {c.estado === 'cancelada' ? 'Cancelada' : 'Registrada'}
            </span>
          </div>
          <div className="ayuda">{c.fecha} · {pesos(c.total)}</div>
          {c.motivo_cancelacion && (
            <Alerta tipo="aviso" palabra="Cancelada">{c.motivo_cancelacion}</Alerta>
          )}

          <div className="tabla-scroll" style={{ marginTop: 8 }}>
            <table style={{ width: '100%', minWidth: 520 }}>
              <thead>
                <tr>
                  <th>SKU</th><th>Pieza</th><th>Cant.</th><th>Costo</th><th>Importe</th><th>Inventario</th>
                </tr>
              </thead>
              <tbody>
                {(c.lineas || []).map((l, i) => (
                  <tr key={i}>
                    <td>{l.sku}</td>
                    <td>{l.nombre}{l.pedido ? ` · pedido ${l.pedido}` : ''}</td>
                    <td align="right">{l.cantidad}</td>
                    <td align="right">{pesos(l.costo_unitario)}</td>
                    <td align="right">{pesos(l.importe)}</td>
                    {/* Con palabra, nunca solo color: es la diferencia entre "entró" y
                        "solo se le guardó el costo porque ya había entrado". */}
                    <td>{l.movio_inventario ? 'Entró' : 'Ya había entrado'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <div className="fila" style={{ marginTop: 8, flexWrap: 'wrap' }}>
            {c.archivo_xml && (
              <button type="button" onClick={() => abrirArchivo(c.archivo_xml)}>Ver XML</button>
            )}
            {c.archivo_pdf && (
              <button type="button" onClick={() => abrirArchivo(c.archivo_pdf)}>Ver PDF</button>
            )}
            {c.estado !== 'cancelada' && cancelando !== c.id && (
              <button type="button" className="btn-peligro" onClick={() => { setCancelando(c.id); setMotivo('') }}>
                Cancelar esta compra
              </button>
            )}
          </div>

          {cancelando === c.id && (
            <div style={{ marginTop: 8 }}>
              <Alerta tipo="aviso" palabra="Ojo">
                Cancelar no borra nada: devuelve el material con movimientos de ajuste. Los
                pedidos ligados siguen marcados como recibidos.
              </Alerta>
              <label className="campo">
                <span>¿Por qué se cancela? *</span>
                <input value={motivo} onChange={e => setMotivo(e.target.value)} />
              </label>
              <div className="fila">
                <button type="button" className="btn-peligro" onClick={() => cancelar(c)}>
                  Sí, cancelar
                </button>
                <button type="button" onClick={() => { setCancelando(''); setMotivo('') }}>
                  Mejor no
                </button>
              </div>
            </div>
          )}
        </div>
      ))}
    </div>
  )
}
