// ---------------------------------------------------------------------------
// Paquetes solares (SQL 78). El costo y el precio los calcula la BASE (costear_paquete), con la misma
// regla de margen que los productos sueltos y el IVA incluido; aquí solo se muestran y se piden.
// ---------------------------------------------------------------------------

import { supabase } from './supabase'
import { explicarError } from './errores'

export const VARIANTES = [
  { clave: 'interconectado', nombre: 'Interconectado', detalle: 'Con medidor bidireccional de CFE' },
  { clave: 'hibrido_a', nombre: 'Híbrido A', detalle: 'Interconectado + respaldo con batería' },
  { clave: 'hibrido_b', nombre: 'Híbrido B', detalle: 'Todo en el LUX: no inyecta a CFE' }
]
export const RECETAS = [
  { clave: 'interconectado', nombre: 'Interconectado' },
  { clave: 'respaldo', nombre: 'Respaldo (se suma al interconectado en el híbrido A)' },
  { clave: 'hibrido_b', nombre: 'Híbrido B' }
]
export const TIPOS_COSTO = { equipo: 'Equipo', material_local: 'Material de compra local', mano_obra: 'Mano de obra' }

const ESTADOS = {
  al_dia: { etiqueta: 'Publicado', clase: 'estado-aprobado' },
  automatico: { etiqueta: 'Se actualiza solo', clase: 'estado-revisa' },
  por_aprobar: { etiqueta: 'Por publicar', clase: 'estado-revisa' },
  falta_costo: { etiqueta: 'Falta costo', clase: 'estado-error' },
  sin_regla: { etiqueta: 'Sin regla de margen', clase: 'estado-error' }
}
export const estadoDe = e => ESTADOS[e] || { etiqueta: e || '—', clase: '' }

export const pesos = v => (v == null || v === '' || !Number.isFinite(Number(v))
  ? '—'
  : Number(v).toLocaleString('es-MX', { style: 'currency', currency: 'MXN', maximumFractionDigits: 0 }))

// Qué pasaría con el precio del sitio, en palabras.
export function textoCambio(v) {
  if (!v || v.precio == null) return ''
  if (v.publicado == null || Number(v.publicado) <= 0) return 'Todavía no tiene precio en el sitio'
  const c = Number(v.cambio_pct)
  if (!c) return v.primera ? 'Mismo precio; falta publicarlo desde la receta' : 'Igual al del sitio'
  const sentido = c > 0 ? 'Sube' : 'Baja'
  const pct = Math.abs(c).toLocaleString('es-MX', { maximumFractionDigits: 1 })
  return `${sentido} ${pct} % contra el sitio (${pesos(v.publicado)})` + (v.primera ? '; primera vez desde la receta' : '')
}

// Una variante se puede publicar si tiene precio y es distinto del publicado (o nunca salió de la receta).
export const sePuedePublicar = v => v?.precio != null && (v.estado === 'por_aprobar' || v.estado === 'automatico')

export function porPublicar(lista) {
  let n = 0
  for (const p of lista || []) for (const v of Object.values(p.variantes || {})) if (sePuedePublicar(v)) n += 1
  return n
}

export function tituloPaquete(p) {
  const partes = [p.nombre]
  if (Number(p.paneles) > 0) partes.push(`${p.paneles} paneles`)
  if (Number(p.kwp) > 0) partes.push(`${Number(p.kwp).toLocaleString('es-MX')} kWp`)
  return partes.join(' · ')
}

export function textoRegla(r) {
  if (!r) return 'Sin regla de margen: créala en Proveedor → Reglas de margen.'
  const sobre = r.sobre === 'precio' ? 'sobre el precio' : 'sobre el costo'
  const de = r.categoria ? 'la regla de paquetes' : 'la regla general'
  return `Margen de ${de}: ${Number(r.margen_pct)} % ${sobre}. Precio con IVA, terminado en 999.`
}

// ---- llamadas ----

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

export async function cargarPaquetes() {
  const r = await rpc('paquetes_solares', {})
  return r.error ? { error: r.error, paquetes: [] } : { paquetes: Array.isArray(r.data) ? r.data : [] }
}
export const publicarPrecio = (paquete, variante) => rpc('publicar_precio_paquete', { p_paquete: paquete, p_variante: variante })
export const recalcularPaquetes = () => rpc('recalcular_paquetes', {})

export async function cargarLineas(paqueteId) {
  try {
    const { data, error } = await supabase.from('paquete_solar_lineas')
      .select('id, variante, orden, grupo, concepto, cantidad, tipo_costo, parametro, costo_fijo, producto:productos(id, sku, nombre, costo, activo)')
      .eq('paquete_id', paqueteId).order('variante').order('orden')
    if (error) return { error: textoDeError(error), lineas: [] }
    return { lineas: data || [] }
  } catch (e) {
    return { error: textoDeError(e), lineas: [] }
  }
}

const escribir = async consulta => {
  try {
    const { error } = await consulta
    return error ? { error: textoDeError(error) } : { ok: true }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}
export const guardarCantidad = (lineaId, cantidad) =>
  escribir(supabase.from('paquete_solar_lineas').update({ cantidad: Number(cantidad) }).eq('id', lineaId))
export const quitarLineaPaquete = lineaId => escribir(supabase.from('paquete_solar_lineas').delete().eq('id', lineaId))
export const agregarLineaPaquete = ({ paqueteId, variante, producto, cantidad, orden }) =>
  escribir(supabase.from('paquete_solar_lineas').insert({
    paquete_id: paqueteId, variante, producto_id: producto.id, concepto: producto.nombre,
    cantidad: Number(cantidad), tipo_costo: 'equipo', grupo: 'Agregado a mano', orden
  }))

export async function buscarProductos(texto) {
  const t = String(texto || '').trim()
  if (t.length < 2) return { productos: [] }
  try {
    const patron = `%${t.replace(/[%_,()]/g, ' ')}%`
    const { data, error } = await supabase.from('productos').select('id, sku, nombre, costo')
      .eq('activo', true).neq('categoria', 'paquete_solar')
      .or(`sku.ilike.${patron},nombre.ilike.${patron}`).order('sku').limit(20)
    if (error) return { error: textoDeError(error), productos: [] }
    return { productos: data || [] }
  } catch (e) {
    return { error: textoDeError(e), productos: [] }
  }
}

// Una cantidad válida: número mayor que cero.
export const cantidadValida = v => {
  const n = Number(String(v ?? '').replace(',', '.'))
  return Number.isFinite(n) && n > 0
}
