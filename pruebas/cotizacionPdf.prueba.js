import { test } from 'node:test'
import assert from 'node:assert/strict'
import { sePuedeEditar, filasDePartidas, nombreArchivoCotizacion, vigenteHasta } from '../src/lib/cotizacionPdf.js'

test('solo se edita lo que el cliente no ha aceptado', () => {
  assert.equal(sePuedeEditar('borrador'), true)
  assert.equal(sePuedeEditar('enviada'), true)
  for (const e of ['aceptada', 'rechazada', 'vencida', undefined]) assert.equal(sePuedeEditar(e), false)
})

test('el archivo se llama COT-<folio>.pdf', () => {
  assert.equal(nombreArchivoCotizacion({ folio: 42 }), 'COT-42.pdf')
})

test('una partida incluida se lee "Incluido", no $0.00', () => {
  const [f] = filasDePartidas([{ descripcion: 'Filtro', cantidad: 2, precio_unitario: 0, importe: 0, incluida: true }])
  assert.equal(f.precio, 'Incluido')
  assert.equal(f.importe, 'Incluido')
})

test('una partida normal muestra su precio e importe en pesos', () => {
  const [f] = filasDePartidas([{ sku: 'A1', descripcion: 'Servicio', cantidad: 1, precio_unitario: 4500, importe: 4500 }])
  assert.match(f.precio, /4,500\.00/)
  assert.match(f.importe, /4,500\.00/)
  assert.equal(f.sku, 'A1')
})

test('sin importe guardado se calcula de cantidad por precio', () => {
  const [f] = filasDePartidas([{ descripcion: 'x', cantidad: 3, precio_unitario: 100 }])
  assert.match(f.importe, /300\.00/)
})

test('sin partidas no truena', () => {
  assert.deepEqual(filasDePartidas(null), [])
})

test('la vigencia por omisión es de 15 días', () => {
  assert.equal(vigenteHasta({ fecha: '2026-10-01' }), '2026-10-16')
  assert.equal(vigenteHasta({ fecha: '2026-10-01', vigencia_dias: 30 }), '2026-10-31')
})

import { folioCotizacion, fechaCorta, tituloDeCotizacion, datosDelCliente, datosDelEquipo, lineasDeCondiciones } from '../src/lib/cotizacionPdf.js'

test('el folio se arma como PMX-COT-AAAAMMDD-0001', () => {
  assert.equal(folioCotizacion({ fecha: '2026-10-05', folio: 1 }), 'PMX-COT-20261005-0001')
  assert.equal(folioCotizacion({ fecha: '2026-10-05', folio: 1234 }), 'PMX-COT-20261005-1234')
})

test('la fecha corta es dd/mm/aaaa', () => {
  assert.equal(fechaCorta('2026-10-05'), '05/10/2026')
  assert.equal(fechaCorta(null), '')
})

test('el título dice el tipo de cotización', () => {
  assert.equal(tituloDeCotizacion('venta'), 'COTIZACIÓN — VENTA DE EQUIPO')
  assert.equal(tituloDeCotizacion('loQueSea'), 'COTIZACIÓN — SERVICIOS')
})

test('los datos del cliente omiten lo vacío, sin dejar "[ ]"', () => {
  const pares = datosDelCliente({ fecha: '2026-10-05', folio: 3, vigencia_dias: 15 },
    { nombre: 'Hotel X', telefono: '9991112233', direccion: 'Calle 1', municipio: 'Cancún' })
  const etiquetas = pares.map(([e]) => e)
  assert.ok(etiquetas.includes('Cliente') && etiquetas.includes('Dirección'))
  assert.ok(!etiquetas.includes('Correo') && !etiquetas.includes('Contacto') && !etiquetas.includes('RFC'))
  assert.equal(pares.find(([e]) => e === 'Dirección')[1], 'Calle 1, Cancún')
})

test('los datos del equipo salen solo si existen', () => {
  assert.deepEqual(datosDelEquipo(null), [])
  const p = datosDelEquipo({ marca: 'Cummins', modelo: '4BTAA3.3', capacidad_kw: 60, atributos: { combustible: 'diesel' } })
  assert.deepEqual(p.map(([e]) => e), ['Marca', 'Modelo', 'Capacidad', 'Combustible'])
  assert.equal(p.find(([e]) => e === 'Combustible')[1], 'Diésel')
})

test('las condiciones se separan por renglón y sin vacíos', () => {
  assert.deepEqual(lineasDeCondiciones('a\n\n b \n'), ['a', 'b'])
  assert.deepEqual(lineasDeCondiciones(null), [])
})
