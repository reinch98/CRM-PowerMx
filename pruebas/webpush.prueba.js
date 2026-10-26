// Avisos push (SQL 90). Lo que se cuida: que el aviso salga cifrado de forma que el navegador
// lo pueda abrir (RFC 8291) y firmado de forma que el proveedor acepte la firma VAPID (RFC 8292).
// La prueba hace de navegador: genera sus llaves, descifra lo que mandamos y verifica la firma.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { cifrar, firmaVapid, avisoDeMensaje, mandarPush, avisarATodos, aB64url, deB64url, hkdf } from '../supabase/functions/_shared/webpush.js'

const enc = new TextEncoder()
const junta = (...p) => { const o = new Uint8Array(p.reduce((n, x) => n + x.length, 0)); let i = 0; for (const x of p) { o.set(x, i); i += x.length } return o }

async function navegador() {
  const llaves = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits'])
  const publica = new Uint8Array(await crypto.subtle.exportKey('raw', llaves.publicKey))
  const auth = crypto.getRandomValues(new Uint8Array(16))
  return { llaves, p256dh: aB64url(publica), auth: aB64url(auth), publica, authBytes: auth }
}

// Lo que hace el navegador al recibir el aviso (RFC 8291, lado del receptor).
async function descifrar(cuerpo, nav) {
  const sal = cuerpo.slice(0, 16)
  const largo = cuerpo[20]
  const asPublica = cuerpo.slice(21, 21 + largo)
  const cifrado = cuerpo.slice(21 + largo)
  const asLlave = await crypto.subtle.importKey('raw', asPublica, { name: 'ECDH', namedCurve: 'P-256' }, false, [])
  const ecdh = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: asLlave }, nav.llaves.privateKey, 256))
  const ikm = await hkdf(nav.authBytes, ecdh, junta(enc.encode('WebPush: info\0'), nav.publica, asPublica), 32)
  const cek = await hkdf(sal, ikm, enc.encode('Content-Encoding: aes128gcm\0'), 16)
  const nonce = await hkdf(sal, ikm, enc.encode('Content-Encoding: nonce\0'), 12)
  const llave = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['decrypt'])
  const claro = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: nonce }, llave, cifrado))
  assert.equal(claro[claro.length - 1], 2, 'el último byte marca el último registro')
  return new TextDecoder().decode(claro.slice(0, -1))
}

async function llavesVapid() {
  const par = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])
  const jwk = await crypto.subtle.exportKey('jwk', par.privateKey)
  const publica = new Uint8Array(await crypto.subtle.exportKey('raw', par.publicKey))
  return { publica: aB64url(publica), privada: jwk.d, contacto: 'https://crm.powermx.com.mx', par }
}

test('el navegador puede abrir el aviso', async () => {
  const nav = await navegador()
  const cuerpo = await cifrar('{"titulo":"Hola ñandú"}', nav.p256dh, nav.auth)
  assert.equal(cuerpo[16] * 2 ** 24 + cuerpo[17] * 2 ** 16 + cuerpo[18] * 256 + cuerpo[19], 4096)
  assert.equal(await descifrar(cuerpo, nav), '{"titulo":"Hola ñandú"}')
})

test('la firma VAPID es un JWT ES256 válido para el origen del proveedor', async () => {
  const v = await llavesVapid()
  const encabezado = await firmaVapid('https://fcm.googleapis.com/fcm/send/abc', v.publica, v.privada, v.contacto, Date.UTC(2026, 9, 24))
  const [, t, k] = /^vapid t=([^,]+), k=(.+)$/.exec(encabezado)
  assert.equal(k, v.publica)
  const [c, cuerpo, firma] = t.split('.')
  const datos = JSON.parse(new TextDecoder().decode(deB64url(cuerpo)))
  assert.equal(datos.aud, 'https://fcm.googleapis.com')
  assert.equal(datos.sub, 'https://crm.powermx.com.mx')
  const ok = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, v.par.publicKey, deB64url(firma), enc.encode(`${c}.${cuerpo}`))
  assert.equal(ok, true)
})

test('el texto del aviso: quién y qué, recortado; sin texto, dice qué mandó', () => {
  const a = avisoDeMensaje({ nombre: 'Adal', telefono: '5219991234567', texto: 'Hola,\n¿me cotizan?', tipo: 'texto' })
  assert.equal(a.titulo, 'WhatsApp · Adal')
  assert.equal(a.cuerpo, 'Hola, ¿me cotizan?')
  assert.equal(a.url, '/?ir=whatsapp')
  assert.equal(avisoDeMensaje({ telefono: '999', tipo: 'imagen' }).cuerpo, 'Mandó una foto')
  assert.equal(avisoDeMensaje({ texto: 'x'.repeat(300) }).cuerpo.length, 120)
})

test('un navegador que ya no existe (410) se marca para borrar; nunca lanza', async () => {
  const nav = await navegador()
  const v = await llavesVapid()
  const sus = { endpoint: 'https://fcm.googleapis.com/fcm/send/abc', p256dh: nav.p256dh, auth: nav.auth }
  assert.deepEqual(await mandarPush(sus, { titulo: 'x' }, v, async () => ({ status: 410 })), { ok: false, vivo: false, status: 410 })
  assert.equal((await mandarPush(sus, { titulo: 'x' }, v, async () => ({ status: 201 }))).ok, true)
  const sinRed = await mandarPush(sus, { titulo: 'x' }, v, async () => { throw new Error('sin red') })
  assert.equal(sinRed.vivo, true)
})

test('avisarATodos: manda a cada destino, borra el muerto y no truena sin llaves', async () => {
  const nav = await navegador()
  const v = await llavesVapid()
  const llamadas = []
  const sb = { rpc: async (n, a) => { llamadas.push([n, a]); return n === 'push_destinos'
    ? { data: [{ endpoint: 'https://a.push/1', p256dh: nav.p256dh, auth: nav.auth }, { endpoint: 'https://a.push/2', p256dh: nav.p256dh, auth: nav.auth }] }
    : { data: null } } }
  const r = await avisarATodos(sb, { titulo: 'x' }, v, async url => ({ status: url.endsWith('/2') ? 410 : 201 }))
  assert.equal(r.enviados, 1)
  assert.deepEqual(llamadas.filter(l => l[0] === 'push_resultado').map(l => l[1]),
    [{ p_endpoint: 'https://a.push/1', p_vivo: true }, { p_endpoint: 'https://a.push/2', p_vivo: false }])
  assert.match((await avisarATodos(sb, {}, {})).motivo, /VAPID/)
})
