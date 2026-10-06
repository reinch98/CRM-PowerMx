// ---------------------------------------------------------------------------
// Piezas de estilo para los PDF de PowerMx (orden de servicio y, en su día, la cotización):
// encabezado de marca en dos bandas, banda de título, barras de sección, rejilla de datos,
// tablas con líneas, cajas de texto y pie con número de página.
//
// `fmt` es `paraPdf` de documentos.js (traduce lo que Helvetica no sabe escribir). Se recibe
// como parámetro para que este módulo no importe a documentos.js y no haya un ciclo.
// ---------------------------------------------------------------------------

export const NOCHE = [12, 21, 32]
export const AZUL = [31, 56, 100]
export const CLARO = [232, 237, 244]
export const ZEBRA = [244, 246, 250]
export const DURAZNO = [253, 233, 208]
export const LINEA = [203, 213, 225]
export const TEXTO = [30, 41, 59]
export const GRIS = [71, 85, 105]

export const CONTACTO_EMPRESA =
  'Mérida, Yucatán, México  |  Tel: 999 475 5275  |  pablocana98@gmail.com  |  www.powermx.com.mx'

// Altura de una celda de texto: renglones por interlineado más un margen.
export const alturaDeCelda = (renglones, interlineado = 4.4) => Math.max(1, renglones) * interlineado + 2.4

export function crearLienzo(doc, fmt) {
  const ancho = doc.internal.pageSize.getWidth()
  const alto = doc.internal.pageSize.getHeight()
  const m = 12
  const L = {
    doc, ancho, alto, m, der: ancho - m, util: ancho - 2 * m, y: 0,
    piso: alto - 18   // lo que pasa de aquí se va a la hoja siguiente
  }

  // Devuelve true si tuvo que cambiar de hoja.
  L.salto = h => {
    if (L.y + h > L.piso) { doc.addPage(); L.y = 16; return true }
    return false
  }

  L.encabezado = ({ logo, titulo }) => {
    doc.setFillColor(...NOCHE).rect(0, 0, ancho, 17, 'F')
    doc.setFillColor(...AZUL).rect(0, 17, ancho, 8, 'F')
    if (logo) doc.addImage(logo, 'PNG', m, 2.5, 12, 12)
    doc.setFont('helvetica', 'bold').setFontSize(16).setTextColor(255, 255, 255)
    doc.text('PowerMx — Soluciones de Energía', ancho / 2 + (logo ? 6 : 0), 11.5, { align: 'center' })
    doc.setFont('helvetica', 'italic').setFontSize(8.2).setTextColor(...CLARO)
    doc.text(fmt(CONTACTO_EMPRESA), ancho / 2, 22.2, { align: 'center' })
    doc.setFillColor(...DURAZNO).rect(0, 29, ancho, 10, 'F')
    doc.setFont('helvetica', 'bold').setFontSize(12.5).setTextColor(...AZUL)
    doc.text(fmt(titulo), ancho / 2, 35.8, { align: 'center' })
    L.y = 46
  }

  L.barra = texto => {
    L.salto(18)
    doc.setFillColor(...AZUL).rect(m, L.y - 4.6, L.util, 7, 'F')
    doc.setFont('helvetica', 'bold').setFontSize(10).setTextColor(255, 255, 255)
    doc.text(fmt(texto), m + 2, L.y)
    L.y += 6.4
  }

  // Datos en dos columnas: etiqueta en azul, valor y línea fina debajo.
  L.rejilla = pares => {
    const colAncho = L.util / 2
    const etiquetaAncho = 28
    for (let i = 0; i < pares.length; i += 2) {
      const celdas = pares.slice(i, i + 2).map(([e, v], k) => ({
        e, x: m + k * colAncho,
        lineas: doc.splitTextToSize(fmt(v), colAncho - etiquetaAncho - 3)
      }))
      const alturaFila = Math.max(...celdas.map(cl => cl.lineas.length)) * 4.8 + 1.6
      L.salto(alturaFila)
      for (const cl of celdas) {
        doc.setFont('helvetica', 'bold').setFontSize(9.5).setTextColor(...AZUL)
        doc.text(fmt(`${cl.e}:`), cl.x + 1, L.y)
        doc.setFont('helvetica', 'normal').setFontSize(9.5).setTextColor(...TEXTO)
        doc.text(cl.lineas, cl.x + etiquetaAncho, L.y)
      }
      doc.setDrawColor(...LINEA).setLineWidth(0.2).line(m, L.y + alturaFila - 3.6, L.der, L.y + alturaFila - 3.6)
      L.y += alturaFila
    }
    L.y += 2
  }

  // Caja con borde y texto corrido. Un texto largo se parte entre hojas, cada parte con su borde.
  L.caja = (texto, { tamano = 9.5, relleno = null } = {}) => {
    const lineas = doc.splitTextToSize(fmt(texto), L.util - 6)
    let i = 0
    while (i < lineas.length) {
      L.salto(14)
      const caben = Math.max(1, Math.floor((L.piso - L.y - 3) / 4.6))
      const parte = lineas.slice(i, i + caben)
      const h = parte.length * 4.6 + 3.6
      if (relleno) doc.setFillColor(...relleno).rect(m, L.y - 4, L.util, h, 'F')
      doc.setDrawColor(...LINEA).setLineWidth(0.25).rect(m, L.y - 4, L.util, h)
      doc.setFont('helvetica', 'normal').setFontSize(tamano).setTextColor(...TEXTO)
      doc.text(parte, m + 3, L.y)
      L.y += h + 1
      i += parte.length
    }
    L.y += 2
  }

  // Tabla con líneas en todas las celdas. `columnas`: [{ t, ancho, align }] (ancho en mm, que
  // sumen L.util). `filas`: arreglos de texto. El encabezado se repite en cada hoja.
  L.tabla = (columnas, filas, { tamano = 8.8, zebra = true } = {}) => {
    const xs = []
    columnas.reduce((x, c) => { xs.push(x); return x + c.ancho }, m)
    const encabezado = () => {
      L.salto(14)
      doc.setFillColor(...AZUL).rect(m, L.y - 4.4, L.util, 7, 'F')
      doc.setFont('helvetica', 'bold').setFontSize(tamano).setTextColor(255, 255, 255)
      columnas.forEach((c, i) => {
        const x = c.align === 'right' ? xs[i] + c.ancho - 1.6 : c.align === 'center' ? xs[i] + c.ancho / 2 : xs[i] + 1.6
        doc.text(fmt(c.t), x, L.y, { align: c.align || 'left' })
      })
      doc.setDrawColor(...LINEA).setLineWidth(0.2)
      L.y += 5.2
    }
    encabezado()
    filas.forEach((fila, n) => {
      const celdas = fila.map((v, i) => doc.splitTextToSize(fmt(v ?? ''), columnas[i].ancho - 3.2))
      const h = alturaDeCelda(Math.max(...celdas.map(c => c.length)))
      if (L.salto(h + 1)) encabezado()
      const arriba = L.y - 3.9
      if (zebra && n % 2 === 0) doc.setFillColor(...ZEBRA).rect(m, arriba, L.util, h, 'F')
      doc.setDrawColor(...LINEA).setLineWidth(0.2)
      doc.setFont('helvetica', 'normal').setFontSize(tamano).setTextColor(...TEXTO)
      columnas.forEach((c, i) => {
        doc.rect(xs[i], arriba, c.ancho, h)
        const x = c.align === 'right' ? xs[i] + c.ancho - 1.6 : c.align === 'center' ? xs[i] + c.ancho / 2 : xs[i] + 1.6
        doc.text(celdas[i], x, L.y, { align: c.align || 'left' })
      })
      L.y += h
    })
    L.y += 3
  }

  L.pie = izquierda => {
    const total = doc.getNumberOfPages()
    for (let p = 1; p <= total; p++) {
      doc.setPage(p)
      doc.setDrawColor(...LINEA).setLineWidth(0.2).line(m, alto - 12, L.der, alto - 12)
      doc.setFont('helvetica', 'normal').setFontSize(8).setTextColor(...GRIS)
      doc.text(fmt(izquierda), m, alto - 7.5)
      doc.text(`Página ${p} de ${total}`, L.der, alto - 7.5, { align: 'right' })
    }
  }

  return L
}
