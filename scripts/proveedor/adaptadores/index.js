// Registro de adaptadores. Cada uno exporta `leer(config)` y devuelve
// `{ fuente, filas, avisos }` con las filas en el formato de `normalizar.js`.
import { leer as excel } from './excel.js'
import { leer as xlstore } from './xlstore.js'
import { leer as solarama } from './solarama.js'

export const ADAPTADORES = { excel, xlstore, solarama }

export function adaptador(nombre) {
  const a = ADAPTADORES[nombre]
  if (!a) throw new Error(`No existe el adaptador "${nombre}". Hay: ${Object.keys(ADAPTADORES).join(', ')}.`)
  return a
}
