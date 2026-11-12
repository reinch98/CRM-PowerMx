import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  sumarMeses, finDePoliza, planDeVisitas, alcanceDeEquipo, totalesPoliza, estadoPoliza, estadoVisita,
  resumenPolizas, filtrarPolizas, faltasPoliza, buscarEquipos
} from '../src/lib/polizas.js'

test('meses como Postgres: fin de mes se recorta, el año avanza', () => {
  assert.equal(sumarMeses('2026-01-31', 1), '2026-02-28')
  assert.equal(sumarMeses('2028-01-31', 1), '2028-02-29')
  assert.equal(sumarMeses('2026-11-10', 3), '2027-02-10')
  assert.equal(finDePoliza('2026-11-10'), '2027-11-09')
  assert.equal(finDePoliza('2026-03-01'), '2027-02-28')
})

test('plan de visitas: los mismos casos que la prueba SQL 97', () => {
  const b = planDeVisitas('basica', 'aire', '2026-11-10')
  assert.deepEqual(b.map(v => [v.tipo, v.fecha]), [['menor', '2026-11-10'], ['mayor', '2027-05-10']])
  const e = planDeVisitas('estandar', 'liquido', '2026-11-10')
  assert.deepEqual(e.map(v => v.tipo), ['menor', 'inspeccion', 'mayor', 'inspeccion'])
  assert.equal(planDeVisitas('integral', 'aire', '2026-11-10').length, 4)
  const i = planDeVisitas('integral', 'liquido', '2026-11-10')
  assert.equal(i.length, 12)
  assert.equal(i[6].tipo, 'mayor')
  assert.equal(i[6].banco_carga, true)
  assert.equal(i.filter(v => v.banco_carga).length, 1)
  assert.deepEqual(planDeVisitas('', 'aire', '2026-11-10'), [])
})

test('alcance según el equipo', () => {
  assert.equal(alcanceDeEquipo({ capacidad_kw: 24, atributos: { enfriamiento: 'air_cooled' } }), 'aire')
  assert.equal(alcanceDeEquipo({ capacidad_kw: 22, atributos: { enfriamiento: 'liquid_cooled' } }), 'liquido')
  assert.equal(alcanceDeEquipo({ capacidad_kw: 20, atributos: { combustible: 'diesel' } }), 'liquido')
  assert.equal(alcanceDeEquipo({ capacidad_kw: 80 }), 'liquido')
  assert.equal(alcanceDeEquipo({ capacidad_kw: 10, atributos: {} }), 'aire')
})

test('totales con IVA: 14,000 → 16,240 como en la base', () => {
  assert.deepEqual(totalesPoliza(14000), { subtotal: 14000, iva: 2240, total: 16240 })
  assert.deepEqual(totalesPoliza(''), { subtotal: 0, iva: 0, total: 0 })
})

const hoy = '2026-11-10'
test('estado de la póliza con palabra', () => {
  assert.equal(estadoPoliza({ estado: 'vigente', inicio: '2026-01-01', fin: '2026-12-31' }, hoy).clave, 'vigente')
  const pv = estadoPoliza({ estado: 'vigente', inicio: '2025-11-20', fin: '2026-11-19' }, hoy)
  assert.equal(pv.clave, 'por_vencer')
  assert.equal(pv.etiqueta, 'Vence en 9 días')
  assert.equal(estadoPoliza({ estado: 'vigente', inicio: '2025-11-20', fin: '2026-11-19', renovada: true }, hoy).clave, 'vigente')
  assert.equal(estadoPoliza({ estado: 'vigente', inicio: '2025-01-01', fin: '2025-12-31' }, '2026-01-05').clave, 'vencida')
  assert.equal(estadoPoliza({ estado: 'cancelada', fin: '2027-01-01' }, hoy).etiqueta, 'Cancelada')
  assert.equal(estadoPoliza({ estado: 'vigente', inicio: '2026-12-01', fin: '2027-11-30' }, hoy).clave, 'por_iniciar')
})

test('estado de la visita: atrasada solo si pasó su fecha sin cita futura', () => {
  assert.equal(estadoVisita({ estado: 'pendiente', fecha: '2026-12-01' }, hoy).atrasada, false)
  assert.equal(estadoVisita({ estado: 'pendiente', fecha: '2026-11-01' }, hoy).etiqueta, 'Atrasada')
  assert.equal(estadoVisita({ estado: 'agendada', fecha: '2026-11-01', cita_estado: 'por_programar' }, hoy).atrasada, true)
  const futura = estadoVisita({ estado: 'agendada', fecha: '2026-11-01', cita_estado: 'programada', cita_fecha: '2026-11-15' }, hoy)
  assert.equal(futura.atrasada, false)
  assert.equal(futura.etiqueta, 'Cita el 15/11/26')
  assert.equal(estadoVisita({ estado: 'realizada', fecha: '2026-01-01', realizada_en: '2026-01-03' }, hoy).etiqueta, 'Hecha el 03/01/26')
  assert.equal(estadoVisita({ estado: 'omitida', fecha: '2026-01-01' }, hoy).atrasada, false)
})

test('resumen y filtros', () => {
  const lista = [
    { estado: 'vigente', inicio: '2026-01-01', fin: '2026-12-31', visitas: [{ estado: 'pendiente', fecha: '2026-10-01' }] },
    { estado: 'vigente', inicio: '2025-11-20', fin: '2026-11-19', visitas: [] },
    { estado: 'vigente', inicio: '2025-01-01', fin: '2025-12-31', visitas: [] },
    { estado: 'cancelada', inicio: '2026-01-01', fin: '2026-12-31', visitas: [{ estado: 'pendiente', fecha: '2026-10-01' }] }
  ]
  assert.deepEqual(resumenPolizas(lista, hoy), { vigentes: 2, porVencer: 1, atrasadas: 1, vencidas: 1 })
  assert.equal(filtrarPolizas(lista, 'vigentes', hoy).length, 2)
  assert.equal(filtrarPolizas(lista, 'atender', hoy).length, 3)
  assert.equal(filtrarPolizas(lista, 'todas', hoy).length, 4)
})

test('faltas y búsqueda de equipos', () => {
  assert.equal(faltasPoliza({}).length, 4)
  assert.deepEqual(faltasPoliza({ equipo_id: 'e', nivel: 'basica', inicio: hoy, subtotal: '8000' }), [])
  const eq = [{ marca: 'Generac', modelo: 'G0072101', clientes: { nombre: 'Yanue' } }, { marca: 'Cummins', clientes: { nombre: 'Hotel' } }]
  assert.equal(buscarEquipos(eq, 'yan').length, 1)
  assert.equal(buscarEquipos(eq, '').length, 2)
})
