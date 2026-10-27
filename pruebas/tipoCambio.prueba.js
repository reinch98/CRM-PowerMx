// Tipo de cambio del DOF y su franja en el encabezado. Toca DINERO: Cotizaciones convierte los
// equipos en dólares con este número, así que una lectura equivocada se cobraría tal cual.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { leerDof, diasEntre, fechaPlausible } from '../supabase/functions/_shared/tipoCambio.js'
import { resumenTipoCambio, fechaCorta, DIAS_SIN_ACTUALIZAR } from '../src/lib/tipoCambio.js'

// Trozo con la forma de la página real (26/10/2026). El menú de arriba también dice "DOLAR": no es el dato.
const bloque = (fecha, dolar) => `
  <select><option value="158">DOLAR</option><option value="163">CCP-DOLARES</option></select>
  <td class="tituloBloque5" colspan="2">Tipo de Cambio y Tasas al ${fecha}</td>
  <p style="display:block;float:left;width:45%; font-size: 10pt;"><span class="tituloBloque4">DOLAR</span> <br /> ${dolar}</p>
  <p style="display:block;float:left;width:45%; font-size: 10pt;"><span class="tituloBloque4">UDIS</span> <br /> 8.863616</p>`

test('lee el dólar y la fecha del bloque del DOF', () => {
  assert.deepEqual(leerDof(bloque('26/10/2026', '18.6670')), { valor: 18.667, fecha: '2026-10-26', fuente: 'dof' })
})

test('no confunde el menú ("DOLAR", "CCP-DOLARES") ni las UDIS con el dólar', () => {
  assert.equal(leerDof(bloque('26/10/2026', '19.2500')).valor, 19.25)
})

test('rechaza lo que no es un dólar razonable', () => {
  for (const malo of ['0.5000', '186.6700', '4.9999']) {
    assert.throws(() => leerDof(bloque('26/10/2026', malo)), /fuera de rango/)
  }
})

test('si la página cambió, dice por qué y no inventa un valor', () => {
  assert.throws(() => leerDof('<html>mantenimiento</html>'), /bloque/)
  assert.throws(() => leerDof(''), /bloque/)
  assert.throws(() => leerDof(null), /bloque/)
  assert.throws(() => leerDof('<td>Tipo de Cambio y Tasas al 26/10/2026</td> sin renglón'), /renglón DOLAR/)
  assert.throws(() => leerDof(bloque('31/02/2026', '18.6670')), /imposible/)
})

test('una página vieja en caché no pasa por buena', () => {
  assert.equal(diasEntre('2026-10-20', '2026-10-26'), 6)
  assert.equal(fechaPlausible('2026-10-26', '2026-10-26'), true)
  assert.equal(fechaPlausible('2026-10-23', '2026-10-26'), true)
  assert.equal(fechaPlausible('2026-09-26', '2026-10-26'), false)
  assert.equal(fechaPlausible('2026-12-01', '2026-10-26'), false)
})

test('la franja dice valor con 4 decimales, fecha corta y fuente', () => {
  const r = resumenTipoCambio({ valor: '18.667', fecha: '2026-10-26', fuente: 'dof' }, '2026-10-26')
  assert.equal(r.valor, '$18.6670')
  assert.equal(r.fecha, '26/10/26')
  assert.equal(r.fuente, 'DOF')
  assert.equal(r.vencido, false)
  assert.equal(r.aviso, '')
})

test('un puente de varios días todavía no es "sin actualizar"; más de eso sí, con palabras', () => {
  const dato = { valor: 18.5, fecha: '2026-10-20', fuente: 'dof' }
  assert.equal(DIAS_SIN_ACTUALIZAR, 4)
  assert.equal(resumenTipoCambio(dato, '2026-10-24').vencido, false)
  const viejo = resumenTipoCambio(dato, '2026-10-26')
  assert.equal(viejo.vencido, true)
  assert.equal(viejo.aviso, 'Sin actualizar desde el 20/10/26')
})

test('lo capturado a mano se dice a mano, y sin dato se avisa en vez de mostrar cero', () => {
  assert.equal(resumenTipoCambio({ valor: 18.5, fecha: '2026-10-26', fuente: 'manual' }, '2026-10-26').fuente, 'capturado a mano')
  assert.equal(resumenTipoCambio({ valor: 18.5, fecha: '2026-10-26', fuente: 'banxico:SF43718' }, '2026-10-26').fuente, 'Banxico')
  for (const nada of [null, undefined, {}, { valor: 0, fecha: '2026-10-26' }, { valor: 'x', fecha: '2026-10-26' }]) {
    const r = resumenTipoCambio(nada, '2026-10-26')
    assert.equal(r.hay, false)
    assert.equal(r.vencido, true)
    assert.equal(r.valor, '')
  }
  assert.equal(fechaCorta('2026-10-26'), '26/10/26')
  assert.equal(fechaCorta(null), '')
})
