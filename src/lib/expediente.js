// ---------------------------------------------------------------------------
// Expediente de ingresos y egresos de una cotización (SQL 61).
//
// El INGRESO es la cotización; sus cobros se comprueban con la operación bancaria (foto o PDF).
// El MATERIAL no se captura aquí: lo dicta la cotización, a costo real. Aquí van los demás
// egresos: gasolina, uso del vehículo, pago de técnicos, viáticos y otros.
//
// Las cifras (utilidad, material, avisos) las calcula la BASE (`expediente_resumen`) con una sola
// fórmula; esta pantalla solo las muestra. Aquí viven las reglas de captura y las llamadas.
// ---------------------------------------------------------------------------

import { supabase } from './supabase'
import { explicarError } from './errores'
import { redimensionar } from './imagen'

const BUCKET = 'finanzas'

export const CATEGORIAS_EGRESO = [
  ['tecnico', 'Pago de técnico'],
  ['gasolina', 'Gasolina'],
  ['vehiculo', 'Uso del vehículo'],
  ['viaticos', 'Viáticos'],
  ['otro', 'Otro gasto']
]
export const FORMAS_COBRO = [
  ['transferencia', 'Transferencia'],
  ['deposito', 'Depósito'],
  ['cheque', 'Cheque'],
  ['efectivo', 'Efectivo']
]

const ETIQUETAS = { cobro: 'Cobro', ...Object.fromEntries(CATEGORIAS_EGRESO) }
export const etiquetaCategoria = c => ETIQUETAS[c] || c || '—'

const num = v => {
  const n = Number(v)
  return Number.isFinite(n) ? n : 0
}
const vacioANull = v => {
  const t = typeof v === 'string' ? v.trim() : v
  return t === '' || t == null ? null : t
}

export const pesos = v =>
  num(v).toLocaleString('es-MX', { style: 'currency', currency: 'MXN' })

// Con palabra, nunca solo con color: "Comprobado" / "Sin comprobante".
export const estadoComprobante = m => (m?.archivo ? 'Comprobado' : 'Sin comprobante')

// Utilidad o pérdida dicha con palabra.
export function textoUtilidad(utilidad) {
  const n = num(utilidad)
  if (n > 0) return 'Utilidad'
  if (n < 0) return 'Pérdida'
  return 'Sin utilidad'
}

// ---- captura ----

// Qué falta o está mal en lo que se va a guardar. null = se puede guardar.
export function validarMovimiento(form, tipo) {
  const monto = num(form?.monto)
  if (!(monto > 0)) return 'Escribe el monto: tiene que ser mayor que cero.'
  if (!form?.fecha) return 'Falta la fecha.'
  if (tipo === 'ingreso') return null
  if (!form?.categoria) return 'Elige qué tipo de gasto es.'
  if (form.categoria === 'tecnico' && !form.tecnico_id) return 'Elige a qué técnico se le pagó.'
  if (form.categoria === 'otro' && !String(form.concepto || '').trim()) return 'Describe en qué fue el gasto.'
  const iva = num(form.iva)
  if (iva < 0) return 'El IVA no puede ser negativo.'
  if (iva > monto) return 'El IVA no puede ser mayor que el monto.'
  return null
}

// La fila tal como se guarda: '' → null (Postgres no acepta '' en columnas numéricas o de fecha) y
// el IVA solo cuenta en un egreso (un cobro no lo usa para la utilidad).
export function filaDeMovimiento(form, tipo, cotizacionId, quien) {
  const esIngreso = tipo === 'ingreso'
  return {
    cotizacion_id: cotizacionId,
    tipo,
    categoria: esIngreso ? 'cobro' : form.categoria,
    fecha: form.fecha,
    concepto: vacioANull(form.concepto),
    monto: num(form.monto),
    iva: esIngreso ? 0 : num(form.iva),
    forma: esIngreso ? vacioANull(form.forma) : null,
    referencia: vacioANull(form.referencia),
    tecnico_id: !esIngreso && form.categoria === 'tecnico' ? vacioANull(form.tecnico_id) : null,
    notas: vacioANull(form.notas),
    creado_por: quien || 'crm'
  }
}

// El bucket acepta JPG, PNG, WebP y PDF. Una foto del celular se vuelve JPG antes de subir.
export const esPdf = f => f?.type === 'application/pdf' || /\.pdf$/i.test(f?.name || '')
export const esImagen = f => /^image\//.test(f?.type || '')
export const archivoValido = f => esPdf(f) || esImagen(f)

const limpiarNombre = n =>
  String(n || 'comprobante').replace(/\.[^.]+$/, '').normalize('NFD').replace(/[̀-ͯ]/g, '')
    .replace(/[^a-zA-Z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40) || 'comprobante'

// finanzas/<cotización>/<marca de tiempo>-<nombre>.<ext>: la marca evita pisar uno con otro.
export function rutaComprobante(cotizacionId, nombreOriginal, esDocumentoPdf, marca = Date.now()) {
  return `${cotizacionId}/${marca}-${limpiarNombre(nombreOriginal)}.${esDocumentoPdf ? 'pdf' : 'jpg'}`
}

// ---- llamadas ----

const textoDeError = e => {
  const codigo = String(e?.code || '')
  if (['22023', '42501'].includes(codigo) && e?.message) return e.message
  return explicarError(e).texto
}

export async function cargarResumen(cotizacionId) {
  try {
    const { data, error } = await supabase.rpc('expediente_resumen', { p_cotizacion: cotizacionId })
    if (error) return { error: textoDeError(error) }
    return { resumen: data }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}

export async function cargarMovimientos(cotizacionId) {
  try {
    const { data, error } = await supabase.from('expediente_movimientos')
      .select('*, perfiles:tecnico_id(nombre)')
      .eq('cotizacion_id', cotizacionId)
      .order('fecha', { ascending: true }).order('created_at', { ascending: true })
    if (error) return { error: textoDeError(error) }
    return { movimientos: data || [] }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}

// Sube el comprobante (si hay) y luego guarda el movimiento con su ruta. Si el archivo no sube,
// no se guarda nada: un cobro "comprobado" sin archivo sería mentira.
export async function guardarMovimiento(fila, archivo) {
  try {
    let ruta = null
    let nombre = null
    if (archivo) {
      if (!archivoValido(archivo)) return { error: 'El comprobante tiene que ser una foto o un PDF.' }
      const pdf = esPdf(archivo)
      const cuerpo = pdf ? archivo : await redimensionar(archivo, 2000, 0.85)
      ruta = rutaComprobante(fila.cotizacion_id, archivo.name, pdf)
      nombre = archivo.name || (pdf ? 'comprobante.pdf' : 'comprobante.jpg')
      const { error: eSub } = await supabase.storage.from(BUCKET)
        .upload(ruta, cuerpo, { upsert: true, contentType: pdf ? 'application/pdf' : 'image/jpeg' })
      if (eSub) return { error: `No se pudo subir el comprobante: ${textoDeError(eSub)}` }
    }
    const { error } = await supabase.from('expediente_movimientos')
      .insert([{ ...fila, archivo: ruta, archivo_nombre: nombre }])
    if (error) return { error: textoDeError(error) }
    return { ok: true }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}

export async function borrarMovimiento(id) {
  try {
    const { error } = await supabase.from('expediente_movimientos').delete().eq('id', id)
    if (error) return { error: textoDeError(error) }
    return { ok: true }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}

export async function cerrarExpediente(cotizacionId, forzar = false) {
  try {
    const { data, error } = await supabase.rpc('cerrar_expediente', { p_cotizacion: cotizacionId, p_forzar: forzar })
    if (error) return { error: textoDeError(error) }
    return { respuesta: data }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}

export async function reabrirExpediente(cotizacionId, motivo) {
  try {
    const { data, error } = await supabase.rpc('reabrir_expediente', { p_cotizacion: cotizacionId, p_motivo: motivo })
    if (error) return { error: textoDeError(error) }
    return { respuesta: data }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}

export async function urlComprobante(ruta) {
  try {
    const { data, error } = await supabase.storage.from(BUCKET).createSignedUrl(ruta, 300)
    if (error) return null
    return data?.signedUrl || null
  } catch {
    return null
  }
}
