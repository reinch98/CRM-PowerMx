// ---------------------------------------------------------------------------
// Reglas puras del envío por la API de WhatsApp (Cloud API de Meta).
//
// JavaScript plano a propósito: lo importa la Edge Function (Deno) y también las pruebas
// de Node (`pruebas/enviarWhatsapp.prueba.js`) y la usan `enviar-whatsapp` y el webhook `whatsapp`. Así lo que se prueba es exactamente lo que
// sale a Meta.
// ---------------------------------------------------------------------------

// Lo que Meta recibe para UN mensaje de la cola (lo que devuelve `tomar_salida`, SQL 56).
// `enlaceDocumento`: URL firmada del PDF cuando la plantilla lleva encabezado de documento.
export function cuerpoMensaje(m, enlaceDocumento = null) {
  if (m.tipo === 'texto') {
    return {
      messaging_product: 'whatsapp',
      to: m.to,
      type: 'text',
      text: { body: m.texto, preview_url: false },
    }
  }
  const componentes = []
  if (m.documento_ruta) {
    if (!enlaceDocumento) throw new Error('La plantilla lleva documento y no hay enlace al PDF.')
    componentes.push({
      type: 'header',
      parameters: [{ type: 'document', document: { link: enlaceDocumento, filename: m.documento_nombre || 'documento.pdf' } }],
    })
  }
  const parametros = (m.parametros || []).map(p => ({
    type: 'text',
    // Las plantillas de PowerMx usan variables CON NOMBRE ({{nombre}}), no {{1}}: Meta
    // empareja por `parameter_name`, no por el orden.
    parameter_name: p.nombre,
    text: limpiarParametro(p.valor),
  }))
  if (parametros.length) componentes.push({ type: 'body', parameters: parametros })
  return {
    messaging_product: 'whatsapp',
    to: m.to,
    type: 'template',
    template: {
      name: m.plantilla,
      language: { code: m.idioma || 'es_MX' },
      ...(componentes.length ? { components: componentes } : {}),
    },
  }
}

// Meta rechaza un parámetro con saltos de línea, tabuladores o más de 4 espacios seguidos.
export function limpiarParametro(v) {
  const t = String(v ?? '').replace(/[\r\n\t]+/g, ' ').replace(/ {2,}/g, ' ').trim()
  return t || '—'
}

// Códigos de error de Meta que se arreglan solos esperando (vuelven a la cola con espera);
// todo lo demás es permanente y lo revisa una persona.
const TEMPORALES = new Set([
  1, 2,        // error interno / servicio no disponible
  4, 80007,    // límite de llamadas de la app o de la cuenta
  130429,      // límite de mensajes por segundo
  131016,      // servicio sobrecargado
  133004,      // servidor no disponible por un momento
])

// De la respuesta de Meta al resultado que guarda `marcar_salida`.
export function leerRespuesta(status, cuerpo) {
  const id = cuerpo?.messages?.[0]?.id
  if (status >= 200 && status < 300 && id) return { ok: true, wamid: id }
  const e = cuerpo?.error || {}
  const codigo = e.code ?? null
  const temporal = status === 429 || status >= 500 || TEMPORALES.has(Number(codigo))
  const detalle = e.error_data?.details || e.message || `HTTP ${status}`
  return { ok: false, temporal, error: `${codigo ?? status}: ${traducir(codigo, detalle)}` }
}

// Los que más van a salir, en palabras para la oficina.
function traducir(codigo, detalle) {
  switch (Number(codigo)) {
    case 131047: return 'pasaron más de 24 horas desde el último mensaje del cliente; hace falta plantilla'
    case 131026: return 'no se pudo entregar (el número no tiene WhatsApp o bloqueó al negocio)'
    case 132000: return 'las variables no coinciden con la plantilla aprobada: revisa sus nombres en Por enviar → Plantillas'
    case 132001: return 'la plantilla no existe o no está aprobada en ese idioma'
    case 132015: case 132016: return 'Meta pausó o desactivó la plantilla por mala calidad'
    case 131049: return 'Meta no lo entregó para cuidar la experiencia del cliente (demasiado marketing); no reintentar pronto'
    case 131050: return 'el cliente dejó de aceptar marketing de este número'
    case 190: return 'el token de Meta venció o no es válido: renueva WHATSAPP_TOKEN'
    default: return detalle
  }
}

// ¿Es un mensaje de baja? Texto "BAJA"/"STOP" o el botón de baja de marketing de Meta.
const BAJAS = new Set(['baja', 'stop', 'alto', 'detener promociones', 'stop promotions', 'darme de baja', 'unsubscribe'])
export function esBaja(texto) {
  const t = String(texto ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '')
    .toLowerCase().replace(/[.!¡]/g, '').trim()
  return BAJAS.has(t)
}

// Del acuse de Meta (`statuses`) al error que se guarda, si lo hay.
export function errorDeAcuse(st) {
  const e = st?.errors?.[0]
  if (!e) return null
  return `${e.code ?? ''}: ${traducir(e.code, e.error_data?.details || e.title || e.message || '')}`.trim()
}
