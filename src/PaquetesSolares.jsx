import { useEffect, useState } from 'react'
import { Alerta } from './ui'
import {
  VARIANTES, RECETAS, TIPOS_COSTO, estadoDe, pesos, textoCambio, sePuedePublicar, porPublicar, tituloPaquete,
  textoRegla, cargarPaquetes, publicarPrecio, recalcularPaquetes, cargarLineas, guardarCantidad,
  quitarLineaPaquete, agregarLineaPaquete, buscarProductos, cantidadValida
} from './lib/paquetesSolares'

// ---------------------------------------------------------------------------
// Paquetes solares (SQL 78). Solo admin.
//
// Cada paquete tiene su receta (lista de materiales) en tres variantes. La BASE calcula el costo con los
// costos del catálogo y los parámetros de costeo, y el precio con la regla de margen e IVA. Aquí se ve qué
// pasaría con el precio del sitio y se publica. La primera vez de cada variante es siempre a mano; después,
// un cambio de ±15 % o menos se aplica solo en cada sincronización con el proveedor.
// ---------------------------------------------------------------------------

function Variante({ p, def, onPublicado }) {
  const v = p.variantes[def.clave]
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')
  const e = estadoDe(v.estado)

  async function publicar() {
    setError(''); setOcupado(true)
    const r = await publicarPrecio(p.paquete_id, def.clave)
    setOcupado(false)
    if (r.error) return setError(r.error)
    onPublicado(`${p.nombre} ${def.nombre.toLowerCase()}: publicado en ${pesos(r.data?.precio)}.`)
  }

  return (
    <div style={{ borderTop: '1px solid var(--linea)', paddingTop: 10, marginTop: 10 }}>
      <div className="fila" style={{ justifyContent: 'space-between', alignItems: 'baseline' }}>
        <div>
          <div className="renglon-titulo">{def.nombre}</div>
          <div className="renglon-datos">{def.detalle}</div>
        </div>
        <span className={`estado ${e.clase}`}>{e.etiqueta}</span>
      </div>
      <div className="kpis" style={{ marginTop: 8 }}>
        <div className="kpi">
          <span className="kpi-nombre">Costo</span>
          <span className="kpi-valor">{pesos(v.costo)}</span>
          <span className="kpi-nota">{v.imprevistos > 0 ? `con ${pesos(v.imprevistos)} de imprevistos` : 'sin imprevistos'}</span>
        </div>
        <div className="kpi kpi-principal">
          <span className="kpi-nombre">Precio con IVA</span>
          <span className="kpi-valor">{pesos(v.precio)}</span>
          <span className="kpi-nota">{v.alcanza == null ? 'sin dato de existencias' : `alcanza para ${v.alcanza} con lo de Mérida`}</span>
        </div>
      </div>
      {v.precio != null && <p className="ayuda" style={{ margin: '4px 0 0' }}>{textoCambio(v)}</p>}
      {v.faltan?.length > 0 && (
        <Alerta tipo="aviso">
          Sin precio hasta que se resuelva: {v.faltan.map(f => `${f.concepto}${f.sku ? ` (${f.sku})` : ''}: ${f.motivo}`).join('; ')}.
        </Alerta>
      )}
      {error && <Alerta tipo="error">{error}</Alerta>}
      {sePuedePublicar(v) && (
        <button type="button" className="btn-primario" style={{ marginTop: 8 }} disabled={ocupado} onClick={publicar}>
          {ocupado ? 'Publicando…' : `Publicar ${pesos(v.precio)}`}
        </button>
      )}
    </div>
  )
}

function LineaReceta({ l, onCambio }) {
  const [cant, setCant] = useState(String(Number(l.cantidad)))
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')
  const cambio = cant !== String(Number(l.cantidad))
  const unitario = l.producto ? Number(l.producto.costo) : null

  async function correr(fn) {
    setError(''); setOcupado(true)
    const r = await fn()
    setOcupado(false)
    if (r.error) return setError(r.error)
    onCambio()
  }

  return (
    <li style={{ borderTop: '1px solid var(--linea)', padding: '8px 0' }}>
      <div className="renglon-titulo" style={{ fontWeight: 600 }}>{l.concepto}</div>
      <div className="renglon-datos">
        {[l.producto?.sku, l.grupo, TIPOS_COSTO[l.tipo_costo] !== l.grupo && TIPOS_COSTO[l.tipo_costo],
          l.parametro && 'costo en Precios → Costeo de paquetes solares',
          unitario != null && `${pesos(unitario)} c/u`, l.producto && !l.producto.activo && 'producto desactivado']
          .filter(Boolean).join(' · ')}
      </div>
      <div className="fila" style={{ alignItems: 'flex-end', marginTop: 6 }}>
        <label className="campo" style={{ flex: '0 1 140px', marginBottom: 0 }}>
          <span>Cantidad</span>
          <input type="number" inputMode="decimal" min="0" step="any" value={cant} onChange={ev => setCant(ev.target.value)} />
        </label>
        {cambio && (
          <button type="button" className="btn-primario" disabled={ocupado || !cantidadValida(cant)}
            onClick={() => correr(() => guardarCantidad(l.id, cant))}>Guardar</button>
        )}
        <button type="button" disabled={ocupado} onClick={() => correr(() => quitarLineaPaquete(l.id))}
          aria-label={`Quitar ${l.concepto} de la receta`}>Quitar</button>
      </div>
      {error && <Alerta tipo="error">{error}</Alerta>}
    </li>
  )
}

function AgregarLinea({ paqueteId, siguiente, onCambio }) {
  const [texto, setTexto] = useState('')
  const [resultados, setResultados] = useState([])
  const [elegido, setElegido] = useState(null)
  const [variante, setVariante] = useState('interconectado')
  const [cant, setCant] = useState('1')
  const [error, setError] = useState('')
  const [ocupado, setOcupado] = useState(false)

  async function buscar() {
    setError('')
    const r = await buscarProductos(texto)
    if (r.error) return setError(r.error)
    setResultados(r.productos)
    if (r.productos.length === 0) setError('No encontré piezas activas con ese texto.')
  }
  async function agregar() {
    setError(''); setOcupado(true)
    const r = await agregarLineaPaquete({ paqueteId, variante, producto: elegido, cantidad: cant, orden: siguiente })
    setOcupado(false)
    if (r.error) return setError(r.error)
    setElegido(null); setResultados([]); setTexto(''); setCant('1')
    onCambio()
  }

  return (
    <details className="tarjeta" style={{ marginTop: 12 }}>
      <summary className="resumen">Agregar una pieza del catálogo</summary>
      {!elegido && (
        <>
          <div className="fila" style={{ alignItems: 'flex-end' }}>
            <label className="campo" style={{ flex: '1 1 200px', marginBottom: 0 }}>
              <span>Buscar por código o nombre</span>
              <input value={texto} onChange={ev => setTexto(ev.target.value)}
                onKeyDown={ev => { if (ev.key === 'Enter') { ev.preventDefault(); buscar() } }} placeholder="Batería, MC4, SMOALM…" />
            </label>
            <button type="button" disabled={texto.trim().length < 2} onClick={buscar}>Buscar</button>
          </div>
          {resultados.length > 0 && (
            <div className="buscador-lista" style={{ position: 'static', marginTop: 8 }}>
              {resultados.map(pr => (
                <button key={pr.id} type="button" onClick={() => setElegido(pr)}>
                  {pr.nombre}
                  <span className="ayuda">{pr.sku} · {pr.costo == null ? 'sin costo' : `${pesos(pr.costo)} de costo`}</span>
                </button>
              ))}
            </div>
          )}
        </>
      )}
      {elegido && (
        <>
          <p style={{ margin: '8px 0' }}><strong>{elegido.nombre}</strong> <span className="ayuda">({elegido.sku})</span></p>
          <div className="rejilla-2">
            <label className="campo">
              <span>¿En qué receta?</span>
              <select value={variante} onChange={ev => setVariante(ev.target.value)}>
                {RECETAS.map(r => <option key={r.clave} value={r.clave}>{r.nombre}</option>)}
              </select>
            </label>
            <label className="campo">
              <span>Cantidad</span>
              <input type="number" inputMode="decimal" min="0" step="any" value={cant} onChange={ev => setCant(ev.target.value)} />
            </label>
          </div>
          <div className="fila">
            <button type="button" className="btn-primario" disabled={ocupado || !cantidadValida(cant)} onClick={agregar}>Agregar a la receta</button>
            <button type="button" onClick={() => setElegido(null)}>Elegir otra</button>
          </div>
        </>
      )}
      {error && <Alerta tipo="aviso">{error}</Alerta>}
    </details>
  )
}

function Receta({ paqueteId, onCambio }) {
  const [vuelta, setVuelta] = useState(0)
  const [datos, setDatos] = useState(null)

  useEffect(() => {
    let vivo = true
    cargarLineas(paqueteId).then(d => { if (vivo) setDatos(d) })
    return () => { vivo = false }
  }, [paqueteId, vuelta])

  const cambio = () => { setVuelta(v => v + 1); onCambio() }
  if (!datos) return <p>Cargando…</p>
  return (
    <>
      {datos.error && <Alerta tipo="error">{datos.error}</Alerta>}
      <p className="ayuda">
        Los costos salen del catálogo (los actualiza la sincronización con el proveedor) y de Precios → Costeo de
        paquetes solares. Cambiar una cantidad recalcula el precio al momento.
      </p>
      {RECETAS.map(r => {
        const lineas = datos.lineas.filter(l => l.variante === r.clave)
        if (lineas.length === 0) return null
        return (
          <section key={r.clave} style={{ marginTop: 12 }}>
            <h4 style={{ margin: '0 0 4px' }}>{r.nombre} ({lineas.length})</h4>
            <ul style={{ listStyle: 'none', margin: 0, padding: 0 }}>
              {lineas.map(l => <LineaReceta key={`${l.id}-${l.cantidad}`} l={l} onCambio={cambio} />)}
            </ul>
          </section>
        )
      })}
      <AgregarLinea paqueteId={paqueteId} siguiente={datos.lineas.length + 1} onCambio={cambio} />
    </>
  )
}

function Paquete({ p, onCambio, onAviso }) {
  const [abierta, setAbierta] = useState(false)
  const receta = p.receta || {}
  return (
    <section className="tarjeta" aria-label={p.nombre}>
      <div className="renglon-titulo" style={{ fontSize: 20 }}>{tituloPaquete(p)}</div>
      <div className="renglon-datos">
        {[receta.inversor, receta.arreglo, p.publicar === false && 'No se publica en el sitio'].filter(Boolean).join(' · ')}
      </div>
      {p.sin_receta && <Alerta tipo="aviso">Este paquete todavía no tiene receta: agrégale piezas en "Lista de materiales".</Alerta>}
      {VARIANTES.filter(d => p.variantes?.[d.clave]).map(d => (
        <Variante key={d.clave} p={p} def={d} onPublicado={t => { onAviso(t); onCambio() }} />
      ))}
      <details style={{ marginTop: 12 }} open={abierta} onToggle={ev => setAbierta(ev.currentTarget.open)}>
        <summary className="resumen">Lista de materiales</summary>
        {abierta && <Receta paqueteId={p.paquete_id} onCambio={onCambio} />}
      </details>
    </section>
  )
}

export default function PaquetesSolares() {
  const [vuelta, setVuelta] = useState(0)
  const [datos, setDatos] = useState(null)
  const [mensaje, setMensaje] = useState('')
  const [ocupado, setOcupado] = useState(false)

  useEffect(() => {
    let vivo = true
    cargarPaquetes().then(d => { if (vivo) setDatos(d) })
    return () => { vivo = false }
  }, [vuelta])

  const recargar = () => setVuelta(v => v + 1)
  const avisar = t => { setMensaje(t); window.scrollTo?.({ top: 0, behavior: 'smooth' }) }
  const lista = datos?.paquetes || []
  const pendientes = porPublicar(lista)
  const regla = lista.find(p => p.regla)?.regla

  async function recalcular() {
    setOcupado(true)
    const r = await recalcularPaquetes()
    setOcupado(false)
    if (r.error) return avisar(r.error)
    const d = r.data || {}
    avisar(`Recalculados ${d.paquetes} paquetes: ${d.aplicados} ${d.aplicados === 1 ? 'precio se actualizó solo' : 'precios se actualizaron solos'}, ` +
      `${d.por_aprobar} ${d.por_aprobar === 1 ? 'espera' : 'esperan'} que los publiques.`)
    recargar()
  }

  return (
    <div className="pagina pagina-angosta">
      <h2>Paquetes solares</h2>
      <p className="ayuda">
        El precio se calcula con lo que cuesta cada pieza hoy. La primera vez se publica a mano; después, un
        cambio de 15 % o menos se aplica solo en cada sincronización con el proveedor, y lo demás espera aquí.
      </p>
      {datos?.error && <Alerta tipo="error">{datos.error}</Alerta>}
      {mensaje && <Alerta tipo="ok">{mensaje}</Alerta>}
      {!datos && <p>Cargando…</p>}
      {datos && (
        <>
          <div className="kpis">
            <div className="kpi kpi-principal">
              <span className="kpi-nombre">Por publicar</span>
              <span className="kpi-valor">{pendientes}</span>
              <span className="kpi-nota">{pendientes === 1 ? 'precio' : 'precios'} de {lista.length} paquetes</span>
            </div>
          </div>
          <p className="ayuda">{textoRegla(regla)}</p>
          <button type="button" disabled={ocupado} onClick={recalcular} style={{ marginBottom: 12 }}>
            {ocupado ? 'Recalculando…' : 'Recalcular ahora'}
          </button>
          {lista.length === 0 && <div className="tarjeta"><p style={{ margin: 0 }}>No hay paquetes solares activos.</p></div>}
          {lista.map(p => <Paquete key={p.paquete_id} p={p} onCambio={recargar} onAviso={avisar} />)}
        </>
      )}
    </div>
  )
}
