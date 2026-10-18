import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  normalizarCotizacion, problemasDeCotizacion, lineasParaCotizacion, estadoCotizacion, textoAceptada, dinero
} from '../src/lib/cotizacionesProveedor.js'

test('lo leído de una cotización: número, vigencia escrita o calculada con los días', () => {
  const a = normalizarCotizacion({
    proveedor: 'EXEL SOLAR', numero: 'COT-1474', fecha: '2026-10-09', vigencia: '2026-10-24', moneda: 'usd',
    lineas: [{ codigo: 'C10', descripcion: 'Cable 10 AWG', cantidad: 2, precio_unitario: '127.95' }]
  })
  assert.equal(a.numero, 'COT-1474')
  assert.equal(a.vigencia, '2026-10-24')
  assert.equal(a.moneda, 'USD')
  assert.equal(a.lineas[0].precio_unitario, 127.95)
  const b = normalizarCotizacion({ factura: 'Q-9', fecha: '2026-10-09', vigencia_dias: 15, lineas: [] })
  assert.equal(b.numero, 'Q-9')                  // sin "numero", el folio leído
  assert.equal(b.vigencia, '2026-10-24')         // 9 + 15 días
  assert.equal(normalizarCotizacion({ vigencia_dias: 15 }).vigencia, '')   // sin fecha no se inventa
})

const linea = (tipo, extra = {}) => ({
  codigo: 'X1', descripcion: 'Filtro', cantidad: 2, costo_unitario: 10,
  decision: { tipo, producto_id: tipo === 'producto' ? 'p1' : undefined, nuevo: { sku: 'N1', nombre: 'Nueva', categoria: 'refaccion', unidad: 'pieza' } },
  ...extra
})

test('lo que falta antes de registrar: proveedor y, en dólares, el tipo de cambio', () => {
  const f = problemasDeCotizacion({ proveedor: '', moneda: 'USD', tipo_cambio: '', lineas: [linea('producto')] })
  assert.ok(f.includes('Escribe de qué proveedor es la cotización.'))
  assert.ok(f.includes('Escribe el tipo de cambio: la cotización está en dólares.'))
  assert.deepEqual(problemasDeCotizacion({ proveedor: 'Exel', moneda: 'USD', tipo_cambio: '18.2', lineas: [linea('producto')] }), [])
})

test('los renglones que se mandan: sin los omitidos, con su descripción y su precio', () => {
  const r = lineasParaCotizacion([linea('producto'), linea('omitir'), linea('nuevo', { descripcion: '  Manguera  ' })])
  assert.equal(r.length, 2)
  assert.deepEqual(r[0], { codigo: 'X1', cantidad: 2, costo_unitario: 10, producto_id: 'p1', descripcion: 'Filtro' })
  assert.equal(r[1].nuevo.sku, 'N1')
  assert.equal(r[1].descripcion, 'Manguera')
})

test('el estado se dice con palabra, y una vigente con la fecha pasada es "Vencida"', () => {
  assert.equal(estadoCotizacion({ estado: 'vigente' }).etiqueta, 'Vigente')
  assert.equal(estadoCotizacion({ estado: 'vigente', vencida: true }).etiqueta, 'Vencida')
  assert.equal(estadoCotizacion({ estado: 'aceptada', vencida: true }).etiqueta, 'Aceptada')
  assert.equal(estadoCotizacion({ estado: 'cancelada' }).clase, 'estado-cancelada')
})

test('al aceptar se dice cuántos pedidos salieron, con plurales bien hechos', () => {
  assert.equal(textoAceptada({ pedidos_nuevos: 2, pedidos_tomados: 1 }),
    'Aceptada: se hicieron 2 pedidos nuevos y se tomó 1 pedido que estaba pendiente. Los ves en Pedidos como "pedida".')
  assert.equal(textoAceptada({ pedidos_nuevos: 1, pedidos_tomados: 0 }),
    'Aceptada: se hizo 1 pedido nuevo. Los ves en Pedidos como "pedida".')
  assert.equal(textoAceptada({ sin_cambio: true }), 'Esa cotización ya estaba aceptada.')
  assert.equal(dinero(1234.5, 'USD'), 'USD 1,234.50')
  assert.match(dinero(1234.5), /\$1,234\.50/)
})
