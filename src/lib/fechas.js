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
