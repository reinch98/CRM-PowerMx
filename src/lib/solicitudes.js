// ---------------------------------------------------------------------------
// Solicitudes de material: el técnico pide una pieza que necesita (típicamente para la
// siguiente visita), sin ver costos ni precios. Es una SOLICITUD, no una requisición: la
// requisición (compras, solo admin) sigue viviendo en Requisiciones.jsx. Esta tabla no
// mueve inventario por sí sola: solo coordina al técnico con el almacén/admin.
//
// La base (19_solicitudes_material.sql) es la que manda: RLS decide quién ve y crea qué.
// Aquí solo hay reglas puras (validar antes de enviar, poner las cosas en palabras) y las
// llamadas de red.
// ---------------------------------------------------------------------------

import { supabase } from './supabase'
import { explicarError } from './errores'

export const ESTADOS = { pendiente: 'Pendiente', atendida: 'Atendida', descartada: 'Descartada' }
export const etiquetaEstado = e => ESTADOS[e] ?? e

// Lo que se muestra de una pieza: la del catálogo (sku — nombre) o la descripción libre.
export const nombrePieza = s => (s.sku ? `${s.sku} — ${s.nombre}` : s.descripcion_libre || 'Pieza')

// ¿Se puede enviar? null si está bien.
export function problemaDeSolicitud({ productoId, descripcion, cantidad }) {
  if (!productoId && !String(descripcion ?? '').trim()) {
    return 'Elige una pieza del catálogo o escribe una descripción.'
  }
  const n = Number(cantidad)
  if (!Number.isFinite(n) || n <= 0) return 'La cantidad debe ser mayor que cero.'
  return null
}

function textoDeError(error) {
  const codigo = String(error?.code || '')
  if (['22023', 'P0002', '42501'].includes(codigo) && error?.message) return error.message
  return explicarError(error).texto
}

// ---- técnico ----

const SELECCION = 'id, folio, sku, nombre, unidad, descripcion_libre, cantidad, nota, estado, resolucion, created_at'

export async function crearSolicitud({ ordenId, tecnicoId, productoId, descripcion, cantidad, nota }) {
  try {
    const { error } = await supabase.from('solicitudes_material').insert([{
      tecnico_id: tecnicoId,
      orden_id: ordenId,
      producto_id: productoId || null,
      descripcion_libre: productoId ? null : (descripcion || '').trim() || null,
      cantidad: Number(cantidad),
      nota: (nota || '').trim() || null
    }])
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

export async function cargarSolicitudesDeOrden(ordenId) {
  try {
    const { data, error } = await supabase.from('solicitudes_material')
      .select(SELECCION).eq('orden_id', ordenId).order('created_at', { ascending: false })
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true, solicitudes: data || [] }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

// Solo mientras sigue pendiente (la base lo exige también: RLS).
export async function cancelarSolicitud(id) {
  try {
    const { error } = await supabase.from('solicitudes_material').update({ estado: 'descartada' }).eq('id', id)
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

// ---- almacén / admin ----

async function llamar(nombre, args) {
  try {
    const { data, error } = await supabase.rpc(nombre, args)
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true, data }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

export async function cargarSolicitudesPendientes() {
  const r = await llamar('solicitudes_material_pendientes')
  return r.ok ? { ok: true, solicitudes: r.data || [] } : r
}

export const atenderSolicitud = (id, resolucion) =>
  llamar('atender_solicitud_material', { p_id: id, p_resolucion: resolucion })

export const descartarSolicitud = (id, motivo) =>
  llamar('descartar_solicitud_material', { p_id: id, p_motivo: motivo })
