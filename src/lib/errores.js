// ---------------------------------------------------------------------------
// Traduce un error de Supabase a algo que un técnico en campo entienda y pueda
// actuar. `temporal` separa lo que se arregla solo (señal) de lo que necesita
// que alguien haga algo (permisos, sesión, datos).
// ---------------------------------------------------------------------------

export function explicarError(error) {
  const mensaje = String(error?.message || error || '')
  const codigo = String(error?.code || error?.statusCode || error?.status || '')

  if (/failed to fetch|networkerror|network request|load failed|timeout|offline/i.test(mensaje)) {
    return { texto: 'Sin señal o conexión débil. Se reintenta solo.', temporal: true }
  }
  if (codigo === 'PGRST301' || /jwt|token.*expired|session.*expired/i.test(mensaje)) {
    return { texto: 'Tu sesión venció. Sal y vuelve a entrar; la orden no se pierde.', temporal: false }
  }
  if (codigo === '42501' || codigo === '403' || /row-level security|permission denied|not authorized|unauthorized/i.test(mensaje)) {
    return { texto: 'Tu cuenta no tiene permiso para guardar esta orden. Avisa al administrador.', temporal: false }
  }
  if (codigo === '23503') {
    return { texto: 'El cliente o el equipo de esta orden ya no existe en el sistema.', temporal: false }
  }
  if (codigo === '23502' || codigo === '22P02' || codigo === '22007') {
    return { texto: `Un dato de la orden no es válido (${mensaje}).`, temporal: false }
  }
  if (codigo === '404' || /bucket not found/i.test(mensaje)) {
    return { texto: 'No se encontró el lugar donde guardar las fotos. Avisa al administrador.', temporal: false }
  }
  return { texto: mensaje || 'Error desconocido.', temporal: false }
}
