// Supabase corta las consultas a 1,000 filas sin avisar; `todasLasFilas` las pide por páginas.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { todasLasFilas } from '../src/lib/paginar.js'

// Una consulta falsa con `.range(desde, hasta)` como la de supabase-js. Como el servidor real,
// nunca entrega más de `tope` filas por respuesta.
function tabla(n, { tope = 1000, falla = null } = {}) {
  const todas = Array.from({ length: n }, (_, i) => ({ id: i }))
  const llamadas = []
  const armar = () => ({
    range: async (desde, hasta) => {
      llamadas.push([desde, hasta])
      if (falla !== null && llamadas.length === falla) return { data: null, error: { message: 'se cayó' } }
      return { data: todas.slice(desde, Math.min(hasta + 1, desde + tope)), error: null }
    },
  })
  return { armar, llamadas }
}

test('trae todo aunque pase de mil filas y no repite ni se salta ninguna', async () => {
  const { armar, llamadas } = tabla(2503)
  const r = await todasLasFilas(armar)
  assert.equal(r.error, null)
  assert.equal(r.data.length, 2503)
  assert.deepEqual(r.data.map(f => f.id), Array.from({ length: 2503 }, (_, i) => i))
  assert.deepEqual(llamadas, [[0, 999], [1000, 1999], [2000, 2999]])
})

test('una tabla chica se pide una sola vez', async () => {
  const { armar, llamadas } = tabla(95)
  const r = await todasLasFilas(armar)
  assert.equal(r.data.length, 95)
  assert.equal(llamadas.length, 1)
})

test('una tabla vacía y una de exactamente una página no se quedan en un ciclo', async () => {
  assert.deepEqual((await todasLasFilas(tabla(0).armar)).data, [])
  const justa = tabla(1000)
  assert.equal((await todasLasFilas(justa.armar)).data.length, 1000)
  assert.equal(justa.llamadas.length, 2)   // la segunda llega vacía y confirma que ya no hay más
})

test('si una página falla devuelve el error y NO un resultado a medias', async () => {
  const { armar } = tabla(2500, { falla: 2 })
  const r = await todasLasFilas(armar)
  assert.equal(r.data, null)
  assert.equal(r.error.message, 'se cayó')
})

test('respeta un tamaño de página menor (el servidor puede tener otro tope)', async () => {
  const { armar, llamadas } = tabla(25, { tope: 10 })
  const r = await todasLasFilas(armar, 10)
  assert.equal(r.data.length, 25)
  assert.deepEqual(llamadas, [[0, 9], [10, 19], [20, 29]])
})
