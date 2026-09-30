// Convierte las filas de una hoja (arreglos, la primera es el encabezado) al formato que
// espera `sync_recibir_lote`. Es puro: sin archivos ni red, así se prueba en Node.
//
// Formato de salida, uno por producto del proveedor:
//   { sku_proveedor, nombre, categoria, marca, modelo, costo, moneda,
//     stock_local, stock_proveedor, tiempo_entrega_dias, url_imagen, documentos }
// `costo` es lo que el proveedor le cobra a PowerMx (no el precio de lista).

const sinAcentos = (t) => String(t ?? '').normalize('NFD').replace(/\p{M}/gu, '')
const clave = (t) => sinAcentos(t).toLowerCase().replace(/\s+/g, ' ').trim()

// Cada campo acepta varios encabezados posibles; gana el primero que exista en la hoja.
// El "costo" de XLStore es la columna "Tu precio (USD)"; el precio de lista NO se usa.
export const ALIAS = {
  sku_proveedor: ['codigo', 'sku', 'sku proveedor', 'sku_proveedor'],
  nombre: ['descripcion', 'nombre'],
  categoria: ['categoria'],
  marca: ['marca'],
  modelo: ['modelo'],
  costo: ['tu precio (usd)', 'costo', 'precio proveedor', 'tu precio'],
  moneda: ['moneda'],
  stock_local: ['stock local mid', 'stock local'],
  stock_proveedor: ['stock nacional', 'stock proveedor'],
  tiempo_entrega_dias: ['tiempo de entrega (dias)', 'tiempo_entrega_dias'],
  url_imagen: ['imagen', 'url imagen'],
  ficha_tecnica: ['ficha tecnica'],
  manual: ['manual de usuario', 'manual'],
  certificado: ['certificado'],
  garantia: ['garantia'],
  otros: ['otros documentos tecnicos'],
}

// Si no hay columna "Moneda", se deduce del encabezado del costo ("(USD)") o de la opción.
function monedaPorEncabezado(encabezado) {
  const t = clave(encabezado)
  if (t.includes('usd')) return 'USD'
  if (t.includes('mxn')) return 'MXN'
  return null
}

const numero = (v) => {
  if (v === null || v === undefined || v === '') return null
  const n = typeof v === 'number' ? v : Number(String(v).replace(/[$,\s]/g, ''))
  return Number.isFinite(n) ? n : NaN
}

const lista = (v) =>
  String(v ?? '').split(/\r?\n/).map((s) => s.trim()).filter(Boolean)

const CAMPOS_DOCUMENTO = ['ficha_tecnica', 'manual', 'certificado', 'garantia', 'otros']

/**
 * @param {Array<Array<any>>} filas  hoja completa; la primera fila es el encabezado
 * @param {{monedaPorOmision?: 'USD'|'MXN'}} [opciones]
 * @returns {{filas: object[], avisos: string[]}}  lanza Error si el archivo no sirve
 */
export function normalizarHoja(filas, opciones = {}) {
  if (!Array.isArray(filas) || filas.length < 2) {
    throw new Error('La hoja está vacía o no trae encabezado.')
  }
  const encabezado = filas[0].map(clave)
  const col = {}
  for (const [campo, alias] of Object.entries(ALIAS)) {
    const i = alias.map(clave).map((a) => encabezado.indexOf(a)).find((n) => n >= 0)
    col[campo] = i ?? -1
  }
  if (col.sku_proveedor < 0) throw new Error('Falta la columna del código del producto en la hoja.')
  if (col.costo < 0) throw new Error('Falta la columna de costo en la hoja.')

  const monedaBase = opciones.monedaPorOmision || monedaPorEncabezado(filas[0][col.costo])
  if (col.moneda < 0 && !monedaBase) {
    throw new Error('No se sabe la moneda del costo: agrega una columna "Moneda" o indica --moneda.')
  }

  const avisos = []
  const vistos = new Set()
  const salida = []
  filas.slice(1).forEach((f, n) => {
    const celda = (campo) => (col[campo] >= 0 ? f[col[campo]] : null)
    const sku = String(celda('sku_proveedor') ?? '').trim()
    if (!sku) return // renglón vacío al final de la hoja
    if (vistos.has(sku)) throw new Error(`Código repetido en la hoja: ${sku} (renglón ${n + 2}).`)
    vistos.add(sku)

    const costo = numero(celda('costo'))
    if (Number.isNaN(costo)) throw new Error(`Costo inválido en ${sku}: "${celda('costo')}".`)
    if (costo !== null && costo < 0) throw new Error(`Costo negativo en ${sku}.`)
    if (costo === null) avisos.push(`${sku}: sin costo (probablemente "cotizar" en el proveedor).`)

    const moneda = String(celda('moneda') ?? '').trim().toUpperCase() || monedaBase
    if (!['USD', 'MXN'].includes(moneda)) throw new Error(`Moneda inválida en ${sku}: "${moneda}".`)

    const entero = (campo) => {
      const v = numero(celda(campo))
      if (Number.isNaN(v)) throw new Error(`${campo} inválido en ${sku}.`)
      return v === null ? null : Math.round(v)
    }
    const documentos = {}
    for (const campo of CAMPOS_DOCUMENTO) {
      const urls = lista(celda(campo))
      if (urls.length) documentos[campo] = [...new Set(urls)]
    }
    const texto = (campo) => String(celda(campo) ?? '').trim() || null

    salida.push({
      sku_proveedor: sku,
      nombre: texto('nombre'),
      categoria: texto('categoria'),
      marca: texto('marca'),
      modelo: texto('modelo'),
      costo,
      moneda,
      stock_local: entero('stock_local'),
      stock_proveedor: entero('stock_proveedor'),
      tiempo_entrega_dias: entero('tiempo_entrega_dias'),
      url_imagen: texto('url_imagen'),
      documentos,
    })
  })
  if (!salida.length) throw new Error('La hoja no trae ningún producto.')
  return { filas: salida, avisos }
}
