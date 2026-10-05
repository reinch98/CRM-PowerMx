// ---------------------------------------------------------------------------
// PDF de la cotización, para mandarlo al cliente.
//
// Conserva el orden y las bandas del formato que PowerMx ya usaba en Excel (encabezado de
// marca, título, datos del cliente, datos del equipo, conceptos, totales y condiciones) y lo
// mejora: solo imprime los datos que existen (nada de "[ ]"), repite el encabezado de la tabla
// en cada hoja, numera las páginas y arma el folio como PMX-COT-AAAAMMDD-0001.
//
// Lo que NUNCA sale: las notas internas, el costo, ni nada que no esté ya en la cotización
// (las partidas se copiaron del catálogo al cotizar, así que el PDF muestra lo que se cotizó,
// no el precio de hoy). Una refacción "incluida en el servicio" va a $0 por dentro; en el papel
// se lee "Incluido", porque un $0.00 parecería un precio que se olvidó capturar.
// ---------------------------------------------------------------------------

import { supabase } from './supabase'
import { paraPdf, fechaLarga } from './documentos.js'
import { sumarDias } from './fechas.js'

const NOCHE = [12, 21, 32]
const AZUL = [31, 56, 100]
const CLARO = [232, 237, 244]
const ZEBRA = [244, 246, 250]
const DURAZNO = [253, 233, 208]
const LINEA = [203, 213, 225]
const TEXTO = [30, 41, 59]
const GRIS = [71, 85, 105]

const CONTACTO_EMPRESA = 'Mérida, Yucatán, México  |  Tel: 999 475 5275  |  pablocana98@gmail.com  |  www.powermx.com.mx'

const NOMBRE_TIPO = {
  venta: 'VENTA DE EQUIPO', instalacion: 'INSTALACIÓN', mantenimiento: 'MANTENIMIENTO',
  diagnostico: 'DIAGNÓSTICO', refacciones: 'REFACCIONES', renta: 'RENTA'
}
const COMBUSTIBLE = { gasolina: 'Gasolina', gas_lp: 'Gas LP', gas_natural: 'Gas natural', diesel: 'Diésel' }

// Solo se edita lo que el cliente todavía no aceptó: una aceptada ya apartó inventario por
// sus partidas, y cambiarlas por debajo dejaría el apartado en otra cantidad.
export const ESTADOS_EDITABLES = ['borrador', 'enviada']
export const sePuedeEditar = estado => ESTADOS_EDITABLES.includes(estado)

export const nombreArchivoCotizacion = c => `COT-${c.folio}.pdf`

export const pesos = v =>
  Number(v || 0).toLocaleString('es-MX', { style: 'currency', currency: 'MXN' })

// PMX-COT-20261005-0042: la fecha de la cotización y su folio con ceros.
export function folioCotizacion(c) {
  const f = String(c.fecha || '').replace(/-/g, '')
  return `PMX-COT-${f || 'SINFECHA'}-${String(c.folio ?? '').padStart(4, '0')}`
}

// '2026-10-05' -> '05/10/2026'
export function fechaCorta(fecha) {
  const [a, m, d] = String(fecha || '').split('-')
  return a && m && d ? `${d}/${m}/${a}` : ''
}

export const tituloDeCotizacion = tipo => `COTIZACIÓN — ${NOMBRE_TIPO[tipo] || 'SERVICIOS'}`

// Lo que se imprime de cada partida.
export function filasDePartidas(partidas) {
  return (partidas || []).map((p, i) => {
    const incluida = p.incluida === true
    const cantidad = Number(p.cantidad || 0)
    return {
      numero: String(i + 1),
      sku: p.sku || '',
      descripcion: p.descripcion || '',
      cantidad: String(cantidad),
      unidad: p.unidad || '',
      precio: incluida ? 'Incluido' : pesos(p.precio_unitario),
      importe: incluida ? 'Incluido' : pesos(p.importe ?? cantidad * Number(p.precio_unitario || 0))
    }
  })
}

export const vigenteHasta = c => sumarDias(c.fecha, c.vigencia_dias || 15)

// Pares etiqueta/valor del cliente. Los vacíos se omiten: un "[ ]" en un documento que se
// manda al cliente se ve como algo que se olvidó llenar.
export function datosDelCliente(c, cliente) {
  const dir = [cliente?.direccion, cliente?.colonia, cliente?.municipio].filter(Boolean).join(', ')
  return [
    ['Folio', folioCotizacion(c)],
    ['Fecha', fechaCorta(c.fecha)],
    ['Cliente', cliente?.nombre || c.clientes?.nombre || ''],
    ['Vigencia (días)', String(c.vigencia_dias || 15)],
    ['Contacto', cliente?.contacto_nombre || ''],
    ['Teléfono', cliente?.telefono || ''],
    ['Correo', cliente?.email || ''],
    ['RFC', cliente?.rfc || ''],
    ['Dirección', dir]
  ].filter(([, v]) => v)
}

export function datosDelEquipo(eq) {
  if (!eq) return []
  const comb = eq.atributos?.combustible
  return [
    ['Marca', eq.marca || ''],
    ['Modelo', eq.modelo || ''],
    ['Capacidad', eq.capacidad_kw ? `${eq.capacidad_kw} kW` : ''],
    ['No. de serie', eq.numero_serie || ''],
    ['Combustible', COMBUSTIBLE[comb] || ''],
    ['Horas de uso', eq.horas_uso != null && eq.horas_uso !== '' ? String(eq.horas_uso) : '']
  ].filter(([, v]) => v)
}

export const lineasDeCondiciones = texto =>
  String(texto || '').split('\n').map(s => s.trim()).filter(Boolean)

export async function cargarClienteParaPdf(clienteId) {
  const { data } = await supabase.from('clientes')
    .select('nombre, rfc, telefono, email, contacto_nombre, direccion, colonia, municipio')
    .eq('id', clienteId).maybeSingle()
  return data || null
}

export async function cargarEquipoParaPdf(equipoId) {
  if (!equipoId) return null
  const { data } = await supabase.from('equipos')
    .select('marca, modelo, capacidad_kw, numero_serie, horas_uso, atributos')
    .eq('id', equipoId).maybeSingle()
  return data || null
}

async function logoDataUrl() {
  try {
    const r = await fetch('/icono-192.png')
    if (!r.ok) return null
    const blob = await r.blob()
    return await new Promise((resolve, reject) => {
      const l = new FileReader()
      l.onload = () => resolve(l.result)
      l.onerror = () => reject(l.error)
      l.readAsDataURL(blob)
    })
  } catch {
    return null
  }
}

// jsPDF se carga aparte, igual que en la orden: arrastra bastante y solo el admin lo usa.
export async function construirPdfCotizacion(c, cliente, equipo) {
  const { jsPDF } = await import('jspdf')
  const doc = new jsPDF({ unit: 'mm', format: 'a4' })
  const ancho = doc.internal.pageSize.getWidth()
  const alto = doc.internal.pageSize.getHeight()
  const m = 12
  const der = ancho - m
  const util = der - m
  const piso = alto - 18          // lo que pasa de aquí se va a la hoja siguiente
  let y = 0

  const salto = h => { if (y + h > piso) { doc.addPage(); y = 16; return true } return false }

  // ---- encabezado de marca (dos bandas, como en el formato de Excel) ----
  doc.setFillColor(...NOCHE).rect(0, 0, ancho, 17, 'F')
  doc.setFillColor(...AZUL).rect(0, 17, ancho, 8, 'F')
  const logo = await logoDataUrl()
  if (logo) doc.addImage(logo, 'PNG', m, 2.5, 12, 12)
  doc.setFont('helvetica', 'bold').setFontSize(16).setTextColor(255, 255, 255)
  doc.text('PowerMx — Soluciones de Energía', ancho / 2 + (logo ? 6 : 0), 11.5, { align: 'center' })
  doc.setFont('helvetica', 'italic').setFontSize(8.2).setTextColor(...CLARO)
  doc.text(paraPdf(CONTACTO_EMPRESA), ancho / 2, 22.2, { align: 'center' })

  // ---- título ----
  doc.setFillColor(...DURAZNO).rect(0, 29, ancho, 10, 'F')
  doc.setFont('helvetica', 'bold').setFontSize(13).setTextColor(...AZUL)
  doc.text(paraPdf(tituloDeCotizacion(c.tipo)), ancho / 2, 35.8, { align: 'center' })
  y = 46

  // ---- barra de sección ----
  const barra = texto => {
    salto(16)
    doc.setFillColor(...AZUL).rect(m, y - 4.6, util, 7, 'F')
    doc.setFont('helvetica', 'bold').setFontSize(10).setTextColor(255, 255, 255)
    doc.text(paraPdf(texto), m + 2, y)
    y += 6
  }

  // ---- rejilla de datos en dos columnas: etiqueta en azul, valor debajo de línea fina ----
  const rejilla = pares => {
    const colAncho = util / 2
    const etiquetaAncho = 28
    for (let i = 0; i < pares.length; i += 2) {
      const celdas = pares.slice(i, i + 2).map(([e, v], k) => {
        const x = m + k * colAncho
        const lineas = doc.splitTextToSize(paraPdf(v), colAncho - etiquetaAncho - 3)
        return { e, x, lineas }
      })
      const alturaFila = Math.max(...celdas.map(cl => cl.lineas.length)) * 4.8 + 1.6
      salto(alturaFila)
      for (const cl of celdas) {
        doc.setFont('helvetica', 'bold').setFontSize(9.5).setTextColor(...AZUL)
        doc.text(paraPdf(`${cl.e}:`), cl.x + 1, y)
        doc.setFont('helvetica', 'normal').setFontSize(9.5).setTextColor(...TEXTO)
        doc.text(cl.lineas, cl.x + etiquetaAncho, y)
      }
      doc.setDrawColor(...LINEA).setLineWidth(0.2).line(m, y + alturaFila - 3.6, der, y + alturaFila - 3.6)
      y += alturaFila
    }
    y += 2
  }

  rejilla(datosDelCliente(c, cliente))
  const eq = datosDelEquipo(equipo)
  if (eq.length) { barra('DATOS DEL EQUIPO'); rejilla(eq) }

  // ---- tabla de conceptos ----
  barra('CONCEPTOS COTIZADOS')
  const ancho_col = { no: 10, desc: 84, cant: 18, uni: 22, precio: 26, sub: 26 }
  const x_no = m
  const x_desc = x_no + ancho_col.no
  const x_cant = x_desc + ancho_col.desc
  const x_uni = x_cant + ancho_col.cant
  const x_precio = x_uni + ancho_col.uni
  const x_sub = x_precio + ancho_col.precio

  const encabezadoTabla = () => {
    doc.setFillColor(...AZUL).rect(m, y - 4.4, util, 7.4, 'F')
    doc.setFont('helvetica', 'bold').setFontSize(9).setTextColor(255, 255, 255)
    doc.text('No.', x_no + ancho_col.no / 2, y, { align: 'center' })
    doc.text('Descripción', x_desc + 2, y)
    doc.text('Cantidad', x_cant + ancho_col.cant / 2, y, { align: 'center' })
    doc.text('Unidad', x_uni + ancho_col.uni / 2, y, { align: 'center' })
    doc.text('Precio unitario', x_precio + ancho_col.precio - 2, y, { align: 'right' })
    doc.text('Subtotal', x_sub + ancho_col.sub - 2, y, { align: 'right' })
    y += 6.2
  }
  encabezadoTabla()

  filasDePartidas(c.partidas).forEach((f, i) => {
    const texto = f.sku ? `${f.sku} — ${f.descripcion}` : f.descripcion
    const lineas = doc.splitTextToSize(paraPdf(texto), ancho_col.desc - 4)
    const h = lineas.length * 4.6 + 3
    if (salto(h + 2)) encabezadoTabla()
    if (i % 2 === 0) doc.setFillColor(...ZEBRA).rect(m, y - 3.9, util, h, 'F')
    doc.setFont('helvetica', 'normal').setFontSize(9).setTextColor(...TEXTO)
    doc.text(f.numero, x_no + ancho_col.no / 2, y, { align: 'center' })
    doc.text(lineas, x_desc + 2, y)
    doc.text(paraPdf(f.cantidad), x_cant + ancho_col.cant / 2, y, { align: 'center' })
    doc.text(paraPdf(f.unidad), x_uni + ancho_col.uni / 2, y, { align: 'center' })
    doc.text(paraPdf(f.precio), x_precio + ancho_col.precio - 2, y, { align: 'right' })
    doc.text(paraPdf(f.importe), x_sub + ancho_col.sub - 2, y, { align: 'right' })
    y += h
  })
  doc.setDrawColor(...LINEA).setLineWidth(0.2).line(m, y - 3.9, der, y - 3.9)

  // ---- totales ----
  y += 2
  const fila = (etiqueta, valor) => {
    salto(7)
    doc.setFont('helvetica', 'bold').setFontSize(9.5).setTextColor(...AZUL)
    doc.text(paraPdf(etiqueta), x_precio + ancho_col.precio - 2, y, { align: 'right' })
    doc.setFont('helvetica', 'normal').setTextColor(...TEXTO)
    doc.text(paraPdf(valor), x_sub + ancho_col.sub - 2, y, { align: 'right' })
    y += 5.6
  }
  fila('Subtotal:', pesos(c.subtotal))
  if (Number(c.descuento) > 0) fila('Descuento:', `-${pesos(c.descuento)}`)
  fila('IVA (16%):', pesos(c.iva))
  salto(10)
  doc.setFillColor(...AZUL).rect(x_precio - 14, y - 4.6, der - (x_precio - 14), 8, 'F')
  doc.setFont('helvetica', 'bold').setFontSize(11).setTextColor(255, 255, 255)
  doc.text('TOTAL:', x_precio + ancho_col.precio - 2, y + 0.4, { align: 'right' })
  doc.text(paraPdf(pesos(c.total)), x_sub + ancho_col.sub - 2, y + 0.4, { align: 'right' })
  y += 12

  // ---- condiciones ----
  barra('CONDICIONES')
  const vig = c.vigencia_dias || 15
  const hasta = fechaLarga(vigenteHasta(c)) || vigenteHasta(c)
  const condiciones = [
    ['Vigencia', `${vig} días naturales a partir de la fecha de emisión (hasta el ${hasta}).`],
    ...lineasDeCondiciones(c.condiciones).map(t => ['', t])
  ]
  for (const [etiqueta, texto] of condiciones) {
    const lineas = doc.splitTextToSize(paraPdf(etiqueta ? texto : `•  ${texto}`), util - 34)
    salto(lineas.length * 4.8 + 1)
    if (etiqueta) {
      doc.setFont('helvetica', 'bold').setFontSize(9.5).setTextColor(...AZUL)
      doc.text(`${etiqueta}:`, m + 1, y)
    }
    doc.setFont('helvetica', 'normal').setFontSize(9.5).setTextColor(...TEXTO)
    doc.text(lineas, etiqueta ? m + 28 : m + 3, y)
    y += lineas.length * 4.8 + 1.2
  }

  // ---- pie en cada hoja ----
  const paginas = doc.getNumberOfPages()
  for (let p = 1; p <= paginas; p++) {
    doc.setPage(p)
    doc.setDrawColor(...LINEA).setLineWidth(0.2).line(m, alto - 12, der, alto - 12)
    doc.setFont('helvetica', 'normal').setFontSize(8).setTextColor(...GRIS)
    doc.text(paraPdf(`PowerMx · ${folioCotizacion(c)}`), m, alto - 7.5)
    doc.text(`Página ${p} de ${paginas}`, der, alto - 7.5, { align: 'right' })
  }
  return doc.output('blob')
}

// Descarga en el navegador. En iPhone y en Android guarda o abre el archivo.
export function descargarBlob(blob, nombre) {
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = nombre
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 60000)
}
