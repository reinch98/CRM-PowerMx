// ---------------------------------------------------------------------------
// Semáforo de vigencia de cotizaciones (pedido de Caña, 19/11/2026).
//
// Una cotización en borrador o enviada vence `vigencia_dias` (15 por omisión)
// después de su fecha. El reloj diario de la base (SQL 102) la pasa a `vencida`;
// mientras tanto la pantalla ya la pinta en rojo. Vencida o rechazada = archivada:
// no se borra, se oculta de la lista y se reactiva pasándola a Borrador.
//
// Siempre devuelve una PALABRA además del color: ningún estado solo con color.
// ---------------------------------------------------------------------------
import { sumarDias } from './fechas.js'

export const VIGENCIA_POR_OMISION = 15
export const DIAS_AVISO = 3          // desde aquí se pinta ámbar

const ARCHIVADAS = ['vencida', 'rechazada']
const VIVAS = ['borrador', 'enviada']

// Fecha en que vence (el último día en que todavía es válida).
export function fechaVence(c) {
  if (!c?.fecha) return null
  const dias = Number(c.vigencia_dias) > 0 ? Number(c.vigencia_dias) : VIGENCIA_POR_OMISION
  return sumarDias(c.fecha, dias)
}

// Días de `desde` a `hasta`, ambas 'AAAA-MM-DD' (positivo si `hasta` es después).
export function diasEntre(desde, hasta) {
  const a = Date.UTC(...partes(desde))
  const b = Date.UTC(...partes(hasta))
  return Math.round((b - a) / 86400000)
}

function partes(f) {
  const [y, m, d] = f.split('-').map(Number)
  return [y, m - 1, d]
}

const ddmm = f => `${f.slice(8, 10)}/${f.slice(5, 7)}`

export const esArchivada = c => ARCHIVADAS.includes(c?.estado)

// { nivel: 'vigente' | 'por_vencer' | 'vencida' | 'archivada' | null, palabra, dias }
// nivel null = no aplica (aceptada: ya no vence).
export function semaforoVigencia(c, hoy) {
  if (esArchivada(c)) {
    return { nivel: 'archivada', palabra: `Archivada · ${c.estado}`, dias: null }
  }
  if (!VIVAS.includes(c?.estado)) return { nivel: null, palabra: '', dias: null }

  const vence = fechaVence(c)
  if (!vence) return { nivel: null, palabra: 'Sin fecha', dias: null }
  const dias = diasEntre(hoy, vence)

  if (dias < 0) {
    const n = -dias
    return { nivel: 'vencida', palabra: `Vencida hace ${n} ${n === 1 ? 'día' : 'días'}`, dias }
  }
  if (dias <= DIAS_AVISO) {
    const palabra = dias === 0 ? 'Vence hoy' : dias === 1 ? 'Vence mañana' : `Vence en ${dias} días`
    return { nivel: 'por_vencer', palabra, dias }
  }
  return { nivel: 'vigente', palabra: `Vigente · vence el ${ddmm(vence)}`, dias }
}

// Lo que se ve en la lista: las archivadas solo si se piden.
export function cotizacionesVisibles(lista, verArchivadas) {
  return verArchivadas ? lista : lista.filter(c => !esArchivada(c))
}

// Conteos para el resumen de arriba de la lista.
export function resumenVigencia(lista, hoy) {
  const r = { por_vencer: 0, vencida: 0, archivada: 0 }
  for (const c of lista) {
    const { nivel } = semaforoVigencia(c, hoy)
    if (nivel in r) r[nivel]++
  }
  return r
}
