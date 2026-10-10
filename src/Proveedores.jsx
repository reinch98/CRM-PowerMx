import { useEffect, useMemo, useState } from 'react'
import { Alerta } from './ui'
import { hoyLocal } from './lib/fechas'
import { pesos, pesosRedondos, fechaLegible, etiquetaCategoria } from './lib/finanzas'
import {
  cargarProveedores, cargarCarpeta, cargarParecidos, guardarProveedor, unirProveedores, marcarDistintos,
  filtrarProveedores, formVacio, aFormulario, validarProveedor, textoUnion, resumenLinea, estadoFactura,
  ESTADO_PEDIDO
} from './lib/proveedores'

// ---------------------------------------------------------------------------
// Proveedores (SQL 80). Solo admin.
//
// La carpeta de cada proveedor: sus facturas y lo que se le debe, lo que se le ha pagado, las
// compras, los pedidos y las piezas que vende. Las fichas se crean SOLAS cuando entra una compra,
// un pedido o una factura con un nombre nuevo; aquí se completan (RFC, contacto) y se juntan las
// que resultaron ser el mismo proveedor escrito de dos maneras.
// ---------------------------------------------------------------------------

async function leerTodo() {
  const [l, p] = await Promise.all([cargarProveedores(), cargarParecidos()])
  return { lista: l.data || [], parecidos: p.data || [], error: l.error || p.error || '' }
}

function Campo({ etiqueta, children }) {
  return <label className="campo"><span>{etiqueta}</span>{children}</label>
}

function FormProveedor({ id, inicial, onGuardado, onCancelar }) {
  const [form, setForm] = useState(inicial || formVacio())
  const [error, setError] = useState('')
  const [ocupado, setOcupado] = useState(false)
  const cambiar = (campo, valor) => setForm(f => ({ ...f, [campo]: valor }))

  async function enviar(e) {
    e.preventDefault()
    const problema = validarProveedor(form)
    if (problema) return setError(problema)
    setError(''); setOcupado(true)
    const r = await guardarProveedor(id, form)
    setOcupado(false)
    if (r.error) return setError(r.error)
    onGuardado(r.data?.id, form.nombre.trim())
  }

  return (
    <form onSubmit={enviar}>
      {error && <Alerta tipo="error">{error}</Alerta>}
      <div className="rejilla-2">
        <Campo etiqueta="Nombre *">
          <input value={form.nombre} onChange={e => cambiar('nombre', e.target.value)} autoComplete="off" />
        </Campo>
        <Campo etiqueta="RFC">
          <input value={form.rfc} onChange={e => cambiar('rfc', e.target.value)} autoComplete="off"
            placeholder="ABC010101XY1" />
        </Campo>
        <Campo etiqueta="Contacto">
          <input value={form.contacto} onChange={e => cambiar('contacto', e.target.value)} />
        </Campo>
        <Campo etiqueta="Teléfono">
          <input type="tel" value={form.telefono} onChange={e => cambiar('telefono', e.target.value)} />
        </Campo>
        <Campo etiqueta="Correo">
          <input type="email" value={form.email} onChange={e => cambiar('email', e.target.value)} />
        </Campo>
      </div>
      <Campo etiqueta="Otras formas de escribirlo (una por renglón)">
        <textarea rows={3} value={form.alias} onChange={e => cambiar('alias', e.target.value)}
          placeholder="Como viene impreso en sus facturas" />
      </Campo>
      <p className="ayuda">Con estas, su próxima factura o compra se reconoce sola aunque traiga otro nombre.</p>
      <Campo etiqueta="Notas">
        <textarea rows={2} value={form.notas} onChange={e => cambiar('notas', e.target.value)} />
      </Campo>
      {id && (
        <label className="fila" style={{ gap: 10, alignItems: 'center', minHeight: 48 }}>
          <input type="checkbox" checked={form.activo} onChange={e => cambiar('activo', e.target.checked)} />
          <span>Activo (desmarca si ya no le compras)</span>
        </label>
      )}
      <div className="fila" style={{ marginTop: 12 }}>
        <button type="submit" className="btn-primario" disabled={ocupado}>{ocupado ? 'Guardando…' : 'Guardar'}</button>
        {onCancelar && <button type="button" onClick={onCancelar} disabled={ocupado}>Cancelar</button>}
      </div>
    </form>
  )
}

function Ficha({ p }) {
  return (
    <div>
      <div className="renglon-titulo">{p.nombre}</div>
      <div className="renglon-datos">
        {p.rfc ? `RFC ${p.rfc}` : 'Sin RFC'}
        {p.alias?.length > 0 && ` · también: ${p.alias.join(', ')}`}
      </div>
    </div>
  )
}

// "¿Son el mismo?": la base propone, el admin decide.
function Parecidos({ pares, onCambio, onAviso }) {
  const [confirmar, setConfirmar] = useState(null)   // { queda, seVa }
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')

  async function unir() {
    setOcupado(true); setError('')
    const r = await unirProveedores(confirmar.queda.id, confirmar.seVa.id)
    setOcupado(false)
    if (r.error) return setError(r.error)
    onAviso(textoUnion(r.data?.movidos, confirmar.queda.nombre, confirmar.seVa.nombre))
    setConfirmar(null); onCambio()
  }

  async function distintos(a, b) {
    setOcupado(true); setError('')
    const r = await marcarDistintos(a.id, b.id)
    setOcupado(false)
    if (r.error) return setError(r.error)
    onCambio()
  }

  if (pares.length === 0) return null
  return (
    <section className="tarjeta">
      <h3 style={{ marginTop: 0 }}>¿Son el mismo proveedor? ({pares.length})</h3>
      <p className="ayuda">Se parecen por el nombre. Si son el mismo, únelos: todo pasa a una sola carpeta.</p>
      {error && <Alerta tipo="error">{error}</Alerta>}
      {pares.map(({ a, b }) => {
        const esta = confirmar && [a.id, b.id].includes(confirmar.queda.id) && [a.id, b.id].includes(confirmar.seVa.id)
        return (
          <div key={`${a.id}-${b.id}`} className="renglon" style={{ display: 'grid', gap: 10 }}>
            <Ficha p={a} />
            <Ficha p={b} />
            {esta ? (
              <>
                <Alerta tipo="aviso">
                  Todo lo de «{confirmar.seVa.nombre}» pasará a «{confirmar.queda.nombre}» y la ficha de
                  «{confirmar.seVa.nombre}» dejará de existir. Su nombre queda como otra forma de escribirlo.
                </Alerta>
                <div className="fila">
                  <button type="button" className="btn-primario" disabled={ocupado} onClick={unir}>
                    {ocupado ? 'Uniendo…' : 'Unir'}
                  </button>
                  <button type="button" disabled={ocupado} onClick={() => setConfirmar(null)}>No unir</button>
                </div>
              </>
            ) : (
              <div className="fila">
                <button type="button" disabled={ocupado} onClick={() => setConfirmar({ queda: a, seVa: b })}>
                  Sí, quedarse con «{a.nombre}»
                </button>
                <button type="button" disabled={ocupado} onClick={() => setConfirmar({ queda: b, seVa: a })}>
                  Sí, quedarse con «{b.nombre}»
                </button>
                <button type="button" disabled={ocupado} onClick={() => distintos(a, b)}>No, son distintos</button>
              </div>
            )}
          </div>
        )
      })}
    </section>
  )
}

function Seccion({ titulo, vacio, children, cuantos }) {
  return (
    <section className="tarjeta">
      <h3 style={{ marginTop: 0 }}>{titulo}{cuantos != null ? ` (${cuantos})` : ''}</h3>
      {cuantos === 0 ? <p style={{ margin: 0 }}>{vacio}</p> : children}
    </section>
  )
}

function Carpeta({ id, onVolver, onCambio, onAviso }) {
  const [datos, setDatos] = useState(null)
  const [vuelta, setVuelta] = useState(0)
  const [editando, setEditando] = useState(false)
  const hoy = hoyLocal()

  useEffect(() => {
    let vivo = true
    cargarCarpeta(id).then(r => { if (vivo) setDatos(r) })
    return () => { vivo = false }
  }, [id, vuelta])

  if (!datos) return <p>Cargando…</p>
  if (datos.error) {
    return (
      <>
        <button type="button" onClick={onVolver}>← Todos los proveedores</button>
        <Alerta tipo="error">{datos.error}</Alerta>
      </>
    )
  }
  const c = datos.data
  const p = c.proveedor
  const r = c.resumen || {}

  return (
    <>
      <button type="button" onClick={onVolver}>← Todos los proveedores</button>
      <section className="tarjeta" style={{ marginTop: 12 }}>
        {editando ? (
          <FormProveedor id={p.id} inicial={aFormulario(p)}
            onGuardado={() => { setEditando(false); setVuelta(v => v + 1); onCambio(); onAviso('Proveedor guardado.') }}
            onCancelar={() => setEditando(false)} />
        ) : (
          <>
            <h2 style={{ marginTop: 0 }}>{p.nombre}</h2>
            <div>
              {p.clave && <span className="etiqueta">Lista de precios sincronizada</span>}
              {!p.activo && <span className="etiqueta etiqueta-aviso">Inactivo</span>}
            </div>
            <p style={{ marginBottom: 4 }}>{p.rfc ? `RFC ${p.rfc}` : 'Sin RFC: captúralo para reconocer sus facturas por RFC.'}</p>
            {(p.contacto || p.telefono || p.email) && (
              <p className="renglon-datos" style={{ margin: '4px 0' }}>
                {[p.contacto, p.telefono, p.email].filter(Boolean).join(' · ')}
              </p>
            )}
            {p.alias?.length > 0 && <p className="ayuda">También aparece como: {p.alias.join(', ')}</p>}
            {p.notas && <p className="ayuda">{p.notas}</p>}
            <button type="button" onClick={() => setEditando(true)}>Editar datos</button>
          </>
        )}
      </section>

      <div className="kpis">
        <div className="kpi kpi-principal">
          <span className="kpi-nombre">Le debes</span>
          <span className="kpi-valor">{pesosRedondos(r.por_pagar)}</span>
          <span className="kpi-nota">{Number(r.vencido) > 0 ? `${pesosRedondos(r.vencido)} vencido` : 'Nada vencido'}</span>
        </div>
        <div className="kpi">
          <span className="kpi-nombre">Pagado en 12 meses</span>
          <span className="kpi-valor">{pesosRedondos(r.pagado_12m)}</span>
        </div>
        <div className="kpi">
          <span className="kpi-nombre">Comprado en 12 meses</span>
          <span className="kpi-valor">{pesosRedondos(r.comprado_12m)}</span>
          <span className="kpi-nota">{r.compras || 0} {r.compras === 1 ? 'compra' : 'compras'}</span>
        </div>
        <div className="kpi">
          <span className="kpi-nombre">Pedidos abiertos</span>
          <span className="kpi-valor">{r.pedidos_abiertos || 0}</span>
        </div>
      </div>

      <Seccion titulo="Facturas" cuantos={c.facturas.length} vacio="Todavía no hay facturas de este proveedor.">
        {c.facturas.map(f => {
          const e = estadoFactura(f, hoy)
          return (
            <div key={f.id} className="renglon">
              <div>
                <div className="renglon-titulo">Factura {[f.serie, f.folio].filter(Boolean).join(' ') || 'sin folio'}</div>
                <div className="renglon-datos">
                  {fechaLegible(f.fecha)} · total {pesos(f.total)}{f.moneda && f.moneda !== 'MXN' ? ` ${f.moneda}` : ''}
                  {f.por_pagar && Number(f.saldo) > 0.01 && ` · saldo ${pesos(f.saldo)}`}
                </div>
              </div>
              <div className="renglon-lado"><span className={e.clase}><strong>{e.etiqueta}</strong></span></div>
            </div>
          )
        })}
      </Seccion>

      <Seccion titulo="Pagos" cuantos={c.pagos.length} vacio="Todavía no hay pagos registrados a este proveedor.">
        {c.pagos.map(m => (
          <div key={m.id} className="renglon">
            <div>
              <div className="renglon-titulo">{m.concepto || etiquetaCategoria(m.categoria)}</div>
              <div className="renglon-datos">
                {[fechaLegible(m.fecha), m.concepto && etiquetaCategoria(m.categoria), m.factura && `factura ${m.factura}`,
                  m.referencia && `ref. ${m.referencia}`].filter(Boolean).join(' · ')}
              </div>
            </div>
            <div className="renglon-lado"><span className="monto monto-salida">{pesos(m.monto)}</span></div>
          </div>
        ))}
      </Seccion>

      <Seccion titulo="Compras" cuantos={c.compras.length} vacio="Todavía no hay compras registradas con este proveedor.">
        {c.compras.map(x => (
          <div key={x.id} className="renglon">
            <div>
              <div className="renglon-titulo">Compra {x.folio}{x.factura ? ` · factura ${x.factura}` : ''}</div>
              <div className="renglon-datos">
                {fechaLegible(x.fecha)}{x.proveedor_texto && x.proveedor_texto !== p.nombre ? ` · capturada como «${x.proveedor_texto}»` : ''}
              </div>
            </div>
            <div className="renglon-lado">
              <span className="monto">{pesos(x.total)}</span>
              {x.estado === 'cancelada' && <span className="estado-cancelada"><strong>Cancelada</strong></span>}
            </div>
          </div>
        ))}
      </Seccion>

      <Seccion titulo="Pedidos" cuantos={c.pedidos.length} vacio="No hay pedidos abiertos ni recientes con este proveedor.">
        {c.pedidos.map(x => (
          <div key={x.id} className="renglon">
            <div>
              <div className="renglon-titulo">{x.cantidad} × {x.producto}</div>
              <div className="renglon-datos">
                {[`REQ-${x.folio}`, x.sku, x.referencia && `ref. ${x.referencia}`,
                  x.fecha_pedido && `pedido el ${fechaLegible(x.fecha_pedido)}`].filter(Boolean).join(' · ')}
              </div>
            </div>
            <div className="renglon-lado"><span className={`estado-${x.estado}`}><strong>{ESTADO_PEDIDO[x.estado] || x.estado}</strong></span></div>
          </div>
        ))}
      </Seccion>

      <Seccion titulo="Piezas que le compras" cuantos={r.productos ?? c.productos.length}
        vacio="Ninguna pieza del catálogo está ligada a este proveedor.">
        {Number(r.productos) > c.productos.length && (
          <p className="ayuda">Se muestran {c.productos.length} de {r.productos}. Las demás están en Inventario.</p>
        )}
        {c.productos.map(x => (
          <div key={x.id} className="renglon">
            <div>
              <div className="renglon-titulo">{x.nombre}</div>
              <div className="renglon-datos">
                {x.sku}{x.codigo && x.codigo !== x.sku ? ` · su código ${x.codigo}` : ''}
                {x.opcion === 1 && ' · se le compra a él (opción 1)'}
              </div>
            </div>
            {x.costo != null && <div className="renglon-lado"><span className="monto">{pesos(x.costo)}</span></div>}
          </div>
        ))}
      </Seccion>
    </>
  )
}

export default function Proveedores() {
  const [datos, setDatos] = useState(null)
  const [vuelta, setVuelta] = useState(0)
  const [busqueda, setBusqueda] = useState('')
  const [abierto, setAbierto] = useState(null)   // id del proveedor cuya carpeta se ve
  const [alta, setAlta] = useState(false)
  const [mensaje, setMensaje] = useState('')

  useEffect(() => {
    let vivo = true
    leerTodo().then(d => { if (vivo) setDatos(d) })
    return () => { vivo = false }
  }, [vuelta])

  const recargar = () => setVuelta(v => v + 1)
  const avisar = texto => { setMensaje(texto); window.scrollTo?.({ top: 0, behavior: 'smooth' }) }
  const lista = useMemo(() => filtrarProveedores(datos?.lista || [], busqueda), [datos, busqueda])

  if (abierto) {
    return (
      <div className="pagina pagina-angosta">
        {mensaje && <Alerta tipo="ok">{mensaje}</Alerta>}
        <Carpeta id={abierto} onVolver={() => { setAbierto(null); setMensaje('') }} onCambio={recargar} onAviso={avisar} />
      </div>
    )
  }

  return (
    <div className="pagina pagina-angosta">
      <h2>Proveedores</h2>
      <p className="ayuda">
        Cada proveedor con sus facturas, pagos, compras y pedidos. Se dan de alta solos cuando entra una
        compra o una factura con un nombre nuevo.
      </p>
      {datos?.error && <Alerta tipo="error">{datos.error}</Alerta>}
      {mensaje && <Alerta tipo="ok">{mensaje}</Alerta>}

      <details className="tarjeta" open={alta} onToggle={e => setAlta(e.currentTarget.open)}>
        <summary className="resumen">Agregar un proveedor</summary>
        {alta && (
          <FormProveedor
            onGuardado={(id, nombre) => { setAlta(false); recargar(); avisar(`«${nombre}» agregado.`) }}
            onCancelar={() => setAlta(false)} />
        )}
      </details>

      {datos && (
        <Parecidos pares={datos.parecidos} onCambio={recargar} onAviso={avisar} />
      )}

      <div className="buscador">
        <input type="search" value={busqueda} onChange={e => setBusqueda(e.target.value)}
          placeholder="Buscar por nombre o RFC" aria-label="Buscar proveedor" />
      </div>

      {!datos && <p>Cargando…</p>}
      {datos && lista.length === 0 && (
        <div className="tarjeta"><p style={{ margin: 0 }}>
          {busqueda ? 'Ningún proveedor coincide con la búsqueda.' : 'Todavía no hay proveedores.'}
        </p></div>
      )}
      {lista.map(p => {
        const r = p.resumen || {}
        return (
          <button key={p.id} type="button" className="orden-item" onClick={() => { setAbierto(p.id); setMensaje('') }}>
            <strong>{p.nombre}</strong>
            <span className="renglon-datos">
              {p.rfc ? `RFC ${p.rfc}` : 'Sin RFC'} · {resumenLinea(r)}
            </span>
            <span>
              {Number(r.por_pagar) > 0
                ? <>Le debes <strong>{pesos(r.por_pagar)}</strong>{Number(r.vencido) > 0 && <span className="estado-error"> · <strong>{pesos(r.vencido)} vencido</strong></span>}</>
                : 'No le debes nada'}
            </span>
            <span>
              {p.clave && <span className="etiqueta">Lista sincronizada</span>}
              {!p.activo && <span className="etiqueta etiqueta-aviso">Inactivo</span>}
            </span>
          </button>
        )
      })}
    </div>
  )
}
