// Precio con el que un producto entra a una cotización. Toca DINERO: una cotización de un generador de
// $26,000 con IVA incluido tiene que terminar en $26,000, no en $30,160.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { precioParaCotizar, textoPrecioLista, IVA } from '../src/lib/precioLista.js'

const total = (precioUnitario) => precioUnitario * (1 + IVA)

test('un generador en pesos: la cotización termina en el precio de lista (IVA incluido)', () => {
  const r = precioParaCotizar({ sku: 'GAS-CX8000', precio: 26000, moneda: 'MXN', categoria: 'generador' })
  assert.equal(Math.round(total(r.precio) * 100) / 100, 26000)
  assert.match(r.nota, /IVA incluido/)
})

test('un generador en dólares: se convierte y también termina en lista × tipo de cambio', () => {
  const r = precioParaCotizar({ sku: 'AIR-10KW', precio: 6500, moneda: 'USD', categoria: 'generador' }, 18.5)
  assert.equal(Math.round(total(r.precio) * 100) / 100, 6500 * 18.5)
  assert.match(r.nota, /USD 6,500 × TC 18.5/)
  assert.match(r.nota, /IVA incluido/)
})

test('lo que NO es generador sigue siendo precio más IVA: no se divide', () => {
  const r = precioParaCotizar({ sku: 'REF-1', precio: 350, moneda: 'MXN', categoria: 'refaccion' })
  assert.equal(r.precio, 350)
  assert.equal(r.nota, '')
})

test('un producto no generador en dólares solo se convierte, sin quitarle IVA', () => {
  const r = precioParaCotizar({ sku: 'P', precio: 100, moneda: 'USD', categoria: 'panel' }, 18.5)
  assert.equal(r.precio, 1850)
  assert.doesNotMatch(r.nota, /IVA/)
})

test('en dólares y sin tipo de cambio no inventa un precio', () => {
  for (const tc of [null, undefined, 0, 'x']) {
    const r = precioParaCotizar({ sku: 'AIR-10KW', precio: 6500, moneda: 'USD', categoria: 'generador' }, tc)
    assert.ok(r.error)
    assert.equal(r.precio, undefined)
  }
})

test('sin precio capturado no entra', () => {
  assert.ok(precioParaCotizar({ sku: 'X', precio: null, moneda: 'MXN', categoria: 'generador' }).error)
})

test('el texto del buscador dice la moneda y el IVA', () => {
  const pesos = (v) => `$${v}`
  assert.equal(textoPrecioLista({ precio: 26000, moneda: 'MXN', categoria: 'generador' }, 18.5, pesos), '$26000 con IVA incluido')
  assert.match(textoPrecioLista({ precio: 6500, moneda: 'USD', categoria: 'generador' }, 18.5, pesos), /^USD 6,500 con IVA incluido \(en pesos al TC 18.5\)$/)
  assert.equal(textoPrecioLista({ precio: 350, moneda: 'MXN', categoria: 'refaccion' }, 18.5, pesos), '$350')
  assert.equal(textoPrecioLista({ precio: null, moneda: 'MXN', categoria: 'refaccion' }, 18.5, pesos), 'sin precio')
})
