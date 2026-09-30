// Adaptador de archivo: lee un .xlsx y devuelve las filas ya normalizadas.
// Es la única pieza que sabe de Excel. Para cambiar de proveedor (o de un archivo a un
// feed/API) se escribe otro adaptador con la misma forma y se registra en `index.js`;
// nada más del sync se entera.
import { readSheet } from 'read-excel-file/node'
import { normalizarHoja } from './normalizar.js'

/**
 * @param {{archivo: string, hoja?: string, moneda?: 'USD'|'MXN'}} config
 */
export async function leer(config) {
  if (!config.archivo) throw new Error('Falta la ruta del archivo (--archivo).')
  const filas = await readSheet(config.archivo, config.hoja)
  const { filas: productos, avisos } = normalizarHoja(filas, { monedaPorOmision: config.moneda })
  return { fuente: `excel:${config.archivo}`, filas: productos, avisos }
}
