import { test } from 'node:test'
import assert from 'node:assert/strict'
import { ajustarEn, datosEquipoOrden, fechaCorta, TITULO_CORTO_STRING } from '../src/lib/documentos.js'
import { COLUMNAS_STRING } from '../src/lib/revision.js'
import { alturaDeCelda } from '../src/lib/pdfEstilo.js'

test('una foto vertical se ajusta dentro del marco sin deformarse', () => {
  const c = ajustarEn(1080, 1350, 90, 67.5)
  assert.ok(Math.abs(c.w / c.h - 1080 / 1350) < 1e-9)
  assert.ok(c.w <= 90 && c.h <= 67.5 + 1e-9)
  assert.ok(c.dx > 0, 'queda centrada: sobra ancho a los lados')
  assert.equal(Math.round(c.dy), 0)
})

test('una foto horizontal 4:3 llena el marco 4:3', () => {
  const c = ajustarEn(1200, 900, 90, 67.5)
  assert.equal(Math.round(c.w), 90)
  assert.equal(Math.round(c.h * 10) / 10, 67.5)
  assert.equal(Math.round(c.dx), 0)
})

test('sin medidas de la foto se usa toda la caja en vez de tronar', () => {
  assert.deepEqual(ajustarEn(0, 0, 50, 40), { dx: 0, dy: 0, w: 50, h: 40 })
})

test('datos del equipo de la orden: lo vacío no sale, pero la serie pendiente sí se dice', () => {
  const p = datosEquipoOrden({ marca: 'Cummins', modelo: '4BTAA3.3', capacidad_kw: 60, numero_serie: '' }, { horas_equipo: 1200 }, { combustible: 'diesel' })
  const mapa = Object.fromEntries(p)
  assert.equal(mapa.Marca, 'Cummins')
  assert.equal(mapa['No. de serie'], 'Pendiente')
  assert.equal(mapa.Combustible, 'Diésel')
  assert.equal(mapa['Horómetro'], '1200 h')
  assert.ok(!('Ubicación' in mapa))
})

test('sin equipo no hay sección de datos del equipo', () => {
  assert.deepEqual(datosEquipoOrden(null, {}, null), [])
  assert.deepEqual(datosEquipoOrden({}, {}, null), [])
})

test('la fecha corta de la orden es dd/mm/aaaa', () => {
  assert.equal(fechaCorta('2026-09-24'), '24/09/2026')
  assert.equal(fechaCorta(undefined), '')
})

test('toda columna de string tiene su encabezado corto', () => {
  for (const [k] of COLUMNAS_STRING) assert.ok(TITULO_CORTO_STRING[k], `falta el encabezado corto de ${k}`)
})

test('una celda más alta cuando tiene más renglones', () => {
  assert.ok(alturaDeCelda(3) > alturaDeCelda(1))
  assert.equal(alturaDeCelda(0), alturaDeCelda(1))
})
