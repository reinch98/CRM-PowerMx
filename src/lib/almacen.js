// ---------------------------------------------------------------------------
// Almacén: lo que pide la pantalla "Almacén" y la firma de recibido del técnico.
//
// Todo pasa por funciones de la base (14_almacen_entregas.sql): el almacenista no lee
// tablas. Necesita señal: el inventario se mueve al firmar, y eso no puede quedar en una
// cola. Las funciones devuelven mensajes en español cuando algo no procede ("Solo quedan
// 1 por entregar…"), así que se muestran tal cual.
// ---------------------------------------------------------------------------

import { supabase } from './supabase'
import { explicarError } from './errores'

const BUCKET = 'ordenes'

// ---- reglas puras (sin red) ----

// Lo que aún se puede entregar de una línea: pedido − entregado − lo que espera firma.
export const pendiente = l =>
  Math.max(0, Number(l.pedida) - Number(l.entregada) - Number(l.en_entrega || 0))

// Lo que conviene proponer entregar: lo pendiente, sin pasar de lo que hay en el estante.
export const sugerido = l => Math.max(0, Math.min(pendiente(l), Number(l.fisico) || 0))

// Estado con palabra (nunca solo color).
export function estadoLinea(l) {
  const entregada = Number(l.entregada)
  const pedida = Number(l.pedida)
  const porFirmar = Number(l.en_entrega || 0)
  if (entregada >= pedida) return 'Completo'
  if (entregada + porFirmar >= pedida) return 'Por firmar'
  if (pendiente(l) > 0 && (Number(l.fisico) || 0) <= 0) return 'Sin existencia'
  return entregada > 0 ? 'Parcial' : 'Sin entregar'
}

// Las cantidades capturadas → líneas para `crear_entrega`. Ignora vacíos, ceros y basura.
export function lineasParaEntrega(lineas, capturado) {
  const salida = []
  for (const l of lineas) {
    const texto = capturado[l.producto_id]
    const valor = Number(texto === undefined ? sugerido(l) : texto)
    if (Number.isFinite(valor) && valor > 0) salida.push({ producto_id: l.producto_id, cantidad: valor })
  }
  return salida
}

// ---- llamadas ----

// Un mensaje de la base (raise exception) es legible y se muestra tal cual; un corte de red
// o una sesión vencida pasan por explicarError.
function textoDe(error) {
  const codigo = String(error?.code || '')
  if (['22023', 'P0002', '42501', 'P0001'].includes(codigo) && error?.message) return error.message
  return explicarError(error).texto
}

async function llamar(nombre, args) {
  try {
    const { data, error } = await supabase.rpc(nombre, args)
    if (error) return { ok: false, texto: textoDe(error) }
    return { ok: true, data }
  } catch (e) {
    return { ok: false, texto: textoDe(e) }
  }
}

export async function cargarPorSurtir() {
  const r = await llamar('ordenes_por_surtir')
  return r.ok ? { ok: true, ordenes: r.data || [] } : r
}

// Piezas para agregar a mano a una lista: existencias no lleva precios ni costos.
export async function cargarExistencias() {
  try {
    const { data, error } = await supabase.from('existencias')
      .select('id, sku, nombre, unidad, fisico').order('nombre')
    if (error) return { ok: false, texto: textoDe(error) }
    return { ok: true, piezas: data || [] }
  } catch (e) {
    return { ok: false, texto: textoDe(e) }
  }
}

export const fijarSurtido = (orden, producto, cantidad) =>
  llamar('fijar_surtido', { p_orden: orden, p_producto: producto, p_cantidad: cantidad })

export const crearEntrega = (orden, lineas) =>
  llamar('crear_entrega', { p_orden: orden, p_lineas: lineas })

export const cancelarEntrega = entrega => llamar('cancelar_entrega', { p_entrega: entrega })

export const entregarSinFirma = (entrega, motivo) =>
  llamar('entregar_sin_firma', { p_entrega: entrega, p_motivo: motivo })

// ---- devoluciones y adicionales (18_uso_y_devoluciones.sql) ----

// Órdenes cerradas o canceladas con material que el técnico aún debe devolver.
export async function cargarDevoluciones() {
  const r = await llamar('devoluciones_pendientes')
  return r.ok ? { ok: true, devoluciones: r.data || [] } : r
}

export const recibirDevolucion = (orden, lineas, observaciones) =>
  llamar('recibir_devolucion', { p_orden: orden, p_lineas: lineas, p_observaciones: observaciones || null })

// Solo admin (la base lo exige): lo que nunca volvió se da por consumido, con motivo.
export const resolverDiferencia = (orden, producto, motivo) =>
  llamar('resolver_diferencia', { p_orden: orden, p_producto: producto, p_motivo: motivo })

// Lo que el técnico usó y no le entregaron.
export async function cargarAdicionales() {
  const r = await llamar('adicionales_por_conciliar')
  return r.ok ? { ok: true, adicionales: r.data || [] } : r
}

export const conciliarAdicional = (orden, nota) =>
  llamar('conciliar_adicional', { p_orden: orden, p_nota: nota || null })

// T1 firma de recibido. La imagen se sube primero; si la función falla, la firma queda
// sin uso en el bucket (inofensivo) y se puede reintentar: el mismo nombre se reemplaza.
export async function firmarEntrega(entrega, firmaPng) {
  const ruta = `entregas/${entrega}.png`
  try {
    const { error } = await supabase.storage.from(BUCKET)
      .upload(ruta, firmaPng, { contentType: 'image/png', upsert: true })
    if (error) return { ok: false, texto: explicarError(error).texto }
  } catch (e) {
    return { ok: false, texto: explicarError(e).texto }
  }
  return llamar('firmar_entrega', { p_entrega: entrega, p_firma: ruta })
}
