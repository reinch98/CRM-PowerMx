// Genera las llaves VAPID de PowerMx (avisos push, SQL 90) y las guarda como secretos de Supabase.
// Se corre UNA vez, desde la carpeta del CRM:   node scripts/generar_llaves_avisos.mjs
//
// La llave privada no se imprime ni se guarda en ningún archivo: pasa directo a `supabase secrets
// set`. Si se vuelve a correr, las llaves cambian y cada celular tiene que volver a "Avisarme
// aquí" (las suscripciones viejas quedan amarradas a la llave anterior).
import { execFileSync } from 'node:child_process'

const par = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign'])
const privada = (await crypto.subtle.exportKey('jwk', par.privateKey)).d
const publica = Buffer.from(await crypto.subtle.exportKey('raw', par.publicKey)).toString('base64url')

execFileSync('npx', ['supabase', 'secrets', 'set',
  `VAPID_PUBLIC_KEY=${publica}`, `VAPID_PRIVATE_KEY=${privada}`, 'VAPID_CONTACTO=https://crm.powermx.com.mx'],
{ stdio: ['ignore', 'ignore', 'inherit'], shell: process.platform === 'win32' })

console.log('Listo: las llaves de avisos quedaron guardadas en Supabase (Edge Functions → Secrets).')
