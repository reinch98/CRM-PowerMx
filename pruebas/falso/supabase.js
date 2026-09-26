// ---------------------------------------------------------------------------
// Supabase falso para las pruebas en Node.
//
// `src/lib/supabase.js` usa `import.meta.env`, que solo existe dentro de Vite: al
// importarlo desde Node truena antes de llegar a la primera prueba. Los enlaces de
// `pruebas/enlaces.js` desvían ese archivo aquí.
//
// A propósito NO imita a Supabase: cualquier llamada de red revienta con un mensaje
// claro. Estas pruebas son de las **reglas puras** —precios, cantidades, la cola sin
// señal—, no de la base. Si una prueba llega hasta aquí, está probando lo que no debe.
// ---------------------------------------------------------------------------

const revienta = () => {
  throw new Error(
    'Una prueba tocó Supabase. Aquí solo se prueban reglas puras: ' +
    'saca el cálculo de la función que llama a la base.'
  )
}

export const supabase = {
  from: revienta,
  rpc: revienta,
  storage: { from: revienta },
  auth: { getUser: revienta, getSession: revienta },
}
