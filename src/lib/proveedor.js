// Pantalla "Proveedor": aprobar lo que el sync no publica solo, vincular productos del CRM con
// los del proveedor, y capturar las reglas de margen (SQL 44).
//
// Las reglas puras van arriba (probadas en pruebas/proveedor-pantalla.prueba.js); las llamadas a
// la base, abajo. Aquí NO se calcula ningún precio: el precio lo calcula la base
// (`_precio_venta`) y esta pantalla solo lo muestra. Una segunda fórmula en JS podría dar otro
// número, y el admin aprobaría uno que la base no va a publicar.
import { supabase } from './supabase'
import { explicarError } from './errores'

export const PROVEEDOR = 'xlstore'

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
    if (num(d.costo_mxn) !== null) filas.push({ etiqueta: 'Costo del proveedor', valor: pesos(d.costo_mxn) })
    if (num(d.margen_pct) !== null) filas.push({ etiqueta: 'Margen de la regla', valor: `${d.margen_pct} %` })
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

export function textoDeRegla(r) {
  const partes = [`${Number(r?.margen_pct)} % de margen`]
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

export const reglaVacia = { categoria: '', marca: '', margen_pct: '', margen_minimo_mxn: '0', redondeo: '1' }

// La regla con la que se arranca (pedido de Caña, 30/09/2026): 35 % a todos los productos, sin mínimo
// y al peso. Es un punto de partida, no una decisión: se edita o se apaga desde la misma pantalla, y
// una regla más específica (por marca o categoría) le gana.
export const MARGEN_INICIAL_PCT = 35
export const reglaInicial = { ...reglaVacia, margen_pct: String(MARGEN_INICIAL_PCT) }

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
  if (errores.length) return { ok: false, errores }
  return {
    ok: true,
    regla: {
      categoria: String(f.categoria || '').trim() || null,
      marca: String(f.marca || '').trim() || null,
      margen_pct: margen, margen_minimo_mxn: minimo, redondeo,
    },
  }
}

// ---- vínculos ----

export function estadoDeVinculo(p) {
  if (!p?.proveedor_sku) return 'sin_vincular'
  return p.precio_auto ? 'automatico' : 'vinculado'
}
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

export function textoDeCorrida(c) {
  if (!c) return null
  const cuando = new Date(c.iniciada_en).toLocaleString('es-MX', { dateStyle: 'short', timeStyle: 'short' })
  if (c.estado === 'aplicada') {
    const r = c.resumen || {}
    return { tipo: 'ok', texto: `Última lectura ${cuando}: ${c.filas ?? 0} productos; ${r.aplicados ?? 0} precios aplicados, ${r.en_revision ?? 0} esperando aprobación.` }
  }
  if (c.estado === 'fallida') {
    return { tipo: 'error', texto: `La última lectura (${cuando}) falló y no se aplicó nada: ${c.error || 'sin detalle'}` }
  }
  return { tipo: 'aviso', texto: `Una lectura (${cuando}) quedó a medias (${c.estado}).` }
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

export const cargarUltimaCorrida = () => llamar(() => supabase.from('sync_corridas')
  .select('*').eq('proveedor', PROVEEDOR).order('iniciada_en', { ascending: false }).limit(1))

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
      .select('id, sku, nombre, categoria, marca, modelo, precio, costo, proveedor, proveedor_sku, precio_auto', { count: 'exact' })
      .eq('activo', true)
    if (soloSin) q = q.is('proveedor_sku', null)
    if (t) q = q.or(['sku', 'nombre', 'marca', 'modelo', 'proveedor_sku'].map(c => `${c}.ilike.%${t}%`).join(','))
    return q.order('sku').limit(LIMITE_VINCULOS)
  })
  if (!p.ok) return p
  const skus = [...new Set(p.datos.map(x => x.proveedor_sku).filter(Boolean))]
  let lecturas = []
  if (skus.length) {
    const l = await llamar(() => supabase.from('proveedor_productos')
      .select('sku_proveedor, costo, moneda, stock_local, vigente')
      .eq('proveedor', PROVEEDOR).in('sku_proveedor', skus))
    if (!l.ok) return l
    lecturas = l.datos
  }
  return { ok: true, productos: p.datos, total: p.total ?? p.datos.length,
    lecturas: Object.fromEntries(lecturas.map(x => [x.sku_proveedor, x])) }
}

export const cargarResumenProveedor = () =>
  llamar(() => supabase.rpc('proveedor_resumen', { p_proveedor: PROVEEDOR }))

export const importarProductos = categorias =>
  llamar(() => supabase.rpc('importar_productos_proveedor', { p_proveedor: PROVEEDOR, p_categorias: categorias }))

export const activarPrecioAutomatico = categoria =>
  llamar(() => supabase.rpc('activar_precio_automatico', { p_proveedor: PROVEEDOR, p_categoria: categoria }))

export const buscarEnProveedor = texto => {
  const t = patronDeBusqueda(texto)
  return llamar(() => supabase.from('proveedor_productos')
    .select('sku_proveedor, nombre, marca, modelo, costo, moneda, stock_local')
    .eq('proveedor', PROVEEDOR).eq('vigente', true)
    .or(['sku_proveedor', 'nombre', 'modelo', 'marca'].map(c => `${c}.ilike.%${t}%`).join(','))
    .order('sku_proveedor').limit(15))
}

export const vincularProducto = (productoId, sku, precioAuto) =>
  llamar(() => supabase.rpc('vincular_producto_proveedor', {
    p_producto: productoId, p_proveedor: PROVEEDOR, p_sku: sku, p_precio_auto: !!precioAuto,
  }))
