// El inicio del admin (SQL 42). Los textos los arma la base; aquí se prueba la presentación:
// que el nivel se diga con palabra, que no se dibujen grupos vacíos y que una cita se lea
// completa aunque le falten datos.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { NIVELES, etiquetaNivel, porNivel, cuantasEsperan, textoCita, hayDia } from '../src/lib/inicio.js'

const aviso = (clave, nivel, n) => ({ clave, nivel, n, texto: `${n} cosas`, pantalla: 'agenda' })

test('el nivel se dice con palabra, nunca solo con color', () => {
  assert.equal(etiquetaNivel('alto'), 'Atender hoy')
  assert.equal(etiquetaNivel('medio'), 'Esta semana')
  assert.equal(etiquetaNivel('bajo'), 'Cuando se pueda')
  assert.equal(Object.keys(NIVELES).length, 3)
})

test('un nivel desconocido no deja el encabezado en blanco', () => {
  assert.equal(etiquetaNivel('loQueSea'), 'Pendiente')
  assert.equal(etiquetaNivel(undefined), 'Pendiente')
})

test('porNivel agrupa en el orden alto → medio → bajo', () => {
  const g = porNivel([aviso('a', 'bajo', 1), aviso('b', 'alto', 2), aviso('c', 'medio', 3)])
  assert.deepEqual(g.map(x => x.nivel), ['alto', 'medio', 'bajo'])
})

test('porNivel no dibuja grupos vacíos', () => {
  const g = porNivel([aviso('a', 'alto', 1)])
  assert.equal(g.length, 1)
  assert.equal(g[0].etiqueta, 'Atender hoy')
  assert.deepEqual(porNivel([]), [])
  assert.deepEqual(porNivel(null), [])
})

test('porNivel respeta el orden que mandó la base dentro de cada nivel', () => {
  // La base ya los ordena por cantidad; la pantalla no los vuelve a acomodar.
  const g = porNivel([aviso('primero', 'alto', 9), aviso('segundo', 'alto', 2)])
  assert.deepEqual(g[0].items.map(i => i.clave), ['primero', 'segundo'])
})

test('cuantasEsperan suma las cosas, no los renglones', () => {
  // Dos avisos de 3 y 4 son SIETE cosas esperando, no dos.
  assert.equal(cuantasEsperan([aviso('a', 'alto', 3), aviso('b', 'medio', 4)]), 7)
  assert.equal(cuantasEsperan([]), 0)
  assert.equal(cuantasEsperan(null), 0)
})

test('cuantasEsperan aguanta un número que viene como texto', () => {
  assert.equal(cuantasEsperan([{ n: '3' }, { n: '4' }]), 7)
  assert.equal(cuantasEsperan([{ n: null }]), 0)
})

test('textoCita se lee completa: hora, cliente y quién va', () => {
  assert.equal(textoCita({ hora: '09:30', cliente: 'Hotel X', tecnico: 'Luis' }),
               '09:30 · Hotel X · Luis')
})

test('textoCita: sin técnico lo DICE, no lo calla', () => {
  // Una cita sin técnico asignado es justo lo que hay que notar al ver el día.
  assert.match(textoCita({ hora: '09:30', cliente: 'Hotel X' }), /sin técnico asignado/)
})

test('textoCita: sin hora tampoco se queda en blanco', () => {
  assert.match(textoCita({ cliente: 'Hotel X', tecnico: 'Luis' }), /^sin hora · Hotel X/)
  assert.match(textoCita({}), /sin hora/)
})

test('hayDia distingue un día libre de un error', () => {
  assert.equal(hayDia([{ cita_id: 1 }]), true)
  assert.equal(hayDia([]), false)
  assert.equal(hayDia(null), false)
})
