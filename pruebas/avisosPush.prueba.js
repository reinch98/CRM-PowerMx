// Avisos en el celular (SQL 90): cuándo se pueden activar y cómo se llama cada dispositivo.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { soporteAvisos, nombreDispositivo, claveABytes } from '../src/lib/avisosPush.js'

const android = 'Mozilla/5.0 (Linux; Android 14; SM-A546E) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36'
const iphone = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1'
const base = { sw: true, push: true, permiso: 'default', instalada: false }

test('Android con Chrome sí puede', () => {
  assert.equal(soporteAvisos({ ...base, ua: android }).puede, true)
})

test('iPhone solo desde el ícono de la pantalla de inicio', () => {
  const r = soporteAvisos({ ...base, ua: iphone })
  assert.equal(r.puede, false)
  assert.match(r.motivo, /pantalla de inicio/)
  assert.equal(soporteAvisos({ ...base, ua: iphone, instalada: true }).puede, true)
})

test('sin service worker, o con el permiso bloqueado, dice por qué', () => {
  assert.match(soporteAvisos({ ...base, ua: android, push: false }).motivo, /no puede recibir avisos/)
  assert.match(soporteAvisos({ ...base, ua: android, permiso: 'denied' }).motivo, /bloqueados/)
})

test('nombre del dispositivo', () => {
  assert.equal(nombreDispositivo(android), 'Chrome en Android')
  assert.equal(nombreDispositivo(iphone), 'Safari en iPhone')
  assert.equal(nombreDispositivo('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0 Safari/537.36 Edg/130.0'), 'Edge en Windows')
})

test('la llave pública pasa de base64url a bytes', () => {
  assert.deepEqual([...claveABytes('AQID_-8')], [1, 2, 3, 255, 239])
})
