// CSV → hoja (arreglo de arreglos), con las reglas de RFC 4180: comillas dobles, comillas escapadas ("")
// y saltos de línea DENTRO de una celda (las fichas de un producto van una por renglón en la misma celda).
// Se quita la marca BOM que Excel y las descargas del navegador agregan al principio.
export function parsearCsv(texto) {
  const crudo = String(texto ?? '')
  const t = crudo.charCodeAt(0) === 0xFEFF ? crudo.slice(1) : crudo
  const filas = []
  let fila = []
  let celda = ''
  let entreComillas = false

  for (let i = 0; i < t.length; i++) {
    const c = t[i]
    if (entreComillas) {
      if (c === '"') {
        if (t[i + 1] === '"') { celda += '"'; i++ } else entreComillas = false
      } else celda += c
      continue
    }
    if (c === '"') entreComillas = true
    else if (c === ',') { fila.push(celda); celda = '' }
    else if (c === '\n' || c === '\r') {
      if (c === '\r' && t[i + 1] === '\n') i++
      fila.push(celda); celda = ''
      filas.push(fila); fila = []
    } else celda += c
  }
  if (entreComillas) throw new Error('El CSV está incompleto: una celda con comillas no se cerró.')
  if (celda !== '' || fila.length) { fila.push(celda); filas.push(fila) }

  // Una línea totalmente vacía (el último salto de línea) no es un renglón.
  return filas.filter((f) => !(f.length === 1 && f[0] === ''))
    .map((f) => f.map((v) => (v === '' ? null : v)))
}
