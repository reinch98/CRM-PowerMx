// Compras (SQL 41). Toca DINERO y toca INVENTARIO: el total que ve el admin antes de guardar
// tiene que ser el mismo que calcula la base, o nadie se entera hasta cuadrar con el proveedor.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  IVA, importeLinea, totalesDeCompra, problemasDeCompra, cambioDeCosto,
  lineasParaGuardar, lineaDesdePedido, lineaNueva,
} from '../src/lib/compras.js'

const linea = (cantidad, costo, extra = {}) =>
  ({ producto_id: 'p1', cantidad, costo_unitario: costo, ...extra })

test('importeLinea redondea a centavos', () => {
  assert.equal(importeLinea(linea(3, 1.115)), 3.35)
  assert.equal(importeLinea(linea(10, 310)), 3100)
  assert.equal(importeLinea(linea('4', '310')), 1240)
  assert.equal(importeLinea({}), 0)
})

test('totalesDeCompra da los MISMOS números que el SQL 41', () => {
  // Es el caso exacto de `41_prueba_compras.sql`: 10×310 + 4×310 + 3×300.
  // Si estos dos se separaran, la pantalla prometería un total y la base guardaría otro.
  const lineas = [linea(10, 310), linea(4, 310), linea(3, 300)]
  assert.deepEqual(totalesDeCompra(lineas), { subtotal: 5240, iva: 838.40, total: 6078.40 })
})

test('totalesDeCompra: el IVA capturado a mano gana', () => {
  // Una factura con IVA exento, o con retenciones, no es el 16% del subtotal.
  const lineas = [linea(10, 100)]
  assert.deepEqual(totalesDeCompra(lineas, 0), { subtotal: 1000, iva: 0, total: 1000 })
  assert.deepEqual(totalesDeCompra(lineas, 75.5), { subtotal: 1000, iva: 75.5, total: 1075.5 })
})

test('totalesDeCompra: vacío no es NaN', () => {
  assert.deepEqual(totalesDeCompra([]), { subtotal: 0, iva: 0, total: 0 })
  assert.deepEqual(totalesDeCompra(null), { subtotal: 0, iva: 0, total: 0 })
  assert.deepEqual(totalesDeCompra([linea(1, 'abc')]), { subtotal: 0, iva: 0, total: 0 })
})

test('IVA es el 16%', () => {
  assert.equal(IVA, 0.16)
  assert.equal(totalesDeCompra([linea(1, 100)]).iva, 16)
})

test('problemasDeCompra: hace falta proveedor y al menos una pieza', () => {
  assert.match(problemasDeCompra({ lineas: [linea(1, 10)] }).join(' '), /de quién se compró/)
  assert.match(problemasDeCompra({ proveedor: '  ' , lineas: [linea(1, 10)] }).join(' '), /de quién/)
  assert.match(problemasDeCompra({ proveedor: 'X', lineas: [] }).join(' '), /al menos una pieza/)
  assert.deepEqual(problemasDeCompra({ proveedor: 'X', lineas: [linea(1, 10)] }), [])
})

test('problemasDeCompra: una pieza sin cantidad o con costo negativo', () => {
  assert.match(problemasDeCompra({ proveedor: 'X', lineas: [linea(0, 10)] }).join(' '), /sin cantidad/)
  assert.match(problemasDeCompra({ proveedor: 'X', lineas: [linea(2, -5)] }).join(' '), /negativo/)
  // Un costo en CERO sí se permite: una pieza de garantía o una muestra entra sin costo.
  assert.deepEqual(problemasDeCompra({ proveedor: 'X', lineas: [linea(2, 0)] }), [])
})

test('problemasDeCompra ignora los renglones vacíos del formulario', () => {
  const lineas = [linea(1, 10), { cantidad: '', costo_unitario: '' }]
  assert.deepEqual(problemasDeCompra({ proveedor: 'X', lineas }), [])
})

// ---- el aviso del costo ----

test('cambioDeCosto avisa en palabras cuando el costo cambió', () => {
  const r = cambioDeCosto(linea(1, 310), 285)
  assert.equal(r.hay, true)
  assert.equal(r.subio, true)
  assert.equal(r.diferencia, 25)
  assert.match(r.texto, /subió de 285 a 310/)
})

test('cambioDeCosto distingue que bajó', () => {
  const r = cambioDeCosto(linea(1, 250), 285)
  assert.equal(r.subio, false)
  assert.equal(r.diferencia, -35)
  assert.match(r.texto, /bajó/)
})

test('cambioDeCosto: mismo costo, sin aviso', () => {
  assert.equal(cambioDeCosto(linea(1, 285), 285).hay, false)
})

test('cambioDeCosto: sin costo en el catálogo es la PRIMERA vez, no un cambio', () => {
  // De las 52 refacciones, 51 no tienen costo capturado: la primera compra lo establece.
  // Decir "subió de 0 a 310" sería engañoso.
  for (const viejo of [0, null, undefined, '']) {
    const r = cambioDeCosto(linea(1, 310), viejo)
    assert.equal(r.hay, false, `falló con ${JSON.stringify(viejo)}`)
    assert.equal(r.primero, true)
  }
})

// ---- lo que viaja a la base ----

test('lineasParaGuardar tira los renglones vacíos y los de cantidad cero', () => {
  const lineas = [linea(2, 10), { cantidad: 5, costo_unitario: 3 }, linea(0, 10)]
  const r = lineasParaGuardar(lineas)
  assert.equal(r.length, 1)   // el segundo no tiene producto_id, el tercero no tiene cantidad
  assert.equal(r[0].cantidad, 2)
})

test('lineasParaGuardar NO manda requisicion_id vacío', () => {
  // La base lo leería como un uuid inválido y tronaría la compra entera.
  const r = lineasParaGuardar([linea(1, 10, { requisicion_id: '' })])
  assert.equal('requisicion_id' in r[0], false)

  const con = lineasParaGuardar([linea(1, 10, { requisicion_id: 'req-1' })])
  assert.equal(con[0].requisicion_id, 'req-1')
})

test('lineasParaGuardar solo manda actualizar_costo si está marcado', () => {
  assert.equal('actualizar_costo' in lineasParaGuardar([linea(1, 10)])[0], false)
  assert.equal(lineasParaGuardar([linea(1, 10, { actualizar_costo: true })])[0].actualizar_costo, true)
})

test('lineasParaGuardar manda números, no textos del formulario', () => {
  const r = lineasParaGuardar([linea('3', '310')])
  assert.equal(r[0].cantidad, 3)
  assert.equal(r[0].costo_unitario, 310)
  assert.equal(typeof r[0].cantidad, 'number')
})

test('lineaDesdePedido trae la pieza, la cantidad y el costo de referencia', () => {
  const p = { requisicion_id: 'r1', folio: 12, producto_id: 'p9', sku: 'FIL-1',
              nombre: 'Filtro', unidad: 'pieza', cantidad: 4, costo_referencia: 285 }
  const l = lineaDesdePedido(p)
  assert.equal(l.producto_id, 'p9')
  assert.equal(l.cantidad, 4)
  assert.equal(l.costo_unitario, 285)
  assert.equal(l.requisicion_id, 'r1')
  assert.equal(l.pedido, 12)
})

test('lineaNueva parte del costo del catálogo, y vacío si no hay', () => {
  assert.equal(lineaNueva({ id: 'p1', sku: 'A', costo: 120 }).costo_unitario, 120)
  assert.equal(lineaNueva({ id: 'p1', sku: 'A' }).costo_unitario, '')
  assert.equal(lineaNueva({ id: 'p1', sku: 'A' }).cantidad, 1)
})
