// Adaptador de Solarama: lee su lista de precios en PDF (una por mes, "LISTA DE PRECIOS SOLARAMA
// <MES> <AÑO>.pdf") y la entrega en el mismo formato que `normalizar.js`.
//
//   node scripts/proveedor/sync.js --proveedor solarama --adaptador solarama --archivo "C:\...\LISTA.pdf"
//
// El PDF no es una tabla: cada texto está suelto en la página y el precio de un producto a veces queda
// en otro renglón que su descripción (la descripción va centrada en dos líneas, arriba y abajo del
// código). Por eso aquí se trabaja con la POSICIÓN de cada texto: se juntan los textos de un mismo
// renglón, se reconoce cada producto por su código (columna izquierda) y su precio (columna derecha),
// y cada renglón suelto de descripción se le pega al producto más cercano.
//
// Solarama no da existencias ni enlaces a imágenes o fichas: esas columnas van vacías.
// Precios en dólares MÁS IVA; para los paneles se toma el precio "Menor a 1 pallet" (lo que se paga
// por pieza) y, si solo se vende por pallet cerrado, el de 1 pallet con esa nota.
//
// La parte que interpreta la página (`filasDeSolarama`) es pura y se prueba con textos de mentira en
// pruebas/solarama.prueba.js. Si el PDF de un mes cambia de forma, la lectura FALLA con el nombre de
// la página que no se entendió, en vez de entregar precios equivocados.

const MINIMO_PRODUCTOS = 300 // la lista de septiembre de 2026 trae 400 y tantos

const quitarAcentos = (t) => String(t ?? '').normalize('NFD').replace(/\p{M}/gu, '')
const compacto = (t) => quitarAcentos(t).replace(/\s+/g, '').toUpperCase()
const limpio = (t) => String(t ?? '').replace(/\s+/g, ' ').replace(/\s+([.,)])/g, '$1').trim()

// Junta los textos de un renglón: sin espacio cuando se tocan ("MIN 6000TL" + "-" + "X2").
export function juntar(textos) {
  const t = [...textos].sort((a, b) => a.x - b.x)
  let s = ''
  let fin = null
  for (const it of t) {
    if (fin !== null && it.x - fin > 1.5) s += ' '
    s += it.s
    fin = it.x + (it.w ?? it.s.length * 4)
  }
  // Guiones tipográficos (‐ – −) como guion normal: el mismo modelo debe escribirse igual siempre.
  return s.replace(/[‐-―−]/g, '-').replace(/\s+/g, ' ').trim()
}

// Renglones de una página: textos cuya altura difiere menos de 3.5 puntos.
export function renglones(textos) {
  const orden = [...textos].sort((a, b) => a.y - b.y || a.x - b.x)
  const filas = []
  for (const it of orden) {
    const f = filas.find((r) => Math.abs(r.y - it.y) <= 3.5)
    if (f) f.textos.push(it)
    else filas.push({ y: it.y, textos: [it] })
  }
  return filas
}

const enRango = (it, [a, b]) => it.x >= a && it.x < b

// "$ 1, ,010" → 1010 · "$ 29.63" → 29.63 · "(sujeto a proyecto)" → null
export function precioDe(texto) {
  const m = String(texto ?? '').replace(/\s+/g, '').match(/\$([\d,]*\d(?:\.\d+)?)/)
  if (!m) return null
  const n = Number(m[1].replace(/,/g, ''))
  return Number.isFinite(n) ? n : null
}

// ---------------------------------------------------------------------------------------------
// Formas de página. Cada una dice dónde están las columnas (en puntos desde la izquierda), qué
// categoría y marca llevan sus productos, y cómo se reconoce en el texto de la página.

const CAT = {
  panel: 'Paneles solares',
  inversor: 'Inversores',
  micro: 'Microinversores',
  bateria: 'Baterías, controladores y generadores',
  monitoreo: 'Monitoreo, optimizadores y protecciones',
  suministros: 'Suministros de instalación',
  montaje: 'Sistemas de montaje',
}

const FORMAS = [
  { nombre: 'paneles', reconoce: /PANELESSOLARES/, paneles: true },
  { nombre: 'growatt interconectados', reconoce: /INVERSORESINTERCONECTADOS/, sku: [0, 170], precio: 520,
    marca: 'Growatt', categoria: () => CAT.inversor },
  { nombre: 'growatt aislados, micro y accesorios', reconoce: /MICROINVERSORES/, precio: 528,
    sku: (y) => (y < 280 ? [115, 240] : [0, 212]), marca: 'Growatt',
    categoria: (sku, y) => {
      if (y < 280) return CAT.inversor
      if (/^NEO|TRUNK/i.test(sku)) return CAT.micro
      if (/^(AXE|ALP)/i.test(sku)) return CAT.bateria
      return CAT.monitoreo
    } },
  { nombre: 'huawei', reconoce: /HUAWEI/, sku: [0, 190], precio: 500, marca: 'Huawei',
    categoria: (sku) => (/^SUN2000-\d+K/i.test(sku) ? CAT.inversor : CAT.monitoreo) },
  { nombre: 'victron', reconoce: /MULTIPLUS/, sku: [0, 185], precio: 518, marca: 'Victron Energy',
    categoria: (sku) => (/^(MULTI|QUATTRO)/i.test(sku) ? CAT.inversor : /^SMART/i.test(sku) ? CAT.bateria : CAT.monitoreo) },
  { nombre: 'pytes', reconoce: /BATERIASYACCESORIOS/, sku: [0, 210], precio: 524, marca: 'Pytes',
    categoria: () => CAT.bateria },
  { nombre: 'ecoflow', reconoce: /BATERIAS,ACCESORIOSYPANELES/, sku: [0, 200], precio: 498, marca: 'EcoFlow',
    categoria: (sku) => (/PANEL(PLEGABLE|RIGIDO)/i.test(sku) ? CAT.panel : /MC4/i.test(sku) ? CAT.suministros : CAT.bateria) },
  { nombre: 'unirac una fila', reconoce: /ESTRUCTURAUNIRACUNAFILA(0|10)°/, sku: [150, 330], precio: 390,
    marca: 'Unirac', categoria: () => CAT.montaje, kitSimple: true },
  { nombre: 'unirac ascender', reconoce: /KIT[12]FILAS?/, sku: [0, 175], precio: 510, marca: 'Unirac',
    categoria: () => CAT.montaje, ascender: true },
  { nombre: 'rm10 y carport', reconoce: /RM10/, sku: [0, 140], precio: 440, marca: null,
    categoria: () => CAT.montaje, marcaPorSku: (sku) => (/^3\d{5}$/.test(sku) ? 'Unirac' : null) },
  { nombre: 'piezas de estructura', reconoce: /PIEZAS/, sku: [0, 180], precio: 488,
    marca: null, categoria: () => CAT.montaje },
  { nombre: 'solución de lámina', reconoce: /OLUCIONDELAMINA/, sku: [0, 140], precio: 498, marca: 'Sunfer',
    categoria: () => CAT.montaje },
  { nombre: 'kits de lámina', reconoce: /KITSDESOLUCION/, sku: [0, 160], precio: 510, marca: 'Sunfer',
    categoria: () => CAT.montaje },
  { nombre: 'accesorios y protecciones', reconoce: /ACCESORIOSYPROTECCIONES/, sku: [0, 165], precio: 528,
    marca: null, marcaPorSku: (sku, desc) => (/SUNTREE|SL7N/i.test(`${sku} ${desc}`) ? 'Suntree' : null),
    categoria: (sku) => (/^(C1[02][NR]|MC4|T-TYPE|LLAVE|BATTERY CABLE|SHPN)/i.test(sku) ? CAT.suministros : CAT.monitoreo) },
]

const ES_ENCABEZADO = /^(SKU|DESCRIPCI[OÓ]N|PRECIO|P ?RECIO|MARCA|TIPO INVERSOR)$/i
const PIE = (y) => y > 700 || y < 60

// ---------------------------------------------------------------------------------------------

function paginaDePaneles(filas, avisos) {
  const MENOR = [340, 430]
  const PALLET = [430, 525]
  const modelos = []
  for (const f of filas) {
    if (PIE(f.y)) continue
    const izq = juntar(f.textos.filter((t) => t.x >= 120 && t.x < 340))
    if (/^[A-Z][A-Z0-9.-]{6,}$/.test(izq) && /\d{3}/.test(izq)) modelos.push({ y: f.y, modelo: izq })
  }
  const salida = []
  modelos.forEach((m, i) => {
    const hasta = modelos[i + 1]?.y ?? 700
    const bloque = filas.filter((f) => f.y >= m.y && f.y < hasta && !PIE(f.y))
    const col = (r) => bloque.map((f) => juntar(f.textos.filter((t) => enRango(t, r)))).join(' ')
    const menor = col(MENOR)
    const pallet = col(PALLET)
    const piezaMenor = /EXCLUSIVA/i.test(menor) ? null : precioDe(menor.match(/\$[\d.,\s]+USD\/PZA/i)?.[0])
    const piezaPallet = precioDe(pallet.match(/\$[\d.,\s]+USD\/PZA/i)?.[0])
    const desc = limpio(bloque.filter((f) => f.y !== m.y)
      .map((f) => juntar(f.textos.filter((t) => t.x < 340))).filter(Boolean).join(' '))
    const watts = Number(m.modelo.match(/(\d{3})W?$/)?.[1] ?? desc.match(/^(\d{3})/)?.[1])
    const marca = /^CS/.test(m.modelo) ? 'Canadian Solar' : /^NEG/.test(m.modelo) ? 'Trina Solar'
      : /^TWMN/.test(m.modelo) ? 'Tongwei' : null
    const soloPallet = piezaMenor === null
    const costo = piezaMenor ?? piezaPallet
    if (costo === null) avisos.push(`${m.modelo}: no encontré su precio por pieza.`)
    salida.push({
      sku_proveedor: m.modelo,
      nombre: limpio(`Panel solar ${marca ?? ''} ${watts || ''} W N-type TOPCon bifacial${soloPallet ? ' · solo por pallet' : ''}`),
      categoria: CAT.panel, marca, modelo: m.modelo,
      descripcion: limpio([desc,
        piezaMenor !== null ? `Menos de 1 pallet: USD ${piezaMenor} por pieza.` : 'Venta solo por pallet cerrado.',
        piezaPallet !== null ? `1 pallet: USD ${piezaPallet} por pieza.` : ''].join(' ')),
      costo,
    })
  })
  return salida
}

// "ASCENDER2X3A15°" → { filas: 2, porFila: 3, grados: 15, elevacion: '50.8 cm' }
export function datosAscender(sku) {
  const m = String(sku).match(/^(ASCENDER|ASCEN|ASCE)(\d)X(\d+)A(\d+)/i)
  if (!m) return null
  const elevacion = { ASCENDER: 'elevada 50.8 cm', ASCEN: 'elevada 25.4 cm', ASCE: 'sin elevación' }[m[1].toUpperCase()]
  return { filas: Number(m[2]), porFila: Number(m[3]), grados: Number(m[4]), elevacion }
}

function paginaGenerica(forma, filas, avisos) {
  const notas = filas.filter((f) => !PIE(f.y) && /^•/.test(juntar(f.textos)))
    .map((f) => juntar(f.textos).replace(/^•\s*/, ''))
  const notaPagina = notas.join(' ')
  const skuRango = (y) => (typeof forma.sku === 'function' ? forma.sku(y) : forma.sku)
  const descRango = (y) => [skuRango(y)[1], forma.precio]

  // 1. Renglones con producto: código a la izquierda y precio (o "sujeto a proyecto") a la derecha.
  const productos = []
  const sueltos = []
  let contexto = ''
  for (const f of filas) {
    if (PIE(f.y)) continue
    const todo = juntar(f.textos)
    if (/^•/.test(todo)) continue
    const sku = juntar(f.textos.filter((t) => enRango(t, skuRango(f.y))))
    const desc = juntar(f.textos.filter((t) => enRango(t, descRango(f.y))))
    const der = juntar(f.textos.filter((t) => t.x >= forma.precio))
    const tienePrecio = /\$\s*[\d,]/.test(der) || /SUJETO A PROYECTO/i.test(der.replace(/\s+/g, ' '))
    if (/PRECIO$/i.test(compacto(der)) || f.textos.some((t) => ES_ENCABEZADO.test(t.s.trim()))) {
      // Encabezado de tabla; si trae título ("KIT 1 FILA CON ELEVACION ...") se usa de contexto.
      const titulo = limpio(juntar(f.textos.filter((t) => t.x < forma.precio)))
      if (titulo && !ES_ENCABEZADO.test(titulo) && !/^SKU\b/i.test(titulo)) contexto = titulo
      continue
    }
    if (sku && tienePrecio && !ES_ENCABEZADO.test(sku)) {
      // En los kits de dos filas la columna "2X4" queda pegada al código: no es parte de él.
      const codigo = (forma.ascender ? sku.replace(/\s+\d+X\d+$/i, '') : sku).replace(/\s*-\s*/g, '-')
      productos.push({ y: f.y, sku: codigo, desc: [{ y: f.y, t: desc }],
        precio: precioDe(der), proyecto: /SUJETO/i.test(der), par: /\(\s*par\s*\)/i.test(der), contexto })
    } else if (!sku && !tienePrecio && desc) {
      sueltos.push({ y: f.y, t: desc })
    } else if (!tienePrecio && sku && !desc) {
      // Un título de sección suelto ("Micro inversores", "Accesorios"): no es descripción de nadie.
      contexto = sku
    }
  }
  // 2. Cada renglón suelto de descripción va con el producto más cercano (arriba o abajo).
  for (const s of sueltos) {
    let mejor = null
    for (const p of productos) {
      const d = Math.abs(p.y - s.y)
      if (d <= 16 && (!mejor || d < mejor.d)) mejor = { p, d }
    }
    if (mejor) mejor.p.desc.push(s)
  }

  return productos.map((p) => {
    const desc = limpio(p.desc.sort((a, b) => a.y - b.y).map((d) => d.t).filter(Boolean).join(' '))
    let nombre = desc
    if (forma.kitSimple) {
      const m = p.sku.match(/KIT(\d)X(\d+)A(\d+)/i)
      nombre = m ? `Estructura Unirac ${m[1] === '1' ? 'una fila' : `${m[1]} filas`} para ${Number(m[1]) * Number(m[2])} paneles, ${m[3]}°${m[3] === '10' ? ' con patas inclinadas' : ''}`
        : `Estructura Unirac ${p.sku}`
    } else if (forma.ascender) {
      const a = datosAscender(p.sku)
      nombre = a ? `Estructura Unirac Ascender ${a.filas === 1 ? '1 fila' : `${a.filas} filas`}, ${a.filas * a.porFila} paneles, ${a.grados}°, ${a.elevacion}`
        : desc || p.sku
    }
    if (!nombre) nombre = p.sku
    if (p.par && !/\bpar(es)?\b/i.test(nombre)) nombre += ' (par)'
    if (p.precio === null && !p.proyecto) avisos.push(`${p.sku}: no encontré su precio.`)
    const marca = forma.marcaPorSku ? forma.marcaPorSku(p.sku, desc) : forma.marca
    return {
      sku_proveedor: p.sku,
      nombre: limpio(nombre),
      categoria: forma.categoria(p.sku, p.y),
      marca,
      modelo: /^\d+$/.test(p.sku) || /^[A-Z]{1,2}\d{4,}/.test(p.sku) ? null : p.sku,
      descripcion: limpio([desc !== nombre ? desc : '', p.contexto && !forma.ascender ? '' : '',
        p.proyecto ? 'Precio sujeto a proyecto.' : '', p.par ? 'Precio por par.' : '', notaPagina].join(' ')) || null,
      costo: p.precio,
    }
  })
}

/**
 * @param {Array<{p:number,x:number,y:number,w?:number,s:string}>} textos  todos los textos del PDF
 * @param {{minimo?: number}} [opciones]  `minimo` solo se baja en las pruebas
 * @returns {{filas: object[], avisos: string[], vigencia: string|null, paginas: object[]}}
 */
export function filasDeSolarama(textos, { minimo = MINIMO_PRODUCTOS } = {}) {
  const avisos = []
  const paginas = []
  const porPagina = new Map()
  for (const t of textos) {
    if (!porPagina.has(t.p)) porPagina.set(t.p, [])
    porPagina.get(t.p).push(t)
  }
  const todo = compacto(textos.map((t) => t.s).join(' '))
  if (!/SOLARAMA|PRECIOSENDOLARES/.test(todo) || !/MASIVA/.test(todo)) {
    throw new Error('Este PDF no parece la lista de precios de Solarama (no dice "precios en dólares… más IVA").')
  }
  const vig = textos.map((t) => t.s).join(' ').match(/VIGENCIA\s+A\s*PARTIR\s+DEL\s+(.+?\d{4})/i)
  const vigencia = vig ? limpio(vig[1]) : null

  let filas = []
  for (const [p, ts] of [...porPagina.entries()].sort((a, b) => a[0] - b[0])) {
    const cuerpo = ts.filter((t) => !PIE(t.y))
    if (!cuerpo.length) continue // portada
    const textoPagina = compacto(cuerpo.map((t) => t.s).join(' '))
    const forma = FORMAS.find((f) => f.reconoce.test(textoPagina))
    if (!forma) throw new Error(`No reconozco la forma de la página ${p} del PDF: Solarama cambió el formato de su lista.`)
    const r = renglones(cuerpo)
    const deEsta = forma.paneles ? paginaDePaneles(r, avisos) : paginaGenerica(forma, r, avisos)
    if (!deEsta.length) throw new Error(`La página ${p} (${forma.nombre}) no dio ningún producto: revisa si cambió el formato.`)
    paginas.push({ pagina: p, forma: forma.nombre, productos: deEsta.length })
    filas = filas.concat(deEsta)
  }

  // Códigos repetidos: el mismo producto en dos páginas se queda una vez; si el precio no coincide,
  // se avisa y se queda el primero.
  const vistos = new Map()
  const unicas = []
  for (const f of filas) {
    const previo = vistos.get(f.sku_proveedor)
    if (previo) {
      if (previo.costo !== f.costo) avisos.push(`${f.sku_proveedor}: aparece dos veces con precio distinto (${previo.costo} y ${f.costo}); se queda el primero.`)
      continue
    }
    vistos.set(f.sku_proveedor, f)
    unicas.push(f)
  }

  for (const f of unicas) {
    if (f.costo !== null && (f.costo <= 0 || f.costo > 50000)) {
      throw new Error(`Precio fuera de rango en ${f.sku_proveedor}: ${f.costo}. Revisa la lectura del PDF.`)
    }
  }
  if (unicas.length < minimo) {
    throw new Error(`Solo leí ${unicas.length} productos (espero al menos ${minimo}): la lista cambió de formato o está incompleta.`)
  }

  return {
    vigencia,
    paginas,
    avisos,
    filas: unicas.map((f) => ({
      ...f,
      moneda: 'USD',
      stock_local: null,
      stock_proveedor: null,
      tiempo_entrega_dias: null,
      url_imagen: null,
      documentos: {},
    })),
  }
}

// Lee el PDF con pdf.js (solo el texto: no dibuja nada) y lo interpreta.
export async function textosDelPdf(ruta) {
  const { readFile } = await import('node:fs/promises')
  const pdfjs = await import('pdfjs-dist/legacy/build/pdf.mjs')
  const doc = await pdfjs.getDocument({ data: new Uint8Array(await readFile(ruta)), verbosity: 0 }).promise
  const textos = []
  for (let p = 1; p <= doc.numPages; p++) {
    const pagina = await doc.getPage(p)
    const alto = pagina.getViewport({ scale: 1 }).height
    for (const it of (await pagina.getTextContent()).items) {
      if (!it.str || !it.str.trim()) continue
      textos.push({ p, x: it.transform[4], y: alto - it.transform[5], w: it.width, s: it.str })
    }
  }
  return textos
}

/** @param {{archivo: string}} config */
export async function leer(config) {
  if (!config.archivo) throw new Error('Falta la ruta del PDF de Solarama (--archivo).')
  if (!/\.pdf$/i.test(config.archivo)) throw new Error('El adaptador de Solarama lee el PDF de su lista de precios.')
  const r = filasDeSolarama(await textosDelPdf(config.archivo))
  return {
    fuente: `solarama-pdf:${config.archivo}${r.vigencia ? ` (vigente desde ${r.vigencia})` : ''}`,
    filas: r.filas,
    avisos: r.avisos,
  }
}
