// Adaptador de archivo: lee un .xlsx (o un .csv, que es lo que baja la herramienta del navegador) y devuelve
// las filas ya normalizadas. Es la pieza que sabe de archivos. Para cambiar de proveedor (o de un archivo
// a un feed/API) se escribe otro adaptador con la misma forma y se registra en `index.js`; nada más del
// sync se entera.
import { readFile } from 'node:fs/promises'
import { readSheet } from 'read-excel-file/node'
import { normalizarHoja } from './normalizar.js'
import { parsearCsv } from './csv.js'

/**
 * @param {{archivo: string, hoja?: string, moneda?: 'USD'|'MXN'}} config
 */
export async function leer(config) {
  if (!config.archivo) throw new Error('Falta la ruta del archivo (--archivo).')
  const esCsv = /\.csv$/i.test(config.archivo)
  const filas = esCsv
    ? parsearCsv(await readFile(config.archivo, 'utf8'))
    : await readSheet(config.archivo, config.hoja)
  const { filas: productos, avisos } = normalizarHoja(filas, { monedaPorOmision: config.moneda })
  return { fuente: `${esCsv ? 'csv' : 'excel'}:${config.archivo}`, filas: productos, avisos }
}
