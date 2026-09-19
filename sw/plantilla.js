// ---------------------------------------------------------------------------
// Service worker del CRM: deja abrir la app sin señal.
//
// Esto es una PLANTILLA. vite.config.js la convierte en dist/sw.js al construir,
// reemplazando __VERSION__ y __PRECACHE__ (los archivos exactos de esa versión,
// con sus nombres con hash). No se importa desde la app.
//
// Qué hace y qué no:
//   · Guarda la app (HTML, JS, CSS) al instalarse, para que abra sin señal.
//   · La página de inicio va primero a la red y cae a la copia si no responde:
//     con señal siempre se ve la versión más nueva.
//   · NO toca nada que no sea de este mismo sitio. Las llamadas a Supabase
//     (datos, sesión, fotos) van directo a la red, sin copia. Los datos sin señal
//     los resuelve la propia app (cola de órdenes, catálogo de equipos, perfil).
// ---------------------------------------------------------------------------

const VERSION = '__VERSION__'
const CACHE = `crm-powermx-${VERSION}`
const PRECACHE = JSON.parse('__PRECACHE__')

// Con señal mala la red no falla, se queda pensando. Pasado este tiempo se
// usa la copia en vez de dejar al técnico mirando una pantalla en blanco.
const ESPERA_RED_MS = 4000

self.addEventListener('install', evento => {
  evento.waitUntil(
    caches.open(CACHE)
      // cache: 'reload' se salta la copia del navegador, para guardar lo que hay de verdad.
      .then(cache => cache.addAll(PRECACHE.map(url => new Request(url, { cache: 'reload' }))))
      .then(() => self.skipWaiting())
  )
})

self.addEventListener('activate', evento => {
  evento.waitUntil(
    caches.keys()
      .then(nombres => Promise.all(
        nombres
          .filter(n => n.startsWith('crm-powermx-') && n !== CACHE)
          .map(n => caches.delete(n))
      ))
      .then(() => self.clients.claim())
  )
})

self.addEventListener('fetch', evento => {
  const peticion = evento.request
  if (peticion.method !== 'GET') return

  const url = new URL(peticion.url)
  if (url.origin !== self.location.origin) return   // Supabase y demás: directo a la red
  if (url.pathname === '/sw.js') return             // el navegador lo actualiza por su cuenta

  if (peticion.mode === 'navigate') {
    evento.respondWith(paginaDeInicio(peticion))
  } else {
    evento.respondWith(primeroLaCopia(peticion))
  }
})

function conTiempo(promesa, ms) {
  return Promise.race([
    promesa,
    new Promise((_, rechazar) => setTimeout(() => rechazar(new Error('sin respuesta')), ms))
  ])
}

// La app es de una sola página: cualquier dirección abre el mismo HTML, que se
// guarda bajo '/'.
async function paginaDeInicio(peticion) {
  const cache = await caches.open(CACHE)
  try {
    const respuesta = await conTiempo(fetch(peticion), ESPERA_RED_MS)
    if (respuesta.ok) cache.put('/', respuesta.clone())
    return respuesta
  } catch {
    return (await cache.match('/')) || Response.error()
  }
}

// Los archivos con hash en el nombre nunca cambian: si hay copia, esa es.
async function primeroLaCopia(peticion) {
  const cache = await caches.open(CACHE)
  const guardada = await cache.match(peticion)
  if (guardada) return guardada

  const respuesta = await fetch(peticion)
  if (respuesta.ok) cache.put(peticion, respuesta.clone())
  return respuesta
}
