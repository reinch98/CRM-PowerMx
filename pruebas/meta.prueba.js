// Catálogo de Meta (SQL 88): el aviso de por qué un producto marcado no saldría, y las tandas
// del update (cientos de ids en una sola dirección se pasan del largo permitido).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { avisoMeta, enTandas, productosTexto } from '../src/lib/meta.js'

const base = { activo: true, publicar: true, categoria: 'panel', precio: 3500, moneda: 'MXN' }

test('un producto publicado, en pesos y con precio sí sale', () => {
  assert.equal(avisoMeta(base), null)
})

test('lo que Meta no acepta se dice en palabras', () => {
  assert.match(avisoMeta({ ...base, precio: null }), /Sin precio/)
  assert.match(avisoMeta({ ...base, precio: 0 }), /Sin precio/)
  assert.match(avisoMeta({ ...base, moneda: 'USD' }), /dólares/)
  assert.match(avisoMeta({ ...base, publicar: false }), /No está publicado/)
  assert.match(avisoMeta({ ...base, categoria: 'renta' }), /Rentas/)
  assert.match(avisoMeta({ ...base, categoria: 'paquete_solar' }), /paquetes/)
})

test('enTandas parte la lista sin perder ni repetir', () => {
  const ids = Array.from({ length: 250 }, (_, i) => i)
  const t = enTandas(ids)
  assert.deepEqual(t.map(x => x.length), [100, 100, 50])
  assert.deepEqual(t.flat(), ids)
  assert.deepEqual(enTandas([]), [])
})

test('productosTexto en singular y plural', () => {
  assert.equal(productosTexto(1), '1 producto')
  assert.equal(productosTexto(0), '0 productos')
})
