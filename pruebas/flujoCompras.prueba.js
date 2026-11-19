// Pedido → nota → factura (FlujoCompras). Junta lo que la base ya liga: compra_lineas.requisicion_id
// y cfdi.compra_id. Si se arma mal, un pedido aparece dos veces o una compra facturada sale pendiente.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { armarFlujo, contarEtapas, pasosDe } from '../src/lib/flujoCompras.js'

const req = (id, folio, estado, extra = {}) =>
  ({ id, folio, estado, cantidad: 1, sku: 'GON-GP58', fecha_pedido: '2026-11-12', ...extra })

const base = () => ({
  requisiciones: [
    req('r1', 50, 'recibida', { cotizacion: 74, cliente: 'Cliente A' }),
    req('r2', 51, 'recibida'),
    req('r3', 60, 'pendiente', { fecha_pedido: '2026-11-18' }),
    req('r4', 61, 'cancelada'),
  ],
  compras: [
    { id: 'c1', folio: 51, fecha: '2026-11-11', proveedor: 'RAG', factura: 'K109125', total: 147, estado: 'registrada' },
    { id: 'c2', folio: 53, fecha: '2026-11-13', proveedor: 'AutoZone', factura: null, total: 457, estado: 'registrada' },
    { id: 'c3', folio: 40, fecha: '2026-11-01', proveedor: 'X', estado: 'cancelada' },
  ],
  lineas: [
    { compra_id: 'c1', requisicion_id: 'r1', cantidad: 1, sku: 'GON-GP58' },
    { compra_id: 'c1', requisicion_id: 'r2', cantidad: 1, sku: 'GON-GP58' },
    { compra_id: 'c1', requisicion_id: null, cantidad: 1, sku: 'GON-GP58' },
    { compra_id: 'c2', requisicion_id: null, cantidad: 2, sku: 'STP-SL4967XL' },
  ],
  facturas: [{ id: 'f1', compra_id: 'c1', serie: 'K', folio: '109125' }],
})

test('una tarjeta por compra viva y otra por cada pedido que espera su nota', () => {
  const f = armarFlujo(base())
  assert.deepEqual(f.map(x => x.clave), ['req-r3', 'compra-c2', 'compra-c1'])
})

test('los pedidos recibidos van dentro de su compra y no se repiten sueltos', () => {
  const c1 = armarFlujo(base()).find(x => x.clave === 'compra-c1')
  assert.deepEqual(c1.pedidos.map(p => p.folio), [50, 51])
  assert.equal(c1.compra.lineas.length, 3)
})

test('la etapa sale de lo que falta', () => {
  const porClave = Object.fromEntries(armarFlujo(base()).map(x => [x.clave, x.etapa]))
  assert.deepEqual(porClave, { 'compra-c1': 'completo', 'compra-c2': 'factura', 'req-r3': 'nota' })
  assert.deepEqual(contarEtapas(armarFlujo(base())), { todos: 3, nota: 1, factura: 1, completo: 1 })
})

test('los pasos lo dicen con palabra', () => {
  const f = armarFlujo(base())
  const [p1, n1, f1] = pasosDe(f.find(x => x.clave === 'compra-c1'))
  assert.equal(p1.titulo, 'REQ-50, REQ-51')
  assert.equal(n1.titulo, 'COMPRA-51')
  assert.equal(f1.titulo, 'Factura K109125')
  assert.ok(f1.hecho)

  const [p2, , f2] = pasosDe(f.find(x => x.clave === 'compra-c2'))
  assert.equal(p2.titulo, 'Sin pedido')
  assert.equal(f2.hecho, false)
  assert.match(f2.nota, /Sin factura/)

  const [, n3] = pasosDe(f.find(x => x.clave === 'req-r3'))
  assert.equal(n3.hecho, false)
  assert.equal(n3.titulo, 'Esperando la nota')
})

test('una compra con folio de factura pero sin XML dice cuál subir', () => {
  const datos = base()
  datos.facturas = []
  const c1 = armarFlujo(datos).find(x => x.clave === 'compra-c1')
  assert.equal(c1.etapa, 'factura')
  assert.match(pasosDe(c1)[2].nota, /K109125/)
})

test('sin datos no truena', () => {
  assert.deepEqual(armarFlujo(), [])
  assert.deepEqual(contarEtapas([]), { todos: 0, nota: 0, factura: 0, completo: 0 })
})
