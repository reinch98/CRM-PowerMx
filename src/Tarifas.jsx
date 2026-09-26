import { useEffect, useMemo, useState } from 'react'
import { supabase } from './lib/supabase'
import { CLASES, CONCEPTOS_CATALOGO, esConceptoCatalogo, nombreTarifaCatalogo, sugerirSkuTarifa } from './lib/tarifas'
import {
  cargarPaquetes, crearPaquete, agregarLineaPaquete, quitarLineaPaquete, borrarPaquete
} from './lib/preventivo'
import { Alerta } from './ui'

// Tarifas de servicio (solo admin; el técnico nunca ve precios). Se COPIAN a la
// partida al cotizar, así que cambiar una tarifa no altera cotizaciones viejas.
//
//   diagnóstico: por clase de equipo y tramo de capacidad (kW; kWh en baterías).
//   traslado:    precio por km, solo ida, desde los km indicados; una vez rebasados
//                se cobran todos los km.
//   catálogo:    correctivo, preventivo, instalación de gas o eléctrica, u otro. Cada
//                una tiene su propio SKU: se busca y se agrega a una cotización igual
//                que un producto, sin depender de una fórmula. Clase y tramo son
//                opcionales aquí (una instalación no siempre depende de la clase).

const NOMBRE_CLASE = Object.fromEntries(CLASES)
const NOMBRE_CONCEPTO_CATALOGO = Object.fromEntries(CONCEPTOS_CATALOGO)

const vacia = {
  concepto: 'diagnostico', clase: 'gasolina',
  kw_desde: '', kw_hasta: '', km_desde: '40', precio: '', notas: '',
  sku: '', nombre: ''
}

const aNumero = v => (v === '' || v == null ? null : Number(v))

// ---------------------------------------------------------------------------
// Paquetes de mantenimiento: qué refacciones lleva un preventivo (SQL 28).
//
// El precio del servicio va en la tabla de arriba, fijo. Esto es lo OTRO que cambia de un
// equipo a otro: qué piezas se le ponen. Un paquete apunta a una clase y un tramo de kW
// (lo general) o a una marca y modelo concretos, y al cotizar **gana el específico**.
//
// Cada línea dice qué hace falta ("Filtro de aceite") y con qué producto se cumple. Si ese
// producto tiene grupo equivalente en Inventario, al cotizar salen también sus genéricos
// con lo disponible de cada uno.
// ---------------------------------------------------------------------------
const paqueteVacio = {
  tipo: 'menor', clase: 'diesel', kw_desde: '', kw_hasta: '',
  marca: '', modelo: '', nombre: '', notas: ''
}

function PaquetesMantenimiento({ productos }) {
  const [paquetes, setPaquetes] = useState([])
  const [nuevo, setNuevo] = useState(paqueteVacio)
  const [lineas, setLineas] = useState({})    // { [paqueteId]: { descripcion, producto_id, cantidad } }
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState('')

  useEffect(() => { cargar() }, [])

  async function cargar() {
    const r = await cargarPaquetes()
    if (r.ok) setPaquetes(r.paquetes)
    else setError(r.texto)
  }

  async function crear(e) {
    e.preventDefault()
    setError(''); setMensaje('')
    const r = await crearPaquete({
      tipo: nuevo.tipo,
      clase: nuevo.clase || null,
      kw_desde: nuevo.kw_desde === '' ? null : Number(nuevo.kw_desde),
      kw_hasta: nuevo.kw_hasta === '' ? null : Number(nuevo.kw_hasta),
      marca: nuevo.marca.trim() || null,
      modelo: nuevo.modelo.trim() || null,
      nombre: nuevo.nombre.trim() || null,
      notas: nuevo.notas.trim() || null,
    })
    if (!r.ok) return setError(r.texto)
    setNuevo(paqueteVacio); setMensaje('Paquete creado. Agrégale sus piezas.'); cargar()
  }

  async function agregarLinea(paqueteId) {
    const l = lineas[paqueteId] || {}
    if (!l.descripcion?.trim()) return setError('Escribe qué pieza es.')
    if (!l.producto_id) return setError('Elige con qué producto se cumple.')
    setError('')
    const r = await agregarLineaPaquete(paqueteId, {
      descripcion: l.descripcion.trim(),
      producto_id: l.producto_id,
      cantidad: Number(l.cantidad) || 1,
      orden: 0,
    })
    if (!r.ok) return setError(r.texto)
    setLineas({ ...lineas, [paqueteId]: {} })
    cargar()
  }

  async function quitarLinea(id) {
    const r = await quitarLineaPaquete(id)
    if (!r.ok) return setError(r.texto)
    cargar()
  }

  async function borrar(p) {
    if (!confirm(`¿Borrar el paquete "${nombrePaquete(p)}"?`)) return
    const r = await borrarPaquete(p.id)
    if (!r.ok) return setError(r.texto)
    cargar()
  }

  const nombrePaquete = p => p.nombre
    || [p.tipo === 'menor' ? 'Menor' : 'Mayor',
        p.marca && p.modelo ? `${p.marca} ${p.modelo}` : NOMBRE_CLASE[p.clase] || p.clase,
        p.kw_desde != null || p.kw_hasta != null
          ? `${p.kw_desde ?? 0}–${p.kw_hasta ?? '∞'} kW` : null].filter(Boolean).join(' · ')

  const cambiarLinea = (id, campo, valor) =>
    setLineas({ ...lineas, [id]: { ...(lineas[id] || {}), [campo]: valor } })

  return (
    <section className="tarjeta" style={{ marginTop: 16 }}>
      <h3>Paquetes de mantenimiento</h3>
      <p className="ayuda">
        Qué refacciones lleva un preventivo. El precio va arriba, en las tarifas; esto es lo
        que se aparta del almacén. Si un paquete apunta a una marca y modelo, gana sobre el
        general de su clase.
      </p>

      {error && <Alerta tipo="error">{error}</Alerta>}
      {mensaje && <Alerta tipo="ok" palabra="Listo">{mensaje}</Alerta>}

      {paquetes.map(p => (
        <div key={p.id} className="refaccion">
          <span className="fila" style={{ justifyContent: 'space-between' }}>
            <strong>{nombrePaquete(p)}</strong>
            <button type="button" className="btn-peligro" onClick={() => borrar(p)}>Borrar</button>
          </span>

          {(p.paquete_lineas || []).map(l => (
            <span key={l.id} className="fila" style={{ justifyContent: 'space-between' }}>
              <span>
                {l.cantidad} × {l.descripcion}
                <span className="ayuda">
                  {' '}{productos.find(x => x.id === l.producto_id)?.sku || 'sin producto'}
                </span>
              </span>
              <button type="button" onClick={() => quitarLinea(l.id)}>Quitar</button>
            </span>
          ))}
          {(p.paquete_lineas || []).length === 0 && (
            <span className="ayuda">Sin piezas todavía: así no se puede cotizar.</span>
          )}

          <div className="rejilla-2">
            <label className="campo">
              <span>Qué pieza</span>
              <input value={lineas[p.id]?.descripcion || ''} placeholder="Filtro de aceite"
                onChange={e => cambiarLinea(p.id, 'descripcion', e.target.value)} />
            </label>
            <label className="campo">
              <span>Cantidad</span>
              <input type="number" min="1" value={lineas[p.id]?.cantidad ?? 1}
                onChange={e => cambiarLinea(p.id, 'cantidad', e.target.value)} />
            </label>
          </div>
          <label className="campo">
            <span>Con qué producto</span>
            <select value={lineas[p.id]?.producto_id || ''}
              onChange={e => cambiarLinea(p.id, 'producto_id', e.target.value)}>
              <option value="">— Elige —</option>
              {productos.map(x => (
                <option key={x.id} value={x.id}>
                  {x.sku} — {x.nombre}{x.grupo_equivalente ? ' (con genéricos)' : ''}
                </option>
              ))}
            </select>
          </label>
          <button type="button" onClick={() => agregarLinea(p.id)}>Agregar la pieza</button>
        </div>
      ))}

      <details className="tarjeta" style={{ marginTop: 12 }}>
        <summary className="resumen">＋ Nuevo paquete</summary>
        <form onSubmit={crear} style={{ maxWidth: 520, marginTop: 12 }}>
          <div className="rejilla-2">
            <label className="campo">
              <span>Tipo</span>
              <select value={nuevo.tipo} onChange={e => setNuevo({ ...nuevo, tipo: e.target.value })}>
                <option value="menor">Mantenimiento menor</option>
                <option value="mayor">Mantenimiento mayor</option>
              </select>
            </label>
            <label className="campo">
              <span>Clase</span>
              <select value={nuevo.clase} onChange={e => setNuevo({ ...nuevo, clase: e.target.value })}>
                <option value="">Cualquiera</option>
                {CLASES.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
              </select>
            </label>
            <label className="campo">
              <span>Desde (kW)</span>
              <input type="number" value={nuevo.kw_desde}
                onChange={e => setNuevo({ ...nuevo, kw_desde: e.target.value })} />
            </label>
            <label className="campo">
              <span>Hasta (kW)</span>
              <input type="number" value={nuevo.kw_hasta}
                onChange={e => setNuevo({ ...nuevo, kw_hasta: e.target.value })} />
            </label>
            <label className="campo">
              <span>Marca (opcional)</span>
              <input value={nuevo.marca} onChange={e => setNuevo({ ...nuevo, marca: e.target.value })} />
            </label>
            <label className="campo">
              <span>Modelo (opcional)</span>
              <input value={nuevo.modelo} onChange={e => setNuevo({ ...nuevo, modelo: e.target.value })} />
            </label>
          </div>
          <p className="ayuda">
            Marca y modelo solo si este paquete es para ese equipo en concreto. Al cotizar,
            un paquete con modelo gana sobre el general de su clase.
          </p>
          <label className="campo">
            <span>Nombre (opcional)</span>
            <input value={nuevo.nombre} onChange={e => setNuevo({ ...nuevo, nombre: e.target.value })} />
          </label>
          <button type="submit" className="btn-primario">Crear paquete</button>
        </form>
      </details>
    </section>
  )
}

export default function Tarifas() {
  const [filas, setFilas] = useState([])
  const [nueva, setNueva] = useState(vacia)
  const [skuTocado, setSkuTocado] = useState(false)   // si el admin ya editó el SKU a mano, no se le pisa
  const [edicion, setEdicion] = useState({})    // { [id]: { campo: valor } }
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState('')
  const [productos, setProductos] = useState([])

  useEffect(() => { cargar() }, [])

  async function cargar() {
    const [t, p] = await Promise.all([
      supabase.from('tarifas_servicio').select('*')
        .order('concepto').order('clase').order('kw_desde'),
      // Para armar las líneas de un paquete hace falta el catálogo con su grupo
      // equivalente: es lo que decide qué genéricos salen al cotizar.
      supabase.from('productos').select('id, sku, nombre, grupo_equivalente')
        .eq('activo', true).order('sku')
    ])
    if (t.error) return setError(t.error.message)
    setFilas(t.data || [])
    setProductos(p.data || [])
  }

  const diagnostico = useMemo(() => filas.filter(f => f.concepto === 'diagnostico'), [filas])
  const traslado = useMemo(() => filas.filter(f => f.concepto === 'traslado'), [filas])
  const catalogo = useMemo(() => filas.filter(f => esConceptoCatalogo(f.concepto)), [filas])

  function textoDeError(error) {
    return error.code === '23505' ? 'Ese SKU ya existe. Usa otro.' : error.message
  }

  function validar(f) {
    if (f.precio === '' || f.precio == null || Number(f.precio) < 0) return 'Falta el precio'
    if (f.concepto === 'diagnostico') {
      if (!f.clase) return 'Elige la clase del equipo'
      const d = aNumero(f.kw_desde), h = aNumero(f.kw_hasta)
      if (d != null && h != null && d > h) return 'El tramo está al revés: "desde" es mayor que "hasta"'
    }
    if (esConceptoCatalogo(f.concepto)) {
      if (!f.sku?.trim()) return 'Falta el SKU: es lo que se busca para agregarla a una cotización'
      if (f.concepto === 'otro' && !f.nombre?.trim()) return 'Escribe el nombre del servicio: "otro" no tiene uno por defecto'
      const d = aNumero(f.kw_desde), h = aNumero(f.kw_hasta)
      if (d != null && h != null && d > h) return 'El tramo está al revés: "desde" es mayor que "hasta"'
    }
    return ''
  }

  async function agregar(e) {
    e.preventDefault()
    setError(''); setMensaje('')
    const motivo = validar(nueva)
    if (motivo) return setError(motivo)
    const esDiag = nueva.concepto === 'diagnostico'
    const esCatalogo = esConceptoCatalogo(nueva.concepto)
    const { error } = await supabase.from('tarifas_servicio').insert([{
      concepto: nueva.concepto,
      clase: (esDiag || esCatalogo) ? (nueva.clase || null) : null,
      kw_desde: (esDiag || esCatalogo) ? aNumero(nueva.kw_desde) : null,
      kw_hasta: (esDiag || esCatalogo) ? aNumero(nueva.kw_hasta) : null,
      km_desde: nueva.concepto === 'traslado' ? aNumero(nueva.km_desde) : null,
      sku: esCatalogo ? nueva.sku.trim() : null,
      nombre: esCatalogo ? (nueva.nombre.trim() || null) : null,
      precio: Number(nueva.precio),
      notas: nueva.notas || null
    }])
    if (error) return setError(textoDeError(error))
    setNueva({ ...vacia, concepto: nueva.concepto })
    setSkuTocado(false)
    setMensaje('Tarifa agregada.')
    cargar()
  }

  function editar(id, campo, valor) {
    setEdicion({ ...edicion, [id]: { ...(edicion[id] || {}), [campo]: valor } })
  }

  const valor = (f, campo) => (campo in (edicion[f.id] || {}) ? edicion[f.id][campo] : (f[campo] ?? ''))

  async function guardarFila(f) {
    const cambios = edicion[f.id]
    if (!cambios) return
    setError(''); setMensaje('')
    const merged = { ...f, ...cambios }
    const motivo = validar(merged)
    if (motivo) return setError(motivo)

    const payload = {}
    for (const c of Object.keys(cambios)) {
      payload[c] = ['kw_desde', 'kw_hasta', 'km_desde', 'precio'].includes(c) ? aNumero(cambios[c]) : cambios[c]
    }
    const { error } = await supabase.from('tarifas_servicio').update(payload).eq('id', f.id)
    if (error) return setError(textoDeError(error))
    const { [f.id]: _, ...resto } = edicion
    setEdicion(resto)
    setMensaje('Tarifa actualizada.')
    cargar()
  }

  async function quitar(f) {
    if (!confirm('¿Quitar esta tarifa? Las cotizaciones ya hechas no cambian: llevan su precio copiado.')) return
    const { error } = await supabase.from('tarifas_servicio').delete().eq('id', f.id)
    if (error) return setError(textoDeError(error))
    cargar()
  }

  // Tramos de la misma clase que se empalman: no se bloquea, se avisa.
  const empalmes = useMemo(() => {
    const avisos = []
    const activas = diagnostico.filter(f => f.activo)
    for (let i = 0; i < activas.length; i++) {
      for (let j = i + 1; j < activas.length; j++) {
        const a = activas[i], b = activas[j]
        if (a.clase !== b.clase) continue
        const ad = a.kw_desde ?? -Infinity, ah = a.kw_hasta ?? Infinity
        const bd = b.kw_desde ?? -Infinity, bh = b.kw_hasta ?? Infinity
        if (ad < bh && bd < ah) {
          avisos.push(`${NOMBRE_CLASE[a.clase] || a.clase}: los tramos ${a.kw_desde ?? '…'}–${a.kw_hasta ?? '…'} y ${b.kw_desde ?? '…'}–${b.kw_hasta ?? '…'} se empalman. Gana el que empieza más arriba.`)
        }
      }
    }
    return avisos
  }, [diagnostico])

  const esDiag = nueva.concepto === 'diagnostico'
  const esTraslado = nueva.concepto === 'traslado'
  const esCatalogo = esConceptoCatalogo(nueva.concepto)

  // Al elegir un concepto de catálogo, o cambiarle la clase, se sugiere el SKU; el
  // admin lo puede editar libremente, y desde ahí ya no se le pisa (skuTocado).
  function cambiarConcepto(concepto) {
    const catalogoNuevo = esConceptoCatalogo(concepto)
    const clase = catalogoNuevo ? '' : 'gasolina'   // diagnóstico exige clase; traslado la ignora
    setNueva({ ...nueva, concepto, clase, sku: catalogoNuevo ? sugerirSkuTarifa(concepto, clase) : nueva.sku })
    setSkuTocado(false)
  }
  function cambiarClaseNueva(clase) {
    const cambios = { ...nueva, clase }
    if (esConceptoCatalogo(nueva.concepto) && !skuTocado) cambios.sku = sugerirSkuTarifa(nueva.concepto, clase)
    setNueva(cambios)
  }

  // Función y NO componente: un componente definido aquí adentro se recrearía en cada
  // tecla y el campo perdería el foco mientras se escribe.
  function filaTarifa(f) {
    const diag = f.concepto === 'diagnostico'
    return (
      <tr key={f.id} style={f.activo ? undefined : { opacity: 0.6 }}>
        {diag && <td>{NOMBRE_CLASE[f.clase] || f.clase}</td>}
        {diag ? (
          <>
            <td><input type="number" step="any" style={{ width: 90 }} aria-label="kW desde"
              value={valor(f, 'kw_desde')} onChange={e => editar(f.id, 'kw_desde', e.target.value)} /></td>
            <td><input type="number" step="any" style={{ width: 90 }} aria-label="kW hasta"
              value={valor(f, 'kw_hasta')} onChange={e => editar(f.id, 'kw_hasta', e.target.value)} /></td>
          </>
        ) : (
          <td><input type="number" step="any" style={{ width: 90 }} aria-label="Km desde"
            value={valor(f, 'km_desde')} onChange={e => editar(f.id, 'km_desde', e.target.value)} /></td>
        )}
        <td><input type="number" step="any" min="0" style={{ width: 110 }} aria-label="Precio"
          value={valor(f, 'precio')} onChange={e => editar(f.id, 'precio', e.target.value)} /></td>
        <td align="center">
          <input type="checkbox" aria-label="Activa" checked={!!valor(f, 'activo')}
            onChange={e => editar(f.id, 'activo', e.target.checked)} />
          {' '}{valor(f, 'activo') ? 'Sí' : 'No'}
        </td>
        <td>
          {edicion[f.id] && <button onClick={() => guardarFila(f)}>Guardar</button>}
          {' '}<button className="btn-peligro" onClick={() => quitar(f)}>Quitar</button>
        </td>
      </tr>
    )
  }

  function filaCatalogo(f) {
    return (
      <tr key={f.id} style={f.activo ? undefined : { opacity: 0.6 }}>
        <td><input aria-label="SKU" style={{ width: 150 }}
          value={valor(f, 'sku')} onChange={e => editar(f.id, 'sku', e.target.value)} /></td>
        <td>{NOMBRE_CONCEPTO_CATALOGO[f.concepto] || f.concepto}</td>
        <td>
          <select aria-label="Clase (opcional)" value={valor(f, 'clase')} onChange={e => editar(f.id, 'clase', e.target.value)}>
            <option value="">Cualquiera</option>
            {CLASES.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
          </select>
        </td>
        <td>
          <input aria-label={`Nombre para mostrar de ${f.sku}`} style={{ width: 170 }}
            placeholder={nombreTarifaCatalogo(f)}
            value={valor(f, 'nombre')} onChange={e => editar(f.id, 'nombre', e.target.value)} />
        </td>
        <td><input type="number" step="any" min="0" style={{ width: 110 }} aria-label="Precio"
          value={valor(f, 'precio')} onChange={e => editar(f.id, 'precio', e.target.value)} /></td>
        <td align="center">
          <input type="checkbox" aria-label="Activa" checked={!!valor(f, 'activo')}
            onChange={e => editar(f.id, 'activo', e.target.checked)} />
          {' '}{valor(f, 'activo') ? 'Sí' : 'No'}
        </td>
        <td>
          {edicion[f.id] && <button onClick={() => guardarFila(f)}>Guardar</button>}
          {' '}<button className="btn-peligro" onClick={() => quitar(f)}>Quitar</button>
        </td>
      </tr>
    )
  }

  return (
    <div className="pagina">
      <h2>Tarifas de servicio</h2>
      <p className="ayuda" style={{ maxWidth: 680 }}>
        Precios del diagnóstico, del traslado y de los servicios de catálogo. Al cotizar se copian
        a la partida: cambiar una tarifa aquí no altera las cotizaciones que ya hiciste.
      </p>

      {error && <Alerta tipo="error">{error}</Alerta>}
      {mensaje && <Alerta tipo="ok" palabra="Listo">{mensaje}</Alerta>}
      {empalmes.map((a, i) => <Alerta key={i} tipo="aviso" palabra="Ojo">{a}</Alerta>)}

      <section className="tarjeta">
        <h3>Servicios (por SKU)</h3>
        <p className="ayuda">
          Correctivo, preventivo, instalación de gas o eléctrica, u otro. Cada una se busca y se
          agrega a una cotización por su SKU, igual que un producto: no mueve inventario. La clase
          y el tramo de kW son opcionales.
        </p>
        <div className="tabla-scroll">
          <table>
            <thead>
              <tr><th>SKU</th><th>Concepto</th><th>Clase</th><th>Nombre (opcional)</th><th>Precio</th><th>Activa</th><th></th></tr>
            </thead>
            <tbody>
              {catalogo.map(filaCatalogo)}
              {catalogo.length === 0 && (
                <tr><td colSpan={7} className="ayuda">Todavía no hay servicios de catálogo.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      <section className="tarjeta">
        <h3>Diagnóstico</h3>
        <p className="ayuda">
          Por clase de equipo y tramo de capacidad. El tramo incluye sus dos extremos. En baterías
          la capacidad se mide en kWh.
        </p>
        <div className="tabla-scroll">
          <table>
            <thead>
              <tr><th>Clase</th><th>Desde (kW)</th><th>Hasta (kW)</th><th>Precio</th><th>Activa</th><th></th></tr>
            </thead>
            <tbody>
              {diagnostico.map(filaTarifa)}
              {diagnostico.length === 0 && (
                <tr><td colSpan={6} className="ayuda">Todavía no hay tarifas de diagnóstico.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      <section className="tarjeta">
        <h3>Traslado</h3>
        <p className="ayuda">
          Precio por kilómetro, solo ida. Desde los km indicados se cobran <strong>todos</strong> los km
          (a 55 km y con desde = 40, se cobran 55).
        </p>
        <div className="tabla-scroll">
          <table>
            <thead>
              <tr><th>Desde (km)</th><th>Precio por km</th><th>Activa</th><th></th></tr>
            </thead>
            <tbody>
              {traslado.map(filaTarifa)}
              {traslado.length === 0 && (
                <tr><td colSpan={4} className="ayuda">Todavía no hay tarifa de traslado.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      <PaquetesMantenimiento productos={productos} />

      <section className="tarjeta">
        <h3>Agregar tarifa</h3>
        <form onSubmit={agregar} style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr)', gap: 10, maxWidth: 520 }}>
          <label className="campo">
            <span>Concepto</span>
            <select value={nueva.concepto} onChange={e => cambiarConcepto(e.target.value)}>
              <option value="diagnostico">Diagnóstico</option>
              <option value="traslado">Traslado (por km)</option>
              {CONCEPTOS_CATALOGO.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
            </select>
          </label>

          {esCatalogo && (
            <label className="campo">
              <span>SKU</span>
              <input value={nueva.sku}
                onChange={e => { setSkuTocado(true); setNueva({ ...nueva, sku: e.target.value }) }} />
              <span className="ayuda">Se sugiere solo; puedes cambiarlo, pero debe ser único.</span>
            </label>
          )}

          {(esDiag || esCatalogo) && (
            <>
              <label className="campo">
                <span>Clase de equipo{esCatalogo && ' (opcional)'}</span>
                <select value={nueva.clase} onChange={e => cambiarClaseNueva(e.target.value)}>
                  {esCatalogo && <option value="">Cualquiera</option>}
                  {CLASES.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
                </select>
              </label>
              <div className="rejilla-2">
                <label className="campo">
                  <span>Desde (kW){esCatalogo && ' (opcional)'}</span>
                  <input type="number" step="any" min="0" value={nueva.kw_desde}
                    onChange={e => setNueva({ ...nueva, kw_desde: e.target.value })} />
                </label>
                <label className="campo">
                  <span>Hasta (kW){esCatalogo && ' (opcional)'}</span>
                  <input type="number" step="any" min="0" value={nueva.kw_hasta}
                    onChange={e => setNueva({ ...nueva, kw_hasta: e.target.value })} />
                </label>
              </div>
            </>
          )}

          {esCatalogo && (
            <label className="campo">
              <span>Nombre para mostrar{nueva.concepto === 'otro' ? '' : ' (opcional)'}</span>
              <input value={nueva.nombre} placeholder={nombreTarifaCatalogo({ ...nueva, kw_desde: aNumero(nueva.kw_desde), kw_hasta: aNumero(nueva.kw_hasta) })}
                onChange={e => setNueva({ ...nueva, nombre: e.target.value })} />
              {nueva.concepto === 'otro' && <span className="ayuda">"Otro" no tiene un nombre por defecto: escríbelo.</span>}
            </label>
          )}

          {esTraslado && (
            <label className="campo">
              <span>A partir de (km)</span>
              <input type="number" step="any" min="0" value={nueva.km_desde}
                onChange={e => setNueva({ ...nueva, km_desde: e.target.value })} />
            </label>
          )}

          <label className="campo">
            <span>Precio{esTraslado ? ' por km' : ''}</span>
            <input type="number" step="any" min="0" value={nueva.precio}
              onChange={e => setNueva({ ...nueva, precio: e.target.value })} />
          </label>

          <button type="submit" className="btn-primario">Agregar</button>
        </form>
      </section>
    </div>
  )
}
