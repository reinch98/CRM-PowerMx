import { useEffect, useMemo, useState } from 'react'
import { supabase } from './lib/supabase'
import { Alerta } from './ui'
import { aFormulario, paraGuardar } from './lib/formularios'
import { todasLasFilas } from './lib/paginar'

const CATEGORIAS = [
  ['generador', 'Generadores'],
  ['paquete_solar', 'Paquetes solares'],
  ['bateria', 'Baterías'],
  ['panel', 'Paneles'],
  ['refaccion', 'Refacciones'],
  ['renta', 'Rentas'],
  ['inversor', 'Inversores'],
  ['accesorio_solar', 'Accesorios solares']
]

// Campos que cambian según la categoría. Se guardan dentro de `atributos` (jsonb) con
// el MISMO nombre que ya usa el catálogo de siempre (así el sitio y `convertir.js`,
// que leen `atributos` tal cual, no necesitan tocarse). `bool: true` = casilla que se
// guarda como "si"/"no" — así lo grabó la carga original y así lo espera aBooleano()
// del lado del sitio.
const ATRIBUTOS = {
  generador: [
    ['segmento', 'Segmento'], ['combustible', 'Combustible'], ['kw', 'Potencia (kW)'],
    ['arranque', 'Arranque'], ['fase', 'Fase'], ['voltaje', 'Voltaje'],
    ['garantia_anios', 'Garantía'], ['ats', 'Incluye ATS', 'bool']
  ],
  bateria: [
    ['segmento', 'Segmento'], ['kwh', 'Capacidad (kWh)'], ['quimica', 'Química'],
    ['ciclos', 'Ciclos'], ['voltaje', 'Voltaje'], ['dod', 'DoD'], ['garantia_anios', 'Garantía']
  ],
  panel: [
    ['potencia_w', 'Potencia (W)']
  ],
  refaccion: [
    ['subcategoria', 'Subcategoría']
  ],
  renta: [
    ['kva', 'KVA'], ['combustible', 'Combustible']
  ],
  paquete_solar: [
    ['paneles', 'Número de paneles'], ['kw', 'kW instalados'],
    ['ahorro_mensual', 'Ahorro mensual estimado (texto, ej. "$600–$900")'],
    ['popular', 'Marcarlo como "Más popular"', 'bool']
  ]
}

// Las tarifas de rentas y paquetes no van en `atributos`: van en `precios` (jsonb),
// que es justo la columna pensada para "más de un precio" (ver CLAUDE.md).
const PRECIOS = {
  renta: [
    ['24hr', 'Precio 24 horas'], ['48hr', 'Precio 48 horas'], ['semana', 'Precio por semana']
  ],
  paquete_solar: [
    ['estandar', 'Precio con inversor estándar'], ['hibrido', 'Precio con inversor híbrido']
  ]
}

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

const NUMERICAS_PRODUCTO = ['precio', 'costo', 'minimo']

const vacioProducto = {
  sku: '', categoria: 'refaccion', nombre: '', marca: '', modelo: '',
  descripcion: '', precio: '', costo: '', minimo: '', unidad: 'pieza',
  clave_producto_sat: '', clave_unidad_sat: '', grupo_equivalente: '',
  activo: true, publicar: true
}

const vacioMovimiento = {
  producto_id: '', tipo: 'entrada', cantidad: '',
  cliente_id: '', referencia: '', notas: ''
}

const num = v => (v === '' || v == null ? null : Number(v))

// atributos.ats/popular se guardan como "si"/"no" (la carga original los dejó así).
// Al abrir para editar los leemos como boolean para la casilla; al guardar los
// devolvemos a "si"/"no".
const boolDeAtributo = v => v === true || v === 'si' || v === 'sí' || v === 'true'

export default function Inventario() {
  const [vista, setVista] = useState('existencias')
  const [productos, setProductos] = useState([])
  const [filas, setFilas] = useState([])       // vista disponibles
  const [clientes, setClientes] = useState([])
  const [categoria, setCategoria] = useState('')
  const [busqueda, setBusqueda] = useState('')
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState('')

  const [form, setForm] = useState(vacioProducto)
  const [atributos, setAtributos] = useState({})
  const [precios, setPrecios] = useState({})
  const [editando, setEditando] = useState(null)   // el producto completo, para el formulario grande
  const [abierto, setAbierto] = useState(false)
  const [guardando, setGuardando] = useState(false)

  const [mov, setMov] = useState(vacioMovimiento)
  const [edicionRapida, setEdicionRapida] = useState({})  // { [id]: { precio, costo, minimo, grupo_equivalente } }

  useEffect(() => { cargar() }, [])

  async function cargar() {
    const [p, d, c] = await Promise.all([
      todasLasFilas(() => supabase.from('productos').select('*').eq('activo', true).order('categoria').order('sku')),
      todasLasFilas(() => supabase.from('disponibles').select('*').order('categoria').order('sku')),
      supabase.from('clientes').select('id, nombre').order('nombre')
    ])
    if (p.error) return setError(p.error.message)
    if (d.error) return setError(d.error.message)
    setProductos(p.data || [])
    setFilas(d.data || [])
    setClientes(c.data || [])
  }

  // Borrar de verdad solo si nunca se movió; con historia se desactiva (lo decide la base).
  async function quitarProducto(p) {
    const ok = window.confirm(`¿Quitar ${p.sku} · ${p.nombre || ''}? Si nunca se movió se borra; si tiene historia solo se desactiva y deja de salir en el catálogo y el sitio.`)
    if (!ok) return
    setError(''); setMensaje('')
    const { data, error: e } = await supabase.rpc('quitar_producto', { p_producto: p.id })
    if (e) return setError(e.message)
    setMensaje(data === 'eliminado'
      ? `${p.sku} se eliminó.`
      : `${p.sku} tiene historia, así que se desactivó: ya no sale en el catálogo ni en el sitio.`)
    await cargar()
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
  // Captura rápida: edita precio, costo, mínimo y grupo directo en la lista,
  // sin abrir el formulario grande. Sigue siendo lo más rápido para lo de todos
  // los días; el formulario de abajo es para lo demás (nombre, atributos, tarifas,
  // publicar) y para dar de alta.
  // -------------------------------------------------------------------------
  function editarRapido(id, campo, valor) {
    setEdicionRapida({ ...edicionRapida, [id]: { ...(edicionRapida[id] || {}), [campo]: valor } })
  }

  async function guardarFila(p) {
    const cambios = edicionRapida[p.id]
    if (!cambios) return
    const payload = {}
    for (const campo of NUMERICAS_PRODUCTO) {
      if (campo in cambios) payload[campo] = num(cambios[campo])
    }
    // Texto, no número: la etiqueta vacía se guarda como null para no dejar equivalencias
    // fantasma que agruparían entre sí todos los productos sin grupo.
    if ('grupo_equivalente' in cambios) {
      payload.grupo_equivalente = cambios.grupo_equivalente.trim() || null
    }
    const { error } = await supabase.from('productos').update(payload).eq('id', p.id)
    if (error) return setError(error.message)
    const { [p.id]: _, ...resto } = edicionRapida
    setEdicionRapida(resto)
    setMensaje(`${p.sku} actualizado.`)
    cargar()
  }

  // -------------------------------------------------------------------------
  // Formulario grande: alta y edición completas. Mismo formulario para las dos,
  // igual que Clientes y Equipos — así un campo nuevo no se olvida en la edición.
  // -------------------------------------------------------------------------
  function cambiar(campo, valor) {
    setForm({ ...form, [campo]: valor })
  }

  function cambiarCategoria(nuevaCategoria) {
    setForm({ ...form, categoria: nuevaCategoria })
    setAtributos({})  // los atributos y tarifas de la categoría anterior ya no aplican
    setPrecios({})
  }

  function cambiarAtributo(campo, valor) {
    setAtributos({ ...atributos, [campo]: valor })
  }

  function cambiarPrecio(campo, valor) {
    setPrecios({ ...precios, [campo]: valor })
  }

  function nuevoProducto() {
    setForm(vacioProducto)
    setAtributos({})
    setPrecios({})
    setEditando(null)
    setAbierto(true)
    setError('')
  }

  function editarProducto(p) {
    setForm(aFormulario(p, vacioProducto))
    setAtributos(Object.fromEntries(
      (ATRIBUTOS[p.categoria] || []).map(([clave, , tipo]) =>
        [clave, tipo === 'bool' ? boolDeAtributo(p.atributos?.[clave]) : (p.atributos?.[clave] ?? '')])
    ))
    setPrecios(Object.fromEntries(
      (PRECIOS[p.categoria] || []).map(([clave]) => [clave, p.precios?.[clave] ?? ''])
    ))
    setEditando(p)
    setAbierto(true)
    setError('')
    window.scrollTo({ top: 0, behavior: 'smooth' })
  }

  function cancelar() {
    setForm(vacioProducto); setAtributos({}); setPrecios({}); setEditando(null); setAbierto(false); setError('')
  }

  async function guardarProducto(e) {
    e.preventDefault()
    setError(''); setMensaje('')
    if (!form.sku.trim()) return setError('El SKU es obligatorio')
    if (!form.nombre.trim()) return setError('El nombre es obligatorio')

    const payload = paraGuardar(form, { numericas: NUMERICAS_PRODUCTO })
    payload.sku = form.sku.trim()
    payload.grupo_equivalente = form.grupo_equivalente.trim() || null
    payload.minimo = payload.minimo ?? 0

    // Los atributos vacíos no se guardan; los booleanos se devuelven a "si"/"no",
    // como los dejó la carga original.
    const camposAtributos = (ATRIBUTOS[form.categoria] || [])
    const limpiosAtr = Object.fromEntries(
      camposAtributos
        .map(([clave, , tipo]) => [clave, tipo === 'bool' ? (atributos[clave] ? 'si' : 'no') : atributos[clave]])
        .filter(([, v]) => v !== '' && v != null)
    )
    // Al editar hay que conservar lo que este formulario no maneja (por si algún día
    // `atributos` guarda algo más, como pasa en equipos con las placas).
    const clavesFormulario = camposAtributos.map(([clave]) => clave)
    const ajenos = Object.fromEntries(
      Object.entries(editando?.atributos || {}).filter(([k]) => !clavesFormulario.includes(k))
    )
    payload.atributos = { ...ajenos, ...limpiosAtr }

    // `precios`: solo rentas y paquetes lo usan; en las demás categorías se queda vacío.
    const camposPrecios = PRECIOS[form.categoria] || []
    payload.precios = Object.fromEntries(
      camposPrecios
        .map(([clave]) => [clave, num(precios[clave])])
        .filter(([, v]) => v != null)
    )
    // El `precio` plano de rentas y paquetes es el que se muestra "de entrada" (24 h /
    // estándar): se sincroniza con la tarifa correspondiente para que no quede viejo si
    // solo se editan las tarifas. El formulario ni siquiera muestra el campo Precio para
    // estas dos categorías, justo para que no se pueda desincronizar a mano.
    if (form.categoria === 'renta') payload.precio = payload.precios['24hr'] ?? null
    if (form.categoria === 'paquete_solar') payload.precio = payload.precios.estandar ?? null

    setGuardando(true)
    const { error } = editando
      ? await supabase.from('productos').update(payload).eq('id', editando.id)
      : await supabase.from('productos').insert([payload])
    setGuardando(false)

    if (error) return setError(error.message)
    setMensaje(editando ? `${payload.sku} actualizado.` : 'Producto agregado.')
    cancelar()
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
  const esPaquete = form.categoria === 'paquete_solar'
  const esRentaOPaquete = form.categoria === 'renta' || esPaquete
  const atributosDeLaCategoria = ATRIBUTOS[form.categoria] || []
  const preciosDeLaCategoria = PRECIOS[form.categoria] || []

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
                  <th>Grupo equivalente</th><th>Publicado</th><th></th>
                </tr>
              </thead>
              <tbody>
                {visibles.map(p => {
                  const ed = edicionRapida[p.id] || {}
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
                          onChange={e => editarRapido(p.id, 'precio', e.target.value)}
                        />
                      </td>
                      <td>
                        <input
                          type="number" style={{ width: 110, textAlign: 'right' }} aria-label={`Costo de ${p.sku}`}
                          value={'costo' in ed ? ed.costo : (p.costo ?? '')}
                          onChange={e => editarRapido(p.id, 'costo', e.target.value)}
                        />
                      </td>
                      <td align="right">{margen == null ? '—' : `${margen}%`}</td>
                      <td>
                        <input
                          type="number" style={{ width: 90, textAlign: 'right' }} aria-label={`Mínimo de ${p.sku}`}
                          value={'minimo' in ed ? ed.minimo : (p.minimo ?? '')}
                          onChange={e => editarRapido(p.id, 'minimo', e.target.value)}
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
                          onChange={e => editarRapido(p.id, 'grupo_equivalente', e.target.value)}
                        />
                      </td>
                      <td>{p.publicar ? 'Sí' : <span className="estado estado-rechazada">No</span>}</td>
                      <td>
                        <div className="fila" style={{ gap: 6 }}>
                          {edicionRapida[p.id] && <button className="btn-primario" onClick={() => guardarFila(p)}>Guardar</button>}
                          <button onClick={() => editarProducto(p)}>Editar</button>
                          <button className="btn-peligro" onClick={() => quitarProducto(p)}>Quitar</button>
                        </div>
                      </td>
                    </tr>
                  )
                })}
                {visibles.length === 0 && (
                  <tr><td colSpan={9} className="ayuda">No hay productos con esos filtros.</td></tr>
                )}
              </tbody>
            </table>
          </div>

          <details className="tarjeta" open={abierto}>
            <summary className="resumen" onClick={e => { if (!abierto) { e.preventDefault(); nuevoProducto() } }}>
              {editando ? `Editando ${editando.sku}` : '＋ Agregar producto'}
            </summary>

            <form onSubmit={guardarProducto} style={{ maxWidth: 560, marginTop: 12, display: 'grid', gap: 12 }}>
              <label className="campo"><span>SKU *</span>
                <input value={form.sku} onChange={e => cambiar('sku', e.target.value)} /></label>

              <label className="campo"><span>Categoría</span>
                <select value={form.categoria} onChange={e => cambiarCategoria(e.target.value)}>
                  {CATEGORIAS.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
                </select>
              </label>

              <label className="campo"><span>Nombre *</span>
                <input value={form.nombre} onChange={e => cambiar('nombre', e.target.value)} /></label>

              {!esPaquete && (
                <>
                  <label className="campo"><span>Marca</span>
                    <input value={form.marca} onChange={e => cambiar('marca', e.target.value)} /></label>
                  <label className="campo"><span>Modelo</span>
                    <input value={form.modelo} onChange={e => cambiar('modelo', e.target.value)} /></label>
                </>
              )}

              <label className="campo"><span>Unidad</span>
                <input value={form.unidad} onChange={e => cambiar('unidad', e.target.value)}
                  placeholder="pieza, servicio…" /></label>

              {!esRentaOPaquete && (
                <label className="campo"><span>Precio</span>
                  <input type="number" value={form.precio} onChange={e => cambiar('precio', e.target.value)} /></label>
              )}
              {esRentaOPaquete && (
                <p className="ayuda">
                  El precio se toma solo de las tarifas, más abajo ({form.categoria === 'renta' ? 'la de 24 horas' : 'la del inversor estándar'}).
                </p>
              )}
              <label className="campo"><span>Costo</span>
                <input type="number" value={form.costo} onChange={e => cambiar('costo', e.target.value)} /></label>
              <label className="campo"><span>Mínimo</span>
                <input type="number" value={form.minimo} onChange={e => cambiar('minimo', e.target.value)} /></label>

              {!esPaquete && (
                <>
                  <label className="campo"><span>Clave producto SAT</span>
                    <input value={form.clave_producto_sat} onChange={e => cambiar('clave_producto_sat', e.target.value)} /></label>
                  <label className="campo"><span>Clave unidad SAT</span>
                    <input value={form.clave_unidad_sat} onChange={e => cambiar('clave_unidad_sat', e.target.value)} /></label>
                </>
              )}

              <label className="campo"><span>Grupo equivalente</span>
                <input value={form.grupo_equivalente} onChange={e => cambiar('grupo_equivalente', e.target.value)}
                  placeholder="p. ej. FILTRO-ACEITE-P554407" /></label>

              <label className="campo">
                <span>{esPaquete ? 'Qué incluye (una línea por elemento)' : 'Descripción'}</span>
                <textarea rows={esPaquete ? 4 : 2}
                  value={esPaquete ? form.descripcion.split('|').map(s => s.trim()).filter(Boolean).join('\n') : form.descripcion}
                  onChange={e => cambiar('descripcion', esPaquete
                    ? e.target.value.split('\n').map(s => s.trim()).filter(Boolean).join(' | ')
                    : e.target.value)} />
              </label>

              <label className="casilla">
                <input type="checkbox" checked={form.activo} onChange={e => cambiar('activo', e.target.checked)} />
                Activo
              </label>
              <label className="casilla">
                <input type="checkbox" checked={form.publicar} onChange={e => cambiar('publicar', e.target.checked)} />
                Publicar en el sitio (si tiene precio o tarifas)
              </label>

              {atributosDeLaCategoria.length > 0 && (
                <fieldset className="conjunto">
                  <legend>Datos de {CATEGORIAS.find(([v]) => v === form.categoria)?.[1].toLowerCase()}</legend>
                  {atributosDeLaCategoria.map(([campo, etiqueta, tipo]) => (
                    tipo === 'bool' ? (
                      <label key={campo} className="casilla">
                        <input type="checkbox" checked={!!atributos[campo]}
                          onChange={e => cambiarAtributo(campo, e.target.checked)} />
                        {etiqueta}
                      </label>
                    ) : (
                      <label key={campo} className="campo">
                        <span>{etiqueta}</span>
                        <input value={atributos[campo] || ''} onChange={e => cambiarAtributo(campo, e.target.value)} />
                      </label>
                    )
                  ))}
                </fieldset>
              )}

              {preciosDeLaCategoria.length > 0 && (
                <fieldset className="conjunto">
                  <legend>Tarifas</legend>
                  {preciosDeLaCategoria.map(([campo, etiqueta]) => (
                    <label key={campo} className="campo">
                      <span>{etiqueta}</span>
                      <input type="number" value={precios[campo] ?? ''} onChange={e => cambiarPrecio(campo, e.target.value)} />
                    </label>
                  ))}
                </fieldset>
              )}

              <div className="fila">
                <button type="submit" className="btn-primario" disabled={guardando}>
                  {editando ? 'Guardar cambios' : 'Agregar'}
                </button>
                {editando && <button type="button" onClick={cancelar}>Cancelar</button>}
              </div>
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
