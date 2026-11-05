// Mandar fotos y documentos desde la conversación de WhatsApp (SQL 96): qué se puede mandar
// tal cual, qué se convierte a JPG y qué se rechaza antes de gastar una subida.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { revisarArchivoWa, pesoLegible, MAX_FOTO_WA } from '../src/lib/whatsapp.js'

const archivo = (type, size, name = 'x') => ({ type, size, name })

test('una foto JPG o PNG chica sale tal cual', () => {
  assert.deepEqual(revisarArchivoWa(archivo('image/jpeg', 300000)), { ok: true, tipo: 'imagen', convertir: false })
  assert.deepEqual(revisarArchivoWa(archivo('image/png', 300000)), { ok: true, tipo: 'imagen', convertir: false })
})

test('una foto pesada o de iPhone (HEIC) se convierte a JPG', () => {
  assert.equal(revisarArchivoWa(archivo('image/jpeg', MAX_FOTO_WA + 1)).convertir, true)
  assert.equal(revisarArchivoWa(archivo('image/heic', 900000)).convertir, true)
  assert.equal(revisarArchivoWa(archivo('image/webp', 900000)).tipo, 'imagen')
})

test('PDF, Word y Excel van como documento; uno de más de 25 MB no', () => {
  assert.equal(revisarArchivoWa(archivo('application/pdf', 1000)).tipo, 'documento')
  assert.equal(revisarArchivoWa(archivo('application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 1000)).tipo, 'documento')
  assert.equal(revisarArchivoWa(archivo('application/pdf', 26 * 1024 * 1024)).ok, false)
})

test('un ZIP, un video o nada se rechaza con su motivo', () => {
  assert.match(revisarArchivoWa(archivo('application/zip', 1000)).texto, /no acepta/)
  assert.equal(revisarArchivoWa(archivo('video/mp4', 1000)).ok, false)
  assert.equal(revisarArchivoWa(null).ok, false)
})

test('peso en palabras', () => {
  assert.equal(pesoLegible(850 * 1024), '850 KB')
  assert.equal(pesoLegible(2.4 * 1024 * 1024), '2.4 MB')
  assert.equal(pesoLegible(10), '1 KB')
})
