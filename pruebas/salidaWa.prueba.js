// Cola de salida y campañas de WhatsApp (SQL 56 y 57): lo que la pantalla traduce a palabras.
// Lo que aquí se cuida: que nada "aprobado pero esperando a Meta" se vea como si ya fuera a
// salir, que las variables de una plantilla se escriban como Meta las acepta, y que el
// resultado de una campaña diga lo más importante primero (una BAJA pesa más que un "respondió").
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  etiquetaEstado, etiquetaOrigen, agruparCola, esperanPorPlantilla, leerVariables, variablesValidas,
  nombreMes, mesesCampana, mesInicial, resultadoEnvio, porcentaje,
} from '../src/lib/salidaWa.js'

test('estados y orígenes en palabras', () => {
  assert.equal(etiquetaEstado('por_aprobar'), 'Por aprobar')
  assert.equal(etiquetaEstado('sin_confirmar'), 'Sin confirmar')
  assert.equal(etiquetaEstado('leido'), 'Leído')
  assert.equal(etiquetaOrigen('aviso'), 'Aviso de cita')
  assert.equal(etiquetaEstado(undefined), '—')
})

test('agruparCola separa lo que espera a Meta de lo que ya sale', () => {
  const g = agruparCola([
    { id: 1, estado: 'por_aprobar', plantilla: 'cita_confirmada', plantilla_aprobada: false },
    { id: 2, estado: 'pendiente', plantilla: 'cita_confirmada', plantilla_aprobada: false },
    { id: 3, estado: 'pendiente', plantilla: 'cita_confirmada', plantilla_aprobada: true },
    { id: 4, estado: 'pendiente', plantilla: null },                 // texto libre
    { id: 5, estado: 'fallido' }, { id: 6, estado: 'sin_confirmar' },
  ])
  assert.deepEqual(g.porAprobar.map(f => f.id), [1])
  assert.deepEqual(g.esperanMeta.map(f => f.id), [2])
  assert.deepEqual(g.enCamino.map(f => f.id), [3, 4])
  assert.deepEqual(g.problemas.map(f => f.id), [5, 6])
})

test('plantilla_aprobada nula también espera (no se da por aprobada)', () => {
  const g = agruparCola([{ estado: 'pendiente', plantilla: 'x' }])
  assert.equal(g.esperanMeta.length, 1)
})

test('esperanPorPlantilla cuenta y ordena', () => {
  assert.deepEqual(esperanPorPlantilla([{ plantilla: 'a' }, { plantilla: 'b' }, { plantilla: 'b' }]), [['b', 2], ['a', 1]])
})

test('leerVariables separa por comas y quita llaves', () => {
  assert.deepEqual(leerVariables('{{nombre}}, servicio ,Fecha'), ['nombre', 'servicio', 'fecha'])
  assert.deepEqual(leerVariables(''), [])
})

test('una variable con espacios NO se parte en varias: llega entera y se rechaza', () => {
  const v = leerVariables('nombre del cliente, fecha')
  assert.deepEqual(v, ['nombre del cliente', 'fecha'])
  assert.equal(variablesValidas(v), false)
})

test('variablesValidas: solo minúsculas, números y guion bajo, empezando con letra', () => {
  assert.equal(variablesValidas(['nombre', 'fecha_cita', 'equipo2']), true)
  assert.equal(variablesValidas(['nombre del cliente']), false)
  assert.equal(variablesValidas(['1nombre']), false)
  assert.equal(variablesValidas(['nómbre']), false)
})

test('meses de la campaña: oct-2026 a sep-2027, con cambio de año', () => {
  const m = mesesCampana()
  assert.equal(m.length, 12)
  assert.equal(m[0], '2026-10')
  assert.equal(m[3], '2027-01')
  assert.equal(m[11], '2027-09')
  assert.equal(nombreMes('2027-01'), 'Enero 2027')
})

test('mesInicial: el mes en curso si está en la campaña; si no, el primero', () => {
  assert.equal(mesInicial(new Date(2026, 9, 3)), '2026-10')
  assert.equal(mesInicial(new Date(2027, 2, 15)), '2027-03')
  assert.equal(mesInicial(new Date(2028, 0, 1)), '2026-10')
})

test('resultadoEnvio: lo más importante primero', () => {
  assert.equal(resultadoEnvio({ baja: true, respondio: true, cita: true }), 'Pidió BAJA')
  assert.equal(resultadoEnvio({ cita: true, respondio: true }), 'Sacó cita')
  assert.equal(resultadoEnvio({ respondio: true }), 'Respondió')
  assert.equal(resultadoEnvio({ estado: 'omitido', motivo: 'pidió BAJA' }), 'Omitido: pidió BAJA')
  assert.equal(resultadoEnvio({ estado: 'aprobado', enviado_en: '2026-10-05T10:00' }), 'Enviado, sin respuesta')
  assert.equal(resultadoEnvio({ estado: 'aprobado' }), 'En la cola')
  assert.equal(resultadoEnvio({ estado: 'propuesto' }), 'Por proponer')
})

test('porcentaje sin dividir entre cero', () => {
  assert.equal(porcentaje(1, 4), '25 %')
  assert.equal(porcentaje(0, 0), '—')
})
