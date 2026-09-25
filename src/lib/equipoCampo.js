// ---------------------------------------------------------------------------
// El equipo se captura en campo (SQL 23).
//
// El cliente casi nunca sabe el modelo ni la serie; el técnico sí, porque está frente a la
// placa. Así que la orden puede nacer sin equipo y el técnico lo elige o lo da de alta
// durante la visita. La serie puede faltar: una placa borrada no detiene el trabajo.
//
// El técnico NUNCA ve ni toca nada comercial (póliza, frecuencia, próximo mantenimiento):
// eso se queda en la pantalla Equipos, que es de la oficina.
// ---------------------------------------------------------------------------

import { supabase } from './supabase'
import { explicarError } from './errores'

export const TIPOS_EQUIPO = [
  ['generador', 'Generador'],
  ['solar', 'Sistema solar'],
  ['bateria', 'Batería'],
  ['otro', 'Otro'],
]

// El combustible decide la clase de precio del diagnóstico, por eso es lista cerrada.
export const COMBUSTIBLES = [
  ['gasolina', 'Gasolina'],
  ['gas_lp', 'Gas LP'],
  ['gas_natural', 'Gas natural'],
  ['diesel', 'Diésel'],
]

// ---- reglas puras ----

const etiqueta = (lista, clave) => lista.find(([v]) => v === clave)?.[1] || clave

export const nombreTipoEquipo = t => etiqueta(TIPOS_EQUIPO, t)
export const nombreCombustible = c => (c ? etiqueta(COMBUSTIBLES, c) : null)

export const faltaSerie = eq => !eq?.numero_serie

// Cómo se lee un equipo en una lista: lo que sirve para reconocerlo de un vistazo.
// La serie va al final porque es lo que menos ayuda a distinguirlo en el sitio.
export function descripcionEquipo(eq) {
  if (!eq) return ''
  const partes = [
    [eq.marca, eq.modelo].filter(Boolean).join(' '),
    eq.capacidad_kw ? `${eq.capacidad_kw} kW` : null,
    eq.ubicacion_equipo,
  ].filter(Boolean)
  if (partes.length === 0) partes.push(nombreTipoEquipo(eq.tipo))
  return partes.join(' · ')
}

// El horómetro sin su fecha no dice nada: 1,200 horas de hace dos años no es el estado
// de hoy. Si no hay fecha, se dice que no se sabe de cuándo es.
export function textoHorometro(eq) {
  if (eq?.horas_uso === null || eq?.horas_uso === undefined || eq.horas_uso === '') return null
  const horas = Number(eq.horas_uso).toLocaleString('es-MX')
  if (!eq.horas_uso_fecha) return `${horas} h (sin fecha)`
  const f = new Date(`${eq.horas_uso_fecha}T12:00:00`).toLocaleDateString('es-MX', { dateStyle: 'short' })
  return `${horas} h al ${f}`
}

// Qué se puede guardar. Se pide poco a propósito: el técnico está de pie, con guantes y
// bajo el sol. El tipo es lo único obligatorio porque decide de qué trabajo se trata.
export function revisarDatosEquipo(form) {
  if (!form?.tipo) return 'Elige de qué tipo es el equipo.'
  if (form.capacidad_kw !== '' && form.capacidad_kw !== null && form.capacidad_kw !== undefined) {
    const n = Number(form.capacidad_kw)
    if (!Number.isFinite(n) || n <= 0) return 'La capacidad tiene que ser un número mayor que cero.'
  }
  if (form.anio !== '' && form.anio !== null && form.anio !== undefined) {
    const n = Number(form.anio)
    if (!Number.isInteger(n) || n < 1950 || n > 2100) return 'Revisa el año.'
  }
  // Sin serie se puede guardar, pero sin NADA que lo identifique no: quedaría un equipo
  // fantasma que nadie puede reconocer en la siguiente visita.
  const algo = [form.numero_serie, form.marca, form.modelo, form.ubicacion_equipo]
    .some(v => String(v ?? '').trim() !== '')
  if (!algo) return 'Escribe al menos la marca, el modelo, la serie o dónde está.'
  return null
}

// Lo que se manda a la base. Las cadenas vacías se van como ausentes: Postgres no acepta
// '' en columnas numéricas, y un texto vacío no es un dato.
export function datosParaGuardar(form) {
  const limpio = {}
  for (const [k, v] of Object.entries(form || {})) {
    const s = typeof v === 'string' ? v.trim() : v
    if (s === '' || s === null || s === undefined) continue
    limpio[k] = s
  }
  if (limpio.capacidad_kw !== undefined) limpio.capacidad_kw = Number(limpio.capacidad_kw)
  if (limpio.anio !== undefined) limpio.anio = Number(limpio.anio)
  return limpio
}

function textoDeError(error) {
  const codigo = String(error?.code || '')
  if (['22023', 'P0002', '42501'].includes(codigo) && error?.message) return error.message
  return explicarError(error).texto
}

// ---- llamadas ----

async function llamar(nombre, args) {
  try {
    const { data, error } = await supabase.rpc(nombre, args)
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true, data }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

// Los equipos que ese cliente ya tiene guardados. El técnico sí puede leer `equipos`
// (RLS se lo permite), así que no hace falta una función aparte.
export async function cargarEquiposDeCliente(clienteId) {
  if (!clienteId) return { ok: true, equipos: [] }
  try {
    const { data, error } = await supabase.from('equipos')
      .select('id, numero_serie, tipo, marca, modelo, capacidad_kw, ubicacion_equipo, horas_uso, horas_uso_fecha, atributos')
      .eq('cliente_id', clienteId)
      .neq('estado', 'baja')
      .order('created_at')
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true, equipos: data || [] }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

export const ligarEquipo = (ordenId, equipoId) =>
  llamar('equipo_de_orden', { p_orden: ordenId, p_equipo: equipoId })

export const altaEquipoEnOrden = (ordenId, datos) =>
  llamar('registrar_equipo_en_orden', { p_orden: ordenId, p_datos: datos })

export async function cargarEquiposSinSerie() {
  const r = await llamar('equipos_sin_serie', {})
  return r.ok ? { ok: true, equipos: r.data || [] } : r
}
