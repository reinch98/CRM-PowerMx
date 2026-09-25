// ---------------------------------------------------------------------------
// Bandeja de WhatsApp: reglas puras y llamadas a la base (22_whatsapp_bandeja.sql).
//
// Los mensajes ENTRAN por el webhook de Meta, que todavía no existe: hasta entonces la
// bandeja está vacía y la pantalla lo explica. Lo que ya sirve es el registro: una
// conversación por número, ligada sola al contacto cuando el número se conoce.
//
// **Ventana de 24 horas:** WhatsApp solo deja escribir libre durante 24 h desde el último
// mensaje del cliente. Fuera de eso hace falta una plantilla aprobada por Meta. La pantalla
// lo dice con palabras antes de que el envío falle.
// ---------------------------------------------------------------------------

import { supabase } from './supabase'
import { explicarError } from './errores'
import { normalizarTelefono } from './contactos'

// ---- reglas puras ----

export const ventanaAbierta = (conv, ahora = new Date()) =>
  !!conv?.ventana_hasta && new Date(conv.ventana_hasta) > ahora

// Cómo llamar a una conversación: la persona si se conoce, si no el nombre que manda
// WhatsApp (dato del cliente, no de confianza), y si no el número.
export function nombreConversacion(conv) {
  return conv?.contacto || conv?.nombre_wa || conv?.telefono || 'Sin nombre'
}

// "hace un momento", "hace 5 min", "hace 2 h", "hace 3 días". Sin fecha, null.
export function haceCuanto(iso, ahora = new Date()) {
  if (!iso) return null
  const minutos = Math.floor((ahora - new Date(iso)) / 60000)
  if (!Number.isFinite(minutos)) return null
  if (minutos < 1) return 'hace un momento'
  if (minutos < 60) return `hace ${minutos} min`
  const horas = Math.floor(minutos / 60)
  if (horas < 24) return `hace ${horas} h`
  const dias = Math.floor(horas / 24)
  return dias === 1 ? 'ayer' : `hace ${dias} días`
}

// Qué se puede hacer con esta conversación ahora mismo, en palabras.
export function estadoVentana(conv, ahora = new Date()) {
  if (!conv?.ventana_hasta) return { puede: false, texto: 'Sin mensajes del cliente todavía' }
  if (ventanaAbierta(conv, ahora)) {
    const hora = new Date(conv.ventana_hasta).toLocaleString('es-MX', { dateStyle: 'short', timeStyle: 'short' })
    return { puede: true, texto: `Puedes responder libremente hasta el ${hora}` }
  }
  return { puede: false, texto: 'Pasaron más de 24 horas: solo se puede escribir con una plantilla aprobada' }
}

// Enlace para abrir el chat con el texto listo. Mientras no exista la API, así se manda
// a mano (igual que los avisos de cita).
export function enlaceWhatsApp(telefono, texto) {
  const n = normalizarTelefono(telefono)
  if (!n) return null
  return `https://wa.me/52${n}?text=${encodeURIComponent(texto ?? '')}`
}

function textoDeError(error) {
  const codigo = String(error?.code || '')
  if (['22023', 'P0002', '42501'].includes(codigo) && error?.message) return error.message
  return explicarError(error).texto
}

// ---- llamadas ----

async function llamar(nombre, args) {
  try {
    const { data, error } = await supabase.rpc(nombre, args)
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true, data }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

export async function cargarBandeja(incluirCerradas = false) {
  const r = await llamar('bandeja_whatsapp', { p_incluir_cerradas: incluirCerradas })
  return r.ok ? { ok: true, conversaciones: r.data || [] } : r
}

export async function cargarMensajes(conversacionId) {
  try {
    const { data, error } = await supabase.from('mensajes_wa')
      .select('id, direccion, tipo, texto, estado, enviado_por, wa_timestamp, created_at')
      .eq('conversacion_id', conversacionId)
      .order('created_at')
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true, mensajes: data || [] }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

// Personas a las que se puede ligar un número desconocido.
export async function cargarContactos() {
  try {
    const { data, error } = await supabase.from('contactos')
      .select('id, nombre, telefono, cliente_id, clientes(nombre)')
      .eq('activo', true).order('nombre')
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true, contactos: data || [] }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

// Deja registrado lo que se respondió. NO lo manda: hasta que exista la API, el envío
// es a mano por el enlace de WhatsApp.
export const registrarRespuesta = (conversacionId, texto) =>
  llamar('registrar_mensaje_saliente', { p_conversacion: conversacionId, p_texto: texto })

// ---- el agente ----

export const esBorrador = m => m?.direccion === 'saliente' && m?.estado === 'borrador'

export async function cargarAgente() {
  try {
    const { data, error } = await supabase.from('wa_agente')
      .select('activo, modo, tope_dia, instrucciones').maybeSingle()
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true, agente: data || { activo: false, modo: 'borrador', tope_dia: 20 } }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

export async function guardarAgente(cambios) {
  try {
    const { error } = await supabase.from('wa_agente').update(cambios).eq('id', true)
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

// Un borrador que el admin sí mandó deja de ser borrador. Se marca aparte del enlace
// porque `wa.me` no avisa si de verdad se envió: por eso el texto sigue a la vista.
export async function marcarBorradorEnviado(id) {
  try {
    const { error } = await supabase.from('mensajes_wa').update({ estado: 'enviado' }).eq('id', id)
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

export const marcarLeida = id => llamar('marcar_conversacion_leida', { p_conversacion: id })
export const cerrarConversacion = (id, abrir = false) =>
  llamar('cerrar_conversacion', { p_conversacion: id, p_abrir: abrir })
export const vincularConversacion = (conversacionId, contactoId) =>
  llamar('vincular_conversacion', { p_conversacion: conversacionId, p_contacto: contactoId })
