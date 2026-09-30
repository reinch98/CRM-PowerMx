// Registro de adaptadores. Cada uno exporta `leer(config)` y devuelve
// `{ fuente, filas, avisos }` con las filas en el formato de `normalizar.js`.
import { leer as excel } from './excel.js'

export const ADAPTADORES = { excel }

export function adaptador(nombre) {
  const a = ADAPTADORES[nombre]
  if (!a) throw new Error(`No existe el adaptador "${nombre}". Hay: ${Object.keys(ADAPTADORES).join(', ')}.`)
  return a
}
