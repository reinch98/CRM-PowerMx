import { test } from 'node:test'
import assert from 'node:assert/strict'
import { textoReabierto } from '../src/lib/comisiones.js'
import { textoDeshecho } from '../src/lib/finanzas.js'

test('reabrir un pago pagado: dice cuántos egresos se quitaron y cuántos renglones del banco se liberaron', () => {
  assert.equal(textoReabierto({ estaba: 'pagado', egresos_borrados: 2, banco_liberados: 1 }, 14),
    'PAGO-14 volvió a borrador: corrígelo, apruébalo y regístralo de nuevo. ' +
    'Se quitaron 2 egresos del libro y los expedientes. 1 renglón del banco volvió a "por conciliar".')
  assert.equal(textoReabierto({ egresos_borrados: 1, banco_liberados: 3 }, 2),
    'PAGO-2 volvió a borrador: corrígelo, apruébalo y regístralo de nuevo. ' +
    'Se quitó 1 egreso del libro y los expedientes. 3 renglones del banco volvieron a "por conciliar".')
})

test('reabrir un pago aprobado: sin egresos que mencionar', () => {
  assert.equal(textoReabierto({ estaba: 'aprobado', egresos_borrados: 0, banco_liberados: 0 }, 7),
    'PAGO-7 volvió a borrador: corrígelo, apruébalo y regístralo de nuevo.')
  assert.equal(textoReabierto(undefined, 7), 'PAGO-7 volvió a borrador: corrígelo, apruébalo y regístralo de nuevo.')
})

test('deshacer un pago a proveedor: lo que se vuelve a deber y el banco', () => {
  assert.equal(textoDeshecho({ saldo: 1160, banco: 0 }, 'Refaccionaria del Sureste'),
    'Pago deshecho. A Refaccionaria del Sureste le vuelves a deber $1,160.00; regístralo de nuevo con el monto correcto.')
  assert.match(textoDeshecho({ saldo: 500, banco: 1 }, 'X'), /1 renglón del banco volvió a "por conciliar"\.$/)
  assert.match(textoDeshecho({ saldo: 500 }, ''), /^Pago deshecho\. A ese proveedor/)
})
