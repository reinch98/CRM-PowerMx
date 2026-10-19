// Pagos a proveedor y anticipos (SQL 85). Solo admin.
//
// Un comprobante de pago (SPEI, depósito, transferencia) que está en la bandeja de Finanzas se lee con
// la IA (leer-comprobante, modo "banco") y se registra: paga una factura por pagar de ese proveedor o
// queda como anticipo (de una cotización de proveedor, o suelto). La base reconoce al proveedor, dice
// qué factura cuadra con el monto y frena un pago que parece repetido hasta que se confirme.
import { supabase } from './supabase'
import { explicarError } from './errores'
import { leerComprobante } from './expediente'
import { aNumero } from './factura'

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

const pesos = v => Number(v || 0).toLocaleString('es-MX', { style: 'currency', currency: 'MXN' })
const texto = v => (typeof v === 'string' ? v.trim() : '')
const fechaValida = v => (/^\d{4}-\d{2}-\d{2}$/.test(texto(v)) ? texto(v) : '')
const FORMAS = { transferencia: 'transferencia', spei: 'transferencia', deposito: 'deposito', 'depósito': 'deposito', cheque: 'cheque', efectivo: 'efectivo' }

// Lo que leyó la IA de un comprobante bancario. Quien RECIBE el dinero es el proveedor.
export function normalizarComprobantePago(leido) {
  const l = leido && typeof leido === 'object' ? leido : {}
  return {
    monto: aNumero(l.monto),
    fecha: fechaValida(l.fecha),
    forma: FORMAS[texto(l.forma).toLowerCase()] || (texto(l.forma) ? 'transferencia' : ''),
    referencia: texto(l.referencia),
    banco: texto(l.banco),
    beneficiario: texto(l.beneficiario),
    ordenante: texto(l.ordenante),
    concepto: texto(l.concepto),
    notas: texto(l.notas)
  }
}

// Con qué se queda el pago si nadie elige: la factura cuyo saldo es exactamente el monto (si es una
// sola); si no, la única cotización aceptada; si no, anticipo suelto.
export function destinoInicial(opciones) {
  const exactas = (opciones?.facturas || []).filter(f => f.exacta)
  if (exactas.length === 1) return { tipo: 'factura', id: exactas[0].cfdi_id }
  const aceptadas = (opciones?.cotizaciones || []).filter(c => c.estado === 'aceptada')
  if (exactas.length === 0 && aceptadas.length === 1) return { tipo: 'cotizacion', id: aceptadas[0].id }
  return { tipo: 'anticipo', id: null }
}

const nombreFactura = f => [f?.serie, f?.folio].filter(Boolean).join(' ') || 'sin folio'

// "Paga la factura A 902 · saldo $8,500.00 · Cuadra exacto"
export function textoOpcionFactura(f, monto) {
  const m = Number(monto) || 0
  const saldo = Number(f.saldo) || 0
  let como
  if (Math.abs(saldo - m) <= 0.01) como = 'Cuadra exacto'
  else if (m < saldo) como = `Pago parcial: quedaría ${pesos(saldo - m)}`
  else como = 'El pago es mayor que lo que se debe'
  return `Paga la factura ${nombreFactura(f)} · saldo ${pesos(saldo)} · ${como}`
}

export function textoOpcionCotizacion(c) {
  const total = c.moneda === 'USD'
    ? `USD ${Number(c.total).toLocaleString('es-MX', { minimumFractionDigits: 2 })} (≈ ${pesos(c.total_mxn)})`
    : pesos(c.total)
  const ya = Number(c.anticipos) > 0 ? ` · ya se dieron ${pesos(c.anticipos)}` : ''
  return `Anticipo de la cotización COTP-${c.folio}${c.numero ? ` (${c.numero})` : ''} · total ${total}${ya}`
}

// Lo que falta antes de registrar (la base lo vuelve a revisar).
export function problemasDePago(form, destino, opciones) {
  const faltas = []
  if (!String(form?.proveedor || '').trim()) faltas.push('Escribe a qué proveedor se le pagó.')
  if (!(Number(form?.monto) > 0)) faltas.push('Escribe el monto pagado.')
  if (!form?.fecha) faltas.push('Escribe la fecha del pago.')
  if (destino?.tipo === 'factura') {
    const f = (opciones?.facturas || []).find(x => x.cfdi_id === destino.id)
    if (!f) faltas.push('Elige la factura que paga.')
    else if (Number(form.monto) > Number(f.saldo) + 0.01) faltas.push('El pago es mayor que el saldo de esa factura: regístralo como anticipo o elige otra.')
  }
  if (destino?.tipo === 'cotizacion' && !destino.id) faltas.push('Elige la cotización del anticipo.')
  return faltas
}

export function paraRegistrar(form, destino, documentoId) {
  return {
    proveedor_id: form.proveedor_id || null,
    proveedor: String(form.proveedor || '').trim(),
    monto: Number(form.monto),
    fecha: form.fecha,
    forma: form.forma || null,
    referencia: String(form.referencia || '').trim() || null,
    cuenta_id: form.cuenta_id || null,
    notas: String(form.notas || '').trim() || null,
    cfdi_id: destino?.tipo === 'factura' ? destino.id : null,
    cotizacion_proveedor_id: destino?.tipo === 'cotizacion' ? destino.id : null,
    documento_id: documentoId || null
  }
}

export function textoRegistrado(r) {
  if (r?.tipo === 'pago_factura') return `Pago registrado: la factura de ${r.proveedor} quedó pagada.`
  if (r?.tipo === 'pago_parcial') return `Pago parcial registrado a ${r.proveedor}: falta ${pesos(r.saldo)} de esa factura.`
  return `Anticipo a ${r?.proveedor} registrado. Cuando llegue su factura, aplícalo en Finanzas → Por pagar.`
}

// ---- llamadas ----

export async function leerComprobantePago(ruta) {
  const r = await leerComprobante(ruta, 'banco')
  if (r.error) return { error: r.error }
  return { lectura: normalizarComprobantePago(r.crudo) }
}
export const cargarOpcionesPago = (proveedor, monto) =>
  rpc('opciones_pago_proveedor', { p_proveedor: proveedor, p_monto: Number(monto) > 0 ? Number(monto) : null })
export const registrarPagoProveedor = (datos, confirmar = false) =>
  rpc('registrar_pago_proveedor', { p_datos: datos, p_confirmar: confirmar })
export const cargarAnticipos = (proveedorId = null) => rpc('anticipos_proveedor', { p_proveedor: proveedorId || null })
export const aplicarAnticipo = (movimientoId, cfdiId) => rpc('aplicar_anticipo', { p_movimiento: movimientoId, p_cfdi: cfdiId })
export const quitarAnticipo = (movimientoId, motivo) =>
  rpc('quitar_anticipo_de_factura', { p_movimiento: movimientoId, p_motivo: motivo })
