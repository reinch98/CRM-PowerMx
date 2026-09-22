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

const BUCKET = 'ordenes'
const NOCHE = [12, 21, 32]     // #0c1520
const CLARO = [232, 237, 244]  // #e8edf4
const TEXTO = [30, 41, 59]

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
// jsPDF se carga aparte (arrastra html2canvas y dompurify, que aquí no se usan): solo el admin
// lo necesita, y solo al generar un documento, así que no debe pesar en la carga del técnico.
export async function construirPdfOrden(orden, nombreTecnico, nombreTecnico2, tipo) {
  const { jsPDF } = await import('jspdf')
  const doc = new jsPDF({ unit: 'mm', format: 'a4' })
  const ancho = doc.internal.pageSize.getWidth()
  const alto = doc.internal.pageSize.getHeight()
  const izq = 16
  const der = ancho - 16
  let y = 32

  function saltoSiHaceFalta(alturaNecesaria) {
    if (y + alturaNecesaria > alto - 20) { doc.addPage(); y = 20 }
  }
  function titulo(texto) {
    saltoSiHaceFalta(12)
    doc.setFont('helvetica', 'bold').setFontSize(12).setTextColor(...NOCHE)
    doc.text(texto, izq, y)
    y += 6
    doc.setFont('helvetica', 'normal').setFontSize(10.5).setTextColor(...TEXTO)
  }
  function parrafo(texto) {
    const lineas = doc.splitTextToSize(texto, der - izq)
    saltoSiHaceFalta(lineas.length * 5 + 2)
    doc.text(lineas, izq, y)
    y += lineas.length * 5 + 3
  }
  function linea(texto) {
    saltoSiHaceFalta(6)
    doc.text(texto, izq, y)
    y += 6
  }

  // Encabezado de marca.
  doc.setFillColor(...NOCHE)
  doc.rect(0, 0, ancho, 24, 'F')
  const logo = await logoDataUrl()
  if (logo) doc.addImage(logo, 'PNG', izq, 5, 14, 14)
  doc.setFont('helvetica', 'bold').setFontSize(16).setTextColor(...CLARO)
  doc.text('PowerMx', logo ? izq + 18 : izq, 15)
  doc.setFont('helvetica', 'normal').setFontSize(10)
  doc.text(`Orden de servicio OS-${orden.folio}`, der, 11, { align: 'right' })
  doc.text(tipo === 'interno' ? 'Copia interna' : 'Orden de servicio', der, 17, { align: 'right' })
  doc.setTextColor(...TEXTO)

  // Datos del servicio.
  const cl = orden.clientes || {}
  const eq = orden.equipos || {}
  const ci = orden.citas || {}
  linea(`Cliente: ${cl.nombre || '—'}`)
  const equipo = descripcionEquipo(eq)
  if (equipo) linea(`Equipo: ${equipo}${eq.numero_serie ? ` (serie ${eq.numero_serie})` : ''}`)
  linea(`Servicio: ${nombreTipoServicio(orden.tipo_servicio)}`)
  const fecha = fechaLarga(ci.fecha || orden.fecha)
  linea(`Fecha: ${fecha || 'sin fecha'}${ci.hora ? ` · ${String(ci.hora).slice(0, 5)} h` : ''}`)
  const tecnicos = [nombreTecnico, nombreTecnico2].filter(Boolean).join(' y ')
  if (tecnicos) linea(`Atendió: ${tecnicos}`)
  y += 3

  titulo('Trabajo realizado')
  parrafo(orden.trabajos_realizados?.trim() || 'Sin notas capturadas.')

  if (orden.observaciones?.trim()) { titulo('Observaciones'); parrafo(orden.observaciones.trim()) }
  if (orden.recomendaciones?.trim()) { titulo('Recomendaciones'); parrafo(orden.recomendaciones.trim()) }
  if (orden.requiere_seguimiento) {
    titulo('Seguimiento')
    parrafo(`Requiere seguimiento${orden.fecha_seguimiento ? ` para el ${fechaLarga(orden.fecha_seguimiento)}` : ''}.`)
  }
  if (orden.horas_equipo != null) linea(`Horómetro del equipo: ${orden.horas_equipo}`)

  // Solo la copia interna lleva el material: sin costos, esa tabla nunca los tuvo.
  if (tipo === 'interno') {
    const usado = (orden.orden_surtido || []).filter(l => Number(l.cantidad_usada) > 0)
    if (usado.length > 0) {
      titulo('Material usado (del almacén)')
      for (const l of usado) linea(`${l.cantidad_usada} × ${l.sku} — ${l.nombre}${l.unidad ? ` ${l.unidad}` : ''}`)
      y += 2
    }
    const adicionales = (orden.refacciones || []).filter(r => r?.descripcion)
    if (adicionales.length > 0) {
      titulo('Material adicional (no entregado por almacén)')
      for (const r of adicionales) linea(`${r.cantidad || 1} × ${r.descripcion}`)
      y += 2
    }
  }

  titulo('Firma de recibido')
  const firma = await firmaDataUrl(orden.firma_cliente)
  if (firma) {
    saltoSiHaceFalta(30)
    doc.addImage(firma, 'PNG', izq, y, 70, 28)
    y += 32
  } else {
    parrafo('El cliente no firmó esta orden.')
  }

  // Pie de página, en todas las hojas que haya.
  const total = doc.internal.getNumberOfPages()
  for (let p = 1; p <= total; p++) {
    doc.setPage(p)
    doc.setFont('helvetica', 'normal').setFontSize(8).setTextColor(...TEXTO)
    doc.text(
      `PowerMx · OS-${orden.folio} · generado el ${fechaLarga(hoyLocal())} · ${tipo === 'interno' ? 'copia interna' : 'copia del cliente'} · página ${p} de ${total}`,
      izq, alto - 10
    )
  }

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
