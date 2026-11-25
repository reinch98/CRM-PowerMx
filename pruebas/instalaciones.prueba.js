// Cotizador de instalaciones (SQL 104). Lo que aquí se cuida: que la cantidad salga bien de los
// metros (sin pedir un tubo de más por un redondeo), que de cada grupo entre solo la opción elegida,
// que la cantidad escrita a mano mande, que las partidas salgan LIBRES (sin producto_id), y que el
// gas a 15 m dé los mismos $13,300 de la hoja "INSTALACIÓN GAS" de ESTRUCTURA.xlsx.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  cantidadSugerida, estadoInicial, lineasDeBloque, totalesDeLineas, partidasDeInstalacion,
  notasDeInstalacion, paraGuardarMaterial, problemasDeMaterial,
} from '../src/lib/instalaciones.js'

const m = (id, bloque, extra) => ({ id, bloque, tipo: 'material', unidad: 'pza', activo: true,
  cantidad_fija: 0, por_metro: 0, metros_incluidos: 0, grupo: null, predeterminado: false, costo: null, orden: 0, ...extra })

// Como la siembra del 104.
const MATERIALES = [
  m('cal2', 'electrica', { nombre: 'Cable cal. 2 AWG', unidad: 'm', precio: 188.76, costo: 121, cantidad_fija: 6, por_metro: 3, grupo: 'cable_fuerza', predeterminado: true, orden: 10 }),
  m('cal4', 'electrica', { nombre: 'Cable cal. 4 AWG', unidad: 'm', precio: 111.633, cantidad_fija: 6, por_metro: 3, grupo: 'cable_fuerza', orden: 11 }),
  m('tubo', 'electrica', { nombre: 'Tubo 2" cédula 40', precio: 175, costo: 125, por_metro: 0.3333, grupo: 'tuberia', predeterminado: true, orden: 30 }),
  m('codo', 'electrica', { nombre: 'Codo 90° 2"', precio: 171.6, cantidad_fija: 4, orden: 41 }),
  m('gabinete', 'electrica', { nombre: 'Gabinete', precio: 1200, orden: 60 }),
  m('mo', 'electrica', { nombre: 'Mano de obra eléctrica', tipo: 'mano_obra', unidad: 'servicio', precio: 9000, cantidad_fija: 1, metros_incluidos: 10, descripcion: 'Mano de obra de instalación eléctrica.', orden: 90 }),
  m('mo_m', 'electrica', { nombre: 'Por metro', tipo: 'mano_obra', unidad: 'm', precio: 370, por_metro: 1, metros_incluidos: 10, orden: 91 }),
  m('durman', 'gas', { nombre: 'Tubería PE-AL-PE', unidad: 'm', precio: 80, por_metro: 2, orden: 10 }),
  m('gcodo', 'gas', { nombre: 'Codo 90°', precio: 250, cantidad_fija: 5, orden: 20 }),
  m('ralta', 'gas', { nombre: 'Regulador de alta', precio: 1800, cantidad_fija: 1, orden: 21 }),
  m('rbaja', 'gas', { nombre: 'Regulador de baja', precio: 1800, cantidad_fija: 1, orden: 22 }),
  m('punta', 'gas', { nombre: 'Punta POL', precio: 150, cantidad_fija: 1, orden: 23 }),
  m('macho', 'gas', { nombre: 'Conector macho', precio: 250, cantidad_fija: 8, orden: 24 }),
  m('hembra', 'gas', { nombre: 'Conector hembra', precio: 250, cantidad_fija: 8, orden: 25 }),
  m('bushing', 'gas', { nombre: 'Bushing', precio: 150, cantidad_fija: 2, orden: 26 }),
  m('te', 'gas', { nombre: 'Te', precio: 250, orden: 27 }),
  m('mano', 'gas', { nombre: 'Manómetro', precio: 800, cantidad_fija: 2, orden: 28 }),
  m('ats', 'otro', { nombre: 'Transferencia automática 100 A', precio: 16500, cantidad_fija: 1 }),
  m('viejo', 'otro', { nombre: 'Ya no se usa', precio: 1, cantidad_fija: 1, activo: false }),
]

test('la cantidad sale de los metros, hacia arriba y sin un tubo de más por el redondeo', () => {
  const tubo = MATERIALES.find(x => x.id === 'tubo')
  assert.equal(cantidadSugerida(tubo, 15), 5)
  assert.equal(cantidadSugerida(tubo, 16), 6)
  assert.equal(cantidadSugerida(MATERIALES.find(x => x.id === 'cal2'), 15), 51)
  // Los metros incluidos no se cobran.
  const porMetro = MATERIALES.find(x => x.id === 'mo_m')
  assert.equal(cantidadSugerida(porMetro, 8), 0)
  assert.equal(cantidadSugerida(porMetro, 25), 15)
})

test('el gas a 15 m da los $13,300 de la hoja de ESTRUCTURA.xlsx', () => {
  const estado = estadoInicial(MATERIALES)
  const t = totalesDeLineas(lineasDeBloque(MATERIALES, 'gas', estado.gas))
  assert.equal(t.total, 13300)
})

test('de cada grupo entra solo la opción elegida, empezando por la predeterminada', () => {
  const estado = estadoInicial(MATERIALES)
  assert.equal(estado.electrica.elecciones.cable_fuerza, 'cal2')
  let ids = lineasDeBloque(MATERIALES, 'electrica', estado.electrica).map(l => l.material.id)
  assert.ok(ids.includes('cal2') && !ids.includes('cal4'))
  estado.electrica.elecciones.cable_fuerza = 'cal4'
  ids = lineasDeBloque(MATERIALES, 'electrica', estado.electrica).map(l => l.material.id)
  assert.ok(ids.includes('cal4') && !ids.includes('cal2'))
})

test('la cantidad escrita a mano manda; vacía regresa a la sugerida; nunca negativa', () => {
  const estado = estadoInicial(MATERIALES)
  const de = id => lineasDeBloque(MATERIALES, 'electrica', estado.electrica).find(l => l.material.id === id)
  estado.electrica.cantidades.gabinete = '2'
  assert.equal(de('gabinete').cantidad, 2)
  assert.equal(de('gabinete').importe, 2400)
  estado.electrica.cantidades.gabinete = ''
  assert.equal(de('gabinete').cantidad, 0)
  estado.electrica.cantidades.codo = '-3'
  assert.equal(de('codo').cantidad, 0)
})

test('las partidas salen libres: materiales en un lote y mano de obra aparte', () => {
  const estado = estadoInicial(MATERIALES)
  estado.electrica.activo = true
  estado.electrica.metros = 20
  const p = partidasDeInstalacion({ materiales: MATERIALES, estado })
  assert.equal(p.length, 2)
  assert.ok(p.every(x => x.producto_id === null))
  assert.match(p[0].descripcion, /hasta 20 m/)
  assert.match(p[0].descripcion, /Cable cal\. 2 AWG \(66 m\)/)
  assert.doesNotMatch(p[0].descripcion, /Gabinete/) // cantidad 0: no se menciona
  // 66 × 188.76 + 7 tubos × 175 + 4 codos × 171.6 = 12,458.16 + 1,225 + 686.40 = 14,369.56
  assert.equal(p[0].precio_unitario, 14369.56)
  // 9,000 + 10 m × 370
  assert.equal(p[1].precio_unitario, 12700)
  assert.match(p[1].descripcion, /hasta 20 m/)
})

test('desglosado sale una partida por material; los extras van uno por uno; lo inactivo no sale', () => {
  const estado = estadoInicial(MATERIALES)
  estado.gas.activo = true
  estado.otro.activo = true
  const p = partidasDeInstalacion({ materiales: MATERIALES, estado, desglosar: true })
  assert.equal(p.filter(x => x.instalacion === 'gas').length, 9) // la Te va en 0
  const extras = p.filter(x => x.instalacion === 'otro')
  assert.deepEqual(extras.map(x => x.descripcion), ['Transferencia automática 100 A'])
  // Un bloque apagado no da partidas.
  estado.gas.activo = false
  assert.equal(partidasDeInstalacion({ materiales: MATERIALES, estado }).filter(x => x.instalacion === 'gas').length, 0)
})

test('la nota interna dice el total por bloque y el costo conocido sin inventar el que falta', () => {
  const estado = estadoInicial(MATERIALES)
  estado.electrica.activo = true
  const n = notasDeInstalacion({ materiales: MATERIALES, estado })
  assert.match(n, /Instalación eléctrica \(15 m\)/)
  // Costo: 51 × 121 + 5 × 125 = 6,796; el codo no tiene costo y se dice aparte.
  assert.match(n, /Costo conocido de materiales: \$6,796\.00/)
  assert.match(n, /sin costo capturado/)
})

test('guardar un material: vacíos como null y una predeterminada solo con grupo', () => {
  const f = paraGuardarMaterial({ bloque: 'gas', nombre: ' Llave de paso ', precio: '350', costo: '', cantidad_fija: '1', por_metro: '', metros_incluidos: '', grupo: '', predeterminado: true })
  assert.equal(f.nombre, 'Llave de paso')
  assert.equal(f.precio, 350)
  assert.equal(f.costo, null)
  assert.equal(f.por_metro, 0)
  assert.equal(f.grupo, null)
  assert.equal(f.predeterminado, false)
  assert.deepEqual(problemasDeMaterial({ nombre: '', precio: '' }), ['Escribe el nombre.', 'Escribe el precio (sin IVA).'])
  assert.deepEqual(problemasDeMaterial({ nombre: 'x', precio: '1', por_metro: '-1' }), ['Las cantidades y el costo no pueden ser negativos.'])
})
