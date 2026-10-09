// ---------------------------------------------------------------------------
// Comisiones del técnico y pagos a técnicos (SQL 66 y 67).
//
// Lo que ve el TÉCNICO sale de `mis_comisiones()`: solo lo suyo, y el monto aparece hasta que el
// administrador aprueba el pago. Una orden cerrada sin aprobar se ve "En revisión", sin cifra:
// así no se promete una cantidad que todavía puede ajustarse.
//
// El estado de la orden (cerrada) y el de la comisión (en revisión / aprobada / pagada) son cosas
// distintas a propósito: cerrar no significa que ya se aprobó el pago.
// ---------------------------------------------------------------------------

import { supabase } from './supabase'
import { explicarError } from './errores'
import { leerLocal, escribirLocal } from './local'

export const CACHE_COMISIONES = 'cache_comisiones'

export const ESTADOS_COMISION = {
  en_revision: { etiqueta: 'En revisión', clase: 'estado-pendiente', ayuda: 'La orden ya cerró. El monto aparece cuando el administrador lo apruebe.' },
  aprobada: { etiqueta: 'Aprobada', clase: 'estado-enviada', ayuda: 'Aprobada: está por pagarse.' },
  pagada: { etiqueta: 'Pagada', clase: 'estado-aceptada', ayuda: 'Ya se pagó.' }
}

export const TIPOS_SERVICIO = {
  preventivo: 'Preventivo', correctivo: 'Correctivo', instalacion: 'Instalación',
  diagnostico: 'Diagnóstico', visita_tecnica: 'Visita técnica'
}
export const nombreServicio = t => TIPOS_SERVICIO[t] || (t ? String(t) : 'Servicio')
export const etiquetaRol = r => (r === 'ayudante' ? 'Ayudante' : 'Responsable')

const num = v => {
  const n = Number(v)
  return Number.isFinite(n) ? n : 0
}
export const pesos = v => num(v).toLocaleString('es-MX', { style: 'currency', currency: 'MXN' })

const MESES = ['Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio', 'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre']

// La fecha de la base viene como 'AAAA-MM-DD'. Se lee como texto: new Date('2026-10-09') es UTC y
// en Mérida mostraría el día anterior.
export function fechaCorta(iso) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso || ''))
  if (!m) return ''
  return `${Number(m[3])} ${MESES[Number(m[2]) - 1].slice(0, 3).toLowerCase()}`
}

// Lo que llega de la base (o de la copia local), sin confiar en su forma.
export function normalizarComisiones(raw) {
  const x = raw && typeof raw === 'object' ? raw : {}
  const r = x.resumen || {}
  return {
    resumen: { por_cobrar: num(r.por_cobrar), pagado_mes: num(r.pagado_mes), en_revision: num(r.en_revision) },
    ordenes: Array.isArray(x.ordenes) ? x.ordenes.filter(o => o && ESTADOS_COMISION[o.estado]) : [],
    ajustes: Array.isArray(x.ajustes) ? x.ajustes : []
  }
}

// Agrupa por mes (el más reciente primero) con lo ya aprobado o pagado de cada mes.
export function agruparPorMes(ordenes) {
  const grupos = new Map()
  for (const o of ordenes || []) {
    const clave = String(o.fecha || '').slice(0, 7) || 'sin-fecha'
    if (!grupos.has(clave)) grupos.set(clave, [])
    grupos.get(clave).push(o)
  }
  return Array.from(grupos.entries())
    .sort(([a], [b]) => (a < b ? 1 : -1))
    .map(([mes, lista]) => {
      const [a, m] = mes.split('-').map(Number)
      return {
        mes,
        titulo: MESES[m - 1] ? `${MESES[m - 1]} ${a}` : 'Sin fecha',
        ordenes: lista,
        total: lista.reduce((s, o) => s + (o.estado !== 'en_revision' ? num(o.monto) : 0), 0),
        en_revision: lista.filter(o => o.estado === 'en_revision').length
      }
    })
}

export const FILTROS = [
  ['todas', 'Todas'], ['en_revision', 'En revisión'], ['aprobada', 'Aprobadas'], ['pagada', 'Pagadas']
]
export const filtrar = (ordenes, filtro) =>
  filtro === 'todas' ? ordenes || [] : (ordenes || []).filter(o => o.estado === filtro)

const textoDeError = e => {
  const codigo = String(e?.code || '')
  if (['22023', '42501'].includes(codigo) && e?.message) return e.message
  return explicarError(e).texto
}

export function copiaLocal() {
  const c = leerLocal(CACHE_COMISIONES, null)
  return c?.datos ? { ...normalizarComisiones(c.datos), guardado_en: c.en } : null
}

// Pide las comisiones y guarda una copia para verlas sin señal.
export async function cargarMisComisiones(dias = 120) {
  try {
    const { data, error } = await supabase.rpc('mis_comisiones', { p_dias: dias })
    if (error) return { error: textoDeError(error), datos: copiaLocal() }
    const datos = normalizarComisiones(data)
    escribirLocal(CACHE_COMISIONES, { datos, en: new Date().toISOString() })
    return { datos }
  } catch (e) {
    return { error: textoDeError(e), datos: copiaLocal() }
  }
}

// ---- lado del administrador (pagos a técnicos) ----

export const ESTADOS_PAGO = {
  propuesto: { etiqueta: 'Borrador', clase: 'estado-borrador' },
  aprobado: { etiqueta: 'Aprobado · por pagar', clase: 'estado-enviada' },
  pagado: { etiqueta: 'Pagado', clase: 'estado-aceptada' },
  cancelado: { etiqueta: 'Cancelado', clase: 'estado-cancelada' }
}

export function validarTarifa(t) {
  if (!TIPOS_SERVICIO[t.tipo_servicio]) return 'Elige el tipo de servicio.'
  if (!['responsable', 'ayudante'].includes(t.rol)) return 'Elige el rol.'
  if (t.monto === '' || t.monto == null || !(Number(t.monto) >= 0)) return 'Escribe el monto (puede ser 0).'
  if (!/^\d{4}-\d{2}-\d{2}$/.test(t.vigente_desde || '')) return 'Escribe desde cuándo aplica.'
  return ''
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

export const porPagarTecnicos = () => rpc('por_pagar_tecnicos', {})
export const proponerPago = (tecnico, desde, hasta) =>
  rpc('proponer_pago_tecnico', { p_tecnico: tecnico, p_desde: desde, p_hasta: hasta })
export const ajustarPago = (pago, concepto, monto) =>
  rpc('ajustar_pago_tecnico', { p_pago: pago, p_concepto: concepto, p_monto: num(monto) })
export const quitarLinea = linea => rpc('quitar_linea_pago_tecnico', { p_linea: linea })
export const aprobarPago = pago => rpc('aprobar_pago_tecnico', { p_pago: pago })
export const registrarPago = (pago, { forma, referencia, fecha, cuenta_id }) =>
  rpc('registrar_pago_tecnico', {
    p_pago: pago, p_forma: forma, p_referencia: referencia || null, p_fecha: fecha || null,
    p_archivo: null, p_cuenta: cuenta_id || null
  })
export const cancelarPago = (pago, motivo) => rpc('cancelar_pago_tecnico', { p_pago: pago, p_motivo: motivo })

export async function cargarPagos() {
  try {
    const p = await supabase.from('pagos_tecnico').select('*').in('estado', ['propuesto', 'aprobado', 'pagado'])
      .order('created_at', { ascending: false }).limit(60)
    if (p.error) return { error: textoDeError(p.error) }
    const ids = (p.data || []).map(x => x.id)
    let lineas = []
    if (ids.length) {
      const l = await supabase.from('pagos_tecnico_lineas').select('*').in('pago_id', ids).eq('activa', true).order('created_at')
      if (l.error) return { error: textoDeError(l.error) }
      lineas = l.data || []
    }
    return { pagos: (p.data || []).map(x => ({ ...x, lineas: lineas.filter(l => l.pago_id === x.id) })) }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}

// Nombres de los técnicos (id → nombre) para mostrar los pagos.
export async function nombresTecnicos() {
  const r = await rpc('lista_tecnicos', {})
  return Object.fromEntries((r.data || []).map(t => [t.id, t.nombre]))
}

// Folio, fecha y cliente de las órdenes de las líneas de pago.
export async function infoOrdenes(ids) {
  const unicos = [...new Set((ids || []).filter(Boolean))]
  if (!unicos.length) return {}
  try {
    const r = await supabase.from('ordenes_servicio').select('id, folio, fecha, cliente:clientes(nombre)').in('id', unicos)
    if (r.error) return {}
    return Object.fromEntries((r.data || []).map(o => [o.id, o]))
  } catch {
    return {}
  }
}

export async function cargarTarifas() {
  try {
    const r = await supabase.from('tarifas_pago_tecnico').select('*')
      .order('tipo_servicio').order('rol').order('vigente_desde', { ascending: false })
    if (r.error) return { error: textoDeError(r.error) }
    return { tarifas: r.data || [] }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}

export async function guardarTarifa(t) {
  const problema = validarTarifa(t)
  if (problema) return { error: problema }
  try {
    const fila = {
      tipo_servicio: t.tipo_servicio, rol: t.rol, monto: num(t.monto), vigente_desde: t.vigente_desde,
      vigente_hasta: t.vigente_hasta || null, tecnico_id: t.tecnico_id || null, notas: (t.notas || '').trim() || null
    }
    const r = t.id
      ? await supabase.from('tarifas_pago_tecnico').update(fila).eq('id', t.id)
      : await supabase.from('tarifas_pago_tecnico').insert(fila)
    if (r.error) {
      if (String(r.error.code) === '23505') return { error: 'Ya hay una tarifa para ese servicio, rol y fecha.' }
      return { error: textoDeError(r.error) }
    }
    return { ok: true }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}
