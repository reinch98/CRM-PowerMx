// ---------------------------------------------------------------------------
// Reglas de la cola de trabajos sin señal. Funciones puras: reciben una lista y
// devuelven otra, sin tocar el navegador ni la base, para poder probarlas.
//
// Cada elemento de la cola es un intento de subir algo de una orden:
//   { clave: 'parte:<orden>' | 'cierre:<orden>', tipo, orden_id, payload?, n, sync? }
//
//   · `clave` identifica el asunto: guardar la parte de la orden X es SIEMPRE lo mismo,
//     así que un elemento nuevo REEMPLAZA al anterior en vez de apilarse.
//   · `n` cuenta cuántas veces se reemplazó. Al terminar de subir un elemento solo se
//     quita si `n` no cambió: si el técnico siguió escribiendo mientras subía, el
//     elemento nuevo se conserva y volverá a subirse.
// ---------------------------------------------------------------------------

export const claveDe = (tipo, orden_id) => `${tipo}:${orden_id}`

// Agrega o reemplaza el elemento de esa clave, subiendo su contador.
export function encolarEn(cola, item) {
  const previo = cola.find(i => i.clave === item.clave)
  const nuevo = { ...item, n: (previo?.n || 0) + 1 }
  return [...cola.filter(i => i.clave !== item.clave), nuevo]
}

// Las partes van antes que los cierres: el cierre necesita que las notas ya estén
// arriba para juntarlas. Dentro de cada tipo se respeta el orden de llegada.
export function ordenarCola(cola) {
  const peso = i => (i.tipo === 'parte' ? 0 : 1)
  return [...cola].sort((a, b) => peso(a) - peso(b))
}

// Quita el elemento solo si sigue siendo el mismo intento (mismo n).
export function sacarSiSigue(cola, clave, n) {
  return cola.filter(i => !(i.clave === clave && i.n === n))
}

// Anota por qué falló el elemento, solo si sigue siendo el mismo intento.
export function marcarFallo(cola, clave, n, motivo, temporal) {
  return cola.map(i => (i.clave === clave && i.n === n
    ? { ...i, sync: { error: motivo, temporal, intentos: (i.sync?.intentos || 0) + 1, ultimo_intento: new Date().toISOString() } }
    : i))
}

// ¿La orden tiene algo por subir?
export const pendienteDe = (cola, orden_id) => cola.filter(i => i.orden_id === orden_id)

// Un cierre pendiente no admite más ediciones: la orden ya está "en camino" a cerrarse.
export const cierrePendiente = (cola, orden_id) => cola.some(i => i.clave === claveDe('cierre', orden_id))
