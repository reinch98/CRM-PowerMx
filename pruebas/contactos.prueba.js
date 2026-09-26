// Contactos (SQL 15). La regla que sostiene todo el WhatsApp: **el cliente sale del
// NÚMERO**, nunca del texto de un mensaje. Si `normalizarTelefono` no coincide con
// `normalizar_telefono` de la base, un número deja de reconocerse y el agente contesta
// como si fuera un desconocido.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  normalizarTelefono, etiquetaRol, permisosEnPalabras, descripcionEquipo,
  armarContacto, problemaDeContacto, textoDeError,
} from '../src/lib/contactos.js'

test('normalizarTelefono: el mismo número escrito de cinco formas es UNO', () => {
  // WhatsApp entrega los de México como 521…; en el CRM se capturan a mano de mil maneras.
  const esperado = '9991234567'
  for (const t of [
    '9991234567',
    '999 123 4567',
    '999-123-4567',
    '(999) 123 4567',
    '+52 999 123 4567',
    '5219991234567',      // como lo manda WhatsApp
    '+52 1 999 123 4567',
  ]) {
    assert.equal(normalizarTelefono(t), esperado, `falló con ${t}`)
  }
})

test('normalizarTelefono: menos de 10 dígitos no es un teléfono', () => {
  assert.equal(normalizarTelefono('123456789'), null)
  assert.equal(normalizarTelefono('9991234'), null)
  assert.equal(normalizarTelefono(''), null)
  assert.equal(normalizarTelefono(null), null)
  assert.equal(normalizarTelefono('sin número'), null)
})

test('normalizarTelefono: exactamente 10 dígitos pasan', () => {
  assert.equal(normalizarTelefono('9991234567'), '9991234567')
})

test('etiquetaRol: "empresa" no es un rol que se elija', () => {
  assert.equal(etiquetaRol('responsable'), 'Responsable')
  assert.equal(etiquetaRol('solo_avisos'), 'Solo avisos')
  assert.equal(etiquetaRol('empresa'), 'Toda la empresa')
  assert.equal(etiquetaRol('loQueSea'), 'loQueSea')
})

test('permisosEnPalabras: nunca solo casillas', () => {
  assert.equal(permisosEnPalabras({}), 'Sin permisos')
  assert.equal(permisosEnPalabras({ recibe_ordenes: true }), 'Recibe órdenes')
  assert.equal(
    permisosEnPalabras({ puede_pedir_citas: true, recibe_ordenes: true, recibe_cotizaciones: true }),
    'Pide citas · Recibe órdenes · Recibe cotizaciones'
  )
})

test('descripcionEquipo siempre dice algo', () => {
  assert.equal(descripcionEquipo({ tipo: 'generador', marca: 'Generac', capacidad_kw: 22 }), 'generador Generac 22 kW')
  assert.equal(descripcionEquipo({}), 'Equipo')
})

test('armarContacto: los vacíos van como null, no como cadena vacía', () => {
  const r = armarContacto({ nombre: '  Juan  ', puesto: '', telefono: '   ', email: null })
  assert.equal(r.nombre, 'Juan')     // recortado
  assert.equal(r.puesto, null)
  assert.equal(r.telefono, null)
  assert.equal(r.email, null)
})

test('armarContacto: los permisos de empresa solo cuentan si es de toda la empresa', () => {
  // Un encargado de un equipo no puede recibir las órdenes de todos los equipos por error.
  const conPermisos = { nombre: 'Ana', puede_pedir_citas: true, recibe_ordenes: true, recibe_cotizaciones: true }
  const suelto = armarContacto({ ...conPermisos, de_toda_la_empresa: false })
  assert.equal(suelto.puede_pedir_citas, false)
  assert.equal(suelto.recibe_ordenes, false)
  assert.equal(suelto.recibe_cotizaciones, false)

  const empresa = armarContacto({ ...conPermisos, de_toda_la_empresa: true })
  assert.equal(empresa.puede_pedir_citas, true)
  assert.equal(empresa.recibe_ordenes, true)
})

test('armarContacto: las casillas siempre salen booleanas', () => {
  const r = armarContacto({ nombre: 'Ana' })
  for (const clave of ['whatsapp', 'verificado', 'de_toda_la_empresa']) {
    assert.equal(typeof r[clave], 'boolean', `${clave} no es booleano`)
  }
})

test('problemaDeContacto: el nombre es lo único obligatorio', () => {
  assert.match(problemaDeContacto({ nombre: '' }), /nombre/)
  assert.equal(problemaDeContacto({ nombre: 'Ana' }), null)
})

test('problemaDeContacto: un teléfono corto se atrapa antes de mandarlo', () => {
  assert.match(problemaDeContacto({ nombre: 'Ana', telefono: '99912' }), /10 dígitos/)
  assert.equal(problemaDeContacto({ nombre: 'Ana', telefono: '999 123 4567' }), null)
  assert.equal(problemaDeContacto({ nombre: 'Ana', telefono: '' }), null)   // sin teléfono se puede
})

test('textoDeError explica el número repetido, que es el choque común', () => {
  assert.match(textoDeError({ code: '23505' }), /ya está registrado/)
  // Un mensaje escrito por la base se muestra tal cual.
  assert.equal(textoDeError({ code: 'P0002', message: 'No existe ese equipo.' }), 'No existe ese equipo.')
  assert.equal(textoDeError({}), 'Error desconocido.')
})
