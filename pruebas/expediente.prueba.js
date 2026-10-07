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

import { normalizarTicket, normalizarBanco, formDesdeTicket, formDesdeBanco } from '../src/lib/expediente.js'

test('un ticket leído se normaliza: números, fecha válida y categoría conocida', () => {
  const t = normalizarTicket({
    establecimiento: ' Gasolinera Norte ', fecha: '2026-10-06', total: '$1,045.50', litros: 40.2,
    combustible: 'magna', categoria: 'gasolina', folio: 'T-99', iva: null
  })
  assert.equal(t.establecimiento, 'Gasolinera Norte')
  assert.equal(t.total, 1045.5)
  assert.equal(t.litros, 40.2)
  assert.equal(t.categoria, 'gasolina')
  assert.equal(t.iva, null)
  assert.equal(normalizarTicket({ fecha: '6/10/2026', categoria: 'inventada' }).fecha, '')
  assert.equal(normalizarTicket({ categoria: 'inventada' }).categoria, '')
  assert.equal(normalizarTicket(null).total, null)
})

test('un comprobante bancario leído se normaliza', () => {
  const b = normalizarBanco({ monto: '1,500', fecha: '2026-10-02', forma: 'transferencia', referencia: ' SPEI-1 ', banco: 'BBVA' })
  assert.equal(b.monto, 1500)
  assert.equal(b.forma, 'transferencia')
  assert.equal(b.referencia, 'SPEI-1')
  assert.equal(normalizarBanco({ forma: 'bitcoin' }).forma, '')
})

test('el ticket llena el formulario de gasto y cambia el tipo si no era el que estaba', () => {
  const form = { fecha: '2026-10-07', categoria: 'tecnico', concepto: '', monto: '', iva: '', tecnico_id: '', notas: '' }
  const f = formDesdeTicket(normalizarTicket({
    establecimiento: 'Gasolinera Norte', fecha: '2026-10-06', total: 1045.5, litros: 40.2, combustible: 'magna',
    categoria: 'gasolina', folio: 'T-99'
  }), form)
  assert.equal(f.categoria, 'gasolina')
  assert.equal(f.fecha, '2026-10-06')
  assert.equal(f.monto, '1045.5')
  assert.equal(f.concepto, '40.2 L magna · Gasolinera Norte')
  assert.equal(f.referencia, 'T-99')
})

test('lo que el ticket no trae NO pisa lo que ya estaba capturado', () => {
  const form = { fecha: '2026-10-07', categoria: 'viaticos', concepto: 'Comida', monto: '300', iva: '41.38', tecnico_id: '', notas: '' }
  const f = formDesdeTicket(normalizarTicket({ notas: 'borroso' }), form)
  assert.deepEqual({ ...f, referencia: undefined }, { ...form, referencia: undefined })
  assert.equal(f.monto, '300')
  assert.equal(f.iva, '41.38')
})

test('el comprobante bancario llena el cobro: monto, fecha, forma, referencia y banco', () => {
  const form = { fecha: '2026-10-07', monto: '', forma: 'efectivo', referencia: '', notas: '' }
  const f = formDesdeBanco(normalizarBanco({
    monto: 2900, fecha: '2026-10-05', forma: 'transferencia', referencia: 'MBAN123', banco: 'BBVA', ordenante: 'Hotel X'
  }), form)
  assert.equal(f.monto, '2900')
  assert.equal(f.forma, 'transferencia')
  assert.equal(f.referencia, 'MBAN123')
  assert.equal(f.notas, 'Banco: BBVA · De: Hotel X')
  // sin forma leída se queda la que estaba
  assert.equal(formDesdeBanco(normalizarBanco({ monto: 10 }), form).forma, 'efectivo')
})

import { verificacionDeCobro, estadoCobro, textoCobranza } from '../src/lib/expediente.js'

test('un cobro con el monto capturado igual al leído queda verificado', () => {
  assert.equal(verificacionDeCobro({ monto: '2900', monto_leido: '2900' }).estado, 'verificado')
  assert.equal(verificacionDeCobro({ monto: '2900.004', monto_leido: '2900' }).estado, 'verificado')
})

test('si lo capturado no coincide con lo leído, no cuadra y lo dice en pesos', () => {
  const v = verificacionDeCobro({ monto: '1900', monto_leido: '1800' })
  assert.equal(v.estado, 'no_coincide')
  assert.match(v.texto, /1,800/)
  assert.match(v.texto, /1,900/)
})

test('sin lectura del comprobante el cobro suma pero no puede cerrar la cobranza', () => {
  assert.equal(verificacionDeCobro({ monto: '500', monto_leido: '' }).estado, 'sin_leer')
  assert.equal(verificacionDeCobro({ monto: '500' }).estado, 'sin_leer')
})

test('el cobro guarda el monto que leyó la IA y si fue leído', () => {
  const leido = filaDeMovimiento({ monto: '2900', fecha: '2026-10-07', monto_leido: '2900' }, 'ingreso', 'c1')
  assert.equal(leido.leido_ia, true)
  assert.equal(leido.monto_leido, 2900)
  const nada = filaDeMovimiento({ monto: '2900', fecha: '2026-10-07', monto_leido: '' }, 'ingreso', 'c1')
  assert.equal(nada.leido_ia, false)
  assert.equal(nada.monto_leido, null)
  const gasto = filaDeMovimiento({ categoria: 'gasolina', monto: '100', fecha: '2026-10-07', monto_leido: '100' }, 'egreso', 'c1')
  assert.equal(gasto.leido_ia, false)
  assert.equal(gasto.monto_leido, null)
})

test('el comprobante bancario deja guardado el monto leído para comparar', () => {
  const f = formDesdeBanco(normalizarBanco({ monto: 2900, referencia: 'X' }), { fecha: '2026-10-07', monto: '', forma: 'efectivo', referencia: '', notas: '', monto_leido: '' })
  assert.equal(f.monto_leido, '2900')
  assert.equal(f.monto, '2900')
})

test('el estado de un cobro ya guardado se dice con palabra', () => {
  assert.equal(estadoCobro({ archivo: null }), 'Sin comprobante')
  assert.equal(estadoCobro({ archivo: 'x', leido_ia: false }), 'Comprobante sin verificar')
  assert.equal(estadoCobro({ archivo: 'x', leido_ia: true, monto_leido: 1800, monto: 1900 }), 'Comprobante sin verificar')
  assert.equal(estadoCobro({ archivo: 'x', leido_ia: true, monto_leido: 1900, monto: 1900 }), 'Verificado con el comprobante')
})

test('la cobranza se dice con palabra', () => {
  assert.equal(textoCobranza('pendiente'), 'Sin cobros')
  assert.equal(textoCobranza('parcial'), 'Cobro parcial')
  assert.equal(textoCobranza('liquidada'), 'Cobrada')
  assert.equal(textoCobranza('rara'), '—')
})
