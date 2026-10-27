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
      .select('id, direccion, tipo, texto, estado, enviado_por, wa_timestamp, created_at, media_id, media_ruta, media_mime, media_nombre, media_error')
      .eq('conversacion_id', conversacionId)
      .order('created_at')
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true, mensajes: data || [] }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

// ---- fotos, documentos y audios (SQL 87) ----

export const BUCKET_MEDIA = 'whatsapp'
const DIAS_EN_META = 30

// Cómo se muestra el archivo de un mensaje: 'imagen' | 'audio' | 'video' | 'documento',
// o null si el mensaje no trae archivo. Manda el tipo real del archivo; sin él, el del mensaje.
export function claseMedia(m) {
  if (!m?.media_id && !m?.media_ruta) return null
  const mime = String(m.media_mime || '')
  if (mime.startsWith('image/')) return 'imagen'
  if (mime.startsWith('audio/')) return 'audio'
  if (mime.startsWith('video/')) return 'video'
  if (mime) return 'documento'
  return { imagen: 'imagen', audio: 'audio', documento: 'documento' }[m.tipo] || 'documento'
}

const NOMBRES = { imagen: 'La foto', audio: 'El audio', video: 'El video', documento: 'El documento' }

// Qué pasa con un archivo que todavía no está en el CRM, en palabras, y si aún se puede traer.
export function estadoArchivo(m, ahora = new Date()) {
  if (!m?.media_id || m.media_ruta) return null
  const quien = NOMBRES[claseMedia(m)] || 'El archivo'
  const fecha = new Date(m.wa_timestamp || m.created_at)
  const vencido = Number.isFinite(+fecha) && (ahora - fecha) > DIAS_EN_META * 86400000
  if (vencido) return { puede: false, texto: `${quien} ya no se puede traer: Meta lo borra a los 30 días.` }
  if (m.media_error) return { puede: true, texto: `${quien} no se pudo guardar: ${m.media_error}` }
  return { puede: true, texto: `${quien} todavía está en Meta y no se ha guardado.` }
}

// Enlaces firmados (1 hora) de los archivos de una conversación, por ruta. Solo el admin
// puede leer el bucket; sin enlace, la burbuja dice que no se pudo abrir.
export async function enlacesArchivos(mensajes) {
  const rutas = [...new Set((mensajes || []).map(m => m.media_ruta).filter(Boolean))]
  if (!rutas.length) return {}
  try {
    const { data } = await supabase.storage.from(BUCKET_MEDIA).createSignedUrls(rutas, 3600)
    return Object.fromEntries((data || []).filter(x => x.signedUrl).map(x => [x.path, x.signedUrl]))
  } catch {
    return {}
  }
}

// Trae de Meta lo que falta (Edge Function `media-whatsapp`). Con `mensajeId`, solo ese.
export async function traerArchivos(mensajeId = null) {
  try {
    const { data, error } = await supabase.functions.invoke('media-whatsapp', {
      body: mensajeId ? { mensaje: mensajeId } : {},
    })
    if (error) {
      let detalle = ''
      try { detalle = (await error.context?.json())?.error || '' } catch { /* sin cuerpo */ }
      return { ok: false, texto: detalle || 'No se pudo hablar con Meta.' }
    }
    if (data?.error) return { ok: false, texto: data.error }
    return { ok: true, ...data }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

// El resultado de traer archivos, en una frase.
export function resumenTraidos(r) {
  if (!r?.revisados) return 'No había archivos pendientes de los últimos 30 días.'
  const partes = []
  if (r.guardados) partes.push(r.guardados === 1 ? 'Se guardó 1 archivo.' : `Se guardaron ${r.guardados} archivos.`)
  if (r.fallidos) partes.push(`${r.fallidos === 1 ? '1 no se pudo' : `${r.fallidos} no se pudieron`}: ${(r.errores || []).join(' ')}`)
  return partes.join(' ')
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
// ¿Qué toca mostrar arriba de "Responder"? (pura; los mensajes vienen del más viejo al más nuevo)
// · { borrador }   el agente ya sugirió algo después del último mensaje del cliente
// · { pedir: true } el cliente escribió y nadie le ha contestado ni hay sugerencia
// · null           ya se le contestó (o no hay mensajes del cliente)
export function estadoSugerencia(mensajes = []) {
  let ultimoCliente = -1
  mensajes.forEach((m, i) => { if (m.direccion === 'entrante') ultimoCliente = i })
  if (ultimoCliente < 0) return null
  const despues = mensajes.slice(ultimoCliente + 1).filter(m => m.direccion === 'saliente')
  const borrador = [...despues].reverse().find(esBorrador)
  if (borrador) return { borrador }
  return despues.length ? null : { pedir: true }
}

// Le pide al agente una sugerencia para esta conversación. Queda guardada como borrador: nunca
// se envía sola, aunque el agente esté en automático o apagado.
export async function pedirSugerencia(conversacionId) {
  try {
    const { data, error } = await supabase.functions.invoke('agente-whatsapp', {
      body: { conversacion: conversacionId, solo_sugerir: true },
    })
    if (error) {
      let detalle = ''
      try {
        const cuerpo = await error.context?.json()
        detalle = [cuerpo?.error, cuerpo?.detalle].filter(Boolean).join(' · ')
      } catch { /* sin cuerpo */ }
      return { ok: false, texto: detalle || 'No se pudo hablar con el agente.' }
    }
    if (data?.error) return { ok: false, texto: data.error }
    if (data?.omitido) return { ok: false, texto: `El agente no sugirió nada: ${data.motivo}.` }
    return { ok: true, texto: data?.texto || '' }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

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
