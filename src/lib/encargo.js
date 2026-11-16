// Un "encargo" entre pantallas: datos que una pantalla deja para la siguiente.
//
// `irA(clave)` solo cambia de pantalla (App.jsx) y cada pantalla se monta de nuevo, así que
// no hay por dónde pasarle datos. Esto los guarda EN MEMORIA (no en el navegador: se pierde
// al recargar, que es lo correcto para algo a medio hacer) y los entrega una sola vez, a la
// pantalla a la que iban. Hoy lo usa Solicitudes → Cotizaciones (calculadora solar, fase 5).
let pendiente = null

export function dejarEncargo(pantalla, datos) {
  pendiente = { pantalla, datos }
}

// Lo entrega y lo borra: una segunda llamada (o la de otra pantalla) no recibe nada.
export function tomarEncargo(pantalla) {
  if (!pendiente || pendiente.pantalla !== pantalla) return null
  const { datos } = pendiente
  pendiente = null
  return datos
}
