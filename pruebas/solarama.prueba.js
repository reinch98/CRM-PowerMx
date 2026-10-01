import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  juntar, precioDe, renglones, datosAscender, filasDeSolarama,
} from '../scripts/proveedor/adaptadores/solarama.js'
import { leerArgumentos } from '../scripts/proveedor/sync.js'
import { adaptador } from '../scripts/proveedor/adaptadores/index.js'

// Textos de mentira con la misma forma que los del PDF de Solarama: cada pedazo con su página, su
// posición (x desde la izquierda, y desde arriba) y su ancho. El ancho importa: dos pedazos que se
// tocan van juntos ("MIN 6000TL" + "-" + "X2").
const t = (p, x, y, s, w) => ({ p, x, y, s, w: w ?? s.length * 5 })

const PIE = (p) => [
  t(p, 32, 714, 'PRECIOS EN DÓLARES AMERICANOS'),
  t(p, 32, 726, 'TIPO DE CAMBIO DE ACUERDO AL DIARIO OFICIAL DEL DIA DE PAGO. PRECIOS SON MÁS IVA.'),
  t(p, 32, 739, 'VIGENCIA APARTIR DEL 3 DE SEPTIEMBRE DEL 2026'),
]

// Página como la de inversores Growatt: la descripción va en dos renglones, uno ARRIBA y otro ABAJO
// del renglón que trae el código y el precio.
const GROWATT = [
  t(2, 217, 91, 'Inversores Interconectados'),
  t(2, 90, 121, 'SKU'), t(2, 308, 121, 'Descripción'), t(2, 530, 121, 'Precio'),
  t(2, 176, 138, 'Inversor GROWATT de 2.5 KW a 220V con 1 MPPT'),
  t(2, 64, 145, 'MIC 2500TL', 59), t(2, 123, 145, '-', 4), t(2, 127, 145, 'X2'),
  t(2, 535, 145, '$', 8), t(2, 544, 145, '2', 6), t(2, 550, 145, '53'),
  t(2, 176, 151, 'Certificado UL. 10 años de garantía.'),
  t(2, 176, 274, 'Inversor GROWATT de 8 KW a 220V con 3 MPPT'),
  t(2, 64, 281, 'MIN 8000TL', 59), t(2, 123, 281, '‐', 4), t(2, 127, 281, 'X2'),
  t(2, 535, 281, '$', 8), t(2, 544, 281, '1,614'),
  t(2, 176, 287, 'Wifi X incluido.'),
  ...PIE(2),
]

// Página de paneles: el modelo en su renglón, los precios "menos de 1 pallet" y "1 pallet" en dos
// columnas, y uno que solo se vende por pallet.
const PANELES = [
  t(3, 259, 70, 'Paneles solares'),
  t(3, 62, 107, 'Marca'), t(3, 203, 107, 'Descripción'), t(3, 348, 107, 'Menor a 1 pallet'), t(3, 457, 107, '1 pallet'),
  t(3, 193, 433, 'NEG19RC.20', 53), t(3, 246, 433, '-', 3), t(3, 249, 433, '630W'),
  t(3, 355, 439, '.173 USD/WATT'), t(3, 444, 439, '.171 USD/WATT'),
  t(3, 140, 445, '630W N-TYPE TOPCON BIFACIAL.'),
  t(3, 351, 452, '$108.99 USD/PZA'), t(3, 440, 452, '$107.73 USD/PZA'),
  t(3, 196, 483, 'TWMNF', 32), t(3, 228, 483, '-', 3), t(3, 231, 483, '66HD715'),
  t(3, 347, 489, 'Exclusiva venta por'), t(3, 444, 489, '.162 USD/WATT'),
  t(3, 129, 495, '715W N-TYPE TOPCON BIFACIAL.'),
  t(3, 358, 501, 'pallet cerrado'), t(3, 440, 501, '$115.83 USD/PZA'),
  ...PIE(3),
]

test('juntar: lo que se toca va pegado, lo separado con espacio, y el guion tipográfico es guion', () => {
  assert.equal(juntar([t(1, 64, 0, 'MIN 6000TL', 50), t(1, 114, 0, '-', 4), t(1, 118, 0, 'X2')]), 'MIN 6000TL-X2')
  assert.equal(juntar([t(1, 10, 0, 'KIT', 15), t(1, 40, 0, 'ASCENDER')]), 'KIT ASCENDER')
  assert.equal(juntar([t(1, 60, 0, 'MAX 50KTL3', 50), t(1, 110, 0, '‐', 4), t(1, 114, 0, 'XL2')]), 'MAX 50KTL3-XL2')
})

test('precioDe: el precio aunque venga partido en pedazos; "sujeto a proyecto" no es precio', () => {
  assert.equal(precioDe('$ 1,  ,010'), 1010)
  assert.equal(precioDe('$ 29.63'), 29.63)
  assert.equal(precioDe('$5,818.49'), 5818.49)
  assert.equal(precioDe('(sujeto a proyecto)'), null)
  assert.equal(precioDe(''), null)
})

test('renglones: textos a la misma altura (±3.5 puntos) van en el mismo renglón', () => {
  const r = renglones([t(1, 10, 100, 'a'), t(1, 50, 102, 'b'), t(1, 10, 120, 'c')])
  assert.equal(r.length, 2)
  assert.deepEqual(r[0].textos.map((x) => x.s), ['a', 'b'])
})

test('datosAscender: filas, paneles, grados y elevación salen del código', () => {
  assert.deepEqual(datosAscender('ASCENDER2X3A15°'), { filas: 2, porFila: 3, grados: 15, elevacion: 'elevada 50.8 cm' })
  assert.deepEqual(datosAscender('ASCEN1X4A10°'), { filas: 1, porFila: 4, grados: 10, elevacion: 'elevada 25.4 cm' })
  assert.equal(datosAscender('ASCE1X10A20°').elevacion, 'sin elevación')
  assert.equal(datosAscender('KIT1X4A10°'), null)
})

test('una página de inversores: código, precio y la descripción de arriba y de abajo juntas', () => {
  const r = filasDeSolarama(GROWATT, { minimo: 1 })
  assert.equal(r.vigencia, '3 DE SEPTIEMBRE DEL 2026')
  assert.equal(r.filas.length, 2)
  const [mic, min] = r.filas
  assert.equal(mic.sku_proveedor, 'MIC 2500TL-X2')
  assert.equal(mic.costo, 253)
  assert.equal(mic.nombre, 'Inversor GROWATT de 2.5 KW a 220V con 1 MPPT Certificado UL. 10 años de garantía.')
  assert.equal(mic.categoria, 'Inversores')
  assert.equal(mic.marca, 'Growatt')
  assert.equal(mic.moneda, 'USD')
  assert.equal(min.sku_proveedor, 'MIN 8000TL-X2') // el guion tipográfico quedó normal
  assert.equal(min.costo, 1614)
  assert.deepEqual(min.documentos, {})
  assert.equal(min.stock_local, null) // Solarama no da existencias
})

test('paneles: el precio por pieza de menos de 1 pallet; si solo se vende por pallet, se dice', () => {
  const r = filasDeSolarama(PANELES, { minimo: 1 })
  const [trina, tongwei] = r.filas
  assert.equal(trina.sku_proveedor, 'NEG19RC.20-630W')
  assert.equal(trina.marca, 'Trina Solar')
  assert.equal(trina.costo, 108.99)
  assert.match(trina.descripcion, /1 pallet: USD 107\.73/)
  assert.equal(tongwei.sku_proveedor, 'TWMNF-66HD715')
  assert.equal(tongwei.marca, 'Tongwei')
  assert.equal(tongwei.costo, 115.83)
  assert.match(tongwei.nombre, /solo por pallet/)
  assert.match(tongwei.descripcion, /Venta solo por pallet cerrado/)
})

test('si Solarama cambia el formato, la lectura falla diciendo la página, no entrega precios malos', () => {
  const rara = [t(4, 200, 90, 'Promociones del mes'), t(4, 60, 140, 'ALGO'), t(4, 530, 140, '$ 10'), ...PIE(4)]
  assert.throws(() => filasDeSolarama([...GROWATT, ...rara], { minimo: 1 }), /página 4/)
  assert.throws(() => filasDeSolarama(GROWATT), /Solo leí 2 productos/)
  assert.throws(() => filasDeSolarama([t(1, 10, 100, 'Otra lista cualquiera')]), /no parece la lista de precios de Solarama/)
})

test('un precio absurdo (la lectura se descuadró) detiene todo', () => {
  const malo = GROWATT.map((x) => (x.s === '1,614' ? { ...x, s: '99,614' } : x))
  assert.throws(() => filasDeSolarama(malo, { minimo: 1 }), /Precio fuera de rango en MIN 8000TL-X2/)
})

test('sync: con --proveedor solarama se usa su adaptador sin tener que decirlo', () => {
  assert.equal(leerArgumentos(['--proveedor', 'solarama', '--archivo', 'x.pdf']).adaptador, 'solarama')
  assert.equal(leerArgumentos(['--proveedor', 'solarama', '--adaptador', 'excel', '--archivo', 'x.xlsx']).adaptador, 'excel')
  assert.equal(leerArgumentos(['--archivo', 'x.xlsx']).adaptador, 'excel')
  assert.equal(typeof adaptador('solarama'), 'function')
})

test('el adaptador de Solarama solo acepta el PDF', async () => {
  await assert.rejects(adaptador('solarama')({ archivo: 'lista.xlsx' }), /lee el PDF/)
  await assert.rejects(adaptador('solarama')({}), /Falta la ruta/)
})
