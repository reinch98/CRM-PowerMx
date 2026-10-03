// Avisos de cita (SQL 16) y bandeja de WhatsApp (SQL 22).
//
// Lo que aquí se cuida: el enlace `wa.me` tiene que llevar el código de país y el texto
// escapado, y la ventana de 24 horas tiene que decirse EN PALABRAS antes de que el envío
// falle — fuera de ella WhatsApp solo acepta plantillas aprobadas.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { enlaceWhatsApp, agruparPorCita, cuandoCorto, etiquetaTipo, etiquetaPara } from '../src/lib/avisos.js'
import {
  ventanaAbierta, estadoVentana, nombreConversacion, haceCuanto, esBorrador,
} from '../src/lib/whatsapp.js'

test('enlaceWhatsApp arma wa.me con el 52 y el texto escapado', () => {
  const url = enlaceWhatsApp('999 123 4567', 'Cita el 26/09 a las 9:00 & confirmada')
  assert.ok(url.startsWith('https://wa.me/529991234567?text='))
  assert.ok(url.includes('%26'))        // el & escapado, o cortaría el enlace
  assert.ok(!url.includes(' '))
})

test('enlaceWhatsApp normaliza el número que venga', () => {
  assert.equal(
    enlaceWhatsApp('5219991234567', 'hola'),
    enlaceWhatsApp('999-123-4567', 'hola')
  )
})

test('enlaceWhatsApp: sin número válido no hay enlace', () => {
  // La pantalla muestra "Falta el teléfono" en vez de un enlace roto.
  assert.equal(enlaceWhatsApp('', 'hola'), null)
  assert.equal(enlaceWhatsApp('99912', 'hola'), null)
  assert.equal(enlaceWhatsApp(null, 'hola'), null)
})

test('enlaceWhatsApp aguanta un texto vacío', () => {
  assert.equal(enlaceWhatsApp('9991234567', null), 'https://wa.me/529991234567?text=')
})

test('agruparPorCita junta los mensajes de una misma cita, en orden', () => {
  const avisos = [
    { cita_id: 1, cliente: 'Hotel X', fecha: '2026-09-26', hora: '09:00:00', para: 'cliente' },
    { cita_id: 1, cliente: 'Hotel X', fecha: '2026-09-26', hora: '09:00:00', para: 'tecnico' },
    { cita_id: 2, cliente: 'Plaza Y', fecha: '2026-09-27', hora: null, para: 'cliente' },
  ]
  const g = agruparPorCita(avisos)
  assert.equal(g.length, 2)
  assert.equal(g[0].cita_id, 1)
  assert.equal(g[0].avisos.length, 2)
  assert.equal(g[1].avisos.length, 1)
})

test('agruparPorCita respeta el orden que manda la base', () => {
  const avisos = [{ cita_id: 9 }, { cita_id: 3 }, { cita_id: 9 }]
  assert.deepEqual(agruparPorCita(avisos).map(g => g.cita_id), [9, 3])
})

test('agruparPorCita con nada devuelve nada', () => {
  assert.deepEqual(agruparPorCita([]), [])
  assert.deepEqual(agruparPorCita(null), [])
})

test('cuandoCorto: sin fecha lo dice; una cita puede estar por programar', () => {
  assert.equal(cuandoCorto(null, null), 'sin fecha')
  assert.equal(cuandoCorto('2026-09-26', '09:00:00'), '2026-09-26 09:00')
  assert.equal(cuandoCorto('2026-09-26', null), '2026-09-26')
})

test('etiquetaTipo y etiquetaPara nunca dejan una clave cruda a la vista', () => {
  assert.equal(etiquetaTipo('reprogramacion'), 'Cambio de horario')
  assert.equal(etiquetaTipo('recordatorio'), 'Recordatorio')
  assert.equal(etiquetaTipo('otra_cosa'), 'otra_cosa')
  assert.equal(etiquetaPara('tecnico'), 'Técnico')
  assert.equal(etiquetaPara('cliente'), 'Cliente')
})

// ---- la ventana de 24 horas ----

const AHORA = new Date('2026-09-26T12:00:00Z')

test('ventanaAbierta: mientras no pasen 24 h del último mensaje del cliente', () => {
  assert.equal(ventanaAbierta({ ventana_hasta: '2026-09-26T18:00:00Z' }, AHORA), true)
  assert.equal(ventanaAbierta({ ventana_hasta: '2026-09-26T11:59:00Z' }, AHORA), false)
  assert.equal(ventanaAbierta({}, AHORA), false)
  assert.equal(ventanaAbierta(null, AHORA), false)
})

test('estadoVentana lo dice en palabras ANTES de que el envío falle', () => {
  const abierta = estadoVentana({ ventana_hasta: '2026-09-26T18:00:00Z' }, AHORA)
  assert.equal(abierta.puede, true)
  assert.match(abierta.texto, /Puedes responder/)

  const cerrada = estadoVentana({ ventana_hasta: '2026-09-25T18:00:00Z' }, AHORA)
  assert.equal(cerrada.puede, false)
  assert.match(cerrada.texto, /plantilla aprobada/)
})

test('estadoVentana: sin mensajes del cliente todavía, no se puede escribir', () => {
  const r = estadoVentana({}, AHORA)
  assert.equal(r.puede, false)
  assert.match(r.texto, /todavía/)
})

test('nombreConversacion: la persona conocida gana al nombre que manda WhatsApp', () => {
  // El nombre de WhatsApp lo pone el cliente: es dato, no verdad.
  assert.equal(nombreConversacion({ contacto: 'Ana López', nombre_wa: 'ANA', telefono: '999' }), 'Ana López')
  assert.equal(nombreConversacion({ nombre_wa: 'ANA', telefono: '999' }), 'ANA')
  assert.equal(nombreConversacion({ telefono: '9991234567' }), '9991234567')
  assert.equal(nombreConversacion({}), 'Sin nombre')
})

test('haceCuanto en palabras', () => {
  assert.equal(haceCuanto('2026-09-26T11:59:40Z', AHORA), 'hace un momento')
  assert.equal(haceCuanto('2026-09-26T11:55:00Z', AHORA), 'hace 5 min')
  assert.equal(haceCuanto('2026-09-26T10:00:00Z', AHORA), 'hace 2 h')
  assert.equal(haceCuanto('2026-09-25T10:00:00Z', AHORA), 'ayer')
  assert.equal(haceCuanto('2026-09-23T10:00:00Z', AHORA), 'hace 3 días')
  assert.equal(haceCuanto(null, AHORA), null)
})

test('esBorrador: solo un saliente sin enviar', () => {
  // En la burbuja se ve igual que lo ya enviado; por eso se marca fuerte.
  assert.equal(esBorrador({ direccion: 'saliente', estado: 'borrador' }), true)
  assert.equal(esBorrador({ direccion: 'saliente', estado: 'enviado' }), false)
  assert.equal(esBorrador({ direccion: 'entrante', estado: 'borrador' }), false)
  assert.equal(esBorrador(null), false)
})
