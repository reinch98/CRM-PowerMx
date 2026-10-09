// ---------------------------------------------------------------------------
// Tablero de dirección (SQL 74). Todas las cifras las calcula la base (`tablero_direccion`); aquí solo
// hay presentación: nombres en palabras, escala de la gráfica y el margen total ponderado.
// ---------------------------------------------------------------------------

import { supabase } from './supabase'
import { explicarError } from './errores'

const num = v => {
  const n = Number(v)
  return Number.isFinite(n) ? n : 0
}

export const LINEAS = {
  generadores: 'Generadores', solar: 'Solar', rentas: 'Rentas', polizas: 'Pólizas', otros: 'Sin clasificar'
}
export const nombreLinea = l => LINEAS[l] || l || 'Sin clasificar'

const MESES = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic']
const MESES_LARGOS = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre']
export const mesCorto = aaaamm => MESES[Number(String(aaaamm).slice(5, 7)) - 1] || ''
export const mesLargo = aaaamm => {
  const m = Number(String(aaaamm).slice(5, 7))
  return MESES_LARGOS[m - 1] ? `${MESES_LARGOS[m - 1]} ${String(aaaamm).slice(0, 4)}` : String(aaaamm)
}

// Tope "redondo" para el eje: el siguiente 1, 2 o 5 × 10^n por encima del máximo.
export function topeEje(maximo) {
  const m = num(maximo)
  if (m <= 0) return 1000
  const potencia = 10 ** Math.floor(Math.log10(m))
  for (const f of [1, 2, 5, 10]) if (f * potencia >= m) return f * potencia
  return 10 * potencia
}

// "$12k", "$1.5 M": para las etiquetas del eje, donde no caben los pesos completos.
export function pesosCortos(v) {
  const n = num(v)
  if (Math.abs(n) >= 1e6) return `$${(n / 1e6).toLocaleString('es-MX', { maximumFractionDigits: 1 })} M`
  if (Math.abs(n) >= 1e3) return `$${(n / 1e3).toLocaleString('es-MX', { maximumFractionDigits: 0 })}k`
  return `$${n.toLocaleString('es-MX', { maximumFractionDigits: 0 })}`
}

// Margen de todo el periodo, ponderado por la venta (no el promedio de los porcentajes de cada línea).
export function margenTotal(lineas) {
  const venta = (lineas || []).reduce((s, l) => s + num(l.venta), 0)
  const utilidad = (lineas || []).reduce((s, l) => s + num(l.utilidad), 0)
  return venta > 0 ? Math.round(utilidad / venta * 1000) / 10 : null
}

// Lo que llega de la base, sin confiar en su forma.
export function normalizarTablero(raw) {
  const x = raw && typeof raw === 'object' ? raw : {}
  return {
    periodo: x.periodo || {},
    resumen: { ingresos: num(x.resumen?.ingresos), gastos: num(x.resumen?.gastos), resultado: num(x.resumen?.resultado) },
    mensual: Array.isArray(x.mensual) ? x.mensual.map(m => ({ mes: m.mes, ingresos: num(m.ingresos), gastos: num(m.gastos) })) : [],
    lineas: Array.isArray(x.lineas) ? x.lineas : [],
    cxc: { total: num(x.cxc?.total), vencido: num(x.cxc?.vencido), vencidas: num(x.cxc?.vencidas), mayores: x.cxc?.mayores || [] },
    tecnicos: Array.isArray(x.tecnicos) ? x.tecnicos : [],
    operacion: x.operacion || {}
  }
}

export async function cargarTablero(meses) {
  try {
    const { data, error } = await supabase.rpc('tablero_direccion', { p_meses: meses })
    if (error) {
      const codigo = String(error.code || '')
      return { error: ['22023', '42501'].includes(codigo) && error.message ? error.message : explicarError(error).texto }
    }
    return { tablero: normalizarTablero(data) }
  } catch (e) {
    return { error: explicarError(e).texto }
  }
}
