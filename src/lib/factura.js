// ---------------------------------------------------------------------------
// Leer una factura de proveedor y registrarla como compra (Edge Function `leer-comprobante`, modo factura, SQL 62).
//
// La función solo PROPONE. Aquí viven las reglas para revisar lo leído antes de que entre nada al
// almacén: normalizar la lectura, empatar cada línea con una pieza del catálogo (por el código
// del proveedor, por SKU o por nombre) y decir con palabras qué tan segura es la pareja. Todo es
// puro y probado en Node; las llamadas a la base están al final.
// ---------------------------------------------------------------------------

import { supabase } from './supabase'
import { explicarError } from './errores'
import { redimensionar } from './imagen'
import { todasLasFilas } from './paginar'

const BUCKET = 'compras'
export const IVA = 0.16

const num = v => {
  const n = Number(v)
  return Number.isFinite(n) ? n : 0
}
const redondear = (n, d = 2) => {
  const f = 10 ** d
  return Math.round((n + Number.EPSILON) * f) / f
}

// "$1,234.50" → 1234.5; lo que no es número → null.
export function aNumero(v) {
  if (typeof v === 'number') return Number.isFinite(v) ? v : null
  if (typeof v !== 'string') return null
  const limpio = v.replace(/[^0-9.,-]/g, '').replace(/,/g, '')
  if (limpio === '' || limpio === '-' || limpio === '.') return null
  const n = Number(limpio)
  return Number.isFinite(n) ? n : null
}

// ---------------------------------------------------------------------------
// Texto: normalizar y comparar nombres
// ---------------------------------------------------------------------------

const PARASITAS = new Set([
  'de', 'del', 'la', 'el', 'los', 'las', 'para', 'con', 'sin', 'y', 'e', 'o', 'en', 'a', 'un', 'una',
  'por', 'pza', 'pzas', 'pieza', 'piezas', 'kit', 'marca', 'tipo', 'modelo'
])
// Lo que un proveedor lleva al final de su razón social y no dice quién es.
const SOCIETARIOS = new Set(['sa', 'cv', 's', 'rl', 'sapi', 'sas', 'srl', 'mexico', 'mx', 'comercializadora', 'grupo'])

export function normalizarTexto(t) {
  return String(t ?? '')
    .toLowerCase()
    .normalize('NFD').replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9]+/g, ' ')
    .trim()
}

// Un código para comparar: sin espacios, guiones ni mayúsculas ("XA-1 " = "xa1").
export const codigoCompacto = t => normalizarTexto(t).replace(/ /g, '')

export function tokens(t, extraParasitos) {
  const vistos = new Set()
  for (const p of normalizarTexto(t).split(' ')) {
    if (!p) continue
    if (PARASITAS.has(p) || extraParasitos?.has(p)) continue
    if (p.length < 2 && !/\d/.test(p)) continue
    vistos.add(p)
  }
  return [...vistos]
}

const tieneDigitos = p => /\d/.test(p)

// Qué tanto se parecen dos nombres, de 0 a 1 (coeficiente de Dice sobre las palabras). Si los dos
// traen medidas o claves con números ("15W40", "4BTAA3") y NO comparten ninguna, casi seguro son
// otra pieza: se castiga fuerte, porque "aceite 15W40" y "aceite 10W30" no son lo mismo.
export function parecido(a, b, extraParasitos) {
  const A = tokens(a, extraParasitos)
  const B = tokens(b, extraParasitos)
  if (A.length === 0 || B.length === 0) return 0
  const conjuntoB = new Set(B)
  const comunes = A.filter(p => conjuntoB.has(p))
  let puntaje = (2 * comunes.length) / (A.length + B.length)
  const dA = A.filter(tieneDigitos)
  const dB = B.filter(tieneDigitos)
  if (dA.length > 0 && dB.length > 0 && !dA.some(p => conjuntoB.has(p))) puntaje *= 0.4
  return puntaje
}

// ---------------------------------------------------------------------------
// Lo que lee la IA, normalizado
// ---------------------------------------------------------------------------

const texto = v => (typeof v === 'string' ? v.trim() : '')

export function normalizarLectura(leido) {
  const l = leido && typeof leido === 'object' ? leido : {}
  const bruto = Array.isArray(l.lineas) ? l.lineas : []
  const lineas = []
  let descartadas = 0
  for (const r of bruto) {
    const descripcion = texto(r?.descripcion)
    const cantidad = aNumero(r?.cantidad)
    const precio = aNumero(r?.precio_unitario)
    if (!descripcion || !(cantidad > 0) || precio == null || precio < 0) { descartadas += 1; continue }
    lineas.push({
      codigo: texto(r?.codigo),
      descripcion,
      cantidad,
      unidad: texto(r?.unidad),
      precio_unitario: precio,
      importe: aNumero(r?.importe)
    })
  }
  const fecha = /^\d{4}-\d{2}-\d{2}$/.test(texto(l.fecha)) ? texto(l.fecha) : ''
  return {
    proveedor: texto(l.proveedor),
    rfc: texto(l.rfc),
    factura: texto(l.factura),
    uuid_fiscal: texto(l.uuid_fiscal),
    fecha,
    moneda: texto(l.moneda).toUpperCase() === 'USD' ? 'USD' : 'MXN',
    preciosIncluyenIva: l.precios_incluyen_iva === true,
    subtotal: aNumero(l.subtotal),
    iva: aNumero(l.iva),
    total: aNumero(l.total),
    lineas,
    descartadas,
    notas: texto(l.notas)
  }
}

// El costo que se guarda es SIN IVA: la compra suma el IVA aparte. Un ticket que ya lo incluye se
// divide entre 1.16.
export const costoSinIva = (precio, incluyeIva) =>
  incluyeIva ? redondear(num(precio) / (1 + IVA), 4) : redondear(num(precio), 4)

// ¿Lo leído cuadra con los totales de la factura? Es la comprobación de que la IA no se comió ni
// inventó un renglón: la suma de las líneas contra el subtotal impreso. null = no se puede saber.
export function cuadre(lineas, subtotalLeido) {
  const esperado = Number(subtotalLeido)
  if (!Number.isFinite(esperado) || esperado <= 0) return { cuadra: null, suma: 0, esperado: null, diferencia: 0 }
  const suma = redondear((lineas || []).reduce((n, l) => n + num(l.cantidad) * num(l.costo_unitario), 0))
  const diferencia = redondear(suma - esperado)
  const tolerancia = Math.max(1, esperado * 0.005)
  return { cuadra: Math.abs(diferencia) <= tolerancia, suma, esperado, diferencia }
}

// ---------------------------------------------------------------------------
// Empatar una línea con el catálogo
// ---------------------------------------------------------------------------

export const RAZONES = {
  codigo_proveedor: 'Mismo código del proveedor',
  sku: 'Mismo SKU',
  nombre: 'Parecido por nombre'
}

export function textoDeRazon(c) {
  if (c.razon === 'nombre') return `${RAZONES.nombre} (${Math.round(c.puntaje * 100)} %)`
  return RAZONES[c.razon] || ''
}

// `catalogo`: [{ id, sku, nombre, ... }]. `vinculos`: [{ producto_id, proveedor, proveedor_sku }] (los
// códigos que cada proveedor le da a cada pieza). Devuelve los mejores candidatos, el más seguro primero.
export function candidatos(linea, { productos = [], vinculos = [], proveedor = '' } = {}, max = 5) {
  const mejor = new Map()
  const poner = (producto, puntaje, razon) => {
    const previo = mejor.get(producto.id)
    if (!previo || puntaje > previo.puntaje) mejor.set(producto.id, { producto, puntaje, razon })
  }
  const porId = new Map(productos.map(p => [p.id, p]))
  const codigo = codigoCompacto(linea?.codigo)
  const prov = normalizarTexto(proveedor)

  if (codigo) {
    for (const v of vinculos) {
      if (normalizarTexto(v.proveedor) === prov && codigoCompacto(v.proveedor_sku) === codigo) {
        const p = porId.get(v.producto_id)
        if (p) poner(p, 1, 'codigo_proveedor')
      }
    }
    for (const p of productos) {
      if (codigoCompacto(p.sku) === codigo) poner(p, 0.95, 'sku')
    }
  }

  const descripcion = String(linea?.descripcion ?? '')
  if (tokens(descripcion).length > 0) {
    for (const p of productos) {
      const s = parecido(descripcion, p.nombre)
      if (s >= 0.4) poner(p, s, 'nombre')
    }
  }

  return [...mejor.values()].sort((a, b) => b.puntaje - a.puntaje).slice(0, max)
}

// Qué se propone para una línea. `certeza` se dice con palabra en la pantalla:
//   segura     → el código del proveedor ya estaba ligado a esa pieza
//   probable   → mismo SKU o nombre muy parecido: se preselecciona pero se pide revisar
//   dudosa     → hay candidatos flojos: NO se preselecciona nada, hay que decidir
//   sin_pareja → nada se le parece: se propone crear una pieza nueva
export function decisionInicial(cands) {
  const top = cands?.[0]
  if (top && top.razon === 'codigo_proveedor') return { tipo: 'producto', producto_id: top.producto.id, certeza: 'segura' }
  if (top && top.razon === 'sku') return { tipo: 'producto', producto_id: top.producto.id, certeza: 'probable' }
  if (top && top.puntaje >= 0.75) return { tipo: 'producto', producto_id: top.producto.id, certeza: 'probable' }
  if (top) return { tipo: 'pendiente', certeza: 'dudosa' }
  return { tipo: 'nuevo', certeza: 'sin_pareja' }
}

export const TEXTO_CERTEZA = {
  segura: 'Segura',
  probable: 'Revisa',
  dudosa: 'Dudosa',
  sin_pareja: 'Sin pareja'
}

// Un nombre de proveedor ya conocido, para no partir un mismo proveedor en dos por cómo viene
// impreso ("CUMMINS MEXICO S.A. DE C.V." y "Cummins México" son el mismo).
export function proveedorSugerido(leido, conocidos = []) {
  const buscado = normalizarTexto(leido)
  if (!buscado) return ''
  let mejor = { nombre: '', puntaje: 0 }
  for (const c of conocidos) {
    const n = normalizarTexto(c)
    if (!n) continue
    if (n === buscado) return c
    const s = parecido(leido, c, SOCIETARIOS)
    if (s > mejor.puntaje) mejor = { nombre: c, puntaje: s }
  }
  return mejor.puntaje >= 0.6 ? mejor.nombre : ''
}

// SKU propuesto para una pieza nueva: el código del proveedor, limpio y en mayúsculas. Sin código
// no se inventa nada: queda vacío y el admin lo escribe.
export function skuSugerido(codigo) {
  return String(codigo ?? '').trim().toUpperCase().replace(/\s+/g, '-').replace(/[^A-Z0-9._/-]/g, '')
}

// ---------------------------------------------------------------------------
// Revisión: validar y armar lo que va a la base
// ---------------------------------------------------------------------------

// `lineas` es lo que está en pantalla: cada una con { codigo, descripcion, cantidad, costo_unitario,
// decision: { tipo: 'producto'|'nuevo'|'omitir'|'pendiente', producto_id, nuevo:{sku,nombre,categoria,unidad} } }.
export function problemasDeRevision({ proveedor, lineas, skuExistentes = new Set() } = {}) {
  const faltas = []
  if (!String(proveedor ?? '').trim()) faltas.push('Escribe de quién se compró.')
  const activas = (lineas || []).filter(l => l.decision?.tipo !== 'omitir')
  if (activas.length === 0) faltas.push('No queda ninguna línea por registrar.')
  const pendientes = activas.filter(l => ['pendiente', 'buscar'].includes(l.decision?.tipo) ||
    (l.decision?.tipo === 'producto' && !l.decision?.producto_id)).length
  if (pendientes > 0) faltas.push(`Falta decidir qué hacer con ${pendientes} línea(s): elige la pieza, crea una nueva u omítela.`)
  if (activas.some(l => !(num(l.cantidad) > 0))) faltas.push('Hay una línea sin cantidad.')
  if (activas.some(l => num(l.costo_unitario) < 0)) faltas.push('Un costo no puede ser negativo.')

  const nuevas = activas.filter(l => l.decision?.tipo === 'nuevo')
  if (nuevas.some(l => !String(l.decision.nuevo?.sku ?? '').trim())) faltas.push('A una pieza nueva le falta el SKU.')
  if (nuevas.some(l => !String(l.decision.nuevo?.nombre ?? '').trim())) faltas.push('A una pieza nueva le falta el nombre.')
  if (nuevas.some(l => !String(l.decision.nuevo?.categoria ?? '').trim())) faltas.push('A una pieza nueva le falta la categoría.')
  const skus = nuevas.map(l => String(l.decision.nuevo?.sku ?? '').trim().toUpperCase()).filter(Boolean)
  const repetido = skus.find((s, i) => skus.indexOf(s) !== i)
  if (repetido) faltas.push(`El SKU ${repetido} está en dos piezas nuevas de la misma factura.`)
  const yaExiste = skus.find(s => skuExistentes.has(s))
  if (yaExiste) faltas.push(`El SKU ${yaExiste} ya existe en el catálogo: elígelo en la lista en vez de crearlo.`)
  return faltas
}

// Las líneas tal como las espera `registrar_compra_de_factura`.
export function lineasParaRegistrar(lineas) {
  return (lineas || [])
    .filter(l => (l.decision?.tipo === 'producto' && l.decision.producto_id) || l.decision?.tipo === 'nuevo')
    .map(l => {
      const base = {
        codigo: String(l.codigo ?? '').trim() || null,
        cantidad: num(l.cantidad),
        costo_unitario: num(l.costo_unitario),
        ...(l.actualizar_costo ? { actualizar_costo: true } : {})
      }
      if (l.decision.tipo === 'nuevo') {
        const n = l.decision.nuevo || {}
        return {
          ...base,
          nuevo: {
            sku: String(n.sku ?? '').trim(),
            nombre: String(n.nombre ?? '').trim(),
            categoria: String(n.categoria ?? '').trim(),
            unidad: String(n.unidad ?? '').trim() || 'pieza'
          }
        }
      }
      return { ...base, producto_id: l.decision.producto_id }
    })
}

// ---------------------------------------------------------------------------
// Llamadas
// ---------------------------------------------------------------------------

const textoDeError = e => {
  const codigo = String(e?.code || '')
  if (['22023', 'P0002', '42501', 'P0001'].includes(codigo) && e?.message) return e.message
  if (codigo === '23505') return 'Esa factura de ese proveedor ya está capturada.'
  return explicarError(e).texto
}

const limpiarNombre = n =>
  String(n || 'factura').replace(/\.[^.]+$/, '').normalize('NFD').replace(/[̀-ͯ]/g, '')
    .replace(/[^a-zA-Z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40) || 'factura'

export const esPdf = f => f?.type === 'application/pdf' || /\.pdf$/i.test(f?.name || '')
export const esImagen = f => /^image\//.test(f?.type || '')

// lecturas/<marca>-<nombre>.<ext>: la marca evita que dos facturas se pisen.
export const rutaDeLectura = (nombre, pdf, marca = Date.now()) =>
  `lecturas/${marca}-${limpiarNombre(nombre)}.${pdf ? 'pdf' : 'jpg'}`

export async function subirParaLeer(archivo) {
  try {
    if (!esPdf(archivo) && !esImagen(archivo)) return { error: 'La factura tiene que ser una foto o un PDF.' }
    const pdf = esPdf(archivo)
    const cuerpo = pdf ? archivo : await redimensionar(archivo, 2000, 0.85)
    const ruta = rutaDeLectura(archivo.name, pdf)
    const { error } = await supabase.storage.from(BUCKET)
      .upload(ruta, cuerpo, { upsert: true, contentType: pdf ? 'application/pdf' : 'image/jpeg' })
    if (error) return { error: `No se pudo subir la factura: ${textoDeError(error)}` }
    return { ruta }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}

export async function leerFactura(ruta) {
  try {
    const { data, error } = await supabase.functions.invoke('leer-comprobante', { body: { ruta, modo: 'factura' } })
    if (error) {
      // La función devuelve el motivo en el cuerpo; `invoke` solo trae el código.
      let detalle = ''
      try { detalle = (await error.context?.json())?.error || '' } catch { /* sin cuerpo */ }
      return { error: detalle || 'No se pudo leer la factura.' }
    }
    if (data?.error) return { error: data.error }
    if (!data?.ok) return { error: 'No entendí lo que devolvió el modelo.' }
    return { lectura: normalizarLectura(data.leido), uso: data.uso || null }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}

export async function cargarVinculos() {
  try {
    const { data, error } = await todasLasFilas(() => supabase.from('producto_proveedores')
      .select('producto_id, proveedor, proveedor_sku')
      .order('producto_id').order('proveedor'))
    if (error) return { error: textoDeError(error) }
    return { vinculos: data || [] }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}

export async function registrarCompraDeFactura(datos, lineas) {
  try {
    const { data, error } = await supabase.rpc('registrar_compra_de_factura', {
      p_datos: datos,
      p_lineas: lineasParaRegistrar(lineas)
    })
    if (error) return { error: textoDeError(error) }
    return { datos: data }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}
