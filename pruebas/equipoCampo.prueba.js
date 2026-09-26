// Equipo capturado en campo (SQL 23) y solicitudes de material (SQL 19).
//
// La idea que esto protege: el equipo dejó de ser un requisito para agendar y pasó a ser
// algo que la base **aprende en cada visita**. Puede nacer sin serie —una placa borrada no
// detiene el trabajo— pero no sin nada que lo identifique.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  faltaSerie, descripcionEquipo, textoHorometro, revisarDatosEquipo, datosParaGuardar,
  nombreCombustible, nombreTipoEquipo,
} from '../src/lib/equipoCampo.js'
import { problemaDeSolicitud, nombrePieza, etiquetaEstado } from '../src/lib/solicitudes.js'

test('faltaSerie: la 23 permite guardar sin serie', () => {
  assert.equal(faltaSerie({ numero_serie: null }), true)
  assert.equal(faltaSerie({ numero_serie: '' }), true)
  assert.equal(faltaSerie({ numero_serie: 'ABC123' }), false)
  assert.equal(faltaSerie(null), true)
})

test('descripcionEquipo pone primero lo que sirve para reconocerlo en el sitio', () => {
  // La serie va al final (de hecho no entra): es lo que menos ayuda estando de pie frente
  // a tres generadores.
  assert.equal(
    descripcionEquipo({ marca: 'Generac', modelo: 'SD100', capacidad_kw: 100, ubicacion_equipo: 'azotea' }),
    'Generac SD100 · 100 kW · azotea'
  )
  assert.equal(descripcionEquipo({ marca: 'Generac' }), 'Generac')
  assert.equal(descripcionEquipo({ ubicacion_equipo: 'cuarto de máquinas' }), 'cuarto de máquinas')
})

test('descripcionEquipo: sin nada identificable cae al tipo', () => {
  assert.equal(descripcionEquipo({ tipo: 'generador' }), 'Generador')
  assert.equal(descripcionEquipo(null), '')
})

test('textoHorometro: las horas SIN su fecha no dicen nada', () => {
  // 1,200 horas de hace dos años no es el estado de hoy.
  assert.equal(textoHorometro({ horas_uso: 1200, horas_uso_fecha: '2026-08-01' }), '1,200 h al 01/08/26')
  assert.equal(textoHorometro({ horas_uso: 1200 }), '1,200 h (sin fecha)')
  assert.equal(textoHorometro({ horas_uso: 1200, horas_uso_fecha: null }), '1,200 h (sin fecha)')
})

test('textoHorometro: sin horas capturadas, null', () => {
  assert.equal(textoHorometro({ horas_uso: null }), null)
  assert.equal(textoHorometro({ horas_uso: '' }), null)
  assert.equal(textoHorometro({}), null)
  assert.equal(textoHorometro(null), null)
})

test('textoHorometro: un cero es un dato (equipo nuevo)', () => {
  assert.equal(textoHorometro({ horas_uso: 0, horas_uso_fecha: '2026-08-01' }), '0 h al 01/08/26')
})

test('revisarDatosEquipo: el tipo es lo único obligatorio', () => {
  assert.match(revisarDatosEquipo({}), /tipo/)
  assert.equal(revisarDatosEquipo({ tipo: 'generador', marca: 'Generac' }), null)
})

test('revisarDatosEquipo: SIN SERIE se puede, sin nada que lo identifique no', () => {
  // Un equipo fantasma que nadie reconoce en la siguiente visita es peor que ninguno.
  assert.match(revisarDatosEquipo({ tipo: 'generador' }), /marca, el modelo, la serie o dónde está/)
  // Cualquiera de los cuatro basta.
  assert.equal(revisarDatosEquipo({ tipo: 'generador', numero_serie: 'ABC' }), null)
  assert.equal(revisarDatosEquipo({ tipo: 'generador', modelo: 'SD100' }), null)
  assert.equal(revisarDatosEquipo({ tipo: 'generador', ubicacion_equipo: 'azotea' }), null)
})

test('revisarDatosEquipo: espacios en blanco no identifican nada', () => {
  assert.match(revisarDatosEquipo({ tipo: 'generador', marca: '   ' }), /marca, el modelo/)
})

test('revisarDatosEquipo: la capacidad, si se captura, tiene que ser un número', () => {
  assert.match(revisarDatosEquipo({ tipo: 'generador', marca: 'X', capacidad_kw: '0' }), /mayor que cero/)
  assert.match(revisarDatosEquipo({ tipo: 'generador', marca: 'X', capacidad_kw: 'abc' }), /número/)
  assert.equal(revisarDatosEquipo({ tipo: 'generador', marca: 'X', capacidad_kw: '' }), null)   // vacía se puede
  assert.equal(revisarDatosEquipo({ tipo: 'generador', marca: 'X', capacidad_kw: '22' }), null)
})

test('revisarDatosEquipo: un año con dedazo se atrapa', () => {
  assert.match(revisarDatosEquipo({ tipo: 'generador', marca: 'X', anio: '202' }), /año/)
  assert.match(revisarDatosEquipo({ tipo: 'generador', marca: 'X', anio: '20266' }), /año/)
  assert.equal(revisarDatosEquipo({ tipo: 'generador', marca: 'X', anio: '2019' }), null)
})

test('datosParaGuardar: NINGUNA cadena vacía sale a la base', () => {
  // Postgres no acepta '' en columnas numéricas, y una serie vacía chocaría con la
  // siguiente en el índice único: `equipos_sin_serie()` busca nulos.
  const r = datosParaGuardar({ tipo: 'generador', marca: 'Generac', modelo: '', numero_serie: '   ', capacidad_kw: '' })
  assert.deepEqual(Object.keys(r).sort(), ['marca', 'tipo'])
  for (const v of Object.values(r)) assert.notEqual(v, '')
})

test('datosParaGuardar manda la capacidad y el año como NÚMEROS', () => {
  const r = datosParaGuardar({ tipo: 'generador', marca: 'X', capacidad_kw: '22.5', anio: '2019' })
  assert.equal(r.capacidad_kw, 22.5)
  assert.equal(typeof r.capacidad_kw, 'number')
  assert.equal(r.anio, 2019)
  assert.equal(typeof r.anio, 'number')
})

test('datosParaGuardar recorta los espacios de lo que sí va', () => {
  assert.equal(datosParaGuardar({ marca: '  Generac  ' }).marca, 'Generac')
})

test('nombreCombustible y nombreTipoEquipo en palabras', () => {
  assert.equal(nombreCombustible('gas_lp'), 'Gas LP')
  assert.equal(nombreCombustible(null), null)
  assert.equal(nombreTipoEquipo('solar'), 'Sistema solar')
  assert.equal(nombreTipoEquipo('raro'), 'raro')   // una clave nueva no deja la pantalla en blanco
})

// ---- solicitudes de material (el técnico pide, sin ver precios) ----

test('problemaDeSolicitud: hace falta una pieza o una descripción', () => {
  assert.match(problemaDeSolicitud({ cantidad: 1 }), /catálogo o escribe una descripción/)
  assert.match(problemaDeSolicitud({ descripcion: '   ', cantidad: 1 }), /catálogo/)
  // Del catálogo, o libre si la pieza no existe todavía.
  assert.equal(problemaDeSolicitud({ productoId: 'p1', cantidad: 1 }), null)
  assert.equal(problemaDeSolicitud({ descripcion: 'Empaque de cabeza', cantidad: 1 }), null)
})

test('problemaDeSolicitud: la cantidad tiene que ser mayor que cero', () => {
  for (const cantidad of [0, -1, '', 'abc', null]) {
    assert.match(problemaDeSolicitud({ productoId: 'p1', cantidad }), /mayor que cero/, `falló con ${cantidad}`)
  }
  assert.equal(problemaDeSolicitud({ productoId: 'p1', cantidad: '2' }), null)
})

test('nombrePieza: del catálogo o la descripción libre', () => {
  assert.equal(nombrePieza({ sku: 'FIL-1', nombre: 'Filtro' }), 'FIL-1 — Filtro')
  assert.equal(nombrePieza({ descripcion_libre: 'Empaque raro' }), 'Empaque raro')
  assert.equal(nombrePieza({}), 'Pieza')
})

test('etiquetaEstado: estados con palabra', () => {
  assert.equal(etiquetaEstado('pendiente'), 'Pendiente')
  assert.equal(etiquetaEstado('atendida'), 'Atendida')
  assert.equal(etiquetaEstado('descartada'), 'Descartada')
  assert.equal(etiquetaEstado('raro'), 'raro')
})
