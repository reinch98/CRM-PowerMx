// Precio con el que un producto entra a una cotización.
//
// Una cotización se arma en pesos y SIN IVA (el IVA se suma al final). Pero dos cosas del catálogo no
// encajan tal cual:
//   · Un producto en dólares (moneda = 'USD') se convierte con el último tipo de cambio guardado.
//   · Un GENERADOR se publica con el IVA incluido (volantes del 16/10/2026): para que la cotización
//     termine en ese mismo precio, la partida lleva el precio entre 1.16 y el IVA lo devuelve al sumarse.
//     Solo los generadores: el resto del catálogo sigue siendo "precio más IVA".
// La partida dice de dónde salió el número, para que nadie lea 6,500 USD como pesos ni se pregunte por
// qué el precio unitario no coincide con el del volante.

export const IVA = 0.16

const redondeo = (n, d) => Math.round(n * 10 ** d) / 10 ** d

export function precioParaCotizar(producto, tcUsd) {
  const lista = Number(producto.precio)
  if (producto.precio == null || !Number.isFinite(lista)) return { error: `${producto.sku} no tiene precio capturado.` }

  let pesos = lista
  const notas = []

  if (producto.moneda === 'USD') {
    const tc = Number(tcUsd)
    if (!Number.isFinite(tc) || tc <= 0) {
      return { error: `${producto.sku} está en dólares y no hay un tipo de cambio guardado.` }
    }
    pesos = lista * tc
    notas.push(`USD ${lista.toLocaleString('es-MX')} × TC ${tc}`)
  }

  const esGenerador = producto.categoria === 'generador'
  if (esGenerador) {
    pesos = pesos / (1 + IVA)
    notas.push('precio de lista con IVA incluido')
  }

  return {
    // 4 decimales en generadores: con 2, 26,000 / 1.16 volvería a 25,999.99 al sumarle el IVA.
    precio: redondeo(pesos, esGenerador ? 4 : 2),
    nota: notas.length ? ` (${notas.join('; ')})` : '',
  }
}

// Cómo se ve el precio en la lista de resultados del buscador.
export function textoPrecioLista(producto, tcUsd, formatoPesos) {
  if (producto.precio == null) return 'sin precio'
  const iva = producto.categoria === 'generador' ? ' con IVA incluido' : ''
  if (producto.moneda === 'USD') {
    return `USD ${Number(producto.precio).toLocaleString('es-MX')}${iva} (en pesos al TC ${tcUsd ?? 'sin dato'})`
  }
  return `${formatoPesos(producto.precio)}${iva}`
}
