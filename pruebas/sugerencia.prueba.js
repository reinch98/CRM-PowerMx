// La sugerencia del agente arriba de "Responder": cuándo se pide, cuándo se muestra y cuándo no.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { estadoSugerencia } from '../src/lib/whatsapp.js'

const entra = id => ({ id, direccion: 'entrante', estado: 'recibido' })
const sale = (id, estado = 'leido') => ({ id, direccion: 'saliente', estado, texto: `r${id}` })

test('el cliente escribió y nadie contestó: se pide', () => {
  assert.deepEqual(estadoSugerencia([sale(1), entra(2), entra(3)]), { pedir: true })
})

test('ya hay sugerencia después del último mensaje del cliente: se muestra la más nueva', () => {
  const r = estadoSugerencia([entra(1), sale(2, 'borrador'), sale(3, 'borrador')])
  assert.equal(r.borrador.id, 3)
})

test('ya se le contestó: no se muestra nada', () => {
  assert.equal(estadoSugerencia([entra(1), sale(2)]), null)
  assert.equal(estadoSugerencia([entra(1), sale(2, 'aprobado')]), null)
})

test('una sugerencia vieja no cuenta si el cliente volvió a escribir', () => {
  assert.deepEqual(estadoSugerencia([entra(1), sale(2, 'borrador'), entra(3)]), { pedir: true })
})

test('sin mensajes del cliente no hay nada que sugerir', () => {
  assert.equal(estadoSugerencia([]), null)
  assert.equal(estadoSugerencia([sale(1)]), null)
})
