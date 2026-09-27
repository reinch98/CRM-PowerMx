// Precios de diagnóstico, traslado y servicios de catálogo. Esto toca DINERO: lo que
// salga de aquí se copia a la cotización y ahí se queda.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  claseDeEquipo, capacidadDeEquipo, tarifaDiagnostico, tarifaTraslado,
  partidasDeDiagnostico, importe, esConceptoCatalogo, nombreTarifaCatalogo,
  tarifasDeCatalogo, sugerirSkuTarifa, partidaDeTraslado,
} from '../src/lib/tarifas.js'

const diag = (clase, kw_desde, kw_hasta, precio) =>
  ({ activo: true, concepto: 'diagnostico', clase, kw_desde, kw_hasta, precio })

test('claseDeEquipo: el gas natural se cobra como gas LP', () => {
  assert.equal(claseDeEquipo({ tipo: 'generador', atributos: { combustible: 'gas_natural' } }), 'gas_lp')
  assert.equal(claseDeEquipo({ tipo: 'generador', atributos: { combustible: 'gas_lp' } }), 'gas_lp')
  assert.equal(claseDeEquipo({ tipo: 'generador', atributos: { combustible: 'diesel' } }), 'diesel')
  assert.equal(claseDeEquipo({ tipo: 'generador', atributos: { combustible: 'gasolina' } }), 'gasolina')
})

test('claseDeEquipo: solares y baterías tienen su propia tarifa', () => {
  assert.equal(claseDeEquipo({ tipo: 'solar' }), 'solar')
  assert.equal(claseDeEquipo({ tipo: 'bateria' }), 'bateria')
})

test('claseDeEquipo: sin combustible capturado no se adivina la clase', () => {
  assert.equal(claseDeEquipo({ tipo: 'generador', atributos: {} }), null)
  assert.equal(claseDeEquipo({ tipo: 'generador' }), null)
  assert.equal(claseDeEquipo({ tipo: 'otro' }), null)
  assert.equal(claseDeEquipo(null), null)
})

test('capacidadDeEquipo: capacidad_kw manda, y cada tipo tiene su respaldo', () => {
  assert.equal(capacidadDeEquipo({ tipo: 'generador', capacidad_kw: 22 }), 22)
  assert.equal(capacidadDeEquipo({ tipo: 'solar', atributos: { potencia_inversor_kw: 5 } }), 5)
  assert.equal(capacidadDeEquipo({ tipo: 'bateria', atributos: { capacidad_kwh: 10 } }), 10)
  // capacidad_kw gana sobre el respaldo.
  assert.equal(capacidadDeEquipo({ tipo: 'solar', capacidad_kw: 8, atributos: { potencia_inversor_kw: 5 } }), 8)
})

test('capacidadDeEquipo: cadena vacía, null y cero no son capacidades', () => {
  assert.equal(capacidadDeEquipo({ capacidad_kw: '' }), null)
  assert.equal(capacidadDeEquipo({ capacidad_kw: null }), null)
  assert.equal(capacidadDeEquipo({ capacidad_kw: 0 }), null)
  assert.equal(capacidadDeEquipo({ capacidad_kw: 'abc' }), null)
  assert.equal(capacidadDeEquipo(null), null)
})

test('tarifaDiagnostico: respeta el tramo, incluidos sus extremos', () => {
  const t = [diag('diesel', 30, 500, 3500)]
  assert.equal(tarifaDiagnostico(t, 'diesel', 30)?.precio, 3500)   // el borde de abajo entra
  assert.equal(tarifaDiagnostico(t, 'diesel', 500)?.precio, 3500)  // el de arriba también
  assert.equal(tarifaDiagnostico(t, 'diesel', 29), null)
  assert.equal(tarifaDiagnostico(t, 'diesel', 501), null)
})

test('tarifaDiagnostico: los tramos que se traslapan los separa la clase', () => {
  // Entre 8 y 10 kW se traslapan gasolina (1.5-10) y gas LP (8-26): por eso hace falta
  // preguntar el combustible, no basta la capacidad.
  const t = [diag('gasolina', 1.5, 10, 1200), diag('gas_lp', 8, 26, 1800)]
  assert.equal(tarifaDiagnostico(t, 'gasolina', 9)?.precio, 1200)
  assert.equal(tarifaDiagnostico(t, 'gas_lp', 9)?.precio, 1800)
})

test('tarifaDiagnostico: si dos tramos coinciden gana el más específico', () => {
  const t = [diag('diesel', null, null, 1000), diag('diesel', 100, 500, 4000)]
  assert.equal(tarifaDiagnostico(t, 'diesel', 200)?.precio, 4000)
  // Fuera del tramo específico queda el abierto.
  assert.equal(tarifaDiagnostico(t, 'diesel', 50)?.precio, 1000)
})

test('tarifaDiagnostico: una tarifa apagada no se usa', () => {
  const t = [{ ...diag('diesel', 30, 500, 3500), activo: false }]
  assert.equal(tarifaDiagnostico(t, 'diesel', 100), null)
})

test('tarifaDiagnostico: sin clase o sin capacidad no devuelve nada', () => {
  const t = [diag('diesel', 30, 500, 3500)]
  assert.equal(tarifaDiagnostico(t, null, 100), null)
  assert.equal(tarifaDiagnostico(t, 'diesel', null), null)
  assert.equal(tarifaDiagnostico(null, 'diesel', 100), null)
})

test('tarifaTraslado: solo la activa', () => {
  assert.equal(tarifaTraslado([{ activo: false, concepto: 'traslado', precio: 9 }]), null)
  assert.equal(tarifaTraslado([{ activo: true, concepto: 'traslado', precio: 9 }])?.precio, 9)
})

// ---- el traslado: la regla que Caña decidió el 20/09/2026 ----

const TARIFAS = [diag('diesel', 30, 500, 3500), { activo: true, concepto: 'traslado', precio: 15, km_desde: 40 }]
const EQUIPO = { tipo: 'generador', capacidad_kw: 100, atributos: { combustible: 'diesel' } }
const trasladoDe = r => r.partidas.find(p => p.servicio === 'traslado')

test('traslado: rebasados los 40 km se cobran TODOS los km, solo ida', () => {
  const r = partidasDeDiagnostico({ tarifas: TARIFAS, equipo: EQUIPO, cliente: { distancia_km: 60 } })
  const t = trasladoDe(r)
  assert.equal(t.cantidad, 60)        // los 60, no los 20 que pasan de 40
  assert.equal(t.precio_unitario, 15)
  assert.equal(importe(t.cantidad, t.precio_unitario), 900)
  assert.match(t.descripcion, /solo ida/)
})

test('traslado: a los 40 km justos ya aplica; por debajo no hay partida', () => {
  const a = partidasDeDiagnostico({ tarifas: TARIFAS, equipo: EQUIPO, cliente: { distancia_km: 40 } })
  assert.equal(trasladoDe(a).cantidad, 40)
  const b = partidasDeDiagnostico({ tarifas: TARIFAS, equipo: EQUIPO, cliente: { distancia_km: 39.9 } })
  assert.equal(trasladoDe(b), undefined)
  assert.deepEqual(b.avisos, [])      // no cobrar traslado cerca no es un problema que avisar
})

test('traslado: sin km_desde capturado, el mínimo son 40 km', () => {
  const tarifas = [{ activo: true, concepto: 'traslado', precio: 15, km_desde: null }]
  const bajo = partidasDeDiagnostico({ tarifas, equipo: EQUIPO, cliente: { distancia_km: 39 } })
  assert.equal(trasladoDe(bajo), undefined)
  const alto = partidasDeDiagnostico({ tarifas, equipo: EQUIPO, cliente: { distancia_km: 41 } })
  assert.equal(trasladoDe(alto).cantidad, 41)
})

test('traslado: sin distancia del cliente avisa y no cobra', () => {
  for (const cliente of [{ distancia_km: null }, { distancia_km: '' }, {}, null]) {
    const r = partidasDeDiagnostico({ tarifas: TARIFAS, equipo: EQUIPO, cliente })
    assert.equal(trasladoDe(r), undefined)
    assert.match(r.avisos.join(' '), /distancia/)
  }
})

test('traslado: con distancia pero sin tarifa capturada, avisa', () => {
  const r = partidasDeDiagnostico({ tarifas: [diag('diesel', 30, 500, 3500)], equipo: EQUIPO, cliente: { distancia_km: 90 } })
  assert.equal(trasladoDe(r), undefined)
  assert.match(r.avisos.join(' '), /traslado/)
})

test('diagnóstico: sin tarifa deja el precio VACÍO, nunca inventa uno', () => {
  const r = partidasDeDiagnostico({ tarifas: [], equipo: EQUIPO, cliente: { distancia_km: 10 } })
  const d = r.partidas.find(p => p.servicio === 'diagnostico')
  assert.equal(d.precio_unitario, '')   // vacío, no 0: un 0 se cobraría como gratis
  assert.match(r.avisos.join(' '), /No hay tarifa de diagnóstico/)
})

test('diagnóstico: sin combustible avisa qué capturar y no pone precio', () => {
  const equipo = { tipo: 'generador', capacidad_kw: 100, atributos: {} }
  const r = partidasDeDiagnostico({ tarifas: TARIFAS, equipo, cliente: { distancia_km: 10 } })
  assert.equal(r.partidas.find(p => p.servicio === 'diagnostico').precio_unitario, '')
  assert.match(r.avisos.join(' '), /combustible/)
})

test('diagnóstico: sin capacidad avisa y no pone precio', () => {
  const equipo = { tipo: 'generador', atributos: { combustible: 'diesel' } }
  const r = partidasDeDiagnostico({ tarifas: TARIFAS, equipo, cliente: { distancia_km: 10 } })
  assert.equal(r.partidas.find(p => p.servicio === 'diagnostico').precio_unitario, '')
  assert.match(r.avisos.join(' '), /capacidad/)
})

test('diagnóstico: sin equipo no se arma la partida, solo el aviso', () => {
  const r = partidasDeDiagnostico({ tarifas: TARIFAS, equipo: null, cliente: { distancia_km: 60 } })
  assert.equal(r.partidas.find(p => p.servicio === 'diagnostico'), undefined)
  assert.match(r.avisos.join(' '), /Elige el equipo/)
  // El traslado sí se calcula: no depende del equipo.
  assert.equal(trasladoDe(r).cantidad, 60)
})

test('diagnóstico y traslado: partidas LIBRES, sin producto_id', () => {
  const r = partidasDeDiagnostico({ tarifas: TARIFAS, equipo: EQUIPO, cliente: { distancia_km: 60 } })
  assert.equal(r.partidas.length, 2)
  // Sin producto_id no mueven inventario ni generan requisiciones.
  for (const p of r.partidas) assert.equal(p.producto_id, null)
  assert.deepEqual(r.avisos, [])
})

test('importe redondea a centavos', () => {
  assert.equal(importe(3, 1.115), 3.35)
  assert.equal(importe(60, 15), 900)
  assert.equal(importe(null, 15), 0)
  assert.equal(importe(2, null), 0)
  assert.equal(importe('3', '2.5'), 7.5)
})

// ---- tarifas de catálogo (SQL 21) ----

test('esConceptoCatalogo: todo menos diagnóstico y traslado', () => {
  assert.equal(esConceptoCatalogo('diagnostico'), false)
  assert.equal(esConceptoCatalogo('traslado'), false)
  for (const c of ['correctivo', 'preventivo_menor', 'preventivo_mayor', 'instalacion_gas', 'otro']) {
    assert.equal(esConceptoCatalogo(c), true)
  }
})

test('nombreTarifaCatalogo: el nombre capturado gana', () => {
  assert.equal(nombreTarifaCatalogo({ nombre: 'Puesta en marcha', concepto: 'otro' }), 'Puesta en marcha')
})

test('nombreTarifaCatalogo: sin nombre, lo arma con concepto, clase y tramo', () => {
  assert.equal(nombreTarifaCatalogo({ concepto: 'correctivo' }), 'Servicio correctivo')
  assert.equal(
    nombreTarifaCatalogo({ concepto: 'correctivo', clase: 'gas_lp', kw_desde: 8, kw_hasta: 26 }),
    'Servicio correctivo — Gas LP / natural, 8–26 kW'
  )
  assert.equal(
    nombreTarifaCatalogo({ concepto: 'preventivo_menor', kw_desde: 30, kw_hasta: null }),
    'Mantenimiento menor — 30–… kW'
  )
})

test('tarifasDeCatalogo: solo activas, con SKU y sin fórmula', () => {
  const r = tarifasDeCatalogo([
    { id: 1, activo: true, sku: 'SRV-COR', concepto: 'correctivo', precio: '800' },
    { id: 2, activo: true, sku: 'SRV-DIAG', concepto: 'diagnostico', precio: '1' },  // fórmula
    { id: 3, activo: true, sku: null, concepto: 'correctivo', precio: '1' },         // sin sku
    { id: 4, activo: false, sku: 'SRV-X', concepto: 'correctivo', precio: '1' },     // apagada
  ])
  assert.equal(r.length, 1)
  assert.equal(r[0].sku, 'SRV-COR')
  assert.equal(r[0].precio, 800)   // número, no la cadena que devuelve Postgres
})

test('sugerirSkuTarifa propone, y menor y mayor no chocan', () => {
  assert.equal(sugerirSkuTarifa('correctivo', 'gas_lp'), 'SRV-COR-GLP')
  assert.equal(sugerirSkuTarifa('correctivo', null), 'SRV-COR')
  assert.notEqual(sugerirSkuTarifa('preventivo_menor', 'diesel'), sugerirSkuTarifa('preventivo_mayor', 'diesel'))
  assert.equal(sugerirSkuTarifa('otro', null), 'SRV-SERV')
})

// ---- la partida de traslado, ahora compartida por el diagnóstico y el preventivo ----

test('partidaDeTraslado: rebasado el mínimo cobra TODOS los km, solo ida', () => {
  const { partida, aviso } = partidaDeTraslado({ tarifas: TARIFAS, cliente: { distancia_km: 60 } })
  assert.equal(partida.cantidad, 60)
  assert.equal(partida.precio_unitario, 15)
  assert.equal(importe(partida.cantidad, partida.precio_unitario), 900)
  assert.equal(partida.servicio, 'traslado')
  assert.equal(partida.producto_id, null)   // partida libre: no mueve inventario
  assert.equal(aviso, null)
})

test('partidaDeTraslado: el mismo número que da `_precio_traslado` en SQL', () => {
  // Las dos implementaciones de la regla tienen que coincidir: la de aquí la usa el navegador
  // y la del SQL 36 la usa el agente de WhatsApp, que no puede leer `tarifas_servicio`.
  // 60 km × 15 = 900 es el caso que también comprueba `36_prueba_wa_cotizar_preventivo.sql`.
  const { partida } = partidaDeTraslado({ tarifas: TARIFAS, cliente: { distancia_km: 60 } })
  assert.equal(importe(partida.cantidad, partida.precio_unitario), 900)
})

test('partidaDeTraslado: cerca no se cobra, y eso NO es un aviso', () => {
  // No cobrar traslado a 10 km es lo correcto, no un dato que falte.
  const r = partidaDeTraslado({ tarifas: TARIFAS, cliente: { distancia_km: 10 } })
  assert.equal(r.partida, null)
  assert.equal(r.aviso, null)
})

test('partidaDeTraslado: a los 40 justos ya aplica', () => {
  assert.equal(partidaDeTraslado({ tarifas: TARIFAS, cliente: { distancia_km: 40 } }).partida.cantidad, 40)
  assert.equal(partidaDeTraslado({ tarifas: TARIFAS, cliente: { distancia_km: 39.9 } }).partida, null)
})

test('partidaDeTraslado: lo que SÍ es aviso es un dato que falta', () => {
  const sinKm = partidaDeTraslado({ tarifas: TARIFAS, cliente: {} })
  assert.equal(sinKm.partida, null)
  assert.match(sinKm.aviso, /distancia/)

  const sinTarifa = partidaDeTraslado({ tarifas: [], cliente: { distancia_km: 60 } })
  assert.equal(sinTarifa.partida, null)
  assert.match(sinTarifa.aviso, /traslado/)
})
