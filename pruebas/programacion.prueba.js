import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  nombreMes, mesSiguiente, primeroDeMes, fechaLarga, queVisita, resumenMes, pendientesDelMes,
  porZona, fechaPropuesta, mensajeCoordinar, mesInicial
} from '../src/lib/programacion.js'

test('meses: nombre, primero y siguiente (con cambio de año)', () => {
  assert.equal(nombreMes('2026-12-01'), 'diciembre')
  assert.equal(primeroDeMes('2026-11-26'), '2026-11-01')
  assert.equal(mesSiguiente('2026-12-01'), '2027-01-01')
  assert.equal(mesSiguiente('2026-11-01'), '2026-12-01')
  assert.equal(fechaLarga('2026-12-03'), 'jueves 3 de diciembre')
  assert.equal(fechaLarga(null), 'sin fecha')
  assert.equal(mesInicial('2026-11-26'), '2026-12-01')
  assert.equal(mesInicial('2026-12-05'), '2026-12-01')
  assert.equal(mesInicial('2026-12-20'), '2027-01-01')
})

test('qué visita es, en palabras', () => {
  assert.equal(queVisita({ visita_tipo: 'menor', visita: 1, visitas: 4, poliza: 4 }), 'Servicio menor · visita 1 de 4 · POL-4')
  assert.equal(queVisita({ visita_tipo: 'inspeccion', visita: 2, visitas: 4, poliza: 4 }), 'Visita de inspección · visita 2 de 4 · POL-4')
  assert.equal(queVisita({ tipo_servicio: 'correctivo' }), 'Servicio correctivo')
  assert.equal(queVisita({}), 'Mantenimiento preventivo')
})

test('resumen del mes y lo que falta', () => {
  const r = resumenMes({
    citas: [{ estado: 'por_programar' }, { estado: 'por_programar' }, { estado: 'programada' }],
    sin_cita: [{}], sugeridos: [{}, {}]
  })
  assert.deepEqual(r, { porProgramar: 2, programadas: 1, sinCita: 1, sugeridos: 2 })
  assert.equal(pendientesDelMes(r), 3)
  assert.deepEqual(resumenMes(null), { porProgramar: 0, programadas: 0, sinCita: 0, sugeridos: 0 })
})

test('agrupa por zona, "Sin zona" al final', () => {
  const g = porZona([{ zona: 'PROGRESO' }, { zona: '' }, { zona: 'CHELEM-CHUBURNA' }, { zona: 'PROGRESO' }])
  assert.deepEqual(g.map(x => [x.zona, x.lista.length]), [['CHELEM-CHUBURNA', 1], ['PROGRESO', 2], ['Sin zona', 1]])
})

test('fecha propuesta: la de la póliza, nunca antes de mañana', () => {
  assert.equal(fechaPropuesta({ fecha_sugerida: '2026-12-01' }, '2026-11-26'), '2026-12-01')
  assert.equal(fechaPropuesta({ fecha_sugerida: '2026-11-01' }, '2026-11-26'), '2026-11-27')
  assert.equal(fechaPropuesta({}, '2026-11-30'), '2026-12-01')
})

test('mensaje para coordinar: póliza y sin póliza', () => {
  const p = mensajeCoordinar({ contacto: 'MARTHA CHAFIN', poliza: 4, visita_tipo: 'menor', visita: 1, visitas: 4,
    equipo: 'Generac G0070431 22 kW', equipo_tipo: 'generador' }, '2026-12-01')
  assert.match(p, /^Hola Martha,/)
  assert.match(p, /En diciembre le toca el servicio menor de su generador Generac G0070431 22 kW \(visita 1 de 4 de su póliza\)\./)
  assert.match(p, /¿Qué día y horario le acomodan\?/)
  const s = mensajeCoordinar({ equipo: 'Kohler 14 kW', equipo_tipo: 'generador' }, '2027-01-01')
  assert.match(s, /^Hola,/)
  assert.match(s, /En enero le toca el mantenimiento preventivo de su generador Kohler 14 kW\./)
  assert.match(s, /cotización/)
})
