import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  normalizarComisiones, agruparPorMes, filtrar, fechaCorta, nombreServicio, etiquetaRol, validarTarifa
} from '../src/lib/comisiones.js'

const ordenes = [
  { orden_id: 'a', folio: 10, fecha: '2026-10-05', tipo_servicio: 'preventivo', rol: 'responsable', estado: 'pagada', monto: 600 },
  { orden_id: 'b', folio: 11, fecha: '2026-10-08', tipo_servicio: 'correctivo', rol: 'ayudante', estado: 'aprobada', monto: 400 },
  { orden_id: 'c', folio: 12, fecha: '2026-10-09', tipo_servicio: 'preventivo', rol: 'responsable', estado: 'en_revision', monto: null },
  { orden_id: 'd', folio: 9, fecha: '2026-09-28', tipo_servicio: 'instalacion', rol: 'responsable', estado: 'pagada', monto: 900 }
]

test('normaliza lo que llega de la base y descarta estados desconocidos', () => {
  const n = normalizarComisiones({ resumen: { por_cobrar: '400', pagado_mes: 600 }, ordenes: [...ordenes, { estado: 'raro' }] })
  assert.equal(n.resumen.por_cobrar, 400)
  assert.equal(n.resumen.en_revision, 0)
  assert.equal(n.ordenes.length, 4)
  assert.deepEqual(normalizarComisiones(null).ordenes, [])
})

test('agrupa por mes, el más reciente primero, y una orden en revisión no suma', () => {
  const g = agruparPorMes(ordenes)
  assert.equal(g.length, 2)
  assert.equal(g[0].titulo, 'Octubre 2026')
  assert.equal(g[0].total, 1000)
  assert.equal(g[0].en_revision, 1)
  assert.equal(g[1].titulo, 'Septiembre 2026')
  assert.equal(g[1].total, 900)
})

test('filtra por estado', () => {
  assert.equal(filtrar(ordenes, 'todas').length, 4)
  assert.equal(filtrar(ordenes, 'en_revision').length, 1)
  assert.equal(filtrar(ordenes, 'pagada').length, 2)
})

test('la fecha se lee como texto, sin correrse un día', () => {
  assert.equal(fechaCorta('2026-10-01'), '1 oct')
  assert.equal(fechaCorta(''), '')
})

test('nombres en palabras', () => {
  assert.equal(nombreServicio('visita_tecnica'), 'Visita técnica')
  assert.equal(nombreServicio(null), 'Servicio')
  assert.equal(etiquetaRol('ayudante'), 'Ayudante')
  assert.equal(etiquetaRol('responsable'), 'Responsable')
})

test('validar una tarifa', () => {
  assert.equal(validarTarifa({ tipo_servicio: 'preventivo', rol: 'responsable', monto: '0', vigente_desde: '2026-10-01' }), '')
  assert.match(validarTarifa({ tipo_servicio: 'otro', rol: 'responsable', monto: '1', vigente_desde: '2026-10-01' }), /servicio/)
  assert.match(validarTarifa({ tipo_servicio: 'preventivo', rol: 'responsable', monto: '', vigente_desde: '2026-10-01' }), /monto/)
  assert.match(validarTarifa({ tipo_servicio: 'preventivo', rol: 'responsable', monto: '-5', vigente_desde: '2026-10-01' }), /monto/)
})
