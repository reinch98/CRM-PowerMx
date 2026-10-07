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
const numONull = v => {
  if (v === '' || v == null) return null
  const n = Number(v)
  return Number.isFinite(n) ? n : null
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

// ---- verificación del cobro con el comprobante leído por la IA ----

// El cobro solo CUENTA para cerrar la cobranza si lo capturado coincide con lo que la IA leyó en el
// comprobante (la base lo vuelve a comprobar). Esto lo dice en pantalla mientras se captura.
export function verificacionDeCobro(form) {
  const leido = numONull(form?.monto_leido)
  if (leido == null) {
    return { estado: 'sin_leer', etiqueta: 'Sin leer', texto: 'Este cobro suma, pero sin leer su comprobante no puede cerrar la cobranza solo.' }
  }
  const monto = num(form?.monto)
  if (Math.abs(monto - leido) <= 0.01) {
    return { estado: 'verificado', etiqueta: 'Verificado', texto: `El monto coincide con el comprobante (${pesos(leido)}).` }
  }
  return { estado: 'no_coincide', etiqueta: 'No cuadra', texto: `El comprobante dice ${pesos(leido)} y escribiste ${pesos(monto)}.` }
}

// El estado de un cobro ya guardado, con palabra.
export function estadoCobro(m) {
  if (!m?.archivo) return 'Sin comprobante'
  const leido = numONull(m.monto_leido)
  if (m.leido_ia && leido != null && Math.abs(leido - num(m.monto)) <= 0.01) return 'Verificado con el comprobante'
  return 'Comprobante sin verificar'
}

export const textoCobranza = estado =>
  ({ pendiente: 'Sin cobros', parcial: 'Cobro parcial', liquidada: 'Cobrada' }[estado] || '—')

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
    leido_ia: esIngreso && numONull(form.monto_leido) != null,
    monto_leido: esIngreso ? numONull(form.monto_leido) : null,
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

// Sube un comprobante (foto o PDF) al bucket y devuelve su ruta. Una foto del celular se encoge
// antes de subir. Se separa de guardar para poder LEERLO antes de registrar sin subirlo dos veces.
export async function subirComprobante(cotizacionId, archivo) {
  try {
    if (!archivoValido(archivo)) return { error: 'El comprobante tiene que ser una foto o un PDF.' }
    const pdf = esPdf(archivo)
    const cuerpo = pdf ? archivo : await redimensionar(archivo, 2000, 0.85)
    const ruta = rutaComprobante(cotizacionId, archivo.name, pdf)
    const { error } = await supabase.storage.from(BUCKET)
      .upload(ruta, cuerpo, { upsert: true, contentType: pdf ? 'application/pdf' : 'image/jpeg' })
    if (error) return { error: `No se pudo subir el comprobante: ${textoDeError(error)}` }
    return { ruta, nombre: archivo.name || (pdf ? 'comprobante.pdf' : 'comprobante.jpg') }
  } catch (err) {
    return { error: textoDeError(err) }
  }
}

// Guarda el movimiento. El comprobante es el archivo elegido (se sube aquí) o uno que ya se subió
// para leerlo (`subido`). Si el archivo no sube no se guarda nada: un cobro "comprobado" sin
// archivo sería mentira.
export async function guardarMovimiento(fila, archivo, subido) {
  try {
    let ruta = subido?.ruta || null
    let nombre = subido?.nombre || null
    if (!ruta && archivo) {
      const r = await subirComprobante(fila.cotizacion_id, archivo)
      if (r.error) return { error: r.error }
      ruta = r.ruta
      nombre = r.nombre
    }
    const { error } = await supabase.from('expediente_movimientos')
      .insert([{ ...fila, archivo: ruta, archivo_nombre: nombre }])
    if (error) return { error: textoDeError(error) }
    return { ok: true }
  } catch (err) {
    return { error: textoDeError(err) }
  }
}

// ---- leer el comprobante con IA (Edge Function `leer-comprobante`): solo propone ----

const texto = v => (typeof v === 'string' ? v.trim() : '')
const aNumero = v => {
  if (typeof v === 'number') return Number.isFinite(v) ? v : null
  if (typeof v !== 'string') return null
  const limpio = v.replace(/[^0-9.,-]/g, '').replace(/,/g, '')
  const n = Number(limpio)
  return limpio === '' || limpio === '-' || limpio === '.' || !Number.isFinite(n) ? null : n
}
const fechaValida = v => (/^\d{4}-\d{2}-\d{2}$/.test(texto(v)) ? texto(v) : '')
const claveEn = (v, lista) => (lista.some(([k]) => k === v) ? v : '')

export function normalizarTicket(l) {
  const x = l && typeof l === 'object' ? l : {}
  return {
    establecimiento: texto(x.establecimiento),
    fecha: fechaValida(x.fecha),
    total: aNumero(x.total),
    iva: aNumero(x.iva),
    litros: aNumero(x.litros),
    combustible: texto(x.combustible),
    folio: texto(x.folio),
    categoria: claveEn(texto(x.categoria), CATEGORIAS_EGRESO),
    concepto: texto(x.concepto),
    notas: texto(x.notas)
  }
}

export function normalizarBanco(l) {
  const x = l && typeof l === 'object' ? l : {}
  return {
    monto: aNumero(x.monto),
    fecha: fechaValida(x.fecha),
    forma: claveEn(texto(x.forma), FORMAS_COBRO),
    referencia: texto(x.referencia),
    banco: texto(x.banco),
    ordenante: texto(x.ordenante),
    beneficiario: texto(x.beneficiario),
    concepto: texto(x.concepto),
    notas: texto(x.notas)
  }
}

const aTexto = n => (n == null ? '' : String(n))

// Lo leído de un ticket llena el formulario de gasto; lo que no se leyó se queda como estaba.
export function formDesdeTicket(l, form) {
  const detalle = [
    l.litros != null ? `${l.litros} L${l.combustible ? ' ' + l.combustible : ''}` : '',
    l.establecimiento
  ].filter(Boolean).join(' · ')
  return {
    ...form,
    categoria: l.categoria || form.categoria,
    fecha: l.fecha || form.fecha,
    monto: l.total != null ? aTexto(l.total) : form.monto,
    iva: l.iva != null ? aTexto(l.iva) : form.iva,
    concepto: l.concepto || detalle || form.concepto,
    referencia: l.folio || form.referencia
  }
}

// Lo leído de un comprobante bancario llena el formulario de cobro.
export function formDesdeBanco(l, form) {
  const notas = [l.banco && `Banco: ${l.banco}`, l.ordenante && `De: ${l.ordenante}`].filter(Boolean).join(' · ')
  return {
    ...form,
    fecha: l.fecha || form.fecha,
    monto: l.monto != null ? aTexto(l.monto) : form.monto,
    forma: l.forma || form.forma,
    referencia: l.referencia || form.referencia,
    // El monto que leyó la IA queda aparte de lo capturado: si no coinciden, el cobro no verifica nada.
    monto_leido: l.monto != null ? aTexto(l.monto) : (form.monto_leido ?? ''),
    notas: notas || form.notas
  }
}

// modo: 'ticket' (gastos) | 'banco' (cobros)
export async function leerComprobante(ruta, modo) {
  try {
    const { data, error } = await supabase.functions.invoke('leer-comprobante', { body: { ruta, modo } })
    if (error) {
      // La función devuelve el motivo en el cuerpo; `invoke` solo trae el código.
      let detalle = ''
      try { detalle = (await error.context?.json())?.error || '' } catch { /* sin cuerpo */ }
      return { error: detalle || 'No se pudo leer el comprobante.' }
    }
    if (data?.error) return { error: data.error }
    if (!data?.ok) return { error: 'No entendí lo que devolvió el modelo.' }
    return { lectura: modo === 'banco' ? normalizarBanco(data.leido) : normalizarTicket(data.leido) }
  } catch (err) {
    return { error: textoDeError(err) }
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

export async function liquidarCobranza(cotizacionId, motivo) {
  try {
    const { data, error } = await supabase.rpc('liquidar_cobranza', { p_cotizacion: cotizacionId, p_motivo: motivo })
    if (error) return { error: textoDeError(error) }
    return { respuesta: data }
  } catch (err) {
    return { error: textoDeError(err) }
  }
}

export async function reabrirCobranza(cotizacionId) {
  try {
    const { data, error } = await supabase.rpc('reabrir_cobranza', { p_cotizacion: cotizacionId })
    if (error) return { error: textoDeError(error) }
    return { respuesta: data }
  } catch (err) {
    return { error: textoDeError(err) }
  }
}

// ¿Esa clave de rastreo ya se usó en otro cobro? Una misma transferencia contada dos veces haría
// pasar por cobrado lo que no se cobró. Solo avisa: un pago puede repartirse legítimamente.
export async function referenciaRepetida(referencia) {
  const ref = String(referencia ?? '').trim()
  if (!ref) return null
  try {
    const { data } = await supabase.from('expediente_movimientos')
      .select('cotizacion_id, monto, cotizaciones(folio)')
      .eq('tipo', 'ingreso').eq('referencia', ref).limit(1)
    const r = data?.[0]
    return r ? { folio: r.cotizaciones?.folio ?? null, monto: r.monto } : null
  } catch {
    return null
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
