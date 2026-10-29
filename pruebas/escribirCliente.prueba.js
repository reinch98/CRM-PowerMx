// Escribirle a un cliente con una plantilla (SQL 93): qué plantillas se ofrecen y qué datos faltan.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { plantillasParaEscribir, etiquetaVariable, datosQueFaltan } from '../src/lib/salidaWa.js'

const p = (nombre, extra = {}) => ({ nombre, estado: 'aprobada', encabezado: 'ninguno', uso: 'campana:x', variables: ['nombre'], ...extra })

test('solo se ofrecen las aprobadas, sin documento y que no salen solas', () => {
  const lista = plantillasParaEscribir([
    p('seguimiento_pendiente'),
    p('borrador', { estado: 'borrador' }),
    p('orden_servicio_lista', { uso: 'orden', encabezado: 'documento' }),
    p('cita_confirmada', { uso: 'aviso:confirmacion:cliente' }),
    p('con_pdf', { encabezado: 'documento' }),
  ])
  assert.deepEqual(lista.map(x => x.nombre), ['seguimiento_pendiente'])
})

test('cada dato tiene su nombre en palabras', () => {
  assert.equal(etiquetaVariable('nombre'), 'Nombre del cliente')
  assert.equal(etiquetaVariable('equipo'), 'Equipo')
  assert.equal(etiquetaVariable('fecha_visita'), 'Fecha visita')
})

test('dice qué datos faltan, sin contar los que son puro espacio', () => {
  const pl = p('x', { variables: ['nombre', 'equipo'] })
  assert.deepEqual(datosQueFaltan(pl, { nombre: 'Ana', equipo: '   ' }), ['equipo'])
  assert.deepEqual(datosQueFaltan(pl, { nombre: 'Ana', equipo: 'Generac' }), [])
  assert.deepEqual(datosQueFaltan(null, {}), [])
})
