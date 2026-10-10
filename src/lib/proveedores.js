// Proveedores (SQL 80): la ficha y la carpeta de cada proveedor. Solo admin.
//
// La base hace el trabajo de reconocer a un proveedor (por RFC, clave de sincronización o nombre
// sin "S.A. de C.V."); aquí solo se muestra, se edita y se decide lo que la base no puede saber:
// si dos fichas parecidas son el mismo proveedor.
//
// No confundir con proveedor.js: ese es la sincronización de precios de XLStore y Solarama.
import { supabase } from './supabase'
import { explicarError } from './errores'
import { RFC_VALIDO, estadoVencimiento } from './finanzas'

const textoDeError = e => {
  const codigo = String(e?.code || '')
  if (['22023', '42501'].includes(codigo) && e?.message) return e.message
  return explicarError(e).texto
}
const rpc = async (nombre, args) => {
  try {
    const { data, error } = await supabase.rpc(nombre, args)
    if (error) return { error: textoDeError(error) }
    return { data }
  } catch (e) {
    return { error: textoDeError(e) }
  }
}

export const cargarProveedores = () => rpc('proveedores_resumen')
export const cargarCarpeta = id => rpc('carpeta_proveedor', { p_id: id })
export const cargarParecidos = () => rpc('proveedores_parecidos')
export const guardarProveedor = (id, form) => rpc('guardar_proveedor', { p_id: id || null, p_datos: paraGuardar(form) })
export const unirProveedores = (queda, seVa) => rpc('unir_proveedores', { p_queda: queda, p_se_va: seVa })
export const marcarDistintos = (a, b) => rpc('marcar_proveedores_distintos', { p_a: a, p_b: b })

// ---- reglas puras ----

const normal = t => String(t ?? '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').trim()
const limpiarRfc = t => String(t ?? '').toUpperCase().replace(/[\s-]/g, '')
const RFC_GENERICOS = ['XAXX010101000', 'XEXX010101000']

// Busca en nombre, RFC, clave y en cómo viene impreso (alias).
export function filtrarProveedores(lista, texto) {
  const q = normal(texto)
  if (!q) return lista
  return lista.filter(p => [p.nombre, p.rfc, p.clave, ...(p.alias || [])].some(v => normal(v).includes(q)))
}

export const formVacio = () => ({ nombre: '', rfc: '', contacto: '', telefono: '', email: '', notas: '', alias: '', activo: true })

export function aFormulario(p) {
  return {
    nombre: p?.nombre || '', rfc: p?.rfc || '', contacto: p?.contacto || '', telefono: p?.telefono || '',
    email: p?.email || '', notas: p?.notas || '', alias: (p?.alias || []).join('\n'), activo: p?.activo !== false
  }
}

// Lo mismo que revisa guardar_proveedor, adelantado para avisar antes de mandar.
export function validarProveedor(f) {
  if (!String(f?.nombre || '').trim()) return 'Escribe el nombre del proveedor.'
  const rfc = limpiarRfc(f?.rfc)
  if (rfc && RFC_GENERICOS.includes(rfc)) return 'Ese es el RFC genérico del SAT: déjalo vacío.'
  if (rfc && !RFC_VALIDO.test(rfc)) return 'El RFC no tiene el formato del SAT (12 o 13 caracteres, como ABC010101XY1).'
  const email = String(f?.email || '').trim()
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return 'El correo no parece válido.'
  return ''
}

export function paraGuardar(f) {
  const texto = v => String(v ?? '').trim() || null
  return {
    nombre: String(f?.nombre || '').trim().replace(/\s+/g, ' '),
    rfc: limpiarRfc(f?.rfc) || null,
    contacto: texto(f?.contacto), telefono: texto(f?.telefono), email: texto(f?.email), notas: texto(f?.notas),
    alias: String(f?.alias || '').split('\n').map(a => a.trim()).filter(Boolean),
    activo: f?.activo !== false
  }
}

const plural = (n, uno, varios) => `${n} ${n === 1 ? uno : varios}`
const enLista = partes => (partes.length > 1 ? `${partes.slice(0, -1).join(', ')} y ${partes[partes.length - 1]}` : partes[0])

// "Lo de «Cummins Sales» pasó a «Cummins» (2 compras y 1 pedido)." (la alerta ya antepone "Listo")
export function textoUnion(movidos, queda, seVa) {
  const m = movidos || {}
  const partes = [
    m.compras > 0 && plural(m.compras, 'compra', 'compras'),
    m.facturas > 0 && plural(m.facturas, 'factura', 'facturas'),
    m.pagos > 0 && plural(m.pagos, 'pago', 'pagos'),
    m.pedidos > 0 && plural(m.pedidos, 'pedido', 'pedidos'),
    m.productos > 0 && plural(m.productos, 'producto', 'productos'),
  ].filter(Boolean)
  const lista = enLista(partes)
  return `Lo de «${seVa}» pasó a «${queda}»${lista ? ` (${lista})` : ''}. Su nombre queda como otra forma de escribirlo.`
}

// La línea de la lista: lo que hay con él.
export function resumenLinea(r) {
  const x = r || {}
  return [
    x.productos > 0 && plural(x.productos, 'producto', 'productos'),
    x.compras > 0 && plural(x.compras, 'compra', 'compras'),
    x.facturas > 0 && plural(x.facturas, 'factura', 'facturas'),
    x.pedidos_abiertos > 0 && plural(x.pedidos_abiertos, 'pedido abierto', 'pedidos abiertos'),
  ].filter(Boolean).join(' · ') || 'Sin movimientos todavía'
}

const diasEntre = (desde, hasta) => Math.round((Date.parse(hasta) - Date.parse(desde)) / 86400000)

// El estado de una factura del proveedor, con palabra.
export function estadoFactura(f, hoy) {
  if (f?.estado_sat === 'cancelado') return { etiqueta: 'Cancelada en el SAT', clase: 'estado-cancelada' }
  if (!f?.por_pagar) return { etiqueta: 'Sin saldo pendiente', clase: 'estado-cerrada' }
  if (Number(f.saldo) <= 0.01) return { etiqueta: 'Pagada', clase: 'estado-cerrada' }
  if (!f.vence) return { etiqueta: 'Por pagar', clase: 'estado-revisa' }
  const v = estadoVencimiento(diasEntre(hoy, f.vence))
  return { etiqueta: v.etiqueta, clase: v.clase }
}

export const ESTADO_PEDIDO = {
  pendiente: 'Por pedir', pedida: 'Pedido al proveedor', recibida: 'Recibido', cancelada: 'Cancelado'
}
