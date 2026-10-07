import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  aNumero, normalizarTexto, tokens, parecido, normalizarLectura, costoSinIva, cuadre,
  candidatos, decisionInicial, proveedorSugerido, skuSugerido, problemasDeRevision,
  lineasParaRegistrar, textoDeRazon, rutaDeLectura, codigoCompacto
} from '../src/lib/factura.js'

const catalogo = [
  { id: 'p1', sku: 'FIL-ACE-001', nombre: 'Filtro de aceite Fleetguard LF3000' },
  { id: 'p2', sku: 'FIL-COMB-002', nombre: 'Filtro de combustible Fleetguard FS1000' },
  { id: 'p3', sku: 'ACE-15W40', nombre: 'Aceite 15W40 galón' },
  { id: 'p4', sku: 'ACE-10W30', nombre: 'Aceite 10W30 galón' },
  { id: 'p5', sku: 'BAT-12V', nombre: 'Batería 12V 100Ah' }
]
const vinculos = [{ producto_id: 'p1', proveedor: 'Cummins México', proveedor_sku: 'LF-3000' }]

test('los importes con $ y comas se leen como número', () => {
  assert.equal(aNumero('$1,234.50'), 1234.5)
  assert.equal(aNumero(12), 12)
  assert.equal(aNumero('abc'), null)
  assert.equal(aNumero(''), null)
  assert.equal(aNumero(NaN), null)
})

test('el texto se compara sin acentos, mayúsculas ni signos', () => {
  assert.equal(normalizarTexto('  Batería, 12V/100Ah! '), 'bateria 12v 100ah')
  assert.equal(codigoCompacto('XA-1 '), 'xa1')
  assert.deepEqual(tokens('Filtro de aceite para motor'), ['filtro', 'aceite', 'motor'])
})

test('dos nombres iguales dan 1 y dos distintos dan poco', () => {
  assert.equal(parecido('Filtro de aceite', 'filtro aceite'), 1)
  assert.ok(parecido('Filtro de aceite', 'Batería 12V') < 0.2)
})

test('el aceite 15W40 NO se confunde con el 10W30', () => {
  const bien = parecido('Aceite 15W40 galón', 'Aceite 15W40 galón')
  const mal = parecido('Aceite 10W30 galón', 'Aceite 15W40 galón')
  assert.equal(bien, 1)
  assert.ok(mal < 0.4, `salió ${mal}`)
})

test('la lectura descarta renglones incompletos y lo dice', () => {
  const l = normalizarLectura({
    proveedor: ' Cummins ', fecha: '2026-10-07', total: '$1,160.00',
    lineas: [
      { descripcion: 'Filtro', cantidad: 2, precio_unitario: '$100.00', codigo: 'LF-3000' },
      { descripcion: '', cantidad: 1, precio_unitario: 5 },
      { descripcion: 'Sin cantidad', cantidad: 0, precio_unitario: 5 },
      { descripcion: 'Sin precio', cantidad: 1 }
    ]
  })
  assert.equal(l.proveedor, 'Cummins')
  assert.equal(l.lineas.length, 1)
  assert.equal(l.descartadas, 3)
  assert.equal(l.lineas[0].precio_unitario, 100)
  assert.equal(l.total, 1160)
  assert.equal(l.moneda, 'MXN')
})

test('una fecha mal escrita se descarta y los dólares se detectan', () => {
  const l = normalizarLectura({ fecha: '7/10/2026', moneda: 'usd', lineas: [] })
  assert.equal(l.fecha, '')
  assert.equal(l.moneda, 'USD')
  assert.deepEqual(normalizarLectura(null).lineas, [])
})

test('un precio con IVA incluido se pasa a costo sin IVA', () => {
  assert.equal(costoSinIva(116, true), 100)
  assert.equal(costoSinIva(100, false), 100)
})

test('el cuadre avisa cuando la lectura no suma el subtotal impreso', () => {
  const lineas = [{ cantidad: 2, costo_unitario: 100 }, { cantidad: 5, costo_unitario: 40 }]
  assert.equal(cuadre(lineas, 400).cuadra, true)
  assert.equal(cuadre(lineas, 450).cuadra, false)
  assert.equal(cuadre(lineas, 450).diferencia, -50)
  assert.equal(cuadre(lineas, null).cuadra, null)
  assert.equal(cuadre(lineas, 400.4).cuadra, true)   // un redondeo no es un renglón perdido
})

test('un código del proveedor ya conocido empata con seguridad', () => {
  const c = candidatos({ codigo: 'lf 3000', descripcion: 'cualquier cosa' }, { productos: catalogo, vinculos, proveedor: 'CUMMINS MÉXICO' })
  assert.equal(c[0].producto.id, 'p1')
  assert.equal(c[0].razon, 'codigo_proveedor')
  assert.equal(decisionInicial(c).certeza, 'segura')
})

test('el mismo código en OTRO proveedor no cuenta como código del proveedor', () => {
  const c = candidatos({ codigo: 'LF-3000', descripcion: 'x' }, { productos: catalogo, vinculos, proveedor: 'Otro proveedor' })
  assert.ok(!c.some(x => x.razon === 'codigo_proveedor'))
})

test('un código igual al SKU del catálogo se preselecciona pero se pide revisar', () => {
  const c = candidatos({ codigo: 'BAT-12V', descripcion: 'acumulador' }, { productos: catalogo, vinculos: [], proveedor: 'X' })
  const d = decisionInicial(c)
  assert.equal(d.producto_id, 'p5')
  assert.equal(d.certeza, 'probable')
  assert.equal(textoDeRazon(c[0]), 'Mismo SKU')
})

test('un nombre casi igual se propone; uno apenas parecido deja la decisión pendiente', () => {
  const casi = candidatos({ codigo: '', descripcion: 'Filtro de aceite Fleetguard LF3000' }, { productos: catalogo })
  assert.equal(decisionInicial(casi).producto_id, 'p1')
  const flojo = candidatos({ codigo: '', descripcion: 'Filtro de aceite motor' }, { productos: catalogo })
  assert.ok(flojo.length > 0)
  assert.equal(decisionInicial(flojo).tipo, 'pendiente')
  assert.equal(decisionInicial(flojo).certeza, 'dudosa')
  assert.match(textoDeRazon(flojo[0]), /Parecido por nombre \(\d+ %\)/)
})

test('un filtro de aire NO se empata con el filtro de aceite', () => {
  const c = candidatos({ codigo: '', descripcion: 'Filtro de aire primario' }, { productos: catalogo })
  assert.equal(decisionInicial(c).tipo, 'nuevo')
})

test('lo que no se parece a nada se propone como pieza nueva', () => {
  const c = candidatos({ codigo: 'ZZ-9', descripcion: 'Tarjeta controladora de transferencia' }, { productos: catalogo })
  assert.equal(c.length, 0)
  const d = decisionInicial(c)
  assert.equal(d.tipo, 'nuevo')
  assert.equal(d.certeza, 'sin_pareja')
})

test('un proveedor conocido se reconoce aunque cambie la razón social impresa', () => {
  const conocidos = ['Cummins México', 'Solarama']
  assert.equal(proveedorSugerido('CUMMINS MEXICO S.A. DE C.V.', conocidos), 'Cummins México')
  assert.equal(proveedorSugerido('Refaccionaria El Sol', conocidos), '')
  assert.equal(proveedorSugerido('', conocidos), '')
})

test('el SKU sugerido es el código del proveedor, limpio', () => {
  assert.equal(skuSugerido(' lf 3000/a '), 'LF-3000/A')
  assert.equal(skuSugerido('ñ#$%'), '')
  assert.equal(skuSugerido(null), '')
})

const linea = (extra = {}) => ({
  codigo: 'C1', descripcion: 'Pieza', cantidad: 2, costo_unitario: 10,
  decision: { tipo: 'producto', producto_id: 'p1' }, ...extra
})

test('no se puede registrar con una línea sin decidir', () => {
  const f = problemasDeRevision({ proveedor: 'X', lineas: [linea({ decision: { tipo: 'pendiente' } })] })
  assert.ok(f.some(x => /decidir/.test(x)))
  assert.deepEqual(problemasDeRevision({ proveedor: 'X', lineas: [linea()] }), [])
})

test('una línea en "buscar otra pieza" sin elegir cuenta como pendiente y no se manda', () => {
  const l = linea({ decision: { tipo: 'buscar' } })
  assert.ok(problemasDeRevision({ proveedor: 'X', lineas: [l] }).some(x => /decidir/.test(x)))
  assert.equal(lineasParaRegistrar([l]).length, 0)
})

test('si todas las líneas se omiten no hay nada que registrar', () => {
  const f = problemasDeRevision({ proveedor: 'X', lineas: [linea({ decision: { tipo: 'omitir' } })] })
  assert.ok(f.some(x => /ninguna línea/.test(x)))
})

test('una pieza nueva pide SKU, nombre y categoría', () => {
  const l = linea({ decision: { tipo: 'nuevo', nuevo: { sku: '', nombre: '', categoria: '' } } })
  const f = problemasDeRevision({ proveedor: 'X', lineas: [l] })
  assert.ok(f.some(x => /SKU/.test(x)) && f.some(x => /nombre/.test(x)) && f.some(x => /categoría/.test(x)))
})

test('dos piezas nuevas con el mismo SKU, o un SKU que ya existe, se frenan', () => {
  const n = sku => linea({ decision: { tipo: 'nuevo', nuevo: { sku, nombre: 'N', categoria: 'refaccion' } } })
  const dup = problemasDeRevision({ proveedor: 'X', lineas: [n('a-1'), n('A-1')] })
  assert.ok(dup.some(x => /dos piezas nuevas/.test(x)))
  const existe = problemasDeRevision({ proveedor: 'X', lineas: [n('fil-ace-001')], skuExistentes: new Set(['FIL-ACE-001']) })
  assert.ok(existe.some(x => /ya existe/.test(x)))
})

test('las líneas que van a la base: omitidas fuera, nuevas con su pieza y vacío como null', () => {
  const salida = lineasParaRegistrar([
    linea({ actualizar_costo: true }),
    linea({ codigo: '  ', decision: { tipo: 'nuevo', nuevo: { sku: ' x-1 ', nombre: ' N ', categoria: 'refaccion', unidad: '' } } }),
    linea({ decision: { tipo: 'omitir' } }),
    linea({ decision: { tipo: 'pendiente' } })
  ])
  assert.equal(salida.length, 2)
  assert.equal(salida[0].producto_id, 'p1')
  assert.equal(salida[0].actualizar_costo, true)
  assert.equal(salida[1].codigo, null)
  assert.deepEqual(salida[1].nuevo, { sku: 'x-1', nombre: 'N', categoria: 'refaccion', unidad: 'pieza' })
  assert.equal(salida[1].producto_id, undefined)
})

test('la factura se sube a una ruta de lecturas que no se pisa', () => {
  assert.equal(rutaDeLectura('Factura Cummins Nº1.PDF', true, 7), 'lecturas/7-Factura-Cummins-N-1.pdf')
  assert.notEqual(rutaDeLectura('a.jpg', false, 1), rutaDeLectura('a.jpg', false, 2))
})
