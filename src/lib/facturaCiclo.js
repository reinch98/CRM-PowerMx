// La factura cierra el ciclo de compras (SQL 86). Solo admin.
//
// Una factura recibida (su XML) se liga a su COMPRA (el material que entró al almacén), a su COTIZACIÓN
// de proveedor y a sus PAGOS (incluidos los anticipos que se dieron antes de que llegara). La base liga
// sola lo seguro y propone lo demás; aquí se arma lo que se ve y se corrige a mano. Y si la factura es
// de material que todavía no entró, la compra se registra desde el mismo XML, sin volver a leerla.
import { supabase } from './supabase'
import { explicarError } from './errores'
import { normalizarLectura } from './factura'

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

const num = v => (Number.isFinite(Number(v)) ? Number(v) : 0)
const redondear = v => Math.round(num(v) * 100) / 100
export const pesos = v => num(v).toLocaleString('es-MX', { style: 'currency', currency: 'MXN' })
const dinero = (v, moneda) => (moneda === 'USD'
  ? `USD ${num(v).toLocaleString('es-MX', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
  : pesos(v))
const fechaCorta = f => (/^\d{4}-\d{2}-\d{2}/.test(String(f || '')) ? String(f).slice(0, 10).split('-').reverse().join('/') : '')

// La fecha de un CFDI (con hora y zona) como día de Mérida.
function diaMerida(fecha) {
  const d = new Date(fecha)
  if (Number.isNaN(d.getTime())) return ''
  return d.toLocaleDateString('en-CA', { timeZone: 'America/Merida' })
}

// ---------------------------------------------------------------------------
// La "lectura" de una factura armada desde su XML, con la misma forma que la que da la IA: así el mismo
// revisor de renglones (FacturaLeida) mete el material al almacén sin gastar una lectura.
// Una factura en dólares se pasa a pesos con SU tipo de cambio (la compra se guarda en pesos).
// ---------------------------------------------------------------------------
export function lecturaDesdeCfdi(cfdi, nombreProveedor = '') {
  const c = cfdi || {}
  const usd = c.moneda === 'USD' && num(c.tipo_cambio) > 0
  const f = usd ? num(c.tipo_cambio) : 1
  const notas = []
  if (usd) notas.push(`La factura viene en dólares: se pasó a pesos con su tipo de cambio (${num(c.tipo_cambio)}).`)
  if (c.moneda === 'USD' && !usd) notas.push('La factura viene en dólares y no trae tipo de cambio: escribe los costos ya en pesos.')
  if (num(c.descuento) > 0) {
    notas.push(`La factura trae un descuento de ${pesos(num(c.descuento) * f)} que no está repartido en los renglones: ajusta los costos si quieres que lo reflejen.`)
  }
  const crudo = {
    proveedor: nombreProveedor || c.nombre_emisor || '',
    rfc: c.rfc_emisor || '',
    factura: [c.serie, c.folio].filter(Boolean).join('-'),
    uuid_fiscal: c.uuid_fiscal || '',
    fecha: diaMerida(c.fecha),
    moneda: usd ? 'MXN' : (c.moneda || 'MXN'),
    precios_incluyen_iva: false,
    subtotal: redondear(num(c.subtotal) * f),
    iva: redondear(num(c.iva_trasladado) * f),
    total: redondear(num(c.total) * f),
    lineas: (Array.isArray(c.conceptos) ? c.conceptos : []).map(x => ({
      codigo: x?.codigo || '',
      descripcion: x?.descripcion || '',
      cantidad: num(x?.cantidad),
      unidad: '',
      precio_unitario: Math.round(num(x?.valor_unitario) * f * 10000) / 10000,
      importe: redondear(num(x?.importe) * f)
    })),
    notas: notas.join(' ')
  }
  return normalizarLectura(crudo)
}

// ---------------------------------------------------------------------------
// Textos
// ---------------------------------------------------------------------------
export const nombreFactura = f => [f?.serie, f?.folio].filter(Boolean).join(' ') || 'sin folio'

export function textoCompra(co) {
  if (!co) return ''
  return [`Compra ${co.folio}`, co.factura && `factura ${co.factura}`, fechaCorta(co.fecha), pesos(co.total)].filter(Boolean).join(' · ')
}

export function textoCotizacion(q) {
  if (!q) return ''
  const total = q.moneda === 'USD'
    ? `${dinero(q.total, 'USD')}${num(q.total_mxn) > 0 ? ` (≈ ${pesos(q.total_mxn)})` : ''}`
    : pesos(q.total)
  return [`COTP-${q.folio}${q.numero ? ` (${q.numero})` : ''}`, q.estado === 'aceptada' ? 'aceptada' : 'vigente', total].join(' · ')
}

export function textoAnticipo(a) {
  return [pesos(a.monto), fechaCorta(a.fecha) && `pagado el ${fechaCorta(a.fecha)}`, a.cotizacion_proveedor, a.referencia && `ref. ${a.referencia}`]
    .filter(Boolean).join(' · ')
}

// ---------------------------------------------------------------------------
// Anticipos al aprobar la factura
// ---------------------------------------------------------------------------

// Los que se proponen marcados: primero los de SU cotización, mientras quepan en el saldo; si no hay de
// su cotización, uno solo que cuadre EXACTO con lo que se debe. Con dudas no se marca nada.
export function anticiposIniciales(ctx) {
  const saldo = num(ctx?.factura?.saldo)
  const lista = Array.isArray(ctx?.anticipos) ? ctx.anticipos : []
  const ids = []
  let suma = 0
  for (const a of lista.filter(x => x.de_su_cotizacion)) {
    if (suma + num(a.monto) <= saldo + 0.01) { ids.push(a.movimiento_id); suma += num(a.monto) }
  }
  if (ids.length) return ids
  const exactos = lista.filter(a => Math.abs(num(a.monto) - saldo) <= 0.01)
  return exactos.length === 1 ? [exactos[0].movimiento_id] : []
}

export function sumaAnticipos(ctx, ids) {
  const elegidos = new Set(ids || [])
  return redondear((ctx?.anticipos || []).filter(a => elegidos.has(a.movimiento_id)).reduce((s, a) => s + num(a.monto), 0))
}

export function problemaDeAnticipos(ctx, ids) {
  if (!ids?.length) return ''
  const saldo = num(ctx?.factura?.saldo)
  const suma = sumaAnticipos(ctx, ids)
  if (suma > saldo + 0.01) return `Los anticipos elegidos (${pesos(suma)}) suman más de lo que se debe de esta factura (${pesos(saldo)}).`
  return ''
}

// "Ya la pagué" cuando ya hay un anticipo de ese mismo monto: probablemente es el mismo pago.
export function avisoPagoDoble(ctx, pagado) {
  if (!pagado) return ''
  const total = num(ctx?.factura?.total)
  const a = (ctx?.anticipos || []).find(x => Math.abs(num(x.monto) - total) <= 0.01)
  if (!a) return ''
  return `Ya registraste un pago de ${pesos(a.monto)} a ${ctx.factura.proveedor || 'este proveedor'}${fechaCorta(a.fecha) ? ` el ${fechaCorta(a.fecha)}` : ''} como anticipo. Si es el pago de esta factura, aplícalo en vez de registrar otro: contarías el pago dos veces.`
}

// ---------------------------------------------------------------------------
// Llamadas
// ---------------------------------------------------------------------------
export const cargarContextoFactura = cfdiId => rpc('factura_contexto', { p_cfdi: cfdiId })
// La fila completa (con sus conceptos) para meter el material al almacén desde el XML.
export async function cargarCfdi(cfdiId) {
  try {
    const { data, error } = await supabase.from('cfdi').select('*').eq('id', cfdiId).maybeSingle()
    if (error) return { error: textoDeError(error) }
    if (!data) return { error: 'No encontré esa factura.' }
    return { data }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}
export const ligarFactura = (cfdiId, { compra = null, cotizacion = null } = {}) =>
  rpc('ligar_factura', { p_cfdi: cfdiId, p_compra: compra, p_cotizacion: cotizacion })
export const desligarFactura = (cfdiId, que) => rpc('desligar_factura', { p_cfdi: cfdiId, p_que: que })
