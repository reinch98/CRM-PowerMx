import { test } from 'node:test'
import assert from 'node:assert/strict'
import { normalizarGasto, propuestaDeGasto } from '../src/lib/finanzas.js'

// Un pedido de material a un proveedor: lo que el modo "ticket" rechazaba y dejaba vacío.
const PEDIDO = {
  documento: 'pedido', proveedor: 'EXEL SOLAR', rfc: 'ese010101abc', folio: '1474048', fecha: '2026-10-09',
  moneda: 'MXN', subtotal: '4,081.10', iva: 652.98, total: '$4,734.08', categoria: 'pago_proveedor',
  concepto: 'Cable fotovoltaico 10 AWG rojo y negro'
}

test('un pedido de proveedor se normaliza con las categorías de Finanzas', () => {
  const l = normalizarGasto(PEDIDO)
  assert.equal(l.documento, 'pedido')
  assert.equal(l.proveedor, 'EXEL SOLAR')
  assert.equal(l.rfc, 'ESE010101ABC')
  assert.equal(l.total, 4734.08)
  assert.equal(l.subtotal, 4081.1)
  assert.equal(l.categoria, 'pago_proveedor')
  assert.equal(l.moneda, 'MXN')
})

test('la propuesta lleva proveedor y concepto, y avisa que un pedido no es comprobante de pago', () => {
  const { propuesta, avisos } = propuestaDeGasto(normalizarGasto(PEDIDO))
  assert.equal(propuesta.categoria, 'pago_proveedor')
  assert.equal(propuesta.monto, 4734.08)
  assert.equal(propuesta.concepto, 'EXEL SOLAR — Cable fotovoltaico 10 AWG rojo y negro')
  assert.equal(propuesta.referencia, '1474048')
  assert.equal(avisos.length, 1)
  assert.match(avisos[0].texto, /^Es un pedido, no un comprobante de pago/)
})

test('lo que no se reconoce no inventa: categoría y fecha inválidas quedan vacías', () => {
  const l = normalizarGasto({ categoria: 'casino', fecha: '09/10/2026', documento: 'vale', total: 'abc' })
  assert.equal(l.categoria, '')
  assert.equal(l.fecha, '')
  assert.equal(l.documento, '')
  assert.equal(l.total, null)
  assert.equal(propuestaDeGasto(l).propuesta.categoria, 'otro')
  assert.equal(normalizarGasto('basura').proveedor, '')
})

test('sin total se dice por qué; en dólares se avisa', () => {
  const sinTotal = propuestaDeGasto(normalizarGasto({ notas: 'La imagen está borrosa.' }))
  assert.equal(sinTotal.avisos[0].texto, 'La IA no encontró el total: La imagen está borrosa. Captúralo a mano.')
  const usd = propuestaDeGasto(normalizarGasto({ total: 100, moneda: 'usd' }))
  assert.match(usd.avisos[0].texto, /dólares/)
  const ticket = propuestaDeGasto(normalizarGasto({ documento: 'ticket', establecimiento: 'Gasolinera', litros: 30, total: 700, categoria: 'gasolina' }))
  assert.equal(ticket.propuesta.concepto, 'Gasolinera')
  assert.equal(ticket.avisos.length, 0)
})
