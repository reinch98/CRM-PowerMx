// ---------------------------------------------------------------------------
// Finanzas (SQL 67): bandeja de documentos, CFDI, libro de movimientos y cuentas.
//
// Principio: el sistema LEE y PROPONE; el administrador aprueba. Nada fiscal ni de dinero se
// vuelve definitivo sin `aprobar_documento`. Las reglas de aquí son puras (se prueban en Node);
// las llamadas a la base van al final.
// ---------------------------------------------------------------------------

import { supabase } from './supabase'
import { explicarError } from './errores'
import { leerCfdiXml, MAX_BYTES_XML } from './cfdi'
import { leerComprobante } from './expediente'
import { sha256Hex, revisarArchivo } from './huellas'

const BUCKET = 'finanzas'

// ---- categorías ----

// Gastos del negocio. `retiro_dueno` NO es un gasto: es dinero que sale hacia ti y no entra en
// la utilidad ni en los reportes del negocio; por eso va en su propio grupo.
export const CATEGORIAS_GASTO = [
  ['gasolina', 'Gasolina'],
  ['vehiculo', 'Vehículo (mantenimiento)'],
  ['material', 'Material y refacciones'],
  ['herramienta', 'Herramienta'],
  ['viaticos', 'Viáticos'],
  ['tecnico', 'Pago de técnico'],
  ['renta', 'Renta'],
  ['servicios', 'Servicios (luz, internet, teléfono)'],
  ['software', 'Software y suscripciones'],
  ['publicidad', 'Publicidad'],
  ['comisiones_bancarias', 'Comisiones bancarias'],
  ['impuestos', 'Impuestos'],
  ['pago_proveedor', 'Pago a proveedor (compras)'],
  ['otro', 'Otro gasto']
]
export const CATEGORIAS_CAPITAL = [
  ['retiro_dueno', 'Retiro del dueño'],
  ['aportacion', 'Aportación del dueño']
]
const INGRESOS = ['cobro', 'aportacion', 'otro_ingreso']
const ETIQUETAS = {
  cobro: 'Cobro de cotización', otro_ingreso: 'Otro ingreso',
  ...Object.fromEntries(CATEGORIAS_GASTO), ...Object.fromEntries(CATEGORIAS_CAPITAL)
}
export const etiquetaCategoria = c => ETIQUETAS[c] || c || '—'
export const esIngreso = categoria => INGRESOS.includes(categoria)
export const esCapital = categoria => categoria === 'retiro_dueno' || categoria === 'aportacion'

export const FORMAS_PAGO = [
  ['transferencia', 'Transferencia'], ['efectivo', 'Efectivo'], ['tarjeta', 'Tarjeta'], ['otro', 'Otra']
]

const num = v => {
  const n = Number(v)
  return Number.isFinite(n) ? n : 0
}
export const pesos = v => num(v).toLocaleString('es-MX', { style: 'currency', currency: 'MXN' })
// Para los indicadores grandes: sin centavos (el detalle los conserva).
export const pesosRedondos = v =>
  num(v).toLocaleString('es-MX', { style: 'currency', currency: 'MXN', minimumFractionDigits: 0, maximumFractionDigits: 0 })
const redondear = n => Math.round(n * 100) / 100

// La fecha de un CFDI es una hora (con zona); el movimiento se fecha por DÍA de Mérida.
export function fechaMerida(iso) {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  return d.toLocaleDateString('en-CA', { timeZone: 'America/Merida' })
}

const sinAcentos = s => String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()

// ---- clasificación: primero lo aprendido de este proveedor, luego palabras ----

const PALABRAS = [
  [/gasolin|magna|premium|diesel|combustible|pemex|oxxo gas|total gas|g500/, 'gasolina'],
  [/renta de |arrendamiento|alquiler/, 'renta'],
  [/telcel|telmex|izzi|totalplay|megacable|internet|telefon|comision federal|\bcfe\b|agua potable/, 'servicios'],
  [/software|licencia|suscripci|hosting|dominio|google|microsoft|anthropic|openai|supabase|cloudflare|github|meta platforms/, 'software'],
  [/comision|anualidad|membresia|banorte/, 'comisiones_bancarias'],
  [/publicidad|anuncio|imprenta|lona|rotulo|facebook ads/, 'publicidad'],
  [/herramienta|taladro|multimetro|pinza|llave/, 'herramienta'],
  [/viatico|hotel|hospedaje|restaurante|alimentos|comida/, 'viaticos'],
  [/llantas|afinacion|taller mecanico|mantenimiento vehic/, 'vehiculo'],
  [/refaccion|filtro|aceite|bujia|bateria|cable|inversor|panel|material|tornillo|soporte|breaker/, 'material']
]

// Devuelve { categoria, confianza, motivo }. La confianza sale de CÓMO se decidió, no de lo que
// diga un modelo sobre sí mismo: una regla aprendida varias veces es "alta", una coincidencia de
// palabras o una regla vista una sola vez es "media", y sin pista es "baja".
export function proponerGasto({ cfdi, regla, compra }) {
  if (compra) return { categoria: 'pago_proveedor', confianza: 'alta', motivo: 'Ya está registrada en Compras.' }
  if (regla?.categoria) {
    const veces = regla.veces || 1
    return {
      categoria: regla.categoria,
      confianza: veces >= 2 ? 'alta' : 'media',
      motivo: `Así clasificaste a este proveedor ${veces} ${veces === 1 ? 'vez' : 'veces'}.`
    }
  }
  const claves = (cfdi?.conceptos || []).map(c => String(c.clave || ''))
  if (claves.some(c => c.startsWith('1510'))) {
    return { categoria: 'gasolina', confianza: 'media', motivo: 'La clave del SAT es de combustible.' }
  }
  const texto = sinAcentos([cfdi?.nombre_emisor, ...(cfdi?.conceptos || []).map(c => c.descripcion)].join(' '))
  for (const [patron, categoria] of PALABRAS) {
    if (patron.test(texto)) return { categoria, confianza: 'media', motivo: 'Por las palabras del concepto.' }
  }
  return { categoria: 'otro', confianza: 'baja', motivo: 'No hay pista de qué es: elige tú.' }
}

export const ETIQUETA_CONFIANZA = { alta: 'Seguro', media: 'Revisa', baja: 'Elige tú' }

// Qué hacer por omisión con un CFDI. Lo que tú emites o que no es una factura de gasto
// (nota de crédito, complemento de pago) solo se archiva como respaldo.
export function accionSugerida(cfdi) {
  if (!cfdi) return 'gasto'
  if (cfdi.sentido === 'emitido') return 'archivar'
  if (cfdi.tipo_comprobante && cfdi.tipo_comprobante !== 'I') return 'archivar'
  return 'gasto'
}

// Avisos en palabras para el que revisa. Los estructurales (no cuadra) vienen del lector.
export function avisosDeCfdi(c) {
  if (!c) return []
  const a = []
  if (c.tipo_comprobante === 'E') a.push('Es una nota de crédito: no se registra como gasto.')
  if (c.tipo_comprobante === 'P') a.push('Es un complemento de pago: sirve de respaldo, no es un gasto.')
  if (c.sentido === 'recibido' && c.metodo_pago === 'PPD') {
    a.push('Se paga después (PPD): el IVA solo se acredita cuando la pagues. Si aún no la pagas, déjala "por pagar".')
  }
  if (c.moneda && c.moneda !== 'MXN') a.push(`Está en ${c.moneda}: captura el monto en pesos que de verdad pagaste.`)
  if (c.sentido === 'emitido' && (num(c.isr_retenido) > 0 || num(c.iva_retenido) > 0)) {
    const partes = [num(c.isr_retenido) > 0 && `ISR ${pesos(c.isr_retenido)}`, num(c.iva_retenido) > 0 && `IVA ${pesos(c.iva_retenido)}`]
    a.push(`Te retuvieron ${partes.filter(Boolean).join(' y ')}: te pagarán menos que el total.`)
  }
  return a
}

const FORMA_DESDE_SAT = { '01': 'efectivo', '03': 'transferencia', '04': 'tarjeta', '28': 'tarjeta' }

// 'AAAA-MM-DD' + n días, sin pasar por UTC (a medianoche en UTC el día se correría en Mérida).
export function sumarDias(iso, n) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso || ''))
  if (!m) return ''
  const d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]) + n)
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

// Cuánto falta para que venza una factura, en palabras y con su clase (nunca solo color).
export function estadoVencimiento(dias) {
  if (dias == null || Number.isNaN(Number(dias))) return { etiqueta: 'Sin vencimiento', clase: 'estado-borrador', nivel: 'sin' }
  const d = Number(dias)
  if (d < 0) return { etiqueta: `Vencida hace ${-d} ${d === -1 ? 'día' : 'días'}`, clase: 'estado-error', nivel: 'vencida' }
  if (d === 0) return { etiqueta: 'Vence hoy', clase: 'estado-revisa', nivel: 'pronto' }
  if (d <= 7) return { etiqueta: `Vence en ${d} ${d === 1 ? 'día' : 'días'}`, clase: 'estado-revisa', nivel: 'pronto' }
  return { etiqueta: `Vence en ${d} días`, clase: 'estado-enviada', nivel: 'tiempo' }
}

export function validarPagoCfdi(form, saldo) {
  const monto = num(form.monto)
  if (!(monto > 0)) return 'Escribe cuánto pagaste.'
  if (monto > num(saldo) + 0.01) return `El pago no puede ser mayor que lo que falta (${pesos(saldo)}).`
  if (!form.fecha) return 'Escribe la fecha del pago.'
  return ''
}

// Valores iniciales del formulario de aprobación, a partir del CFDI y de lo propuesto.
export function formularioDeAprobacion(doc, cfdi, propuesta) {
  const ia = doc?.metodo === 'ia' ? doc?.propuesta || {} : {}
  return {
    accion: accionSugerida(cfdi),
    categoria: propuesta?.categoria || ia.categoria || 'otro',
    monto: cfdi ? String(cfdi.total ?? '') : ia.monto != null ? String(ia.monto) : '',
    iva: cfdi ? String(cfdi.iva_trasladado ?? '') : ia.iva != null ? String(ia.iva) : '',
    fecha: cfdi ? fechaMerida(cfdi.fecha) : ia.fecha || '',
    pagado: cfdi ? cfdi.metodo_pago !== 'PPD' : true,
    // Si queda por pagar: 30 días después de la factura, como propone la base. Se puede cambiar.
    vence: cfdi ? sumarDias(fechaMerida(cfdi.fecha), 30) : '',
    cuenta_id: '',
    forma: FORMA_DESDE_SAT[cfdi?.forma_pago] || 'transferencia',
    concepto: cfdi?.nombre_emisor || ia.concepto || '',
    referencia: ia.referencia || '',
    cotizacion_id: '',
    notas: ''
  }
}

export function validarAprobacion(form) {
  if (form.accion === 'archivar') return ''
  if (!form.categoria) return 'Elige el tipo de gasto.'
  if (form.pagado) {
    if (!(num(form.monto) > 0)) return 'Escribe el monto que pagaste.'
    if (!form.fecha) return 'Escribe la fecha en que pagaste.'
    if (num(form.iva) < 0 || num(form.iva) > num(form.monto)) return 'El IVA no puede ser mayor que el monto.'
  }
  return ''
}

// Lo que viaja a `aprobar_documento`: números como números y vacíos como null (Postgres no
// acepta '' en columnas numéricas o de fecha).
export function paraEnviarAprobacion(form) {
  const vacio = t => t == null || (typeof t === 'string' && t.trim() === '')
  const v = t => (vacio(t) ? null : t)
  return {
    accion: form.accion,
    categoria: form.categoria,
    monto: vacio(form.monto) ? null : num(form.monto),
    iva: vacio(form.iva) ? null : num(form.iva),
    fecha: v(form.fecha),
    pagado: !!form.pagado,
    vence: form.pagado ? null : v(form.vence),
    cuenta_id: v(form.cuenta_id),
    forma: v(form.forma),
    concepto: v(form.concepto),
    referencia: v(form.referencia),
    cotizacion_id: v(form.cotizacion_id),
    notas: v(form.notas)
  }
}

// ---- libro ----

export const rangoDeMes = aaaamm => {
  const [a, m] = aaaamm.split('-').map(Number)
  const ultimo = new Date(a, m, 0).getDate()
  return { desde: `${aaaamm}-01`, hasta: `${aaaamm}-${String(ultimo).padStart(2, '0')}` }
}

export function mesAnterior(aaaamm, pasos = 1) {
  const [a, m] = aaaamm.split('-').map(Number)
  const d = new Date(a, m - 1 - pasos, 1)
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`
}

const MESES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre']
export function nombreDeMes(aaaamm) {
  const [a, m] = String(aaaamm).split('-').map(Number)
  return MESES[m - 1] ? `${MESES[m - 1]} ${a}` : String(aaaamm)
}

// 'AAAA-MM-DD' → '8 oct 2026'. Se lee como texto: new Date('2026-10-08') es UTC y en Mérida
// mostraría el día anterior.
export function fechaLegible(iso) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso || ''))
  if (!m || !MESES[Number(m[2]) - 1]) return ''
  return `${Number(m[3])} ${MESES[Number(m[2]) - 1].slice(0, 3)} ${m[1]}`
}

// Las cifras del mes. Ingresos y gastos del negocio van aparte de lo que pones o sacas tú: un
// retiro no es un gasto del negocio ni una aportación es una venta.
export function resumenLibro(filas) {
  let ingresos = 0, gastos = 0, retiros = 0, aportaciones = 0, ivaAcreditable = 0
  const porCategoria = {}
  for (const f of filas || []) {
    const monto = num(f.monto)
    if (f.categoria === 'aportacion') aportaciones += monto
    else if (f.categoria === 'retiro_dueno') retiros += monto
    else if (esIngreso(f.categoria)) ingresos += monto
    else {
      gastos += monto
      ivaAcreditable += f.cfdi_id ? num(f.iva) : 0
      porCategoria[f.categoria] = (porCategoria[f.categoria] || 0) + monto
    }
  }
  return {
    ingresos: redondear(ingresos),
    gastos: redondear(gastos),
    resultado: redondear(ingresos - gastos),
    retiros: redondear(retiros),
    aportaciones: redondear(aportaciones),
    movimiento_neto_caja: redondear(ingresos + aportaciones - gastos - retiros),
    iva_acreditable: redondear(ivaAcreditable),
    por_categoria: Object.entries(porCategoria)
      .map(([categoria, monto]) => ({ categoria, monto: redondear(monto) }))
      .sort((x, y) => y.monto - x.monto)
  }
}

export function validarMovimientoLibre(f) {
  if (!f.categoria) return 'Elige de qué es el movimiento.'
  if (f.categoria === 'cobro') return 'Los cobros de una cotización se registran en su Expediente.'
  if (!(num(f.monto) > 0)) return 'Escribe el monto.'
  if (!f.fecha) return 'Escribe la fecha.'
  if (num(f.iva) < 0 || num(f.iva) > num(f.monto)) return 'El IVA no puede ser mayor que el monto.'
  return ''
}

// ---- llamadas ----

const textoDeError = e => {
  const codigo = String(e?.code || '')
  if (['22023', '42501', '23505'].includes(codigo) && e?.message) return e.message
  return explicarError(e).texto
}
const intentar = async fn => {
  try {
    return await fn()
  } catch (e) {
    return { error: textoDeError(e) }
  }
}

// La huella vive en huellas.js (la usan también Expediente, Compras y Banco); se reexporta aquí
// porque conciliacion.js y las pruebas ya la importaban de este módulo.
export { sha256Hex }

const EXT_POR_MIME = { 'application/pdf': 'pdf', 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' }
const esXml = a => /\.xml$/i.test(a?.name || '') || /xml/.test(a?.type || '')

// Sube UN archivo a la bandeja. Resultado: { estado: 'nuevo' | 'duplicado' | 'error', ... }.
//   · XML: se lee sin IA, se registra el CFDI y queda con una propuesta.
//   · PDF o foto: queda pendiente; se puede leer con IA o capturar a mano.
export async function subirDocumento(archivo, Parser = globalThis.DOMParser) {
  return intentar(async () => {
    const nombre = archivo?.name || 'archivo'
    const tamano = archivo?.size || 0
    if (tamano > 10 * 1024 * 1024) return { estado: 'error', nombre, error: 'Pesa más de 10 MB.' }
    const buf = await archivo.arrayBuffer()
    const hash = await sha256Hex(buf)
    // Ya registrado en otra parte (un cobro, un gasto del Expediente, un estado de cuenta): no se
    // sube. Un duplicado dentro de la propia bandeja lo resuelve registrar_documento más abajo.
    const rep = await revisarArchivo(hash, 'dinero', 'documentos')
    if (rep.repetido) return { estado: 'error', nombre, error: rep.texto }

    if (esXml(archivo)) {
      if (tamano > MAX_BYTES_XML) return { estado: 'error', nombre, error: 'El XML pesa demasiado para ser un CFDI.' }
      const lectura = leerCfdiXml(new TextDecoder('utf-8').decode(buf), Parser)
      if (lectura.error) return { estado: 'error', nombre, error: lectura.error }
      const ruta = `documentos/${hash}.xml`
      const sube = await supabase.storage.from(BUCKET).upload(ruta, new Blob([buf], { type: 'text/xml' }), { upsert: true, contentType: 'text/xml' })
      if (sube.error) return { estado: 'error', nombre, error: `No se pudo subir: ${textoDeError(sube.error)}` }

      const reg = await supabase.rpc('registrar_documento', {
        p_tipo: 'cfdi_xml', p_archivo: ruta, p_nombre: nombre, p_mime: 'text/xml', p_hash: hash,
        p_metodo: 'xml', p_extraido: lectura.datos, p_validaciones: lectura.avisos
      })
      if (reg.error) return { estado: 'error', nombre, error: textoDeError(reg.error) }
      if (reg.data?.duplicado) return { estado: 'duplicado', nombre, documento_id: reg.data.documento_id, estadoDoc: reg.data.estado }

      const cf = await supabase.rpc('registrar_cfdi', { p_datos: lectura.datos, p_archivo: ruta, p_documento: reg.data.documento_id })
      if (cf.error) {
        // Un CFDI que no es tuyo no debe quedarse en la bandeja esperando.
        await supabase.rpc('rechazar_documento', { p_documento: reg.data.documento_id, p_motivo: textoDeError(cf.error) })
        return { estado: 'error', nombre, error: textoDeError(cf.error) }
      }
      if (cf.data?.duplicado) return { estado: 'duplicado', nombre, documento_id: reg.data.documento_id, estadoDoc: 'propuesto', cfdi_id: cf.data.cfdi_id }

      // Propuesta de clasificación (solo para una factura recibida).
      const cfdi = (await supabase.from('cfdi').select('*').eq('id', cf.data.cfdi_id).single()).data
      if (cfdi && accionSugerida(cfdi) === 'gasto') {
        const regla = (await supabase.from('reglas_clasificacion').select('*').eq('rfc_emisor', cfdi.rfc_emisor).maybeSingle()).data
        const propuesta = proponerGasto({ cfdi, regla, compra: cfdi.compra_id })
        await supabase.from('documentos').update({ propuesta }).eq('id', reg.data.documento_id)
      }
      return { estado: 'nuevo', nombre, documento_id: reg.data.documento_id, cfdi_id: cf.data.cfdi_id, sentido: cf.data.sentido }
    }

    const mime = archivo.type
    if (!EXT_POR_MIME[mime]) return { estado: 'error', nombre, error: 'Solo XML de CFDI, PDF o foto (JPG, PNG, WebP).' }
    const ruta = `documentos/${hash}.${EXT_POR_MIME[mime]}`
    const sube = await supabase.storage.from(BUCKET).upload(ruta, new Blob([buf], { type: mime }), { upsert: true, contentType: mime })
    if (sube.error) return { estado: 'error', nombre, error: `No se pudo subir: ${textoDeError(sube.error)}` }
    const reg = await supabase.rpc('registrar_documento', {
      p_tipo: mime === 'application/pdf' ? 'factura_pdf' : 'ticket', p_archivo: ruta, p_nombre: nombre,
      p_mime: mime, p_hash: hash, p_metodo: 'manual', p_extraido: null, p_validaciones: []
    })
    if (reg.error) return { estado: 'error', nombre, error: textoDeError(reg.error) }
    if (reg.data?.duplicado) return { estado: 'duplicado', nombre, documento_id: reg.data.documento_id, estadoDoc: reg.data.estado }
    return { estado: 'nuevo', nombre, documento_id: reg.data.documento_id, sentido: null }
  })
}

// ---- lectura con IA de un gasto (leer-comprobante, modo "gasto") ----
// Antes se leía en modo "ticket" (el del Expediente, solo gastos de un trabajo) y un pedido de material
// a un proveedor volvía vacío con una nota que nadie veía.

const textoLeido = v => (typeof v === 'string' ? v.trim() : v == null ? '' : String(v).trim())
const numeroLeido = v => {
  if (v === '' || v == null) return null
  const n = Number(String(v).replace(/[$,\s]/g, ''))
  return Number.isFinite(n) ? Math.round(n * 100) / 100 : null
}
const fechaLeida = v => (/^\d{4}-\d{2}-\d{2}$/.test(textoLeido(v)) ? textoLeido(v) : '')
const CLAVES_GASTO = CATEGORIAS_GASTO.map(([k]) => k)
const DOCUMENTOS_GASTO = { factura: 'Factura', ticket: 'Ticket', nota_venta: 'Nota de venta', pedido: 'Pedido',
  cotizacion: 'Cotización', recibo: 'Recibo', otro: 'Documento' }

// Lo que devolvió el modelo, sin confiar en su forma: categorías solo de las de Finanzas.
export function normalizarGasto(leido) {
  const x = leido && typeof leido === 'object' ? leido : {}
  const categoria = textoLeido(x.categoria).toLowerCase()
  const documento = textoLeido(x.documento).toLowerCase()
  return {
    documento: documento in DOCUMENTOS_GASTO ? documento : '',
    proveedor: textoLeido(x.proveedor || x.establecimiento),
    rfc: textoLeido(x.rfc).toUpperCase(),
    folio: textoLeido(x.folio),
    fecha: fechaLeida(x.fecha),
    moneda: textoLeido(x.moneda).toUpperCase() === 'USD' ? 'USD' : 'MXN',
    subtotal: numeroLeido(x.subtotal),
    iva: numeroLeido(x.iva),
    total: numeroLeido(x.total),
    litros: numeroLeido(x.litros),
    combustible: textoLeido(x.combustible),
    categoria: CLAVES_GASTO.includes(categoria) ? categoria : '',
    concepto: textoLeido(x.concepto),
    notas: textoLeido(x.notas)
  }
}

// La propuesta para el formulario y los avisos que la persona debe ver antes de aprobar.
export function propuestaDeGasto(l) {
  const concepto = [l.proveedor, l.concepto].filter(Boolean).join(' — ')
  const propuesta = {
    categoria: l.categoria || 'otro', monto: l.total, iva: l.iva, fecha: l.fecha,
    concepto: concepto || (l.litros != null ? `${l.litros} L ${l.combustible}`.trim() : ''),
    referencia: l.folio
  }
  const avisos = []
  if (l.documento === 'pedido' || l.documento === 'cotizacion') {
    avisos.push({ nivel: 'aviso', texto: `Es ${l.documento === 'pedido' ? 'un pedido' : 'una cotización'}, no un comprobante de pago. ` +
      'Si ya lo pagaste, regístralo como gasto; si no, guárdalo como respaldo y registra la factura cuando llegue.' })
  }
  if (l.moneda === 'USD') avisos.push({ nivel: 'aviso', texto: 'Está en dólares: captura el monto en pesos que salió de la cuenta.' })
  if (l.total == null) {
    avisos.push({ nivel: 'aviso', texto: `La IA no encontró el total${l.notas ? `: ${l.notas}` : '.'} Captúralo a mano.` })
  } else if (l.notas) {
    avisos.push({ nivel: 'info', texto: `Nota de la lectura: ${l.notas}` })
  }
  return { propuesta, avisos }
}

// Lee una foto o PDF con la IA y guarda lo que leyó junto a la propuesta y sus avisos. Solo propone: la
// persona confirma o corrige antes de aprobar.
export async function leerDocumentoConIA(doc) {
  return intentar(async () => {
    const r = await leerComprobante(doc.archivo, 'gasto')
    if (r.error) return { error: r.error }
    const l = normalizarGasto(r.crudo)
    const { propuesta, avisos } = propuestaDeGasto(l)
    const upd = await supabase.from('documentos')
      .update({ metodo: 'ia', extraido: l, propuesta, validaciones: avisos, modelo: 'leer-comprobante', estado: 'propuesto' })
      .eq('id', doc.id)
    if (upd.error) return { error: textoDeError(upd.error) }
    return { lectura: l, propuesta, avisos }
  })
}

export async function listarBandeja() {
  return intentar(async () => {
    const d = await supabase.from('documentos').select('*').in('estado', ['pendiente', 'propuesto'])
      .order('created_at', { ascending: false }).limit(200)
    if (d.error) return { error: textoDeError(d.error) }
    const ids = (d.data || []).map(x => x.cfdi_id).filter(Boolean)
    let cfdis = {}
    if (ids.length) {
      const c = await supabase.from('cfdi').select('*').in('id', ids)
      if (c.error) return { error: textoDeError(c.error) }
      cfdis = Object.fromEntries((c.data || []).map(x => [x.id, x]))
    }
    return { documentos: (d.data || []).map(x => ({ ...x, cfdi: cfdis[x.cfdi_id] || null })) }
  })
}

export async function aprobarDocumento(id, form) {
  return intentar(async () => {
    const r = await supabase.rpc('aprobar_documento', { p_documento: id, p_datos: paraEnviarAprobacion(form) })
    if (r.error) return { error: textoDeError(r.error) }
    return { ok: true, ...r.data }
  })
}

export async function rechazarDocumento(id, motivo) {
  return intentar(async () => {
    const r = await supabase.rpc('rechazar_documento', { p_documento: id, p_motivo: motivo })
    if (r.error) return { error: textoDeError(r.error) }
    return { ok: true }
  })
}

export async function sugerirCotizaciones(cfdiId) {
  return intentar(async () => {
    const r = await supabase.rpc('sugerir_cotizaciones_para_cfdi', { p_cfdi: cfdiId })
    if (r.error) return { error: textoDeError(r.error) }
    return { cotizaciones: r.data || [] }
  })
}

export async function ligarCfdiCotizacion(cfdiId, cotizacionId) {
  return intentar(async () => {
    const r = await supabase.rpc('ligar_cfdi_cotizacion', { p_cfdi: cfdiId, p_cotizacion: cotizacionId })
    if (r.error) return { error: textoDeError(r.error) }
    return { ok: true }
  })
}

// ---- cuentas por pagar (SQL 72) ----

export async function cargarPorPagar() {
  return intentar(async () => {
    const r = await supabase.rpc('cuentas_por_pagar')
    if (r.error) return { error: textoDeError(r.error) }
    const d = r.data || {}
    return { total: num(d.total), vencido: num(d.vencido), cuentas: Array.isArray(d.cuentas) ? d.cuentas : [] }
  })
}

export async function pagarCfdi(cfdiId, form) {
  return intentar(async () => {
    const r = await supabase.rpc('pagar_cfdi', {
      p_cfdi: cfdiId, p_monto: num(form.monto), p_fecha: form.fecha || null,
      p_cuenta: form.cuenta_id || null, p_forma: form.forma || null, p_referencia: (form.referencia || '').trim() || null
    })
    if (r.error) return { error: textoDeError(r.error) }
    return { ok: true, saldo: num(r.data?.saldo) }
  })
}

// Pagos a proveedores ya registrados desde "Por pagar" (SQL 77), para poder deshacer uno.
export async function cargarPagosRegistrados(dias = 90) {
  return intentar(async () => {
    const r = await supabase.rpc('pagos_cfdi_registrados', { p_dias: dias })
    if (r.error) return { error: textoDeError(r.error) }
    return { pagos: Array.isArray(r.data) ? r.data : [] }
  })
}

export async function deshacerPagoCfdi(movimientoId, motivo) {
  return intentar(async () => {
    const r = await supabase.rpc('deshacer_pago_cfdi', { p_movimiento: movimientoId, p_motivo: motivo })
    if (r.error) return { error: textoDeError(r.error) }
    return { ok: true, saldo: num(r.data?.saldo), banco: Number(r.data?.banco_liberados) || 0 }
  })
}

export function textoDeshecho(r, proveedor) {
  const partes = [`Pago deshecho. A ${proveedor || 'ese proveedor'} le vuelves a deber ${pesos(r?.saldo)}; regístralo de nuevo con el monto correcto.`]
  if (r?.banco > 0) partes.push(`${r.banco === 1 ? '1 renglón del banco volvió' : `${r.banco} renglones del banco volvieron`} a "por conciliar".`)
  return partes.join(' ')
}

export async function programarPagoCfdi(cfdiId, vence, categoria) {
  return intentar(async () => {
    const r = await supabase.rpc('programar_pago_cfdi', { p_cfdi: cfdiId, p_vence: vence, p_categoria: categoria || null })
    if (r.error) return { error: textoDeError(r.error) }
    return { ok: true }
  })
}

export async function urlDocumento(ruta) {
  try {
    const { data, error } = await supabase.storage.from(BUCKET).createSignedUrl(ruta, 300)
    return error ? null : data?.signedUrl || null
  } catch {
    return null
  }
}

export async function cargarLibro(desde, hasta) {
  return intentar(async () => {
    const r = await supabase.from('expediente_movimientos')
      .select('*, cotizacion:cotizaciones(folio), cuenta:cuentas_financieras(nombre)')
      .gte('fecha', desde).lte('fecha', hasta)
      .order('fecha', { ascending: false }).order('created_at', { ascending: false }).limit(1000)
    if (r.error) return { error: textoDeError(r.error) }
    return { filas: r.data || [], recortado: (r.data || []).length >= 1000 }
  })
}

export async function guardarMovimientoLibre(f) {
  return intentar(async () => {
    const fila = {
      tipo: esIngreso(f.categoria) ? 'ingreso' : 'egreso',
      categoria: f.categoria,
      fecha: f.fecha,
      concepto: (f.concepto || '').trim() || null,
      monto: num(f.monto),
      iva: f.iva === '' || f.iva == null ? 0 : num(f.iva),
      forma: f.forma || null,
      referencia: (f.referencia || '').trim() || null,
      cuenta_id: f.cuenta_id || null,
      notas: (f.notas || '').trim() || null
    }
    const r = await supabase.from('expediente_movimientos').insert(fila)
    if (r.error) return { error: textoDeError(r.error) }
    return { ok: true }
  })
}

export async function listarCuentas() {
  return intentar(async () => {
    const r = await supabase.from('cuentas_financieras').select('*').order('nombre')
    if (r.error) return { error: textoDeError(r.error) }
    return { cuentas: r.data || [] }
  })
}

export async function guardarCuenta(c) {
  return intentar(async () => {
    const fila = {
      nombre: (c.nombre || '').trim(), tipo: c.tipo || 'banco', banco: (c.banco || '').trim() || null,
      ultimos4: (c.ultimos4 || '').trim() || null, activa: c.activa !== false
    }
    if (!fila.nombre) return { error: 'Ponle un nombre a la cuenta.' }
    if (fila.ultimos4 && !/^[0-9]{4}$/.test(fila.ultimos4)) return { error: 'Los últimos dígitos son 4 números.' }
    const r = c.id
      ? await supabase.from('cuentas_financieras').update(fila).eq('id', c.id)
      : await supabase.from('cuentas_financieras').insert(fila)
    if (r.error) return { error: textoDeError(r.error) }
    return { ok: true }
  })
}

export async function cargarEmpresaFiscal() {
  return intentar(async () => {
    const r = await supabase.from('empresa_fiscal').select('*').eq('id', true).maybeSingle()
    if (r.error) return { error: textoDeError(r.error) }
    return { empresa: r.data || {} }
  })
}

export const RFC_VALIDO = /^[A-ZÑ&]{3,4}[0-9]{6}[A-Z0-9]{3}$/

export function validarEmpresaFiscal(e) {
  const rfc = (e.rfc || '').trim().toUpperCase()
  if (!RFC_VALIDO.test(rfc)) return 'El RFC no tiene el formato correcto (13 caracteres para persona física).'
  const cp = (e.cp_expedicion || '').trim()
  if (cp && !/^[0-9]{5}$/.test(cp)) return 'El código postal tiene 5 números.'
  return ''
}

export async function guardarEmpresaFiscal(e) {
  return intentar(async () => {
    const problema = validarEmpresaFiscal(e)
    if (problema) return { error: problema }
    const r = await supabase.from('empresa_fiscal').upsert({
      id: true,
      rfc: e.rfc.trim().toUpperCase(),
      razon_social: (e.razon_social || '').trim() || null,
      regimen_fiscal: (e.regimen_fiscal || '').trim() || '626',
      cp_expedicion: (e.cp_expedicion || '').trim() || null,
      updated_at: new Date().toISOString()
    })
    if (r.error) return { error: textoDeError(r.error) }
    return { ok: true }
  })
}
