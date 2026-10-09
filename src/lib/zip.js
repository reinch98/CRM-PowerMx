// ---------------------------------------------------------------------------
// Lector mínimo de ZIP para la descarga masiva del SAT (un ZIP lleno de XML).
//
// Sin dependencias: lee el directorio central del ZIP a mano y descomprime con `DecompressionStream`
// ('deflate-raw'), que ya traen el navegador y Node. Solo saca los archivos que pasan el filtro (por
// omisión, los .xml) y nunca los escribe a disco: devuelve sus bytes.
//
// Defensas contra un ZIP malicioso o roto: tope de archivos, de tamaño por archivo y total (se cuentan
// los bytes REALES al descomprimir, no solo lo que el ZIP declara), sin ZIP64 y sin archivos cifrados.
// ---------------------------------------------------------------------------

export const LIMITES_ZIP = { archivos: 500, porArchivo: 2 * 1024 * 1024, total: 60 * 1024 * 1024 }

const FIRMA_FIN = 0x06054b50
const FIRMA_CENTRAL = 0x02014b50
const FIRMA_LOCAL = 0x04034b50

const esXml = nombre => /\.xml$/i.test(nombre)
const nombreBase = n => String(n).split('/').pop()

class ErrorZip extends Error {}

async function inflar(datos, maximo) {
  const ds = new DecompressionStream('deflate-raw')
  const escritor = ds.writable.getWriter()
  escritor.write(datos).catch(() => {})
  escritor.close().catch(() => {})
  const lector = ds.readable.getReader()
  const partes = []
  let total = 0
  for (;;) {
    const { done, value } = await lector.read()
    if (done) break
    total += value.length
    if (total > maximo) {
      await lector.cancel().catch(() => {})
      throw new ErrorZip('demasiado grande')
    }
    partes.push(value)
  }
  const salida = new Uint8Array(total)
  let pos = 0
  for (const p of partes) { salida.set(p, pos); pos += p.length }
  return salida
}

function buscarFin(dv, largo) {
  // El registro final mide 22 bytes más un comentario de hasta 65,535.
  const tope = Math.max(0, largo - 22 - 65535)
  for (let i = largo - 22; i >= tope; i--) {
    if (dv.getUint32(i, true) === FIRMA_FIN) return i
  }
  return -1
}

// Devuelve { archivos: [{ nombre, bytes }], omitidos: [{ nombre, motivo }] } o { error }.
export async function leerZip(buffer, { filtro = esXml, limites = LIMITES_ZIP } = {}) {
  try {
    const u8 = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer)
    const dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength)
    if (u8.length < 22) return { error: 'El archivo no es un ZIP.' }
    const fin = buscarFin(dv, u8.length)
    if (fin < 0) return { error: 'El archivo no es un ZIP o está incompleto.' }

    const entradas = dv.getUint16(fin + 10, true)
    const inicioCentral = dv.getUint32(fin + 16, true)
    if (entradas === 0xffff || inicioCentral === 0xffffffff) {
      return { error: 'Ese ZIP es demasiado grande (formato ZIP64). Descomprímelo y sube los XML.' }
    }

    const decodificar = new TextDecoder('utf-8')
    const archivos = []
    const omitidos = []
    let total = 0
    let p = inicioCentral

    for (let k = 0; k < entradas; k++) {
      if (p + 46 > u8.length || dv.getUint32(p, true) !== FIRMA_CENTRAL) {
        return { error: 'El ZIP está dañado.' }
      }
      const banderas = dv.getUint16(p + 8, true)
      const metodo = dv.getUint16(p + 10, true)
      const comprimido = dv.getUint32(p + 20, true)
      const declarado = dv.getUint32(p + 24, true)
      const largoNombre = dv.getUint16(p + 28, true)
      const largoExtra = dv.getUint16(p + 30, true)
      const largoComentario = dv.getUint16(p + 32, true)
      const local = dv.getUint32(p + 42, true)
      const ruta = decodificar.decode(u8.subarray(p + 46, p + 46 + largoNombre))
      p += 46 + largoNombre + largoExtra + largoComentario

      if (ruta.endsWith('/')) continue                     // carpeta
      const nombre = nombreBase(ruta)
      if (!filtro(nombre)) continue                         // no es XML: se ignora sin avisar
      if (archivos.length >= limites.archivos) { omitidos.push({ nombre, motivo: `Más de ${limites.archivos} archivos` }); continue }
      if (banderas & 0x1) { omitidos.push({ nombre, motivo: 'Tiene contraseña' }); continue }
      if (declarado > limites.porArchivo) { omitidos.push({ nombre, motivo: 'Pesa demasiado para ser un CFDI' }); continue }
      if (metodo !== 0 && metodo !== 8) { omitidos.push({ nombre, motivo: 'Compresión no soportada' }); continue }

      if (local + 30 > u8.length || dv.getUint32(local, true) !== FIRMA_LOCAL) {
        omitidos.push({ nombre, motivo: 'Dañado' })
        continue
      }
      const inicioDatos = local + 30 + dv.getUint16(local + 26, true) + dv.getUint16(local + 28, true)
      const datos = u8.subarray(inicioDatos, inicioDatos + comprimido)
      if (datos.length < comprimido) { omitidos.push({ nombre, motivo: 'Dañado' }); continue }

      let bytes
      try {
        bytes = metodo === 0 ? datos.slice() : await inflar(datos, limites.porArchivo)
      } catch (e) {
        omitidos.push({ nombre, motivo: e instanceof ErrorZip ? 'Pesa demasiado para ser un CFDI' : 'Dañado' })
        continue
      }
      if (bytes.length > limites.porArchivo) { omitidos.push({ nombre, motivo: 'Pesa demasiado para ser un CFDI' }); continue }
      total += bytes.length
      if (total > limites.total) return { error: 'El ZIP descomprimido pesa demasiado. Súbelo en partes.' }
      archivos.push({ nombre, bytes })
    }
    return { archivos, omitidos }
  } catch {
    return { error: 'No pude abrir el ZIP.' }
  }
}

export const esZip = a => /\.zip$/i.test(a?.name || '') || /zip/.test(a?.type || '')
