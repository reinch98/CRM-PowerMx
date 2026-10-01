// Adaptador de XLStore con la SESIÓN de Caña (opción D): lee el catálogo directo del sitio, sin pasar por
// un archivo. No hace login ni salta ningún captcha: reutiliza la cookie de una sesión que una persona
// ya inició en su navegador.
//
// De dónde sale la cookie (en este orden):
//   1. la variable de entorno XLSTORE_COOKIE;
//   2. el archivo de config.cookieArchivo (por omisión %USERPROFILE%\.powermx\xlstore-cookie.txt).
// La cookie es el equivalente a la contraseña mientras dure la sesión: nunca se imprime, y el mensaje de
// error no la incluye.
//
// Limitaciones que conviene tener presentes:
//   · cuando la sesión caduca, la lectura falla con un mensaje claro (el CRM lo muestra como "la última
//     lectura falló"); hay que iniciar sesión y volver a copiar la cookie.
//   · reutilizar una sesión de forma automática puede ir contra los términos de uso de XLStore. Es una
//     decisión de Caña, no un hecho técnico.
import { readFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { DOMParser } from 'linkedom'
import { BASE, extraerCatalogo } from '../xlstore/extraer.js'
import { normalizarHoja } from './normalizar.js'

export const COOKIE_POR_OMISION = path.join(os.homedir(), '.powermx', 'xlstore-cookie.txt')

export async function leerCookie(config = {}, env = process.env) {
  if (env.XLSTORE_COOKIE && env.XLSTORE_COOKIE.trim()) return env.XLSTORE_COOKIE.trim()
  const ruta = config.cookieArchivo || COOKIE_POR_OMISION
  try {
    const t = (await readFile(ruta, 'utf8')).trim()
    if (t) return t
  } catch { /* se explica abajo */ }
  throw new Error(
    'No encontré la cookie de sesión de XLStore. Guárdala con la opción "Guardar mi sesión de XLStore" de ' +
    'powermx.ps1 (o en la variable XLSTORE_COOKIE).'
  )
}

// La cookie viaja en un encabezado: un salto de línea ahí rompería la petición (o la inyectaría).
export function cookieSegura(cookie) {
  const c = String(cookie ?? '').replace(/^cookie:\s*/i, '').trim()
  if (!c || /[\r\n]/.test(c) || c.includes(String.fromCharCode(0))) throw new Error('La cookie de XLStore guardada no es válida: vuelve a copiarla.')
  return c
}

/**
 * @param {{cookieArchivo?: string, conDocumentos?: boolean, moneda?: 'USD'|'MXN'}} config
 */
// `extra` (categorías, mínimos, ritmo) solo lo usan las pruebas, para no leer ocho categorías de un sitio de mentira.
export async function leer(config = {}, { fetchFn = fetch, env = process.env, onProgreso = (t) => console.log(`  ${t}`), extra = {} } = {}) {
  const cookie = cookieSegura(await leerCookie(config, env))
  const base = (env.XLSTORE_BASE || BASE).replace(/\/$/, '')   // XLSTORE_BASE solo lo usan las pruebas
  const conCookie = (url) => fetchFn(url, {
    headers: { Cookie: cookie, Accept: 'text/html,application/json,*/*', 'User-Agent': 'Mozilla/5.0 (compatible; PowerMx-sync)' },
    redirect: 'follow',
  })
  const { filas, avisos, resumen } = await extraerCatalogo({
    fetchFn: conCookie, DP: DOMParser, base, conDocumentos: !!config.conDocumentos, onProgreso, ...extra,
  })
  const normal = normalizarHoja(filas, { monedaPorOmision: config.moneda })
  return {
    fuente: `xlstore:sesion (${resumen.productos} productos, ${resumen.sinPrecio} sin precio)`,
    filas: normal.filas,
    avisos: [...avisos, ...normal.avisos],
  }
}
