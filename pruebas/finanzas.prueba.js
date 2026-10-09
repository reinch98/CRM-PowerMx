import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  proponerGasto, accionSugerida, avisosDeCfdi, formularioDeAprobacion, validarAprobacion,
  paraEnviarAprobacion, resumenLibro, rangoDeMes, mesAnterior, nombreDeMes, fechaMerida,
  validarMovimientoLibre, validarEmpresaFiscal, etiquetaCategoria, esIngreso, sha256Hex
} from '../src/lib/finanzas.js'

const cfdiGas = {
  sentido: 'recibido', tipo_comprobante: 'I', nombre_emisor: 'SERVICIO LAS AMERICAS SA DE CV',
  rfc_emisor: 'SLA010101AAA', total: 812.0, iva_trasladado: 112.0, metodo_pago: 'PUE', forma_pago: '04',
  fecha: '2026-10-09T20:03:11+00:00', conceptos: [{ clave: '15101514', descripcion: 'MAGNA' }]
}

test('una regla aprendida varias veces manda y es "alta"', () => {
  const p = proponerGasto({ cfdi: cfdiGas, regla: { categoria: 'viaticos', veces: 3 } })
  assert.equal(p.categoria, 'viaticos')
  assert.equal(p.confianza, 'alta')
})

test('una regla vista una sola vez es "media"', () => {
  assert.equal(proponerGasto({ cfdi: cfdiGas, regla: { categoria: 'gasolina', veces: 1 } }).confianza, 'media')
})

test('sin regla, la clave del SAT de combustible propone gasolina', () => {
  const p = proponerGasto({ cfdi: cfdiGas })
  assert.equal(p.categoria, 'gasolina')
  assert.equal(p.confianza, 'media')
})

test('sin regla ni clave, las palabras del concepto proponen la categoría', () => {
  const p = proponerGasto({ cfdi: { nombre_emisor: 'Radiomóvil Dipsa (TELCEL)', conceptos: [{ descripcion: 'Servicio de telefonía' }] } })
  assert.equal(p.categoria, 'servicios')
})

test('sin ninguna pista es "baja" y deja elegir', () => {
  const p = proponerGasto({ cfdi: { nombre_emisor: 'ACME', conceptos: [{ descripcion: 'Varios' }] } })
  assert.equal(p.categoria, 'otro')
  assert.equal(p.confianza, 'baja')
})

test('una factura ya registrada en Compras se paga como "pago a proveedor"', () => {
  assert.equal(proponerGasto({ cfdi: cfdiGas, compra: 'x' }).categoria, 'pago_proveedor')
})

test('lo emitido, notas de crédito y complementos solo se archivan', () => {
  assert.equal(accionSugerida({ sentido: 'emitido', tipo_comprobante: 'I' }), 'archivar')
  assert.equal(accionSugerida({ sentido: 'recibido', tipo_comprobante: 'E' }), 'archivar')
  assert.equal(accionSugerida({ sentido: 'recibido', tipo_comprobante: 'P' }), 'archivar')
  assert.equal(accionSugerida({ sentido: 'recibido', tipo_comprobante: 'I' }), 'gasto')
})

test('avisos en palabras: PPD, moneda extranjera y retenciones', () => {
  assert.ok(avisosDeCfdi({ sentido: 'recibido', metodo_pago: 'PPD' }).some(a => /PPD/.test(a)))
  assert.ok(avisosDeCfdi({ sentido: 'recibido', moneda: 'USD' }).some(a => /USD/.test(a)))
  assert.ok(avisosDeCfdi({ sentido: 'emitido', isr_retenido: 12.5 }).some(a => /retuvieron ISR/.test(a)))
  assert.deepEqual(avisosDeCfdi({ sentido: 'recibido', metodo_pago: 'PUE', moneda: 'MXN' }), [])
})

test('el formulario nace del CFDI: total, IVA, fecha de Mérida y forma', () => {
  const f = formularioDeAprobacion({}, cfdiGas, { categoria: 'gasolina' })
  assert.equal(f.monto, '812')
  assert.equal(f.iva, '112')
  assert.equal(f.fecha, '2026-10-09')
  assert.equal(f.forma, 'tarjeta')
  assert.equal(f.pagado, true)
  assert.equal(f.categoria, 'gasolina')
})

test('una factura PPD nace como "aún no la pago"', () => {
  assert.equal(formularioDeAprobacion({}, { ...cfdiGas, metodo_pago: 'PPD' }, null).pagado, false)
})

test('la fecha del CFDI se lee en hora de Mérida, no en UTC', () => {
  // 03:00 UTC del 10 de octubre son las 21:00 del 9 en Mérida.
  assert.equal(fechaMerida('2026-10-10T03:00:00+00:00'), '2026-10-09')
})

test('validar la aprobación', () => {
  assert.equal(validarAprobacion({ accion: 'archivar' }), '')
  assert.match(validarAprobacion({ accion: 'gasto', categoria: 'gasolina', pagado: true, monto: '', fecha: '2026-10-09' }), /monto/)
  assert.match(validarAprobacion({ accion: 'gasto', categoria: 'gasolina', pagado: true, monto: '100', iva: '200', fecha: '2026-10-09' }), /IVA/)
  assert.equal(validarAprobacion({ accion: 'gasto', categoria: 'gasolina', pagado: false }), '')
})

test('lo que viaja a la base: números como números y vacíos como null', () => {
  const d = paraEnviarAprobacion({ accion: 'gasto', categoria: 'otro', monto: '100.5', iva: '', fecha: '', pagado: true, cuenta_id: '', forma: 'efectivo', concepto: ' ', referencia: '', cotizacion_id: '', notas: '' })
  assert.equal(d.monto, 100.5)
  assert.equal(d.iva, null)
  assert.equal(d.fecha, null)
  assert.equal(d.cuenta_id, null)
  assert.equal(d.concepto, null)
})

test('el resumen del mes separa negocio de lo que pones o sacas tú', () => {
  const r = resumenLibro([
    { categoria: 'cobro', monto: 10000 },
    { categoria: 'gasolina', monto: 812, iva: 112, cfdi_id: 'c1' },
    { categoria: 'renta', monto: 3000, iva: 0 },
    { categoria: 'material', monto: 1160, iva: 160 },          // sin CFDI: su IVA no se acredita
    { categoria: 'retiro_dueno', monto: 2000 },
    { categoria: 'aportacion', monto: 500 }
  ])
  assert.equal(r.ingresos, 10000)
  assert.equal(r.gastos, 4972)
  assert.equal(r.resultado, 5028)
  assert.equal(r.retiros, 2000)
  assert.equal(r.aportaciones, 500)
  assert.equal(r.iva_acreditable, 112)
  assert.equal(r.movimiento_neto_caja, 3528)
  assert.equal(r.por_categoria[0].categoria, 'renta')
})

test('rangos y nombres de mes', () => {
  assert.deepEqual(rangoDeMes('2026-02'), { desde: '2026-02-01', hasta: '2026-02-28' })
  assert.deepEqual(rangoDeMes('2028-02'), { desde: '2028-02-01', hasta: '2028-02-29' })
  assert.equal(mesAnterior('2026-01'), '2025-12')
  assert.equal(mesAnterior('2026-12', -1), '2027-01')
  assert.equal(nombreDeMes('2026-10'), 'octubre 2026')
})

test('movimiento sin documento: un cobro no entra por aquí', () => {
  assert.match(validarMovimientoLibre({ categoria: 'cobro', monto: '1', fecha: '2026-10-01' }), /Expediente/)
  assert.equal(validarMovimientoLibre({ categoria: 'retiro_dueno', monto: '500', fecha: '2026-10-01' }), '')
})

test('RFC y código postal', () => {
  assert.equal(validarEmpresaFiscal({ rfc: 'GOMP850101AB1', cp_expedicion: '97000' }), '')
  assert.match(validarEmpresaFiscal({ rfc: 'GOMP85' }), /RFC/)
  assert.match(validarEmpresaFiscal({ rfc: 'gomp850101ab1', cp_expedicion: '970' }), /postal/)
})

test('etiquetas y tipos', () => {
  assert.equal(etiquetaCategoria('retiro_dueno'), 'Retiro del dueño')
  assert.equal(esIngreso('aportacion'), true)
  assert.equal(esIngreso('retiro_dueno'), false)
})

test('la huella del archivo es SHA-256 en hexadecimal', async () => {
  const h = await sha256Hex(new TextEncoder().encode('abc'))
  assert.equal(h, 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
})
