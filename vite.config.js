import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'

// Escribe dist/sw.js a partir de sw/plantilla.js con la lista exacta de archivos
// de esta construcción. La versión sale de esa lista: como los nombres llevan
// hash del contenido, cualquier cambio de código cambia la versión, el navegador
// ve un sw.js distinto y actualiza la copia guardada.
function serviceWorker() {
  return {
    name: 'service-worker-crm',
    apply: 'build',
    generateBundle(_opciones, bundle) {
      const archivos = Object.keys(bundle)
        .filter(nombre => nombre !== 'index.html' && !nombre.endsWith('.map'))
        .map(nombre => `/${nombre}`)
        .sort()
      // '/' es el index.html. Los de public/ no aparecen en el bundle: van a mano.
      const publicos = [
        '/manifest.webmanifest', '/favicon.svg', '/icono.svg',
        '/icono-192.png', '/icono-512.png', '/icono-maskable-512.png', '/apple-touch-icon.png',
      ]
      const lista = ['/', ...publicos, ...archivos]
      const version = createHash('sha256').update(lista.join('|')).digest('hex').slice(0, 10)

      // Se reemplaza el marcador CON comillas: el mismo texto aparece en los
      // comentarios de la plantilla y ahí no debe tocarse.
      const fuente = readFileSync(new URL('./sw/plantilla.js', import.meta.url), 'utf8')
        .replace("'__VERSION__'", JSON.stringify(version))
        .replace("'__PRECACHE__'", JSON.stringify(JSON.stringify(lista)))

      // Un service worker con marcadores sin reemplazar rompería la instalación
      // en silencio: mejor que la construcción falle.
      if (/'__(VERSION|PRECACHE)__'/.test(fuente)) {
        throw new Error('sw/plantilla.js: quedaron marcadores sin reemplazar')
      }

      this.emitFile({ type: 'asset', fileName: 'sw.js', source: fuente })
    },
  }
}

// https://vite.dev/config/
export default defineConfig({
  plugins: [react(), serviceWorker()],
})
