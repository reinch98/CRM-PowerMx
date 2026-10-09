import { test } from 'node:test'
import assert from 'node:assert/strict'
import { porcentaje, mesesDisponibles, mesPorOmision, resultadoIva, aCsv, csvContador } from '../src/lib/resico.js'

test('la tasa se dice en por ciento', () => {
  assert.equal(porcentaje(0.011), '1.1 %')
  assert.equal(porcentaje(0.025), '2.5 %')
  assert.equal(porcentaje(null), '—')
})

test('los meses empiezan en el alta de RESICO, el más reciente primero', () => {
  assert.deepEqual(mesesDisponibles('2026-09-22', '2026-10-09'), ['2026-10', '2026-09'])
  assert.deepEqual(mesesDisponibles('2026-11-01', '2027-01-15'), ['2027-01', '2026-12', '2026-11'])
  assert.deepEqual(mesesDisponibles('', '2026-10-09'), ['2026-10'])
})

test('hasta el día 17 se abre el mes anterior (el que se declara); después, el actual', () => {
  const meses = ['2026-10', '2026-09']
  assert.equal(mesPorOmision('2026-10-09', meses), '2026-09')
  assert.equal(mesPorOmision('2026-10-18', meses), '2026-10')
  // Si el mes anterior es antes del alta, se queda en el actual.
  assert.equal(mesPorOmision('2026-09-30', ['2026-09']), '2026-09')
})

test('IVA a cargo o a favor, en palabras', () => {
  assert.deepEqual(resultadoIva({ a_cargo: 7840, a_favor: 0 }), { etiqueta: 'IVA a cargo', monto: 7840, aFavor: false })
  assert.deepEqual(resultadoIva({ a_cargo: 0, a_favor: 300 }), { etiqueta: 'IVA a favor', monto: 300, aFavor: true })
})

test('el CSV escapa comas y comillas, y los números van con dos decimales', () => {
  const csv = aCsv([{ a: 'Refacciones, S.A. "La buena"', b: 1160 }], [['a', 'Proveedor'], ['b', 'Monto']])
  assert.equal(csv, 'Proveedor,Monto\r\n"Refacciones, S.A. ""La buena""",1160.00')
})

test('el paquete para el contador trae resumen, ingresos y gastos, con BOM para Excel', () => {
  const r = {
    periodo: { desde: '2027-03-01', hasta: '2027-03-31', limite_pago: '2027-04-17' },
    ingresos: { cobrado: 58000, iva: 8000, base: 50000, detalle: [{ fecha: '2027-03-10', cliente: 'X', monto: 58000, iva: 8000, base: 50000 }] },
    isr: { tasa: 0.011, causado: 550, retenido: 0, a_pagar: 550 },
    iva: { acreditable: 160, retenido: 0, a_cargo: 7840, a_favor: 0 },
    gastos: { total: 1660, sin_cfdi: 500, detalle: [{ fecha: '2027-03-11', proveedor: 'P', monto: 1160, iva: 160 }] },
    anual: { acumulado: 50000 }
  }
  const csv = csvContador(r, 'PABLO')
  assert.ok(csv.startsWith('﻿'))
  assert.ok(csv.includes('ISR estimado a pagar,550.00'))
  assert.ok(csv.includes('Tasa ISR RESICO,1.1 %'))
  assert.ok(csv.includes('INGRESOS COBRADOS'))
  assert.ok(csv.includes('2027-03-11,P,,,,1160.00,160.00,'))
})
