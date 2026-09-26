// Reglas del almacén (SQL 14). Esto toca INVENTARIO: proponer entregar más de lo que hay
// en el estante deja al técnico esperando en la bodega.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { pendiente, sugerido, estadoLinea, lineasParaEntrega } from '../src/lib/almacen.js'

// Una línea de `orden_surtido`: pedida por la cotización, ya entregada, esperando firma, y
// lo que hay físicamente en el estante.
const linea = (pedida, entregada, en_entrega, fisico) =>
  ({ producto_id: 'p1', pedida, entregada, en_entrega, fisico })

test('pendiente descuenta lo entregado Y lo que espera firma', () => {
  // Sin descontar `en_entrega` se prepararía dos veces la misma pieza: el inventario no se
  // mueve hasta que T1 firma, así que la entrega sin firmar es invisible en `fisico`.
  assert.equal(pendiente(linea(5, 0, 0, 10)), 5)
  assert.equal(pendiente(linea(5, 2, 0, 10)), 3)
  assert.equal(pendiente(linea(5, 2, 3, 10)), 0)
})

test('pendiente nunca es negativo', () => {
  assert.equal(pendiente(linea(5, 9, 0, 10)), 0)
  assert.equal(pendiente(linea(5, 3, 4, 10)), 0)
})

test('pendiente aguanta en_entrega sin capturar', () => {
  assert.equal(pendiente({ producto_id: 'p1', pedida: 5, entregada: 1 }), 4)
})

test('sugerido no promete más de lo que hay en el estante', () => {
  assert.equal(sugerido(linea(5, 0, 0, 10)), 5)   // alcanza: propone lo pendiente
  assert.equal(sugerido(linea(5, 0, 0, 2)), 2)    // no alcanza: propone lo que hay
  assert.equal(sugerido(linea(5, 0, 0, 0)), 0)
})

test('sugerido con existencia negativa propone cero, no un número raro', () => {
  // El físico sale de movimientos: un ajuste mal capturado puede dejarlo negativo.
  assert.equal(sugerido(linea(5, 0, 0, -3)), 0)
  assert.equal(sugerido({ producto_id: 'p1', pedida: 5, entregada: 0, fisico: null }), 0)
})

test('estadoLinea: siempre una palabra, nunca solo color', () => {
  assert.equal(estadoLinea(linea(5, 5, 0, 10)), 'Completo')
  assert.equal(estadoLinea(linea(5, 9, 0, 10)), 'Completo')      // de más también está completo
  assert.equal(estadoLinea(linea(5, 2, 3, 10)), 'Por firmar')
  assert.equal(estadoLinea(linea(5, 0, 5, 10)), 'Por firmar')
  assert.equal(estadoLinea(linea(5, 2, 0, 10)), 'Parcial')
  assert.equal(estadoLinea(linea(5, 0, 0, 10)), 'Sin entregar')
})

test('estadoLinea: "Sin existencia" avisa antes de que el técnico llegue por ella', () => {
  assert.equal(estadoLinea(linea(5, 0, 0, 0)), 'Sin existencia')
  assert.equal(estadoLinea(linea(5, 2, 0, 0)), 'Sin existencia')
  assert.equal(estadoLinea(linea(5, 0, 0, -1)), 'Sin existencia')
})

test('estadoLinea: completo gana aunque no haya existencia', () => {
  // Ya se entregó todo: que el estante esté vacío da igual.
  assert.equal(estadoLinea(linea(5, 5, 0, 0)), 'Completo')
})

test('lineasParaEntrega: sin capturar nada, se propone lo sugerido', () => {
  const lineas = [linea(5, 0, 0, 3)]
  assert.deepEqual(lineasParaEntrega(lineas, {}), [{ producto_id: 'p1', cantidad: 3 }])
})

test('lineasParaEntrega: lo capturado manda, incluso por encima del estante', () => {
  // No se recorta aquí a propósito: si el almacenista pide de más, la base lo rechaza y
  // dice cuánto queda. Recortar en silencio esconde el error.
  const lineas = [linea(5, 0, 0, 3)]
  assert.deepEqual(lineasParaEntrega(lineas, { p1: '5' }), [{ producto_id: 'p1', cantidad: 5 }])
})

test('lineasParaEntrega: los ceros, vacíos y la basura no viajan a la base', () => {
  const lineas = [linea(5, 0, 0, 3)]
  for (const valor of ['0', '', 'abc', '-2', null]) {
    assert.deepEqual(lineasParaEntrega(lineas, { p1: valor }), [], `falló con ${JSON.stringify(valor)}`)
  }
})

test('lineasParaEntrega: cada pieza va por su cuenta', () => {
  const lineas = [
    { producto_id: 'a', pedida: 2, entregada: 0, en_entrega: 0, fisico: 9 },
    { producto_id: 'b', pedida: 4, entregada: 0, en_entrega: 0, fisico: 1 },
    { producto_id: 'c', pedida: 1, entregada: 1, en_entrega: 0, fisico: 9 },  // ya completa
  ]
  assert.deepEqual(lineasParaEntrega(lineas, {}), [
    { producto_id: 'a', cantidad: 2 },
    { producto_id: 'b', cantidad: 1 },
  ])
})
