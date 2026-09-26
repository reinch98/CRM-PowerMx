// ---------------------------------------------------------------------------
// Cotizar un mantenimiento preventivo (SQL 28).
//
// Cómo lo quiso Caña: **el cliente ve un solo precio** —el del servicio, fijo y tabulado
// por clase y capacidad— y las refacciones van incluidas. Pero por dentro **sí apartan
// inventario**, para que el almacén sepa qué surtir.
//
// Eso se logra sin tocar nada del almacén: las refacciones entran como partidas normales
// con `precio_unitario: 0` y la marca `incluida`. Apartar inventario solo mira
// `producto_id` y `cantidad` —el precio nunca entra—, así que la pieza se aparta igual y
// llega a la lista de surtido; y como su importe es cero, no se le cobra dos veces.
//
// Lo que cambia de un equipo a otro no es el precio sino **qué código se usa**: hay
// material genérico que sirve igual. Por eso cada línea trae todas sus opciones con lo
// disponible de cada una, y quien cotiza elige.
// ---------------------------------------------------------------------------

import { supabase } from './supabase'
import { explicarError } from './errores'

export const TIPOS_PREVENTIVO = [
  ['menor', 'Mantenimiento menor'],
  ['mayor', 'Mantenimiento mayor'],
]

// ---- reglas puras ----

// Qué opción conviene proponer para una línea: la preferida si alcanza, si no la que
// tenga con qué cumplir. Si ninguna alcanza, se propone la preferida igual y la pantalla
// avisa: quedarse sin sugerencia obligaría a elegir a ciegas.
export function opcionSugerida(linea) {
  const opciones = linea?.opciones || []
  if (opciones.length === 0) return null
  const necesarias = Number(linea.cantidad || 0)
  const alcanza = o => Number(o.disponible || 0) >= necesarias
  return opciones.find(o => o.preferido && alcanza(o))
    || opciones.find(alcanza)
    || opciones.find(o => o.preferido)
    || opciones[0]
}

// Lo que falta para poder agregar el preventivo. Vacío = se puede.
export function problemasDelPaquete(paquete, elegidas = {}) {
  if (!paquete) return ['Todavía no se consultó el paquete.']
  const faltas = []
  if (paquete.falta) faltas.push(paquete.falta)
  for (const l of paquete.lineas || []) {
    const id = elegidas[l.linea_id] ?? opcionSugerida(l)?.producto_id
    if (!id) faltas.push(`${l.descripcion}: no hay ningún código para esa pieza.`)
  }
  return faltas
}

// Cuánto falta comprar de cada pieza elegida. No bloquea: al aceptar, la cotización
// genera la requisición sola (regla de la 08). Sirve para avisar antes.
export function faltantes(paquete, elegidas = {}) {
  const salida = []
  for (const l of paquete?.lineas || []) {
    const id = elegidas[l.linea_id] ?? opcionSugerida(l)?.producto_id
    const o = (l.opciones || []).find(x => x.producto_id === id)
    if (!o) continue
    const falta = Number(l.cantidad || 0) - Number(o.disponible || 0)
    if (falta > 0) salida.push({ sku: o.sku, nombre: o.nombre, falta })
  }
  return salida
}

// Las partidas que se agregan a la cotización: el servicio con su precio, y cada
// refacción a cero y marcada como incluida.
export function partidasDePreventivo(paquete, elegidas = {}) {
  if (!paquete?.servicio) return []
  const partidas = [{
    producto_id: null,
    sku: paquete.servicio.sku,
    descripcion: paquete.servicio.nombre,
    unidad: 'servicio',
    cantidad: 1,
    precio_unitario: Number(paquete.servicio.precio || 0),
  }]
  for (const l of paquete.lineas || []) {
    const id = elegidas[l.linea_id] ?? opcionSugerida(l)?.producto_id
    const o = (l.opciones || []).find(x => x.producto_id === id)
    if (!o) continue
    partidas.push({
      producto_id: o.producto_id,
      sku: o.sku,
      descripcion: o.nombre,
      unidad: o.unidad || 'pieza',
      cantidad: Number(l.cantidad || 1),
      precio_unitario: 0,
      // La marca que hace que no se cobre dos veces: va incluida en el servicio.
      incluida: true,
    })
  }
  return partidas
}

export const esIncluida = p => p?.incluida === true

// ---- llamadas ----

function textoDeError(error) {
  const codigo = String(error?.code || '')
  if (['22023', 'P0002', '42501'].includes(codigo) && error?.message) return error.message
  return explicarError(error).texto
}

// El almacén precarga la lista de surtido con el paquete del equipo. **No devuelve
// precios**: el almacenista no los ve, y por eso esto no pasa por `paquete_preventivo`.
export async function surtidoDesdePaquete(ordenId, tipo) {
  try {
    const { data, error } = await supabase.rpc('surtido_desde_paquete', {
      p_orden: ordenId, p_tipo: tipo,
    })
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true, datos: data }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

// Lo que de verdad se ha usado en equipos parecidos. Propone; no decide.
export async function piezasQueSeRepiten(filtros = {}) {
  try {
    const { data, error } = await supabase.rpc('piezas_que_se_repiten', {
      p_clase: filtros.clase || null,
      p_kw_desde: filtros.kw_desde ?? null,
      p_kw_hasta: filtros.kw_hasta ?? null,
      p_marca: filtros.marca || null,
      p_modelo: filtros.modelo || null,
      p_desde: filtros.desde || null,
    })
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true, piezas: data || [] }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

// Qué tan seguro es que una pieza sea parte del mantenimiento, en palabras. Lo que importa
// es en cuántas VISITAS apareció, no cuántas piezas salieron: 20 piezas en una sola visita
// fue una reparación, no un preventivo.
export function queTanSeguido(pieza) {
  const de = Number(pieza?.de_visitas || 0)
  const v = Number(pieza?.visitas || 0)
  if (de === 0) return { texto: 'Sin visitas cerradas', proporcion: 0, fuerte: false }
  const proporcion = v / de
  if (de < 3) return { texto: `${v} de ${de} visitas · todavía son pocas`, proporcion, fuerte: false }
  if (proporcion >= 0.8) return { texto: `${v} de ${de} visitas · casi siempre`, proporcion, fuerte: true }
  if (proporcion >= 0.5) return { texto: `${v} de ${de} visitas · seguido`, proporcion, fuerte: false }
  return { texto: `${v} de ${de} visitas · de vez en cuando`, proporcion, fuerte: false }
}

export async function cargarPaquete(equipoId, tipo) {
  try {
    const { data, error } = await supabase.rpc('paquete_preventivo', {
      p_equipo: equipoId, p_tipo: tipo,
    })
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true, paquete: data }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

// ---- definir paquetes (oficina) ----

export async function cargarPaquetes() {
  try {
    const { data, error } = await supabase.from('paquetes_mantenimiento')
      .select('*, paquete_lineas(*)')
      .order('tipo').order('clase').order('kw_desde')
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true, paquetes: data || [] }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

export async function crearPaquete(datos) {
  try {
    const { data, error } = await supabase.from('paquetes_mantenimiento')
      .insert([datos]).select('id').single()
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true, id: data.id }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

export async function agregarLineaPaquete(paqueteId, linea) {
  try {
    const { error } = await supabase.from('paquete_lineas')
      .insert([{ paquete_id: paqueteId, ...linea }])
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

export async function quitarLineaPaquete(id) {
  try {
    const { error } = await supabase.from('paquete_lineas').delete().eq('id', id)
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

export async function borrarPaquete(id) {
  try {
    const { error } = await supabase.from('paquetes_mantenimiento').delete().eq('id', id)
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}
