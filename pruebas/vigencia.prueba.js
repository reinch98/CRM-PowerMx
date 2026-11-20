import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  fechaVence, diasEntre, semaforoVigencia, cotizacionesVisibles, resumenVigencia
} from '../src/lib/vigencia.js'

const HOY = '2026-11-19'

test('vence = fecha + vigencia, con 15 días si no hay', () => {
  assert.equal(fechaVence({ fecha: '2026-11-01', vigencia_dias: 10 }), '2026-11-11')
  assert.equal(fechaVence({ fecha: '2026-11-01', vigencia_dias: null }), '2026-11-16')
  assert.equal(fechaVence({ fecha: '2026-12-25', vigencia_dias: 15 }), '2027-01-09')
})

test('días entre fechas cruzando mes y año', () => {
  assert.equal(diasEntre('2026-11-19', '2026-11-22'), 3)
  assert.equal(diasEntre('2026-12-30', '2027-01-02'), 3)
  assert.equal(diasEntre('2026-11-19', '2026-11-15'), -4)
})

test('verde con más de 3 días', () => {
  const s = semaforoVigencia({ estado: 'enviada', fecha: '2026-11-15', vigencia_dias: 15 }, HOY)
  assert.equal(s.nivel, 'vigente')
  assert.equal(s.palabra, 'Vigente · vence el 30/11')
})

test('ámbar de 3 días a hoy, con la palabra exacta', () => {
  const c = d => ({ estado: 'borrador', fecha: '2026-11-04', vigencia_dias: d })
  assert.equal(semaforoVigencia(c(18), HOY).palabra, 'Vence en 3 días')
  assert.equal(semaforoVigencia(c(16), HOY).palabra, 'Vence mañana')
  assert.equal(semaforoVigencia(c(15), HOY).palabra, 'Vence hoy')
  assert.equal(semaforoVigencia(c(15), HOY).nivel, 'por_vencer')
})

test('rojo al pasar la vigencia (el día de vencer todavía vale)', () => {
  const s = semaforoVigencia({ estado: 'borrador', fecha: '2026-10-29', vigencia_dias: 15 }, HOY)
  assert.equal(s.nivel, 'vencida')
  assert.equal(s.palabra, 'Vencida hace 6 días')
  const uno = semaforoVigencia({ estado: 'enviada', fecha: '2026-11-03', vigencia_dias: 15 }, HOY)
  assert.equal(uno.palabra, 'Vencida hace 1 día')
})

test('aceptada no vence; vencida y rechazada son archivadas', () => {
  assert.equal(semaforoVigencia({ estado: 'aceptada', fecha: '2026-01-01' }, HOY).nivel, null)
  assert.equal(semaforoVigencia({ estado: 'vencida', fecha: '2026-01-01' }, HOY).palabra, 'Archivada · vencida')
  assert.equal(semaforoVigencia({ estado: 'rechazada', fecha: '2026-01-01' }, HOY).nivel, 'archivada')
})

test('la lista oculta las archivadas salvo que se pidan, y el resumen las cuenta', () => {
  const lista = [
    { estado: 'borrador', fecha: '2026-10-01', vigencia_dias: 15 },   // vencida
    { estado: 'enviada', fecha: '2026-11-05', vigencia_dias: 15 },    // vence en 1
    { estado: 'vencida', fecha: '2026-09-01' },
    { estado: 'rechazada', fecha: '2026-09-01' },
    { estado: 'aceptada', fecha: '2026-09-01' }
  ]
  assert.equal(cotizacionesVisibles(lista, false).length, 3)
  assert.equal(cotizacionesVisibles(lista, true).length, 5)
  assert.deepEqual(resumenVigencia(lista, HOY), { por_vencer: 1, vencida: 1, archivada: 2 })
})
