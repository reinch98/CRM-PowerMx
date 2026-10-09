import { test } from 'node:test'
import assert from 'node:assert/strict'
import { deflateRawSync } from 'node:zlib'
import { leerZip, esZip } from '../src/lib/zip.js'

// Arma un ZIP real: [{ nombre, texto, metodo: 0|8, banderas }]
function armarZip(entradas) {
  const locales = []
  const centrales = []
  let offset = 0
  for (const e of entradas) {
    const nombre = Buffer.from(e.nombre, 'utf8')
    const crudo = Buffer.from(e.texto ?? '', 'utf8')
    const metodo = e.metodo ?? 8
    const datos = metodo === 8 ? deflateRawSync(crudo) : crudo
    const declarado = e.declarado ?? crudo.length
    const l = Buffer.alloc(30)
    l.writeUInt32LE(0x04034b50, 0); l.writeUInt16LE(20, 4); l.writeUInt16LE(e.banderas ?? 0, 6)
    l.writeUInt16LE(metodo, 8); l.writeUInt32LE(datos.length, 18); l.writeUInt32LE(declarado, 22)
    l.writeUInt16LE(nombre.length, 26); l.writeUInt16LE(0, 28)
    locales.push(l, nombre, datos)
    const c = Buffer.alloc(46)
    c.writeUInt32LE(0x02014b50, 0); c.writeUInt16LE(20, 4); c.writeUInt16LE(20, 6); c.writeUInt16LE(e.banderas ?? 0, 8)
    c.writeUInt16LE(metodo, 10); c.writeUInt32LE(datos.length, 20); c.writeUInt32LE(declarado, 24)
    c.writeUInt16LE(nombre.length, 28); c.writeUInt32LE(offset, 42)
    centrales.push(c, nombre)
    offset += 30 + nombre.length + datos.length
  }
  const central = Buffer.concat(centrales)
  const fin = Buffer.alloc(22)
  fin.writeUInt32LE(0x06054b50, 0); fin.writeUInt16LE(entradas.length, 8); fin.writeUInt16LE(entradas.length, 10)
  fin.writeUInt32LE(central.length, 12); fin.writeUInt32LE(offset, 16)
  return new Uint8Array(Buffer.concat([...locales, central, fin]))
}

const XML = '<?xml version="1.0"?><cfdi:Comprobante xmlns:cfdi="x" Total="1160"/>'
const texto = b => new TextDecoder().decode(b)

test('saca los XML comprimidos y sin comprimir, e ignora carpetas y lo que no es XML', async () => {
  const zip = armarZip([
    { nombre: 'Recibidos/', texto: '', metodo: 0 },
    { nombre: 'Recibidos/AAAA-1111.xml', texto: XML },
    { nombre: 'BBBB-2222.XML', texto: XML, metodo: 0 },
    { nombre: 'Metadata.txt', texto: 'uuid~rfc' }
  ])
  const r = await leerZip(zip)
  assert.equal(r.error, undefined)
  assert.deepEqual(r.archivos.map(a => a.nombre), ['AAAA-1111.xml', 'BBBB-2222.XML'])
  assert.equal(texto(r.archivos[0].bytes), XML)
  assert.equal(texto(r.archivos[1].bytes), XML)
  assert.deepEqual(r.omitidos, [])
})

test('un XML con contraseña se omite con su motivo', async () => {
  const r = await leerZip(armarZip([{ nombre: 'a.xml', texto: XML, banderas: 1 }]))
  assert.deepEqual(r.omitidos, [{ nombre: 'a.xml', motivo: 'Tiene contraseña' }])
  assert.equal(r.archivos.length, 0)
})

test('una bomba de descompresión se corta por los bytes reales, aunque mienta en el tamaño', async () => {
  const enorme = 'A'.repeat(3 * 1024 * 1024)
  const r = await leerZip(armarZip([{ nombre: 'bomba.xml', texto: enorme, declarado: 100 }]))
  assert.deepEqual(r.omitidos, [{ nombre: 'bomba.xml', motivo: 'Pesa demasiado para ser un CFDI' }])
})

test('respeta el tope de archivos', async () => {
  const zip = armarZip([1, 2, 3].map(n => ({ nombre: `${n}.xml`, texto: XML })))
  const r = await leerZip(zip, { limites: { archivos: 2, porArchivo: 1e6, total: 1e7 } })
  assert.equal(r.archivos.length, 2)
  assert.equal(r.omitidos[0].motivo, 'Más de 2 archivos')
})

test('lo que no es ZIP da un error claro', async () => {
  assert.match((await leerZip(new TextEncoder().encode('hola, no soy un zip, de verdad que no'))).error, /no es un ZIP/)
  assert.match((await leerZip(new Uint8Array(5))).error, /no es un ZIP/)
})

test('reconoce un ZIP por nombre o tipo', () => {
  assert.equal(esZip({ name: 'SAT_octubre.ZIP' }), true)
  assert.equal(esZip({ name: 'x', type: 'application/x-zip-compressed' }), true)
  assert.equal(esZip({ name: 'factura.xml', type: 'text/xml' }), false)
})
