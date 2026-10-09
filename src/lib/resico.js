// ---------------------------------------------------------------------------
// Reporte mensual RESICO (SQL 73). Las cifras las calcula la base (`reporte_resico`); aquí solo hay
// presentación: qué meses se pueden ver, cuál se abre primero y el CSV para el contador.
// Es un ESTIMADO para revisar con el contador, no una declaración.
// ---------------------------------------------------------------------------

import { supabase } from './supabase'
import { explicarError } from './errores'

const num = v => {
  const n = Number(v)
  return Number.isFinite(n) ? n : 0
}

// 0.011 → "1.1 %"
export function porcentaje(tasa) {
  if (tasa == null || tasa === '') return '—'
  const p = Math.round(num(tasa) * 10000) / 100
  return `${p} %`
}

const aMes = (a, m) => `${a}-${String(m).padStart(2, '0')}`

// Meses desde el alta en RESICO hasta hoy, el más reciente primero.
export function mesesDisponibles(resicoDesde, hoy) {
  const ini = /^(\d{4})-(\d{2})/.exec(String(resicoDesde || ''))
  const fin = /^(\d{4})-(\d{2})/.exec(String(hoy || ''))
  if (!fin) return []
  let a = Number(fin[1]), m = Number(fin[2])
  const ia = ini ? Number(ini[1]) : a, im = ini ? Number(ini[2]) : m
  const lista = []
  while (a > ia || (a === ia && m >= im)) {
    lista.push(aMes(a, m))
    m -= 1
    if (m === 0) { m = 12; a -= 1 }
    if (lista.length > 120) break
  }
  return lista
}

// Hasta el día 17 lo que importa es declarar el mes ANTERIOR; después, el mes en curso.
export function mesPorOmision(hoy, disponibles) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(hoy || ''))
  if (!m || !disponibles?.length) return disponibles?.[0] || ''
  const actual = aMes(Number(m[1]), Number(m[2]))
  if (Number(m[3]) <= 17) {
    let a = Number(m[1]), mes = Number(m[2]) - 1
    if (mes === 0) { mes = 12; a -= 1 }
    const anterior = aMes(a, mes)
    if (disponibles.includes(anterior)) return anterior
  }
  return disponibles.includes(actual) ? actual : disponibles[0]
}

export function resultadoIva(iva) {
  const aCargo = num(iva?.a_cargo), aFavor = num(iva?.a_favor)
  return aFavor > 0 ? { etiqueta: 'IVA a favor', monto: aFavor, aFavor: true } : { etiqueta: 'IVA a cargo', monto: aCargo, aFavor: false }
}

// ---- CSV para el contador (Excel lo abre con acentos gracias al BOM) ----

const celda = v => {
  if (v == null) return ''
  const t = typeof v === 'number' ? v.toFixed(2) : String(v)
  return /[",\n\r]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t
}

export function aCsv(filas, columnas) {
  const lineas = [columnas.map(([, titulo]) => celda(titulo)).join(',')]
  for (const f of filas || []) lineas.push(columnas.map(([clave]) => celda(f[clave])).join(','))
  return lineas.join('\r\n')
}

export function csvContador(r, nombre) {
  const i = r?.ingresos || {}, isr = r?.isr || {}, iva = r?.iva || {}, g = r?.gastos || {}
  const resumen = [
    ['Contribuyente', nombre || ''],
    ['Periodo', `${r?.periodo?.desde || ''} a ${r?.periodo?.hasta || ''}`],
    ['Ingresos cobrados (con IVA)', num(i.cobrado)],
    ['IVA trasladado cobrado', num(i.iva)],
    ['Base ISR (sin IVA)', num(i.base)],
    ['Tasa ISR RESICO', isr.tasa == null ? '' : porcentaje(isr.tasa)],
    ['ISR causado', num(isr.causado)],
    ['ISR retenido por clientes', num(isr.retenido)],
    ['ISR estimado a pagar', num(isr.a_pagar)],
    ['IVA acreditable (gastos pagados con CFDI)', num(iva.acreditable)],
    ['IVA retenido por clientes', num(iva.retenido)],
    ['IVA a cargo', num(iva.a_cargo)],
    ['IVA a favor', num(iva.a_favor)],
    ['Gastos del mes', num(g.total)],
    ['Gastos sin CFDI', num(g.sin_cfdi)],
    ['Ingresos acumulados del año', num(r?.anual?.acumulado)],
    ['Fecha límite de pago', r?.periodo?.limite_pago || '']
  ]
  const partes = [
    'RESUMEN (estimado para revisar con el contador)',
    aCsv(resumen.map(([concepto, valor]) => ({ concepto, valor })), [['concepto', 'Concepto'], ['valor', 'Valor']]),
    '',
    'INGRESOS COBRADOS',
    aCsv(i.detalle, [['fecha', 'Fecha'], ['cliente', 'Cliente'], ['cotizacion', 'Cotización'], ['monto', 'Cobrado'],
      ['iva', 'IVA'], ['base', 'Base'], ['isr_retenido', 'ISR retenido'], ['iva_retenido', 'IVA retenido'],
      ['factura', 'UUID de la factura'], ['forma', 'Forma'], ['referencia', 'Referencia']]),
    '',
    'GASTOS PAGADOS',
    aCsv(g.detalle, [['fecha', 'Fecha'], ['proveedor', 'Proveedor'], ['rfc', 'RFC'], ['categoria', 'Categoría'],
      ['concepto', 'Concepto'], ['monto', 'Pagado'], ['iva', 'IVA acreditable'], ['factura', 'UUID de la factura']])
  ]
  return '﻿' + partes.join('\r\n')
}

// ---- llamadas ----

const textoDeError = e => {
  const codigo = String(e?.code || '')
  if (['22023', '42501'].includes(codigo) && e?.message) return e.message
  return explicarError(e).texto
}

export async function cargarReporte(mes) {
  try {
    const { data, error } = await supabase.rpc('reporte_resico', { p_mes: `${mes}-01` })
    if (error) return { error: textoDeError(error) }
    if (data?.ok === false) return { error: data.motivo || 'No se pudo armar el reporte.' }
    return { reporte: data }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}

export async function cargarTasas(anio) {
  try {
    const r = await supabase.from('resico_tasas_isr').select('*').eq('anio', anio).order('desde')
    if (r.error) return { error: textoDeError(r.error) }
    return { tasas: r.data || [] }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}

// La tasa se captura en por ciento (1.1) y se guarda como fracción (0.011).
export async function guardarTasa(anio, desde, porCiento) {
  const p = Number(porCiento)
  if (porCiento === '' || !Number.isFinite(p) || p < 0 || p >= 50) return { error: 'Escribe la tasa en por ciento, por ejemplo 1.1.' }
  try {
    const r = await supabase.from('resico_tasas_isr').update({ tasa: Math.round(p * 100) / 10000 }).eq('anio', anio).eq('desde', desde)
    if (r.error) return { error: textoDeError(r.error) }
    return { ok: true }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}
