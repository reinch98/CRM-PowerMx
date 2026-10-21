// Fotos y documentos de WhatsApp (SQL 87): cómo se nombra el archivo y qué pasa en cada
// tropiezo con Meta. Lo que aquí se cuida: que un audio "audio/ogg; codecs=opus" se guarde
// con un tipo que Storage acepta, que el wamid no rompa la ruta, y que un fallo deje su
// motivo en la base en vez de tirar el webhook.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mimeBase, extensionDe, rutaMedia, motivoMeta, bajarMedia, MAX_BYTES } from '../supabase/functions/_shared/mediaWa.js'

test('mimeBase quita los parámetros', () => {
  assert.equal(mimeBase('audio/ogg; codecs=opus'), 'audio/ogg')
  assert.equal(mimeBase('IMAGE/JPEG'), 'image/jpeg')
  assert.equal(mimeBase(null), 'application/octet-stream')
})

test('extensión por tipo, o por el nombre del documento', () => {
  assert.equal(extensionDe('image/jpeg'), 'jpg')
  assert.equal(extensionDe('audio/ogg; codecs=opus'), 'ogg')
  assert.equal(extensionDe('application/octet-stream', 'Factura A-12.XML'), 'xml')
  assert.equal(extensionDe('application/x-raro'), 'bin')
})

test('la ruta no lleva símbolos del wamid', () => {
  assert.equal(rutaMedia('c1', 'wamid.HBgM=+/x', 'image/png'), 'c1/wamid.HBgM___x.png')
})

test('motivos de Meta en palabras', () => {
  assert.match(motivoMeta(404, {}), /30 días/)
  assert.match(motivoMeta(400, { error: { code: 100 } }), /30 días/)
  assert.match(motivoMeta(401, { error: { code: 190 } }), /token/)
})

// ---- bajarMedia con Meta y Supabase de mentira ----
function supabaseFalso({ errorSubida = null } = {}) {
  const llamadas = { rpc: [], subidas: [] }
  return {
    llamadas,
    rpc: async (nombre, args) => { llamadas.rpc.push([nombre, args]); return { data: { ok: true }, error: null } },
    storage: { from: bucket => ({ upload: async (ruta, bytes, op) => {
      llamadas.subidas.push({ bucket, ruta, n: bytes.length, op })
      return { error: errorSubida }
    } }) },
  }
}
const respuesta = (status, cuerpo, bytes = null) => ({
  ok: status >= 200 && status < 300, status,
  json: async () => cuerpo,
  arrayBuffer: async () => (bytes ?? new Uint8Array(0)).buffer,
  headers: { get: () => null },
})
const mensaje = { wa_message_id: 'wamid.A=', media_id: 'm1', conversacion_id: 'c1', nombre: null }

test('camino feliz: pide la dirección, baja con el token, sube y anota', async () => {
  const sb = supabaseFalso()
  const pedidas = []
  const f = async (url, op) => {
    pedidas.push([url, op.headers.Authorization])
    return url.includes('/m1') ? respuesta(200, { url: 'https://meta/archivo', mime_type: 'image/jpeg', file_size: 3 })
      : respuesta(200, null, new Uint8Array([1, 2, 3]))
  }
  const r = await bajarMedia({ sb, token: 'T', fetch: f }, mensaje)
  assert.deepEqual(r, { ok: true, ruta: 'c1/wamid.A_.jpg' })
  assert.deepEqual(pedidas.map(p => p[1]), ['Bearer T', 'Bearer T'])
  assert.deepEqual(sb.llamadas.subidas[0], { bucket: 'whatsapp', ruta: 'c1/wamid.A_.jpg', n: 3, op: { contentType: 'image/jpeg', upsert: true } })
  assert.equal(sb.llamadas.rpc[0][1].p_ruta, 'c1/wamid.A_.jpg')
})

test('Meta ya no lo tiene: no sube nada y deja el motivo', async () => {
  const sb = supabaseFalso()
  const r = await bajarMedia({ sb, token: 'T', fetch: async () => respuesta(404, { error: { code: 100 } }) }, mensaje)
  assert.equal(r.ok, false)
  assert.equal(sb.llamadas.subidas.length, 0)
  assert.match(sb.llamadas.rpc[0][1].p_error, /30 días/)
})

test('muy pesado: no se baja', async () => {
  const sb = supabaseFalso()
  let bajadas = 0
  const f = async () => { bajadas++; return respuesta(200, { url: 'https://meta/x', mime_type: 'video/mp4', file_size: MAX_BYTES + 1 }) }
  const r = await bajarMedia({ sb, token: 'T', fetch: f }, mensaje)
  assert.equal(r.ok, false)
  assert.equal(bajadas, 1)
  assert.match(r.error, /25 MB/)
})

test('sin token, sin red o con Storage fallando: nunca lanza', async () => {
  assert.match((await bajarMedia({ sb: supabaseFalso(), token: '' }, mensaje)).error, /WHATSAPP_TOKEN/)
  const sinRed = await bajarMedia({ sb: supabaseFalso(), token: 'T', fetch: async () => { throw new Error('sin red') } }, mensaje)
  assert.match(sinRed.error, /sin red/)
  const f = async url => url.includes('/m1') ? respuesta(200, { url: 'u', mime_type: 'application/pdf' }) : respuesta(200, null, new Uint8Array([1]))
  const r = await bajarMedia({ sb: supabaseFalso({ errorSubida: { message: 'cuota' } }), token: 'T', fetch: f }, mensaje)
  assert.match(r.error, /cuota/)
})
