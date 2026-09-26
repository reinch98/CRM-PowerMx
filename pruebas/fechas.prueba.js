// Fechas en hora local: el error que esto atrapa es usar `toISOString()`, que en
// Mérida (UTC-6) después de las 6 pm ya dice "mañana".
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { hoyLocal, sumarDias, semanaLocal } from '../src/lib/fechas.js'

test('hoyLocal da AAAA-MM-DD y coincide con el reloj del dispositivo', () => {
  const d = new Date()
  const esperado = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
  assert.match(hoyLocal(), /^\d{4}-\d{2}-\d{2}$/)
  assert.equal(hoyLocal(), esperado)
})

test('sumarDias cruza fin de mes, fin de año y años bisiestos', () => {
  assert.equal(sumarDias('2026-09-30', 1), '2026-10-01')
  assert.equal(sumarDias('2026-12-31', 1), '2027-01-01')
  assert.equal(sumarDias('2028-02-28', 1), '2028-02-29')  // bisiesto
  assert.equal(sumarDias('2026-02-28', 1), '2026-03-01')  // no bisiesto
  assert.equal(sumarDias('2026-01-01', -1), '2025-12-31')
  assert.equal(sumarDias('2026-09-26', 0), '2026-09-26')
})

test('semanaLocal: la semana ISO empieza en lunes', () => {
  // 2026-09-21 es lunes y 2026-09-27 domingo: la misma semana.
  assert.equal(semanaLocal('2026-09-21'), semanaLocal('2026-09-27'))
  assert.notEqual(semanaLocal('2026-09-27'), semanaLocal('2026-09-28'))
})

test('semanaLocal: el cambio de año lo decide el jueves de la semana', () => {
  // 2027-01-01 es viernes, así que su jueves cae en 2026: semana 53 de 2026.
  assert.equal(semanaLocal('2027-01-01'), '2026-W53')
  assert.equal(semanaLocal('2026-12-31'), '2026-W53')
  // 2025-12-29 es lunes y su jueves ya es 2026: semana 1 de 2026.
  assert.equal(semanaLocal('2025-12-29'), '2026-W01')
  assert.equal(semanaLocal('2026-01-05'), '2026-W02')
})

test('semanaLocal siempre lleva dos dígitos en la semana', () => {
  assert.match(semanaLocal('2026-01-05'), /^\d{4}-W\d{2}$/)
  assert.match(semanaLocal('2026-09-26'), /^\d{4}-W\d{2}$/)
})
