// Reglas puras del tipo de cambio del DOF. JS plano (sin tipos) para que lo importen la Edge
// Function `tipo-cambio` (Deno) y las pruebas de Node, igual que `_shared/whatsapp.js`.
//
// El Diario Oficial publica cada día, en https://dof.gob.mx/indicadores.php (OJO: sin "www": el
// certificado de www.dof.gob.mx no coincide y falla), el bloque
//
//   Tipo de Cambio y Tasas al 26/10/2026
//   DOLAR 18.6670
//
// que es el FIX de Banxico para solventar obligaciones en dólares. Es el mismo número que la
// serie SF43718, pero sin pedir token.

export const URL_DOF = 'https://dof.gob.mx/indicadores.php'

// Un dólar fuera de este rango es un error de lectura, no un tipo de cambio.
export const MIN_DOLAR = 5
export const MAX_DOLAR = 100

function fechaReal(aaaa, mm, dd) {
  const f = new Date(Date.UTC(Number(aaaa), Number(mm) - 1, Number(dd)))
  return f.getUTCFullYear() === Number(aaaa) && f.getUTCMonth() === Number(mm) - 1 && f.getUTCDate() === Number(dd)
}

/** Saca fecha y valor del HTML del DOF. Lanza Error con el motivo si la página no trae lo esperado. */
export function leerDof(html) {
  const t = String(html ?? '')
  const bloque = /Tipo de Cambio y Tasas al\s+(\d{2})\/(\d{2})\/(\d{4})/i.exec(t)
  if (!bloque) throw new Error('El DOF no trae el bloque "Tipo de Cambio y Tasas": la página cambió o no cargó.')
  const [, dd, mm, aaaa] = bloque
  if (!fechaReal(aaaa, mm, dd)) throw new Error(`El DOF trae una fecha imposible (${dd}/${mm}/${aaaa}).`)

  // El dólar va dentro de ese mismo bloque: se busca solo después del título para no tomar
  // otra mención de "DOLAR" (el menú desplegable trae "DOLAR" y "CCP-DOLARES").
  const resto = t.slice(bloque.index, bloque.index + 4000)
  const dolar = />\s*DOLAR\s*<\/span>\s*<br\s*\/?>\s*([0-9][0-9,]*(?:\.[0-9]+)?)/i.exec(resto)
  if (!dolar) throw new Error('El DOF no trae el renglón DOLAR dentro del bloque de tipo de cambio.')
  const valor = Number(dolar[1].replace(/,/g, ''))
  if (!Number.isFinite(valor) || valor < MIN_DOLAR || valor > MAX_DOLAR) {
    throw new Error(`El DOF trae un dólar fuera de rango (${dolar[1]}).`)
  }
  return { valor, fecha: `${aaaa}-${mm}-${dd}`, fuente: 'dof' }
}

/** Días entre dos fechas 'AAAA-MM-DD' (b − a). */
export function diasEntre(a, b) {
  const t = (s) => {
    const [y, m, d] = String(s).split('-').map(Number)
    return Date.UTC(y, m - 1, d)
  }
  return Math.round((t(b) - t(a)) / 86400000)
}

/**
 * ¿La fecha que trae el DOF cabe con el día de hoy? Una página guardada en caché de hace un mes
 * traería un dólar viejo con apariencia de bueno: se rechaza si se aleja más de `margen` días.
 */
export function fechaPlausible(fecha, hoy, margen = 10) {
  return Math.abs(diasEntre(fecha, hoy)) <= margen
}
