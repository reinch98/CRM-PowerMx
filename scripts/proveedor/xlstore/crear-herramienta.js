// Genera `xlstore-descargar.js`: la herramienta que se PEGA en la consola del navegador estando en
// xlstore.exelsolar.com con la sesión iniciada. Baja el catálogo completo (precios, existencias, enlaces)
// a un archivo `xlstore_catalogo.csv` en la carpeta de Descargas, listo para `sync.js --archivo`.
//
//   node scripts/proveedor/xlstore/crear-herramienta.js
//
// Se genera DE `extraer.js` (el mismo código que usa la lectura con sesión) para que los dos caminos no
// se separen con el tiempo: si cambia cómo se lee XLStore, se cambia en un solo lugar y se vuelve a generar.
import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const aqui = path.dirname(fileURLToPath(import.meta.url))

export function armarHerramienta(codigoExtraer) {
  // Fuera `export`: en la consola todo es del mismo ámbito.
  const cuerpo = codigoExtraer.replace(/^export\s+/gm, '')
  return `/* PowerMx — leer el catálogo de XLStore con TU sesión y bajarlo como CSV.
   Pégalo en la consola (F12 → Consola) estando en xlstore.exelsolar.com con la sesión iniciada.
   Generado de scripts/proveedor/xlstore/extraer.js: no lo edites a mano. */
(async () => {
  if (location.hostname !== 'xlstore.exelsolar.com') {
    alert('Abre esto estando en xlstore.exelsolar.com, con tu sesión iniciada.')
    return
  }
${cuerpo.split('\n').map((l) => (l ? '  ' + l : l)).join('\n')}

  const estado = (t) => console.log('[PowerMx] ' + t)
  try {
    const r = await extraerCatalogo({
      fetchFn: (url) => fetch(url, { credentials: 'include' }),
      DP: DOMParser,
      onProgreso: estado,
    })
    const blob = new Blob(['\\uFEFF' + aCsv(r.filas)], { type: 'text/csv;charset=utf-8' })
    const a = document.createElement('a')
    a.href = URL.createObjectURL(blob)
    a.download = 'xlstore_catalogo.csv'
    document.body.appendChild(a)
    a.click()
    a.remove()
    estado('Listo: ' + r.resumen.productos + ' productos (' + r.resumen.sinPrecio + ' sin precio). Revisa tu carpeta de Descargas.')
    if (r.avisos.length) console.warn('[PowerMx] ' + r.avisos.length + ' avisos:', r.avisos.slice(0, 10))
    alert('Listo: ' + r.resumen.productos + ' productos. Se bajó xlstore_catalogo.csv')
  } catch (e) {
    console.error('[PowerMx]', e)
    alert('No se pudo leer XLStore: ' + e.message)
  }
})()
`
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const fuente = readFileSync(path.join(aqui, 'extraer.js'), 'utf8')
  const salida = path.join(aqui, 'xlstore-descargar.js')
  writeFileSync(salida, armarHerramienta(fuente), 'utf8')
  console.log(`Escrito ${salida}`)
}
