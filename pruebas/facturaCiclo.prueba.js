import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  lecturaDesdeCfdi, textoCompra, textoCotizacion, anticiposIniciales, sumaAnticipos, problemaDeAnticipos, avisoPagoDoble
} from '../src/lib/facturaCiclo.js'

const cfdi = {
  uuid_fiscal: 'aaaaaaaa-0000-4000-8000-000000000086', serie: 'A', folio: '1474048', fecha: '2026-10-10T19:30:00-06:00',
  nombre_emisor: 'EXEL SOLAR SAPI DE CV', rfc_emisor: 'ESO010101AB1', moneda: 'MXN', subtotal: 1997.87, iva_trasladado: 319.66,
  total: 2317.53, descuento: 0,
  conceptos: [
    { clave: '26121600', codigo: 'CAB10', descripcion: 'Cable fotovoltaico 10 AWG', cantidad: 1, valor_unitario: 1997.87, importe: 1997.87 },
    { clave: '0', codigo: '', descripcion: '', cantidad: 1, valor_unitario: 5, importe: 5 }
  ]
}

test('la lectura sale del XML: misma forma que la de la IA, sin renglones vacíos', () => {
  const l = lecturaDesdeCfdi(cfdi, 'Exel Solar')
  assert.equal(l.proveedor, 'Exel Solar')
  assert.equal(l.factura, 'A-1474048')
  assert.equal(l.uuid_fiscal, cfdi.uuid_fiscal)
  assert.equal(l.fecha, '2026-10-10')              // la fecha de Mérida, no la de UTC (ya sería día 11)
  assert.equal(l.lineas.length, 1)
  assert.equal(l.descartadas, 1)
  assert.equal(l.lineas[0].codigo, 'CAB10')
  assert.equal(l.lineas[0].precio_unitario, 1997.87)
  assert.equal(l.preciosIncluyenIva, false)
  assert.equal(l.iva, 319.66)
})

test('en dólares se pasa a pesos con su tipo de cambio; un descuento se avisa', () => {
  const l = lecturaDesdeCfdi({ ...cfdi, moneda: 'USD', tipo_cambio: 18.5, descuento: 10, subtotal: 100, total: 116,
    conceptos: [{ codigo: 'X', descripcion: 'Pieza', cantidad: 2, valor_unitario: 50, importe: 100 }] })
  assert.equal(l.moneda, 'MXN')
  assert.equal(l.lineas[0].precio_unitario, 925)
  assert.equal(l.subtotal, 1850)
  assert.match(l.notas, /tipo de cambio \(18\.5\)/)
  assert.match(l.notas, /descuento de \$185\.00/)
  assert.match(lecturaDesdeCfdi({ ...cfdi, moneda: 'USD', tipo_cambio: null }).notas, /no trae tipo de cambio/)
})

test('textos de la compra y de la cotización', () => {
  assert.equal(textoCompra({ folio: 8, factura: '1474048', fecha: '2026-10-10', total: 2317.53 }),
    'Compra 8 · factura 1474048 · 10/10/2026 · $2,317.53')
  assert.equal(textoCotizacion({ folio: 7, numero: 'COT-1474', estado: 'aceptada', moneda: 'USD', total: 475.6, total_mxn: 8655.92 }),
    'COTP-7 (COT-1474) · aceptada · USD 475.60 (≈ $8,655.92)')
})

test('anticipos propuestos: los de su cotización que caben; si no, el único que cuadra exacto', () => {
  const ant = (id, monto, de) => ({ movimiento_id: id, monto, de_su_cotizacion: de, cabe: true })
  const ctx = (saldo, anticipos) => ({ factura: { saldo, total: saldo, proveedor: 'Exel Solar' }, anticipos })
  assert.deepEqual(anticiposIniciales(ctx(1000, [ant('a', 600, true), ant('b', 600, true), ant('c', 1000, false)])), ['a'])
  assert.deepEqual(anticiposIniciales(ctx(1000, [ant('c', 1000, false)])), ['c'])
  assert.deepEqual(anticiposIniciales(ctx(1000, [ant('c', 1000, false), ant('d', 1000, false)])), [])   // dos iguales: no se adivina
  assert.deepEqual(anticiposIniciales(ctx(1000, [ant('e', 400, false)])), [])
  assert.deepEqual(anticiposIniciales(null), [])
})

test('suma, exceso y el aviso de pago doble', () => {
  const ctx = { factura: { saldo: 1160, total: 1160, proveedor: 'Exel Solar' },
    anticipos: [{ movimiento_id: 'a', monto: 1160, fecha: '2026-10-05' }, { movimiento_id: 'b', monto: 500 }] }
  assert.equal(sumaAnticipos(ctx, ['a', 'b']), 1660)
  assert.match(problemaDeAnticipos(ctx, ['a', 'b']), /suman más/)
  assert.equal(problemaDeAnticipos(ctx, ['a']), '')
  assert.match(avisoPagoDoble(ctx, true), /Ya registraste un pago de \$1,160\.00 a Exel Solar el 05\/10\/2026/)
  assert.equal(avisoPagoDoble(ctx, false), '')
})
