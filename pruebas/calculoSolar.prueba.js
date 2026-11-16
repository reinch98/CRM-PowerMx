// Fase 5 de la calculadora solar: de la solicitud con cálculo a las partidas de la cotización.
//
// Lo que aquí se cuida: que el paquete NUNCA entre con producto_id (apartaría un "paquete"
// que no existe), que las piezas de la receta sí lo lleven a $0 e incluidas, que el precio
// sea el de HOY y que el cambio contra lo que vio el cliente se diga, y que los avisos de la
// calculadora (2 hilos sobre todo) no se pierdan.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  avisosDeCalculo, resumenCalculo, barrasHistorial, precioDeVariante, partidasDePaqueteSolar,
  textoCambio, clienteDeSolicitud, notasDeSolicitud,
} from '../src/lib/calculoSolar.js'
import { dejarEncargo, tomarEncargo } from '../src/lib/encargo.js'

// El cálculo del recibo de referencia (16/11/2026), como lo guarda el SQL 98.
const CALCULO = {
  version: 1, fuente: 'recibo', tipo: 'residencial', tarifa: '1D', hilos: 2, servicio_ult4: '1480',
  kwh_mes: 468.8, gasto_mes: 992.66, tarifa_efectiva: 2.699, dap_mes: 59.31, dias: 367,
  crecimiento: 0.241, fuente_gasto: 'historial', incremento_cfe: 0.06, a_la_medida: false,
  paquete: { sku: 'PKG-ESSENTIAL', nombre: 'Essential', variante: 'interconectado', paneles: 6, kw: 3.78,
             precio: 53999, cobertura: 1, ahorro_mes: 900.85, recibo_despues_mes: 91.81, retorno_anios: 4.6 },
  avisos: ['crecimiento', 'dos_hilos'],
  historial: [{ fin: '2026-11-09', dias: 63, kwh: 1102, importe: 2974.76 }, { fin: '2026-09-07', dias: 60, kwh: 1074, importe: 1570 }],
}

const PAQUETE = {
  id: 'pkg', sku: 'PKG-ESSENTIAL', nombre: 'Essential', categoria: 'paquete_solar', precio: 53999,
  precios: { estandar: 53999, hibrido: 103999, hibrido_b: 0 },
  atributos: { kw: 3.78, paneles: 6 },
  descripcion: 'Paneles JA Solar 630 W bifaciales | Inversor Growatt con monitoreo Wi-Fi | Trámite ante CFE',
}
const pieza = (id, sku, unidad = 'pieza', activo = true) => ({ id, sku, nombre: `Pieza ${sku}`, unidad, activo })
const LINEAS = [
  { variante: 'interconectado', cantidad: 6, producto: pieza('p1', 'PSOJAS1S207') },
  { variante: 'interconectado', cantidad: 1, producto: pieza('p2', 'INVGROWS4') },
  { variante: 'interconectado', cantidad: 0.3, producto: pieza('p3', 'SINPVA1S341', 'rollo') },
  { variante: 'interconectado', cantidad: 0.3, producto: pieza('p3', 'SINPVA1S341', 'rollo') },
  { variante: 'interconectado', cantidad: 4, producto: null }, // mano de obra: parámetro, sin producto
  { variante: 'respaldo', cantidad: 1, producto: pieza('p9', 'BATLUXS107') },
  { variante: 'hibrido_b', cantidad: 1, producto: pieza('p8', 'INVLUXS109') },
]

test('el paquete entra con el precio de hoy y SIN producto_id; las piezas, a $0 e incluidas', () => {
  const r = partidasDePaqueteSolar({ producto: PAQUETE, lineas: LINEAS, calculo: CALCULO })
  assert.equal(r.error, undefined)
  const [principal, ...piezas] = r.partidas
  assert.equal(principal.producto_id, null)
  assert.equal(principal.sku, 'PKG-ESSENTIAL')
  assert.equal(principal.servicio, 'paquete_solar')
  // 53,999 / 1.16 y el IVA lo devuelve: el total de la cotización es el de lista.
  assert.ok(Math.abs(principal.precio_unitario * 1.16 - 53999) < 0.01)
  assert.match(principal.descripcion, /interconectado — paquete Essential: 6 paneles \(3\.78 kWp\)\. Incluye: Paneles JA Solar/)
  assert.deepEqual(piezas.map(p => [p.sku, p.cantidad, p.precio_unitario, p.incluida]), [
    ['PSOJAS1S207', 6, 0, true],
    ['INVGROWS4', 1, 0, true],
    ['SINPVA1S341', 0.6, 0, true], // dos líneas de la misma pieza se suman
  ])
  assert.ok(piezas.every(p => p.producto_id))
  assert.equal(r.cambio, null) // el precio no cambió
  assert.deepEqual(r.avisos, [])
})

test('con respaldo: suma las piezas del respaldo, usa el precio híbrido y no compara contra lo que vio', () => {
  const r = partidasDePaqueteSolar({ producto: PAQUETE, lineas: LINEAS, variante: 'respaldo', calculo: CALCULO })
  assert.ok(Math.abs(r.partidas[0].precio_unitario * 1.16 - 103999) < 0.01)
  assert.match(r.partidas[0].descripcion, /con respaldo en apagones/)
  assert.ok(r.partidas.some(p => p.sku === 'BATLUXS107'))
  assert.ok(!r.partidas.some(p => p.sku === 'INVLUXS109')) // el híbrido B es otra receta
  assert.equal(r.cambio, null) // el cliente vio el interconectado: no se compara con el híbrido
})

test('si el precio cambió desde que lo vio el cliente, lo dice con los dos números', () => {
  const r = partidasDePaqueteSolar({ producto: { ...PAQUETE, precios: { ...PAQUETE.precios, estandar: 56999 } }, lineas: LINEAS, calculo: CALCULO })
  assert.deepEqual(r.cambio, { visto: 53999, hoy: 56999, diferencia: 3000 })
  assert.equal(textoCambio(r.cambio), 'El cliente vio $53,999 y hoy el paquete cuesta $56,999 (sube $3,000). La cotización va con el precio de hoy.')
  assert.equal(textoCambio(null), '')
})

test('sin precio publicado no inventa uno; sin piezas en la receta, avisa', () => {
  assert.match(partidasDePaqueteSolar({ producto: PAQUETE, lineas: LINEAS, variante: 'respaldo', calculo: null }).partidas[0].sku, /PKG/)
  const sinHibrido = { ...PAQUETE, precios: { estandar: 53999, hibrido: 0 } }
  assert.match(partidasDePaqueteSolar({ producto: sinHibrido, variante: 'respaldo' }).error, /no tiene precio publicado con respaldo/)
  assert.match(partidasDePaqueteSolar({ producto: null }).error, /No encontramos el paquete/)
  assert.match(partidasDePaqueteSolar({ producto: PAQUETE, variante: 'otra' }).error, /Variante/)
  const r = partidasDePaqueteSolar({ producto: PAQUETE, lineas: [] })
  assert.equal(r.partidas.length, 1)
  assert.match(r.avisos[0], /no se apartará material/)
  const baja = partidasDePaqueteSolar({ producto: PAQUETE, lineas: [{ variante: 'interconectado', cantidad: 1, producto: pieza('p5', 'VIEJA', 'pieza', false) }] })
  assert.match(baja.avisos[0], /una pieza dada de baja: VIEJA/)
})

test('precioDeVariante: el estándar cae al precio plano; el híbrido no', () => {
  assert.equal(precioDeVariante({ precio: 42999, precios: {} }), 42999)
  assert.equal(precioDeVariante({ precio: 42999, precios: {} }, 'respaldo'), null)
  assert.equal(precioDeVariante(null), null)
})

test('los avisos: lo importante primero y el crecimiento con su porcentaje; claves desconocidas fuera', () => {
  const a = avisosDeCalculo({ ...CALCULO, avisos: ['crecimiento', 'inventado', 'dos_hilos'] })
  assert.deepEqual(a.map(x => [x.clave, x.nivel]), [['dos_hilos', 'alto'], ['crecimiento', 'info']])
  assert.match(a[1].texto, /creció 24 %/)
  assert.deepEqual(avisosDeCalculo(null), [])
})

test('el resumen: solo lo que trae, con palabras', () => {
  const r = Object.fromEntries(resumenCalculo(CALCULO).map(f => [f.etiqueta, f.valor]))
  assert.equal(r['Consumo promedio'], '469 kWh al mes (12 meses de recibos)')
  assert.equal(r['Paga hoy de luz'], '$993 al mes')
  assert.equal(r['Costo por kWh'], '$2.70 · tarifa 1D')
  assert.equal(r.Servicio, '2 hilos (127 V)')
  assert.equal(r.Recibo, 'Número de servicio terminado en 1480')
  assert.equal(r['Paquete que vio'], 'Essential · 6 paneles · 3.78 kWp · $53,999 con IVA')
  assert.equal(r['Ahorro que vio'], '$901 al mes · se paga en unos 4.5 años')
  const minimo = resumenCalculo({ kwh_mes: 300, a_la_medida: true })
  assert.deepEqual(minimo.map(f => f.etiqueta), ['Consumo promedio', 'Paquete que vio'])
  assert.equal(minimo[1].valor, 'Ninguno: sistema a la medida')
  assert.deepEqual(resumenCalculo({}), [])
})

test('el historial en barras relativas al mayor', () => {
  const b = barrasHistorial(CALCULO.historial)
  assert.deepEqual(b.map(x => [x.etiqueta, x.kwh, x.importe, x.pct]), [
    ['Al 09/11/26', 1102, 2974.76, 100],
    ['Al 07/09/26', 1074, 1570, 97],
  ])
  assert.deepEqual(barrasHistorial(null), [])
  assert.equal(barrasHistorial([{ kwh: 10 }])[0].etiqueta, 'Periodo 1')
})

test('cliente y nota interna salen de la solicitud', () => {
  const s = { nombre: ' Leydi Lara ', telefono: '999 123 4567', email: '', ubicacion: 'Vergel, Mérida', created_at: '2026-11-16T15:00:00Z' }
  assert.deepEqual(clienteDeSolicitud(s, CALCULO), {
    nombre: 'Leydi Lara', telefono: '999 123 4567', email: '', direccion: 'Vergel, Mérida',
    municipio: '', tipo_cliente: 'residencial', distancia_km: '',
  })
  assert.equal(clienteDeSolicitud(s, { tipo: 'gobierno' }).tipo_cliente, 'residencial')
  const n = notasDeSolicitud(s, CALCULO)
  assert.match(n, /^Solicitud del sitio \(calculadora solar\)/)
  assert.match(n, /IMPORTANTE: Servicio de 2 hilos/)
  assert.match(n, /Paquete que vio: Essential/)
})

test('el encargo se entrega una sola vez y solo a su pantalla', () => {
  dejarEncargo('cotizaciones', { a: 1 })
  assert.equal(tomarEncargo('clientes'), null)
  assert.deepEqual(tomarEncargo('cotizaciones'), { a: 1 })
  assert.equal(tomarEncargo('cotizaciones'), null)
})
