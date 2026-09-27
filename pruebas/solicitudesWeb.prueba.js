// Solicitudes del sitio público (SQL 36).
//
// Lo que aquí se cuida: que las nuevas se vean primero, que el detalle no muestre renglones
// vacíos ni el "—" que el formulario manda cuando no se marcó nada, y que el mensaje de
// respuesta no truene con un nombre vacío.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  ordenarSolicitudes, contarNuevas, detalleSolicitud, mensajeDeRespuesta, enlaceRespuesta,
} from '../src/lib/solicitudesWeb.js'

const s = (estado, created_at, extra = {}) => ({ estado, created_at, nombre: 'Ana', telefono: '999 123 4567', ...extra })

test('ordenarSolicitudes: las nuevas primero y, dentro de cada estado, la más reciente arriba', () => {
  const lista = [
    s('atendida', '2026-09-20T10:00:00Z', { id: 'a' }),
    s('nueva', '2026-09-18T10:00:00Z', { id: 'b' }),
    s('descartada', '2026-09-25T10:00:00Z', { id: 'c' }),
    s('nueva', '2026-09-24T10:00:00Z', { id: 'd' }),
  ]
  assert.deepEqual(ordenarSolicitudes(lista).map(x => x.id), ['d', 'b', 'a', 'c'])
})

test('ordenarSolicitudes no toca el arreglo original y aguanta null', () => {
  const lista = [s('atendida', '2026-09-20T10:00:00Z'), s('nueva', '2026-09-21T10:00:00Z')]
  ordenarSolicitudes(lista)
  assert.equal(lista[0].estado, 'atendida')
  assert.deepEqual(ordenarSolicitudes(null), [])
})

test('contarNuevas cuenta solo las nuevas', () => {
  assert.equal(contarNuevas([s('nueva', 'x'), s('atendida', 'x'), s('nueva', 'x')]), 2)
  assert.equal(contarNuevas(null), 0)
})

test('detalleSolicitud omite lo vacío y el "—" del formulario', () => {
  const d = detalleSolicitud({
    tipos: 'Generador', uso: 'Residencial', equipo_actual: '—', consumo: '', presupuesto: null,
    ubicacion: 'Mérida', email: '  ',
  })
  assert.deepEqual(d.map(f => f.etiqueta), ['Equipo', 'Uso', 'Ubicación'])
})

test('mensajeDeRespuesta saluda por el primer nombre y dice qué pidió', () => {
  const m = mensajeDeRespuesta({ nombre: 'Ana María López', tipos: 'Generador, Solar' })
  assert.ok(m.startsWith('Hola Ana,'))
  assert.ok(m.includes('sobre generador, solar'))
})

test('mensajeDeRespuesta no truena sin nombre ni equipo', () => {
  const m = mensajeDeRespuesta({})
  assert.ok(m.startsWith('Hola,'))
  assert.ok(!m.includes('sobre'))
})

test('enlaceRespuesta: wa.me con el 52, y sin teléfono válido no hay enlace', () => {
  assert.ok(enlaceRespuesta({ nombre: 'Ana', telefono: '999 123 4567' }).startsWith('https://wa.me/529991234567?text='))
  assert.equal(enlaceRespuesta({ nombre: 'Ana', telefono: '123' }), null)
})
