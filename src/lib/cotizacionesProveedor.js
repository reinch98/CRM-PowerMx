// Cotizaciones de proveedor (SQL 84): lo que un proveedor nos cotiza. Solo admin (lleva costos).
//
// Se lee con IA (leer-comprobante, modo "cotizacion") desde Compras o desde la bandeja de Finanzas,
// se revisa renglón por renglón con las mismas piezas del lector de facturas y se registra. NO mueve
// inventario; aceptarla crea los pedidos. Las reglas que deciden viven en la base: aquí solo se
// prepara lo que se manda y se dice el estado con palabras.
import { supabase } from './supabase'
import { explicarError } from './errores'
import { redimensionar } from './imagen'
import { huellaDe, revisarArchivo } from './huellas'
import { normalizarLectura, problemasDeRevision, lineasParaRegistrar, aNumero, esPdf, esImagen } from './factura'
import { sumarDias } from './finanzas'

const BUCKET = 'compras'

const textoDeError = e => {
  const codigo = String(e?.code || '')
  if (['22023', '42501'].includes(codigo) && e?.message) return e.message
  return explicarError(e).texto
}
const rpc = async (nombre, args) => {
  try {
    const { data, error } = await supabase.rpc(nombre, args)
    if (error) return { error: textoDeError(error) }
    return { data }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}

// ---- lo que lee la IA ----

const texto = v => (typeof v === 'string' ? v.trim() : '')
const fechaValida = v => (/^\d{4}-\d{2}-\d{2}$/.test(texto(v)) ? texto(v) : '')

// La lectura de una factura más lo propio de una cotización: número y vigencia (como fecha, o
// calculada con "válida por N días" desde su fecha).
export function normalizarCotizacion(leido) {
  const l = leido && typeof leido === 'object' ? leido : {}
  const base = normalizarLectura(l)
  const dias = aNumero(l.vigencia_dias)
  const vigencia = fechaValida(l.vigencia) || (base.fecha && dias > 0 ? sumarDias(base.fecha, Math.round(dias)) : '')
  return {
    ...base,
    numero: texto(l.numero) || base.factura,
    vigencia,
    tiempo_entrega: texto(l.tiempo_entrega)
  }
}

// ---- revisión ----

export function problemasDeCotizacion({ proveedor, moneda, tipo_cambio, lineas, skuExistentes } = {}) {
  const faltas = problemasDeRevision({ proveedor, lineas, skuExistentes })
    .map(f => (f === 'Escribe de quién se compró.' ? 'Escribe de qué proveedor es la cotización.' : f))
  if (moneda === 'USD' && !(Number(tipo_cambio) > 0)) faltas.push('Escribe el tipo de cambio: la cotización está en dólares.')
  return faltas
}

// Los renglones tal como los espera registrar_cotizacion_proveedor: los del lector de facturas más
// la descripción impresa (queda en la cotización aunque la pieza del catálogo se llame distinto).
export function lineasParaCotizacion(lineas) {
  return (lineas || [])
    .filter(l => (l.decision?.tipo === 'producto' && l.decision.producto_id) || l.decision?.tipo === 'nuevo')
    .map(l => ({ ...lineasParaRegistrar([l])[0], descripcion: String(l.descripcion ?? '').trim() || null }))
}

// ---- cómo se dice ----

export function estadoCotizacion(c) {
  if (c?.estado === 'vigente' && c?.vencida) return { etiqueta: 'Vencida', clase: 'estado-vencida' }
  return {
    vigente: { etiqueta: 'Vigente', clase: 'estado-enviada' },
    aceptada: { etiqueta: 'Aceptada', clase: 'estado-aceptada' },
    rechazada: { etiqueta: 'Rechazada', clase: 'estado-rechazada' },
    cancelada: { etiqueta: 'Cancelada', clase: 'estado-cancelada' }
  }[c?.estado] || { etiqueta: c?.estado || '—', clase: '' }
}

export function dinero(v, moneda = 'MXN') {
  const n = Number(v || 0)
  return moneda === 'USD'
    ? `USD ${n.toLocaleString('es-MX', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
    : n.toLocaleString('es-MX', { style: 'currency', currency: 'MXN' })
}

const plural = (n, uno, varios) => `${n} ${n === 1 ? uno : varios}`

// "Aceptada: se hicieron 2 pedidos nuevos y se tomó 1 pedido que estaba pendiente."
export function textoAceptada(r) {
  if (r?.sin_cambio) return 'Esa cotización ya estaba aceptada.'
  const nuevos = Number(r?.pedidos_nuevos || 0)
  const tomados = Number(r?.pedidos_tomados || 0)
  const partes = []
  if (nuevos > 0) partes.push(`se ${nuevos === 1 ? 'hizo' : 'hicieron'} ${plural(nuevos, 'pedido nuevo', 'pedidos nuevos')}`)
  if (tomados > 0) partes.push(`se ${tomados === 1 ? 'tomó' : 'tomaron'} ${plural(tomados, 'pedido que estaba pendiente', 'pedidos que estaban pendientes')}`)
  return `Aceptada: ${partes.length ? partes.join(' y ') : 'no hizo falta pedir nada'}. Los ves en Pedidos como "pedida".`
}

// ---- llamadas ----

const limpiarNombre = n =>
  String(n || 'cotizacion').replace(/\.[^.]+$/, '').normalize('NFD').replace(/[̀-ͯ]/g, '')
    .replace(/[^a-zA-Z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40) || 'cotizacion'

// Sube el archivo UNA vez para leerlo. Si ya es una cotización registrada (o una compra), no se sube
// ni se gasta una lectura de IA (SQL 81 y 84).
export async function subirCotizacion(archivo) {
  try {
    if (!esPdf(archivo) && !esImagen(archivo)) return { error: 'La cotización tiene que ser un PDF o una foto.' }
    const hash = await huellaDe(archivo)
    const rep = await revisarArchivo(hash, 'compras')
    if (rep.repetido) return { error: rep.texto, repetido: true }
    const pdf = esPdf(archivo)
    const cuerpo = pdf ? archivo : await redimensionar(archivo, 2000, 0.85)
    const ruta = `cotizaciones/${Date.now()}-${limpiarNombre(archivo.name)}.${pdf ? 'pdf' : 'jpg'}`
    const { error } = await supabase.storage.from(BUCKET)
      .upload(ruta, cuerpo, { upsert: true, contentType: pdf ? 'application/pdf' : 'image/jpeg' })
    if (error) return { error: `No se pudo subir la cotización: ${textoDeError(error)}` }
    return { ruta, bucket: BUCKET, hash, nombre: archivo.name }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}

export async function leerCotizacion(ruta, bucket = BUCKET) {
  try {
    const { data, error } = await supabase.functions.invoke('leer-comprobante', { body: { ruta, bucket, modo: 'cotizacion' } })
    if (error) {
      let detalle = ''
      try { detalle = (await error.context?.json())?.error || '' } catch { /* sin cuerpo */ }
      return { error: detalle || 'No se pudo leer la cotización.' }
    }
    if (data?.error) return { error: data.error }
    if (!data?.ok) return { error: 'No entendí lo que devolvió el modelo.' }
    return { lectura: normalizarCotizacion(data.leido) }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}

export async function ultimoTipoCambio() {
  try {
    const { data } = await supabase.from('tipos_cambio').select('valor, fecha')
      .eq('moneda', 'USD').order('fecha', { ascending: false }).limit(1)
    return data?.[0] || null
  } catch {
    return null
  }
}

export const registrarCotizacion = (datos, lineas) =>
  rpc('registrar_cotizacion_proveedor', { p_datos: datos, p_lineas: lineasParaCotizacion(lineas) })
export const cargarCotizaciones = (proveedorId = null) =>
  rpc('cotizaciones_proveedor_lista', { p_proveedor: proveedorId || null })
export const aceptarCotizacion = id => rpc('aceptar_cotizacion_proveedor', { p_id: id })
export const cambiarEstadoCotizacion = (id, estado, motivo) =>
  rpc('cambiar_estado_cotizacion_proveedor', { p_id: id, p_estado: estado, p_motivo: motivo || null })

export async function urlDeCotizacion(ruta, bucket = BUCKET) {
  try {
    const { data } = await supabase.storage.from(bucket).createSignedUrl(ruta, 300)
    return data?.signedUrl || null
  } catch {
    return null
  }
}
