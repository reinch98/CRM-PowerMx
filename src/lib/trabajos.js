// ---------------------------------------------------------------------------
// "Mis trabajos" sin señal: lo que el técnico ve, lo que escribe y lo que se sube.
//
//   cache_mis_trabajos   las órdenes que le tocan, tal como se vieron la última vez
//                        (la pantalla abre con esto al instante y se refresca por detrás)
//   partes_locales       SU parte de cada orden (notas y fotos), la fuente de verdad
//                        mientras no haya subido; las fotos en sí viven en IndexedDB
//   cola_trabajos        lo que falta subir: partes y cierres (reglas en cola.js)
//
// Cada técnico escribe solo SU parte (una fila por técnico y orden en `orden_partes`),
// así que dos personas nunca editan lo mismo y no hay conflictos que resolver. Cerrar la
// orden lo hace solo el responsable, con la función `cerrar_orden` de la base.
// ---------------------------------------------------------------------------

import { supabase } from './supabase'
import { leerLocal, escribirLocal, usuarioLocal } from './local'
import { guardarFoto, fotosDeOrden, borrarFoto, borrarFotosDeOrden } from './idb'
import { dataUrlABlob } from './imagen'
import { explicarError } from './errores'
import { hoyLocal, sumarDias } from './fechas'
import { claveDe, encolarEn, ordenarCola, sacarSiSigue, marcarFallo } from './cola'

const CACHE = 'cache_mis_trabajos'
const NOMBRES = 'cache_nombres_tecnicos'
const PARTES = 'partes_locales'
export const COLA = 'cola_trabajos'
const BUCKET = 'ordenes'

// Lo que la pantalla necesita de cada orden: su cita, el cliente y el equipo, las partes de
// los dos técnicos y el material (lista de surtido y entregas; sin precios ni costos, esas
// tablas no los tienen). Se guarda con lo demás, así el material se ve también sin señal.
const SELECCION =
  '*, citas(fecha, hora, duracion_min, zona, notas, tipo_servicio), ' +
  'clientes(nombre, telefono, direccion, colonia, municipio, maps_url, referencias), ' +
  'equipos(numero_serie, marca, modelo, tipo, capacidad_kw), orden_partes(*), ' +
  'orden_surtido(id, producto_id, sku, nombre, unidad, cantidad_pedida, cantidad_entregada, ' +
  'cantidad_usada, cantidad_devuelta, cantidad_diferencia), ' +
  'entregas(id, folio, estado, created_at, entrega_lineas(sku, nombre, unidad, cantidad))'

export const leerTrabajos = () => leerLocal(CACHE, [])
export const leerNombres = () => leerLocal(NOMBRES, [])
export const leerCola = () => leerLocal(COLA, [])

// ---------------------------------------------------------------------------
// Lectura
// ---------------------------------------------------------------------------
export async function cargarTrabajos() {
  try {
    const [o, n] = await Promise.all([
      supabase.from('ordenes_servicio').select(SELECCION)
        .in('estado', ['abierta', 'cerrada'])
        .not('cita_id', 'is', null)       // las órdenes de antes (sin cita) no entran aquí
        .order('fecha', { ascending: false })
        .limit(80),
      supabase.rpc('lista_tecnicos')
    ])
    if (o.error) return { ok: false, error: o.error }
    // Las cerradas solo se guardan un tiempo, para consultarlas; las abiertas, siempre.
    const limite = sumarDias(hoyLocal(), -14)
    const ordenes = (o.data || []).filter(x => x.estado === 'abierta' || (x.updated_at || '').slice(0, 10) >= limite)
    escribirLocal(CACHE, ordenes)
    if (!n.error && n.data) escribirLocal(NOMBRES, n.data)
    return { ok: true, ordenes, nombres: n.data || leerNombres() }
  } catch (e) {
    return { ok: false, error: e }
  }
}

// Fotos de Storage que no están en el celular. Sin señal no hay URL y se muestran como conteo.
export async function urlsFirmadas(rutas) {
  if (!rutas.length) return {}
  try {
    const { data } = await supabase.storage.from(BUCKET).createSignedUrls(rutas, 3600)
    return Object.fromEntries((data || []).filter(x => x.signedUrl).map(x => [x.path, x.signedUrl]))
  } catch {
    return {}
  }
}

// ---------------------------------------------------------------------------
// Mi parte, guardada en el celular
// ---------------------------------------------------------------------------
export function parteLocal(orden_id) {
  return leerLocal(PARTES, {})[orden_id] || null
}

function escribirParte(orden_id, parte) {
  const todas = leerLocal(PARTES, {})
  if (parte) todas[orden_id] = parte
  else delete todas[orden_id]
  escribirLocal(PARTES, todas)
}

// Guarda notas y fotos EN EL CELULAR y deja la parte en la cola. Se llama en cada cambio:
// no hay botón de "guardar", así que nada se pierde si se cierra la app.
export function guardarParteLocal(orden_id, cambios) {
  const previa = parteLocal(orden_id)
  const parte = {
    notas: '', fotos: [],
    ...(previa || {}), ...cambios,
    version: (previa?.version || 0) + 1,   // sirve para saber si escribió mientras subía
    sucio: true,
    actualizado: new Date().toISOString()
  }
  escribirParte(orden_id, parte)
  escribirLocal(COLA, encolarEn(leerCola(), { clave: claveDe('parte', orden_id), tipo: 'parte', orden_id }))
  return parte
}

// `actuales`: la lista de fotos que la pantalla tiene ahora (puede venir del servidor, sin
// versión local todavía).
export async function agregarFotoLocal(orden_id, blob, actuales) {
  const id = crypto.randomUUID()
  await guardarFoto({ id, orden_id, blob })
  return guardarParteLocal(orden_id, { fotos: [...actuales, { id, ruta: null }] })
}

export async function quitarFotoLocal(orden_id, id, actuales) {
  try { await borrarFoto(id) } catch { /* si no estaba, no pasa nada */ }
  return guardarParteLocal(orden_id, { fotos: actuales.filter(f => f.id !== id) })
}

// ---------------------------------------------------------------------------
// Cierre y descarte
// ---------------------------------------------------------------------------
export function pedirCierre(orden_id, payload) {
  escribirLocal(COLA, encolarEn(leerCola(), { clave: claveDe('cierre', orden_id), tipo: 'cierre', orden_id, payload }))
}

// Tira lo pendiente de una orden. Solo para lo que ya no puede subir (la orden se cerró o se
// reasignó): la pantalla pide confirmación antes.
export async function descartarPendiente(clave) {
  const item = leerCola().find(i => i.clave === clave)
  escribirLocal(COLA, leerCola().filter(i => i.clave !== clave))
  if (item?.tipo === 'parte') {
    escribirParte(item.orden_id, null)
    try { await borrarFotosDeOrden(item.orden_id) } catch { /* nada */ }
  }
}

// ---------------------------------------------------------------------------
// Subida
// ---------------------------------------------------------------------------
function fallo(error) {
  const m = String(error?.message || error || '')
  // Los mensajes de nuestras funciones ya vienen en español y dicen exactamente qué pasó.
  if (/^(Solo el|La orden|Anota|Falta|Esa pieza|Declaraste|Las cantidades|El material)/.test(m)) return { ok: false, motivo: m, temporal: false }
  // RLS de orden_partes: la orden ya no está abierta o ya no es suya.
  if (/row-level security/i.test(m)) {
    return { ok: false, motivo: 'La orden ya no está abierta o ya no eres parte de ella. Avisa al administrador.', temporal: false }
  }
  const { texto, temporal } = explicarError(error)
  return { ok: false, motivo: texto, temporal }
}

function anotarRutas(orden_id, rutas) {
  const p = parteLocal(orden_id)
  if (!p) return
  // Es progreso de subida, no un cambio del técnico: no sube la versión ni ensucia.
  escribirParte(orden_id, { ...p, fotos: p.fotos.map(f => (rutas[f.id] ? { ...f, ruta: rutas[f.id] } : f)) })
}

async function subirParte(item) {
  try {
    const uid = usuarioLocal()?.id
    if (!uid) return { ok: false, motivo: 'No se encontró tu sesión guardada. Sal y vuelve a entrar.', temporal: false }

    const parte = parteLocal(item.orden_id)
    if (!parte) {
      escribirLocal(COLA, sacarSiSigue(leerCola(), item.clave, item.n))
      return { ok: true }
    }

    // Primero los archivos, luego el renglón: si el renglón se subiera antes podría quedar
    // apuntando a fotos que nunca llegaron.
    const locales = await fotosDeOrden(item.orden_id)
    const nuevas = {}
    for (const f of parte.fotos) {
      if (f.ruta) continue
      const guardada = locales.find(x => x.id === f.id)
      if (!guardada) continue                 // ya no está en el celular: no hay qué subir
      const ruta = `${item.orden_id}/${uid}/${f.id}.jpg`
      const { error } = await supabase.storage.from(BUCKET)
        .upload(ruta, guardada.blob, { contentType: 'image/jpeg', upsert: true })
      if (error) { anotarRutas(item.orden_id, nuevas); return fallo(error) }
      nuevas[f.id] = ruta
    }
    anotarRutas(item.orden_id, nuevas)

    // Se relee: pudo escribir más mientras subían las fotos.
    const actual = parteLocal(item.orden_id)
    const { error } = await supabase.from('orden_partes').upsert({
      orden_id: item.orden_id,
      autor_id: uid,
      notas: actual.notas || null,
      fotos: actual.fotos.filter(f => f.ruta).map(f => f.ruta)
    }, { onConflict: 'orden_id,autor_id' })
    if (error) return fallo(error)

    // Solo queda "limpia" si no escribió nada mientras tanto.
    if (parteLocal(item.orden_id)?.version === actual.version) {
      escribirParte(item.orden_id, { ...parteLocal(item.orden_id), sucio: false })
    }
    escribirLocal(COLA, sacarSiSigue(leerCola(), item.clave, item.n))
    return { ok: true }
  } catch (e) {
    return fallo(e)     // fetch lanza en vez de devolver error cuando no hay red
  }
}

async function subirCierre(item) {
  try {
    // El cierre junta las notas que ya están en la base: primero tienen que estar allá.
    if (parteLocal(item.orden_id)?.sucio) {
      return { ok: false, motivo: 'Esperando a subir tus notas y fotos antes de cerrar.', temporal: true }
    }
    const p = item.payload || {}

    let rutaFirma = null
    if (p.firma_data) {
      rutaFirma = `${item.orden_id}/firma.png`
      const { error } = await supabase.storage.from(BUCKET)
        .upload(rutaFirma, dataUrlABlob(p.firma_data), { contentType: 'image/png', upsert: true })
      if (error) return fallo(error)
    }

    const { error } = await supabase.rpc('cerrar_orden', {
      p_orden: item.orden_id,
      p_firma: rutaFirma,
      p_sin_firma: !!p.sin_firma,
      p_horas: p.horas ?? null,
      p_observaciones: p.observaciones || null,
      p_recomendaciones: p.recomendaciones || null,
      p_seguimiento: !!p.seguimiento,
      p_fecha_seguimiento: p.fecha_seguimiento || null,
      p_refacciones: p.refacciones?.length ? p.refacciones : null,
      // Lo usado de lo entregado. Un cierre que salió del celular antes de esta versión no trae
      // `uso`: se manda null (todo queda pendiente de devolución, que es lo seguro).
      p_uso: p.uso?.length ? p.uso : null
    })
    if (error) return fallo(error)

    // Cerrada (o ya lo estaba: el reintento de un cierre que sí llegó). Se limpia el celular.
    try { await borrarFotosDeOrden(item.orden_id) } catch { /* nada */ }
    escribirParte(item.orden_id, null)
    escribirLocal(CACHE, leerTrabajos().map(o => (o.id === item.orden_id ? { ...o, estado: 'cerrada' } : o)))
    escribirLocal(COLA, sacarSiSigue(leerCola(), item.clave, item.n))
    return { ok: true }
  } catch (e) {
    return fallo(e)
  }
}

// Un solo sincronizador a la vez, aunque haya varias pantallas o temporizadores.
let corriendo = false

export async function sincronizarTrabajos() {
  if (corriendo || leerCola().length === 0) return { corrio: false, subidos: 0, fallidos: 0 }
  corriendo = true
  let subidos = 0, fallidos = 0
  try {
    for (const item of ordenarCola(leerCola())) {
      const r = item.tipo === 'parte' ? await subirParte(item) : await subirCierre(item)
      if (r.ok) {
        subidos++
      } else {
        fallidos++
        escribirLocal(COLA, marcarFallo(leerCola(), item.clave, item.n, r.motivo, r.temporal))
      }
    }
  } finally {
    corriendo = false
  }
  return { corrio: true, subidos, fallidos }
}

// ---------------------------------------------------------------------------
// "Enviar al cliente en cuanto se cierre": lo marca el admin, desde que ve la orden (abierta o
// cerrada), sin esperar a nada. No es un envío automático de verdad (el PDF lo arma el
// navegador del admin, fase 4: ver lib/documentos.js); es un recordatorio que resalta la orden
// al cerrarse y se apaga solo al registrarse el envío.
// ---------------------------------------------------------------------------
export async function marcarEnviarAlCerrar(orden_id, valor) {
  try {
    const { error } = await supabase.from('ordenes_servicio').update({ enviar_al_cerrar: valor }).eq('id', orden_id)
    if (error) return { ok: false, texto: explicarError(error).texto }
    return { ok: true }
  } catch (e) {
    return { ok: false, texto: explicarError(e).texto }
  }
}
