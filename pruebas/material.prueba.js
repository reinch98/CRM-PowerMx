// Uso de material y devoluciones (SQL 18).
//
//   pendiente de devolución = entregada − usada − devuelta − diferencia
//
// Un error aquí sale en dinero: material que el sistema cree consumido y está en la
// camioneta, o al revés, una deuda que nadie le cobra al técnico.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  conMaterial, usoParaCierre, porDevolver, pendienteDeLinea, debeDevolver,
  aRecibir, quedaPendiente, nivelAntiguedad, haceCuanto,
} from '../src/lib/material.js'

const surtido = (producto_id, entregada, extra = {}) =>
  ({ producto_id, cantidad_entregada: entregada, ...extra })

test('conMaterial: solo se pregunta por lo que de verdad recibió', () => {
  const s = [surtido('a', 3), surtido('b', 0), surtido('c', null)]
  assert.deepEqual(conMaterial(s).map(l => l.producto_id), ['a'])
  assert.deepEqual(conMaterial(null), [])
})

test('usoParaCierre: sin capturar nada, se usó CERO', () => {
  // Lo seguro es devolver todo: si el técnico no dice qué usó, no se le da por consumido.
  assert.deepEqual(usoParaCierre([surtido('a', 3)], {}), [{ producto_id: 'a', usadas: 0 }])
  assert.deepEqual(usoParaCierre([surtido('a', 3)], null), [{ producto_id: 'a', usadas: 0 }])
})

test('usoParaCierre recorta a lo recibido: un dedazo no puede tronar el cierre', () => {
  // El cierre se hace en el sitio, a veces sin señal: no puede fallar por un 99.
  assert.deepEqual(usoParaCierre([surtido('a', 3)], { a: '99' }), [{ producto_id: 'a', usadas: 3 }])
  assert.deepEqual(usoParaCierre([surtido('a', 3)], { a: '-5' }), [{ producto_id: 'a', usadas: 0 }])
  assert.deepEqual(usoParaCierre([surtido('a', 3)], { a: 'abc' }), [{ producto_id: 'a', usadas: 0 }])
})

test('usoParaCierre: lo capturado bien pasa tal cual', () => {
  assert.deepEqual(usoParaCierre([surtido('a', 3)], { a: '2' }), [{ producto_id: 'a', usadas: 2 }])
  assert.deepEqual(usoParaCierre([surtido('a', 3)], { a: 3 }), [{ producto_id: 'a', usadas: 3 }])
})

test('porDevolver: lo que no usó queda como deuda con el almacén', () => {
  const s = [surtido('a', 3), surtido('b', 2)]
  const r = porDevolver(s, { a: '1', b: '2' })
  assert.deepEqual(r.map(l => [l.producto_id, l.aDevolver]), [['a', 2]])   // b se usó completo
})

test('porDevolver: si no capturó nada, debe devolver todo', () => {
  const r = porDevolver([surtido('a', 3)], {})
  assert.equal(r[0].aDevolver, 3)
})

test('pendienteDeLinea: la resta completa de la 18', () => {
  assert.equal(pendienteDeLinea(surtido('a', 10, { cantidad_usada: 4, cantidad_devuelta: 3, cantidad_diferencia: 1 })), 2)
  assert.equal(pendienteDeLinea(surtido('a', 10, { cantidad_usada: 10 })), 0)
  assert.equal(pendienteDeLinea(surtido('a', 10)), 10)
})

test('pendienteDeLinea nunca es negativo', () => {
  assert.equal(pendienteDeLinea(surtido('a', 2, { cantidad_usada: 5 })), 0)
})

test('debeDevolver filtra las órdenes ya saldadas', () => {
  const s = [
    surtido('a', 3, { cantidad_usada: 3 }),                        // saldada por uso
    surtido('b', 3, { cantidad_devuelta: 3 }),                     // saldada por devolución
    surtido('c', 3, { cantidad_diferencia: 3 }),                   // saldada por el admin
    surtido('d', 3, { cantidad_usada: 1 }),                        // debe 2
  ]
  assert.deepEqual(debeDevolver(s).map(l => l.producto_id), ['d'])
})

// ---- lado del almacén ----

const dev = (producto_id, pendiente) => ({ producto_id, pendiente })

test('aRecibir: por defecto se recibe todo lo pendiente', () => {
  assert.deepEqual(aRecibir([dev('a', 2), dev('b', 1)], {}), [
    { producto_id: 'a', cantidad: 2 },
    { producto_id: 'b', cantidad: 1 },
  ])
})

test('aRecibir: lo que ya no está pendiente no se ofrece', () => {
  assert.deepEqual(aRecibir([dev('a', 0), dev('b', -1)], {}), [])
})

test('aRecibir NO recorta a lo pendiente: que la base lo rechace y lo diga', () => {
  // Recortar en silencio esconde un error de conteo. La base contesta en español.
  assert.deepEqual(aRecibir([dev('a', 2)], { a: '5' }), [{ producto_id: 'a', cantidad: 5 }])
})

test('aRecibir ignora ceros, vacíos y basura', () => {
  for (const valor of ['0', '', 'abc', '-1']) {
    assert.deepEqual(aRecibir([dev('a', 2)], { a: valor }), [], `falló con ${JSON.stringify(valor)}`)
  }
})

test('quedaPendiente: recibir de menos exige observación', () => {
  const lineas = [dev('a', 3)]
  assert.equal(quedaPendiente(lineas, [{ producto_id: 'a', cantidad: 3 }]), false)
  assert.equal(quedaPendiente(lineas, [{ producto_id: 'a', cantidad: 2 }]), true)
  assert.equal(quedaPendiente(lineas, []), true)              // no se recibió nada
  assert.equal(quedaPendiente(lineas, null), true)
})

test('quedaPendiente: basta que UNA pieza quede corta', () => {
  const lineas = [dev('a', 1), dev('b', 4)]
  const recibir = [{ producto_id: 'a', cantidad: 1 }, { producto_id: 'b', cantidad: 3 }]
  assert.equal(quedaPendiente(lineas, recibir), true)
})

test('nivelAntiguedad: los tramos que decidió Caña, en palabras', () => {
  assert.equal(nivelAntiguedad(0), 'Reciente')
  assert.equal(nivelAntiguedad(1), 'Reciente')
  assert.equal(nivelAntiguedad(2), 'Por vencer')
  assert.equal(nivelAntiguedad(4), 'Por vencer')
  assert.equal(nivelAntiguedad(5), 'Atrasada')
  assert.equal(nivelAntiguedad(30), 'Atrasada')
  assert.equal(nivelAntiguedad(null), 'Reciente')
})

test('haceCuanto: singular y plural', () => {
  assert.equal(haceCuanto(0), 'hoy')
  assert.equal(haceCuanto(-1), 'hoy')
  assert.equal(haceCuanto(1), 'hace 1 día')
  assert.equal(haceCuanto(2), 'hace 2 días')
})
