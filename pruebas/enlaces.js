// ---------------------------------------------------------------------------
// Enlaces de módulos para las pruebas (node:module). Hacen dos cosas.
//
// 1. Desvían `./supabase` al doble de `pruebas/falso/`: el archivo de verdad usa
//    `import.meta.env`, que solo existe dentro de Vite, y truena al cargarlo en Node.
//    Ojo con no atrapar `@supabase/supabase-js`, que también lleva "supabase" en el
//    nombre: solo se desvía el archivo propio del proyecto.
//
// 2. Le agregan `.js` a los imports relativos que no la traen. En el código del CRM
//    conviven `from './errores'` y `from './fechas.js'` porque **Vite resuelve la
//    extensión y Node no**: sin esto, media librería no se puede cargar desde una
//    prueba. Se hace aquí y no renombrando 26 imports para que probar no obligue a
//    tocar el código que ya funciona en producción.
// ---------------------------------------------------------------------------

const FALSO = new URL('./falso/supabase.js', import.meta.url).href

const esElNuestro = e =>
  e === './supabase' || e === './supabase.js' ||
  e.endsWith('/lib/supabase') || e.endsWith('/lib/supabase.js')

const relativoSinExtension = e => /^\.{1,2}\//.test(e) && !/\.[a-z]+$/i.test(e)

export async function resolve(especificador, contexto, siguiente) {
  if (esElNuestro(especificador)) return { url: FALSO, shortCircuit: true }
  try {
    return await siguiente(especificador, contexto)
  } catch (e) {
    if (e?.code === 'ERR_MODULE_NOT_FOUND' && relativoSinExtension(especificador)) {
      return siguiente(`${especificador}.js`, contexto)
    }
    throw e
  }
}
