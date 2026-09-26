import { useEffect, useMemo, useState } from 'react'
import { supabase } from './lib/supabase'
import { Alerta } from './ui'

const CATEGORIAS = [
  ['generador', 'Generadores'],
  ['paquete_solar', 'Paquetes solares'],
  ['bateria', 'Baterías'],
  ['panel', 'Paneles'],
  ['refaccion', 'Refacciones'],
  ['renta', 'Rentas']
]

// Cada tipo de movimiento y a qué bolsa pega. El texto de ayuda es el que
// aparece debajo del selector para que nadie tenga que acordarse.
const TIPOS = [
  ['entrada', 'Entrada por compra', 'Suma al físico. Material que acaba de llegar al almacén.'],
  ['apartado', 'Apartado (cotización aprobada)', 'No mueve el físico, pero deja de estar disponible.'],
  ['libera_apartado', 'Liberar apartado', 'La cotización se rechazó o venció; el material vuelve a estar disponible.'],
  ['salida_venta', 'Salida por venta', 'Facturado y entregado. Sale del almacén.'],
  ['a_resguardo', 'A resguardo de cliente', 'Facturado pero se queda guardado para ese cliente. Requiere elegir cliente.'],
  ['consumo_resguardo', 'Consumo de resguardo', 'El técnico usó material ya pagado por ese cliente. Requiere elegir cliente.'],
  ['consumo_servicio', 'Consumo por servicio o garantía', 'Salió del almacén sin factura de por medio.'],
  ['ajuste', 'Ajuste por conteo físico', 'Cuadra el sistema con lo que realmente hay. Acepta negativo.']
]

const NECESITAN_CLIENTE = ['a_resguardo', 'consumo_resguardo']

const vacioProducto = {
  sku: '', categoria: 'refaccion', nombre: '', marca: '', modelo: '',
  descripcion: '', precio: '', costo: '', minimo: '', unidad: 'pieza',
  clave_producto_sat: '', clave_unidad_sat: 'H87'
}

const vacioMovimiento = {
  producto_id: '', tipo: 'entrada', cantidad: '',
  cliente_id: '', referencia: '', notas: ''
}

const num = v => (v === '' || v == null ? null : Number(v))

export default function Inventario() {
  const [vista, setVista] = useState('existencias')
  const [productos, setProductos] = useState([])
  const [filas, setFilas] = useState([])       // vista disponibles
  const [clientes, setClientes] = useState([])
  const [categoria, setCategoria] = useState('')
  const [busqueda, setBusqueda] = useState('')
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState('')

  const [nuevo, setNuevo] = useState(vacioProducto)
  const [mov, setMov] = useState(vacioMovimiento)
  const [editando, setEditando] = useState({})  // { [id]: { precio, costo, minimo } }

  useEffect(() => { cargar() }, [])

  async function cargar() {
    const [p, d, c] = await Promise.all([
      supabase.from('productos').select('*').eq('activo', true).order('categoria').order('sku'),
      supabase.from('disponibles').select('*').order('categoria').order('sku'),
      supabase.from('clientes').select('id, nombre').order('nombre')
    ])
    if (p.error) return setError(p.error.message)
    if (d.error) return setError(d.error.message)
    setProductos(p.data || [])
    setFilas(d.data || [])
    setClientes(c.data || [])
  }

  // Los productos filtrados alimentan las tres vistas.
  const visibles = useMemo(() => {
    const t = busqueda.trim().toLowerCase()
    return productos.filter(p =>
      (!categoria || p.categoria === categoria) &&
      (!t || p.sku.toLowerCase().includes(t) || (p.nombre || '').toLowerCase().includes(t))
    )
  }, [productos, categoria, busqueda])

  const existencias = useMemo(() => {
    const ids = new Set(visibles.map(p => p.id))
    return filas.filter(f => ids.has(f.id))
  }, [filas, visibles])

  const sinPrecio = productos.filter(p => p.precio == null).length
  const sinCosto = productos.filter(p => p.costo == null).length

  // -------------------------------------------------------------------------
  // Captura rápida: edita precio, costo y mínimo directo en la lista. Es lo
  // que hace falta ahora mismo, no una pantalla de edición por producto.
  // -------------------------------------------------------------------------
  function editar(id, campo, valor) {
    setEditando({ ...editando, [id]: { ...(editando[id] || {}), [campo]: valor } })
  }

  async function guardarFila(p) {
    const cambios = editando[p.id]
    if (!cambios) return
    const payload = {}
    for (const campo of ['precio', 'costo', 'minimo']) {
      if (campo in cambios) payload[campo] = num(cambios[campo])
    }
    // Texto, no número: la etiqueta vacía se guarda como null para no dejar equivalencias
    // fantasma que agruparían entre sí todos los productos sin grupo.
    if ('grupo_equivalente' in cambios) {
      payload.grupo_equivalente = cambios.grupo_equivalente.trim() || null
    }
    const { error } = await supabase.from('productos').update(payload).eq('id', p.id)
    if (error) return setError(error.message)
    const { [p.id]: _, ...resto } = editando
    setEditando(resto)
    setMensaje(`${p.sku} actualizado.`)
    cargar()
  }

  async function guardarProducto(e) {
    e.preventDefault()
    setError(''); setMensaje('')
    if (!nuevo.sku.trim()) return setError('El SKU es obligatorio')
    if (!nuevo.nombre.trim()) return setError('El nombre es obligatorio')

    const payload = {
      ...nuevo,
      sku: nuevo.sku.trim(),
      precio: num(nuevo.precio),
      costo: num(nuevo.costo),
      minimo: num(nuevo.minimo) ?? 0
    }
    const { error } = await supabase.from('productos').insert([payload])
    if (error) return setError(error.message)
    setNuevo(vacioProducto)
    setMensaje('Producto agregado.')
    cargar()
  }

  // -------------------------------------------------------------------------
  // Movimientos: nunca se edita un número de existencia, se registra un hecho.
  // -------------------------------------------------------------------------
  async function guardarMovimiento(e) {
    e.preventDefault()
    setError(''); setMensaje('')

    if (!mov.producto_id) return setError('Elige el producto')
    const cantidad = num(mov.cantidad)
    if (cantidad == null || cantidad === 0) return setError('La cantidad no puede ir vacía ni en cero')
    if (cantidad < 0 && mov.tipo !== 'ajuste') return setError('Solo el ajuste por conteo acepta negativos')
    if (NECESITAN_CLIENTE.includes(mov.tipo) && !mov.cliente_id) {
      return setError('Este movimiento necesita cliente: el resguardo se lleva por cliente')
    }

    const { error } = await supabase.from('movimientos_inventario').insert([{
      producto_id: mov.producto_id,
      tipo: mov.tipo,
      cantidad,
      cliente_id: mov.cliente_id || null,
      referencia: mov.referencia || null,
      notas: mov.notas || null,
      usuario: (await supabase.auth.getUser()).data.user?.email || null
    }])
    if (error) return setError(error.message)

    setMov({ ...vacioMovimiento, tipo: mov.tipo })  // el tipo se queda, se capturan varios seguidos
    setMensaje('Movimiento registrado.')
    cargar()
  }

  const ayudaTipo = TIPOS.find(t => t[0] === mov.tipo)?.[2]

  return (
    <div className="pagina">
      <h2>Inventario</h2>

      <div className="pestanas">
        <button className="pestana" aria-pressed={vista === 'existencias'} onClick={() => setVista('existencias')}>Existencias</button>
        <button className="pestana" aria-pressed={vista === 'catalogo'} onClick={() => setVista('catalogo')}>Catálogo</button>
        <button className="pestana" aria-pressed={vista === 'movimiento'} onClick={() => setVista('movimiento')}>Registrar movimiento</button>
      </div>

      {(sinPrecio > 0 || sinCosto > 0) && (
        <Alerta tipo="aviso" palabra="Faltan datos">
          <strong>{sinPrecio}</strong> precios y <strong>{sinCosto}</strong> costos por capturar.
          Se editan en la pestaña Catálogo.
        </Alerta>
      )}

      {vista !== 'movimiento' && (
        <div className="fila" style={{ marginBottom: 14 }}>
          <select value={categoria} onChange={e => setCategoria(e.target.value)} aria-label="Categoría">
            <option value="">Todas las categorías</option>
            {CATEGORIAS.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
          </select>
          <input
            placeholder="Buscar por SKU o nombre"
            value={busqueda}
            onChange={e => setBusqueda(e.target.value)}
            aria-label="Buscar por SKU o nombre"
            style={{ flex: 1, minWidth: 200 }}
          />
        </div>
      )}

      {error && <Alerta tipo="error">{error}</Alerta>}
      {mensaje && <Alerta tipo="ok" palabra="Listo">{mensaje}</Alerta>}

      {/* ------------------------------------------------------------------ */}
      {vista === 'existencias' && (
        <>
          <p className="ayuda">
            Disponible = físico − apartado − resguardo. Es lo único que puedes prometer.
            Las filas con <strong>Bajo el mínimo</strong> hay que reordenarlas.
          </p>
          <div className="tabla-scroll">
            <table>
              <thead>
                <tr>
                  <th>SKU</th><th>Producto</th><th>Categoría</th>
                  <th>Físico</th><th>Apartado</th><th>Resguardo</th><th>Disponible</th><th>Mínimo</th>
                </tr>
              </thead>
              <tbody>
                {existencias.map(f => {
                  const bajo = f.minimo > 0 && f.disponible < f.minimo
                  return (
                    <tr key={f.id} style={bajo ? { background: 'var(--error-fondo)' } : undefined}>
                      <td>{f.sku}</td>
                      <td>{f.nombre}</td>
                      <td>{f.categoria}</td>
                      <td align="right">{f.fisico}</td>
                      <td align="right">{f.apartado}</td>
                      <td align="right">{f.resguardo}</td>
                      <td align="right">
                        <strong>{f.disponible}</strong>
                        {bajo && <div><span className="estado estado-rechazada">Bajo el mínimo</span></div>}
                      </td>
                      <td align="right">{f.minimo || '—'}</td>
                    </tr>
                  )
                })}
                {existencias.length === 0 && (
                  <tr><td colSpan={8} className="ayuda">No hay productos con esos filtros.</td></tr>
                )}
              </tbody>
            </table>
          </div>
        </>
      )}

      {/* ------------------------------------------------------------------ */}
      {vista === 'catalogo' && (
        <>
          <div className="tabla-scroll">
            <table>
              <thead>
                <tr>
                  <th>SKU</th><th>Producto</th><th>Marca</th>
                  <th>Precio</th><th>Costo</th><th>Margen</th><th>Mínimo</th>
                  <th>Grupo equivalente</th><th></th>
                </tr>
              </thead>
              <tbody>
                {visibles.map(p => {
                  const ed = editando[p.id] || {}
                  const precio = 'precio' in ed ? num(ed.precio) : p.precio
                  const costo = 'costo' in ed ? num(ed.costo) : p.costo
                  const margen = precio && costo ? Math.round(((precio - costo) / precio) * 100) : null
                  return (
                    <tr key={p.id} style={p.precio == null ? { background: 'var(--aviso-fondo)' } : undefined}>
                      <td>{p.sku}</td>
                      <td>
                        {p.nombre}
                        {p.precio == null && <div><span className="estado estado-pendiente">Sin precio</span></div>}
                      </td>
                      <td>{p.marca}</td>
                      <td>
                        <input
                          type="number" style={{ width: 110, textAlign: 'right' }} aria-label={`Precio de ${p.sku}`}
                          value={'precio' in ed ? ed.precio : (p.precio ?? '')}
                          onChange={e => editar(p.id, 'precio', e.target.value)}
                        />
                      </td>
                      <td>
                        <input
                          type="number" style={{ width: 110, textAlign: 'right' }} aria-label={`Costo de ${p.sku}`}
                          value={'costo' in ed ? ed.costo : (p.costo ?? '')}
                          onChange={e => editar(p.id, 'costo', e.target.value)}
                        />
                      </td>
                      <td align="right">{margen == null ? '—' : `${margen}%`}</td>
                      <td>
                        <input
                          type="number" style={{ width: 90, textAlign: 'right' }} aria-label={`Mínimo de ${p.sku}`}
                          value={'minimo' in ed ? ed.minimo : (p.minimo ?? '')}
                          onChange={e => editar(p.id, 'minimo', e.target.value)}
                        />
                      </td>
                      <td>
                        {/* Dos productos con la MISMA etiqueta son intercambiables: el
                            original y su genérico. De ahí salen las opciones de cada
                            línea de un paquete de mantenimiento (SQL 28). */}
                        <input
                          style={{ width: 150 }} aria-label={`Grupo equivalente de ${p.sku}`}
                          placeholder="p. ej. FILTRO-ACEITE-P554407"
                          value={'grupo_equivalente' in ed ? ed.grupo_equivalente : (p.grupo_equivalente ?? '')}
                          onChange={e => editar(p.id, 'grupo_equivalente', e.target.value)}
                        />
                      </td>
                      <td>
                        {editando[p.id] && <button className="btn-primario" onClick={() => guardarFila(p)}>Guardar</button>}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>

          <details className="tarjeta">
            <summary className="resumen">＋ Agregar producto</summary>
            <form onSubmit={guardarProducto} style={{ maxWidth: 520, marginTop: 12 }}>
              <label className="campo"><span>SKU *</span>
                <input value={nuevo.sku} onChange={e => setNuevo({ ...nuevo, sku: e.target.value })} /></label>
              <label className="campo"><span>Categoría</span>
                <select value={nuevo.categoria} onChange={e => setNuevo({ ...nuevo, categoria: e.target.value })}>
                  {CATEGORIAS.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
                </select></label>
              <label className="campo"><span>Nombre *</span>
                <input value={nuevo.nombre} onChange={e => setNuevo({ ...nuevo, nombre: e.target.value })} /></label>
              <label className="campo"><span>Marca</span>
                <input value={nuevo.marca} onChange={e => setNuevo({ ...nuevo, marca: e.target.value })} /></label>
              <label className="campo"><span>Modelo</span>
                <input value={nuevo.modelo} onChange={e => setNuevo({ ...nuevo, modelo: e.target.value })} /></label>
              <label className="campo"><span>Precio</span>
                <input type="number" value={nuevo.precio} onChange={e => setNuevo({ ...nuevo, precio: e.target.value })} /></label>
              <label className="campo"><span>Costo</span>
                <input type="number" value={nuevo.costo} onChange={e => setNuevo({ ...nuevo, costo: e.target.value })} /></label>
              <label className="campo"><span>Mínimo</span>
                <input type="number" value={nuevo.minimo} onChange={e => setNuevo({ ...nuevo, minimo: e.target.value })} /></label>
              <label className="campo"><span>Clave producto SAT</span>
                <input value={nuevo.clave_producto_sat} onChange={e => setNuevo({ ...nuevo, clave_producto_sat: e.target.value })} /></label>
              <label className="campo"><span>Clave unidad SAT</span>
                <input value={nuevo.clave_unidad_sat} onChange={e => setNuevo({ ...nuevo, clave_unidad_sat: e.target.value })} /></label>
              <label className="campo"><span>Descripción</span>
                <textarea rows={2} value={nuevo.descripcion} onChange={e => setNuevo({ ...nuevo, descripcion: e.target.value })} /></label>
              <button type="submit" className="btn-primario">Agregar</button>
            </form>
          </details>
        </>
      )}

      {/* ------------------------------------------------------------------ */}
      {vista === 'movimiento' && (
        <form onSubmit={guardarMovimiento} className="tarjeta" style={{ maxWidth: 520 }}>
          <label className="campo">
            <span>Producto *</span>
            <select value={mov.producto_id} onChange={e => setMov({ ...mov, producto_id: e.target.value })}>
              <option value="">— Elige el producto —</option>
              {productos.map(p => (
                <option key={p.id} value={p.id}>{p.sku} — {p.nombre}</option>
              ))}
            </select>
          </label>

          <label className="campo">
            <span>Tipo de movimiento</span>
            <select value={mov.tipo} onChange={e => setMov({ ...mov, tipo: e.target.value })}>
              {TIPOS.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
            </select>
            <span className="ayuda" style={{ fontWeight: 500 }}>{ayudaTipo}</span>
          </label>

          <label className="campo">
            <span>Cantidad *</span>
            <input type="number" inputMode="decimal" value={mov.cantidad}
              onChange={e => setMov({ ...mov, cantidad: e.target.value })} />
          </label>

          {NECESITAN_CLIENTE.includes(mov.tipo) && (
            <label className="campo">
              <span>Cliente *</span>
              <select value={mov.cliente_id} onChange={e => setMov({ ...mov, cliente_id: e.target.value })}>
                <option value="">— Elige el cliente —</option>
                {clientes.map(c => <option key={c.id} value={c.id}>{c.nombre}</option>)}
              </select>
            </label>
          )}

          <label className="campo">
            <span>Referencia</span>
            <input placeholder="Factura, remisión, orden de compra"
              value={mov.referencia} onChange={e => setMov({ ...mov, referencia: e.target.value })} />
          </label>

          <label className="campo">
            <span>Notas</span>
            <textarea rows={2} value={mov.notas} onChange={e => setMov({ ...mov, notas: e.target.value })} />
          </label>

          <button type="submit" className="btn-primario btn-grande">Registrar movimiento</button>

          <p className="ayuda" style={{ marginTop: 12 }}>
            Los movimientos no se editan ni se borran. Si te equivocas, lo corriges
            con otro movimiento en sentido contrario, igual que en contabilidad.
          </p>
        </form>
      )}
    </div>
  )
}
