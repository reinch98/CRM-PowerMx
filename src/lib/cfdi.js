// ---------------------------------------------------------------------------
// Lectura de un CFDI (XML 3.3 o 4.0) SIN IA.
//
// Un XML timbrado es estructurado y exacto: no hay nada que "interpretar", así que se lee con un
// parser y no cuesta nada. La IA solo entra con PDF o fotos, y siempre se valida contra el XML
// cuando existe.
//
// Esta función es pura: recibe el texto y el constructor de `DOMParser` (el del navegador o el de
// linkedom en las pruebas) y devuelve { datos, avisos } o { error }. No toca la red ni la base.
// El sentido (emitido o recibido) NO se decide aquí: lo decide la base comparando con tu RFC.
// ---------------------------------------------------------------------------

export const MAX_BYTES_XML = 2 * 1024 * 1024

const nombreLocal = el => String(el.localName || el.tagName || '').split(':').pop()
const hijos = el => Array.from(el?.childNodes || []).filter(n => n.nodeType === 1)
const hijosNombre = (el, nombre) => hijos(el).filter(n => nombreLocal(n) === nombre)
// Recorre por `childNodes` y no con getElementsByTagName('*'): linkedom (las pruebas) no lo
// soporta en XML y el recorrido manual da lo mismo en el navegador.
function descendientes(el, nombre) {
  const salida = []
  const visitar = nodo => {
    for (const h of hijos(nodo)) {
      if (nombreLocal(h) === nombre) salida.push(h)
      visitar(h)
    }
  }
  if (el) visitar(el)
  return salida
}
const attr = (el, nombre) => {
  const v = el?.getAttribute?.(nombre)
  return v == null ? '' : String(v).trim()
}
const num = v => {
  const n = Number(v)
  return Number.isFinite(n) ? n : 0
}
const redondear = n => Math.round(n * 100) / 100

// La fecha del CFDI viene sin zona ("2026-10-09T14:03:11"); es hora del centro de México y
// Mérida no cambia de horario. Sin zona, la base la tomaría como UTC y movería el día.
function fechaConZona(f) {
  if (!f) return ''
  return /[zZ]|[+-]\d{2}:\d{2}$/.test(f) ? f : `${f}-06:00`
}

export function leerCfdiXml(texto, Parser) {
  if (typeof texto !== 'string' || !texto.trim()) return { error: 'El archivo está vacío.' }
  if (texto.length > MAX_BYTES_XML) return { error: 'El XML pesa demasiado para ser un CFDI.' }
  // Un CFDI nunca lleva DOCTYPE ni entidades; rechazarlos cierra la puerta a XML malicioso.
  if (/<!DOCTYPE|<!ENTITY/i.test(texto)) return { error: 'Ese XML no es un CFDI válido.' }

  let doc
  try {
    doc = new Parser().parseFromString(texto, 'text/xml')
  } catch {
    return { error: 'No pude abrir el XML.' }
  }
  if (!doc || !doc.documentElement || descendientes(doc, 'parsererror').length > 0
      || nombreLocal(doc.documentElement) === 'parsererror') {
    return { error: 'El XML está dañado o no es un XML.' }
  }

  const comprobante = descendientes(doc, 'Comprobante')[0]
  if (!comprobante) return { error: 'Ese XML no es un CFDI (no encuentro el Comprobante).' }

  const timbre = descendientes(doc, 'TimbreFiscalDigital')[0]
  const uuid = attr(timbre, 'UUID').toLowerCase()
  if (!uuid) {
    return { error: 'El XML no trae timbre (UUID): es un borrador o no está timbrado.' }
  }

  const emisor = hijosNombre(comprobante, 'Emisor')[0] || descendientes(doc, 'Emisor')[0]
  const receptor = hijosNombre(comprobante, 'Receptor')[0] || descendientes(doc, 'Receptor')[0]
  const rfcEmisor = attr(emisor, 'Rfc').toUpperCase()
  const rfcReceptor = attr(receptor, 'Rfc').toUpperCase()
  if (!rfcEmisor || !rfcReceptor) return { error: 'El XML no trae el RFC del emisor o del receptor.' }

  // Impuestos del comprobante: el nodo que cuelga directo de Comprobante, no los de cada concepto.
  const impuestos = hijosNombre(comprobante, 'Impuestos')[0]
  const traslados = impuestos ? descendientes(impuestos, 'Traslado') : []
  const retenciones = impuestos ? descendientes(impuestos, 'Retencion') : []
  const suma = (lista, filtro) =>
    redondear(lista.filter(filtro).reduce((s, n) => s + num(attr(n, 'Importe')), 0))
  const ivaTrasladado = suma(traslados, n => attr(n, 'Impuesto') === '002')
  const totalTraslados = suma(traslados, () => true)
  const isrRetenido = suma(retenciones, n => attr(n, 'Impuesto') === '001')
  const ivaRetenido = suma(retenciones, n => attr(n, 'Impuesto') === '002')
  const totalRetenciones = suma(retenciones, () => true)

  const conceptos = descendientes(hijosNombre(comprobante, 'Conceptos')[0], 'Concepto').map(c => ({
    clave: attr(c, 'ClaveProdServ'),
    descripcion: attr(c, 'Descripcion'),
    cantidad: num(attr(c, 'Cantidad')),
    unidad: attr(c, 'ClaveUnidad'),
    valor_unitario: num(attr(c, 'ValorUnitario')),
    importe: num(attr(c, 'Importe'))
  }))

  const relacionados = [
    ...descendientes(doc, 'CfdiRelacionado').map(n => attr(n, 'UUID')),
    ...descendientes(doc, 'DoctoRelacionado').map(n => attr(n, 'IdDocumento'))
  ].map(u => u.toLowerCase()).filter(Boolean)

  const subtotal = num(attr(comprobante, 'SubTotal'))
  const descuento = num(attr(comprobante, 'Descuento'))
  const total = num(attr(comprobante, 'Total'))
  const version = attr(comprobante, 'Version') || attr(comprobante, 'version')
  const tipo = attr(comprobante, 'TipoDeComprobante') || 'I'
  const moneda = attr(comprobante, 'Moneda') || 'MXN'

  const avisos = []
  if (!['4.0', '3.3'].includes(version)) {
    avisos.push({ nivel: 'aviso', texto: `Versión de CFDI poco común (${version || 'sin versión'}).` })
  }
  const sumaConceptos = redondear(conceptos.reduce((s, c) => s + c.importe, 0))
  if (conceptos.length > 0 && Math.abs(sumaConceptos - subtotal) > 0.02) {
    avisos.push({ nivel: 'aviso', texto: `Los conceptos suman ${sumaConceptos.toFixed(2)} y el subtotal dice ${subtotal.toFixed(2)}.` })
  }
  const esperado = redondear(subtotal - descuento + totalTraslados - totalRetenciones)
  if (tipo !== 'P' && Math.abs(esperado - total) > 0.02) {
    avisos.push({ nivel: 'aviso', texto: `Subtotal más impuestos da ${esperado.toFixed(2)} pero el total dice ${total.toFixed(2)}.` })
  }

  return {
    datos: {
      version,
      uuid_fiscal: uuid,
      tipo_comprobante: tipo,
      serie: attr(comprobante, 'Serie'),
      folio: attr(comprobante, 'Folio'),
      fecha: fechaConZona(attr(comprobante, 'Fecha')),
      rfc_emisor: rfcEmisor,
      nombre_emisor: attr(emisor, 'Nombre'),
      regimen_emisor: attr(emisor, 'RegimenFiscal'),
      rfc_receptor: rfcReceptor,
      nombre_receptor: attr(receptor, 'Nombre'),
      uso_cfdi: attr(receptor, 'UsoCFDI'),
      subtotal,
      descuento,
      total,
      iva_trasladado: ivaTrasladado,
      isr_retenido: isrRetenido,
      iva_retenido: ivaRetenido,
      moneda,
      tipo_cambio: moneda !== 'MXN' ? num(attr(comprobante, 'TipoCambio')) || null : null,
      metodo_pago: attr(comprobante, 'MetodoPago'),
      forma_pago: attr(comprobante, 'FormaPago'),
      lugar_expedicion: attr(comprobante, 'LugarExpedicion'),
      conceptos,
      relacionados
    },
    avisos
  }
}

// ---- vocabulario del SAT, dicho con palabras ----

export const FORMAS_PAGO_SAT = {
  '01': 'Efectivo', '02': 'Cheque', '03': 'Transferencia', '04': 'Tarjeta de crédito',
  '05': 'Monedero electrónico', '06': 'Dinero electrónico', '08': 'Vales de despensa',
  '12': 'Dación en pago', '13': 'Subrogación', '14': 'Consignación', '15': 'Condonación',
  '17': 'Compensación', '23': 'Novación', '24': 'Confusión', '25': 'Remisión de deuda',
  '26': 'Prescripción', '27': 'A satisfacción del acreedor', '28': 'Tarjeta de débito',
  '29': 'Tarjeta de servicios', '30': 'Aplicación de anticipos', '31': 'Intermediario de pagos',
  '99': 'Por definir'
}
export const etiquetaFormaPagoSat = c => FORMAS_PAGO_SAT[c] || c || '—'

export const TIPOS_COMPROBANTE = {
  I: 'Factura', E: 'Nota de crédito', P: 'Complemento de pago', N: 'Nómina', T: 'Traslado'
}
export const etiquetaTipoComprobante = t => TIPOS_COMPROBANTE[t] || t || '—'

export const METODOS_PAGO = { PUE: 'Pago en una sola exhibición', PPD: 'Pago en parcialidades o diferido' }
