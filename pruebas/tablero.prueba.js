import { test } from 'node:test'
import assert from 'node:assert/strict'
import { nombreLinea, mesCorto, mesLargo, topeEje, pesosCortos, margenTotal, normalizarTablero } from '../src/lib/tablero.js'

test('líneas en palabras', () => {
  assert.equal(nombreLinea('polizas'), 'Pólizas')
  assert.equal(nombreLinea('otros'), 'Sin clasificar')
  assert.equal(nombreLinea(undefined), 'Sin clasificar')
})

test('meses cortos y largos sin pasar por fechas UTC', () => {
  assert.equal(mesCorto('2026-10'), 'oct')
  assert.equal(mesLargo('2026-01'), 'enero 2026')
})

test('el tope del eje es redondo y nunca queda por debajo del máximo', () => {
  assert.equal(topeEje(0), 1000)
  assert.equal(topeEje(7840), 10000)
  assert.equal(topeEje(58000), 100000)
  assert.equal(topeEje(1500), 2000)
  assert.equal(topeEje(5000), 5000)
})

test('pesos cortos para el eje', () => {
  assert.equal(pesosCortos(0), '$0')
  assert.equal(pesosCortos(50000), '$50k')
  assert.equal(pesosCortos(1500000), '$1.5 M')
})

test('el margen total se pondera por la venta, no es el promedio de los porcentajes', () => {
  // Una línea chica con 90 % no debe pesar igual que una grande con 10 %.
  const m = margenTotal([{ venta: 1000, utilidad: 900 }, { venta: 100000, utilidad: 10000 }])
  assert.equal(m, 10.8)
  assert.equal(margenTotal([]), null)
})

test('normaliza lo que llega de la base sin confiar en su forma', () => {
  const t = normalizarTablero({ resumen: { ingresos: '5800' }, mensual: [{ mes: '2026-10', ingresos: '5800', gastos: null }] })
  assert.equal(t.resumen.ingresos, 5800)
  assert.equal(t.resumen.gastos, 0)
  assert.deepEqual(t.mensual, [{ mes: '2026-10', ingresos: 5800, gastos: 0 }])
  assert.deepEqual(normalizarTablero(null).lineas, [])
})
