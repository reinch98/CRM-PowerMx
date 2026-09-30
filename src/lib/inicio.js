// ---------------------------------------------------------------------------
// El inicio del admin (SQL 42): lo que está esperando, y el día de hoy.
//
// Los textos vienen armados desde la base, así que aquí solo hay reglas de presentación:
// cómo se llama cada nivel en palabras y cómo se lee una cita del día.
// ---------------------------------------------------------------------------

import { supabase } from './supabase'
import { explicarError } from './errores'

// Nunca solo color: el nivel se dice con palabra. "Alto" no es rojo, es "Atender hoy".
export const NIVELES = {
  alto:  'Atender hoy',
  medio: 'Esta semana',
  bajo:  'Cuando se pueda',
}
export const etiquetaNivel = n => NIVELES[n] ?? 'Pendiente'

// Los avisos agrupados por nivel, en el orden en que los manda la base (ya vienen ordenados)
// y sin niveles vacíos.
export function porNivel(urgente) {
  const grupos = []
  for (const nivel of ['alto', 'medio', 'bajo']) {
    const items = (urgente || []).filter(u => u.nivel === nivel)
    if (items.length) grupos.push({ nivel, etiqueta: etiquetaNivel(nivel), items })
  }
  return grupos
}

// Cuántas cosas esperan en total. Sirve para el encabezado: "8 cosas esperando" dice más que
// una lista sin resumen.
export const cuantasEsperan = urgente =>
  (urgente || []).reduce((n, u) => n + Number(u.n || 0), 0)

// Cómo se lee una cita del día: hora, cliente y quién va. Sin hora, "sin hora".
export function textoCita(c) {
  const partes = [c?.hora || 'sin hora', c?.cliente].filter(Boolean)
  const quien = c?.tecnico ? ` · ${c.tecnico}` : ' · sin técnico asignado'
  return partes.join(' · ') + quien
}

// Un día sin citas no es un error: es un día libre, y se dice así.
export const hayDia = hoy => (hoy || []).length > 0

export async function cargarInicio() {
  try {
    const { data, error } = await supabase.rpc('inicio_admin')
    if (error) return { ok: false, texto: explicarError(error).texto }
    return { ok: true, datos: data && typeof data === 'object' ? data : {} }
  } catch (e) {
    return { ok: false, texto: explicarError(e).texto }
  }
}
