// ---------------------------------------------------------------------------
// PDF de la orden y su envío (fase 4).
//
// El PDF se arma en el NAVEGADOR del admin con jsPDF: no hay función ni CLI de Supabase para
// esto, y el admin ya tiene todos los datos (la orden que se ve en pantalla). Dos copias:
//   · "cliente": solo el trabajo realizado. Las piezas se ven en la cotización, no aquí.
//   · "interno": lo mismo, más el material usado. Sin costos: `orden_surtido` nunca los tuvo.
// Se guardan en el bucket `ordenes` que ya existe. "Enviar al cliente" es manual (sin la API de
// WhatsApp todavía): cada envío guarda una copia fechada por semana y queda en `envios_orden`,
// listo para cuando ese envío sea automático.
// ---------------------------------------------------------------------------

import { supabase } from './supabase'
import { explicarError } from './errores'
import { hoyLocal, semanaLocal } from './fechas'
import {
  revisionDe, formatoDe, contextoDeRevision, seccionesVisibles, aplica,
  DICTAMENES, CALIFICACIONES, veredictoString, VEREDICTOS, COLUMNAS_STRING,
  AC_SOLAR, BANCO_SOLAR, LECTURAS_GEN, TIPOS_TRANSFERENCIA, TRANSFERENCIA_GEN,
} from './revision'
import { nombreCombustible } from './equipoCampo'
import { crearLienzo, AZUL, CLARO, ZEBRA, LINEA, TEXTO, GRIS } from './pdfEstilo.js'

// "B" en la pantalla es un botón; en el papel tiene que leerse solo.
const CALIFICACION_LARGA = Object.fromEntries(CALIFICACIONES)

// Las fuentes estándar de jsPDF (Helvetica) solo saben escribir WinAnsi. Un carácter fuera
// de ahí no falla: sale escrito en dos bytes y en el PDF se ve basura. Nos pasó con la Ω de
// "Aislamiento (MΩ)". Los que de verdad usamos se traducen; del resto, la puntuación que sí
// está en WinAnsi se deja pasar y lo demás se marca, para que nadie firme un documento con
// un dato ilegible sin enterarse.
const TRADUCE = { 'Ω': 'ohm', 'Δ': 'delta ', '−': '-', '→': '->', '±': '+/-' }
const PUNTUACION_OK = '–—‘’“”„†‡•…‰‹›€™Šš Žž Ÿƒˆ˜Œœ'.replace(/ /g, '')

export function paraPdf(texto) {
  let s = String(texto ?? '')
  for (const [de, a] of Object.entries(TRADUCE)) s = s.split(de).join(a)
  return [...s].map(ch => (
    ch.codePointAt(0) <= 255 || PUNTUACION_OK.includes(ch) ? ch : '?'
  )).join('')
}

const BUCKET = 'ordenes'

const MESES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre']
const NOMBRE_TIPO = {
  preventivo: 'Mantenimiento preventivo', correctivo: 'Servicio correctivo',
  instalacion: 'Instalación', diagnostico: 'Diagnóstico', visita_tecnica: 'Visita técnica'
}

function textoDeError(error) {
  const codigo = String(error?.code || '')
  if (['22023', 'P0002', '42501'].includes(codigo) && error?.message) return error.message
  return explicarError(error).texto
}

// ---- reglas puras (nombres, rutas, formatos) ----

export const nombreArchivo = (orden, tipo) => `OS-${orden.folio}-${tipo}.pdf`
export const rutaExpediente = (orden, tipo) => `expedientes/${orden.cliente_id}/${nombreArchivo(orden, tipo)}`

// Una copia por envío, fechada, para llevar el historial de lo que salió realmente.
export function rutaEnvio(orden, semana, marca = Date.now()) {
  return `enviados/${semana}/OS-${orden.folio}-${marca}.pdf`
}

// "22 de septiembre de 2026". Sin fecha, null.
export function fechaLarga(fecha) {
  if (!fecha) return null
  const [a, m, d] = fecha.split('-').map(Number)
  if (!a || !m || !d) return fecha
  return `${d} de ${MESES[m - 1]} de ${a}`
}

// '2026-10-05' -> '05/10/2026'
export function fechaCorta(fecha) {
  const [a, m, d] = String(fecha || '').split('-')
  return a && m && d ? `${d}/${m}/${a}` : ''
}

// Mete una imagen de ancho `w` y alto `h` dentro de una caja sin deformarla: la escala hasta que
// toque el lado que primero se acabe y la centra. Una foto vertical y una horizontal caben en el
// mismo marco; estirarlas a 4:3 las dejaba chuecas.
export function ajustarEn(w, h, cajaW, cajaH) {
  if (!(w > 0) || !(h > 0)) return { dx: 0, dy: 0, w: cajaW, h: cajaH }
  const escala = Math.min(cajaW / w, cajaH / h)
  const ww = w * escala
  const hh = h * escala
  return { dx: (cajaW - ww) / 2, dy: (cajaH - hh) / 2, w: ww, h: hh }
}

// Encabezados cortos para la tabla de strings: la columna mide ~25 mm.
export const TITULO_CORTO_STRING = {
  mppt: 'MPPT', voc_teorico: 'Voc teór. (V)', voc_medido: 'Voc med. (V)',
  isc: 'Isc/Imp (A)', aisl_pos: 'Aisl. + (MΩ)', aisl_neg: 'Aisl. − (MΩ)'
}
export const COLUMNAS_PARAMETRO = [
  { t: 'Parámetro', ancho: 94 }, { t: 'Valor', ancho: 46, align: 'center' }, { t: 'Unidad', ancho: 46, align: 'center' }
]

// Pares de "Datos del equipo" para la orden. Lo que no hay no se imprime; la serie sí se dice
// aunque falte, porque "pendiente" es información (una placa que no se pudo leer).
export function datosEquipoOrden(eq, orden, ctx) {
  if (!eq || (!eq.marca && !eq.modelo && !eq.tipo && !eq.numero_serie)) return []
  const comb = ctx?.combustible || eq.atributos?.combustible
  return [
    ['Marca', eq.marca || ''],
    ['Modelo', eq.modelo || ''],
    ['Capacidad', eq.capacidad_kw ? `${eq.capacidad_kw} kW` : ''],
    ['No. de serie', eq.numero_serie || 'Pendiente'],
    ['Combustible', (comb && (nombreCombustible(comb) || comb)) || ''],
    ['Ubicación', eq.ubicacion_equipo || ''],
    ['Horómetro', orden?.horas_equipo != null ? `${orden.horas_equipo} h` : '']
  ].filter(([, v]) => v)
}

export function nombreTipoServicio(tipo) {
  return NOMBRE_TIPO[tipo] || tipo || 'Servicio'
}

export function descripcionEquipo(eq) {
  if (!eq) return null
  const partes = [eq.tipo, eq.marca, eq.modelo, eq.capacidad_kw ? `${eq.capacidad_kw} kW` : null]
  return partes.filter(Boolean).join(' ') || null
}

// ---- construir el documento ----

async function blobADataUrl(blob) {
  return new Promise((resolve, reject) => {
    const lector = new FileReader()
    lector.onload = () => resolve(lector.result)
    lector.onerror = () => reject(lector.error)
    lector.readAsDataURL(blob)
  })
}

async function logoDataUrl() {
  try {
    const r = await fetch('/icono-192.png')
    if (!r.ok) return null
    return await blobADataUrl(await r.blob())
  } catch {
    return null
  }
}

// La firma vive en el bucket privado: se descarga con la sesión del admin (sin señal firmada:
// download() ya aplica RLS). Si no hay firma o falla, se sigue sin ella.
// Cuántas fotos entran en el anexo. Cada una pesa unos 150 kB y el PDF tiene que poder
// mandarse por WhatsApp; el resto se queda en el expediente.
const MAX_FOTOS_PDF = 12

async function fotoDataUrl(ruta) {
  if (!ruta) return null
  try {
    const { data, error } = await supabase.storage.from(BUCKET).download(ruta)
    if (error || !data) return null
    // jsPDF NO valida la imagen: si le das cualquier cosa con cara de JPEG la incrusta y
    // el visor muestra un hueco. Se comprueba aquí decodificándola de verdad.
    const mapa = await createImageBitmap(data)
    const medidas = { w: mapa.width, h: mapa.height }
    mapa.close()
    return { url: await blobADataUrl(data), ...medidas }
  } catch {
    return null      // archivo corrupto o formato que el navegador no abre
  }
}

async function firmaDataUrl(ruta) {
  if (!ruta) return null
  try {
    const { data, error } = await supabase.storage.from(BUCKET).download(ruta)
    if (error || !data) return null
    return await blobADataUrl(data)
  } catch {
    return null
  }
}

// Arma el PDF y devuelve un Blob. `tipo`: 'cliente' | 'interno'.
// Mismo estilo que la cotización (encabezado de marca, bandas de sección, tablas con líneas):
// las piezas de estilo viven en pdfEstilo.js.
// jsPDF se carga aparte (arrastra html2canvas y dompurify, que aquí no se usan): solo el admin
// lo necesita, y solo al generar un documento, así que no debe pesar en la carga del técnico.
export async function construirPdfOrden(orden, nombreTecnico, nombreTecnico2, tipo) {
  const { jsPDF } = await import('jspdf')
  const doc = new jsPDF({ unit: 'mm', format: 'a4' })
  const L = crearLienzo(doc, paraPdf)

  const cl = orden.clientes || {}
  const eq = orden.equipos || {}
  const ci = orden.citas || {}
  const tecnicos = [nombreTecnico, nombreTecnico2].filter(Boolean).join(' y ')
  const rev = revisionDe(orden)
  const formato = rev ? formatoDe(rev.tipo) : null
  const ctxRev = rev ? contextoDeRevision(rev.tipo, rev.datos, eq) : null

  const nombreServicio = nombreTipoServicio(orden.tipo_servicio).toUpperCase()
  L.encabezado({
    logo: await logoDataUrl(),
    titulo: `ORDEN DE SERVICIO — ${nombreServicio}${tipo === 'interno' ? ' · COPIA INTERNA' : ''}`
  })

  // ---- datos del servicio ----
  const fecha = fechaCorta(ci.fecha || orden.fecha)
  const dir = [cl.direccion, cl.colonia, cl.municipio].filter(Boolean).join(', ')
  L.rejilla([
    ['Folio', `OS-${orden.folio}`],
    ['Fecha', fecha ? `${fecha}${ci.hora ? ` · ${String(ci.hora).slice(0, 5)} h` : ''}` : 'sin fecha'],
    ['Cliente', cl.nombre || ''],
    ['Servicio', nombreTipoServicio(orden.tipo_servicio)],
    ['Teléfono', cl.telefono || ''],
    ['Atendió', tecnicos],
    ['Dirección', dir]
  ].filter(([, v]) => v))

  // ---- datos del equipo ----
  const datosEq = datosEquipoOrden(eq, orden, ctxRev)
  if (datosEq.length > 0) { L.barra('DATOS DEL EQUIPO'); L.rejilla(datosEq) }

  // ---- dictamen: lo primero que el cliente quiere saber ----
  if (rev) {
    const dic = DICTAMENES.find(([k]) => k === rev.datos.dictamen)
    if (dic) {
      L.barra('DICTAMEN')
      const descripcion = L.doc.splitTextToSize(paraPdf(dic[2]), L.util - 8)
      const h = 11 + descripcion.length * 4.6
      L.salto(h + 4)
      doc.setFillColor(...CLARO).rect(L.m, L.y - 4, L.util, h, 'F')
      doc.setDrawColor(...AZUL).setLineWidth(0.5).rect(L.m, L.y - 4, L.util, h)
      doc.setFont('helvetica', 'bold').setFontSize(13).setTextColor(...AZUL)
      doc.text(paraPdf(dic[1].toUpperCase()), L.m + 4, L.y + 2)
      doc.setFont('helvetica', 'normal').setFontSize(9.5).setTextColor(...TEXTO)
      doc.text(descripcion, L.m + 4, L.y + 8)
      L.y += h + 3
      if (rev.datos.motivo_dictamen?.trim()) L.caja(rev.datos.motivo_dictamen.trim())
    }

    const ll = rev.datos.llegada || {}
    const llegada = (rev.tipo === 'solar'
      ? [['Clima', ll.clima], ['Irradiancia', ll.irradiancia && `${ll.irradiancia} W/m²`],
         ['Temperatura ambiente', ll.temp && `${ll.temp} °C`]]
      : [['Tipo de servicio', ll.tipo_servicio],
         ['Combustible', ctxRev.combustible && (nombreCombustible(ctxRev.combustible) || ctxRev.combustible)],
         ['Fases', ctxRev.trifasico ? 'Trifásico' : 'Monofásico']]
    ).filter(([, v]) => v)
    if (llegada.length > 0) { L.barra('CONDICIONES DE LLEGADA'); L.rejilla(llegada) }
  }

  L.barra('TRABAJO REALIZADO')
  L.caja(orden.trabajos_realizados?.trim() || 'Sin notas capturadas.')

  if (rev) {
    // ---- los puntos de revisión, sección por sección, en tabla con líneas ----
    for (const s of seccionesVisibles(formato, ctxRev)) {
      const filas = []
      for (const p of s.puntos) {
        const r = rev.datos.puntos?.[p.clave]
        if (!r?.v) continue
        const extras = (p.campos || [])
          .map(([k, etiqueta]) => (r[k] ? `${etiqueta}: ${r[k]}` : null)).filter(Boolean).join(' · ')
        const detalle = [extras, r.obs?.trim()].filter(Boolean).join('\n')
        filas.push([p.clave, p.titulo, CALIFICACION_LARGA[r.v] || r.v, detalle])
      }
      if (filas.length === 0) continue
      L.barra(`${s.clave}. ${s.titulo.toUpperCase()}`)
      L.tabla([
        { t: 'No.', ancho: 13, align: 'center' },
        { t: 'Punto de revisión', ancho: 74 },
        { t: 'Resultado', ancho: 23, align: 'center' },
        { t: 'Datos y hallazgos', ancho: 76 }
      ], filas)
    }

    // ---- mediciones ----
    const med = rev.datos.mediciones || {}
    if (rev.tipo === 'solar') {
      const strings = (med.strings || []).filter(s => Object.values(s).some(v => v !== ''))
      if (strings.length > 0) {
        L.barra('MEDICIONES POR STRING')
        const ancho = (L.util - 14 - 19) / COLUMNAS_STRING.length
        L.tabla([
          { t: 'String', ancho: 14, align: 'center' },
          ...COLUMNAS_STRING.map(([k]) => ({ t: TITULO_CORTO_STRING[k] || k, ancho, align: 'center' })),
          { t: 'Veredicto', ancho: 19, align: 'center' }
        ], strings.map((s, i) => {
          const v = veredictoString(s)
          return [String(i + 1), ...COLUMNAS_STRING.map(([k]) => s[k] ?? ''), v ? VEREDICTOS[v] : '—']
        }), { tamano: 8.2 })
      }
      const ac = AC_SOLAR.filter(c => aplica(c, ctxRev) && med.ac?.[c.clave])
      if (ac.length > 0) {
        L.barra('PARÁMETROS ELÉCTRICOS')
        L.tabla(COLUMNAS_PARAMETRO, ac.map(c => [c.titulo, med.ac[c.clave], c.unidad || '']))
      }
      const banco = BANCO_SOLAR.filter(c => aplica(c, ctxRev) && med.banco?.[c.clave])
      if (banco.length > 0) {
        L.barra('BANCO Y TIERRA')
        L.tabla(COLUMNAS_PARAMETRO, banco.map(c => [c.titulo, med.banco[c.clave], c.unidad || '']))
      }
    } else {
      const lecturas = LECTURAS_GEN.filter(c => aplica(c, ctxRev) &&
        (med.lecturas?.[c.clave]?.vacio || med.lecturas?.[c.clave]?.carga))
      if (lecturas.length > 0) {
        L.barra('PRUEBA DE FUNCIONAMIENTO')
        if (med.carga_pct) L.rejilla([['Carga de prueba', `${med.carga_pct} % de la capacidad`]])
        L.tabla([
          { t: 'Lectura', ancho: 94 },
          { t: 'En vacío', ancho: 46, align: 'center' },
          { t: 'Con carga', ancho: 46, align: 'center' }
        ], lecturas.map(c => {
          const l = med.lecturas[c.clave]
          return [`${c.titulo}${c.unidad ? ` (${c.unidad})` : ''}`, l.vacio || '—', l.carga || '—']
        }))
      }
      const t = med.transferencia || {}
      if (t.tipo || t.resultado) {
        L.barra('PRUEBA DE TRANSFERENCIA')
        const filas = []
        const como = TIPOS_TRANSFERENCIA.find(([k]) => k === t.tipo)?.[1]
        if (como) filas.push(['Cómo se probó', como])
        for (const [k, etiqueta] of TRANSFERENCIA_GEN) if (t[k]) filas.push([etiqueta, t[k]])
        if (t.resultado) filas.push(['Resultado', t.resultado === 'aprobada' ? 'Aprobada' : 'No aprobada'])
        L.tabla([{ t: 'Concepto', ancho: 94 }, { t: 'Resultado', ancho: 92 }], filas)
      }
    }
    if (rev.datos.reporte_termico) L.caja('Se entrega reporte térmico por separado.')
  }

  if (orden.observaciones?.trim()) { L.barra('OBSERVACIONES'); L.caja(orden.observaciones.trim()) }
  if (orden.recomendaciones?.trim()) { L.barra('RECOMENDACIONES'); L.caja(orden.recomendaciones.trim()) }
  if (orden.requiere_seguimiento) {
    L.barra('SEGUIMIENTO')
    L.caja(`Requiere seguimiento${orden.fecha_seguimiento ? ` para el ${fechaLarga(orden.fecha_seguimiento)}` : ''}.`)
  }

  // Solo la copia interna lleva el material: sin costos, esa tabla nunca los tuvo.
  if (tipo === 'interno') {
    const usado = (orden.orden_surtido || []).filter(l => Number(l.cantidad_usada) > 0)
    if (usado.length > 0) {
      L.barra('MATERIAL USADO (DEL ALMACÉN)')
      L.tabla([
        { t: 'Cant.', ancho: 20, align: 'center' }, { t: 'SKU', ancho: 44 },
        { t: 'Descripción', ancho: 96 }, { t: 'Unidad', ancho: 26, align: 'center' }
      ], usado.map(l => [String(l.cantidad_usada), l.sku || '', l.nombre || '', l.unidad || '']))
    }
    const adicionales = (orden.refacciones || []).filter(r => r?.descripcion)
    if (adicionales.length > 0) {
      L.barra('MATERIAL ADICIONAL (NO ENTREGADO POR ALMACÉN)')
      L.tabla([{ t: 'Cant.', ancho: 20, align: 'center' }, { t: 'Descripción', ancho: 166 }],
        adicionales.map(r => [String(r.cantidad || 1), r.descripcion]))
    }
  }

  // ---- evidencia fotográfica ----
  // El papel solo podía apuntar "No. de fotos ___" y una carpeta; aquí la foto va dentro del
  // documento, en su marco, y dice de qué punto es. Dos por fila, mismo tamaño de espacio para
  // todas (4:3): la foto se ajusta dentro sin deformarse, y una que no se pueda abrir deja su
  // marco con el aviso en vez de tumbar la orden. Se limita el número para que el PDF siga
  // pesando lo que se puede mandar por WhatsApp.
  if (rev) {
    const conFoto = []
    for (const s of seccionesVisibles(formato, ctxRev)) {
      for (const p of s.puntos) {
        for (const f of rev.datos.puntos?.[p.clave]?.fotos || []) {
          if (f.ruta) conFoto.push({ punto: `${p.clave} ${p.titulo}`, ruta: f.ruta })
        }
      }
    }
    if (conFoto.length > 0) {
      doc.addPage(); L.y = 16
      L.barra('EVIDENCIA FOTOGRÁFICA')
      const muestra = conFoto.slice(0, MAX_FOTOS_PDF)
      if (conFoto.length > muestra.length) {
        L.caja(`Se anexan ${muestra.length} de ${conFoto.length} fotografías; el resto queda en el expediente.`)
      }
      const hueco = 6
      const anchoMarco = (L.util - hueco) / 2
      const altoFoto = anchoMarco * 0.75
      const altoMarco = altoFoto + 11
      let columna = 0
      for (let n = 0; n < muestra.length; n++) {
        const f = muestra[n]
        if (columna === 0) L.salto(altoMarco + 4)
        const x = L.m + columna * (anchoMarco + hueco)
        const arriba = L.y - 4
        doc.setDrawColor(...LINEA).setLineWidth(0.3).rect(x, arriba, anchoMarco, altoMarco)
        doc.setFillColor(...ZEBRA).rect(x, arriba, anchoMarco, altoFoto, 'F')
        const imagen = await fotoDataUrl(f.ruta)
        let pintada = false
        if (imagen) {
          const caja = ajustarEn(imagen.w, imagen.h, anchoMarco - 2, altoFoto - 2)
          try {
            doc.addImage(imagen.url, 'JPEG', x + 1 + caja.dx, arriba + 1 + caja.dy, caja.w, caja.h)
            pintada = true
          } catch { /* se deja el aviso de abajo */ }
        }
        if (!pintada) {
          doc.setFont('helvetica', 'italic').setFontSize(9).setTextColor(...GRIS)
          doc.text('Foto no disponible', x + anchoMarco / 2, arriba + altoFoto / 2, { align: 'center' })
        }
        doc.setDrawColor(...LINEA).line(x, arriba + altoFoto, x + anchoMarco, arriba + altoFoto)
        doc.setFont('helvetica', 'normal').setFontSize(8).setTextColor(...TEXTO)
        const leyenda = doc.splitTextToSize(paraPdf(`Foto ${n + 1} — ${f.punto}`), anchoMarco - 4).slice(0, 2)
        doc.text(leyenda, x + 2, arriba + altoFoto + 4)
        columna = columna === 0 ? 1 : 0
        if (columna === 0) L.y += altoMarco + 3
      }
      if (columna === 1) L.y += altoMarco + 3
    }
  }

  // ---- firmas ----
  L.barra('FIRMA DE RECIBIDO')
  const firma = await firmaDataUrl(orden.firma_cliente)
  const altoCaja = 36
  const anchoCaja = (L.util - 6) / 2
  L.salto(altoCaja + 6)
  const arribaCaja = L.y - 4
  for (let k = 0; k < 2; k++) {
    const x = L.m + k * (anchoCaja + 6)
    doc.setDrawColor(...LINEA).setLineWidth(0.3).rect(x, arribaCaja, anchoCaja, altoCaja)
    doc.setDrawColor(...GRIS).setLineWidth(0.2).line(x + 8, arribaCaja + altoCaja - 9, x + anchoCaja - 8, arribaCaja + altoCaja - 9)
    doc.setFont('helvetica', 'normal').setFontSize(8.5).setTextColor(...GRIS)
    doc.text(k === 0 ? 'Firma del cliente (recibe de conformidad)' : 'Técnico responsable',
      x + anchoCaja / 2, arribaCaja + altoCaja - 4.5, { align: 'center' })
  }
  if (firma) {
    try { doc.addImage(firma, 'PNG', L.m + (anchoCaja - 56) / 2, arribaCaja + 2, 56, 23) } catch { /* sin firma legible */ }
  } else {
    doc.setFont('helvetica', 'italic').setFontSize(9).setTextColor(...GRIS)
    doc.text('El cliente no firmó esta orden.', L.m + anchoCaja / 2, arribaCaja + 15, { align: 'center' })
  }
  if (nombreTecnico) {
    doc.setFont('helvetica', 'normal').setFontSize(10).setTextColor(...TEXTO)
    doc.text(paraPdf(nombreTecnico), L.m + anchoCaja + 6 + anchoCaja / 2, arribaCaja + altoCaja - 12, { align: 'center' })
  }
  L.y += altoCaja + 2

  L.pie(`PowerMx · OS-${orden.folio} · generado el ${fechaLarga(hoyLocal())} · ${tipo === 'interno' ? 'copia interna' : 'copia del cliente'}`)
  return doc.output('blob')
}

// ---- almacenar y consultar ----

export async function guardarPdfExpediente(orden, tipo, blob) {
  try {
    const ruta = rutaExpediente(orden, tipo)
    const { error: e1 } = await supabase.storage.from(BUCKET).upload(ruta, blob, { contentType: 'application/pdf', upsert: true })
    if (e1) return { ok: false, texto: textoDeError(e1) }
    const { error: e2 } = await supabase.from('ordenes_pdf')
      .upsert([{ orden_id: orden.id, tipo, ruta, generado_por: null }], { onConflict: 'orden_id,tipo' })
    if (e2) return { ok: false, texto: textoDeError(e2) }
    return { ok: true, ruta }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

export async function cargarPdfDeOrden(ordenId) {
  try {
    const { data, error } = await supabase.from('ordenes_pdf')
      .select('id, tipo, ruta, generado_en').eq('orden_id', ordenId)
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true, pdfs: data || [] }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

export async function cargarEnviosDeOrden(ordenId) {
  try {
    const { data, error } = await supabase.from('envios_orden')
      .select('id, folio, ruta, semana, destinatarios, enviado_en').eq('orden_id', ordenId)
      .order('enviado_en', { ascending: false })
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true, envios: data || [] }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

// Contactos con `recibe_ordenes`, del equipo si lo hay, si no de toda la empresa del cliente.
export async function cargarDestinatariosOrden(orden) {
  try {
    if (orden.equipo_id) {
      const { data, error } = await supabase.from('contactos_por_equipo')
        .select('contacto_id, nombre, telefono, rol').eq('equipo_id', orden.equipo_id).eq('recibe_ordenes', true)
      if (error) return { ok: false, texto: textoDeError(error) }
      return { ok: true, contactos: data || [] }
    }
    const { data, error } = await supabase.from('contactos')
      .select('id, nombre, telefono').eq('cliente_id', orden.cliente_id)
      .eq('de_toda_la_empresa', true).eq('recibe_ordenes', true).eq('activo', true)
    if (error) return { ok: false, texto: textoDeError(error) }
    return { ok: true, contactos: (data || []).map(c => ({ contacto_id: c.id, nombre: c.nombre, telefono: c.telefono })) }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

// Sube la copia fechada (carpeta de la semana) y registra el envío.
export async function registrarEnvio(orden, blob, destinatarios) {
  try {
    const semana = semanaLocal(hoyLocal())
    const ruta = rutaEnvio(orden, semana)
    const { error: e1 } = await supabase.storage.from(BUCKET).upload(ruta, blob, { contentType: 'application/pdf', upsert: true })
    if (e1) return { ok: false, texto: textoDeError(e1) }
    const { error: e2 } = await supabase.from('envios_orden').insert([{
      orden_id: orden.id, ruta, semana,
      destinatarios: destinatarios.map(d => ({ contacto_id: d.contacto_id || null, nombre: d.nombre, telefono: d.telefono }))
    }])
    if (e2) return { ok: false, texto: textoDeError(e2) }
    // Ya se envió: si estaba marcada "enviar al cerrar", se apaga sola. Si esto falla no se
    // avisa (el envío ya quedó registrado, que es lo que importa); a lo más la marca sigue prendida.
    if (orden.enviar_al_cerrar) {
      await supabase.from('ordenes_servicio').update({ enviar_al_cerrar: false }).eq('id', orden.id).then(null, () => {})
    }
    return { ok: true, ruta, semana }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}

// Enlace temporal para ver o descargar un PDF ya guardado.
export async function urlDePdf(ruta) {
  try {
    const { data, error } = await supabase.storage.from(BUCKET).createSignedUrl(ruta, 3600)
    if (error || !data) return { ok: false, texto: textoDeError(error) }
    return { ok: true, url: data.signedUrl }
  } catch (e) {
    return { ok: false, texto: textoDeError(e) }
  }
}
