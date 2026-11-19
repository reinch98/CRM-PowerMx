// ---------------------------------------------------------------------------
// Flujo de compras: pedido (requisición) → nota (la compra con su ticket) → factura (el XML).
//
// No hay tabla nueva: el flujo ya vive en la base y solo había que juntarlo.
//   · `compra_lineas.requisicion_id` dice qué pedido recibió cada compra (SQL 41).
//   · `cfdi.compra_id` dice qué factura es de qué compra (SQL 67 y 86: se liga sola por UUID,
//     o por proveedor + folio + total).
// Un flujo es UNA compra con sus pedidos, o un pedido que todavía no tiene compra.
//
// Las reglas viven aparte de las llamadas para probarlas en Node sin red.
// ---------------------------------------------------------------------------

import { supabase } from './supabase'
import { explicarError } from './errores'

// `sin_factura` (SQL 101): un ticket que nunca tendrá factura y se cerró así, con su motivo.
export const ETAPAS = {
  nota: 'Falta la nota',
  factura: 'Falta la factura',
  completo: 'Completo',
  sin_factura: 'Cerrado sin factura',
}

const num = v => {
  const n = Number(v)
  return Number.isFinite(n) ? n : 0
}

// Ordena de más reciente a más antiguo; empate por folio para que no brinque al recargar.
const porFecha = (a, b) => (b.fecha || '').localeCompare(a.fecha || '') || num(b.folio) - num(a.folio)

// Junta todo en tarjetas. Entradas tal como salen de `cargarFlujo`:
//   requisiciones: [{ id, folio, estado, cantidad, fecha_pedido, created_at, sku, nombre, cotizacion, cliente }]
//   compras:       [{ id, folio, fecha, proveedor, factura, total, estado, archivo_pdf, archivo_xml }]
//   lineas:        [{ compra_id, requisicion_id, cantidad, sku, nombre }]
//   facturas:      [{ id, compra_id, serie, folio, total, fecha }]
export function armarFlujo({ requisiciones = [], compras = [], lineas = [], facturas = [] } = {}) {
  const reqPorId = new Map(requisiciones.map(r => [r.id, r]))
  const facturaDe = new Map(facturas.filter(f => f.compra_id).map(f => [f.compra_id, f]))
  const usadas = new Set()
  const flujos = []

  for (const c of compras) {
    if (c.estado === 'cancelada') continue
    const suyas = lineas.filter(l => l.compra_id === c.id)
    const pedidos = []
    for (const l of suyas) {
      if (!l.requisicion_id) continue
      usadas.add(l.requisicion_id)
      const r = reqPorId.get(l.requisicion_id)
      if (r && !pedidos.includes(r)) pedidos.push(r)
    }
    const factura = facturaDe.get(c.id) || null
    flujos.push({
      clave: `compra-${c.id}`,
      fecha: c.fecha,
      folio: c.folio,
      pedidos,
      compra: { ...c, lineas: suyas },
      factura,
      // La factura manda: si el XML llegó después de cerrarla sin factura, queda Completo.
      etapa: factura ? 'completo' : c.sin_factura_en ? 'sin_factura' : 'factura',
    })
  }

  // Pedidos vivos que ninguna compra ha recibido: esperan su nota.
  for (const r of requisiciones) {
    if (usadas.has(r.id) || !['pendiente', 'pedida'].includes(r.estado)) continue
    flujos.push({
      clave: `req-${r.id}`,
      fecha: r.fecha_pedido || (r.created_at || '').slice(0, 10),
      folio: r.folio,
      pedidos: [r],
      compra: null,
      factura: null,
      etapa: 'nota',
    })
  }

  return flujos.sort(porFecha)
}

// Cuántos hay en cada etapa, para los botones de filtro.
export function contarEtapas(flujos) {
  const n = { todos: flujos.length, nota: 0, factura: 0, completo: 0, sin_factura: 0 }
  for (const f of flujos) n[f.etapa] += 1
  return n
}

// Los tres pasos de un flujo, cada uno con palabra (nunca solo color).
export function pasosDe(flujo) {
  const { pedidos, compra, factura } = flujo
  const pedido = pedidos.length
    ? { hecho: true, titulo: pedidos.map(p => `REQ-${p.folio}`).join(', ') }
    : { hecho: true, titulo: 'Sin pedido', nota: 'Compra para el estante' }
  const nota = compra
    ? { hecho: true, titulo: `COMPRA-${compra.folio}`, nota: compra.proveedor }
    : { hecho: false, titulo: 'Esperando la nota', nota: 'Al llegar el material, regístralo en Compras ligado a este pedido' }
  let fac
  if (factura) {
    fac = { hecho: true, titulo: `Factura ${[factura.serie, factura.folio].filter(Boolean).join('') || 'ligada'}` }
  } else if (compra?.sin_factura_en) {
    fac = { hecho: true, titulo: 'Cerrado sin factura', nota: compra.sin_factura_motivo || '' }
  } else if (compra) {
    fac = { hecho: false, titulo: 'Falta la factura',
      nota: compra.factura
        ? `Sube el XML de la ${compra.factura} en Finanzas: se liga sola si el folio y el total cuadran`
        : 'Sin factura todavía: pídela al proveedor y súbela en Finanzas' }
  } else {
    fac = { hecho: false, titulo: 'Falta la factura' }
  }
  return [
    { clave: 'pedido', nombre: 'Pedido', ...pedido },
    { clave: 'nota', nombre: 'Nota', ...nota },
    { clave: 'factura', nombre: 'Factura', ...fac },
  ]
}

// ---- llamadas ----

const haceDias = dias => {
  const d = new Date()
  d.setDate(d.getDate() - dias)
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

export async function cargarFlujo(dias = 90) {
  try {
    const [cs, rs] = await Promise.all([
      supabase.from('compras')
        .select('id, folio, fecha, proveedor, factura, total, estado, archivo_pdf, archivo_xml, notas, sin_factura_motivo, sin_factura_en')
        .gte('fecha', haceDias(dias)).order('fecha', { ascending: false }),
      supabase.from('requisiciones')
        .select('id, folio, estado, cantidad, fecha_pedido, created_at, productos(sku, nombre), cotizaciones(folio, clientes(nombre))')
        .gte('created_at', haceDias(dias)),
    ])
    if (cs.error) throw cs.error
    if (rs.error) throw rs.error
    const compras = cs.data || []
    const ids = compras.map(c => c.id)
    let lineas = []
    let facturas = []
    if (ids.length) {
      const [ls, fs] = await Promise.all([
        supabase.from('compra_lineas').select('compra_id, requisicion_id, cantidad, productos(sku, nombre)').in('compra_id', ids),
        supabase.from('cfdi').select('id, compra_id, serie, folio, total, fecha').in('compra_id', ids),
      ])
      if (ls.error) throw ls.error
      if (fs.error) throw fs.error
      lineas = (ls.data || []).map(l => ({ ...l, sku: l.productos?.sku, nombre: l.productos?.nombre }))
      facturas = fs.data || []
    }
    const requisiciones = (rs.data || []).map(r => ({
      ...r,
      sku: r.productos?.sku,
      nombre: r.productos?.nombre,
      cotizacion: r.cotizaciones?.folio ?? null,
      cliente: r.cotizaciones?.clientes?.nombre ?? null,
    }))
    return { ok: true, flujos: armarFlujo({ requisiciones, compras, lineas, facturas }) }
  } catch (e) {
    return { ok: false, texto: explicarError(e).texto }
  }
}

// Cerrar un ticket que nunca tendrá factura (SQL 101). La base exige el motivo y que no tenga XML ligado.
async function llamar(nombre, args) {
  try {
    const { data, error } = await supabase.rpc(nombre, args)
    if (error) {
      const propio = ['22023', 'P0002', '42501'].includes(String(error.code)) && error.message
      return { ok: false, texto: propio || explicarError(error).texto }
    }
    return { ok: true, datos: data }
  } catch (e) {
    return { ok: false, texto: explicarError(e).texto }
  }
}

export const cerrarSinFactura = (compraId, motivo) =>
  llamar('cerrar_compra_sin_factura', { p_compra: compraId, p_motivo: motivo })

export const reabrirSinFactura = compraId =>
  llamar('reabrir_compra_sin_factura', { p_compra: compraId })
