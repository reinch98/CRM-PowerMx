// ---------------------------------------------------------------------------
// Salida de WhatsApp: la cola (SQL 56) y las campañas mensuales (SQL 57).
//
// Aquí NO se decide nada que importe para la seguridad o el dinero: ventana de 24 h, bajas,
// tope de marketing y plantillas aprobadas se revisan en la base. Esto solo traduce a
// palabras lo que la base dice y llama a sus funciones.
// ---------------------------------------------------------------------------

import { supabase } from './supabase'
import { explicarError } from './errores'

// ---- reglas puras ----

const ESTADOS = {
  por_aprobar: 'Por aprobar', pendiente: 'En espera', enviando: 'Enviando', enviado: 'Enviado',
  entregado: 'Entregado', leido: 'Leído', fallido: 'Falló', cancelado: 'Cancelado', sin_confirmar: 'Sin confirmar',
}
export const etiquetaEstado = e => ESTADOS[e] || e || '—'

const ORIGENES = { aviso: 'Aviso de cita', orden: 'Orden de servicio', respuesta: 'Respuesta', campana: 'Campaña' }
export const etiquetaOrigen = o => ORIGENES[o] || o || '—'

// Reparte lo que devuelve cola_whatsapp() en lo que la oficina tiene que hacer.
//   porAprobar: esperan tu OK · esperanMeta: aprobados pero su plantilla no está aprobada
//   enCamino: aprobados con plantilla lista (salen en el siguiente minuto) · problemas: fallidos y sin confirmar
export function agruparCola(filas = []) {
  const g = { porAprobar: [], esperanMeta: [], enCamino: [], problemas: [] }
  for (const f of filas) {
    if (f.estado === 'por_aprobar') g.porAprobar.push(f)
    else if (f.estado === 'fallido' || f.estado === 'sin_confirmar') g.problemas.push(f)
    else if (f.estado === 'pendiente' && f.plantilla && f.plantilla_aprobada !== true) g.esperanMeta.push(f)
    else if (f.estado === 'pendiente') g.enCamino.push(f)
  }
  return g
}

// Cuántos esperan por cada plantilla todavía sin aprobar: "cita_confirmada: 3".
export function esperanPorPlantilla(filas = []) {
  const n = {}
  for (const f of filas) n[f.plantilla] = (n[f.plantilla] || 0) + 1
  return Object.entries(n).sort((a, b) => b[1] - a[1])
}

// Texto de la variable de plantillas: "nombre, servicio, fecha" ⇄ ['nombre','servicio','fecha'].
// Se separa SOLO por comas: "nombre del cliente" tiene que llegar entera a la validación y
// rechazarse (Meta no acepta espacios), no partirse en tres variables que sí pasarían.
export function leerVariables(texto) {
  return String(texto || '').split(/[,\n]+/).map(v => v.trim().replace(/^\{+|\}+$/g, '').trim().toLowerCase())
    .filter(Boolean)
}
export const variablesValidas = vars => vars.every(v => /^[a-z][a-z0-9_]*$/.test(v))

// Meses de la campaña: oct-2026 a sep-2027.
const MESES = ['Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio', 'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre']
export function nombreMes(mes) {
  const m = /^(\d{4})-(\d{2})$/.exec(mes || '')
  return m ? `${MESES[Number(m[2]) - 1]} ${m[1]}` : mes || ''
}
export function mesesCampana(desde = '2026-10', n = 12) {
  let [a, m] = desde.split('-').map(Number)
  const out = []
  for (let i = 0; i < n; i++) {
    out.push(`${a}-${String(m).padStart(2, '0')}`)
    m++; if (m > 12) { m = 1; a++ }
  }
  return out
}
// El mes en curso si cae en la campaña; si no, el primero.
export function mesInicial(hoy = new Date(), meses = mesesCampana()) {
  const actual = `${hoy.getFullYear()}-${String(hoy.getMonth() + 1).padStart(2, '0')}`
  return meses.includes(actual) ? actual : meses[0]
}

// Resultado de un envío de campaña en una palabra (la más importante gana).
export function resultadoEnvio(d) {
  if (d.baja) return 'Pidió BAJA'
  if (d.cita) return 'Sacó cita'
  if (d.respondio) return 'Respondió'
  if (d.estado === 'omitido') return d.motivo ? `Omitido: ${d.motivo}` : 'Omitido'
  if (d.enviado_en) return 'Enviado, sin respuesta'
  if (d.estado === 'aprobado') return 'En la cola'
  if (d.estado === 'en_tanda') return 'En la tanda'
  return 'Por proponer'
}

export function porcentaje(parte, total) {
  if (!total) return '—'
  return `${Math.round((parte / total) * 100)} %`
}

// ---- llamadas ----

function textoDeError(error) {
  const codigo = String(error?.code || '')
  if (['22023', 'P0002', '42501'].includes(codigo) && error?.message) return error.message
  return explicarError(error).texto
}

async function llamar(nombre, args) {
  try {
    const { data, error } = await supabase.rpc(nombre, args)
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true, data }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

async function tabla(consulta) {
  try {
    const { data, error } = await consulta
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true, data }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

export async function cargarCola() {
  const r = await llamar('cola_whatsapp', {})
  return r.ok ? { ok: true, filas: r.data || [] } : r
}
export const aprobarSalida = ids => llamar('aprobar_salida', { p_ids: ids })
export const cancelarSalida = (ids, motivo) => llamar('cancelar_salida', { p_ids: ids, p_motivo: motivo || null })
export const responderPorApi = (conversacionId, texto, borradorId = null) =>
  llamar('responder_whatsapp', { p_conversacion: conversacionId, p_texto: texto, p_borrador: borradorId })

export async function cargarConfig() {
  const r = await tabla(supabase.from('wa_config').select('envio_activo, avisos_automaticos, dias_entre_marketing').maybeSingle())
  return r.ok ? { ok: true, config: r.data || { envio_activo: false, avisos_automaticos: false, dias_entre_marketing: 30 } } : r
}
export const guardarConfig = cambios =>
  tabla(supabase.from('wa_config').update({ ...cambios, updated_at: new Date().toISOString() }).eq('id', true))

export async function cargarPlantillas() {
  const r = await tabla(supabase.from('wa_plantillas')
    .select('nombre, idioma, categoria, uso, variables, encabezado, estado, notas').order('nombre'))
  return r.ok ? { ok: true, plantillas: r.data || [] } : r
}
export const guardarPlantilla = (nombre, cambios) =>
  tabla(supabase.from('wa_plantillas').update({ ...cambios, updated_at: new Date().toISOString() }).eq('nombre', nombre))

// Todo lo de un mes de campaña: resultados, la tanda propuesta (si hay) y sus renglones.
export async function cargarCampana(mes) {
  const [res, tandas] = await Promise.all([
    llamar('resultados_campana', { p_mes: mes }),
    tabla(supabase.from('campana_tandas').select('id, numero, estado, aprobada_en').eq('mes', mes).order('numero')),
  ])
  if (!res.ok) return res
  if (!tandas.ok) return tandas
  const propuesta = (tandas.data || []).find(t => t.estado === 'propuesta') || null
  let enTanda = []
  if (propuesta) {
    const r = await tabla(supabase.from('campana_envios')
      .select('id, categoria, prioridad, telefono, nombre, equipo, plantilla, orden')
      .eq('tanda_id', propuesta.id).eq('estado', 'en_tanda').order('orden'))
    if (!r.ok) return r
    enTanda = r.data || []
  }
  return { ok: true, resultados: res.data, tandas: tandas.data || [], propuesta, enTanda }
}
export const proponerTanda = (mes, n) => llamar('proponer_tanda', { p_mes: mes, p_n: n })
export const quitarDeTanda = (ids, omitir = false, motivo = null) =>
  llamar('quitar_de_tanda', { p_ids: ids, p_omitir: omitir, p_motivo: motivo })
export const aprobarTanda = id => llamar('aprobar_tanda', { p_tanda: id })
export const cancelarTanda = id => llamar('cancelar_tanda', { p_tanda: id })
