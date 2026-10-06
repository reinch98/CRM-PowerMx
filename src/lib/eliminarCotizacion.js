// ---------------------------------------------------------------------------
// Eliminar una cotización de prueba con sus citas y órdenes (SQL 60).
//
// Siempre en dos pasos: primero una VISTA PREVIA (la base dice qué se borraría y qué lo impide,
// sin tocar nada) y solo después, con el admin ya enterado, el borrado de verdad.
// ---------------------------------------------------------------------------

import { supabase } from './supabase'
import { explicarError } from './errores'

const plural = (n, uno, varios) => `${n} ${n === 1 ? uno : varios}`

// Lo que se va a borrar, en renglones para mostrar al admin. Lo que es cero no se menciona.
export function renglonesDelResumen(r) {
  if (!r) return []
  const l = [`La cotización ${r.folio} (${String(r.estado || '').replace(/_/g, ' ')})`]
  if (r.citas > 0) l.push(plural(r.citas, 'cita', 'citas'))
  if (r.ordenes > 0) {
    l.push(`${plural(r.ordenes, 'orden de servicio', 'órdenes de servicio')}${r.ordenes_folios ? ` (${r.ordenes_folios})` : ''}, con sus fotos, firma y revisión`)
  }
  if (r.movimientos_apartado > 0) {
    l.push(`${plural(r.movimientos_apartado, 'movimiento de apartado', 'movimientos de apartado')} de inventario (ya liberados: no cambian las existencias)`)
  }
  if (r.pedidos > 0) l.push(plural(r.pedidos, 'pedido pendiente a proveedor', 'pedidos pendientes a proveedor'))
  if (r.entregas_sin_firmar > 0) l.push(plural(r.entregas_sin_firmar, 'entrega del almacén sin firmar', 'entregas del almacén sin firmar'))
  if (r.solicitudes_material > 0) l.push(plural(r.solicitudes_material, 'solicitud de material', 'solicitudes de material'))
  return l
}

// Normaliza la respuesta de la base: nunca devuelve algo a medias.
export function leerRespuesta(data) {
  const d = data && typeof data === 'object' ? data : {}
  return {
    ok: d.ok === true,
    ejecutado: d.ejecutado === true,
    bloqueos: Array.isArray(d.bloqueos) ? d.bloqueos : [],
    resumen: d.resumen || null
  }
}

async function llamar(id, ejecutar) {
  try {
    const { data, error } = await supabase.rpc('eliminar_cotizacion', { p_cotizacion: id, p_ejecutar: ejecutar })
    if (error) return { error: explicarError(error).texto }
    return { respuesta: leerRespuesta(data) }
  } catch (e) {
    return { error: explicarError(e).texto }
  }
}

export const previsualizarEliminacion = id => llamar(id, false)
export const ejecutarEliminacion = id => llamar(id, true)
