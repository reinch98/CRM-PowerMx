import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  filtrarProveedores, aFormulario, validarProveedor, paraGuardar, textoUnion, resumenLinea, estadoFactura
} from '../src/lib/proveedores.js'
import { sha256Hex, huellaDe, textoRepetido } from '../src/lib/huellas.js'

const LISTA = [
  { id: 1, nombre: 'Exel Solar', clave: 'xlstore', rfc: null, alias: ['XLStore', 'EXEL SOLAR S.A.P.I. DE C.V.'] },
  { id: 2, nombre: 'Cummins México', clave: null, rfc: 'CMM010101AB1', alias: [] },
]

test('buscar proveedor por nombre sin acentos, por RFC y por como viene impreso', () => {
  assert.deepEqual(filtrarProveedores(LISTA, 'mexico').map(p => p.id), [2])
  assert.deepEqual(filtrarProveedores(LISTA, 'cmm0101').map(p => p.id), [2])
  assert.deepEqual(filtrarProveedores(LISTA, 'xlstore').map(p => p.id), [1])
  assert.deepEqual(filtrarProveedores(LISTA, 's.a.p.i').map(p => p.id), [1])
  assert.equal(filtrarProveedores(LISTA, '  ').length, 2)
})

test('el formulario valida como la base: nombre, RFC del SAT, RFC genérico y correo', () => {
  assert.equal(validarProveedor({ nombre: '' }), 'Escribe el nombre del proveedor.')
  assert.equal(validarProveedor({ nombre: 'A', rfc: 'xaxx-010101-000' }), 'Ese es el RFC genérico del SAT: déjalo vacío.')
  assert.match(validarProveedor({ nombre: 'A', rfc: 'ABC123' }), /formato del SAT/)
  assert.equal(validarProveedor({ nombre: 'A', rfc: 'abc 010101 xy1' }), '')
  assert.match(validarProveedor({ nombre: 'A', email: 'sin-arroba' }), /correo/)
})

test('lo que se manda: RFC limpio, alias uno por renglón, vacíos como null', () => {
  const d = paraGuardar({ nombre: '  Cummins   México ', rfc: 'cmm-010101 ab1', alias: 'CUMMINS SA\n\n  Cummins MX  ', contacto: ' ', email: '' })
  assert.equal(d.nombre, 'Cummins México')
  assert.equal(d.rfc, 'CMM010101AB1')
  assert.deepEqual(d.alias, ['CUMMINS SA', 'Cummins MX'])
  assert.equal(d.contacto, null)
  assert.equal(d.email, null)
  assert.equal(d.activo, true)
  assert.equal(aFormulario(LISTA[0]).alias, 'XLStore\nEXEL SOLAR S.A.P.I. DE C.V.')
})

test('unir y la línea de la lista se dicen con palabras y plurales bien hechos', () => {
  assert.equal(textoUnion({ compras: 2, pedidos: 1 }, 'Cummins', 'Cummins Sales'),
    'Lo de «Cummins Sales» pasó a «Cummins» (2 compras y 1 pedido). Su nombre queda como otra forma de escribirlo.')
  assert.equal(textoUnion({}, 'A', 'B'), 'Lo de «B» pasó a «A». Su nombre queda como otra forma de escribirlo.')
  assert.equal(resumenLinea({ productos: 908, compras: 1, pedidos_abiertos: 2 }), '908 productos · 1 compra · 2 pedidos abiertos')
  assert.equal(resumenLinea({}), 'Sin movimientos todavía')
})

test('estado de una factura del proveedor', () => {
  const hoy = '2026-10-10'
  assert.equal(estadoFactura({ estado_sat: 'cancelado', por_pagar: true, saldo: 100 }, hoy).etiqueta, 'Cancelada en el SAT')
  assert.equal(estadoFactura({ por_pagar: false, saldo: 0 }, hoy).etiqueta, 'Sin saldo pendiente')
  assert.equal(estadoFactura({ por_pagar: true, saldo: 0 }, hoy).etiqueta, 'Pagada')
  assert.equal(estadoFactura({ por_pagar: true, saldo: 500, vence: '2026-10-07' }, hoy).etiqueta, 'Vencida hace 3 días')
  assert.equal(estadoFactura({ por_pagar: true, saldo: 500, vence: '2026-10-12' }, hoy).etiqueta, 'Vence en 2 días')
})

test('huella de un archivo: SHA-256 de sus bytes, igual de dos maneras', async () => {
  const esperado = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
  assert.equal(await sha256Hex(new TextEncoder().encode('abc')), esperado)
  assert.equal(await huellaDe(new Blob(['abc'])), esperado)
  assert.equal(textoRepetido('en la compra 8 de Exel Solar'), 'Ese archivo ya está registrado en la compra 8 de Exel Solar. No se volvió a subir.')
})
