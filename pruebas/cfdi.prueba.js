import { test } from 'node:test'
import assert from 'node:assert/strict'
import { DOMParser } from 'linkedom'
import { leerCfdiXml, etiquetaFormaPagoSat, etiquetaTipoComprobante } from '../src/lib/cfdi.js'

// CFDI 4.0 sintético: servicio de 1,000 + IVA 160 − retención de ISR de 12.50 = 1,147.50.
const UUID = 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE'
const xml = ({ total = '1147.50', subtotal = '1000.00', extra = '', tipo = 'I', timbre = true } = {}) => `<?xml version="1.0" encoding="UTF-8"?>
<cfdi:Comprobante xmlns:cfdi="http://www.sat.gob.mx/cfd/4" xmlns:tfd="http://www.sat.gob.mx/TimbreFiscalDigital"
  Version="4.0" Serie="A" Folio="123" Fecha="2026-10-09T14:03:11" SubTotal="${subtotal}" Total="${total}"
  Moneda="MXN" TipoDeComprobante="${tipo}" MetodoPago="PPD" FormaPago="99" LugarExpedicion="97000">
  <cfdi:Emisor Rfc="EKU9003173C9" Nombre="PROVEEDOR DE PRUEBA SA" RegimenFiscal="601"/>
  <cfdi:Receptor Rfc="XAXX010101000" Nombre="PUBLICO EN GENERAL" UsoCFDI="G03"/>
  <cfdi:Conceptos>
    <cfdi:Concepto ClaveProdServ="81111500" Cantidad="1" ClaveUnidad="E48" Descripcion="Servicio de mantenimiento"
      ValorUnitario="${subtotal}" Importe="${subtotal}">
      <cfdi:Impuestos><cfdi:Traslados><cfdi:Traslado Base="1000.00" Impuesto="002" TipoFactor="Tasa" TasaOCuota="0.160000" Importe="160.00"/></cfdi:Traslados></cfdi:Impuestos>
    </cfdi:Concepto>
  </cfdi:Conceptos>
  <cfdi:Impuestos TotalImpuestosRetenidos="12.50" TotalImpuestosTrasladados="160.00">
    <cfdi:Retenciones><cfdi:Retencion Impuesto="001" Importe="12.50"/></cfdi:Retenciones>
    <cfdi:Traslados><cfdi:Traslado Base="1000.00" Impuesto="002" TipoFactor="Tasa" TasaOCuota="0.160000" Importe="160.00"/></cfdi:Traslados>
  </cfdi:Impuestos>
  ${extra}
  <cfdi:Complemento>${timbre ? `<tfd:TimbreFiscalDigital Version="1.1" UUID="${UUID}" FechaTimbrado="2026-10-09T14:03:20"/>` : ''}</cfdi:Complemento>
</cfdi:Comprobante>`

test('lee los datos de una factura 4.0', () => {
  const r = leerCfdiXml(xml(), DOMParser)
  assert.equal(r.error, undefined)
  const d = r.datos
  assert.equal(d.uuid_fiscal, UUID.toLowerCase())
  assert.equal(d.rfc_emisor, 'EKU9003173C9')
  assert.equal(d.rfc_receptor, 'XAXX010101000')
  assert.equal(d.subtotal, 1000)
  assert.equal(d.total, 1147.5)
  assert.equal(d.iva_trasladado, 160)
  assert.equal(d.isr_retenido, 12.5)
  assert.equal(d.iva_retenido, 0)
  assert.equal(d.metodo_pago, 'PPD')
  assert.equal(d.tipo_comprobante, 'I')
  assert.equal(d.conceptos.length, 1)
  assert.equal(d.conceptos[0].clave, '81111500')
  assert.deepEqual(r.avisos, [])
})

test('el IVA no se cuenta dos veces: los impuestos de cada concepto no suman al total', () => {
  const r = leerCfdiXml(xml(), DOMParser)
  assert.equal(r.datos.iva_trasladado, 160)
})

test('la fecha sin zona se guarda como hora de Mérida (-06:00)', () => {
  assert.equal(leerCfdiXml(xml(), DOMParser).datos.fecha, '2026-10-09T14:03:11-06:00')
})

test('avisa cuando el total no cuadra con los impuestos', () => {
  const r = leerCfdiXml(xml({ total: '1200.00' }), DOMParser)
  assert.ok(r.avisos.some(a => /total dice 1200\.00/.test(a.texto)))
})

test('avisa cuando los conceptos no suman el subtotal', () => {
  const roto = xml().replace('SubTotal="1000.00"', 'SubTotal="900.00"')
  assert.ok(leerCfdiXml(roto, DOMParser).avisos.some(a => /conceptos suman 1000\.00/.test(a.texto)))
})

test('sin timbre no es un CFDI utilizable', () => {
  const r = leerCfdiXml(xml({ timbre: false }), DOMParser)
  assert.match(r.error, /timbre/)
})

test('lee los CFDI relacionados', () => {
  const extra = `<cfdi:CfdiRelacionados TipoRelacion="01"><cfdi:CfdiRelacionado UUID="11111111-2222-3333-4444-555555555555"/></cfdi:CfdiRelacionados>`
  const r = leerCfdiXml(xml({ extra }), DOMParser)
  assert.deepEqual(r.datos.relacionados, ['11111111-2222-3333-4444-555555555555'])
})

test('rechaza lo que no es un CFDI', () => {
  assert.match(leerCfdiXml('', DOMParser).error, /vacío/)
  assert.match(leerCfdiXml('<hola/>', DOMParser).error, /no es un CFDI/)
  assert.ok(leerCfdiXml('esto no es xml', DOMParser).error)
})

test('rechaza XML con DOCTYPE o entidades (nunca los lleva un CFDI)', () => {
  const malo = '<?xml version="1.0"?><!DOCTYPE x [<!ENTITY a "b">]><cfdi:Comprobante/>'
  assert.match(leerCfdiXml(malo, DOMParser).error, /válido/)
})

test('etiquetas en palabras', () => {
  assert.equal(etiquetaFormaPagoSat('03'), 'Transferencia')
  assert.equal(etiquetaFormaPagoSat('99'), 'Por definir')
  assert.equal(etiquetaFormaPagoSat(''), '—')
  assert.equal(etiquetaTipoComprobante('P'), 'Complemento de pago')
})
