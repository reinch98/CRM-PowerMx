// La cola sin señal. Lo que esto protege: el trabajo que un técnico capturó bajo el sol
// en una obra sin datos. Un fallo aquí no se ve en pantalla, se ve cuando la orden llega
// vacía a la oficina.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  claveDe, encolarEn, ordenarCola, sacarSiSigue, marcarFallo, pendienteDe, cierrePendiente,
} from '../src/lib/cola.js'

const item = (tipo, orden_id, payload = {}) => ({ clave: claveDe(tipo, orden_id), tipo, orden_id, payload })

test('claveDe identifica el asunto, no el intento', () => {
  assert.equal(claveDe('parte', 7), 'parte:7')
  assert.equal(claveDe('cierre', 7), 'cierre:7')
  assert.notEqual(claveDe('parte', 7), claveDe('parte', 8))
})

test('encolar el mismo asunto REEMPLAZA, no apila', () => {
  // El técnico escribe, se guarda solo en cada cambio: sin esto la cola crecería sin fin
  // y subiría veinte versiones de las mismas notas.
  let cola = []
  cola = encolarEn(cola, item('parte', 7, { notas: 'a' }))
  cola = encolarEn(cola, item('parte', 7, { notas: 'ab' }))
  cola = encolarEn(cola, item('parte', 7, { notas: 'abc' }))
  assert.equal(cola.length, 1)
  assert.equal(cola[0].payload.notas, 'abc')   // queda lo último escrito
})

test('el contador n sube en cada reemplazo', () => {
  let cola = encolarEn([], item('parte', 7))
  assert.equal(cola[0].n, 1)
  cola = encolarEn(cola, item('parte', 7))
  assert.equal(cola[0].n, 2)
})

test('asuntos distintos conviven en la cola', () => {
  let cola = encolarEn([], item('parte', 7))
  cola = encolarEn(cola, item('cierre', 7))
  cola = encolarEn(cola, item('parte', 8))
  assert.equal(cola.length, 3)
})

test('sacarSiSigue no tira lo que el técnico escribió mientras subía', () => {
  // El caso real: la parte se está subiendo, el técnico agrega una foto (n pasa a 2) y
  // justo entonces termina la subida del intento 1. Si se quitara por clave, la foto se
  // perdería sin que nadie se enterara.
  let cola = encolarEn([], item('parte', 7, { notas: 'a' }))
  const n = cola[0].n
  cola = encolarEn(cola, item('parte', 7, { notas: 'a + foto' }))
  cola = sacarSiSigue(cola, 'parte:7', n)
  assert.equal(cola.length, 1)
  assert.equal(cola[0].payload.notas, 'a + foto')
})

test('sacarSiSigue quita el elemento cuando nadie lo tocó', () => {
  const cola = encolarEn([], item('parte', 7))
  assert.deepEqual(sacarSiSigue(cola, 'parte:7', cola[0].n), [])
})

test('el cierre va después de la parte y de la revisión', () => {
  // La base no deja cerrar si la seguridad quedó sin resolver (trigger de la 24), y el
  // cierre junta las notas: si subiera primero, lo rechazarían o cerraría sin trabajo.
  const cola = [item('cierre', 7), item('revision', 7), item('parte', 7)]
  assert.deepEqual(ordenarCola(cola).map(i => i.tipo), ['parte', 'revision', 'cierre'])
})

test('ordenarCola respeta el orden de llegada dentro del mismo tipo', () => {
  const cola = [item('parte', 7), item('parte', 8), item('parte', 9)]
  assert.deepEqual(ordenarCola(cola).map(i => i.orden_id), [7, 8, 9])
})

test('ordenarCola no muta la cola que recibe', () => {
  const cola = [item('cierre', 7), item('parte', 7)]
  const copia = [...cola]
  ordenarCola(cola)
  assert.deepEqual(cola, copia)
})

test('un tipo desconocido no se cuela adelante del cierre', () => {
  const cola = ordenarCola([item('cierre', 7), item('loQueSea', 7)])
  assert.equal(cola[cola.length - 1].tipo, 'cierre')
})

test('marcarFallo anota el motivo en español y cuenta los intentos', () => {
  let cola = encolarEn([], item('parte', 7))
  cola = marcarFallo(cola, 'parte:7', 1, 'No hay señal', true)
  assert.equal(cola[0].sync.error, 'No hay señal')
  assert.equal(cola[0].sync.temporal, true)
  assert.equal(cola[0].sync.intentos, 1)
  cola = marcarFallo(cola, 'parte:7', 1, 'No hay señal', true)
  assert.equal(cola[0].sync.intentos, 2)   // se acumulan, no se reinician
})

test('marcarFallo no ensucia un intento que ya quedó viejo', () => {
  let cola = encolarEn([], item('parte', 7))
  cola = encolarEn(cola, item('parte', 7))          // n = 2
  cola = marcarFallo(cola, 'parte:7', 1, 'Falló', false)   // llega el fallo del n = 1
  assert.equal(cola[0].sync, undefined)
})

test('pendienteDe separa lo de cada orden', () => {
  let cola = encolarEn([], item('parte', 7))
  cola = encolarEn(cola, item('cierre', 7))
  cola = encolarEn(cola, item('parte', 8))
  assert.equal(pendienteDe(cola, 7).length, 2)
  assert.equal(pendienteDe(cola, 8).length, 1)
  assert.equal(pendienteDe(cola, 99).length, 0)
})

test('cierrePendiente: con un cierre en camino la orden ya no se edita', () => {
  const soloParte = encolarEn([], item('parte', 7))
  assert.equal(cierrePendiente(soloParte, 7), false)
  const conCierre = encolarEn(soloParte, item('cierre', 7))
  assert.equal(cierrePendiente(conCierre, 7), true)
  assert.equal(cierrePendiente(conCierre, 8), false)   // la de al lado sigue editable
})
