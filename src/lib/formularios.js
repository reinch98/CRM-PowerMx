// ---------------------------------------------------------------------------
// Pasar un registro de la base a un formulario y de vuelta.
//
// Las altas y las ediciones usan el MISMO formulario: si cada pantalla lo copiara a mano,
// un campo nuevo se agregaría al alta y se olvidaría en la edición. Aquí en un solo lugar.
//
// La base guarda `null` donde el formulario necesita `''`: un `<input>` con `value={null}`
// pasa a no controlado y React se queja. Al guardar hay que deshacer la conversión, porque
// Postgres no acepta `''` en columnas numéricas ni de fecha.
// ---------------------------------------------------------------------------

// Toma solo las claves que el formulario conoce: si la tabla trae `id`, `created_at` o
// columnas que la pantalla no edita, no deben viajar de vuelta en el update.
export function aFormulario(registro, vacio) {
  const salida = { ...vacio }
  for (const clave of Object.keys(vacio)) {
    const v = registro?.[clave]
    if (v === null || v === undefined) continue
    salida[clave] = typeof v === 'boolean' ? v : String(v)
  }
  return salida
}

// Lo contrario: las cadenas vacías de columnas numéricas y de fecha se van como null.
export function paraGuardar(form, { numericas = [], fechas = [] } = {}) {
  const salida = { ...form }
  for (const campo of [...numericas, ...fechas]) {
    if (salida[campo] === '') salida[campo] = null
  }
  for (const campo of numericas) {
    if (salida[campo] !== null && salida[campo] !== undefined) salida[campo] = Number(salida[campo])
  }
  return salida
}
