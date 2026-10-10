// El mismo archivo no se registra dos veces (SQL 81).
//
// La huella es el SHA-256 de los bytes ORIGINALES, antes de encoger una foto: el mismo archivo
// elegido dos veces da la misma huella aunque la copia que se sube salga distinta. Se pregunta a
// la base ANTES de subir y de gastar una lectura de IA; al guardar, los disparadores de la base lo
// vuelven a revisar (el candado de verdad está allá, no aquí).
//
// Grupos (los mismos del SQL): 'dinero' = bandeja de Finanzas, cobros y gastos del libro, estados
// de cuenta; 'compras' = archivos de las compras de material.
import { supabase } from './supabase'

export async function sha256Hex(buffer) {
  const h = await crypto.subtle.digest('SHA-256', buffer)
  return Array.from(new Uint8Array(h)).map(b => b.toString(16).padStart(2, '0')).join('')
}

export async function huellaDe(archivo) {
  return sha256Hex(await archivo.arrayBuffer())
}

// "Ese archivo ya está registrado en el expediente de la cotización 12: un cobro del …"
export const textoRepetido = donde =>
  `Ese archivo ya está registrado ${donde || 'en el CRM'}. No se volvió a subir.`

// ¿Ya está registrado? Si la base no contesta (sin red, o el SQL 81 sin correr) no se detiene el
// trabajo: el disparador de la base es el que manda al guardar.
export async function revisarArchivo(hash, grupo = 'dinero', origen = null) {
  try {
    const { data, error } = await supabase.rpc('archivo_repetido', { p_hash: hash, p_grupo: grupo, p_origen: origen })
    if (error || !data) return { repetido: false }
    return { repetido: !!data.repetido, donde: data.donde || '', texto: data.repetido ? textoRepetido(data.donde) : '' }
  } catch {
    return { repetido: false }
  }
}

// Deja la huella de lo que se acaba de subir. Si falla, el archivo ya subió y el trabajo sigue:
// solo se pierde poder reconocerlo como repetido más adelante.
export async function anotarArchivo(bucket, ruta, hash, nombre) {
  try {
    await supabase.rpc('anotar_archivo', { p_bucket: bucket, p_ruta: ruta, p_hash: hash, p_nombre: nombre || null })
  } catch {
    /* sin red: ver arriba */
  }
}
