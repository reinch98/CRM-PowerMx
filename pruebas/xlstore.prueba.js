// Lectura de XLStore con sesión (opciones C y D): parseo del HTML, la lectura completa con sus candados
// (sesión caída, lectura sospechosa, reintentos, ritmo) y la herramienta que se pega en el navegador.
// Todo contra un XLStore FALSO: aquí no se toca el sitio de nadie.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { DOMParser } from 'linkedom'
import {
  numeroUSD, parsearMarcas, parsearListado, parsearExistencia, parsearDocumentos, extraerCatalogo, aCsv,
  haySesion, SesionCaducada, LecturaSospechosa, ENCABEZADO, BASE,
} from '../scripts/proveedor/xlstore/extraer.js'
import { parsearCsv } from '../scripts/proveedor/adaptadores/csv.js'
import { normalizarHoja } from '../scripts/proveedor/adaptadores/normalizar.js'
import { cookieSegura, leerCookie, leer as leerXlstore } from '../scripts/proveedor/adaptadores/xlstore.js'
import { armarHerramienta } from '../scripts/proveedor/xlstore/crear-herramienta.js'
import { readFileSync } from 'node:fs'
import { tarjeta, listado, filtroMarcas, existencia, documentos, catalogoFalso } from './falso/xlstoreHtml.js'

const DP = DOMParser
const SLUGS = ['paneles-solares', 'inversores']
const CATS = [['paneles-solares', 'Paneles solares'], ['inversores', 'Inversores']]

// Un fetch que se comporta como XLStore. `opciones` permite romperlo de formas concretas.
function xlstoreFalso(opciones = {}) {
  const { marcas, porCategoria } = catalogoFalso(SLUGS, opciones.n ?? 12)
  const todos = SLUGS.flatMap((s) => porCategoria[s])
  if (opciones.duplicar) porCategoria.inversores.push({ ...porCategoria['paneles-solares'][0] })   // el mismo código en dos categorías
  const estado = { llamadas: [], enVuelo: 0, maxEnVuelo: 0, sesionesRestantes: opciones.sesionesRestantes ?? Infinity, fallos: {} }
  const respuesta = (cuerpo, extra = {}) => ({ ok: true, status: 200, url: extra.url || '', text: async () => cuerpo })

  const fetchFn = async (url) => {
    estado.llamadas.push(url)
    estado.enVuelo++; estado.maxEnVuelo = Math.max(estado.maxEnVuelo, estado.enVuelo)
    await new Promise((ok) => setTimeout(ok, 1))
    try {
      const u = new URL(url)
      if (u.pathname === '/Account/ExistSession') {
        if (opciones.loginRedirect) return respuesta('<html>login</html>', { url: `${BASE}/Account/Login?ReturnUrl=%2F` })
        const vive = opciones.sinSesion ? false : estado.sesionesRestantes-- > 0
        return respuesta(JSON.stringify({ Exist: vive }))
      }
      if (u.pathname.endsWith('GetFiltrosMarcasCategorias')) return respuesta(filtroMarcas(marcas))
      if (u.pathname.endsWith('GetListProductos')) {
        const prods = porCategoria[u.searchParams.get('Categoria')] || []
        return respuesta(listado(opciones.sinPrecios ? prods.map((p) => ({ ...p, precio: null })) : prods))
      }
      if (u.pathname.endsWith('GetExistenciaProductoGrid')) {
        const codigo = u.searchParams.get('CodigoProducto')
        estado.fallos[codigo] = (estado.fallos[codigo] || 0) + 1
        if (opciones.fallaUnaVez === codigo && estado.fallos[codigo] === 1) return { ok: false, status: 500, text: async () => '' }
        if (opciones.sinExistencias) return respuesta('<html>sin datos</html>')
        return respuesta(existencia(codigo, { local: 1, cedis: 0, clever: 448, nacional: 449 }))
      }
      if (u.pathname.endsWith('GetDocumentosProducto')) {
        const codigo = u.searchParams.get('CodigoProducto')
        return respuesta(documentos([
          `/Multimedia/FichaTecnica/${codigo}_FichaTecnica.pdf`, `/Multimedia/FichaTecnica/${codigo}_FichaTecnica.pdf`,
          `/Multimedia/ManualUsuario/${codigo}_ManualUsuario.pdf`, `/Multimedia/Garantia/${codigo}_Garantia.pdf`,
        ]))
      }
      return { ok: false, status: 404, text: async () => '' }
    } finally { estado.enVuelo-- }
  }
  return { fetchFn, estado, todos }
}

const leerTodo = (f, extra = {}) => extraerCatalogo({ fetchFn: f.fetchFn, DP, categorias: CATS, minimoProductos: 3, pausaMs: 0, ...extra })

// ---- parseo ----

test('numeroUSD entiende los formatos de precio de XLStore', () => {
  assert.equal(numeroUSD('USD $4,259.64'), 4259.64)
  assert.equal(numeroUSD(' USD $114.66 '), 114.66)
  assert.equal(numeroUSD('USD $0.170'), 0.17)
  assert.equal(numeroUSD(''), null)
  assert.equal(numeroUSD('Cotizar'), null)
  assert.equal(numeroUSD(null), null)
})

test('una tarjeta: código, modelo, nombre, marca, imagen, precio de lista y tu precio', () => {
  const marcas = parsearMarcas(filtroMarcas([{ id: 'M1', nombre: 'JA SOLAR' }]), DP)
  assert.deepEqual(marcas, { M1: 'JA SOLAR' })   // "TODOS" no es una marca
  const [t] = parsearListado(listado([{ codigo: 'PSOJAS1S212', idMarca: 'M1', modelo: 'JA-715/LB', nombre: 'Pallet 33 paneles', precioLista: 4259.64, precio: 4050.87, porWatt: 0.17 }]), DP, marcas)
  assert.deepEqual(t, {
    codigo: 'PSOJAS1S212', modelo: 'JA-715/LB', nombre: 'Pallet 33 paneles', marca: 'JA SOLAR',
    precioLista: 4259.64, precio: 4050.87, porWatt: 0.17, imagen: `${BASE}/Multimedia/Productos/M1/PSOJAS1S212.png`,
  })
})

test('una tarjeta sin descuento no inventa precio de lista, y una de "cotizar" queda sin precio', () => {
  const [a, b] = parsearListado(listado([
    { codigo: 'A1', modelo: 'M', nombre: 'N', precio: 100 },
    { codigo: 'B1', modelo: 'M', nombre: 'N', precio: null },
  ]), DP)
  assert.equal(a.precioLista, null)
  assert.equal(a.precio, 100)
  assert.equal(b.precio, null)
})

test('nombres con comillas y símbolos se leen tal cual', () => {
  const [t] = parsearListado(listado([{ codigo: 'X1', modelo: 'A<B', nombre: 'Tubo 1.5" "especial" & más', precio: 5 }]), DP)
  assert.equal(t.nombre, 'Tubo 1.5" "especial" & más')
  assert.equal(t.modelo, 'A<B')
})

test('una tarjeta sin enlace de producto se ignora en vez de romper la lectura', () => {
  const html = '<div class="card-product"><b>Anuncio</b></div>' + tarjeta({ codigo: 'OK1', modelo: 'm', nombre: 'n', precio: 1 })
  assert.deepEqual(parsearListado(html, DP).map((t) => t.codigo), ['OK1'])
})

test('existencias: los cuatro números, o null si la respuesta no los trae (p. ej. la página de login)', () => {
  assert.deepEqual(parsearExistencia(existencia('P', { local: 1, cedis: 0, clever: 448, nacional: 449 })),
    { local: 1, cedis: 0, clever: 448, nacional: 449 })
  assert.equal(parsearExistencia('<html>Inicia sesión</html>'), null)
  assert.equal(parsearExistencia(null), null)
})

test('documentos: separados por tipo y sin repetir', () => {
  const d = parsearDocumentos(documentos([
    '/Multimedia/FichaTecnica/a.pdf', '/Multimedia/FichaTecnica/a.pdf', '/Multimedia/ManualUsuario/m.pdf',
    '/Multimedia/Certificado/c.pdf', '/Multimedia/Garantia/g.pdf', '/Multimedia/DocumentosTecnico/t.pdf', '/Otra/cosa.pdf',
  ]), DP)
  assert.equal(d.ficha.length, 1)
  assert.equal(d.manual.length, 1)
  assert.equal(d.certificado.length + d.garantia.length + d.otros.length, 3)
})

// ---- lectura completa ----

test('lectura completa: encabezado del Excel, un renglón por producto, existencias y marcas', async () => {
  const f = xlstoreFalso()
  const r = await leerTodo(f)
  assert.deepEqual(r.filas[0], ENCABEZADO)
  assert.equal(r.filas.length, 1 + 24)
  assert.equal(r.resumen.productos, 24)
  assert.equal(r.resumen.sinPrecio, 2)   // el producto 3 de cada categoría es "cotizar"
  const idx = (c) => ENCABEZADO.indexOf(c)
  const fila = r.filas[1]
  assert.equal(fila[idx('Categoría')], 'Paneles solares')
  assert.equal(fila[idx('Marca')], 'JA SOLAR')
  assert.equal(fila[idx('Stock local MID')], 1)
  assert.equal(fila[idx('Stock nacional')], 449)
  assert.match(fila[idx('Enlace')], /Detalle\?CodigoProducto=/)
})

test('por omisión NO pide los documentos (una petición menos por producto); con la opción sí', async () => {
  const a = xlstoreFalso()
  await leerTodo(a)
  assert.equal(a.estado.llamadas.filter((u) => u.includes('GetDocumentosProducto')).length, 0)
  const b = xlstoreFalso()
  const r = await leerTodo(b, { conDocumentos: true })
  assert.equal(b.estado.llamadas.filter((u) => u.includes('GetDocumentosProducto')).length, 24)
  const fila = r.filas[1]
  assert.match(fila[ENCABEZADO.indexOf('Ficha técnica')], /FichaTecnica\/.*_FichaTecnica\.pdf$/)
  assert.equal(fila[ENCABEZADO.indexOf('Ficha técnica')].split('\n').length, 1)   // la repetida se quitó
})

test('un producto que sale en dos categorías se cuenta una vez (gana la primera)', async () => {
  const f = xlstoreFalso({ duplicar: true })
  const r = await leerTodo(f)
  assert.equal(r.resumen.productos, 24)
  assert.equal(r.filas.filter((x) => x[0] === f.todos[0].codigo).length, 1)
})

test('el ritmo está acotado: nunca más peticiones a la vez que la concurrencia pedida', async () => {
  const f = xlstoreFalso({ n: 30 })
  await leerTodo(f, { concurrencia: 3 })
  assert.ok(f.estado.maxEnVuelo <= 3, `hubo ${f.estado.maxEnVuelo} peticiones a la vez`)
})

test('un fallo pasajero se reintenta y la lectura sigue completa', async () => {
  const f = xlstoreFalso()
  const r = await leerTodo(f, { })
  const raro = xlstoreFalso({ fallaUnaVez: xlstoreFalso().todos[2].codigo })
  const r2 = await leerTodo(raro)
  assert.equal(r2.resumen.productos, r.resumen.productos)
  assert.equal(r2.filas.filter((x) => x[ENCABEZADO.indexOf('Stock nacional')] === null).length, 0)
})

// ---- candados ----

test('sin sesión al empezar: SesionCaducada y no se lee nada más', async () => {
  const f = xlstoreFalso({ sinSesion: true })
  await assert.rejects(leerTodo(f), SesionCaducada)
  assert.equal(f.estado.llamadas.length, 1)
  assert.equal(await haySesion(f.fetchFn), false)
})

test('si el sitio manda a la página de login, se reconoce como sesión caída', async () => {
  const f = xlstoreFalso({ loginRedirect: true })
  await assert.rejects(leerTodo(f), SesionCaducada)
})

test('si la sesión se cae DURANTE la lectura, se rechaza todo (lo leído después no vale)', async () => {
  const f = xlstoreFalso({ sesionesRestantes: 1 })   // la comprobación inicial pasa; la final, no
  await assert.rejects(leerTodo(f), /se cayó durante la lectura/)
})

test('pocos productos, sin precios o sin existencias: LecturaSospechosa, no se entrega', async () => {
  await assert.rejects(leerTodo(xlstoreFalso(), { minimoProductos: 500 }), LecturaSospechosa)
  await assert.rejects(leerTodo(xlstoreFalso({ sinPrecios: true })), /traen precio/)
  await assert.rejects(leerTodo(xlstoreFalso({ sinExistencias: true })), /sin existencias/)
})

// ---- CSV ----

test('CSV: comillas, comas, saltos de línea dentro de una celda y celdas vacías sobreviven al ir y volver', () => {
  const hoja = [
    ['Código', 'Nombre', 'Ficha técnica', 'Costo'],
    ['A1', 'Tubo 1.5", "especial", con coma', 'https://x/a.pdf\nhttps://x/b.pdf', 10.5],
    ['B2', null, null, null],
  ]
  const csv = aCsv(hoja)
  assert.deepEqual(parsearCsv(csv), [
    ['Código', 'Nombre', 'Ficha técnica', 'Costo'],
    ['A1', 'Tubo 1.5", "especial", con coma', 'https://x/a.pdf\nhttps://x/b.pdf', '10.5'],
    ['B2', null, null, null],
  ])
  assert.deepEqual(parsearCsv('\uFEFFa,b\r\n1,2\r\n'), [['a', 'b'], ['1', '2']])   // BOM y último salto de línea
  assert.throws(() => parsearCsv('a,"sin cerrar'), /incompleto/)
})

test('el CSV de la herramienta entra al sync tal como el Excel de siempre', async () => {
  const r = await leerTodo(xlstoreFalso(), { conDocumentos: true })
  const { filas, avisos } = normalizarHoja(parsearCsv(aCsv(r.filas)))
  assert.equal(filas.length, 24)
  assert.equal(avisos.length, 2)   // los dos "cotizar"
  const p = filas[0]
  assert.equal(p.moneda, 'USD')
  assert.equal(p.costo, 100)
  assert.equal(p.stock_local, 1)
  assert.equal(p.stock_proveedor, 449)
  assert.equal(p.categoria, 'Paneles solares')
  assert.ok(p.documentos.ficha_tecnica[0].endsWith('_FichaTecnica.pdf'))
})

// ---- cookie ----

test('la cookie: se limpia el prefijo "Cookie:", y un salto de línea o una cookie vacía se rechazan', () => {
  assert.equal(cookieSegura('Cookie: a=1; b=2'), 'a=1; b=2')
  assert.equal(cookieSegura('  a=1  '), 'a=1')
  assert.throws(() => cookieSegura(''), /no es válida/)
  assert.throws(() => cookieSegura('a=1\r\nX-Inyectado: 1'), /no es válida/)
})

test('la cookie sale de la variable de entorno primero; sin ninguna, el error explica qué hacer y no la imprime', async () => {
  assert.equal(await leerCookie({}, { XLSTORE_COOKIE: ' sesion=abc ' }), 'sesion=abc')
  await assert.rejects(leerCookie({ cookieArchivo: 'C:/no/existe/cookie.txt' }, {}), /Guardar mi sesión de XLStore/)
})

test('el adaptador manda la cookie, nunca la imprime en el resultado, y lee igual que la herramienta', async () => {
  const f = xlstoreFalso()
  const cookiesVistas = new Set()
  const conCookie = async (url, init) => { cookiesVistas.add(init?.headers?.Cookie); return f.fetchFn(url, init) }
  const env = { XLSTORE_COOKIE: 'ASPXAUTH=secreto123', XLSTORE_BASE: BASE }
  const r = await leerXlstore({}, {
    fetchFn: conCookie, env, onProgreso: () => {}, extra: { categorias: CATS, minimoProductos: 3, pausaMs: 0 },
  })
  assert.deepEqual([...cookiesVistas], ['ASPXAUTH=secreto123'], 'TODAS las peticiones llevan la cookie, y solo esa')
  assert.equal(r.filas.length, 24)
  assert.equal(r.filas[0].moneda, 'USD')
  assert.equal(r.fuente, 'xlstore:sesion (24 productos, 2 sin precio)')
  assert.ok(!JSON.stringify(r).includes('secreto123'), 'la cookie no debe aparecer en el resultado')
})

test('si la sesión caducó, el adaptador falla con un mensaje que no incluye la cookie', async () => {
  const f = xlstoreFalso({ sinSesion: true })
  const env = { XLSTORE_COOKIE: 'ASPXAUTH=secreto123', XLSTORE_BASE: BASE }
  await assert.rejects(
    leerXlstore({}, { fetchFn: f.fetchFn, env, onProgreso: () => {}, extra: { categorias: CATS, minimoProductos: 3 } }),
    (e) => e instanceof SesionCaducada && !e.message.includes('secreto123') && /vuelve a copiar la cookie/.test(e.message))
})

// ---- la herramienta del navegador ----

test('la herramienta generada no usa export/import y es JavaScript válido', () => {
  const codigo = armarHerramienta(readFileSync(new URL('../scripts/proveedor/xlstore/extraer.js', import.meta.url), 'utf8'))
  assert.ok(!/^\s*export\s/m.test(codigo))
  assert.ok(!/\bimport\s/.test(codigo))
  assert.doesNotThrow(() => new Function(codigo))
  const archivo = readFileSync(new URL('../scripts/proveedor/xlstore/xlstore-descargar.js', import.meta.url), 'utf8')
  assert.equal(archivo, codigo, 'xlstore-descargar.js está desactualizado: corre crear-herramienta.js')
})

test('ejecutada como en el navegador (con un XLStore falso) baja un CSV idéntico al del extractor', async () => {
  const codigo = armarHerramienta(readFileSync(new URL('../scripts/proveedor/xlstore/extraer.js', import.meta.url), 'utf8'))
    .replace('minimoProductos = 100', 'minimoProductos = 3')   // el catálogo falso es chico
    .replace(/categorias = CATEGORIAS/, 'categorias = CATS_PRUEBA')
  const f = xlstoreFalso()
  const descargas = []
  const alertas = []
  const entorno = {
    location: { hostname: 'xlstore.exelsolar.com' }, fetch: f.fetchFn, DOMParser: DP, alert: (t) => alertas.push(t),
    console: { log() {}, warn() {}, error() {} },
    Blob: class { constructor(partes) { this.texto = partes.join('') } },
    URL: { createObjectURL: (b) => { descargas.push(b); return 'blob:x' } },
    document: { createElement: () => ({ click() {}, remove() {} }), body: { appendChild() {} } },
    CATS_PRUEBA: CATS,
  }
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor
  await new AsyncFunction(...Object.keys(entorno), `await ${codigo}`)(...Object.values(entorno))
  assert.equal(descargas.length, 1)
  assert.match(alertas.at(-1), /Listo: 24 productos/)
  const esperado = aCsv((await leerTodo(xlstoreFalso())).filas)
  assert.equal(descargas[0].texto, '\uFEFF' + esperado)
})

test('la herramienta se niega a correr fuera de xlstore.exelsolar.com', async () => {
  const codigo = armarHerramienta(readFileSync(new URL('../scripts/proveedor/xlstore/extraer.js', import.meta.url), 'utf8'))
  const alertas = []
  const entorno = { location: { hostname: 'otro-sitio.com' }, alert: (t) => alertas.push(t), fetch: () => { throw new Error('no debe pedir nada') } }
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor
  await new AsyncFunction(...Object.keys(entorno), `await ${codigo}`)(...Object.values(entorno))
  assert.match(alertas[0], /xlstore\.exelsolar\.com/)
})
