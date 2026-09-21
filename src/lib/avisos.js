// ---------------------------------------------------------------------------
// Avisos de cita: reglas puras (sin red) de la cola de mensajes de la Agenda.
// El texto de cada mensaje lo arma la base (16_avisos_de_cita.sql: `texto_aviso`);
// aquí solo se agrupa, se nombra y se arma el enlace de WhatsApp.
// ---------------------------------------------------------------------------

import { normalizarTelefono } from './contactos'

export const TIPOS = {
  confirmacion: 'Confirmación',
  reprogramacion: 'Cambio de horario',
  cancelacion: 'Cancelación'
}
export const etiquetaTipo = tipo => TIPOS[tipo] ?? tipo

export const PARA = { cliente: 'Cliente', tecnico: 'Técnico' }
export const etiquetaPara = quien => PARA[quien] ?? quien

// Enlace que abre WhatsApp con el mensaje ya escrito. wa.me pide el código de país: 52 más los
// 10 dígitos. Sin un número válido no hay enlace (null).
export function enlaceWhatsApp(telefono, texto) {
  const n = normalizarTelefono(telefono)
  if (!n) return null
  return `https://wa.me/52${n}?text=${encodeURIComponent(texto ?? '')}`
}

// Agrupa los avisos por cita, respetando el orden en que llegan (la base ya los manda por fecha).
export function agruparPorCita(avisos) {
  const grupos = []
  const porCita = new Map()
  for (const a of avisos || []) {
    let g = porCita.get(a.cita_id)
    if (!g) {
      g = { cita_id: a.cita_id, cliente: a.cliente, fecha: a.fecha, hora: a.hora, avisos: [] }
      porCita.set(a.cita_id, g)
      grupos.push(g)
    }
    g.avisos.push(a)
  }
  return grupos
}

// "2026-09-22 09:00" (sin segundos); sin fecha, "sin fecha".
export function cuandoCorto(fecha, hora) {
  if (!fecha) return 'sin fecha'
  return hora ? `${fecha} ${String(hora).slice(0, 5)}` : fecha
}
