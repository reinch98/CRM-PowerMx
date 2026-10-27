// Tipo de cambio FIX del Banco de México (serie SF43718, pesos por dólar).
//
// De dónde sale, en este orden:
//   1. TIPO_CAMBIO a mano (sirve cuando todo lo demás falla).
//   2. El que ya guardó el CRM en `tipos_cambio` (lo baja solo del DOF cada mañana, SQL 91): es el
//      mismo FIX de Banxico, sin token. Solo se usa si es reciente (MAX_DIAS_GUARDADO).
//   3. Banxico directo, si hay BANXICO_TOKEN (https://www.banxico.org.mx/SieAPIRest/service/v1/).
// Sin ninguno, el sync NO inventa un tipo de cambio: se detiene.

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

// Un fin de semana largo deja 4 días sin FIX nuevo; más que eso ya es un reloj descompuesto.
export const MAX_DIAS_GUARDADO = 4

const dias = (a, b) => {
  const t = (s) => { const [y, m, d] = String(s).split('-').map(Number); return Date.UTC(y, m - 1, d) }
  return Math.round((t(b) - t(a)) / 86400000)
}

// 'AAAA-MM-DD' de hoy en Mérida (el runner de GitHub corre en UTC).
export const hoyMerida = () => new Date().toLocaleDateString('en-CA', { timeZone: 'America/Merida' })

/**
 * Valida lo que guardó el CRM ({valor, fecha}). Devuelve el dato listo, o `null` con el motivo en
 * `motivo` si no sirve (vacío, fuera de rango, o más viejo de MAX_DIAS_GUARDADO).
 */
export function revisarGuardado(dato, hoy = hoyMerida()) {
  const valor = Number(dato?.valor)
  if (!dato || !dato.fecha || !Number.isFinite(valor)) return { dato: null, motivo: 'el CRM no tiene tipo de cambio guardado' }
  if (valor < 5 || valor > 100) return { dato: null, motivo: 'el guardado en el CRM está fuera de rango' }
  const edad = dias(dato.fecha, hoy)
  if (edad > MAX_DIAS_GUARDADO) return { dato: null, motivo: `el guardado en el CRM es del ${dato.fecha} (hace ${edad} días)` }
  return { dato: { valor, fecha: dato.fecha, fuente: 'dof' }, motivo: '' }
}

/**
 * `guardado` es opcional: una función async que devuelve lo que tenga el CRM en `tipos_cambio`.
 * TIPO_CAMBIO a mano tiene prioridad: sirve cuando todo lo demás falla.
 */
export async function tipoDeCambio(env = process.env, fetchFn = fetch, guardado = null) {
  if (env.TIPO_CAMBIO) {
    const valor = Number(env.TIPO_CAMBIO)
    if (!Number.isFinite(valor) || valor < 5 || valor > 100) throw new Error('TIPO_CAMBIO fuera de rango.')
    return { valor, fecha: null, fuente: 'manual' }
  }
  let motivo = ''
  if (guardado) {
    try {
      const r = revisarGuardado(await guardado())
      if (r.dato) return r.dato
      motivo = r.motivo
    } catch (e) {
      motivo = `no pude leer el del CRM (${e.message})`
    }
  }
  if (!env.BANXICO_TOKEN && motivo) {
    throw new Error(`Sin tipo de cambio: ${motivo}, y no hay BANXICO_TOKEN ni TIPO_CAMBIO a mano.`)
  }
  return obtenerFix({ token: env.BANXICO_TOKEN, fetchFn })
}
