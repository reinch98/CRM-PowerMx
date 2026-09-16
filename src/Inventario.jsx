import { useEffect, useMemo, useState } from 'react'
import { supabase } from './lib/supabase'

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
const pesos = v =>
  v == null ? '—' : Number(v).toLocaleString('es-MX', { style: 'currency', currency: 'MXN', maximumFractionDigits: 0 })

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

  const campo = { padding: 8, fontSize: 15, width: '100%', boxSizing: 'border-box' }
  const chico = { padding: 4, width: 90, textAlign: 'right' }
  const tab = activo => ({
    padding: '8px 16px', marginRight: 6, cursor: 'pointer',
    border: '1px solid #ccc', borderRadius: 6,
    background: activo ? '#333' : '#fff', color: activo ? '#fff' : '#333'
  })
  const ayuda = TIPOS.find(t => t[0] === mov.tipo)?.[2]

  return (
    <div style={{ padding: 20, fontFamily: 'system-ui' }}>
      <h2>Inventario</h2>

      <div style={{ marginBottom: 16 }}>
        <button style={tab(vista === 'existencias')} onClick={() => setVista('existencias')}>Existencias</button>
        <button style={tab(vista === 'catalogo')} onClick={() => setVista('catalogo')}>Catálogo</button>
        <button style={tab(vista === 'movimiento')} onClick={() => setVista('movimiento')}>Registrar movimiento</button>
      </div>

      {(sinPrecio > 0 || sinCosto > 0) && (
        <div style={{ padding: 10, marginBottom: 14, background: '#fff3e0', borderRadius: 6 }}>
          Faltan <strong>{sinPrecio}</strong> precios y <strong>{sinCosto}</strong> costos por capturar.
          Se editan en la pestaña Catálogo.
        </div>
      )}

      {vista !== 'movimiento' && (
        <div style={{ display: 'flex', gap: 8, marginBottom: 14, maxWidth: 560 }}>
          <select value={categoria} onChange={e => setCategoria(e.target.value)} style={campo}>
            <option value="">Todas las categorías</option>
            {CATEGORIAS.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
          </select>
          <input
            placeholder="Buscar por SKU o nombre"
            value={busqueda}
            onChange={e => setBusqueda(e.target.value)}
            style={campo}
          />
        </div>
      )}

      {error && <p style={{ color: 'crimson' }}>{error}</p>}
      {mensaje && <p style={{ color: 'green' }}>{mensaje}</p>}

      {/* ------------------------------------------------------------------ */}
      {vista === 'existencias' && (
        <>
          <p style={{ color: '#666' }}>
            Disponible = físico − apartado − resguardo. Es lo único que puedes prometer.
          </p>
          <table border="1" cellPadding="6" style={{ borderCollapse: 'collapse', fontSize: 14 }}>
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
                  <tr key={f.id} style={bajo ? { background: '#ffebee' } : undefined}>
                    <td>{f.sku}</td>
                    <td>{f.nombre}</td>
                    <td>{f.categoria}</td>
                    <td align="right">{f.fisico}</td>
                    <td align="right">{f.apartado}</td>
                    <td align="right">{f.resguardo}</td>
                    <td align="right"><strong>{f.disponible}</strong></td>
                    <td align="right">{f.minimo || '—'}</td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </>
      )}

      {/* ------------------------------------------------------------------ */}
      {vista === 'catalogo' && (
        <>
          <table border="1" cellPadding="6" style={{ borderCollapse: 'collapse', fontSize: 14, marginBottom: 28 }}>
            <thead>
              <tr>
                <th>SKU</th><th>Producto</th><th>Marca</th>
                <th>Precio</th><th>Costo</th><th>Margen</th><th>Mínimo</th><th></th>
              </tr>
            </thead>
            <tbody>
              {visibles.map(p => {
                const ed = editando[p.id] || {}
                const precio = 'precio' in ed ? num(ed.precio) : p.precio
                const costo = 'costo' in ed ? num(ed.costo) : p.costo
                const margen = precio && costo ? Math.round(((precio - costo) / precio) * 100) : null
                return (
                  <tr key={p.id} style={p.precio == null ? { background: '#fff8e1' } : undefined}>
                    <td>{p.sku}</td>
                    <td>{p.nombre}</td>
                    <td>{p.marca}</td>
                    <td>
                      <input
                        type="number" style={chico}
                        value={'precio' in ed ? ed.precio : (p.precio ?? '')}
                        onChange={e => editar(p.id, 'precio', e.target.value)}
                      />
                    </td>
                    <td>
                      <input
                        type="number" style={chico}
                        value={'costo' in ed ? ed.costo : (p.costo ?? '')}
                        onChange={e => editar(p.id, 'costo', e.target.value)}
                      />
                    </td>
                    <td align="right">{margen == null ? '—' : `${margen}%`}</td>
                    <td>
                      <input
                        type="number" style={{ ...chico, width: 60 }}
                        value={'minimo' in ed ? ed.minimo : (p.minimo ?? '')}
                        onChange={e => editar(p.id, 'minimo', e.target.value)}
                      />
                    </td>
                    <td>
                      {editando[p.id] && <button onClick={() => guardarFila(p)}>Guardar</button>}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>

          <h3>Agregar producto</h3>
          <form onSubmit={guardarProducto} style={{ display: 'grid', gap: 8, maxWidth: 420 }}>
            <label>SKU *<input value={nuevo.sku} onChange={e => setNuevo({ ...nuevo, sku: e.target.value })} style={campo} /></label>
            <label>
              Categoría
              <select value={nuevo.categoria} onChange={e => setNuevo({ ...nuevo, categoria: e.target.value })} style={campo}>
                {CATEGORIAS.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
              </select>
            </label>
            <label>Nombre *<input value={nuevo.nombre} onChange={e => setNuevo({ ...nuevo, nombre: e.target.value })} style={campo} /></label>
            <label>Marca<input value={nuevo.marca} onChange={e => setNuevo({ ...nuevo, marca: e.target.value })} style={campo} /></label>
            <label>Modelo<input value={nuevo.modelo} onChange={e => setNuevo({ ...nuevo, modelo: e.target.value })} style={campo} /></label>
            <label>Precio<input type="number" value={nuevo.precio} onChange={e => setNuevo({ ...nuevo, precio: e.target.value })} style={campo} /></label>
            <label>Costo<input type="number" value={nuevo.costo} onChange={e => setNuevo({ ...nuevo, costo: e.target.value })} style={campo} /></label>
            <label>Mínimo<input type="number" value={nuevo.minimo} onChange={e => setNuevo({ ...nuevo, minimo: e.target.value })} style={campo} /></label>
            <label>Clave producto SAT<input value={nuevo.clave_producto_sat} onChange={e => setNuevo({ ...nuevo, clave_producto_sat: e.target.value })} style={campo} /></label>
            <label>Clave unidad SAT<input value={nuevo.clave_unidad_sat} onChange={e => setNuevo({ ...nuevo, clave_unidad_sat: e.target.value })} style={campo} /></label>
            <label>Descripción<textarea rows={2} value={nuevo.descripcion} onChange={e => setNuevo({ ...nuevo, descripcion: e.target.value })} style={campo} /></label>
            <button type="submit">Agregar</button>
          </form>
        </>
      )}

      {/* ------------------------------------------------------------------ */}
      {vista === 'movimiento' && (
        <form onSubmit={guardarMovimiento} style={{ display: 'grid', gap: 10, maxWidth: 480 }}>
          <label>
            Producto *
            <select value={mov.producto_id} onChange={e => setMov({ ...mov, producto_id: e.target.value })} style={campo}>
              <option value="">— Elige el producto —</option>
              {productos.map(p => (
                <option key={p.id} value={p.id}>{p.sku} — {p.nombre}</option>
              ))}
            </select>
          </label>

          <label>
            Tipo de movimiento
            <select value={mov.tipo} onChange={e => setMov({ ...mov, tipo: e.target.value })} style={campo}>
              {TIPOS.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
            </select>
            <small style={{ color: '#666' }}>{ayuda}</small>
          </label>

          <label>
            Cantidad *
            <input
              type="number" inputMode="decimal"
              value={mov.cantidad}
              onChange={e => setMov({ ...mov, cantidad: e.target.value })}
              style={campo}
            />
          </label>

          {NECESITAN_CLIENTE.includes(mov.tipo) && (
            <label>
              Cliente *
              <select value={mov.cliente_id} onChange={e => setMov({ ...mov, cliente_id: e.target.value })} style={campo}>
                <option value="">— Elige el cliente —</option>
                {clientes.map(c => <option key={c.id} value={c.id}>{c.nombre}</option>)}
              </select>
            </label>
          )}

          <label>
            Referencia
            <input
              placeholder="Factura, remisión, orden de compra"
              value={mov.referencia}
              onChange={e => setMov({ ...mov, referencia: e.target.value })}
              style={campo}
            />
          </label>

          <label>
            Notas
            <textarea rows={2} value={mov.notas} onChange={e => setMov({ ...mov, notas: e.target.value })} style={campo} />
          </label>

          <button type="submit" style={{ padding: 12, fontSize: 16 }}>Registrar movimiento</button>

          <p style={{ color: '#666', fontSize: 13 }}>
            Los movimientos no se editan ni se borran. Si te equivocas, lo corriges
            con otro movimiento en sentido contrario, igual que en contabilidad.
          </p>
        </form>
      )}
    </div>
  )
}
