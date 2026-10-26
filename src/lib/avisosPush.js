// ---------------------------------------------------------------------------
// Avisos en el celular (SQL 90): "avísame aquí cuando llegue un WhatsApp".
//
// Cada navegador que lo pide queda en `push_suscripciones`; el webhook de WhatsApp le manda un
// aviso cifrado por cada mensaje nuevo y el service worker (`sw/plantilla.js`) lo muestra. Solo
// funciona con la app publicada (el service worker no corre en desarrollo) y, en iPhone, solo si
// el CRM se abrió desde el ícono de la pantalla de inicio: Safari no deja avisar a una pestaña.
// ---------------------------------------------------------------------------

import { supabase } from './supabase'
import { explicarError } from './errores'

// ---- reglas puras ----

const esIphone = ua => /iPhone|iPad|iPod/i.test(ua || '')

// ¿Este navegador puede recibir avisos? Si no, por qué, en palabras.
export function soporteAvisos(entorno) {
  const { ua, sw, push, permiso, instalada } = entorno
  if (esIphone(ua) && !instalada) {
    return { puede: false, motivo: 'En iPhone: toca Compartir → "Agregar a pantalla de inicio" y abre el CRM desde ese ícono. Ahí sí se pueden activar.' }
  }
  if (!sw || !push) return { puede: false, motivo: 'Este navegador no puede recibir avisos. Usa Chrome en Android o en la computadora.' }
  if (permiso === 'denied') return { puede: false, motivo: 'Los avisos están bloqueados para este sitio. Actívalos en los ajustes del navegador (permisos → notificaciones) y vuelve aquí.' }
  return { puede: true }
}

// "Chrome en Android", para reconocer cada dispositivo en la lista.
export function nombreDispositivo(ua = '') {
  const so = /Android/i.test(ua) ? 'Android' : esIphone(ua) ? 'iPhone' : /Windows/i.test(ua) ? 'Windows'
    : /Mac OS X/i.test(ua) ? 'Mac' : /Linux/i.test(ua) ? 'Linux' : 'otro equipo'
  const nav = /Edg\//.test(ua) ? 'Edge' : /SamsungBrowser/.test(ua) ? 'Samsung Internet'
    : /Firefox|FxiOS/.test(ua) ? 'Firefox' : /Chrome|CriOS/.test(ua) ? 'Chrome' : /Safari/.test(ua) ? 'Safari' : 'Navegador'
  return `${nav} en ${so}`
}

export function claveABytes(b64url) {
  const b = String(b64url).replace(/-/g, '+').replace(/_/g, '/')
  const bin = atob(b + '='.repeat((4 - (b.length % 4)) % 4))
  return Uint8Array.from(bin, c => c.charCodeAt(0))
}

// ---- lo que toca el navegador y la base ----

export function entornoActual() {
  return {
    ua: navigator.userAgent,
    sw: 'serviceWorker' in navigator,
    push: typeof window !== 'undefined' && 'PushManager' in window,
    permiso: typeof Notification !== 'undefined' ? Notification.permission : 'default',
    instalada: window.matchMedia?.('(display-mode: standalone)')?.matches || navigator.standalone === true,
  }
}

async function registro() {
  const reg = await navigator.serviceWorker.getRegistration()
  if (!reg) throw new Error('La app todavía no termina de instalarse en este navegador. Recarga la página y vuelve a intentar.')
  return reg
}

async function invocar(cuerpo) {
  const { data, error } = await supabase.functions.invoke('avisos-push', { body: cuerpo })
  if (error) {
    let detalle = ''
    try { detalle = (await error.context?.json())?.error || '' } catch { /* sin cuerpo */ }
    throw new Error(detalle || 'No se pudo hablar con el servicio de avisos.')
  }
  if (data?.error) throw new Error(data.error)
  return data
}

const conTexto = async fn => {
  try { return { ok: true, ...(await fn()) } } catch (e) { return { ok: false, texto: e?.message || explicarError(e).texto } }
}

// ¿Este dispositivo ya avisa?
export async function estadoAvisos() {
  try {
    const reg = await navigator.serviceWorker?.getRegistration()
    const sus = await reg?.pushManager?.getSubscription()
    return { activo: !!sus }
  } catch {
    return { activo: false }
  }
}

export const activarAvisos = () => conTexto(async () => {
  const permiso = await Notification.requestPermission()
  if (permiso !== 'granted') throw new Error('No diste permiso para los avisos. Si te equivocaste, actívalo en los ajustes del navegador.')
  const { publica } = await invocar({ accion: 'clave' })
  const reg = await registro()
  const sus = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: claveABytes(publica) })
  const j = sus.toJSON()
  const { error } = await supabase.from('push_suscripciones').upsert({
    endpoint: j.endpoint, p256dh: j.keys.p256dh, auth: j.keys.auth,
    dispositivo: nombreDispositivo(navigator.userAgent), activo: true,
  }, { onConflict: 'endpoint' })
  if (error) throw error
  return {}
})

export const quitarAvisos = () => conTexto(async () => {
  const reg = await registro()
  const sus = await reg.pushManager.getSubscription()
  if (sus) {
    await supabase.from('push_suscripciones').delete().eq('endpoint', sus.endpoint)
    await sus.unsubscribe()
  }
  return {}
})

export const probarAvisos = () => conTexto(() => invocar({ accion: 'probar' }))
