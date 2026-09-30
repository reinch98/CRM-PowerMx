// Reglas puras de la pantalla Proveedor (SQL 44): orden de la cola, textos, validación de las
// reglas de margen y el saneo de la búsqueda. El precio NO se calcula aquí (lo calcula la base).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  ordenarCola, contarPorTipo, detalleDeCambio, esAprobable, explicacion, alcanceDeRegla, textoDeRegla,
  ordenarReglas, validarRegla, reglaVacia, estadoDeVinculo, patronDeBusqueda, filtrarProductos,
  textoDeCorrida, pesos,
} from '../src/lib/proveedor.js'

const q = (tipo, nombre, extra = {}) => ({ id: nombre, tipo, detalle: { nombre, ...extra } })

test('la cola pone primero lo que más urge: desaparecidos, saltos de precio, primeros precios', () => {
  const lista = [q('sin_costo', 'E'), q('precio_inicial', 'B'), q('cambio_precio', 'C'),
    q('sku_desaparecido', 'D'), q('precio_inicial', 'A'), q('sin_regla', 'F')]
  assert.deepEqual(ordenarCola(lista).map(x => x.id), ['D', 'C', 'A', 'B', 'F', 'E'])
  assert.deepEqual(ordenarCola(null), [])
})

test('contarPorTipo', () => {
  assert.deepEqual(contarPorTipo([q('precio_inicial', 'a'), q('precio_inicial', 'b'), q('sin_regla', 'c')]),
    { precio_inicial: 2, sin_regla: 1 })
})

test('solo se aprueba lo que tiene qué aprobar', () => {
  assert.equal(esAprobable('cambio_precio'), true)
  assert.equal(esAprobable('precio_inicial'), true)
  assert.equal(esAprobable('sku_desaparecido'), true)
  assert.equal(esAprobable('sin_regla'), false)
  assert.equal(esAprobable('sin_costo'), false)
  assert.match(explicacion('sin_regla'), /regla de margen/)
})

test('un cambio de precio dice si sube o baja con palabra, no solo con signo', () => {
  const sube = detalleDeCambio(q('cambio_precio', 'X', { precio_actual: 1000, precio: 1300, variacion_pct: 30, costo_mxn: 900, margen_pct: 30 }))
  assert.deepEqual(sube.find(f => f.etiqueta === 'Variación'), { etiqueta: 'Variación', valor: 'Sube 30 %' })
  assert.equal(sube.find(f => f.etiqueta === 'Precio nuevo').valor, pesos(1300))
  const baja = detalleDeCambio(q('cambio_precio', 'X', { precio_actual: 1000, precio: 700, variacion_pct: 30 }))
  assert.equal(baja.find(f => f.etiqueta === 'Variación').valor, 'Baja 30 %')
})

test('un primer precio dice "Sin precio" y toma el precio actual del producto si el detalle no lo trae', () => {
  const f = detalleDeCambio({ tipo: 'precio_inicial', detalle: { precio: 2160 }, productos: { precio: null } })
  assert.equal(f.find(x => x.etiqueta === 'Precio ahora').valor, 'Sin precio')
  const g = detalleDeCambio({ tipo: 'cambio_precio', detalle: { precio: 500 }, productos: { precio: 400 } })
  assert.equal(g.find(x => x.etiqueta === 'Precio ahora').valor, pesos(400))
})

test('las reglas se describen por su alcance y se ordenan de la más específica a la general', () => {
  const general = { id: 1, categoria: null, marca: null, margen_pct: 30, margen_minimo_mxn: 100, redondeo: 10, activo: true }
  const marca = { id: 2, categoria: null, marca: 'JA SOLAR', margen_pct: 20, margen_minimo_mxn: 0, redondeo: 1, activo: true }
  const ambas = { id: 3, categoria: 'panel', marca: 'JA SOLAR', margen_pct: 15, margen_minimo_mxn: 0, redondeo: 1, activo: true }
  const apagada = { id: 4, categoria: 'panel', marca: null, margen_pct: 25, margen_minimo_mxn: 0, redondeo: 1, activo: false }
  assert.equal(alcanceDeRegla(general), 'Todos los productos (regla general)')
  assert.equal(alcanceDeRegla(marca), 'Todo lo de JA SOLAR')
  assert.equal(alcanceDeRegla(ambas), 'Paneles de JA SOLAR')
  assert.deepEqual(ordenarReglas([general, apagada, marca, ambas]).map(r => r.id), [3, 2, 1, 4])
  assert.match(textoDeRegla(general), /30 % de margen · mínimo .*100.* · redondeo hacia arriba a .*10/)
  assert.doesNotMatch(textoDeRegla(marca), /mínimo/)
})

test('validarRegla: lo vacío va como null y lo absurdo se rechaza', () => {
  const ok = validarRegla({ ...reglaVacia, categoria: 'panel', marca: '  ', margen_pct: '30', margen_minimo_mxn: '', redondeo: '10' })
  assert.deepEqual(ok, { ok: true, regla: { categoria: 'panel', marca: null, margen_pct: 30, margen_minimo_mxn: 0, redondeo: 10 } })
  assert.equal(validarRegla({ ...reglaVacia, margen_pct: '' }).ok, false)
  assert.equal(validarRegla({ ...reglaVacia, margen_pct: '-5' }).ok, false)
  assert.equal(validarRegla({ ...reglaVacia, margen_pct: '10', redondeo: '0' }).ok, false)
  assert.equal(validarRegla({ ...reglaVacia, margen_pct: '10', margen_minimo_mxn: '-1' }).ok, false)
  assert.equal(validarRegla({ ...reglaVacia, margen_pct: '0', redondeo: '1' }).ok, true)
})

test('el estado del vínculo se dice en palabras', () => {
  assert.equal(estadoDeVinculo({ proveedor_sku: null }), 'sin_vincular')
  assert.equal(estadoDeVinculo({ proveedor_sku: 'X', precio_auto: false }), 'vinculado')
  assert.equal(estadoDeVinculo({ proveedor_sku: 'X', precio_auto: true }), 'automatico')
})

test('la búsqueda quita lo que rompería el filtro de PostgREST', () => {
  assert.equal(patronDeBusqueda('  JA-M66,(D45)%  *x '), 'JA-M66 D45 x')
  assert.equal(patronDeBusqueda(null), '')
})

test('filtrarProductos busca en varios campos y puede dejar solo los sin vincular', () => {
  const lista = [
    { sku: 'P-1', nombre: 'Panel 630', marca: 'JA SOLAR', modelo: 'M66', proveedor_sku: 'PSO1' },
    { sku: 'P-2', nombre: 'Panel 700', marca: 'LONGI', modelo: 'LR', proveedor_sku: null },
    { sku: 'B-1', nombre: 'Batería', marca: 'JA SOLAR', modelo: null, proveedor_sku: null },
  ]
  assert.equal(filtrarProductos(lista, 'ja solar').length, 2)
  assert.equal(filtrarProductos(lista, 'ja solar', true).length, 1)
  assert.equal(filtrarProductos(lista, 'pso1').length, 1)
  assert.equal(filtrarProductos(lista, '', true).length, 2)
  assert.deepEqual(filtrarProductos(null, ''), [])
})

test('textoDeCorrida: una lectura fallida se dice fuerte, con su motivo', () => {
  const base = { iniciada_en: '2026-09-29T18:00:00Z' }
  assert.equal(textoDeCorrida(null), null)
  const ok = textoDeCorrida({ ...base, estado: 'aplicada', filas: 908, resumen: { aplicados: 4, en_revision: 2 } })
  assert.equal(ok.tipo, 'ok')
  assert.match(ok.texto, /908 productos; 4 precios aplicados, 2 esperando/)
  const mal = textoDeCorrida({ ...base, estado: 'fallida', error: 'Lectura sospechosa' })
  assert.equal(mal.tipo, 'error')
  assert.match(mal.texto, /no se aplicó nada: Lectura sospechosa/)
  assert.equal(textoDeCorrida({ ...base, estado: 'leida' }).tipo, 'aviso')
})
