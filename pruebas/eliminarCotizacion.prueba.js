import { test } from 'node:test'
import assert from 'node:assert/strict'
import { renglonesDelResumen, leerRespuesta } from '../src/lib/eliminarCotizacion.js'

test('el resumen nombra lo que se borra y calla lo que es cero', () => {
  const l = renglonesDelResumen({
    folio: 12, estado: 'borrador', citas: 1, ordenes: 1, ordenes_folios: 'OS-11',
    movimientos_apartado: 0, pedidos: 0, entregas_sin_firmar: 0, solicitudes_material: 0
  })
  assert.equal(l.length, 3)
  assert.match(l[0], /cotización 12 \(borrador\)/)
  assert.equal(l[1], '1 cita')
  assert.match(l[2], /1 orden de servicio \(OS-11\)/)
})

test('los plurales se dicen bien', () => {
  const l = renglonesDelResumen({ folio: 1, estado: 'borrador', citas: 2, ordenes: 2, movimientos_apartado: 4, pedidos: 3 })
  assert.ok(l.includes('2 citas'))
  assert.ok(l.some(x => x.startsWith('2 órdenes de servicio')))
  assert.ok(l.some(x => x.startsWith('4 movimientos de apartado')))
  assert.ok(l.includes('3 pedidos pendientes a proveedor'))
})

test('sin resumen no truena', () => {
  assert.deepEqual(renglonesDelResumen(null), [])
})

test('una respuesta rara de la base se lee como "no ejecutado, sin permiso para seguir"', () => {
  for (const mala of [null, undefined, 'x', 5, {}]) {
    const r = leerRespuesta(mala)
    assert.equal(r.ok, false)
    assert.equal(r.ejecutado, false)
    assert.deepEqual(r.bloqueos, [])
  }
})

test('los bloqueos llegan como lista', () => {
  const r = leerRespuesta({ ok: false, bloqueos: ['a', 'b'], resumen: { folio: 3 } })
  assert.deepEqual(r.bloqueos, ['a', 'b'])
  assert.equal(r.resumen.folio, 3)
})
