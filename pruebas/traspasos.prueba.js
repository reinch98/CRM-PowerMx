// Clientes que el agente pasa a una persona (SQL 98): el número para los avisos, cómo se avisó y el orden.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { telefonoAvisosValido, comoSeAviso, ordenarTraspasos } from '../src/lib/whatsapp.js'

test('el número para los avisos: 10 dígitos, con o sin 52', () => {
  assert.equal(telefonoAvisosValido('999 123 4567'), true)
  assert.equal(telefonoAvisosValido('+52 1 999 123 4567'), true)
  assert.equal(telefonoAvisosValido('529991234567'), true)
  assert.equal(telefonoAvisosValido('12345'), false)
  assert.equal(telefonoAvisosValido(''), false)
})

test('cómo te llegó la tarjeta, en palabras', () => {
  assert.match(comoSeAviso('texto'), /tarjeta de contacto/)
  assert.match(comoSeAviso('plantilla'), /Meta la apruebe/)
  assert.match(comoSeAviso('sin_numero'), /escribe tu número/)
  assert.equal(comoSeAviso(null), '')
})

test('las urgentes primero y luego las que más llevan esperando', () => {
  const l = ordenarTraspasos([
    { id: 'a', urgente: false, created_at: '2026-11-16T10:00:00Z' },
    { id: 'b', urgente: true, created_at: '2026-11-16T12:00:00Z' },
    { id: 'c', urgente: false, created_at: '2026-11-16T09:00:00Z' },
  ])
  assert.deepEqual(l.map(x => x.id), ['b', 'c', 'a'])
})
