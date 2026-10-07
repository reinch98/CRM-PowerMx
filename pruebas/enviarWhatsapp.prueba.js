// Envío por la API de Meta (Edge Function `enviar-whatsapp`): lo que se arma y cómo se lee
// la respuesta. Lo que aquí se cuida: que una plantilla con variables CON NOMBRE salga con
// `parameter_name` (si no, Meta la rechaza), que el PDF vaya como encabezado de documento,
// y que un error temporal no se confunda con uno permanente (uno vuelve a la cola, el otro
// lo revisa una persona — reintentar un permanente solo quema saldo y calidad).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { cuerpoMensaje, limpiarParametro, leerRespuesta, esBaja, errorDeAcuse } from '../supabase/functions/_shared/whatsapp.js'

test('texto libre', () => {
  const c = cuerpoMensaje({ tipo: 'texto', to: '529991234567', texto: 'Hola' })
  assert.deepEqual(c, { messaging_product: 'whatsapp', to: '529991234567', type: 'text', text: { body: 'Hola', preview_url: false } })
})

test('plantilla con variables con nombre', () => {
  const c = cuerpoMensaje({
    tipo: 'plantilla', to: '529991234567', plantilla: 'cita_confirmada', idioma: 'es_MX',
    parametros: [{ nombre: 'nombre', valor: 'Adal' }, { nombre: 'fecha', valor: 'martes 6 de octubre' }],
  })
  assert.equal(c.type, 'template')
  assert.equal(c.template.name, 'cita_confirmada')
  assert.equal(c.template.language.code, 'es_MX')
  assert.deepEqual(c.template.components, [{ type: 'body', parameters: [
    { type: 'text', parameter_name: 'nombre', text: 'Adal' },
    { type: 'text', parameter_name: 'fecha', text: 'martes 6 de octubre' },
  ] }])
})

test('plantilla con PDF: encabezado de documento con el enlace y el nombre', () => {
  const c = cuerpoMensaje({
    tipo: 'plantilla', to: '52999', plantilla: 'orden_servicio_lista', documento_ruta: 'enviados/2026-S40/OS-1.pdf',
    documento_nombre: 'OS-1.pdf', parametros: [{ nombre: 'folio', valor: 'OS-1' }],
  }, 'https://x/firmado')
  assert.deepEqual(c.template.components[0], {
    type: 'header', parameters: [{ type: 'document', document: { link: 'https://x/firmado', filename: 'OS-1.pdf' } }],
  })
  assert.equal(c.template.components[1].type, 'body')
})

test('plantilla con documento pero sin enlace: no sale a medias', () => {
  assert.throws(() => cuerpoMensaje({ tipo: 'plantilla', plantilla: 'x', documento_ruta: 'a.pdf' }))
})

test('plantilla sin variables no manda componentes vacíos', () => {
  const c = cuerpoMensaje({ tipo: 'plantilla', to: '52', plantilla: 'x', parametros: [] })
  assert.equal(c.template.components, undefined)
})

test('limpiarParametro quita saltos y espacios dobles; nunca vacío', () => {
  assert.equal(limpiarParametro('Generac\n22   kW'), 'Generac 22 kW')
  assert.equal(limpiarParametro('  '), '—')
  assert.equal(limpiarParametro(null), '—')
})

test('respuesta buena: trae el wamid', () => {
  assert.deepEqual(leerRespuesta(200, { messages: [{ id: 'wamid.X' }] }), { ok: true, wamid: 'wamid.X' })
})

test('200 sin id no se da por enviado', () => {
  assert.equal(leerRespuesta(200, {}).ok, false)
})

test('errores temporales vuelven a la cola', () => {
  assert.equal(leerRespuesta(429, { error: { code: 130429, message: 'rate' } }).temporal, true)
  assert.equal(leerRespuesta(503, {}).temporal, true)
  assert.equal(leerRespuesta(400, { error: { code: 131016 } }).temporal, true)
})

test('errores permanentes no se reintentan y se explican', () => {
  const r = leerRespuesta(400, { error: { code: 132000, message: 'Number of parameters does not match' } })
  assert.equal(r.temporal, false)
  assert.match(r.error, /variables no coinciden/)
  assert.match(leerRespuesta(401, { error: { code: 190 } }).error, /token/)
  assert.equal(leerRespuesta(400, { error: { code: 131047 } }).temporal, false)
})

test('esBaja reconoce las formas comunes y no confunde frases', () => {
  for (const t of ['BAJA', 'baja', ' Baja! ', 'STOP', 'Detener promociones', 'Stop promotions', 'Darme de baja']) assert.equal(esBaja(t), true, t)
  for (const t of ['bajó la luz', 'no quiero baja', 'hola', '', null]) assert.equal(esBaja(t), false, String(t))
})

test('errorDeAcuse: el error que trae un acuse fallido', () => {
  assert.equal(errorDeAcuse({ status: 'delivered' }), null)
  assert.match(errorDeAcuse({ errors: [{ code: 131026, title: 'Undeliverable' }] }), /^131026: no se pudo entregar/)
})
