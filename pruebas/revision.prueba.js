// La revisión en sitio (SQL 24): los dos formatos de mantenimiento, lo que aplica a cada
// equipo y lo que impide cerrar la orden.
//
// El catálogo de puntos vive en `revision.js` y lo comparten la pantalla del técnico y el
// PDF: si uno dedujera por su cuenta qué aplica, el papel mostraría puntos que el técnico
// nunca vio. Estas pruebas son la red de esa promesa.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  FORMATO_SOLAR, FORMATO_GENERADOR, aplica, seccionesVisibles, avanceSeccion,
  seguridadSinControl, malosSinFoto, veredictoString, dictamenSugerido, loQueFalta,
  contextoDeRevision, formatoDe, revisionDe, avisosMediciones, placaGuardada,
} from '../src/lib/revision.js'

const puntos = ctx => seccionesVisibles(FORMATO_GENERADOR, ctx).reduce((n, s) => n + s.puntos.length, 0)
const claves = ctx => seccionesVisibles(FORMATO_GENERADOR, ctx).flatMap(s => s.puntos.map(p => p.clave))

// Una revisión: `puntos` son las respuestas por clave ({ v: 'B'|'R'|'M'|'NA', obs, fotos }).
const conPuntos = p => ({ puntos: p })

// ---- qué aplica ----

test('aplica: sin condición, siempre', () => {
  assert.equal(aplica({ clave: '2.1' }), true)
  assert.equal(aplica({ clave: '2.1' }, { combustible: 'diesel' }), true)
})

test('aplica: una lista filtra por combustible', () => {
  const soloDiesel = { solo: ['diesel'] }
  assert.equal(aplica(soloDiesel, { combustible: 'diesel' }), true)
  assert.equal(aplica(soloDiesel, { combustible: 'gasolina' }), false)
})

test('aplica: sin combustible conocido, mejor preguntar de menos que inventar', () => {
  assert.equal(aplica({ solo: ['diesel'] }, {}), false)
  assert.equal(aplica({ solo: ['diesel'] }, { combustible: '' }), false)
})

test('aplica: un texto mira una bandera del contexto', () => {
  assert.equal(aplica({ solo: 'bess' }, { bess: true }), true)
  assert.equal(aplica({ solo: 'bess' }, { bess: false }), false)
  assert.equal(aplica({ solo: 'mayor' }, { mayor: true }), true)
})

test('el formato del generador se desglosa por combustible', () => {
  // Los números que Caña revisó. Si un cambio los mueve, es a propósito o es un error.
  assert.equal(puntos({ combustible: 'diesel' }), 50)
  assert.equal(puntos({ combustible: 'gasolina' }), 51)
  assert.equal(puntos({ combustible: 'gas_lp' }), 54)
  assert.equal(puntos({ combustible: 'gas_natural' }), 53)
})

test('el diésel no lleva bujías y el gas sí', () => {
  const diesel = claves({ combustible: 'diesel' })
  const lp = claves({ combustible: 'gas_lp' })
  assert.equal(diesel.includes('4.1'), false)   // bujías: estado y separación
  assert.equal(lp.includes('4.1'), true)
  assert.equal(claves({ combustible: 'gasolina' }).includes('4.1'), true)
})

test('el vaporizador es solo de gas LP', () => {
  assert.equal(claves({ combustible: 'gas_lp' }).includes('3.15'), true)
  assert.equal(claves({ combustible: 'gas_natural' }).includes('3.15'), false)
})

test('la trampa de agua y los dos filtros son del diésel', () => {
  for (const c of ['3.4', '3.5', '3.6', '3.7']) {
    assert.equal(claves({ combustible: 'diesel' }).includes(c), true, `falta ${c} en diésel`)
    assert.equal(claves({ combustible: 'gasolina' }).includes(c), false, `${c} no debería salir en gasolina`)
  }
})

test('el megóhmetro de devanados solo va en el servicio mayor (tipo C)', () => {
  assert.equal(claves({ combustible: 'diesel' }).includes('8.4'), false)
  assert.equal(claves({ combustible: 'diesel', mayor: true }).includes('8.4'), true)
  assert.equal(puntos({ combustible: 'diesel', mayor: true }), 51)
})

test('solar: el BESS solo existe si el equipo tiene baterías', () => {
  const sin = seccionesVisibles(FORMATO_SOLAR, {}).reduce((n, s) => n + s.puntos.length, 0)
  const con = seccionesVisibles(FORMATO_SOLAR, { bess: true }).reduce((n, s) => n + s.puntos.length, 0)
  assert.equal(sin, 25)
  assert.equal(con, 32)   // los 32 puntos del formato resumido
})

test('solar: electrolito y densidad solo con plomo inundado', () => {
  const con = seccionesVisibles(FORMATO_SOLAR, { bess: true, plomo: true }).flatMap(s => s.puntos.map(p => p.clave))
  const sin = seccionesVisibles(FORMATO_SOLAR, { bess: true }).flatMap(s => s.puntos.map(p => p.clave))
  assert.equal(con.includes('4.8'), true)
  assert.equal(sin.includes('4.8'), false)
})

test('seccionesVisibles no deja secciones vacías', () => {
  for (const s of seccionesVisibles(FORMATO_GENERADOR, { combustible: 'diesel' })) {
    assert.ok(s.puntos.length > 0, `la sección ${s.clave} quedó vacía`)
  }
})

test('la sección 1 es SIEMPRE la que bloquea, en los dos formatos', () => {
  // Convención del proyecto: el trigger de la 24 busca las claves `1.%`.
  for (const formato of [FORMATO_SOLAR, FORMATO_GENERADOR]) {
    const bloquea = formato.filter(s => s.bloquea)
    assert.equal(bloquea.length, 1)
    assert.equal(bloquea[0].clave, '1')
    for (const p of bloquea[0].puntos) assert.match(p.clave, /^1\./)
  }
})

test('las claves de los puntos no se repiten', () => {
  for (const formato of [FORMATO_SOLAR, FORMATO_GENERADOR]) {
    const todas = formato.flatMap(s => s.puntos.map(p => p.clave))
    assert.equal(new Set(todas).size, todas.length)
  }
})

// ---- la regla que suspende el servicio ----

test('seguridadSinControl: un "Malo" de seguridad sin control escrito impide cerrar', () => {
  const datos = conPuntos({ '1.3': { v: 'M', obs: '' } })
  assert.deepEqual(seguridadSinControl(datos, FORMATO_SOLAR), ['1.3'])
})

test('seguridadSinControl: no es un callejón, basta escribir el control', () => {
  const datos = conPuntos({ '1.3': { v: 'M', obs: 'Se aisló a mano y se etiquetó el interruptor.' } })
  assert.deepEqual(seguridadSinControl(datos, FORMATO_SOLAR), [])
})

test('seguridadSinControl: solo espacios no cuentan como control', () => {
  const datos = conPuntos({ '1.3': { v: 'M', obs: '   ' } })
  assert.deepEqual(seguridadSinControl(datos, FORMATO_SOLAR), ['1.3'])
})

test('seguridadSinControl: un "Malo" fuera de seguridad no bloquea', () => {
  // Un módulo con hot spot es un hallazgo, no un riesgo para la cuadrilla.
  const datos = conPuntos({ '2.2': { v: 'M', obs: '' } })
  assert.deepEqual(seguridadSinControl(datos, FORMATO_SOLAR), [])
})

test('seguridadSinControl también aplica al formato del generador', () => {
  const datos = conPuntos({ '1.2': { v: 'M', obs: '' } })   // fuga de gas antes de arrancar
  assert.deepEqual(seguridadSinControl(datos, FORMATO_GENERADOR), ['1.2'])
})

test('malosSinFoto: todo punto en "Malo" se documenta con fotografía', () => {
  assert.deepEqual(malosSinFoto(conPuntos({ '2.2': { v: 'M' } }), FORMATO_SOLAR), ['2.2'])
  assert.deepEqual(malosSinFoto(conPuntos({ '2.2': { v: 'M', fotos: [] } }), FORMATO_SOLAR), ['2.2'])
  assert.deepEqual(malosSinFoto(conPuntos({ '2.2': { v: 'M', fotos: ['a.jpg'] } }), FORMATO_SOLAR), [])
})

test('malosSinFoto: Regular y Bueno no exigen foto', () => {
  assert.deepEqual(malosSinFoto(conPuntos({ '2.2': { v: 'R' }, '2.3': { v: 'B' } }), FORMATO_SOLAR), [])
})

// ---- veredicto de un string ----

test('veredictoString: aislamiento bajo 1 MΩ no pasa', () => {
  assert.equal(veredictoString({ aisl_pos: '0.5', aisl_neg: '20', voc_medido: '400' }), 'no_pasa')
  assert.equal(veredictoString({ aisl_pos: '20', aisl_neg: '0.2', voc_medido: '400' }), 'no_pasa')
})

test('veredictoString: una Voc fuera de ±10% pide revisar, no condena', () => {
  assert.equal(veredictoString({ voc_teorico: '400', voc_medido: '350', aisl_pos: '50', aisl_neg: '50' }), 'revisar')
  assert.equal(veredictoString({ voc_teorico: '400', voc_medido: '450', aisl_pos: '50', aisl_neg: '50' }), 'revisar')
})

test('veredictoString: dentro del 10% y con buen aislamiento, pasa', () => {
  assert.equal(veredictoString({ voc_teorico: '400', voc_medido: '380', aisl_pos: '50', aisl_neg: '50' }), 'pasa')
  assert.equal(veredictoString({ voc_teorico: '400', voc_medido: '440', aisl_pos: '50', aisl_neg: '50' }), 'pasa')
})

test('veredictoString: el aislamiento manda sobre la Voc', () => {
  assert.equal(veredictoString({ voc_teorico: '400', voc_medido: '350', aisl_pos: '0.1' }), 'no_pasa')
})

test('veredictoString: sin datos suficientes no propone nada', () => {
  assert.equal(veredictoString({}), null)
  assert.equal(veredictoString({ voc_medido: '400' }), null)          // sin aislamiento
  assert.equal(veredictoString({ aisl_pos: '50', aisl_neg: '50' }), null)  // sin Voc medida
  assert.equal(veredictoString(null), null)
})

// ---- dictamen ----

test('dictamenSugerido: todo bien, aprobado', () => {
  assert.equal(dictamenSugerido(conPuntos({ '2.1': { v: 'B' }, '2.2': { v: 'NA' } }), FORMATO_SOLAR), 'aprobado')
  assert.equal(dictamenSugerido(conPuntos({}), FORMATO_SOLAR), 'aprobado')
})

test('dictamenSugerido: un Regular deja el sistema condicionado', () => {
  assert.equal(dictamenSugerido(conPuntos({ '2.1': { v: 'R' } }), FORMATO_SOLAR), 'condicionado')
})

test('dictamenSugerido: un Malo, no aprobado', () => {
  assert.equal(dictamenSugerido(conPuntos({ '2.1': { v: 'M' } }), FORMATO_SOLAR), 'no_aprobado')
  assert.equal(dictamenSugerido(conPuntos({ '1.1': { v: 'M' } }), FORMATO_SOLAR), 'no_aprobado')
})

test('dictamenSugerido: el Malo gana sobre el Regular', () => {
  assert.equal(dictamenSugerido(conPuntos({ '2.1': { v: 'R' }, '2.3': { v: 'M' } }), FORMATO_SOLAR), 'no_aprobado')
})

// ---- contexto y lectura ----

test('contextoDeRevision: el combustible del equipo, y lo que el técnico corrija gana', () => {
  const equipo = { tipo: 'generador', atributos: { combustible: 'diesel' } }
  assert.equal(contextoDeRevision('generador', {}, equipo).combustible, 'diesel')
  // Si el equipo lo tenía mal, el técnico lo elige en el sitio y eso manda.
  const datos = { llegada: { combustible: 'gas_lp' } }
  assert.equal(contextoDeRevision('generador', datos, equipo).combustible, 'gas_lp')
})

test('contextoDeRevision: sin combustible en ningún lado, queda vacío', () => {
  assert.equal(contextoDeRevision('generador', {}, { tipo: 'generador', atributos: {} }).combustible, '')
  assert.equal(contextoDeRevision('generador', {}, null).combustible, '')
})

test('contextoDeRevision: el tipo C prende el servicio mayor', () => {
  assert.equal(contextoDeRevision('generador', { llegada: { tipo_servicio: 'C' } }, null).mayor, true)
  assert.equal(contextoDeRevision('generador', { llegada: { tipo_servicio: 'A' } }, null).mayor, false)
})

test('contextoDeRevision: en solar, el BESS sale del tipo de equipo', () => {
  assert.equal(contextoDeRevision('solar', {}, { tipo: 'bateria' }).bess, true)
  assert.equal(contextoDeRevision('solar', {}, { tipo: 'solar' }).bess, false)
  // Un solar con banco: el técnico lo marca y eso manda.
  assert.equal(contextoDeRevision('solar', { llegada: { bess: true } }, { tipo: 'solar' }).bess, true)
})

test('formatoDe elige por el tipo de equipo', () => {
  assert.equal(formatoDe('solar'), FORMATO_SOLAR)
  assert.equal(formatoDe('generador'), FORMATO_GENERADOR)
  assert.equal(formatoDe(undefined), FORMATO_GENERADOR)   // el generador es el caso común
})

test('revisionDe acepta fila o lista (PostgREST devuelve las dos formas)', () => {
  assert.deepEqual(revisionDe({ orden_revision: [{ tipo: 'solar', datos: { a: 1 } }] }), { tipo: 'solar', datos: { a: 1 } })
  assert.deepEqual(revisionDe({ orden_revision: { tipo: 'solar', datos: { a: 1 } } }), { tipo: 'solar', datos: { a: 1 } })
  assert.equal(revisionDe({ orden_revision: [] }), null)
  assert.equal(revisionDe({}), null)
  assert.equal(revisionDe(null), null)
})

test('revisionDe: una fila sin tipo se lee como generador', () => {
  assert.equal(revisionDe({ orden_revision: [{ datos: {} }] }).tipo, 'generador')
})

test('avanceSeccion cuenta lo contestado, no lo capturado a medias', () => {
  const seccion = { puntos: [{ clave: 'a' }, { clave: 'b' }, { clave: 'c' }] }
  const datos = conPuntos({ a: { v: 'B' }, b: { obs: 'algo pero sin calificar' } })
  assert.deepEqual(avanceSeccion(datos, seccion), { hechos: 1, total: 3, completa: false })
})

test('avanceSeccion: completa cuando no falta ninguno', () => {
  const seccion = { puntos: [{ clave: 'a' }, { clave: 'b' }] }
  const datos = conPuntos({ a: { v: 'B' }, b: { v: 'NA' } })   // "No aplica" también es contestar
  assert.equal(avanceSeccion(datos, seccion).completa, true)
})

// ---- avisos mientras el técnico sigue en el sitio ----

test('avisosMediciones: la frecuencia fuera de 60 ± 0.5', () => {
  assert.match(avisosMediciones({ mediciones: { ac: { frecuencia: '58' } } }).join(' '), /frecuencia/)
  assert.match(avisosMediciones({ mediciones: { lecturas: { frecuencia: { carga: '61.2' } } } }).join(' '), /frecuencia/)
  assert.deepEqual(avisosMediciones({ mediciones: { ac: { frecuencia: '60.4' } } }), [])
  assert.deepEqual(avisosMediciones({ mediciones: { ac: { frecuencia: '59.5' } } }), [])
})

test('avisosMediciones: la resistencia de tierra dice cuánto dio', () => {
  const a = avisosMediciones({ mediciones: { banco: { r_tierra: '18' } } })
  assert.match(a.join(' '), /18/)
  assert.match(a.join(' '), /tierra/)
  assert.deepEqual(avisosMediciones({ mediciones: { banco: { r_tierra: '10' } } }), [])
})

test('avisosMediciones: wet stacking solo en diésel y con el porcentaje', () => {
  const ctx = { combustible: 'diesel' }
  const a = avisosMediciones({ mediciones: { carga_pct: '15' } }, ctx)
  assert.match(a.join(' '), /15 %/)
  // Un generador de gas probado al 15% no acumula hollín: no se avisa.
  assert.deepEqual(avisosMediciones({ mediciones: { carga_pct: '15' } }, { combustible: 'gas_lp' }), [])
  assert.deepEqual(avisosMediciones({ mediciones: { carga_pct: '35' } }, ctx), [])
})

test('avisosMediciones: cuenta los strings que no pasan, en singular y plural', () => {
  const uno = { mediciones: { strings: [{ aisl_pos: '0.1', voc_medido: '400' }] } }
  assert.match(avisosMediciones(uno).join(' '), /1 string no pasa/)
  const dos = { mediciones: { strings: [{ aisl_pos: '0.1', voc_medido: '400' }, { aisl_neg: '0.2', voc_medido: '400' }] } }
  assert.match(avisosMediciones(dos).join(' '), /2 strings no pasan/)
})

test('avisosMediciones: sin mediciones no inventa avisos', () => {
  assert.deepEqual(avisosMediciones({}), [])
  assert.deepEqual(avisosMediciones(null), [])
})

// ---- lo que falta para cerrar ----

test('loQueFalta: reclama el dictamen y las mediciones', () => {
  const faltas = loQueFalta({}, FORMATO_SOLAR, {}).join(' ')
  assert.match(faltas, /dictamen/)
  assert.match(faltas, /string/)          // un solar sin strings
})

test('loQueFalta: en generador reclama la prueba de funcionamiento', () => {
  const faltas = loQueFalta({}, FORMATO_GENERADOR, { combustible: 'diesel' }).join(' ')
  assert.match(faltas, /prueba de funcionamiento/)
})

test('loQueFalta: la seguridad sin resolver sale primero', () => {
  const datos = conPuntos({ '1.3': { v: 'M', obs: '' } })
  assert.match(loQueFalta(datos, FORMATO_SOLAR, {})[0], /Seguridad sin resolver/)
})

test('loQueFalta solo cuenta las secciones que aplican', () => {
  // Un generador de gasolina no debe reclamar los filtros del diésel.
  const faltas = loQueFalta({}, FORMATO_GENERADOR, { combustible: 'gasolina' }).join(' ')
  assert.doesNotMatch(faltas, /3\.5/)
})

// ---- placas ----

test('placaGuardada encuentra la placa que ya se tomó', () => {
  const equipo = { atributos: { componentes: [{ rol: 'motor', serie: 'ABC' }] } }
  assert.equal(placaGuardada(equipo, 'motor').serie, 'ABC')
  assert.equal(placaGuardada(equipo, 'tablero'), null)
})

test('placaGuardada aguanta un equipo sin componentes', () => {
  assert.equal(placaGuardada({ atributos: {} }, 'motor'), null)
  assert.equal(placaGuardada({}, 'motor'), null)
  assert.equal(placaGuardada(null, 'motor'), null)
  // `componentes` con algo que no es lista (un jsonb mal capturado) no debe tronar.
  assert.equal(placaGuardada({ atributos: { componentes: {} } }, 'motor'), null)
})
