// ---------------------------------------------------------------------------
// Contactos: reglas puras (sin red) de la pantalla "Contactos".
// La base (15_contactos.sql) es la que manda; esto solo valida antes de enviar y
// pone las cosas en palabras.
// ---------------------------------------------------------------------------

export const ROLES = [
  ['responsable', 'Responsable'],
  ['encargado', 'Encargado'],
  ['administracion', 'Administración'],
  ['solo_avisos', 'Solo avisos']
]

// 'empresa' no es un rol que se elija: es lo que la vista `contactos_por_equipo` pone a quien
// aplica a todos los equipos por ser "de toda la empresa".
export const etiquetaRol = rol =>
  rol === 'empresa' ? 'Toda la empresa' : (ROLES.find(([v]) => v === rol)?.[1] ?? rol)

// Igual que `normalizar_telefono` de la base: los últimos 10 dígitos, o null si no hay 10.
// WhatsApp entrega los números de México como 521…, y así "999 123 4567" y "+52 1 999 123 4567"
// son el mismo.
export function normalizarTelefono(texto) {
  const digitos = String(texto ?? '').replace(/\D/g, '')
  return digitos.length >= 10 ? digitos.slice(-10) : null
}

// Permisos en palabras (nunca solo casillas o colores).
export function permisosEnPalabras(x) {
  const p = []
  if (x.puede_pedir_citas) p.push('Pide citas')
  if (x.recibe_ordenes) p.push('Recibe órdenes')
  if (x.recibe_cotizaciones) p.push('Recibe cotizaciones')
  return p.length ? p.join(' · ') : 'Sin permisos'
}

export function descripcionEquipo(e) {
  const partes = [e.tipo, e.marca, e.modelo, e.capacidad_kw ? `${e.capacidad_kw} kW` : null]
  return partes.filter(Boolean).join(' ') || 'Equipo'
}

// Lo que se manda a la tabla al guardar una persona. Los vacíos van como null; los permisos
// de "toda la empresa" solo cuentan si la persona es de toda la empresa.
export function armarContacto(form) {
  const limpio = v => {
    const t = String(v ?? '').trim()
    return t === '' ? null : t
  }
  const empresa = !!form.de_toda_la_empresa
  return {
    nombre: String(form.nombre ?? '').trim(),
    puesto: limpio(form.puesto),
    telefono: limpio(form.telefono),
    email: limpio(form.email),
    notas: limpio(form.notas),
    whatsapp: !!form.whatsapp,
    verificado: !!form.verificado,
    de_toda_la_empresa: empresa,
    puede_pedir_citas: empresa && !!form.puede_pedir_citas,
    recibe_ordenes: empresa && !!form.recibe_ordenes,
    recibe_cotizaciones: empresa && !!form.recibe_cotizaciones
  }
}

// Qué le falta a una persona para poder guardarla (o null si está bien).
export function problemaDeContacto(datos) {
  if (!datos.nombre) return 'Escribe el nombre de la persona.'
  if (datos.telefono && !normalizarTelefono(datos.telefono)) {
    return 'El teléfono debe tener al menos 10 dígitos (con lada).'
  }
  return null
}

// Los errores de la base que sí se pueden explicar.
export function textoDeError(error) {
  const codigo = String(error?.code || '')
  if (codigo === '23505') return 'Ese número ya está registrado en este cliente.'
  if (codigo === '22023' || codigo === 'P0002' || codigo === '42501') return error.message
  return error?.message || 'Error desconocido.'
}
