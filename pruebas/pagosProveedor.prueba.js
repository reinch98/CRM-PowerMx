import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  normalizarComprobantePago, destinoInicial, textoOpcionFactura, textoOpcionCotizacion, problemasDePago,
  paraRegistrar, textoRegistrado
} from '../src/lib/pagosProveedor.js'

test('lo leído de un comprobante bancario: quien recibe es el proveedor', () => {
  const l = normalizarComprobantePago({
    monto: '$2,317.53', fecha: '2026-10-10', forma: 'SPEI', referencia: ' MBAN01002610100001 ',
    beneficiario: 'EXEL SOLAR SAPI DE CV', concepto: 'Pedido 1474048', notas: ''
  })
  assert.equal(l.monto, 2317.53)
  assert.equal(l.forma, 'transferencia')
  assert.equal(l.referencia, 'MBAN01002610100001')
  assert.equal(l.beneficiario, 'EXEL SOLAR SAPI DE CV')
  assert.equal(normalizarComprobantePago({ fecha: '10/10/2026' }).fecha, '')   // fecha sin formato: no se inventa
})

test('a qué se aplica si nadie elige: la factura exacta, luego la cotización aceptada, luego anticipo', () => {
  const f = (id, exacta) => ({ cfdi_id: id, saldo: 100, exacta })
  assert.deepEqual(destinoInicial({ facturas: [f('a', false), f('b', true)], cotizaciones: [] }), { tipo: 'factura', id: 'b' })
  // Dos que cuadran exacto: no se adivina.
  assert.deepEqual(destinoInicial({ facturas: [f('a', true), f('b', true)], cotizaciones: [] }), { tipo: 'anticipo', id: null })
  assert.deepEqual(destinoInicial({ facturas: [], cotizaciones: [{ id: 'q', estado: 'aceptada' }] }), { tipo: 'cotizacion', id: 'q' })
  assert.deepEqual(destinoInicial({ facturas: [], cotizaciones: [{ id: 'q', estado: 'vigente' }] }), { tipo: 'anticipo', id: null })
  assert.deepEqual(destinoInicial(null), { tipo: 'anticipo', id: null })
})

test('cada factura dice si el pago cuadra, es parcial o se pasa', () => {
  const fac = { serie: 'A', folio: '902', saldo: 8500 }
  assert.match(textoOpcionFactura(fac, 8500), /Paga la factura A 902 · saldo \$8,500\.00 · Cuadra exacto/)
  assert.match(textoOpcionFactura(fac, 5000), /Pago parcial: quedaría \$3,500\.00/)
  assert.match(textoOpcionFactura(fac, 9000), /mayor que lo que se debe/)
  assert.match(textoOpcionCotizacion({ folio: 7, numero: 'COT-1474', moneda: 'USD', total: 475.6, total_mxn: 8655.92, anticipos: 1000 }),
    /COTP-7 \(COT-1474\) · total USD 475\.60 \(≈ \$8,655\.92\) · ya se dieron \$1,000\.00/)
})

test('lo que falta antes de registrar, y lo que se manda', () => {
  const opciones = { facturas: [{ cfdi_id: 'a', saldo: 100 }] }
  assert.equal(problemasDePago({ proveedor: '', monto: '', fecha: '' }, { tipo: 'anticipo' }, opciones).length, 3)
  assert.match(problemasDePago({ proveedor: 'X', monto: 150, fecha: '2026-10-10' }, { tipo: 'factura', id: 'a' }, opciones)[0], /mayor que el saldo/)
  assert.deepEqual(problemasDePago({ proveedor: 'X', monto: 100, fecha: '2026-10-10' }, { tipo: 'factura', id: 'a' }, opciones), [])
  const d = paraRegistrar({ proveedor: ' Exel ', proveedor_id: 'p1', monto: '100', fecha: '2026-10-10', referencia: ' ', cuenta_id: '' },
    { tipo: 'cotizacion', id: 'q' }, 'doc1')
  assert.equal(d.proveedor, 'Exel')
  assert.equal(d.monto, 100)
  assert.equal(d.referencia, null)
  assert.equal(d.cuenta_id, null)
  assert.equal(d.cfdi_id, null)
  assert.equal(d.cotizacion_proveedor_id, 'q')
  assert.equal(d.documento_id, 'doc1')
})

test('lo que se dice al registrar', () => {
  assert.equal(textoRegistrado({ tipo: 'pago_factura', proveedor: 'Exel Solar' }), 'Pago registrado: la factura de Exel Solar quedó pagada.')
  assert.match(textoRegistrado({ tipo: 'pago_parcial', proveedor: 'Exel Solar', saldo: 300 }), /falta \$300\.00/)
  assert.match(textoRegistrado({ tipo: 'anticipo', proveedor: 'Exel Solar' }), /^Anticipo a Exel Solar registrado/)
})
