// Solicitudes de cotización que llegan del sitio público (SQL 36).
// Las reglas puras van arriba (probadas en pruebas/solicitudesWeb.prueba.js); las llamadas
// a la base, abajo.
import { supabase } from './supabase'
import { explicarError } from './errores'
import { enlaceWhatsApp } from './whatsapp'

// ---- reglas puras ----

export const ESTADOS = ['nueva', 'atendida', 'descartada']
export const ETIQUETA_ESTADO = { nueva: 'Nueva', atendida: 'Atendida', descartada: 'Descartada' }

// Las nuevas primero y, dentro de cada estado, las más recientes arriba.
export function ordenarSolicitudes(lista) {
  const peso = { nueva: 0, atendida: 1, descartada: 2 }
  return [...(lista || [])].sort((a, b) =>
    (peso[a.estado] ?? 9) - (peso[b.estado] ?? 9) ||
    new Date(b.created_at) - new Date(a.created_at))
}

export function contarNuevas(lista) {
  return (lista || []).filter(s => s.estado === 'nueva').length
}

// Lo que el cliente marcó, en renglones legibles. Solo los datos que sí trae.
export function detalleSolicitud(s) {
  const filas = [
    ['Equipo', s.tipos],
    ['Uso', s.uso],
    ['Equipo actual', s.equipo_actual && s.equipo_actual !== '—' ? s.equipo_actual : null],
    ['Consumo', s.consumo],
    ['Presupuesto', s.presupuesto],
    ['Plazo', s.plazo],
    ['Nos conoció por', s.fuente],
    ['Ubicación', s.ubicacion],
    ['Correo', s.email],
  ]
  return filas.filter(([, v]) => v && String(v).trim()).map(([etiqueta, valor]) => ({ etiqueta, valor }))
}

// El primer mensaje para contestarle: saluda por su nombre y dice qué pidió.
export function mensajeDeRespuesta(s) {
  const primero = String(s?.nombre || '').trim().split(/\s+/)[0] || ''
  const que = s?.tipos ? ` sobre ${s.tipos.toLowerCase()}` : ''
  return `Hola${primero ? ` ${primero}` : ''}, le escribimos de PowerMx. Recibimos su solicitud de cotización${que}. ¿Tiene un momento para platicar los detalles?`
}

export const enlaceRespuesta = s => enlaceWhatsApp(s?.telefono, mensajeDeRespuesta(s))

// ---- llamadas ----

function textoDeError(error) {
  const codigo = String(error?.code || '')
  if (['22023', 'P0002', '42501'].includes(codigo) && error?.message) return error.message
  return explicarError(error).texto
}

export async function cargarSolicitudes() {
  try {
    const { data, error } = await supabase.from('solicitudes_web')
      .select('*, clientes(nombre)')
      .order('created_at', { ascending: false })
      .limit(200)
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true, solicitudes: data || [] }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

export async function resolverSolicitud(id, estado, nota, cliente) {
  try {
    const { error } = await supabase.rpc('resolver_solicitud_web', {
      p_id: id, p_estado: estado, p_nota: nota || null, p_cliente: cliente || null
    })
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}
