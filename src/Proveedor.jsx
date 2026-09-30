import { useCallback, useEffect, useMemo, useState } from 'react'
import { Alerta } from './ui'
import {
  ETIQUETA_TIPO, esAprobable, ordenarCola, contarPorTipo, detalleDeCambio, explicacion,
  CATEGORIAS, alcanceDeRegla, textoDeRegla, ordenarReglas, reglaVacia, validarRegla,
  estadoDeVinculo, ETIQUETA_VINCULO, filtrarProductos, textoDeCorrida, pesos,
  cargarCola, resolverRevision, resolverEnLote, cargarUltimaCorrida, cargarReglas, guardarRegla,
  cambiarActivaRegla, cargarProductosYCostos, buscarEnProveedor, vincularProducto,
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
    const r = await cargarProductosYCostos()
    if (r.ok) { setDatos(r); setError('') } else setError(r.texto)
  }, [])
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    cargar()
  }, [cargar])

  const visibles = useMemo(
    () => filtrarProductos(datos?.productos, texto, soloSin),
    [datos, texto, soloSin])
  const vinculados = (datos?.productos || []).filter(p => p.proveedor_sku).length

  return (
    <>
      <p className="ayuda">
        Un producto solo sigue al proveedor si lo vinculas aquí. Vincular no cambia ningún precio:
        el precio cambia hasta que activas el precio automático.
      </p>
      {error && <Alerta tipo="error">{error}</Alerta>}
      {datos === null && !error && <p>Cargando…</p>}

      {datos && (
        <>
          <p className="ayuda">{vinculados} de {datos.productos.length} productos vinculados.</p>
          <label className="campo">
            <span>Buscar producto del CRM</span>
            <input value={texto} onChange={e => setTexto(e.target.value)} placeholder="SKU, nombre, marca o modelo" />
          </label>
          <label className="casilla">
            <input type="checkbox" checked={soloSin} onChange={e => setSoloSin(e.target.checked)} />
            Mostrar solo los que no están vinculados
          </label>
          {visibles.length === 0 && <p className="ayuda">No hay productos con ese filtro.</p>}
          {visibles.slice(0, 60).map(p => (
            <FilaProducto key={p.id} p={p} lectura={datos.lecturas[p.proveedor_sku]} onCambio={cargar} />
          ))}
          {visibles.length > 60 && (
            <p className="ayuda">Se muestran 60 de {visibles.length}. Escribe en el buscador para acotar.</p>
          )}
        </>
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

export default function Proveedor() {
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
        <button className="pestana" aria-pressed={vista === 'vinculos'} onClick={() => setVista('vinculos')}>Vínculos</button>
        <button className="pestana" aria-pressed={vista === 'reglas'} onClick={() => setVista('reglas')}>Reglas de margen</button>
      </div>

      {vista === 'cola' && <PestanaCola irAReglas={() => setVista('reglas')} />}
      {vista === 'vinculos' && <PestanaVinculos />}
      {vista === 'reglas' && <PestanaReglas />}
    </div>
  )
}
