// ---------------------------------------------------------------------------
// Fotos, documentos y audios que llegan por WhatsApp (SQL 87).
//
// Meta no manda el archivo en el aviso: manda un `media_id`. Para tenerlo hay que pedir
// (con el token) su dirección temporal, bajarlo con el mismo token y guardarlo nosotros,
// porque Meta lo borra a los 30 días. Esto lo hacen el webhook `whatsapp` (al llegar) y
// `media-whatsapp` (lo que ya había llegado, o un reintento a mano).
//
// JavaScript plano, como `whatsapp.js`: lo importan las funciones Deno y las pruebas de Node
// (`pruebas/mediaWa.prueba.js`), que le pasan un `fetch` y un cliente de Supabase falsos.
// ---------------------------------------------------------------------------

export const BUCKET_MEDIA = 'whatsapp'
export const MAX_BYTES = 25 * 1024 * 1024   // el tope del bucket (SQL 87)

// "audio/ogg; codecs=opus" → "audio/ogg". Storage compara el tipo sin parámetros.
export function mimeBase(mime) {
  return String(mime ?? '').split(';')[0].trim().toLowerCase() || 'application/octet-stream'
}

const EXTENSIONES = {
  'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'image/gif': 'gif',
  'audio/ogg': 'ogg', 'audio/mpeg': 'mp3', 'audio/mp4': 'm4a', 'audio/aac': 'aac', 'audio/amr': 'amr',
  'video/mp4': 'mp4', 'video/3gpp': '3gp',
  'application/pdf': 'pdf',
  'application/msword': 'doc',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx',
  'application/vnd.ms-excel': 'xls',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'xlsx',
  'text/plain': 'txt',
}

export function extensionDe(mime, nombre = null) {
  const porMime = EXTENSIONES[mimeBase(mime)]
  if (porMime) return porMime
  const m = /\.([a-z0-9]{1,5})$/i.exec(String(nombre ?? ''))
  return m ? m[1].toLowerCase() : 'bin'
}

// `<conversación>/<wamid>.<ext>`. El wamid trae "=" y otros símbolos: se dejan solo letras,
// números, punto, guion y guion bajo para que la ruta sea segura en Storage.
export function rutaMedia(conversacionId, waMessageId, mime, nombre = null) {
  const id = String(waMessageId ?? '').replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 120) || 'sin_id'
  return `${conversacionId}/${id}.${extensionDe(mime, nombre)}`
}

// Por qué Meta no dio el archivo, en palabras.
export function motivoMeta(status, cuerpo) {
  const codigo = Number(cuerpo?.error?.code)
  if (codigo === 190 || status === 401) return 'El token de Meta venció o no es válido: renueva WHATSAPP_TOKEN.'
  if (status === 404 || codigo === 100) return 'Meta ya no tiene el archivo (pasaron más de 30 días o se borró).'
  return `Meta no dio el archivo (${cuerpo?.error?.message || `HTTP ${status}`}).`
}

const megas = n => `${(n / 1024 / 1024).toFixed(1)} MB`

// Baja UN archivo de Meta, lo sube al bucket y deja el resultado en la base. Nunca lanza:
// devuelve { ok, ruta } o { ok: false, error } — un archivo que falla no debe tumbar a
// los demás ni al webhook.
//   m: { wa_message_id, media_id, conversacion_id, nombre? }
export async function bajarMedia({ sb, token, version = 'v23.0', fetch: f = fetch }, m) {
  const fallar = async error => {
    try {
      await sb.rpc('guardar_media_wa', { p_wa_message_id: m.wa_message_id, p_error: error })
    } catch { /* si ni eso se pudo, queda en el registro de la función */ }
    return { ok: false, error }
  }
  try {
    if (!token) return await fallar('Falta WHATSAPP_TOKEN en los secretos.')
    const auth = { Authorization: `Bearer ${token}` }

    const r1 = await f(`https://graph.facebook.com/${version}/${encodeURIComponent(m.media_id)}`, { headers: auth })
    const info = await r1.json().catch(() => ({}))
    if (!r1.ok || !info?.url) return await fallar(motivoMeta(r1.status, info))
    if (Number(info.file_size) > MAX_BYTES) {
      return await fallar(`Pesa ${megas(Number(info.file_size))}, más de lo que se guarda (25 MB): pídeselo al cliente por otro medio.`)
    }

    // La dirección que da Meta solo sirve unos minutos y también pide el token.
    const r2 = await f(info.url, { headers: auth })
    if (!r2.ok) return await fallar(`No se pudo bajar el archivo de Meta (HTTP ${r2.status}).`)
    const bytes = new Uint8Array(await r2.arrayBuffer())
    if (bytes.length > MAX_BYTES) return await fallar(`Pesa ${megas(bytes.length)}, más de 25 MB.`)

    const mime = mimeBase(info.mime_type || r2.headers?.get?.('content-type'))
    const ruta = rutaMedia(m.conversacion_id, m.wa_message_id, mime, m.nombre)
    const { error: es } = await sb.storage.from(BUCKET_MEDIA).upload(ruta, bytes, { contentType: mime, upsert: true })
    if (es) return await fallar(`No se pudo guardar en el CRM: ${es.message}`)

    const { error: eg } = await sb.rpc('guardar_media_wa', {
      p_wa_message_id: m.wa_message_id, p_ruta: ruta, p_mime: mime, p_nombre: m.nombre ?? null,
    })
    if (eg) return { ok: false, error: `Se guardó el archivo pero no se pudo anotar: ${eg.message}` }
    return { ok: true, ruta }
  } catch (e) {
    return await fallar(`No se pudo bajar: ${e instanceof Error ? e.message : String(e)}`)
  }
}
