import { test } from 'node:test'
import assert from 'node:assert/strict'
import { normalizarEstadoCuenta, cuadreEstado, sentidoDe, textoCandidato, detalleCandidato } from '../src/lib/conciliacion.js'

// El mismo caso de 75_prueba_conciliacion_bancaria.sql: inicial 1,000 → final 14,972.92.
const LEIDO = {
  banco: 'Banorte', cuenta_ultimos4: '****1234', periodo_desde: '2027-05-01', periodo_hasta: '2027-05-31',
  saldo_inicial: '1,000.00', saldo_final: 14972.92,
  movimientos: [
    { fecha: '2027-05-10', descripcion: ' SPEI RECIBIDO CLIENTE ', abono: 5800 },
    { fecha: '2027-05-10', descripcion: 'COMPRA GASOLINERA', cargo: '$812.00' },
    { fecha: '2027-05-12', descripcion: 'PAGO SERVICIO', cargo: 500 },
    { fecha: '2027-05-12', descripcion: 'PAGO SERVICIO', cargo: 500 },
    { fecha: '2027-05-31', descripcion: 'COMISION MANEJO DE CUENTA', cargo: 15.08 },
    { fecha: '2027-05-20', descripcion: 'TRASPASO CUENTA PROPIA', abono: 10000 }
  ]
}

test('normaliza montos con $ y comas, recorta textos y deja solo los 4 últimos dígitos', () => {
  const e = normalizarEstadoCuenta(LEIDO)
  assert.equal(e.cuenta_ultimos4, '1234')
  assert.equal(e.saldo_inicial, 1000)
  assert.equal(e.movimientos.length, 6)
  assert.equal(e.movimientos[0].descripcion, 'SPEI RECIBIDO CLIENTE')
  assert.equal(e.movimientos[1].cargo, 812)
  assert.equal(e.movimientos[0].saldo, null)
  assert.equal(e.descartados, 0)
})

test('descarta y cuenta renglones sin fecha, con cargo y abono a la vez, o sin ninguno', () => {
  const e = normalizarEstadoCuenta({
    movimientos: [
      { fecha: '10/05/2027', cargo: 5 },
      { fecha: '2027-05-10', cargo: 5, abono: 5 },
      { fecha: '2027-05-10' },
      { fecha: '2027-05-10', abono: 7 },
      null
    ]
  })
  assert.equal(e.movimientos.length, 1)
  assert.equal(e.descartados, 4)
})

test('una respuesta que no es objeto no truena', () => {
  const e = normalizarEstadoCuenta('basura')
  assert.deepEqual(e.movimientos, [])
  assert.equal(e.saldo_inicial, null)
  assert.equal(e.periodo_desde, '')
})

test('cuadra: inicial + entradas − salidas = final', () => {
  const c = cuadreEstado(normalizarEstadoCuenta(LEIDO))
  assert.equal(c.abonos, 15800)
  assert.equal(c.cargos, 1827.08)
  assert.equal(c.diferencia, 0)
  assert.equal(c.cuadra, true)
})

test('un renglón perdido no cuadra y dice por cuánto', () => {
  const e = normalizarEstadoCuenta({ ...LEIDO, movimientos: LEIDO.movimientos.slice(0, 5) })
  const c = cuadreEstado(e)
  assert.equal(c.cuadra, false)
  assert.equal(c.diferencia, -10000)
})

test('sin saldos no se puede decir si cuadra', () => {
  const c = cuadreEstado({ saldo_inicial: null, saldo_final: 10, movimientos: [{ abono: 10 }] })
  assert.equal(c.cuadra, null)
  assert.equal(c.abonos, 10)
})

test('candidato del libro: concepto o categoría, y días de diferencia', () => {
  assert.equal(textoCandidato({ clase: 'libro', concepto: 'Anticipo' }), 'Es: Anticipo')
  assert.equal(textoCandidato({ movimiento_id: 'm', categoria: 'viaticos' }), 'Es: Viáticos')
  assert.equal(detalleCandidato({ fecha: '2026-09-25', dias: 0, cotizacion: 118 }), '25 sep 2026 · el mismo día · Cotización 118')
  assert.equal(detalleCandidato({ fecha: '2026-09-27', dias: 1 }), '27 sep 2026 · 1 día de diferencia')
})

test('candidato factura por pagar: proveedor, folio y que se registra el pago', () => {
  const f = { clase: 'factura', cfdi_id: 'c', proveedor: 'Refaccionaria del Sureste', serie: 'A', folio: '881',
    fecha: '2026-09-26', vence: '2026-10-26' }
  assert.equal(textoCandidato(f), 'Paga la factura de Refaccionaria del Sureste A-881')
  assert.equal(detalleCandidato(f), 'Factura del 26 sep 2026 · vence el 26 oct 2026 · al elegirla se registra el pago')
  assert.equal(textoCandidato({ clase: 'factura', proveedor: 'X' }), 'Paga la factura de X')
  assert.equal(detalleCandidato({ clase: 'factura', fecha: '2026-09-26' }), 'Factura del 26 sep 2026 · al elegirla se registra el pago')
})

test('sentido del renglón', () => {
  assert.equal(sentidoDe({ abono: 5 }), 'entrada')
  assert.equal(sentidoDe({ cargo: 5 }), 'salida')
})
