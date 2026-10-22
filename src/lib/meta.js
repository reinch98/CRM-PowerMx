// ---------------------------------------------------------------------------
// Catálogo de Meta (SQL 88): qué productos se mandan a Facebook, Instagram y WhatsApp.
//
// El sitio publica todo; a Meta solo va lo marcado con `productos.en_meta`. El archivo lo arma
// `convertir.js` del repo del sitio (feed-meta.js), que además deja fuera lo que Meta no acepta.
// Aquí se adelanta ese mismo aviso para que no se marque algo que de todos modos no saldría.
// ---------------------------------------------------------------------------

// Por qué un producto marcado NO va a salir en Meta (o null si sí sale). La foto no se sabe
// desde el CRM (vive en el repo del sitio): eso lo dice la corrida de convertir.js.
export function avisoMeta(p) {
  if (!p) return null
  if (!p.activo || !p.publicar) return 'No está publicado en el sitio'
  if (['renta', 'paquete_solar'].includes(p.categoria)) return 'Rentas y paquetes no van a Meta'
  if (!(Number(p.precio) > 0)) return 'Sin precio: Meta lo rechaza'
  if (String(p.moneda || 'MXN').toUpperCase() !== 'MXN') return 'En dólares: se cotiza aparte'
  return null
}

// Los ids en tandas: un update con cientos de ids en la dirección se pasa del largo permitido.
export function enTandas(lista, n = 100) {
  const tandas = []
  for (let i = 0; i < lista.length; i += n) tandas.push(lista.slice(i, i + n))
  return tandas
}

// "12 productos" / "1 producto".
export const productosTexto = n => `${n} producto${n === 1 ? '' : 's'}`
