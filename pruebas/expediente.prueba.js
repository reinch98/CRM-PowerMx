import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  validarMovimiento, filaDeMovimiento, rutaComprobante, estadoComprobante, textoUtilidad,
  etiquetaCategoria, archivoValido, esPdf, CATEGORIAS_EGRESO
} from '../src/lib/expediente.js'

const egreso = (extra = {}) => ({ categoria: 'gasolina', fecha: '2026-10-07', monto: '500', iva: '', ...extra })

test('un monto en cero o vacío no se puede guardar', () => {
  assert.match(validarMovimiento(egreso({ monto: '' }), 'egreso'), /monto/)
  assert.match(validarMovimiento(egreso({ monto: '0' }), 'egreso'), /monto/)
  assert.match(validarMovimiento(egreso({ monto: '-5' }), 'egreso'), /monto/)
  assert.equal(validarMovimiento(egreso(), 'egreso'), null)
})

test('sin fecha no se guarda', () => {
  assert.match(validarMovimiento(egreso({ fecha: '' }), 'egreso'), /fecha/i)
})

test('el pago de técnico exige a quién', () => {
  assert.match(validarMovimiento(egreso({ categoria: 'tecnico' }), 'egreso'), /técnico/)
  assert.equal(validarMovimiento(egreso({ categoria: 'tecnico', tecnico_id: 'abc' }), 'egreso'), null)
})

test('"otro gasto" exige describirlo', () => {
  assert.match(validarMovimiento(egreso({ categoria: 'otro' }), 'egreso'), /Describe/)
  assert.equal(validarMovimiento(egreso({ categoria: 'otro', concepto: 'Caseta' }), 'egreso'), null)
})

test('el IVA no puede ser mayor que el monto ni negativo', () => {
  assert.match(validarMovimiento(egreso({ iva: '600' }), 'egreso'), /IVA/)
  assert.match(validarMovimiento(egreso({ iva: '-1' }), 'egreso'), /IVA/)
  assert.equal(validarMovimiento(egreso({ iva: '68.97' }), 'egreso'), null)
})

test('un cobro solo necesita monto y fecha', () => {
  assert.equal(validarMovimiento({ monto: '1000', fecha: '2026-10-07' }, 'ingreso'), null)
  assert.match(validarMovimiento({ monto: '', fecha: '2026-10-07' }, 'ingreso'), /monto/)
})

test('la fila guardada manda null y no cadena vacía', () => {
  const f = filaDeMovimiento(egreso({ concepto: '  ', referencia: '', notas: '' }), 'egreso', 'cot1', 'caña@x')
  assert.equal(f.concepto, null)
  assert.equal(f.referencia, null)
  assert.equal(f.notas, null)
  assert.equal(f.monto, 500)
  assert.equal(f.iva, 0)
  assert.equal(f.tipo, 'egreso')
  assert.equal(f.creado_por, 'caña@x')
})

test('un cobro se guarda como categoría "cobro" y sin IVA', () => {
  const f = filaDeMovimiento({ monto: '2900', fecha: '2026-10-07', forma: 'transferencia', referencia: 'SPEI-9', iva: '400' }, 'ingreso', 'cot1')
  assert.equal(f.categoria, 'cobro')
  assert.equal(f.iva, 0)
  assert.equal(f.forma, 'transferencia')
  assert.equal(f.tecnico_id, null)
})

test('el técnico solo se guarda cuando el gasto es pago de técnico', () => {
  const pago = filaDeMovimiento(egreso({ categoria: 'tecnico', tecnico_id: 'u1' }), 'egreso', 'c')
  const gas = filaDeMovimiento(egreso({ categoria: 'gasolina', tecnico_id: 'u1' }), 'egreso', 'c')
  assert.equal(pago.tecnico_id, 'u1')
  assert.equal(gas.tecnico_id, null)
})

test('el comprobante se sube con una ruta que cuelga de la cotización y no se pisa', () => {
  const a = rutaComprobante('cot1', 'Ticket Gasolina ñ.JPG', false, 111)
  const b = rutaComprobante('cot1', 'Ticket Gasolina ñ.JPG', false, 222)
  assert.equal(a, 'cot1/111-Ticket-Gasolina-n.jpg')
  assert.notEqual(a, b)
  assert.equal(rutaComprobante('cot1', 'spei.pdf', true, 5), 'cot1/5-spei.pdf')
  assert.equal(rutaComprobante('cot1', '', false, 5), 'cot1/5-comprobante.jpg')
})

test('solo se aceptan fotos y PDF', () => {
  assert.equal(archivoValido({ type: 'image/png', name: 'a.png' }), true)
  assert.equal(archivoValido({ type: 'application/pdf', name: 'a.pdf' }), true)
  assert.equal(archivoValido({ type: '', name: 'banco.PDF' }), true)
  assert.equal(archivoValido({ type: 'application/zip', name: 'a.zip' }), false)
  assert.equal(esPdf({ type: 'application/pdf' }), true)
})

test('el comprobante se dice con palabra', () => {
  assert.equal(estadoComprobante({ archivo: 'x' }), 'Comprobado')
  assert.equal(estadoComprobante({ archivo: null }), 'Sin comprobante')
  assert.equal(estadoComprobante(null), 'Sin comprobante')
})

test('la utilidad se dice con palabra, también cuando es pérdida', () => {
  assert.equal(textoUtilidad(1200), 'Utilidad')
  assert.equal(textoUtilidad(-50), 'Pérdida')
  assert.equal(textoUtilidad(0), 'Sin utilidad')
})

test('toda categoría de gasto tiene su etiqueta', () => {
  for (const [k, t] of CATEGORIAS_EGRESO) assert.equal(etiquetaCategoria(k), t)
  assert.equal(etiquetaCategoria('cobro'), 'Cobro')
})
