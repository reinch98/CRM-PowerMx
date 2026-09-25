// ---------------------------------------------------------------------------
// Leer la placa de un componente (Edge Function `leer-placa`, SQL 26).
//
// El técnico fotografía la placa en el sitio y sigue trabajando. Aquí, en la oficina, se
// lee esa foto y se PROPONE marca, modelo y serie. Lo que el modelo lee **no se guarda
// solo**: se muestra para que una persona lo revise y corrija. Una placa sucia o a
// contraluz da series equivocadas, y una serie mal capturada es peor que ninguna.
// ---------------------------------------------------------------------------

import { supabase } from './supabase'
import { explicarError } from './errores'

// Los campos que se pueden guardar de un componente, en el orden en que se muestran.
export const CAMPOS_COMPONENTE = [
  ['marca', 'Marca'],
  ['modelo', 'Modelo'],
  ['serie', 'Número de serie'],
  ['capacidad', 'Capacidad'],
  ['voltaje', 'Voltaje'],
  ['anio', 'Año'],
  ['cantidad', 'Cantidad'],
]

const NOMBRES_ROL = {
  modulos: 'Paneles', inversor_1: 'Inversor', inversor_2: 'Segundo inversor',
  bateria: 'Batería / BESS', bms: 'BMS / monitoreo',
  generador: 'Generador', motor: 'Motor', alternador: 'Alternador',
  tablero: 'Controlador o tablero',
}
export const nombreRol = rol => NOMBRES_ROL[rol] || rol

// ---- reglas puras ----

// Se queda solo con las claves que sabemos guardar y con las que traen algo. Lo demás que
// devuelva el modelo se ignora: no vamos a escribir campos inventados en el equipo.
export function limpiarLeido(leido) {
  const validos = CAMPOS_COMPONENTE.map(([k]) => k)
  const salida = {}
  for (const [k, v] of Object.entries(leido || {})) {
    if (!validos.includes(k)) continue
    const s = typeof v === 'string' ? v.trim() : v
    if (s === '' || s === null || s === undefined) continue
    salida[k] = String(s)
  }
  return salida
}

// Qué cambiaría si se guardara: sirve para marcar en la pantalla lo que el modelo AGREGA
// frente a lo que ya estaba, y para no pisar a ciegas un dato capturado a mano.
export function diferencias(actual, propuesto) {
  const filas = []
  for (const [k, etiqueta] of CAMPOS_COMPONENTE) {
    const antes = actual?.[k] ?? ''
    const ahora = propuesto?.[k] ?? ''
    if (!antes && !ahora) continue
    filas.push({
      clave: k,
      etiqueta,
      antes: String(antes),
      ahora: String(ahora || antes),
      nuevo: !antes && !!ahora,
      distinto: !!antes && !!ahora && String(antes) !== String(ahora),
    })
  }
  return filas
}

// Los componentes de un equipo que tienen foto pero les falta algún dato: la lista de
// trabajo de la oficina.
export function componentesPorLeer(equipo) {
  const lista = equipo?.atributos?.componentes
  if (!Array.isArray(lista)) return []
  return lista.filter(c => c?.foto && (!c.marca || !c.modelo || !c.serie))
}

// ---- llamadas ----

function textoDeError(error) {
  const codigo = String(error?.code || '')
  if (['22023', 'P0002', '42501'].includes(codigo) && error?.message) return error.message
  return explicarError(error).texto
}

export async function leerPlaca(ruta) {
  try {
    const { data, error } = await supabase.functions.invoke('leer-placa', { body: { ruta } })
    if (error) {
      // La función devuelve el motivo en el cuerpo; `invoke` solo trae el código.
      let detalle = ''
      try { detalle = (await error.context?.json())?.error || '' } catch { /* sin cuerpo */ }
      return { ok: false, texto: detalle || 'No se pudo leer la placa.' }
    }
    if (data?.error) return { ok: false, texto: data.error }
    if (!data?.ok) return { ok: false, texto: data?.error || 'No entendí lo que devolvió el modelo.' }
    return { ok: true, leido: limpiarLeido(data.leido), notas: data.leido?.notas || null, uso: data.uso }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

export async function guardarComponente(equipoId, rol, datos, origen = 'oficina') {
  try {
    const { error } = await supabase.rpc('actualizar_componente', {
      p_equipo: equipoId, p_rol: rol, p_datos: datos, p_origen: origen
    })
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

// Para ver la foto: el bucket es privado, así que hace falta un enlace firmado.
export async function urlDeFoto(ruta, segundos = 600) {
  try {
    const { data, error } = await supabase.storage.from('ordenes').createSignedUrl(ruta, segundos)
    if (error) return null
    return data?.signedUrl || null
  } catch {
    return null
  }
}
