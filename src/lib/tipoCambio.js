// Cómo se dice el tipo de cambio en el encabezado del CRM. Reglas puras: la pantalla
// (`TipoCambio.jsx`) solo las dibuja.
//
// El valor sale de `tipos_cambio` (la lee `tipo_cambio_actual`, solo admin). Lo escribe la
// Edge Function `tipo-cambio` desde el DOF cada mañana, y es el mismo que usa Cotizaciones para
// convertir los equipos en dólares: lo que se ve arriba es lo que se aplica.

// El DOF publica en días hábiles; con un puente largo pueden pasar hasta 4 días sin cambio. Más
// que eso es una señal de que la actualización se descompuso, y se dice con palabras.
export const DIAS_SIN_ACTUALIZAR = 4

function dias(a, b) {
  const t = (s) => {
    const [y, m, d] = String(s).split('-').map(Number)
    return Date.UTC(y, m - 1, d)
  }
  return Math.round((t(b) - t(a)) / 86400000)
}

const FUENTES = { dof: 'DOF', manual: 'capturado a mano' }
function nombreFuente(fuente) {
  const f = String(fuente ?? '')
  if (FUENTES[f]) return FUENTES[f]
  if (f.startsWith('banxico')) return 'Banxico'
  return f || 'sin fuente'
}

/** 'AAAA-MM-DD' → '26/10/26' (corto: en el celular el encabezado no tiene espacio de sobra). */
export function fechaCorta(fecha) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(fecha ?? ''))
  return m ? `${m[3]}/${m[2]}/${m[1].slice(2)}` : ''
}

/**
 * Lo que dice la franja. `fila` es lo que devuelve `tipo_cambio_actual` ({valor, fecha, fuente})
 * o null si no hay ninguno; `hoy` es 'AAAA-MM-DD' en hora de Mérida (`hoyLocal()`).
 */
export function resumenTipoCambio(fila, hoy) {
  const valor = Number(fila?.valor)
  if (!fila || !Number.isFinite(valor) || valor <= 0) {
    return { hay: false, vencido: true, valor: '', fecha: '', fuente: '', aviso: 'Sin tipo de cambio guardado' }
  }
  const atraso = fila.fecha ? dias(fila.fecha, hoy) : 0
  const vencido = atraso > DIAS_SIN_ACTUALIZAR
  return {
    hay: true,
    vencido,
    valor: `$${valor.toFixed(4)}`,
    fecha: fechaCorta(fila.fecha),
    fuente: nombreFuente(fila.fuente),
    // El aviso nombra el atraso: un número viejo con cara de bueno es peor que ninguno.
    aviso: vencido ? `Sin actualizar desde el ${fechaCorta(fila.fecha)}` : '',
  }
}
