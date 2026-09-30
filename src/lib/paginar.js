// Supabase corta TODA consulta a 1,000 filas, en silencio: no da error, solo entrega las
// primeras mil. Con ~95 productos no se notaba; con el catálogo del proveedor (SQL 45) el
// catálogo pasa de mil y las pantallas empezarían a perder productos sin avisar — y como se
// ordena por categoría o por SKU, lo que se pierde son siempre los del final.
//
// `armar` devuelve una consulta NUEVA en cada llamada (un constructor de supabase-js se
// consume al esperarlo) y debe llevar un orden que no se repita entre filas (el SKU, el id):
// con un orden ambiguo, paginar puede repetir o saltarse filas.
export const TAMANO_PAGINA = 1000

export async function todasLasFilas(armar, tamano = TAMANO_PAGINA) {
  const filas = []
  for (let desde = 0; ; desde += tamano) {
    const r = await armar().range(desde, desde + tamano - 1)
    if (r.error) return { data: null, error: r.error }
    const pagina = r.data || []
    filas.push(...pagina)
    if (pagina.length < tamano) break
  }
  return { data: filas, error: null }
}
