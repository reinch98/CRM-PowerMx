// Lectura del catálogo de XLStore (Exel Solar) con una sesión YA iniciada.
//
// UNA sola pieza de código para dos usos (por eso no importa nada y recibe todo de afuera):
//   · en Node, desde `adaptadores/xlstore.js` (con la cookie de sesión de Caña y `linkedom`);
//   · en el navegador, pegada en la consola de xlstore.exelsolar.com (`xlstore-descargar.js`, que se
//     genera de ESTE archivo con `crear-herramienta.js`: no se edita a mano).
//
// XLStore no tiene API: el catálogo sale de páginas que devuelven HTML. Lo que se lee:
//   GetListProductos        tarjetas con código, modelo, nombre, marca, imagen y precios (USD)
//   GetFiltrosMarcasCategorias   id de marca → nombre (la tarjeta solo trae el logo)
//   GetExistenciaProductoGrid    existencias: local (Mérida), cedis, clever, nacional
//   GetDocumentosProducto        enlaces a fichas y manuales (opcional: es una petición por producto)
// Sin sesión no hay precios; con la sesión caída a medias, tampoco: por eso se verifica al principio y
// al final, y una lectura sin precios se RECHAZA en vez de entregarse (el CRM ya tiene su propia guardia
// de lecturas sospechosas, pero aquí se corta antes).
//
// No se salta ningún captcha: la sesión la inicia una persona.

export const BASE = 'https://xlstore.exelsolar.com'

export const CATEGORIAS = [
  ['paneles-solares', 'Paneles solares'],
  ['inversores', 'Inversores'],
  ['microinversores', 'Microinversores'],
  ['baterias-controladores-generadores', 'Baterías, controladores y generadores'],
  ['monitoreo-optimizadores-protecciones', 'Monitoreo, optimizadores y protecciones'],
  ['suministros-de-instalacion', 'Suministros de instalación'],
  ['sistemas-de-montaje', 'Sistemas de montaje'],
  ['bundles', 'Kits'],
]

// Mismas columnas (y mismo orden) que el Excel que ya consume `normalizar.js`.
export const ENCABEZADO = [
  'Código', 'Categoría', 'Marca', 'Modelo', 'Descripción', 'Precio lista (USD)', 'Tu precio (USD)',
  'USD por watt', 'Stock local MID', 'Stock CEDIS', 'Stock Clever', 'Stock nacional', 'Enlace', 'Imagen',
  'Ficha técnica', 'Manual de usuario', 'Certificado', 'Garantía', 'Otros documentos técnicos',
]

export class SesionCaducada extends Error {
  constructor(detalle) {
    super(`La sesión de XLStore no está activa${detalle ? ` (${detalle})` : ''}. Inicia sesión otra vez y vuelve a copiar la cookie.`)
    this.name = 'SesionCaducada'
  }
}
export class LecturaSospechosa extends Error {
  constructor(detalle) {
    super(`Lectura de XLStore sospechosa, no se entrega: ${detalle}`)
    this.name = 'LecturaSospechosa'
  }
}

// ---- parseo (puro: recibe el HTML y un DOMParser) ----

/** "USD $4,259.64" → 4259.64; null si no hay un número. */
export function numeroUSD(texto) {
  const m = String(texto ?? '').match(/\$?\s*([\d][\d,]*(?:\.\d+)?)/)
  if (!m) return null
  const n = Number(m[1].replace(/,/g, ''))
  return Number.isFinite(n) ? n : null
}

const limpio = (t) => String(t ?? '').replace(/\s+/g, ' ').trim()

/** Id de marca → nombre, del filtro de marcas de una categoría. */
export function parsearMarcas(html, DP) {
  const d = new DP().parseFromString(html || '', 'text/html')
  const marcas = {}
  for (const e of d.querySelectorAll('[data-id]')) {
    const id = e.getAttribute('data-id'), nombre = limpio(e.getAttribute('data-name'))
    if (id && nombre && id !== 'TODOS') marcas[id] = nombre
  }
  return marcas
}

/** Las tarjetas del listado. `base` completa las rutas relativas. */
export function parsearListado(html, DP, marcas = {}, base = BASE) {
  const d = new DP().parseFromString(html || '', 'text/html')
  const filas = []
  for (const tarjeta of d.querySelectorAll('.card-product')) {
    const enlace = tarjeta.querySelector('a[href*="CodigoProducto="]')
    if (!enlace) continue
    const codigo = decodeURIComponent((enlace.getAttribute('href').split('CodigoProducto=')[1] || '').split('&')[0]).trim()
    if (!codigo) continue
    const titulo = tarjeta.querySelector('.text-size-title-product')
    const nombre = tarjeta.querySelector('.text-size-descrption-product')
    const logo = tarjeta.querySelector('img[src*="/Marcas/"]')
    const foto = tarjeta.querySelector('img[src*="/Productos/"]')
    const idMarca = ((logo?.getAttribute('src') || '').match(/Marcas\/([^./]+)\./) || [])[1]
    const textoTarjeta = limpio(tarjeta.textContent)
    const porWatt = textoTarjeta.match(/USD\s*\$\s*([\d.,]+)\s*\/\s*w/i)
    const src = foto?.getAttribute('src') || ''
    filas.push({
      codigo,
      modelo: limpio(titulo?.getAttribute('title') || titulo?.textContent),
      nombre: limpio(nombre?.getAttribute('title') || nombre?.textContent),
      marca: marcas[idMarca] || '',
      precioLista: numeroUSD(tarjeta.querySelector('del')?.textContent),
      precio: numeroUSD(tarjeta.querySelector('.text-Precio-Normal-product')?.textContent),
      porWatt: porWatt ? numeroUSD(porWatt[1]) : null,
      imagen: src ? (src.startsWith('http') ? src : base + (src.startsWith('/') ? '' : '/') + src) : '',
    })
  }
  return filas
}

/** Existencias: vienen como atributos de un campo oculto. null si la respuesta no las trae. */
export function parsearExistencia(html) {
  const t = String(html ?? '')
  const g = (k) => { const m = t.match(new RegExp(`data-${k}="(\\d+)"`)); return m ? Number(m[1]) : null }
  const r = { local: g('local'), cedis: g('cedis'), clever: g('clever'), nacional: g('nacional') }
  return Object.values(r).every((v) => v === null) ? null : r
}

/** Enlaces de la lista de documentos, separados por tipo y sin repetir. */
export function parsearDocumentos(html, DP) {
  const d = new DP().parseFromString(html || '', 'text/html')
  const tipos = { FichaTecnica: 'ficha', ManualUsuario: 'manual', Certificado: 'certificado', Garantia: 'garantia', DocumentosTecnico: 'otros' }
  const r = { ficha: [], manual: [], certificado: [], garantia: [], otros: [] }
  for (const a of d.querySelectorAll('a[href]')) {
    const href = a.getAttribute('href')
    const tipo = tipos[(href.split('/')[4] || '')]
    if (tipo && !r[tipo].includes(href)) r[tipo].push(href)
  }
  return r
}

// ---- lectura completa ----

const dormir = (ms) => new Promise((ok) => setTimeout(ok, ms))

async function pedirTexto(fetchFn, url, intentos = 3) {
  let ultimo
  for (let i = 1; i <= intentos; i++) {
    try {
      const r = await fetchFn(url)
      if (!r.ok) throw new Error(`HTTP ${r.status}`)
      // Con la sesión caída el sitio contesta la página de login con un 200.
      if (/Account\/Login/i.test(r.url || '') ) throw new SesionCaducada('lo mandó a la página de login')
      return await r.text()
    } catch (e) {
      if (e instanceof SesionCaducada) throw e
      ultimo = e
      await dormir(400 * i)
    }
  }
  throw ultimo
}

export async function haySesion(fetchFn, base = BASE) {
  try {
    const t = await pedirTexto(fetchFn, `${base}/Account/ExistSession`, 2)
    return JSON.parse(t).Exist === true
  } catch (e) {
    if (e instanceof SesionCaducada) return false
    throw e
  }
}

const urlListado = (base, slug) =>
  `${base}/Producto/GetListProductos?FirstLoad=true&SoloOutlet=false&Search=&Categoria=${slug}&Marca=&MarcasId=` +
  `&CaracteristicasId=&CategoriasOutletId=&ItemsToShow=1000&Page=1&Sort=marca_nombre&Ascending=true` +
  `&TipoView=grid&IsQuoteExpress=false&SetDefaultValues=`

/**
 * Lee todo el catálogo. Devuelve { filas, avisos, resumen }: `filas` es la hoja completa (encabezado
 * primero) lista para `normalizarHoja`, o para escribirse como CSV.
 *
 * opciones: fetchFn (url → Response), DP (DOMParser), base, categorias, conDocumentos (una petición más
 * por producto), concurrencia (por omisión 4: es el sitio de un proveedor, no un servidor propio),
 * pausaMs, minimoProductos, onProgreso(texto).
 */
export async function extraerCatalogo({
  fetchFn, DP, base = BASE, categorias = CATEGORIAS, conDocumentos = false,
  concurrencia = 4, pausaMs = 120, minimoProductos = 100, onProgreso = () => {},
}) {
  if (!(await haySesion(fetchFn, base))) throw new SesionCaducada('antes de empezar')
  const avisos = []
  const porCodigo = new Map()

  for (const [slug, nombreCategoria] of categorias) {
    onProgreso(`Leyendo ${nombreCategoria}…`)
    const marcas = parsearMarcas(await pedirTexto(fetchFn,
      `${base}/Producto/GetFiltrosMarcasCategorias?Categoria=${slug}&Search=&SoloOutlet=false&MarcasIdSelected=`), DP)
    const tarjetas = parsearListado(await pedirTexto(fetchFn, urlListado(base, slug)), DP, marcas, base)
    for (const t of tarjetas) {
      if (porCodigo.has(t.codigo)) continue   // un producto puede salir en dos categorías: gana la primera
      porCodigo.set(t.codigo, { ...t, categoria: nombreCategoria, stock: null, docs: null })
    }
  }

  const productos = [...porCodigo.values()]
  if (productos.length < minimoProductos) {
    throw new LecturaSospechosa(`solo ${productos.length} productos (se esperaban al menos ${minimoProductos})`)
  }
  const conPrecio = productos.filter((p) => p.precio !== null).length
  if (conPrecio < productos.length * 0.5) {
    throw new LecturaSospechosa(`solo ${conPrecio} de ${productos.length} traen precio: casi seguro se cayó la sesión a medias`)
  }

  const cola = [...productos]
  let hechos = 0
  const trabajador = async () => {
    while (cola.length) {
      const p = cola.shift()
      try {
        p.stock = parsearExistencia(await pedirTexto(fetchFn, `${base}/Producto/GetExistenciaProductoGrid?CodigoProducto=${encodeURIComponent(p.codigo)}`))
        if (!p.stock) avisos.push(`${p.codigo}: la respuesta de existencias no trajo datos.`)
        if (conDocumentos) {
          p.docs = parsearDocumentos(await pedirTexto(fetchFn, `${base}/Producto/GetDocumentosProducto?CodigoProducto=${encodeURIComponent(p.codigo)}`), DP)
        }
      } catch (e) {
        if (e instanceof SesionCaducada) throw e
        avisos.push(`${p.codigo}: no se pudo leer (${e.message}).`)
      }
      if (++hechos % 100 === 0) onProgreso(`Existencias: ${hechos}/${productos.length}`)
      if (pausaMs) await dormir(pausaMs)
    }
  }
  await Promise.all(Array.from({ length: Math.max(1, concurrencia) }, trabajador))

  // Si la sesión se cayó durante la lectura, lo leído después de eso no vale.
  if (!(await haySesion(fetchFn, base))) throw new SesionCaducada('se cayó durante la lectura')

  const sinExistencia = productos.filter((p) => !p.stock).length
  if (sinExistencia > productos.length * 0.2) {
    throw new LecturaSospechosa(`${sinExistencia} de ${productos.length} sin existencias`)
  }

  const enlaces = (p, k) => (p.docs?.[k] || []).join('\n')
  const filas = [ENCABEZADO, ...productos.map((p) => [
    p.codigo, p.categoria, p.marca, p.modelo, p.nombre, p.precioLista, p.precio, p.porWatt,
    p.stock?.local ?? null, p.stock?.cedis ?? null, p.stock?.clever ?? null, p.stock?.nacional ?? null,
    `${base}/Producto/Detalle?CodigoProducto=${encodeURIComponent(p.codigo)}`, p.imagen,
    enlaces(p, 'ficha'), enlaces(p, 'manual'), enlaces(p, 'certificado'), enlaces(p, 'garantia'), enlaces(p, 'otros'),
  ])]
  return {
    filas, avisos,
    resumen: { productos: productos.length, conPrecio, sinPrecio: productos.length - conPrecio, sinExistencia },
  }
}

// ---- CSV (para la herramienta del navegador) ----

/** Hoja (arreglo de arreglos) → texto CSV con comillas cuando hace falta. */
export function aCsv(filas) {
  const celda = (v) => {
    const t = v === null || v === undefined ? '' : String(v)
    return /[",\r\n]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t
  }
  return filas.map((f) => f.map(celda).join(',')).join('\r\n')
}
