// ---------------------------------------------------------------------------
// Conciliación bancaria (SQL 75). La IA lee el estado de cuenta (leer-comprobante, modo estado_cuenta)
// y solo PROPONE; aquí se normaliza lo leído, se revisa que cuadre y se llaman las funciones de la base,
// que son las que empatan con el libro. Nada se concilia sin una acción del admin.
// ---------------------------------------------------------------------------

import { supabase } from './supabase'
import { explicarError } from './errores'
import { sha256Hex } from './finanzas'

const BUCKET = 'finanzas'

const num = v => {
  if (v === '' || v == null) return 0
  const n = Number(String(v).replace(/[$,\s]/g, ''))
  return Number.isFinite(n) ? Math.round(n * 100) / 100 : 0
}
const numONull = v => (v === '' || v == null ? null : num(v))
const fechaOk = v => (/^\d{4}-\d{2}-\d{2}$/.test(String(v || '').trim()) ? String(v).trim() : '')
const texto = v => (typeof v === 'string' ? v.trim() : v == null ? '' : String(v))

// Lo que devolvió la IA, sin confiar en su forma. Un renglón sin fecha válida o con cargo Y abono (o
// ninguno) se descarta y se cuenta, para que la persona sepa que algo no se pudo leer.
export function normalizarEstadoCuenta(leido) {
  const x = leido && typeof leido === 'object' ? leido : {}
  const crudos = Array.isArray(x.movimientos) ? x.movimientos : []
  const movimientos = []
  let descartados = 0
  for (const m of crudos) {
    const fila = {
      fecha: fechaOk(m?.fecha), descripcion: texto(m?.descripcion), referencia: texto(m?.referencia),
      cargo: num(m?.cargo), abono: num(m?.abono), saldo: numONull(m?.saldo)
    }
    if (!fila.fecha || (fila.cargo > 0) === (fila.abono > 0)) { descartados += 1; continue }
    movimientos.push(fila)
  }
  return {
    banco: texto(x.banco), cuenta_ultimos4: texto(x.cuenta_ultimos4).replace(/\D/g, '').slice(-4),
    periodo_desde: fechaOk(x.periodo_desde), periodo_hasta: fechaOk(x.periodo_hasta),
    saldo_inicial: numONull(x.saldo_inicial), saldo_final: numONull(x.saldo_final),
    notas: texto(x.notas), movimientos, descartados
  }
}

// ¿Cuadra? saldo inicial + abonos − cargos = saldo final (±1 peso). Sin saldos, no se puede decir.
export function cuadreEstado(e) {
  const abonos = Math.round((e?.movimientos || []).reduce((s, m) => s + num(m.abono), 0) * 100) / 100
  const cargos = Math.round((e?.movimientos || []).reduce((s, m) => s + num(m.cargo), 0) * 100) / 100
  if (e?.saldo_inicial == null || e?.saldo_final == null) return { abonos, cargos, diferencia: null, cuadra: null }
  const diferencia = Math.round((e.saldo_inicial + abonos - cargos - e.saldo_final) * 100) / 100
  return { abonos, cargos, diferencia, cuadra: Math.abs(diferencia) <= 1 }
}

export const sentidoDe = m => (num(m?.abono) > 0 ? 'entrada' : 'salida')

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

// Sube el PDF una sola vez y lo lee con la IA. Si la lectura falla, el archivo ya quedó guardado.
export async function subirYLeerEstado(archivo) {
  try {
    const esPdf = /pdf/.test(archivo?.type || '') || /\.pdf$/i.test(archivo?.name || '')
    if (!esPdf) return { error: 'El estado de cuenta tiene que ser el PDF del banco.' }
    if (archivo.size > 10 * 1024 * 1024) return { error: 'El PDF pesa más de 10 MB.' }
    const buf = await archivo.arrayBuffer()
    const ruta = `estados/${await sha256Hex(buf)}.pdf`
    const sube = await supabase.storage.from(BUCKET).upload(ruta, new Blob([buf], { type: 'application/pdf' }),
      { upsert: true, contentType: 'application/pdf' })
    if (sube.error) return { error: `No se pudo subir: ${textoDeError(sube.error)}` }
    const { data, error } = await supabase.functions.invoke('leer-comprobante', { body: { ruta, modo: 'estado_cuenta' } })
    if (error) {
      let detalle = ''
      try { detalle = (await error.context?.json())?.error || '' } catch { /* sin cuerpo */ }
      return { error: detalle || 'No se pudo leer el estado de cuenta.', ruta }
    }
    if (data?.error) return { error: data.error, ruta }
    if (!data?.ok) return { error: 'No entendí lo que devolvió el modelo.', ruta }
    return { ruta, estado: normalizarEstadoCuenta(data.leido) }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}

export const guardarEstado = (cuentaId, estado, ruta) =>
  rpc('registrar_estado_cuenta', {
    p_cuenta: cuentaId,
    p_datos: {
      periodo_desde: estado.periodo_desde || null, periodo_hasta: estado.periodo_hasta || null,
      saldo_inicial: estado.saldo_inicial, saldo_final: estado.saldo_final, notas: estado.notas || null,
      movimientos: estado.movimientos
    },
    p_archivo: ruta || null
  })

export async function listarEstados(cuentaId) {
  try {
    const r = await supabase.from('estados_cuenta').select('*').eq('cuenta_id', cuentaId)
      .order('periodo_hasta', { ascending: false, nullsFirst: false }).order('created_at', { ascending: false }).limit(36)
    if (r.error) return { error: textoDeError(r.error) }
    return { estados: r.data || [] }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}

export async function cargarConciliacion(estadoId) {
  try {
    const [p, r, m] = await Promise.all([
      rpc('proponer_conciliacion', { p_estado: estadoId }),
      rpc('resumen_conciliacion', { p_estado: estadoId }),
      supabase.from('movimientos_banco').select('*').eq('estado_id', estadoId).neq('estado', 'pendiente').order('fecha')
    ])
    return {
      error: p.error || r.error || (m.error ? textoDeError(m.error) : ''),
      pendientes: p.data || [],
      resumen: r.data || null,
      resueltos: m.data || []
    }
  } catch (e) {
    return { error: textoDeError(e), pendientes: [], resumen: null, resueltos: [] }
  }
}

export const conciliar = (banco, libro) => rpc('conciliar_movimiento', { p_mov_banco: banco, p_movimiento: libro })
export const conciliarSeguros = estado => rpc('conciliar_seguros', { p_estado: estado })
export const desconciliar = banco => rpc('desconciliar_movimiento', { p_mov_banco: banco })
export const ignorar = (banco, nota) => rpc('ignorar_movimiento_banco', { p_mov_banco: banco, p_nota: nota })
export const registrarDesdeBanco = (banco, categoria, concepto) =>
  rpc('registrar_desde_banco', { p_mov_banco: banco, p_categoria: categoria, p_concepto: concepto || null, p_cotizacion: null })
