// ---------------------------------------------------------------------------
// Avisos push (SQL 90): cómo se cifra y se manda una notificación a un navegador.
//
// Es el estándar Web Push que usan todos los sitios que avisan: el navegador del admin dio un
// "endpoint" (una dirección de su proveedor de avisos: Google, Apple o Mozilla) y dos llaves. El
// aviso viaja CIFRADO para ese navegador (RFC 8291, aes128gcm) y firmado con la llave VAPID de
// PowerMx (RFC 8292), así el proveedor sabe quién lo manda y nadie más puede leerlo.
//
// JavaScript plano con WebCrypto, sin dependencias: lo usan las funciones Deno (webhook
// `whatsapp` y `avisos-push`) y las pruebas de Node (`pruebas/webpush.prueba.js`), que lo
// descifran de vuelta para comprobar que está bien armado.
// ---------------------------------------------------------------------------

const enc = new TextEncoder()

export function aB64url(bytes) {
  let s = ''
  for (const b of new Uint8Array(bytes)) s += String.fromCharCode(b)
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

export function deB64url(texto) {
  const b = String(texto).replace(/-/g, '+').replace(/_/g, '/')
  const bin = atob(b + '='.repeat((4 - (b.length % 4)) % 4))
  return Uint8Array.from(bin, c => c.charCodeAt(0))
}

const juntar = (...partes) => {
  const total = partes.reduce((n, p) => n + p.length, 0)
  const out = new Uint8Array(total)
  let i = 0
  for (const p of partes) { out.set(p, i); i += p.length }
  return out
}

export async function hkdf(sal, ikm, info, bytes) {
  const llave = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits'])
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt: sal, info }, llave, bytes * 8))
}

// Cifra `texto` para el navegador dueño de (p256dh, auth). Devuelve el cuerpo listo para mandar.
export async function cifrar(texto, p256dhB64, authB64) {
  const uaPublica = deB64url(p256dhB64)
  const secretoAuth = deB64url(authB64)
  const efimera = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits'])
  const asPublica = new Uint8Array(await crypto.subtle.exportKey('raw', efimera.publicKey))
  const uaLlave = await crypto.subtle.importKey('raw', uaPublica, { name: 'ECDH', namedCurve: 'P-256' }, false, [])
  const ecdh = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaLlave }, efimera.privateKey, 256))

  const ikm = await hkdf(secretoAuth, ecdh, juntar(enc.encode('WebPush: info\0'), uaPublica, asPublica), 32)
  const sal = crypto.getRandomValues(new Uint8Array(16))
  const cek = await hkdf(sal, ikm, enc.encode('Content-Encoding: aes128gcm\0'), 16)
  const nonce = await hkdf(sal, ikm, enc.encode('Content-Encoding: nonce\0'), 12)

  const llaveAes = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt'])
  const claro = juntar(enc.encode(texto), new Uint8Array([2]))   // 2 = último registro
  const cifrado = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, llaveAes, claro))

  const rs = new Uint8Array([0, 0, 16, 0])                          // 4096, el tamaño de registro
  return juntar(sal, rs, new Uint8Array([asPublica.length]), asPublica, cifrado)
}

// Firma VAPID: un JWT ES256 que dice "esto lo manda PowerMx" al proveedor de avisos.
export async function firmaVapid(endpoint, publicaB64, privadaB64, contacto, ahora = Date.now()) {
  const pub = deB64url(publicaB64)
  const jwk = { kty: 'EC', crv: 'P-256', d: privadaB64, x: aB64url(pub.slice(1, 33)), y: aB64url(pub.slice(33, 65)), ext: true }
  const llave = await crypto.subtle.importKey('jwk', jwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'])
  const cabeza = aB64url(enc.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })))
  const cuerpo = aB64url(enc.encode(JSON.stringify({
    aud: new URL(endpoint).origin,
    exp: Math.floor(ahora / 1000) + 12 * 3600,
    sub: contacto,
  })))
  const firma = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, llave, enc.encode(`${cabeza}.${cuerpo}`))
  return `vapid t=${cabeza}.${cuerpo}.${aB64url(firma)}, k=${publicaB64}`
}

// El texto que se ve en la notificación. El mensaje del cliente se recorta: es un aviso, no el chat.
export function avisoDeMensaje({ nombre, telefono, texto, tipo }) {
  const quien = String(nombre || telefono || 'Alguien').trim()
  const cuerpo = String(texto || '').replace(/\s+/g, ' ').trim()
  const que = cuerpo ? (cuerpo.length > 120 ? cuerpo.slice(0, 119) + '…' : cuerpo)
    : ({ imagen: 'Mandó una foto', audio: 'Mandó un audio', documento: 'Mandó un documento', ubicacion: 'Mandó su ubicación' }[tipo] || 'Mandó un mensaje')
  return { titulo: `WhatsApp · ${quien}`, cuerpo: que, url: '/?ir=whatsapp', etiqueta: `wa-${telefono || quien}` }
}

// Manda un aviso a una suscripción. Devuelve { ok, vivo }: `vivo` false = el navegador ya no
// existe (lo desinstalaron o quitaron el permiso) y hay que borrarla.
export async function mandarPush(sus, aviso, vapid, f = fetch) {
  try {
    const cuerpo = await cifrar(JSON.stringify(aviso), sus.p256dh, sus.auth)
    const r = await f(sus.endpoint, {
      method: 'POST',
      headers: {
        Authorization: await firmaVapid(sus.endpoint, vapid.publica, vapid.privada, vapid.contacto),
        'Content-Encoding': 'aes128gcm',
        'Content-Type': 'application/octet-stream',
        TTL: '86400',
        Urgency: 'high',
      },
      body: cuerpo,
    })
    if (r.status === 404 || r.status === 410) return { ok: false, vivo: false, status: r.status }
    return { ok: r.status >= 200 && r.status < 300, vivo: true, status: r.status }
  } catch (e) {
    return { ok: false, vivo: true, error: e instanceof Error ? e.message : String(e) }
  }
}

// Avisa a todos los navegadores de los admins. Nunca lanza: un aviso que falla no debe tumbar
// el webhook. `sb` es el cliente de Supabase (bot o admin).
export async function avisarATodos(sb, aviso, vapid, f = fetch) {
  try {
    if (!vapid?.publica || !vapid?.privada) return { enviados: 0, de: 0, motivo: 'faltan las llaves VAPID' }
    const { data: destinos, error } = await sb.rpc('push_destinos')
    if (error) return { enviados: 0, de: 0, motivo: error.message }
    let enviados = 0
    const fallas = []
    for (const sus of destinos || []) {
      const r = await mandarPush(sus, aviso, vapid, f)
      if (r.ok) enviados++
      else fallas.push(r.error || `HTTP ${r.status}`)
      if (r.ok || r.vivo === false) await sb.rpc('push_resultado', { p_endpoint: sus.endpoint, p_vivo: r.ok })
    }
    return { enviados, de: (destinos || []).length, fallas }
  } catch (e) {
    return { enviados: 0, de: 0, motivo: e instanceof Error ? e.message : String(e) }
  }
}
