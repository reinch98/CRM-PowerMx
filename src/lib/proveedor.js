// Pantalla "Proveedor": aprobar lo que el sync no publica solo, vincular productos del CRM con
// los de cada proveedor, y capturar las reglas de margen (SQL 44 y 51).
//
// Las reglas puras van arriba (probadas en pruebas/proveedor-pantalla.prueba.js); las llamadas a
// la base, abajo. Aquí NO se calcula ningún precio: el precio lo calcula la base
// (`_precio_venta`) y esta pantalla solo lo muestra. Una segunda fórmula en JS podría dar otro
// número, y el admin aprobaría uno que la base no va a publicar.
import { supabase } from './supabase'
import { explicarError } from './errores'

// Proveedores que entran por el sync (SQL 51). Un producto puede tener un código en cada uno: su costo
// es el del más barato (la "opción 1", a quien se le compra) y su precio publicado, el del más caro.
export const PROVEEDORES = [['xlstore', 'XLStore (Exel Solar)'], ['solarama', 'Solarama']]
const NOMBRE_PROVEEDOR = Object.fromEntries(PROVEEDORES)
export const nombreProveedor = clave => NOMBRE_PROVEEDOR[clave] || clave || 'Proveedor'

// ---- reglas puras ----

export const ETIQUETA_TIPO = {
  sku_desaparecido: 'Ya no lo lista el proveedor',
  cambio_precio: 'Cambio de precio fuerte',
  precio_inicial: 'Primer precio',
  sin_regla: 'Falta una regla de margen',
  sin_costo: 'El proveedor no da costo',
}

// Los que se pueden aprobar. `sin_regla` y `sin_costo` no: no hay qué aprobar, hay que arreglar la
// causa (capturar la regla, o esperar a que el proveedor dé un costo) y volver a sincronizar.
export const TIPOS_APROBABLES = ['sku_desaparecido', 'cambio_precio', 'precio_inicial']

export const esAprobable = tipo => TIPOS_APROBABLES.includes(tipo)

// Lo que más urge primero: un producto que dejó de existir, luego un salto de precio.
const PESO_TIPO = { sku_desaparecido: 0, cambio_precio: 1, precio_inicial: 2, sin_regla: 3, sin_costo: 4 }

export function ordenarCola(lista) {
  return [...(lista || [])].sort((a, b) =>
    (PESO_TIPO[a.tipo] ?? 9) - (PESO_TIPO[b.tipo] ?? 9) ||
    String(a.detalle?.nombre || a.productos?.nombre || '').localeCompare(String(b.detalle?.nombre || b.productos?.nombre || ''), 'es'))
}

export function contarPorTipo(lista) {
  const cuenta = {}
  for (const q of lista || []) cuenta[q.tipo] = (cuenta[q.tipo] || 0) + 1
  return cuenta
}

const num = v => {
  const n = Number(v)
  return Number.isFinite(n) ? n : null
}

export const pesos = n =>
  num(n) === null ? '—' : num(n).toLocaleString('es-MX', { style: 'currency', currency: 'MXN' })

// El cambio de un renglón de la cola, en datos listos para pintar. `antes` y `despues` van como
// texto; `variacion` lleva signo y palabra para que no dependa del color.
export function detalleDeCambio(q) {
  const d = q?.detalle || {}
  const antes = num(d.precio_actual ?? q?.productos?.precio)
  const despues = num(d.precio)
  const filas = []
  if (q?.tipo === 'cambio_precio' || q?.tipo === 'precio_inicial') {
    filas.push({ etiqueta: 'Precio ahora', valor: antes && antes > 0 ? pesos(antes) : 'Sin precio' })
    filas.push({ etiqueta: 'Precio nuevo', valor: pesos(despues) })
    if (num(d.costo_mxn) !== null) {
      filas.push({ etiqueta: d.proveedor ? 'Costo (opción 1, el más barato)' : 'Costo del proveedor',
        valor: d.proveedor ? `${pesos(d.costo_mxn)} · ${nombreProveedor(d.proveedor)}` : pesos(d.costo_mxn) })
    }
    // Repetido en dos proveedores: el precio se calcula con el más caro (decisión de Caña, SQL 51).
    if (d.proveedor_precio && d.proveedor_precio !== d.proveedor && num(d.costo_alto_mxn) !== null) {
      filas.push({ etiqueta: 'Precio calculado con', valor: `${pesos(d.costo_alto_mxn)} · ${nombreProveedor(d.proveedor_precio)}` })
    }
    if (num(d.margen_pct) !== null) filas.push({ etiqueta: 'Margen de la regla', valor: textoDeMargen(d.margen_pct, d.margen_sobre) })
    const v = num(d.variacion_pct)
    if (v !== null && antes && despues !== null) {
      filas.push({ etiqueta: 'Variación', valor: `${despues >= antes ? 'Sube' : 'Baja'} ${v} %` })
    }
  } else if (q?.tipo === 'sku_desaparecido') {
    if (num(d.precio_actual) !== null) filas.push({ etiqueta: 'Precio publicado', valor: pesos(d.precio_actual) })
  }
  return filas
}

// Qué pasa si se aprueba y qué hacer si no se puede.
export function explicacion(tipo) {
  switch (tipo) {
    case 'cambio_precio':
      return 'Al aprobar se recalcula con el costo y el tipo de cambio más recientes, y ese precio se publica.'
    case 'precio_inicial':
      return 'El producto todavía no tenía precio. Al aprobar se publica el que dan las reglas.'
    case 'sku_desaparecido':
      return 'Al aprobar, el producto se retira del sitio (no se borra). Al descartar, se queda como está.'
    case 'sin_regla':
      return 'No hay una regla de margen para este producto. Captura una en "Reglas de margen" y vuelve a sincronizar.'
    case 'sin_costo':
      return 'El proveedor no dio costo (suele ser "cotizar"). No se puede calcular precio hasta que lo dé.'
    default:
      return ''
  }
}

// ---- reglas de margen ----

export const CATEGORIAS = [
  ['generador', 'Generadores'], ['panel', 'Paneles'], ['bateria', 'Baterías'],
  ['refaccion', 'Refacciones'], ['paquete_solar', 'Paquetes solares'], ['renta', 'Rentas'],
  ['inversor', 'Inversores'], ['accesorio_solar', 'Accesorios solares'],
]
const NOMBRE_CATEGORIA = Object.fromEntries(CATEGORIAS)

export function alcanceDeRegla(r) {
  const cat = r?.categoria ? (NOMBRE_CATEGORIA[r.categoria] || r.categoria) : null
  if (cat && r?.marca) return `${cat} de ${r.marca}`
  if (cat) return cat
  if (r?.marca) return `Todo lo de ${r.marca}`
  return 'Todos los productos (regla general)'
}

// "30 % del precio de venta (= 42.9 % sobre el costo)" · "35 % sobre el costo". El equivalente se
// muestra porque 30 % sobre el precio NO es lo mismo que 30 % sobre el costo, y es fácil confundirlos.
export function textoDeMargen(pct, sobre) {
  const p = pct === null || pct === undefined || pct === '' ? null : num(pct)
  if (p === null) return '—'
  if (sobre !== 'precio') return `${p} % sobre el costo`
  const equivalente = p < 100 ? Math.round((p / (100 - p)) * 1000) / 10 : null
  return `${p} % del precio de venta` + (equivalente === null ? '' : ` (= ${equivalente} % sobre el costo)`)
}

export function textoDeRegla(r) {
  const partes = [textoDeMargen(r?.margen_pct, r?.sobre)]
  if (Number(r?.margen_minimo_mxn) > 0) partes.push(`mínimo ${pesos(r.margen_minimo_mxn)}`)
  partes.push(`redondeo hacia arriba a ${pesos(r?.redondeo)}`)
  return partes.join(' · ')
}

// La más específica se lista primero: así se ve qué regla le toca a un producto.
export function ordenarReglas(lista) {
  const peso = r => (r.marca ? 2 : 0) + (r.categoria ? 1 : 0)
  return [...(lista || [])].sort((a, b) =>
    Number(b.activo) - Number(a.activo) || peso(b) - peso(a) ||
    alcanceDeRegla(a).localeCompare(alcanceDeRegla(b), 'es'))
}

export const reglaVacia = { categoria: '', marca: '', margen_pct: '', margen_minimo_mxn: '0', redondeo: '1', sobre: 'costo' }

// La regla con la que se arranca: 30 % sobre el costo a todos los productos, sin mínimo y al peso
// (Caña, 01/10/2026: "el margen es sobre el costo"; antes fue 35 %). Es un punto de partida: se edita o
// se apaga aquí mismo, y una regla por marca o categoría le gana.
export const MARGEN_INICIAL_PCT = 30
export const reglaInicial = { ...reglaVacia, margen_pct: String(MARGEN_INICIAL_PCT), sobre: 'costo' }

// Convierte lo escrito en el formulario a lo que acepta la tabla. Un texto vacío va como null:
// null significa "cualquiera", y una cadena vacía nunca coincidiría con nada.
export function validarRegla(f) {
  const errores = []
  const margen = f.margen_pct === '' ? null : num(f.margen_pct)
  const minimo = f.margen_minimo_mxn === '' ? 0 : num(f.margen_minimo_mxn)
  const redondeo = f.redondeo === '' ? null : num(f.redondeo)
  if (margen === null || margen < 0) errores.push('El margen debe ser un número de 0 en adelante.')
  if (minimo === null || minimo < 0) errores.push('El margen mínimo no puede ser negativo.')
  if (redondeo === null || redondeo <= 0) errores.push('El redondeo debe ser mayor que cero (1 = al peso).')
  const sobre = f.sobre === 'precio' ? 'precio' : 'costo'
  if (sobre === 'precio' && margen !== null && margen >= 100) {
    errores.push('Sobre el precio de venta el margen tiene que ser menor que 100 %.')
  }
  if (errores.length) return { ok: false, errores }
  return {
    ok: true,
    regla: {
      categoria: String(f.categoria || '').trim() || null,
      marca: String(f.marca || '').trim() || null,
      margen_pct: margen, margen_minimo_mxn: minimo, redondeo, sobre,
    },
  }
}

// ---- vínculos ----

export function estadoDeVinculo(p) {
  if (!p?.proveedor_sku && !(p?.producto_proveedores || []).length) return 'sin_vincular'
  return p.precio_auto ? 'automatico' : 'vinculado'
}

// Los proveedores de un producto en el orden en que se le compra: la opción 1 primero. Uno recién
// ligado (sin opción todavía, hasta la próxima sincronización) va al final.
export function proveedoresDe(p) {
  return [...(p?.producto_proveedores || [])].sort((a, b) =>
    (a.opcion ?? 99) - (b.opcion ?? 99) || String(a.proveedor).localeCompare(String(b.proveedor)))
}

// Los proveedores que todavía se le pueden agregar a un producto.
export const proveedoresLibres = p =>
  PROVEEDORES.map(([k]) => k).filter(k => !(p?.producto_proveedores || []).some(l => l.proveedor === k))
export const ETIQUETA_VINCULO = {
  sin_vincular: 'Sin vincular', vinculado: 'Vinculado, precio manual', automatico: 'Precio automático',
}

// Quita lo que rompería el filtro `or(...)` de PostgREST (comas, paréntesis, comodines).
export function patronDeBusqueda(texto) {
  return String(texto || '').replace(/[%,()*\\]/g, ' ').replace(/\s+/g, ' ').trim()
}

// Lo que se puede traer del proveedor, y cuántos productos serían. Solo cuenta lo marcado y lo que
// tiene categoría equivalente en el CRM: lo demás no se importa.
export function totalPorTraer(resumen, marcadas) {
  return (resumen || [])
    .filter(c => c.equivale && marcadas.includes(c.categoria))
    .reduce((suma, c) => suma + Number(c.por_traer || 0), 0)
}

export const nombreCategoriaCRM = cat => NOMBRE_CATEGORIA[cat] || cat

// Cuántos de los vinculados de una categoría todavía no siguen el precio del proveedor.
export const faltanConPrecioAuto = c => Math.max(0, Number(c?.total || 0) - Number(c?.con_auto || 0))

// Días después de los cuales una lista se avisa como vieja (Solarama manda la suya cada ~5 meses).
export const DIAS_LISTA_VIEJA = 150

export function textoDeCorrida(c, hoy = new Date()) {
  if (!c) return null
  const cuando = new Date(c.iniciada_en).toLocaleString('es-MX', { dateStyle: 'short', timeStyle: 'short' })
  const quien = nombreProveedor(c.proveedor)
  if (c.estado === 'aplicada') {
    const r = c.resumen || {}
    const texto = `${quien}, última lectura ${cuando}: ${c.filas ?? 0} productos; ${r.aplicados ?? 0} precios aplicados, ${r.en_revision ?? 0} esperando aprobación.`
    const dias = Math.floor((hoy - new Date(c.iniciada_en)) / 86400000)
    if (dias > DIAS_LISTA_VIEJA) {
      return { tipo: 'aviso', texto: `${texto} La lista ya tiene ${dias} días: pide la nueva.` }
    }
    return { tipo: 'ok', texto }
  }
  if (c.estado === 'fallida') {
    return { tipo: 'error', texto: `${quien}: la última lectura (${cuando}) falló y no se aplicó nada: ${c.error || 'sin detalle'}` }
  }
  return { tipo: 'aviso', texto: `${quien}: una lectura (${cuando}) quedó a medias (${c.estado}).` }
}

// De las lecturas más recientes, la última de cada proveedor (en el orden de PROVEEDORES).
export function ultimaPorProveedor(corridas) {
  const vistas = {}
  for (const c of [...(corridas || [])].sort((a, b) => String(b.iniciada_en).localeCompare(String(a.iniciada_en)))) {
    if (!vistas[c.proveedor]) vistas[c.proveedor] = c
  }
  return PROVEEDORES.map(([k]) => vistas[k]).filter(Boolean)
}

// ---- promociones (SQL 52) ----

// Cuánto baja la promoción contra el precio normal, en % entero; null si no baja.
export function descuentoDe(precio, promocion) {
  const p = num(precio)
  const q = promocion === null || promocion === undefined ? null : num(promocion)
  if (!p || p <= 0 || q === null || q <= 0 || q >= p) return null
  return Math.round((1 - q / p) * 100)
}

// Los de promoción, el descuento más grande primero.
export function ordenarPromociones(lista) {
  return [...(lista || [])].sort((a, b) =>
    (descuentoDe(b.precio, b.precio_promocion) ?? 0) - (descuentoDe(a.precio, a.precio_promocion) ?? 0) ||
    String(a.nombre).localeCompare(String(b.nombre), 'es'))
}

// Los parámetros de la promoción van aparte de los del costeo de paquetes en la pantalla Precios.
export const esParametroDePromocion = p => String(p?.clave || '').startsWith('promo_')

// ---- parámetros de costeo (mano de obra, trámites, metros incluidos; SQL 51) ----

// Lo escrito en el campo, como número de 0 en adelante; null si no sirve.
export function valorDeParametro(texto) {
  const t = String(texto ?? '').replace(/[$,\s]/g, '')
  if (t === '') return null
  const n = Number(t)
  return Number.isFinite(n) && n >= 0 ? n : null
}

// ---- llamadas ----

function textoDeError(error) {
  const codigo = String(error?.code || '')
  if (codigo === '23505') return 'Ya hay una regla activa para esa combinación de categoría y marca.'
  if (['22023', '23514', '42501', 'P0001'].includes(codigo) && error?.message) return error.message
  return explicarError(error).texto
}

async function llamar(fn) {
  try {
    const r = await fn()
    if (r.error) return { ok: false, texto: textoDeError(r.error) }
    return { ok: true, datos: r.data, total: r.count }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

export const cargarCola = () => llamar(() => supabase.from('cola_revision')
  .select('*, productos(sku, nombre, precio, marca)')
  .eq('estado', 'pendiente').limit(1000))

export const resolverRevision = (id, aprobar, nota) =>
  llamar(() => supabase.rpc('resolver_revision', { p_id: id, p_aprobar: aprobar, p_nota: nota || null }))

export const resolverEnLote = (tipo, aprobar) =>
  llamar(() => supabase.rpc('resolver_revisiones', { p_tipo: tipo, p_aprobar: aprobar }))

export const cargarUltimasCorridas = () => llamar(() => supabase.from('sync_corridas')
  .select('*').order('iniciada_en', { ascending: false }).limit(20))

export const cargarReglas = () => llamar(() => supabase.from('reglas_margen').select('*'))

export const guardarRegla = (id, regla) => llamar(() => id
  ? supabase.from('reglas_margen').update(regla).eq('id', id)
  : supabase.from('reglas_margen').insert(regla))

export const cambiarActivaRegla = (id, activo) =>
  llamar(() => supabase.from('reglas_margen').update({ activo }).eq('id', id))

// El catálogo del CRM ya pasa de mil productos y Supabase corta en mil: se busca en el servidor y se
// traen solo los primeros 60. El total viene del conteo exacto, no de lo mostrado.
export const LIMITE_VINCULOS = 60

export async function buscarProductosCRM({ texto, soloSin }) {
  const t = patronDeBusqueda(texto)
  const p = await llamar(() => {
    let q = supabase.from('productos')
      .select('id, sku, nombre, categoria, marca, modelo, precio, costo, proveedor, proveedor_sku, precio_auto, ' +
        'producto_proveedores(proveedor, proveedor_sku, opcion, costo_mxn)', { count: 'exact' })
      .eq('activo', true)
    if (soloSin) q = q.is('proveedor_sku', null)
    if (t) q = q.or(['sku', 'nombre', 'marca', 'modelo', 'proveedor_sku'].map(c => `${c}.ilike.%${t}%`).join(','))
    return q.order('sku').limit(LIMITE_VINCULOS)
  })
  if (!p.ok) return p
  // Lo que dijo cada proveedor de cada código ligado (costo, existencias, si lo sigue listando).
  const lecturas = {}
  for (const [prov] of PROVEEDORES) {
    const skus = [...new Set(p.datos.flatMap(x => (x.producto_proveedores || [])
      .filter(l => l.proveedor === prov).map(l => l.proveedor_sku)))]
    if (!skus.length) continue
    const l = await llamar(() => supabase.from('proveedor_productos')
      .select('proveedor, sku_proveedor, costo, moneda, stock_local, vigente')
      .eq('proveedor', prov).in('sku_proveedor', skus))
    if (!l.ok) return l
    for (const x of l.datos) lecturas[`${x.proveedor}|${x.sku_proveedor}`] = x
  }
  return { ok: true, productos: p.datos, total: p.total ?? p.datos.length, lecturas }
}

export const cargarResumenProveedor = proveedor =>
  llamar(() => supabase.rpc('proveedor_resumen', { p_proveedor: proveedor }))

export const importarProductos = (categorias, proveedor) =>
  llamar(() => supabase.rpc('importar_productos_proveedor', { p_proveedor: proveedor, p_categorias: categorias }))

export const activarPrecioAutomatico = (categoria, proveedor) =>
  llamar(() => supabase.rpc('activar_precio_automatico', { p_proveedor: proveedor, p_categoria: categoria }))

export const buscarEnProveedor = (texto, proveedor) => {
  const t = patronDeBusqueda(texto)
  return llamar(() => supabase.from('proveedor_productos')
    .select('sku_proveedor, nombre, marca, modelo, costo, moneda, stock_local')
    .eq('proveedor', proveedor).eq('vigente', true)
    .or(['sku_proveedor', 'nombre', 'modelo', 'marca'].map(c => `${c}.ilike.%${t}%`).join(','))
    .order('sku_proveedor').limit(15))
}

// `sku` null quita a ESE proveedor. `precioAuto` es el interruptor del producto: al agregar un segundo
// proveedor se manda el que ya tenía, para no apagarlo.
export const vincularProducto = (productoId, sku, precioAuto, proveedor) =>
  llamar(() => supabase.rpc('vincular_producto_proveedor', {
    p_producto: productoId, p_proveedor: proveedor, p_sku: sku, p_precio_auto: !!precioAuto,
  }))

export const cargarPromociones = () => llamar(() => supabase.from('productos')
  .select('id, sku, nombre, marca, precio, costo, precio_promocion, publicar, proveedor, ' +
    'producto_proveedores(proveedor, proveedor_sku, opcion, costo_mxn)')
  .not('precio_promocion', 'is', null).eq('activo', true).limit(500))

export const cargarParametrosCosteo = () =>
  llamar(() => supabase.from('parametros_costeo').select('*').order('orden'))

export const fijarParametroCosteo = (clave, valor) =>
  llamar(() => supabase.rpc('fijar_parametro_costeo', { p_clave: clave, p_valor: valor }))
