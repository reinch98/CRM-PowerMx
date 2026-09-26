// El PDF de la orden (fase 4): el texto que sabe escribir jsPDF, los nombres de archivo y
// las rutas del expediente y de los envíos.
//
// `paraPdf` existe por un defecto que solo apareció generando el PDF de verdad: las fuentes
// estándar de jsPDF (Helvetica) solo escriben WinAnsi, y un carácter fuera de ahí no falla,
// sale en dos bytes y en el papel se ve basura. Le pasó a la Ω de "Aislamiento (MΩ)".
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  paraPdf, nombreArchivo, rutaExpediente, rutaEnvio, fechaLarga, nombreTipoServicio,
  descripcionEquipo,
} from '../src/lib/documentos.js'

test('paraPdf traduce la Ω, que es la que rompió el primer PDF real', () => {
  assert.equal(paraPdf('Aislamiento (MΩ)'), 'Aislamiento (Mohm)')
  assert.equal(paraPdf('R tierra 8 Ω'), 'R tierra 8 ohm')
})

test('paraPdf traduce los otros símbolos técnicos que sí usamos', () => {
  assert.equal(paraPdf('ΔT máx'), 'delta T máx')
  assert.equal(paraPdf('±10%'), '+/-10%')
  assert.equal(paraPdf('vacío → carga'), 'vacío -> carga')
  // El menos tipográfico del formato (−) no es el guion del teclado (-).
  assert.equal(paraPdf('aislamiento −/tierra'), 'aislamiento -/tierra')
})

test('paraPdf deja pasar los acentos y la ñ: están en WinAnsi', () => {
  assert.equal(paraPdf('Mérida, Yucatán'), 'Mérida, Yucatán')
  assert.equal(paraPdf('mañana ¿sí? ¡claro!'), 'mañana ¿sí? ¡claro!')
  assert.equal(paraPdf('°C'), '°C')
  assert.equal(paraPdf('N·m'), 'N·m')
})

test('paraPdf deja pasar la puntuación tipográfica de WinAnsi', () => {
  assert.equal(paraPdf('«guion — y comillas “así”…»'), '«guion — y comillas “así”…»')
  assert.equal(paraPdf('8–26 kW'), '8–26 kW')
})

test('paraPdf marca con ? lo que no reconoce, en vez de escribir basura', () => {
  // Que nadie firme un documento con un dato ilegible sin enterarse.
  assert.equal(paraPdf('中文'), '??')
  // Recorre por PUNTOS DE CÓDIGO, no por unidades: un emoji (par surrogado) deja UN solo
  // interrogante, no dos. Con `for` sobre índices saldrían dos y se vería como un error.
  assert.equal(paraPdf('emoji 🔧 aquí'), 'emoji ? aquí')
})

test('paraPdf aguanta null, undefined y números', () => {
  assert.equal(paraPdf(null), '')
  assert.equal(paraPdf(undefined), '')
  assert.equal(paraPdf(0), '0')
  assert.equal(paraPdf(1200), '1200')
})

test('paraPdf no toca un texto que ya es seguro', () => {
  const s = 'Orden OS-124 cerrada el 25/09/2026 por Juan Pérez.'
  assert.equal(paraPdf(s), s)
})

// ---- nombres y rutas ----

const ORDEN = { folio: 124, cliente_id: 'c-7' }

test('nombreArchivo lleva el folio y la copia de la que se trata', () => {
  assert.equal(nombreArchivo(ORDEN, 'cliente'), 'OS-124-cliente.pdf')
  assert.equal(nombreArchivo(ORDEN, 'interna'), 'OS-124-interna.pdf')
})

test('rutaExpediente cuelga del cliente: ahí se guarda su historial', () => {
  assert.equal(rutaExpediente(ORDEN, 'interna'), 'expedientes/c-7/OS-124-interna.pdf')
})

test('rutaExpediente es la misma para la misma orden: al regenerar se reemplaza', () => {
  // Por eso `ordenes_pdf` es un upsert: regenerar no debe dejar dos copias.
  assert.equal(rutaExpediente(ORDEN, 'cliente'), rutaExpediente({ ...ORDEN }, 'cliente'))
})

test('rutaEnvio ordena los enviados por semana y NO se repite', () => {
  // Una copia por envío: el historial tiene que guardar lo que salió cada vez.
  assert.equal(rutaEnvio(ORDEN, '2026-W39', 111), 'enviados/2026-W39/OS-124-111.pdf')
  assert.notEqual(rutaEnvio(ORDEN, '2026-W39', 111), rutaEnvio(ORDEN, '2026-W39', 222))
})

test('fechaLarga se lee sin pensar', () => {
  assert.equal(fechaLarga('2026-09-25'), '25 de septiembre de 2026')
  assert.equal(fechaLarga('2026-01-01'), '1 de enero de 2026')
  assert.equal(fechaLarga('2026-12-31'), '31 de diciembre de 2026')
})

test('fechaLarga: sin fecha no inventa una', () => {
  assert.equal(fechaLarga(null), null)
  assert.equal(fechaLarga(''), null)
  assert.equal(fechaLarga(undefined), null)
})

test('fechaLarga: algo que no es fecha se muestra tal cual', () => {
  assert.equal(fechaLarga('mañana'), 'mañana')
})

test('nombreTipoServicio siempre da algo legible', () => {
  assert.equal(nombreTipoServicio('preventivo'), 'Mantenimiento preventivo')
  assert.equal(nombreTipoServicio('visita_tecnica'), 'Visita técnica')
  assert.equal(nombreTipoServicio('loQueSea'), 'loQueSea')
  assert.equal(nombreTipoServicio(null), 'Servicio')
})

test('descripcionEquipo junta lo que haya, sin huecos', () => {
  assert.equal(
    descripcionEquipo({ tipo: 'generador', marca: 'Generac', modelo: 'SD100', capacidad_kw: 100 }),
    'generador Generac SD100 100 kW'
  )
  // Un equipo capturado en campo puede venir a medias: la 23 lo permite.
  assert.equal(descripcionEquipo({ tipo: 'generador', marca: 'Generac' }), 'generador Generac')
  assert.equal(descripcionEquipo({ tipo: 'solar' }), 'solar')
})

test('descripcionEquipo: sin equipo, null (la orden puede nacer sin él)', () => {
  assert.equal(descripcionEquipo(null), null)
  assert.equal(descripcionEquipo({}), null)
})
