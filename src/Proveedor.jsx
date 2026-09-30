import { useCallback, useEffect, useMemo, useState } from 'react'
import { Alerta } from './ui'
import {
  ETIQUETA_TIPO, esAprobable, ordenarCola, contarPorTipo, detalleDeCambio, explicacion,
  CATEGORIAS, alcanceDeRegla, textoDeRegla, ordenarReglas, reglaVacia, validarRegla,
  estadoDeVinculo, ETIQUETA_VINCULO, textoDeCorrida, pesos, totalPorTraer, nombreCategoriaCRM, faltanConPrecioAuto,
  cargarCola, resolverRevision, resolverEnLote, cargarUltimaCorrida, cargarReglas, guardarRegla,
  cambiarActivaRegla, buscarProductosCRM, buscarEnProveedor, vincularProducto,
  cargarResumenProveedor, importarProductos, activarPrecioAutomatico,
} from './lib/proveedor'

// Precios del proveedor (XLStore). Aquí no se calcula ningún precio: lo calcula la base al
// sincronizar (SQL 44). Esta pantalla decide qué se publica (la cola), qué productos siguen al
// proveedor (los vínculos) y con qué margen (las reglas).

// ---------------------------------------------------------------------------
// Cola: lo que el sync no quiso publicar solo. Componente de nivel superior para que la nota
// no pierda el foco al escribir.
// ---------------------------------------------------------------------------
function TarjetaRevision({ q, irAReglas, onCambio }) {
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')
  const nombre = q.detalle?.nombre || q.productos?.nombre || q.proveedor_sku
  const filas = detalleDeCambio(q)

  async function resolver(aprobar) {
    setOcupado(true); setError('')
    const r = await resolverRevision(q.id, aprobar)
    setOcupado(false)
    if (!r.ok) { setError(r.texto); return }
    onCambio()
  }

  return (
    <section className="tarjeta">
      <h3 style={{ marginBottom: 2 }}>{nombre}</h3>
      <p className="ayuda" style={{ marginTop: 0 }}>
        {q.productos?.sku && <>{q.productos.sku} · </>}código del proveedor {q.proveedor_sku}
      </p>
      <span className={q.tipo === 'cambio_precio' || q.tipo === 'sku_desaparecido' ? 'etiqueta etiqueta-aviso' : 'etiqueta'}>
        {ETIQUETA_TIPO[q.tipo] || q.tipo}
      </span>

      {filas.length > 0 && (
        <dl style={{ display: 'grid', gap: 4, margin: '10px 0 0' }}>
          {filas.map(f => (
            <div key={f.etiqueta} style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              <dt className="ayuda" style={{ margin: 0 }}>{f.etiqueta}:</dt>
              <dd style={{ margin: 0, fontWeight: 700 }}>{f.valor}</dd>
            </div>
          ))}
        </dl>
      )}
      <p className="ayuda">{explicacion(q.tipo)}</p>

      {error && <Alerta tipo="error">{error}</Alerta>}

      <div className="fila" style={{ flexWrap: 'wrap', gap: 8 }}>
        {esAprobable(q.tipo) ? (
          // Retirar un producto del sitio es lo menos reversible de la cola: no se pinta como el
          // botón principal.
          <button className={q.tipo === 'sku_desaparecido' ? 'btn-peligro' : 'btn-primario'}
            disabled={ocupado} onClick={() => resolver(true)}>
            {q.tipo === 'sku_desaparecido' ? 'Retirar del sitio' : 'Aprobar precio'}
          </button>
        ) : (
          q.tipo === 'sin_regla' && <button onClick={irAReglas}>Ir a reglas de margen</button>
        )}
        <button disabled={ocupado} onClick={() => resolver(false)}>
          {esAprobable(q.tipo) ? 'Descartar' : 'Ya lo vi'}
        </button>
      </div>
    </section>
  )
}

function PestanaCola({ irAReglas }) {
  const [cola, setCola] = useState(null)
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState('')
  const [confirmando, setConfirmando] = useState(false)
  const [ocupado, setOcupado] = useState(false)

  const cargar = useCallback(async () => {
    const r = await cargarCola()
    if (r.ok) { setCola(r.datos); setError('') } else setError(r.texto)
  }, [])
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    cargar()
  }, [cargar])

  async function aprobarIniciales() {
    setOcupado(true); setError(''); setMensaje('')
    const r = await resolverEnLote('precio_inicial', true)
    setOcupado(false); setConfirmando(false)
    if (!r.ok) { setError(r.texto); return }
    const { resueltas, fallidas } = r.datos
    setMensaje(`${resueltas} precio${resueltas === 1 ? '' : 's'} publicado${resueltas === 1 ? '' : 's'}` +
      (fallidas ? `; ${fallidas} no se pudieron aprobar (revisa cada una)` : '') + '.')
    cargar()
  }

  const ordenada = useMemo(() => ordenarCola(cola), [cola])
  const cuenta = contarPorTipo(cola)
  const iniciales = cuenta.precio_inicial || 0

  return (
    <>
      {error && <Alerta tipo="error">{error}</Alerta>}
      {mensaje && <Alerta tipo="ok">{mensaje}</Alerta>}
      {cola === null && !error && <p>Cargando…</p>}

      {cola && cola.length === 0 && (
        <section className="tarjeta">
          <h3>No hay nada por aprobar</h3>
          <p className="ayuda">
            Cuando una sincronización encuentre un cambio fuerte de precio, un producto nuevo o uno
            que el proveedor dejó de listar, aparecerá aquí en lugar de publicarse solo.
          </p>
        </section>
      )}

      {iniciales > 1 && (
        <section className="tarjeta">
          <h3>{iniciales} productos esperan su primer precio</h3>
          {!confirmando ? (
            <button className="btn-primario" onClick={() => setConfirmando(true)}>
              Aprobar todos los primeros precios
            </button>
          ) : (
            <>
              <Alerta tipo="aviso" palabra="Confirma">
                Se van a publicar {iniciales} precios con el margen de tus reglas. Revisa antes que
                los márgenes estén bien capturados.
              </Alerta>
              <div className="fila" style={{ gap: 8 }}>
                <button className="btn-primario" disabled={ocupado} onClick={aprobarIniciales}>
                  Sí, publicar los {iniciales}
                </button>
                <button disabled={ocupado} onClick={() => setConfirmando(false)}>No</button>
              </div>
            </>
          )}
        </section>
      )}

      {ordenada.map(q => (
        <TarjetaRevision key={q.id} q={q} irAReglas={irAReglas} onCambio={cargar} />
      ))}
    </>
  )
}

// ---------------------------------------------------------------------------
// Vínculos: qué producto del CRM sigue a cuál del proveedor.
// ---------------------------------------------------------------------------
function FilaProducto({ p, lectura, onCambio }) {
  const [buscando, setBuscando] = useState(false)
  const [texto, setTexto] = useState(p.modelo || p.sku)
  const [resultados, setResultados] = useState([])
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')
  const estado = estadoDeVinculo(p)

  async function buscar(t) {
    setTexto(t)
    if (t.trim().length < 2) { setResultados([]); return }
    const r = await buscarEnProveedor(t)
    if (r.ok) { setResultados(r.datos); setError('') } else setError(r.texto)
  }

  async function guardar(sku, auto) {
    setOcupado(true); setError('')
    const r = await vincularProducto(p.id, sku, auto)
    setOcupado(false)
    if (!r.ok) { setError(r.texto); return }
    setBuscando(false)
    onCambio()
  }

  return (
    <section className="tarjeta">
      <strong>{p.sku} — {p.nombre}</strong>
      <div className="ayuda" style={{ marginTop: 2 }}>
        {[p.marca, p.modelo].filter(Boolean).join(' · ')}
        {p.precio > 0 && <> · precio {pesos(p.precio)}</>}
      </div>
      <span className={estado === 'automatico' ? 'etiqueta' : 'etiqueta etiqueta-aviso'}>{ETIQUETA_VINCULO[estado]}</span>

      {p.proveedor_sku && (
        <p className="ayuda">
          Sigue a <strong>{p.proveedor_sku}</strong>
          {lectura
            ? <> · costo {lectura.costo == null ? 'sin dato' : `${lectura.costo} ${lectura.moneda}`}
              {lectura.stock_local != null && <> · {lectura.stock_local} en Mérida</>}
              {!lectura.vigente && <> · <strong>el proveedor ya no lo lista</strong></>}</>
            : ' · sin lectura del proveedor'}
        </p>
      )}

      {error && <Alerta tipo="error">{error}</Alerta>}

      <div className="fila" style={{ flexWrap: 'wrap', gap: 8 }}>
        {estado === 'sin_vincular' && (
          <button disabled={ocupado} onClick={() => { setBuscando(v => !v); if (!buscando) buscar(texto) }}>
            {buscando ? 'Cerrar búsqueda' : 'Vincular con el proveedor'}
          </button>
        )}
        {estado === 'vinculado' && (
          <button className="btn-primario" disabled={ocupado} onClick={() => guardar(p.proveedor_sku, true)}>
            Activar precio automático
          </button>
        )}
        {estado === 'automatico' && (
          <button disabled={ocupado} onClick={() => guardar(p.proveedor_sku, false)}>
            Pasar a precio manual
          </button>
        )}
        {estado !== 'sin_vincular' && (
          <button disabled={ocupado} onClick={() => guardar(null, false)}>Quitar vínculo</button>
        )}
      </div>
      {estado === 'vinculado' && (
        <p className="ayuda">
          Con el precio automático, el primer precio pasa por la cola para que lo apruebes; después,
          los cambios chicos se aplican solos.
        </p>
      )}

      {buscando && (
        <div className="buscador" style={{ marginTop: 10 }}>
          <input
            placeholder="Buscar en el proveedor por código, modelo o nombre"
            aria-label="Buscar en el proveedor"
            value={texto} onChange={e => buscar(e.target.value)} />
          {resultados.length > 0 && (
            <div className="buscador-lista">
              {resultados.map(r => (
                <button key={r.sku_proveedor} type="button" disabled={ocupado}
                  onClick={() => guardar(r.sku_proveedor, false)}>
                  {r.sku_proveedor} — {r.marca} {r.modelo}
                  <span className="ayuda">
                    {r.nombre} · {r.costo == null ? 'sin costo' : `${r.costo} ${r.moneda}`}
                  </span>
                </button>
              ))}
            </div>
          )}
          {texto.trim().length >= 2 && resultados.length === 0 && (
            <p className="ayuda">Nada coincide. Prueba con el modelo o un pedazo del nombre.</p>
          )}
        </div>
      )}
    </section>
  )
}

function PestanaVinculos() {
  const [datos, setDatos] = useState(null)
  const [error, setError] = useState('')
  const [texto, setTexto] = useState('')
  const [soloSin, setSoloSin] = useState(true)

  const cargar = useCallback(async () => {
    const r = await buscarProductosCRM({ texto, soloSin })
    if (r.ok) { setDatos(r); setError('') } else setError(r.texto)
  }, [texto, soloSin])

  // Se busca en el servidor (el catálogo pasa de mil productos); una pausa corta al escribir
  // evita una consulta por letra.
  useEffect(() => {
    const espera = setTimeout(cargar, texto ? 300 : 0)
    return () => clearTimeout(espera)
  }, [cargar, texto])

  return (
    <>
      <p className="ayuda">
        Un producto solo sigue al proveedor si está vinculado. Vincular no cambia ningún precio: el
        precio cambia hasta que activas el precio automático. Los productos que trajiste del
        proveedor ya vienen vinculados; aquí se liga uno que ya tenías de antes.
      </p>
      {error && <Alerta tipo="error">{error}</Alerta>}
      {datos === null && !error && <p>Cargando…</p>}

      <label className="campo">
        <span>Buscar producto del CRM</span>
        <input value={texto} onChange={e => setTexto(e.target.value)} placeholder="SKU, nombre, marca o modelo" />
      </label>
      <label className="casilla">
        <input type="checkbox" checked={soloSin} onChange={e => setSoloSin(e.target.checked)} />
        Mostrar solo los que no están vinculados
      </label>

      {datos && (
        <>
          {datos.productos.length === 0 && <p className="ayuda">No hay productos con ese filtro.</p>}
          {datos.productos.map(p => (
            <FilaProducto key={p.id} p={p} lectura={datos.lecturas[p.proveedor_sku]} onCambio={cargar} />
          ))}
          {datos.total > datos.productos.length && (
            <p className="ayuda">
              Se muestran {datos.productos.length} de {datos.total}. Escribe en el buscador para acotar.
            </p>
          )}
        </>
      )}
    </>
  )
}

// ---------------------------------------------------------------------------
// Traer productos: crear en el CRM lo que el proveedor tiene y aquí todavía no. Entran sin
// publicar y sin precio, ya vinculados; se publican cuando su precio se aprueba.
// ---------------------------------------------------------------------------
function PestanaTraer({ irA }) {
  const [resumen, setResumen] = useState(null)
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState('')
  const [marcadas, setMarcadas] = useState(null)   // null = todavía no se eligió: se marca todo lo que se puede
  const [confirmando, setConfirmando] = useState(false)
  const [ocupado, setOcupado] = useState(false)

  const cargar = useCallback(async () => {
    const r = await cargarResumenProveedor()
    if (r.ok) { setResumen(r.datos); setError('') } else setError(r.texto)
  }, [])
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    cargar()
  }, [cargar])

  const porTraer = resumen?.por_traer || []
  const vinculados = resumen?.vinculados || []
  const elegidas = marcadas ?? porTraer.filter(c => c.equivale && c.por_traer > 0).map(c => c.categoria)
  const total = totalPorTraer(porTraer, elegidas)

  function alternar(categoria) {
    setConfirmando(false)
    setMarcadas(elegidas.includes(categoria) ? elegidas.filter(c => c !== categoria) : [...elegidas, categoria])
  }

  async function traer() {
    setOcupado(true); setError(''); setMensaje('')
    const r = await importarProductos(elegidas)
    setOcupado(false); setConfirmando(false)
    if (!r.ok) { setError(r.texto); return }
    const d = r.datos
    setMensaje(`Se crearon ${d.creados} producto${d.creados === 1 ? '' : 's'}` +
      (d.ya_existian ? `; ${d.ya_existian} ya existían` : '') + '. Están sin publicar y sin precio.')
    setMarcadas(null); cargar()
  }

  async function activar(categoria) {
    setOcupado(true); setError(''); setMensaje('')
    const r = await activarPrecioAutomatico(categoria)
    setOcupado(false)
    if (!r.ok) { setError(r.texto); return }
    setMensaje(`Precio automático activado en ${r.datos} producto${r.datos === 1 ? '' : 's'} de ${nombreCategoriaCRM(categoria).toLowerCase()}. ` +
      'Su primer precio aparece en "Por aprobar" la próxima vez que sincronices.')
    cargar()
  }

  return (
    <>
      <p className="ayuda">
        Lo que el proveedor tiene y todavía no está en tu catálogo. Al traerlo, el producto queda en
        Inventario con el código de XLStore, sin precio y <strong>sin publicar</strong>.
      </p>
      {error && <Alerta tipo="error">{error}</Alerta>}
      {mensaje && <Alerta tipo="ok">{mensaje}</Alerta>}
      {resumen === null && !error && <p>Cargando…</p>}

      {resumen && porTraer.length === 0 && (
        <Alerta tipo="info">
          Todavía no hay una lectura del proveedor. Corre la sincronización con tu archivo primero.
        </Alerta>
      )}

      {porTraer.length > 0 && (
        <section className="tarjeta">
          <h3>Productos por traer</h3>
          {porTraer.map(c => (
            <label key={c.categoria} className="casilla">
              <input type="checkbox" disabled={!c.equivale || c.por_traer === 0}
                checked={elegidas.includes(c.categoria) && c.equivale && c.por_traer > 0}
                onChange={() => alternar(c.categoria)} />
              <span>
                {c.categoria}: <strong>{c.por_traer}</strong> por traer de {c.total}
                {!c.equivale && ' · sin categoría equivalente en el CRM'}
                {c.equivale && c.por_traer === 0 && ' · ya están todos'}
              </span>
            </label>
          ))}

          {!confirmando ? (
            <button className="btn-primario" disabled={total === 0 || ocupado} onClick={() => setConfirmando(true)}>
              {total === 0 ? 'Nada por traer' : `Traer ${total} producto${total === 1 ? '' : 's'}`}
            </button>
          ) : (
            <>
              <Alerta tipo="aviso" palabra="Confirma">
                Se van a crear {total} productos en el catálogo. No se publican: siguen fuera del sitio
                hasta que tengan precio.
              </Alerta>
              <div className="fila" style={{ gap: 8 }}>
                <button className="btn-primario" disabled={ocupado} onClick={traer}>Sí, traer los {total}</button>
                <button disabled={ocupado} onClick={() => setConfirmando(false)}>No</button>
              </div>
            </>
          )}
        </section>
      )}

      {vinculados.length > 0 && (
        <section className="tarjeta">
          <h3>Precio automático</h3>
          <p className="ayuda">
            Con el precio automático, el sync calcula el precio con tus reglas de margen. Activarlo no
            publica nada: el primer precio de cada producto pasa por &quot;Por aprobar&quot;. Captura antes
            las reglas de margen, o quedarán como &quot;falta regla&quot;.
          </p>
          {vinculados.map(c => (
            <div key={c.categoria} className="fila" style={{ justifyContent: 'space-between', flexWrap: 'wrap', gap: 8, marginBottom: 8 }}>
              <span>
                <strong>{nombreCategoriaCRM(c.categoria)}</strong>: {c.total} vinculados, {c.con_auto} con precio automático
              </span>
              {faltanConPrecioAuto(c) > 0 ? (
                <button disabled={ocupado} onClick={() => activar(c.categoria)}>
                  Activar en los {faltanConPrecioAuto(c)}
                </button>
              ) : (
                <span className="etiqueta">Todos activados</span>
              )}
            </div>
          ))}
          {irA && <button onClick={() => irA('inventario')}>Ver el inventario</button>}
        </section>
      )}
    </>
  )
}

// ---------------------------------------------------------------------------
// Reglas de margen. Sin regla, el sync no calcula precio (queda en la cola como "falta regla").
// ---------------------------------------------------------------------------
function PestanaReglas() {
  const [reglas, setReglas] = useState(null)
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState('')
  const [editando, setEditando] = useState(null)   // null = cerrado, 'nueva' o el id
  const [form, setForm] = useState(reglaVacia)
  const [ocupado, setOcupado] = useState(false)

  const cargar = useCallback(async () => {
    const r = await cargarReglas()
    if (r.ok) { setReglas(r.datos); setError('') } else setError(r.texto)
  }, [])
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    cargar()
  }, [cargar])

  function abrir(r) {
    setMensaje(''); setError('')
    if (r) {
      setForm({
        categoria: r.categoria || '', marca: r.marca || '', margen_pct: String(r.margen_pct),
        margen_minimo_mxn: String(r.margen_minimo_mxn), redondeo: String(r.redondeo),
      })
      setEditando(r.id)
    } else {
      setForm(reglaVacia); setEditando('nueva')
    }
  }

  async function guardar(e) {
    e.preventDefault()
    const v = validarRegla(form)
    if (!v.ok) { setError(v.errores.join(' ')); return }
    setOcupado(true); setError('')
    const r = await guardarRegla(editando === 'nueva' ? null : editando, v.regla)
    setOcupado(false)
    if (!r.ok) { setError(r.texto); return }
    setMensaje('Regla guardada. Se usa en la próxima sincronización.')
    setEditando(null); cargar()
  }

  async function alternar(r) {
    setError(''); setMensaje('')
    const res = await cambiarActivaRegla(r.id, !r.activo)
    if (!res.ok) { setError(res.texto); return }
    cargar()
  }

  const campo = (nombre, valor) => setForm(f => ({ ...f, [nombre]: valor }))
  const hayGeneral = (reglas || []).some(r => r.activo && !r.categoria && !r.marca)

  return (
    <>
      <p className="ayuda">
        Precio = el mayor entre costo + margen % y costo + margen mínimo, redondeado hacia arriba.
        Si varias reglas le tocan a un producto, gana la más específica (marca y categoría, luego
        marca, luego categoría, luego la general).
      </p>
      {error && <Alerta tipo="error">{error}</Alerta>}
      {mensaje && <Alerta tipo="ok">{mensaje}</Alerta>}
      {reglas && !hayGeneral && (
        <Alerta tipo="aviso" palabra="Falta la general">
          No hay una regla general activa: los productos sin regla propia no tendrán precio.
        </Alerta>
      )}
      {reglas === null && !error && <p>Cargando…</p>}

      {editando === null ? (
        <button className="btn-primario" onClick={() => abrir(null)} style={{ marginBottom: 12 }}>
          Nueva regla
        </button>
      ) : (
        <form className="tarjeta" onSubmit={guardar}>
          <h3>{editando === 'nueva' ? 'Nueva regla' : 'Editar regla'}</h3>
          <div className="rejilla-2">
            <label className="campo">
              <span>Categoría</span>
              <select value={form.categoria} onChange={e => campo('categoria', e.target.value)}>
                <option value="">Todas</option>
                {CATEGORIAS.map(([k, n]) => <option key={k} value={k}>{n}</option>)}
              </select>
            </label>
            <label className="campo">
              <span>Marca (vacía = todas)</span>
              <input value={form.marca} onChange={e => campo('marca', e.target.value)} placeholder="JA SOLAR" />
            </label>
            <label className="campo">
              <span>Margen (%)</span>
              <input type="number" min="0" step="any" inputMode="decimal" value={form.margen_pct}
                onChange={e => campo('margen_pct', e.target.value)} required />
            </label>
            <label className="campo">
              <span>Margen mínimo (pesos)</span>
              <input type="number" min="0" step="any" inputMode="decimal" value={form.margen_minimo_mxn}
                onChange={e => campo('margen_minimo_mxn', e.target.value)} />
            </label>
            <label className="campo">
              <span>Redondear hacia arriba a (pesos)</span>
              <input type="number" min="0" step="any" inputMode="decimal" value={form.redondeo}
                onChange={e => campo('redondeo', e.target.value)} required />
            </label>
          </div>
          <div className="fila" style={{ gap: 8 }}>
            <button className="btn-primario" type="submit" disabled={ocupado}>Guardar regla</button>
            <button type="button" onClick={() => setEditando(null)}>Cancelar</button>
          </div>
        </form>
      )}

      {ordenarReglas(reglas).map(r => (
        <section key={r.id} className="tarjeta" style={r.activo ? undefined : { opacity: 0.85 }}>
          <strong>{alcanceDeRegla(r)}</strong>
          {!r.activo && <span className="etiqueta etiqueta-aviso">Apagada</span>}
          <p className="ayuda" style={{ margin: '4px 0 8px' }}>{textoDeRegla(r)}</p>
          <div className="fila" style={{ gap: 8, flexWrap: 'wrap' }}>
            <button onClick={() => abrir(r)}>Editar</button>
            <button onClick={() => alternar(r)}>{r.activo ? 'Apagar' : 'Volver a encender'}</button>
          </div>
        </section>
      ))}
      {reglas && reglas.length === 0 && (
        <p className="ayuda">Todavía no hay reglas. Empieza por una general (categoría y marca vacías).</p>
      )}
    </>
  )
}

// ---------------------------------------------------------------------------

export default function Proveedor({ irA }) {
  const [vista, setVista] = useState('cola')
  const [corrida, setCorrida] = useState(undefined)   // undefined = cargando, null = ninguna
  const [pendientes, setPendientes] = useState(null)

  useEffect(() => {
    let vivo = true
    ;(async () => {
      const [c, q] = await Promise.all([cargarUltimaCorrida(), cargarCola()])
      if (!vivo) return
      setCorrida(c.ok ? (c.datos[0] || null) : null)
      setPendientes(q.ok ? q.datos.length : null)
    })()
    return () => { vivo = false }
  }, [vista])

  const estado = textoDeCorrida(corrida)

  return (
    <div className="pagina-angosta">
      <h2>Precios del proveedor</h2>
      <p className="ayuda">
        XLStore (Exel Solar): qué se aprueba antes de publicarse, qué productos lo siguen y con qué
        margen.
      </p>

      {corrida === null && <Alerta tipo="info">Todavía no se ha corrido ninguna sincronización.</Alerta>}
      {estado && <Alerta tipo={estado.tipo}>{estado.texto}</Alerta>}

      <div className="pestanas">
        <button className="pestana" aria-pressed={vista === 'cola'} onClick={() => setVista('cola')}>
          Por aprobar{pendientes ? ` (${pendientes})` : ''}
        </button>
        <button className="pestana" aria-pressed={vista === 'traer'} onClick={() => setVista('traer')}>Traer productos</button>
        <button className="pestana" aria-pressed={vista === 'vinculos'} onClick={() => setVista('vinculos')}>Vínculos</button>
        <button className="pestana" aria-pressed={vista === 'reglas'} onClick={() => setVista('reglas')}>Reglas de margen</button>
      </div>

      {vista === 'cola' && <PestanaCola irAReglas={() => setVista('reglas')} />}
      {vista === 'traer' && <PestanaTraer irA={irA} />}
      {vista === 'vinculos' && <PestanaVinculos />}
      {vista === 'reglas' && <PestanaReglas />}
    </div>
  )
}
