// Pólizas de servicio (SQL 97). Solo admin: llevan precio.
//
// La base decide todo lo que importa (el calendario de cada nivel, abrir las citas, que una visita
// siga a su cita). Aquí solo se prepara lo que se manda y se dice el estado con palabras. El plan de
// visitas se repite en `planDeVisitas` SOLO para mostrarlo antes de guardar: tiene que dar lo mismo
// que `_plan_poliza` de la base, y la prueba en Node usa los mismos casos que la prueba SQL.
import { supabase } from './supabase'
import { explicarError } from './errores'

export const NIVELES = [
  { clave: 'basica', titulo: 'Básica', resumen: 'Servicio menor y mayor. Emergencias al siguiente día hábil.' },
  { clave: 'estandar', titulo: 'Estándar', resumen: '4 visitas: menor, mayor y 2 inspecciones. Emergencias en 24 h y 10 % en correctivos.' },
  { clave: 'integral', titulo: 'Integral', resumen: 'Como Estándar, o mensual con banco de carga en industriales. Emergencias en 6 h, 24/7, y 15–20 % en correctivos.' }
]
export const ALCANCES = [
  { clave: 'aire', titulo: 'Enfriado por aire (anexo A)' },
  { clave: 'liquido', titulo: 'Enfriado por líquido (anexo B)' }
]
const TIPOS = { menor: 'Servicio menor', mayor: 'Servicio mayor', inspeccion: 'Inspección' }

export const tituloNivel = n => NIVELES.find(x => x.clave === n)?.titulo || n || '—'
export const textoTipoVisita = v => `${TIPOS[v?.tipo] || v?.tipo || 'Visita'}${v?.banco_carga ? ' con banco de carga' : ''}`

// ---- fechas (ISO 'AAAA-MM-DD', sin zonas horarias: todo es fecha de calendario) ----

const partes = iso => iso.split('-').map(Number)
const iso = (a, m, d) => `${a}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`
const diasDelMes = (a, m) => new Date(Date.UTC(a, m, 0)).getUTCDate()

// Igual que Postgres con `fecha + interval 'n months'`: el 31 de enero + 1 mes es el 28 (o 29) de febrero.
export function sumarMeses(fecha, n) {
  const [a, m, d] = partes(fecha)
  const total = (a * 12 + (m - 1)) + n
  const na = Math.floor(total / 12)
  const nm = total - na * 12 + 1
  return iso(na, nm, Math.min(d, diasDelMes(na, nm)))
}
export function sumarDiasIso(fecha, n) {
  const [a, m, d] = partes(fecha)
  const t = new Date(Date.UTC(a, m - 1, d + n))
  return iso(t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate())
}
export function diasEntre(desde, hasta) {
  const [a1, m1, d1] = partes(desde)
  const [a2, m2, d2] = partes(hasta)
  return Math.round((Date.UTC(a2, m2 - 1, d2) - Date.UTC(a1, m1 - 1, d1)) / 86400000)
}
export const finDePoliza = inicio => sumarDiasIso(sumarMeses(inicio, 12), -1)

export function fechaCorta(fecha) {
  if (!fecha) return '—'
  const [a, m, d] = partes(fecha)
  return `${String(d).padStart(2, '0')}/${String(m).padStart(2, '0')}/${String(a).slice(2)}`
}

// ---- reglas ----

// Aire o líquido, igual que `_alcance_de_equipo`: lo que diga el modelo (SQL 94), si no el
// combustible (diésel = líquido) y la capacidad (30 kW o más = líquido).
export function alcanceDeEquipo(e) {
  const enf = e?.atributos?.enfriamiento
  if (['liquid_cooled', 'liquido'].includes(enf)) return 'liquido'
  if (['air_cooled', 'aire'].includes(enf)) return 'aire'
  if (e?.atributos?.combustible === 'diesel') return 'liquido'
  if (Number(e?.capacidad_kw || 0) >= 30) return 'liquido'
  return 'aire'
}

export function planDeVisitas(nivel, alcance, inicio) {
  let meses
  if (nivel === 'basica') meses = [[0, 'menor'], [6, 'mayor']]
  else if (nivel === 'estandar' || (nivel === 'integral' && alcance === 'aire')) {
    meses = [[0, 'menor'], [3, 'inspeccion'], [6, 'mayor'], [9, 'inspeccion']]
  } else if (nivel === 'integral' && alcance === 'liquido') {
    meses = Array.from({ length: 12 }, (_, g) => [g, g === 0 ? 'menor' : g === 6 ? 'mayor' : 'inspeccion'])
  } else return []
  return meses.map(([mes, tipo], i) => ({
    numero: i + 1, tipo, banco_carga: nivel === 'integral' && alcance === 'liquido' && mes === 6,
    fecha: inicio ? sumarMeses(inicio, mes) : null
  }))
}

export function totalesPoliza(subtotal) {
  const s = Math.max(0, Number(subtotal) || 0)
  const iva = Math.round(s * 16) / 100
  return { subtotal: s, iva, total: Math.round((s + iva) * 100) / 100 }
}

// Estado de la póliza con palabra. "Por vencer" = vigente, sin renovar y a 30 días o menos del fin.
export function estadoPoliza(p, hoy) {
  if (p?.estado === 'cancelada') return { clave: 'cancelada', etiqueta: 'Cancelada', clase: 'estado-cancelada' }
  if (p?.fin < hoy) {
    return p?.renovada
      ? { clave: 'terminada', etiqueta: 'Terminada · renovada', clase: 'estado-cancelada' }
      : { clave: 'vencida', etiqueta: 'Vencida', clase: 'estado-vencida' }
  }
  if (p?.inicio > hoy) return { clave: 'por_iniciar', etiqueta: 'Por iniciar', clase: 'estado-enviada' }
  const dias = diasEntre(hoy, p.fin)
  if (dias <= 30 && !p?.renovada) {
    return { clave: 'por_vencer', etiqueta: `Vence en ${dias} ${dias === 1 ? 'día' : 'días'}`, clase: 'estado-vencida' }
  }
  return { clave: 'vigente', etiqueta: p?.renovada ? 'Vigente · ya renovada' : 'Vigente', clase: 'estado-aceptada' }
}

// Estado de una visita. Atrasada = su fecha ya pasó, no se ha hecho y no tiene una cita futura.
export function estadoVisita(v, hoy) {
  if (v?.estado === 'realizada') return { etiqueta: `Hecha el ${fechaCorta(v.realizada_en)}`, clase: 'estado-realizada', atrasada: false }
  if (v?.estado === 'omitida') return { etiqueta: 'Omitida', clase: 'estado-cancelada', atrasada: false }
  if (v?.estado === 'cancelada') return { etiqueta: 'Cancelada', clase: 'estado-cancelada', atrasada: false }
  const programada = v?.estado === 'agendada' && v?.cita_estado === 'programada'
  const atrasada = !!v?.fecha && v.fecha < hoy && !(programada && v?.cita_fecha >= hoy)
  if (programada) {
    return { etiqueta: `Cita el ${fechaCorta(v.cita_fecha)}`, clase: atrasada ? 'estado-rechazada' : 'estado-programada', atrasada }
  }
  if (v?.estado === 'agendada') {
    return atrasada
      ? { etiqueta: 'Atrasada · falta programarla', clase: 'estado-rechazada', atrasada }
      : { etiqueta: 'Por programar en la Agenda', clase: 'estado-por_programar', atrasada }
  }
  return atrasada
    ? { etiqueta: 'Atrasada', clase: 'estado-rechazada', atrasada }
    : { etiqueta: 'Pendiente', clase: 'estado-pendiente', atrasada }
}

export function resumenPolizas(lista, hoy) {
  let vigentes = 0, porVencer = 0, atrasadas = 0, vencidas = 0
  for (const p of lista || []) {
    const e = estadoPoliza(p, hoy).clave
    if (['vigente', 'por_vencer', 'por_iniciar'].includes(e)) vigentes++
    if (e === 'por_vencer') porVencer++
    if (e === 'vencida') vencidas++
    if (p.estado === 'vigente') atrasadas += (p.visitas || []).filter(v => estadoVisita(v, hoy).atrasada).length
  }
  return { vigentes, porVencer, atrasadas, vencidas }
}

export function filtrarPolizas(lista, filtro, hoy) {
  return (lista || []).filter(p => {
    const e = estadoPoliza(p, hoy).clave
    if (filtro === 'vigentes') return ['vigente', 'por_vencer', 'por_iniciar'].includes(e)
    if (filtro === 'atender') {
      return e === 'por_vencer' || e === 'vencida'
        || (p.estado === 'vigente' && (p.visitas || []).some(v => estadoVisita(v, hoy).atrasada))
    }
    return true
  })
}

// Lo que falta antes de poder guardar.
export function faltasPoliza(f) {
  const faltas = []
  if (!f?.equipo_id) faltas.push('Elige el equipo.')
  if (!f?.nivel) faltas.push('Elige el nivel.')
  if (!f?.inicio) faltas.push('Escribe la fecha de inicio.')
  if (!(Number(f?.subtotal) > 0)) faltas.push('Escribe el precio antes de IVA.')
  return faltas
}

export function describirEquipo(e) {
  return [e?.marca, e?.modelo, e?.capacidad_kw ? `${e.capacidad_kw} kW` : null].filter(Boolean).join(' ') || 'Generador'
}

export function buscarEquipos(equipos, texto) {
  const q = (texto || '').trim().toLowerCase()
  if (!q) return equipos || []
  return (equipos || []).filter(e =>
    [e.clientes?.nombre, e.marca, e.modelo, e.numero_serie].filter(Boolean).join(' ').toLowerCase().includes(q))
}

// ---- base ----

const textoDeError = e => {
  const codigo = String(e?.code || '')
  if (['22023', '42501'].includes(codigo) && e?.message) return e.message
  return explicarError(e).texto
}
const rpc = async (nombre, args) => {
  try {
    const { data, error } = await supabase.rpc(nombre, args)
    if (error) return { error: textoDeError(error) }
    return { data }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}

export const cargarPolizas = () => rpc('polizas_lista', { p_dias: 400 })
export const crearPoliza = datos => rpc('crear_poliza', { p_datos: datos })
export const cancelarPoliza = (id, motivo) => rpc('cancelar_poliza', { p_poliza: id, p_motivo: motivo })
export const omitirVisita = (id, motivo) => rpc('omitir_visita_poliza', { p_visita: id, p_motivo: motivo })

export async function cargarEquiposParaPoliza() {
  try {
    const { data, error } = await supabase.from('equipos')
      .select('id, cliente_id, tipo, marca, modelo, capacidad_kw, numero_serie, atributos, en_poliza, clientes(nombre)')
      .eq('tipo', 'generador')
      .order('created_at', { ascending: false })
    if (error) return { error: textoDeError(error) }
    return { data: data || [] }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}
