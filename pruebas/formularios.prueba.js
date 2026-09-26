// Pasar un registro de la base a un formulario y de vuelta (edición de clientes y equipos).
//
// Dos reglas que se olvidan fácil: React se queja de un `<input value={null}>`, y Postgres
// no acepta `''` en columnas numéricas ni de fecha. Entre las dos, un campo vacío puede
// tronar el guardado o guardar un dato falso.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { aFormulario, paraGuardar } from '../src/lib/formularios.js'

const VACIO = { nombre: '', telefono: '', distancia_km: '', proximo: '', activo: false }

test('aFormulario convierte null en cadena vacía', () => {
  // Un `<input value={null}>` pasa a no controlado y React avisa en consola.
  const r = aFormulario({ nombre: 'Hotel X', telefono: null, distancia_km: null }, VACIO)
  assert.equal(r.telefono, '')
  assert.equal(r.distancia_km, '')
})

test('aFormulario toma SOLO las claves que el formulario conoce', () => {
  // Si `id` o `created_at` viajaran de vuelta en el update, se estaría reescribiendo la
  // llave y la fecha de creación del registro.
  const r = aFormulario({ id: 'abc', created_at: '2026-01-01', nombre: 'Hotel X' }, VACIO)
  assert.deepEqual(Object.keys(r).sort(), Object.keys(VACIO).sort())
  assert.equal(r.id, undefined)
  assert.equal(r.created_at, undefined)
})

test('aFormulario pasa los números a texto, que es lo que lee un input', () => {
  const r = aFormulario({ distancia_km: 45.5 }, VACIO)
  assert.equal(r.distancia_km, '45.5')
  assert.equal(typeof r.distancia_km, 'string')
})

test('aFormulario deja los booleanos como booleanos', () => {
  // Una casilla necesita true/false; "false" en texto sería siempre verdadero.
  assert.equal(aFormulario({ activo: true }, VACIO).activo, true)
  assert.equal(aFormulario({ activo: false }, VACIO).activo, false)
})

test('aFormulario: un cero se conserva, no se confunde con vacío', () => {
  assert.equal(aFormulario({ distancia_km: 0 }, VACIO).distancia_km, '0')
})

test('aFormulario sin registro devuelve el formulario vacío (es el alta)', () => {
  assert.deepEqual(aFormulario(null, VACIO), VACIO)
  assert.deepEqual(aFormulario(undefined, VACIO), VACIO)
})

test('aFormulario no muta el objeto vacío que recibe', () => {
  const vacio = { ...VACIO }
  aFormulario({ nombre: 'X' }, vacio)
  assert.deepEqual(vacio, VACIO)
})

// ---- de vuelta a la base ----

test('paraGuardar manda null donde Postgres no acepta cadena vacía', () => {
  const r = paraGuardar({ nombre: 'Hotel X', distancia_km: '', proximo: '' }, { numericas: ['distancia_km'], fechas: ['proximo'] })
  assert.equal(r.distancia_km, null)
  assert.equal(r.proximo, null)
  assert.equal(r.nombre, 'Hotel X')   // el texto sí puede ir vacío
})

test('paraGuardar convierte a número lo que es numérico', () => {
  const r = paraGuardar({ distancia_km: '45.5' }, { numericas: ['distancia_km'] })
  assert.equal(r.distancia_km, 45.5)
  assert.equal(typeof r.distancia_km, 'number')
})

test('paraGuardar: el cero es un cero, no un null', () => {
  // Un cliente a 0 km existe; convertirlo en null perdería el dato.
  const r = paraGuardar({ distancia_km: '0' }, { numericas: ['distancia_km'] })
  assert.equal(r.distancia_km, 0)
})

test('paraGuardar no toca lo que no se le declaró', () => {
  const r = paraGuardar({ nombre: '', otro: '' }, { numericas: [] })
  assert.equal(r.nombre, '')
  assert.equal(r.otro, '')
})

test('paraGuardar sin opciones devuelve una copia igual', () => {
  const form = { nombre: 'X', distancia_km: '' }
  assert.deepEqual(paraGuardar(form), form)
})

test('paraGuardar no muta el formulario en pantalla', () => {
  const form = { distancia_km: '' }
  paraGuardar(form, { numericas: ['distancia_km'] })
  assert.equal(form.distancia_km, '')
})

test('ida y vuelta: lo que sale de la base vuelve igual', () => {
  const registro = { nombre: 'Hotel X', telefono: '9991234567', distancia_km: 45, proximo: null, activo: true }
  const form = aFormulario(registro, VACIO)
  const guardar = paraGuardar(form, { numericas: ['distancia_km'], fechas: ['proximo'] })
  assert.deepEqual(guardar, { nombre: 'Hotel X', telefono: '9991234567', distancia_km: 45, proximo: null, activo: true })
})
