// Programación mensual de visitas (SQL 105). Solo admin.
//
// El día 1 la base abre las citas de todas las visitas de póliza del mes; aquí se arma la tarjeta que
// lo recuerda en el Inicio y deja programarlas una por una sin ir a la Agenda. Las reglas puras
// (resumen, agrupar por zona, el mensaje para coordinar con el cliente) se prueban en Node.
import { supabase } from './supabase'
import { explicarError } from './errores'
import { enlaceWhatsApp } from './avisos'

export const MESES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre']
const DIAS = ['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado']
const TIPOS_VISITA = { menor: 'servicio menor', mayor: 'servicio mayor', inspeccion: 'visita de inspección' }
const TIPOS_SERVICIO = {
  preventivo: 'mantenimiento preventivo', correctivo: 'servicio correctivo', instalacion: 'instalación',
  diagnostico: 'diagnóstico', visita_tecnica: 'visita técnica'
}

const partes = iso => String(iso).slice(0, 10).split('-').map(Number)
const iso = (a, m, d) => `${a}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`

export const nombreMes = mes => {
  const [, m] = partes(mes)
  return MESES[m - 1] || ''
}
export const primeroDeMes = fecha => {
  const [a, m] = partes(fecha)
  return iso(a, m, 1)
}
export function mesSiguiente(mes) {
  const [a, m] = partes(mes)
  return m === 12 ? iso(a + 1, 1, 1) : iso(a, m + 1, 1)
}
// El mes que conviene mostrar al entrar: del día 20 en adelante, el siguiente (es el que hay que preparar).
export function mesInicial(hoy) {
  const [, , d] = partes(hoy)
  return d >= 20 ? mesSiguiente(primeroDeMes(hoy)) : primeroDeMes(hoy)
}

export function fechaLarga(fecha) {
  if (!fecha) return 'sin fecha'
  const [a, m, d] = partes(fecha)
  const dia = new Date(Date.UTC(a, m - 1, d)).getUTCDay()
  return `${DIAS[dia]} ${d} de ${MESES[m - 1]}`
}

const mayus = t => (t ? t[0].toUpperCase() + t.slice(1) : t)

// Qué visita es, en palabras: "Servicio menor · visita 1 de 4 · POL-4", o el tipo de la cita.
export function queVisita(v) {
  if (v?.visita_tipo) {
    return [mayus(TIPOS_VISITA[v.visita_tipo] || v.visita_tipo),
      v.visita ? `visita ${v.visita} de ${v.visitas}` : null,
      v.poliza ? `POL-${v.poliza}` : null].filter(Boolean).join(' · ')
  }
  return mayus(TIPOS_SERVICIO[v?.tipo_servicio] || v?.tipo_servicio || 'mantenimiento preventivo')
}

// El resumen que lleva el encabezado de la tarjeta.
export function resumenMes(d) {
  const citas = d?.citas || []
  return {
    porProgramar: citas.filter(c => c.estado === 'por_programar').length,
    programadas: citas.filter(c => c.estado === 'programada').length,
    sinCita: (d?.sin_cita || []).length,
    sugeridos: (d?.sugeridos || []).length
  }
}
export const pendientesDelMes = r => r.porProgramar + r.sinCita

// Agrupa por zona (para armar rutas): zonas en orden alfabético, "Sin zona" al final.
export function porZona(items) {
  const mapa = new Map()
  for (const it of items || []) {
    const z = (it.zona || '').trim() || 'Sin zona'
    if (!mapa.has(z)) mapa.set(z, [])
    mapa.get(z).push(it)
  }
  return [...mapa.entries()]
    .sort(([a], [b]) => (a === 'Sin zona') - (b === 'Sin zona') || a.localeCompare(b, 'es'))
    .map(([zona, lista]) => ({ zona, lista }))
}

// Fecha propuesta al programar: la que pide la póliza, pero nunca antes de mañana.
export function fechaPropuesta(v, hoy) {
  const [a, m, d] = partes(hoy)
  const t = new Date(Date.UTC(a, m - 1, d + 1))
  const manana = iso(t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate())
  const sugerida = v?.fecha || v?.fecha_sugerida || v?.proximo || null
  return sugerida && String(sugerida).slice(0, 10) > manana ? String(sugerida).slice(0, 10) : manana
}

const nombrePila = t => {
  const p = String(t || '').trim().split(/\s+/)[0]
  return p ? p[0].toUpperCase() + p.slice(1).toLowerCase() : ''
}

// El mensaje para coordinar la fecha con el cliente (se manda por wa.me; el admin lo puede editar).
// Con póliza dice qué visita le toca; sin póliza, ofrece agendar y cotizar.
export function mensajeCoordinar(v, mes) {
  const pila = nombrePila(v?.contacto)
  const hola = pila ? `Hola ${pila},` : 'Hola,'
  const clase = !v?.equipo_tipo || v.equipo_tipo === 'generador' ? 'generador' : 'sistema'
  const equipo = v?.equipo ? ` de su ${clase} ${v.equipo}` : ''
  const nm = nombreMes(mes)
  const horario = 'Atendemos de lunes a viernes de 9:00 a 17:00 y sábados de 9:00 a 13:00.'
  if (v?.poliza || v?.visita_tipo) {
    const que = TIPOS_VISITA[v.visita_tipo] || 'mantenimiento'
    const cual = v.visita ? ` (visita ${v.visita} de ${v.visitas} de su póliza)` : ''
    return [
      hola, '',
      `Le escribimos de PowerMx. En ${nm} le toca el ${que}${equipo}${cual}.`,
      '', `¿Qué día y horario le acomodan? ${horario}`,
      '', 'PowerMx · 999 475 5275'
    ].join('\n')
  }
  return [
    hola, '',
    `Le escribimos de PowerMx. En ${nm} le toca el mantenimiento preventivo${equipo}.`,
    'Con gusto le enviamos la cotización y le agendamos la visita.',
    '', `¿Qué día le acomoda? ${horario}`,
    '', 'PowerMx · 999 475 5275'
  ].join('\n')
}
export const enlaceCoordinar = (v, mes) => enlaceWhatsApp(v?.telefono, mensajeCoordinar(v, mes))

// ---- base ----

const textoDeError = e => explicarError(e).texto
const rpc = async (nombre, args) => {
  try {
    const { data, error } = await supabase.rpc(nombre, args)
    if (error) return { error: textoDeError(error) }
    return { data }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}

export const cargarProgramacion = mes => rpc('programacion_mensual', { p_mes: mes })
export const abrirMes = mes => rpc('abrir_programacion_mensual', { p_mes: mes })
export const marcarRevisada = (mes, revisada = true) =>
  rpc('marcar_programacion_revisada', { p_mes: mes, p_revisada: revisada })
export const cargarTecnicos = () => rpc('lista_tecnicos', {})
export const programarCita = (cita, f, confirmar = false) => rpc('programar_cita', {
  p_cita: cita, p_fecha: f.fecha, p_hora: f.hora || null, p_duracion: Number(f.duracion) || null,
  p_t1: f.t1 || null, p_t2: f.t2 || null, p_confirmar: confirmar
})
