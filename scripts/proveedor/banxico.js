// Tipo de cambio FIX del Banco de México (serie SF43718, pesos por dólar).
// https://www.banxico.org.mx/SieAPIRest/service/v1/ — requiere un token gratuito
// (BANXICO_TOKEN). Sin token o sin respuesta, el sync NO inventa un tipo de cambio:
// se detiene, o usa el que se indique a mano con TIPO_CAMBIO.

export const URL_FIX = 'https://www.banxico.org.mx/SieAPIRest/service/v1/series/SF43718/datos/oportuno'

/** Saca el dato de la respuesta de Banxico. Lanza Error si no trae un número razonable. */
export function parsearFix(json) {
  const dato = json?.bmx?.series?.[0]?.datos?.[0]
  const valor = Number(String(dato?.dato ?? '').replace(/,/g, ''))
  if (!dato || !Number.isFinite(valor) || valor < 5 || valor > 100) {
    throw new Error('Banxico no devolvió un tipo de cambio válido.')
  }
  const [dd, mm, aaaa] = String(dato.fecha).split('/')
  if (!dd || !mm || !aaaa) throw new Error('Banxico devolvió una fecha ilegible.')
  return { valor, fecha: `${aaaa}-${mm.padStart(2, '0')}-${dd.padStart(2, '0')}`, fuente: 'banxico:SF43718' }
}

export async function obtenerFix({ token, fetchFn = fetch } = {}) {
  if (!token) throw new Error('Falta BANXICO_TOKEN (o indica TIPO_CAMBIO a mano).')
  const r = await fetchFn(URL_FIX, { headers: { 'Bmx-Token': token, Accept: 'application/json' } })
  if (!r.ok) throw new Error(`Banxico respondió ${r.status}.`)
  return parsearFix(await r.json())
}

/** TIPO_CAMBIO a mano tiene prioridad: sirve cuando Banxico no responde. */
export async function tipoDeCambio(env = process.env, fetchFn = fetch) {
  if (env.TIPO_CAMBIO) {
    const valor = Number(env.TIPO_CAMBIO)
    if (!Number.isFinite(valor) || valor < 5 || valor > 100) throw new Error('TIPO_CAMBIO fuera de rango.')
    return { valor, fecha: null, fuente: 'manual' }
  }
  return obtenerFix({ token: env.BANXICO_TOKEN, fetchFn })
}
