// ---------------------------------------------------------------------------
// Fechas en hora local.
//
// new Date().toISOString() da la fecha en UTC: en Mérida (UTC-6), después de
// las 6 de la tarde ya dice "mañana". Estas funciones usan la hora del
// dispositivo, que es la de quien está capturando.
// ---------------------------------------------------------------------------

const dos = n => String(n).padStart(2, '0')

// Fecha de hoy como 'AAAA-MM-DD', en hora local.
export function hoyLocal() {
  const d = new Date()
  return `${d.getFullYear()}-${dos(d.getMonth() + 1)}-${dos(d.getDate())}`
}

// Suma días a una fecha 'AAAA-MM-DD'. Se calcula a mediodía para que un
// cambio de horario no la mueva de día.
export function sumarDias(fecha, dias) {
  const d = new Date(`${fecha}T12:00:00`)
  d.setDate(d.getDate() + dias)
  return `${d.getFullYear()}-${dos(d.getMonth() + 1)}-${dos(d.getDate())}`
}

// Semana ISO 8601 de una fecha 'AAAA-MM-DD' (por defecto, hoy), como 'AAAA-Wss'. Sirve para
// ordenar en carpetas los PDF enviados: la semana la decide el reloj de quien envía, igual que
// hoyLocal(). La semana ISO empieza en lunes y toma el número del año de su jueves.
export function semanaLocal(fecha = hoyLocal()) {
  const d = new Date(`${fecha}T12:00:00`)
  const diaIso = (d.getDay() + 6) % 7          // 0 = lunes … 6 = domingo
  d.setDate(d.getDate() - diaIso + 3)          // jueves de esa semana: define el año
  const primerEnero = new Date(d.getFullYear(), 0, 1)
  const semana = Math.ceil((((d - primerEnero) / 86400000) + 1) / 7)
  return `${d.getFullYear()}-W${dos(semana)}`
}
