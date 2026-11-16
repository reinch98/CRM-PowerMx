// Fase 5 de "Calculadora solar → cotización real" (16/11/2026).
//
// Una solicitud que llega de la calculadora del sitio trae su cálculo como dato
// (`solicitudes_web.calculo`, SQL 98: ya pasó por una lista blanca en la base). Aquí se
// traduce para la oficina (resumen, avisos, historial) y se convierte en las partidas de
// una cotización REAL:
//  · UNA partida visible con el precio PUBLICADO HOY del paquete (con IVA incluido, como se
//    publica: entra entre 1.16 para que la cotización termine en el precio de lista).
//  · Las piezas de la receta del paquete (paneles, inversor, estructura, protecciones…) a
//    $0 y marcadas `incluida`, CON su `producto_id`: así al aceptar la cotización se apartan
//    y se piden las que falten, igual que las refacciones del preventivo (SQL 28). El
//    paquete en sí (PKG-…) NUNCA entra con producto_id: apartaría un "paquete" que no
//    existe en el estante.
//  · Si el precio de hoy no es el que vio el cliente, se dice con los dos números.
// Las reglas puras van arriba (pruebas/calculoSolar.prueba.js); la carga, abajo.
import { supabase } from './supabase'
import { explicarError } from './errores'

const IVA = 0.16
const pesos = n => '$' + Math.round(Number(n) || 0).toLocaleString('es-MX')
const kwh = n => Math.round(Number(n) || 0).toLocaleString('es-MX') + ' kWh'
const r4 = n => Math.round(n * 10000) / 10000

// Lo que avisa la calculadora (claves del motor del sitio), dicho para la oficina.
const AVISOS = {
  dos_hilos: ['alto', 'Servicio de 2 hilos (127 V): en la visita revisar si conviene cambiarlo a dos fases con CFE o usar microinversores. Puede cambiar el precio.'],
  tarifa_especial: ['alto', 'Tarifa DAC o uso comercial: el ahorro de la calculadora es solo referencia. Conviene cotizar a la medida.'],
  a_la_medida: ['alto', 'Su consumo no cabe en el paquete más grande: hace falta un sistema a la medida.'],
  crecimiento: ['info', 'Su consumo viene creciendo más de 15 % al año: considerar el paquete de arriba.'],
  sin_kwh: ['info', 'Lo capturó a mano sin kWh: el consumo está estimado con el monto que pagó.'],
  un_recibo: ['info', 'Calculado con un solo recibo, sin el historial de 12 meses.'],
  gasto_un_recibo: ['info', 'El gasto se estimó con el costo de un solo recibo (el lector no traía los importes del historial).'],
}

export function avisosDeCalculo(c) {
  const salida = []
  for (const clave of Array.isArray(c?.avisos) ? c.avisos : []) {
    const a = AVISOS[clave]
    if (!a) continue
    let texto = a[1]
    if (clave === 'crecimiento' && Number.isFinite(Number(c.crecimiento))) {
      texto = `Su consumo creció ${Math.round(Number(c.crecimiento) * 100)} % en un año: considerar el paquete de arriba.`
    }
    salida.push({ clave, nivel: a[0], texto })
  }
  // Lo importante primero.
  return salida.sort((x, y) => (x.nivel === 'alto' ? 0 : 1) - (y.nivel === 'alto' ? 0 : 1))
}

const anios = a => {
  if (!Number.isFinite(Number(a))) return null
  const r = Math.max(0.5, Math.round(Number(a) * 2) / 2)
  return `unos ${r.toLocaleString('es-MX')} ${r === 1 ? 'año' : 'años'}`
}

// El cálculo en renglones legibles. Solo lo que trae.
export function resumenCalculo(c) {
  if (!c || !(Number(c.kwh_mes) > 0)) return []
  const p = c.paquete || {}
  const filas = [
    ['Consumo promedio', `${kwh(c.kwh_mes)} al mes${Number(c.dias) >= 300 ? ' (12 meses de recibos)' : ''}`],
    ['Paga hoy de luz', Number(c.gasto_mes) > 0 ? `${pesos(c.gasto_mes)} al mes` : null],
    ['Costo por kWh', Number(c.tarifa_efectiva) > 0
      ? `$${Number(c.tarifa_efectiva).toFixed(2)}${c.tarifa ? ` · tarifa ${c.tarifa}` : ''}`
      : (c.tarifa ? `Tarifa ${c.tarifa}` : null)],
    ['Servicio', c.hilos ? `${c.hilos} hilos${Number(c.hilos) === 2 ? ' (127 V)' : ''}` : null],
    ['Recibo', c.servicio_ult4 ? `Número de servicio terminado en ${c.servicio_ult4}` : null],
    ['De dónde salió', c.fuente === 'recibo' ? 'Leído de su recibo' : c.fuente === 'manual' ? 'Lo escribió a mano' : null],
    ['Paquete que vio', p.sku
      ? `${p.nombre || p.sku}${p.paneles ? ` · ${p.paneles} paneles` : ''}${p.kw ? ` · ${Number(p.kw).toLocaleString('es-MX')} kWp` : ''}${p.precio ? ` · ${pesos(p.precio)} con IVA` : ''}`
      : (c.a_la_medida ? 'Ninguno: sistema a la medida' : null)],
    ['Ahorro que vio', Number(p.ahorro_mes) > 0
      ? `${pesos(p.ahorro_mes)} al mes${anios(p.retorno_anios) ? ` · se paga en ${anios(p.retorno_anios)}` : ''}`
      : null],
  ]
  return filas.filter(([, v]) => v).map(([etiqueta, valor]) => ({ etiqueta, valor }))
}

// El historial como barras: del más reciente al más viejo, con su largo relativo al mayor.
export function barrasHistorial(historial) {
  const lista = (Array.isArray(historial) ? historial : []).filter(h => Number(h?.kwh) > 0)
  if (!lista.length) return []
  const max = Math.max(...lista.map(h => Number(h.kwh)))
  return lista.map((h, i) => {
    const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(h.fin || '')
    return {
      etiqueta: m ? `Al ${m[3]}/${m[2]}/${m[1].slice(2)}` : `Periodo ${i + 1}`,
      kwh: Number(h.kwh),
      importe: Number(h.importe) > 0 ? Number(h.importe) : null,
      pct: Math.max(2, Math.round((Number(h.kwh) / max) * 100)),
    }
  })
}

export const VARIANTES = {
  interconectado: { precio: 'estandar', nombre: 'interconectado', lineas: ['interconectado'] },
  respaldo: { precio: 'hibrido', nombre: 'con respaldo en apagones (híbrido)', lineas: ['interconectado', 'respaldo'] },
}

export function precioDeVariante(producto, variante = 'interconectado') {
  const v = VARIANTES[variante]
  if (!v || !producto) return null
  const n = Number(producto.precios?.[v.precio] ?? (variante === 'interconectado' ? producto.precio : null))
  return Number.isFinite(n) && n > 0 ? n : null
}

// Qué incluye el paquete, de su descripción (renglones separados con "|", como en Inventario).
const incluyeDe = producto => String(producto?.descripcion || '')
  .split('|').map(t => t.trim()).filter(Boolean)

/**
 * Las partidas de la cotización. `producto` es el paquete (categoría paquete_solar) con
 * `precios`; `lineas` su receta ({variante, cantidad, producto: {id, sku, nombre, unidad}}).
 * Devuelve { partidas, avisos, precioHoy, cambio } o { error }.
 */
export function partidasDePaqueteSolar({ producto, lineas = [], variante = 'interconectado', calculo = null }) {
  const v = VARIANTES[variante]
  if (!v) return { error: 'Variante de paquete no válida.' }
  if (!producto) return { error: 'No encontramos el paquete en el catálogo.' }
  const precioHoy = precioDeVariante(producto, variante)
  if (!precioHoy) return { error: `El paquete ${producto.nombre || producto.sku} no tiene precio publicado ${v.nombre}.` }

  const incluye = incluyeDe(producto)
  const kw = Number(producto.atributos?.kw)
  const paneles = Number(producto.atributos?.paneles)
  const partidas = [{
    producto_id: null,
    sku: producto.sku,
    servicio: 'paquete_solar',
    variante,
    descripcion: `Sistema solar ${v.nombre} — paquete ${producto.nombre}`
      + (paneles > 0 ? `: ${paneles} paneles` : '')
      + (kw > 0 ? ` (${kw.toLocaleString('es-MX')} kWp)` : '')
      + (incluye.length ? `. Incluye: ${incluye.join('; ')}.` : '.'),
    unidad: 'sistema',
    cantidad: 1,
    // Publicado con IVA: entre 1.16 para que el total de la cotización sea el de lista.
    precio_unitario: r4(precioHoy / (1 + IVA)),
  }]

  // Piezas de la receta: una partida por producto, sumando si aparece en varias líneas.
  const porProducto = new Map()
  for (const l of lineas) {
    if (!v.lineas.includes(l?.variante)) continue
    const p = l.producto
    if (!p?.id || !(Number(l.cantidad) > 0)) continue
    const previa = porProducto.get(p.id)
    if (previa) previa.cantidad = r4(previa.cantidad + Number(l.cantidad))
    else {
      porProducto.set(p.id, {
        producto_id: p.id,
        sku: p.sku,
        descripcion: p.nombre,
        unidad: p.unidad || 'pieza',
        cantidad: Number(l.cantidad),
        precio_unitario: 0,
        incluida: true,
      })
    }
  }
  partidas.push(...porProducto.values())

  const avisos = []
  if (!porProducto.size) {
    avisos.push('La receta del paquete no tiene piezas del catálogo: al aceptar no se apartará material. Revisa Paquetes solares.')
  }
  const inactivas = lineas.filter(l => v.lineas.includes(l?.variante) && l.producto && l.producto.activo === false)
  if (inactivas.length) {
    avisos.push(`La receta usa ${inactivas.length === 1 ? 'una pieza dada de baja' : `${inactivas.length} piezas dadas de baja`}: ${inactivas.map(l => l.producto.sku).join(', ')}.`)
  }

  // ¿Cambió el precio desde que el cliente lo vio? Solo se compara la misma variante que vio.
  let cambio = null
  const visto = Number(calculo?.paquete?.precio)
  if (calculo?.paquete?.sku === producto.sku && variante === (calculo.paquete.variante || 'interconectado')
      && visto > 0 && Math.abs(visto - precioHoy) >= 1) {
    cambio = { visto, hoy: precioHoy, diferencia: precioHoy - visto }
  }

  return { partidas, avisos, precioHoy, cambio }
}

export function textoCambio(cambio) {
  if (!cambio) return ''
  const sube = cambio.diferencia > 0
  return `El cliente vio ${pesos(cambio.visto)} y hoy el paquete cuesta ${pesos(cambio.hoy)} `
    + `(${sube ? 'sube' : 'baja'} ${pesos(Math.abs(cambio.diferencia))}). La cotización va con el precio de hoy.`
}

// Los datos para dar de alta al cliente, si todavía no existe.
export function clienteDeSolicitud(s, calculo) {
  return {
    nombre: String(s?.nombre || '').trim(),
    telefono: String(s?.telefono || '').trim(),
    email: String(s?.email || '').trim(),
    direccion: String(s?.ubicacion || '').trim(),
    municipio: '',
    tipo_cliente: ['residencial', 'comercial', 'industrial'].includes(calculo?.tipo) ? calculo.tipo : 'residencial',
    distancia_km: '',
  }
}

// La nota interna de la cotización: de dónde salió y lo que hay que revisar en la visita.
export function notasDeSolicitud(s, calculo) {
  const fecha = s?.created_at ? new Date(s.created_at).toLocaleDateString('es-MX') : ''
  const partes = [`Solicitud del sitio (calculadora solar)${fecha ? ` del ${fecha}` : ''}: ${s?.nombre || ''} · ${s?.telefono || ''}.`]
  for (const f of resumenCalculo(calculo)) partes.push(`${f.etiqueta}: ${f.valor}.`)
  for (const a of avisosDeCalculo(calculo)) partes.push(`${a.nivel === 'alto' ? 'IMPORTANTE' : 'Nota'}: ${a.texto}`)
  return partes.join('\n')
}

// ---- carga ----

export async function cargarPaqueteParaCotizar(sku) {
  try {
    const { data: producto, error } = await supabase.from('productos')
      .select('id, sku, nombre, descripcion, precio, precios, atributos, categoria, activo')
      .eq('sku', sku).maybeSingle()
    if (error) return { error: explicarError(error).texto }
    if (!producto || producto.categoria !== 'paquete_solar') return { error: `No encontramos el paquete ${sku} en el catálogo.` }
    const r = await supabase.from('paquete_solar_lineas')
      .select('variante, orden, cantidad, producto:productos!producto_id(id, sku, nombre, unidad, activo)')
      .eq('paquete_id', producto.id).order('variante').order('orden')
    if (r.error) return { error: explicarError(r.error).texto }
    return { producto, lineas: r.data || [] }
  } catch (e) {
    return { error: explicarError(e).texto }
  }
}

export async function ligarSolicitudACotizacion(solicitudId, cotizacionId) {
  try {
    const { data, error } = await supabase.rpc('ligar_solicitud_a_cotizacion', {
      p_solicitud: solicitudId, p_cotizacion: cotizacionId,
    })
    if (error) return { ok: false, texto: error.message || explicarError(error).texto }
    return { ok: true, folio: data?.folio }
  } catch (e) {
    return { ok: false, texto: explicarError(e).texto }
  }
}
