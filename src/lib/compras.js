// ---------------------------------------------------------------------------
// Compras: lo que entra al almacén, de quién y a cómo (SQL 41).
//
// Reglas puras aparte de las llamadas, porque aquí hay DINERO: el total que ve el admin en
// pantalla antes de guardar tiene que ser el mismo que calcula la base al registrar. Si los
// dos lo calcularan distinto, nadie se enteraría hasta cuadrar con el proveedor.
//
// Quién mueve el inventario lo decide la BASE, no esta pantalla (ver el encabezado del SQL 41):
// una línea ligada a un pedido que ya se recibió solo aporta costo y factura.
// ---------------------------------------------------------------------------

import { supabase } from './supabase'
import { explicarError } from './errores'
import { todasLasFilas } from './paginar'
import { huellaDe, revisarArchivo, anotarArchivo } from './huellas'

const BUCKET = 'compras'
export const IVA = 0.16

const num = v => {
  const n = Number(v)
  return Number.isFinite(n) ? n : 0
}
const centavos = n => Math.round(n * 100) / 100

// ---- reglas puras ----

export const importeLinea = l => centavos(num(l?.cantidad) * num(l?.costo_unitario))

// Los mismos números que `registrar_compra`: subtotal de las líneas, IVA del 16% si no se
// captura uno distinto (una factura con IVA exento o con retenciones se escribe a mano).
export function totalesDeCompra(lineas, ivaCapturado) {
  const subtotal = centavos((lineas || []).reduce((n, l) => n + importeLinea(l), 0))
  const iva = ivaCapturado === '' || ivaCapturado == null
    ? centavos(subtotal * IVA)
    : centavos(num(ivaCapturado))
  return { subtotal, iva, total: centavos(subtotal + iva) }
}

// Qué falta para poder registrar. Vacío = se puede.
export function problemasDeCompra({ proveedor, lineas } = {}) {
  const faltas = []
  if (!String(proveedor ?? '').trim()) faltas.push('Escribe de quién se compró.')
  const buenas = (lineas || []).filter(l => l?.producto_id)
  if (buenas.length === 0) faltas.push('Agrega al menos una pieza.')
  if (buenas.some(l => num(l.cantidad) <= 0)) faltas.push('Hay una pieza sin cantidad.')
  if (buenas.some(l => num(l.costo_unitario) < 0)) faltas.push('Un costo no puede ser negativo.')
  return faltas
}

// ¿El costo de la factura difiere del que tiene el catálogo? Sirve para preguntar si se
// actualiza, nunca para hacerlo solo: una compra de urgencia a sobreprecio no debe reescribir
// el costo de referencia sin que alguien lo decida.
export function cambioDeCosto(linea, costoCatalogo) {
  const nuevo = num(linea?.costo_unitario)
  const viejo = Number(costoCatalogo)
  if (!Number.isFinite(viejo) || viejo <= 0) return { hay: false, primero: true, nuevo }
  const diferencia = centavos(nuevo - viejo)
  if (diferencia === 0) return { hay: false, nuevo, viejo }
  return {
    hay: true, nuevo, viejo, diferencia,
    subio: diferencia > 0,
    // Cuánto cambió, en palabras: "subió de $285 a $310".
    texto: `${diferencia > 0 ? 'subió' : 'bajó'} de ${viejo} a ${nuevo}`,
  }
}

// Las líneas tal como las espera `registrar_compra`. Se tiran las vacías y no se manda
// `requisicion_id` en blanco: la base lo leería como un uuid inválido.
export function lineasParaGuardar(lineas) {
  return (lineas || [])
    .filter(l => l?.producto_id && num(l.cantidad) > 0)
    .map(l => ({
      producto_id: l.producto_id,
      cantidad: num(l.cantidad),
      costo_unitario: num(l.costo_unitario),
      ...(l.requisicion_id ? { requisicion_id: l.requisicion_id } : {}),
      ...(l.actualizar_costo ? { actualizar_costo: true } : {}),
    }))
}

// Una línea nueva a partir de un pedido por recibir: ya trae la pieza, la cantidad y el costo
// de referencia, que es lo que el proveedor debería estar cobrando.
export const lineaDesdePedido = p => ({
  producto_id: p.producto_id,
  sku: p.sku,
  nombre: p.nombre,
  unidad: p.unidad,
  cantidad: p.cantidad,
  costo_unitario: p.costo_referencia ?? '',
  requisicion_id: p.requisicion_id,
  pedido: p.folio,
})

export const lineaNueva = producto => ({
  producto_id: producto.id,
  sku: producto.sku,
  nombre: producto.nombre,
  unidad: producto.unidad,
  cantidad: 1,
  costo_unitario: producto.costo ?? '',
})

// ---- llamadas ----

function textoDeError(error) {
  const codigo = String(error?.code || '')
  if (['22023', 'P0002', '42501', 'P0001'].includes(codigo) && error?.message) return error.message
  // El índice único de proveedor + factura.
  if (codigo === '23505') return 'Esa factura de ese proveedor ya está capturada.'
  return explicarError(error).texto
}

async function llamar(nombre, args) {
  try {
    const { data, error } = await supabase.rpc(nombre, args)
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true, datos: data }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

export async function cargarCompras(dias = 90) {
  const r = await llamar('compras_recientes', { p_dias: dias })
  return r.ok ? { ok: true, compras: r.datos || [] } : r
}

export async function cargarPedidosPorRecibir() {
  const r = await llamar('pedidos_por_recibir')
  return r.ok ? { ok: true, pedidos: r.datos || [] } : r
}

// El catálogo con costos: esta pantalla es solo del admin, que sí lee `productos`.
export async function cargarProductos() {
  try {
    const { data, error } = await todasLasFilas(() => supabase.from('productos')
      .select('id, sku, nombre, unidad, costo, categoria')
      .eq('activo', true).order('sku'))
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true, productos: data || [] }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

export const registrarCompra = (datos, lineas) =>
  llamar('registrar_compra', { p_datos: datos, p_lineas: lineasParaGuardar(lineas) })

export const cancelarCompra = (id, motivo) =>
  llamar('cancelar_compra', { p_compra: id, p_motivo: motivo })

// Antes de registrar la compra: si el XML o el PDF ya están en otra compra, no se registra nada
// (si no, quedaría una compra nueva con la factura de otra). Devuelve el texto del problema o ''.
export async function archivosRepetidos(archivos) {
  for (const a of archivos.filter(Boolean)) {
    const rep = await revisarArchivo(await huellaDe(a), 'compras')
    if (rep.repetido) return `${a.name || 'El archivo'}: ${rep.texto}`
  }
  return ''
}

// La factura se sube DESPUÉS de registrar, porque la ruta cuelga del id de la compra. Si la
// subida falla, la compra ya quedó bien: el archivo se puede volver a adjuntar.
export async function adjuntarArchivo(compraId, archivo, tipo) {
  const ext = tipo === 'xml' ? 'xml' : 'pdf'
  const ruta = `${compraId}/factura.${ext}`
  try {
    const hash = await huellaDe(archivo)
    const rep = await revisarArchivo(hash, 'compras')
    if (rep.repetido) return { ok: false, texto: rep.texto }
    const { error } = await supabase.storage.from(BUCKET)
      .upload(ruta, archivo, { upsert: true })
    if (error) return { ok: false, texto: explicarError(error).texto }
    await anotarArchivo(BUCKET, ruta, hash, archivo.name)
    const campo = tipo === 'xml' ? 'archivo_xml' : 'archivo_pdf'
    const { error: e2 } = await supabase.from('compras').update({ [campo]: ruta }).eq('id', compraId)
    if (e2) return { ok: false, texto: textoDeError(e2) }
    return { ok: true, ruta }
  } catch (e) {
    return { ok: false, texto: explicarError(e).texto }
  }
}

export async function urlDeArchivo(ruta) {
  try {
    const { data, error } = await supabase.storage.from(BUCKET).createSignedUrl(ruta, 300)
    if (error) return null
    return data?.signedUrl || null
  } catch {
    return null
  }
}
