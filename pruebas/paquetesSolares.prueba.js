import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  textoCambio, sePuedePublicar, porPublicar, tituloPaquete, textoRegla, estadoDe, cantidadValida
} from '../src/lib/paquetesSolares.js'

// Lo que devuelve costear_paquete para el Starter con los costos del borrador (prueba SQL 78).
const STARTER = {
  paquete_id: 'p1', nombre: 'Starter', paneles: 4, kwp: 2.52,
  variantes: {
    interconectado: { precio: 48999, publicado: 40000, cambio_pct: 22.5, primera: true, estado: 'por_aprobar' },
    hibrido_a: { precio: 97999, publicado: 52000, cambio_pct: 88.5, primera: true, estado: 'por_aprobar' },
    hibrido_b: { precio: 101999, publicado: null, cambio_pct: null, primera: true, estado: 'por_aprobar' }
  }
}

test('qué pasaría con el precio del sitio, en palabras', () => {
  assert.equal(textoCambio(STARTER.variantes.interconectado),
    'Sube 22.5 % contra el sitio ($40,000); primera vez desde la receta')
  assert.equal(textoCambio(STARTER.variantes.hibrido_b), 'Todavía no tiene precio en el sitio')
  assert.equal(textoCambio({ precio: 49999, publicado: 48999, cambio_pct: 2, primera: false }), 'Sube 2 % contra el sitio ($48,999)')
  assert.equal(textoCambio({ precio: 48999, publicado: 48999, cambio_pct: 0, primera: false }), 'Igual al del sitio')
  assert.equal(textoCambio({ precio: null }), '')
})

test('solo se publica lo que tiene precio y está por publicar', () => {
  assert.equal(sePuedePublicar(STARTER.variantes.interconectado), true)
  assert.equal(sePuedePublicar({ precio: 48999, estado: 'al_dia' }), false)
  assert.equal(sePuedePublicar({ precio: null, estado: 'falta_costo' }), false)
  assert.equal(porPublicar([STARTER, { variantes: { interconectado: { precio: 1, estado: 'al_dia' } } }]), 3)
})

test('título y regla', () => {
  assert.equal(tituloPaquete(STARTER), 'Starter · 4 paneles · 2.52 kWp')
  assert.equal(tituloPaquete({ nombre: 'Nuevo' }), 'Nuevo')
  assert.equal(textoRegla({ categoria: null, margen_pct: 30, sobre: 'costo' }),
    'Margen de la regla general: 30 % sobre el costo. Precio con IVA, terminado en 999.')
  assert.match(textoRegla({ categoria: 'paquete_solar', margen_pct: 25, sobre: 'precio' }), /regla de paquetes: 25 % sobre el precio/)
  assert.match(textoRegla(null), /Sin regla de margen/)
})

test('estados con palabra y cantidades', () => {
  assert.equal(estadoDe('falta_costo').etiqueta, 'Falta costo')
  assert.equal(estadoDe('al_dia').etiqueta, 'Publicado')
  assert.equal(cantidadValida('0.3'), true)
  assert.equal(cantidadValida('0'), false)
  assert.equal(cantidadValida(''), false)
})
