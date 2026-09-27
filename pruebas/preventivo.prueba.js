// Cotizar un preventivo (SQL 28) y aprender del historial (SQL 29).
//
// Este archivo importa una librería que a su vez importa `./supabase`: si los enlaces de
// `pruebas/enlaces.js` dejaran de funcionar, esto revienta al cargar. Sirve de centinela.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  opcionSugerida, problemasDelPaquete, faltantes, partidasDePreventivo, esIncluida,
  queTanSeguido, avisosDePreventivo,
} from '../src/lib/preventivo.js'

// Una línea del paquete: la pieza que toca, con todos los códigos que sirven.
const linea = (cantidad, opciones) => ({ linea_id: 1, descripcion: 'Filtro de aceite', cantidad, opciones })
const original = disponible => ({ producto_id: 'o', sku: 'FIL-ORIG-1', nombre: 'Filtro Perkins', preferido: true, disponible })
const generico = disponible => ({ producto_id: 'g', sku: 'FIL-GEN-1', nombre: 'Filtro genérico', preferido: false, disponible })

test('opcionSugerida: si alcanza el original, va el original', () => {
  assert.equal(opcionSugerida(linea(2, [original(5), generico(99)])).producto_id, 'o')
})

test('opcionSugerida: si el original no alcanza, propone el genérico', () => {
  // Esta es la idea de `grupo_equivalente`: lo que cambia de un equipo a otro no es el
  // precio sino qué código se usa.
  assert.equal(opcionSugerida(linea(2, [original(1), generico(10)])).producto_id, 'g')
})

test('opcionSugerida: si ninguno alcanza, propone el preferido y la pantalla avisa', () => {
  // Quedarse sin sugerencia obligaría a elegir a ciegas.
  assert.equal(opcionSugerida(linea(5, [original(1), generico(2)])).producto_id, 'o')
})

test('opcionSugerida: sin preferido toma el primero que alcance', () => {
  const l = { linea_id: 1, cantidad: 2, opciones: [{ producto_id: 'a', disponible: 0 }, { producto_id: 'b', disponible: 9 }] }
  assert.equal(opcionSugerida(l).producto_id, 'b')
})

test('opcionSugerida: sin opciones no hay nada que proponer', () => {
  assert.equal(opcionSugerida(linea(1, [])), null)
  assert.equal(opcionSugerida(null), null)
})

test('opcionSugerida: el disponible justo alcanza', () => {
  assert.equal(opcionSugerida(linea(3, [original(3)])).producto_id, 'o')
  assert.equal(opcionSugerida(linea(3, [original(2), generico(3)])).producto_id, 'g')
})

// ---- qué impide cotizar ----

const PAQUETE = {
  servicio: { sku: 'SRV-PMEN-DIE', nombre: 'Mantenimiento menor — Diésel 30–100 kW', precio: 4500 },
  lineas: [linea(2, [original(5)])],
}

test('problemasDelPaquete: con todo en su lugar, ninguno', () => {
  assert.deepEqual(problemasDelPaquete(PAQUETE), [])
})

test('problemasDelPaquete: la base dice en palabras por qué no se puede', () => {
  // `paquete_preventivo` nunca inventa un precio: cuando falta un dato lo explica.
  const p = { ...PAQUETE, falta: 'Captura el combustible del equipo.' }
  assert.deepEqual(problemasDelPaquete(p), ['Captura el combustible del equipo.'])
})

test('problemasDelPaquete: una pieza sin ningún código es un problema', () => {
  const p = { servicio: PAQUETE.servicio, lineas: [linea(1, [])] }
  assert.equal(problemasDelPaquete(p).length, 1)
  assert.match(problemasDelPaquete(p)[0], /Filtro de aceite/)
})

test('problemasDelPaquete: sin consultar el paquete, no se cotiza', () => {
  assert.equal(problemasDelPaquete(null).length, 1)
})

test('faltantes avisa qué habrá que pedir, sin bloquear', () => {
  // No bloquea porque al aceptar la cotización la requisición se genera sola (SQL 08).
  const p = { servicio: PAQUETE.servicio, lineas: [linea(5, [original(2)])] }
  assert.deepEqual(faltantes(p), [{ sku: 'FIL-ORIG-1', nombre: 'Filtro Perkins', falta: 3 }])
})

test('faltantes: si el disponible cubre la pieza, no falta nada', () => {
  assert.deepEqual(faltantes(PAQUETE), [])
})

test('faltantes: un disponible negativo no resta de más', () => {
  const p = { servicio: PAQUETE.servicio, lineas: [linea(2, [original(-3)])] }
  assert.equal(faltantes(p)[0].falta, 5)
})

// ---- las partidas: el corazón del acuerdo con Caña ----

test('partidas: el cliente ve UN precio y las refacciones van en cero', () => {
  const partidas = partidasDePreventivo(PAQUETE)
  assert.equal(partidas.length, 2)

  const servicio = partidas[0]
  assert.equal(servicio.producto_id, null)      // partida libre: no mueve inventario
  assert.equal(servicio.precio_unitario, 4500)
  assert.equal(servicio.cantidad, 1)

  const refaccion = partidas[1]
  assert.equal(refaccion.producto_id, 'o')      // CON producto_id: sí aparta inventario
  assert.equal(refaccion.precio_unitario, 0)
  assert.equal(refaccion.cantidad, 2)
  assert.equal(esIncluida(refaccion), true)     // la marca que evita cobrarla dos veces
  assert.equal(esIncluida(servicio), false)
})

test('partidas: la refacción lleva producto_id, que es lo único que mira el almacén', () => {
  // Apartar inventario y armar la lista de surtido solo miran `producto_id` y `cantidad`:
  // el precio nunca entra. Por eso una pieza a cero se aparta igual.
  const r = partidasDePreventivo(PAQUETE)[1]
  assert.ok(r.producto_id)
  assert.ok(r.cantidad > 0)
})

test('partidas: se respeta el código que eligió quien cotiza', () => {
  const p = { servicio: PAQUETE.servicio, lineas: [linea(2, [original(5), generico(5)])] }
  const partidas = partidasDePreventivo(p, { 1: 'g' })
  assert.equal(partidas[1].producto_id, 'g')
  assert.equal(partidas[1].sku, 'FIL-GEN-1')
})

test('partidas: sin servicio no se arma nada', () => {
  assert.deepEqual(partidasDePreventivo({ lineas: PAQUETE.lineas }), [])
  assert.deepEqual(partidasDePreventivo(null), [])
})

test('partidas: una línea sin código se salta, no rompe la cotización', () => {
  const p = { servicio: PAQUETE.servicio, lineas: [linea(1, []), linea(2, [original(9)])] }
  const partidas = partidasDePreventivo(p)
  assert.equal(partidas.length, 2)   // el servicio y la única refacción con código
})

// ---- qué tan seguido se usa una pieza (fase 5) ----

test('queTanSeguido: lo que importa son las VISITAS, no las piezas', () => {
  // 20 piezas en una sola visita fue una reparación; una pieza en 9 de 10 visitas es
  // parte del mantenimiento.
  const casi = queTanSeguido({ visitas: 9, de_visitas: 10 })
  assert.match(casi.texto, /casi siempre/)
  assert.equal(casi.fuerte, true)
})

test('queTanSeguido: los tramos', () => {
  assert.match(queTanSeguido({ visitas: 8, de_visitas: 10 }).texto, /casi siempre/)   // 0.8 justo
  assert.match(queTanSeguido({ visitas: 7, de_visitas: 10 }).texto, /seguido/)
  assert.match(queTanSeguido({ visitas: 5, de_visitas: 10 }).texto, /seguido/)        // 0.5 justo
  assert.match(queTanSeguido({ visitas: 2, de_visitas: 10 }).texto, /de vez en cuando/)
})

test('queTanSeguido: con menos de 3 visitas no presume de estadística', () => {
  const r = queTanSeguido({ visitas: 2, de_visitas: 2 })
  assert.match(r.texto, /todavía son pocas/)
  assert.equal(r.fuerte, false)   // no se resalta: dos visitas no son una tendencia
})

test('queTanSeguido: sin visitas cerradas no hay nada que aprender', () => {
  assert.equal(queTanSeguido({ visitas: 0, de_visitas: 0 }).texto, 'Sin visitas cerradas')
  assert.equal(queTanSeguido(null).texto, 'Sin visitas cerradas')
})

// ---- el traslado en el preventivo (27/09/2026) ----

const TARIFAS_T = [{ activo: true, concepto: 'traslado', precio: 15, km_desde: 40 }]
const PAQ = { ...PAQUETE, tipo: 'menor' }

test('partidas: el preventivo también cobra traslado, como el diagnóstico', () => {
  // Si solo lo cobrara un canal, el mismo servicio costaría distinto según por dónde entró
  // la solicitud (decisión de Caña, 27/09/2026).
  const partidas = partidasDePreventivo(PAQ, {}, { tarifas: TARIFAS_T, cliente: { distancia_km: 60 } })
  const viaje = partidas.find(p => p.servicio === 'traslado')
  assert.ok(viaje, 'falta la partida de traslado')
  assert.equal(viaje.cantidad, 60)
  assert.equal(viaje.precio_unitario, 15)
  assert.equal(partidas.length, 3)   // servicio + refacción + traslado
})

test('partidas: el servicio queda marcado con su tipo', () => {
  // La marca `servicio` es lo que usa el SQL 37 para no apilar dos borradores del mismo tipo.
  const partidas = partidasDePreventivo(PAQ, {}, { tarifas: TARIFAS_T, cliente: { distancia_km: 60 } })
  assert.equal(partidas[0].servicio, 'preventivo_menor')
  assert.equal(partidasDePreventivo({ ...PAQ, tipo: 'mayor' })[0].servicio, 'preventivo_mayor')
})

test('partidas: un cliente cerca no paga traslado', () => {
  const partidas = partidasDePreventivo(PAQ, {}, { tarifas: TARIFAS_T, cliente: { distancia_km: 10 } })
  assert.equal(partidas.find(p => p.servicio === 'traslado'), undefined)
  assert.equal(partidas.length, 2)
})

test('partidas: sin tarifas ni cliente sigue funcionando (solo no hay traslado)', () => {
  const partidas = partidasDePreventivo(PAQ)
  assert.equal(partidas.length, 2)
  assert.equal(partidas.find(p => p.servicio === 'traslado'), undefined)
})

test('avisosDePreventivo junta lo del paquete y lo del traslado', () => {
  // Sin distancia capturada no se puede calcular el traslado: hay que decirlo.
  const avisos = avisosDePreventivo(PAQ, {}, { tarifas: TARIFAS_T, cliente: {} })
  assert.match(avisos.join(' '), /distancia/)
  // Con todo en su lugar, ninguno.
  assert.deepEqual(avisosDePreventivo(PAQ, {}, { tarifas: TARIFAS_T, cliente: { distancia_km: 60 } }), [])
})
