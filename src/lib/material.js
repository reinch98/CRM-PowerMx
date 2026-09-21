// ---------------------------------------------------------------------------
// Material: reglas puras (sin red) del uso, la devolución y su antigüedad.
// La base (18_uso_y_devoluciones.sql) es la que manda; esto solo propone valores por defecto,
// valida antes de enviar y pone las cosas en palabras.
//
//   pendiente de devolución = entregada − usada − devuelta − diferencia
// ---------------------------------------------------------------------------

const num = v => {
  const n = Number(v)
  return Number.isFinite(n) ? n : 0
}

// ---- lado del técnico (líneas de `orden_surtido`: cantidad_entregada, cantidad_usada…) ----

// Lo que recibió de verdad (las líneas sin nada entregado no se le preguntan).
export const conMaterial = surtido => (surtido || []).filter(l => num(l.cantidad_entregada) > 0)

// Lo que declara al cerrar: por pieza, cuántas usó. Sin capturar = 0 (todo se devuelve, que es lo
// seguro). Nunca más de lo recibido ni menos de cero: el cierre no puede tronar por un dedazo.
export function usoParaCierre(surtido, capturado) {
  return conMaterial(surtido).map(l => {
    const dicho = num(capturado?.[l.producto_id])
    const usadas = Math.min(Math.max(dicho, 0), num(l.cantidad_entregada))
    return { producto_id: l.producto_id, usadas }
  })
}

// Lo que va a tener que devolver según lo que declaró.
export function porDevolver(surtido, capturado) {
  const usos = new Map(usoParaCierre(surtido, capturado).map(u => [u.producto_id, u.usadas]))
  return conMaterial(surtido)
    .map(l => ({ ...l, aDevolver: num(l.cantidad_entregada) - (usos.get(l.producto_id) || 0) }))
    .filter(l => l.aDevolver > 0)
}

// Lo que le falta devolver a una orden que ya cerró.
export const pendienteDeLinea = l =>
  Math.max(0, num(l.cantidad_entregada) - num(l.cantidad_usada) - num(l.cantidad_devuelta) - num(l.cantidad_diferencia))

export const debeDevolver = surtido => (surtido || []).filter(l => pendienteDeLinea(l) > 0)

// ---- lado del almacén (líneas de `devoluciones_pendientes`: entregada, usada, devuelta, pendiente…) ----

// Lo que se recibe: por defecto, todo lo pendiente. Se ignoran vacíos, ceros y basura. No se
// recorta a lo pendiente a propósito: si escriben de más, la base lo rechaza y lo dice.
export function aRecibir(lineas, capturado) {
  const salida = []
  for (const l of lineas || []) {
    if (num(l.pendiente) <= 0) continue
    const texto = capturado?.[l.producto_id]
    const valor = texto === undefined ? num(l.pendiente) : Number(texto)
    if (Number.isFinite(valor) && valor > 0) salida.push({ producto_id: l.producto_id, cantidad: valor })
  }
  return salida
}

// ¿Quedaría algo pendiente sin devolverse completo? Entonces la observación es obligatoria.
export function quedaPendiente(lineas, recibir) {
  const recibido = new Map((recibir || []).map(r => [r.producto_id, r.cantidad]))
  return (lineas || []).some(l => num(l.pendiente) > 0 && (recibido.get(l.producto_id) || 0) < num(l.pendiente))
}

// Antigüedad de lo pendiente, con palabra (nunca solo color).
export function nivelAntiguedad(dias) {
  const d = num(dias)
  if (d >= 5) return 'Atrasada'
  if (d >= 2) return 'Por vencer'
  return 'Reciente'
}

export function haceCuanto(dias) {
  const d = num(dias)
  if (d <= 0) return 'hoy'
  return d === 1 ? 'hace 1 día' : `hace ${d} días`
}
