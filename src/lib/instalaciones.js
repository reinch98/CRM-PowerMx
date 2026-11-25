// Cotizador de instalaciones (SQL 104): de la lista de materiales y mano de obra a las partidas
// de una cotización.
//
// Nada de esto está en el catálogo, así que todas las partidas salen LIBRES (sin producto_id):
// no apartan inventario ni generan pedidos, igual que el diagnóstico y el traslado.
//
// La cantidad de cada renglón sale de la distancia:
//     cantidad = cantidad_fija + por_metro × max(0, metros − metros_incluidos), hacia arriba.
// En cada cotización se puede escribir otra cantidad a mano; eso manda sobre la sugerida.
import { supabase } from './supabase'

export const BLOQUES = [
  { clave: 'electrica', titulo: 'Instalación eléctrica', metros: true,
    ayudaMetros: 'Metros del generador al interruptor principal (o a la transferencia).' },
  { clave: 'gas', titulo: 'Instalación de gas', metros: true,
    ayudaMetros: 'Metros del tanque (o la toma de gas) al generador.' },
  { clave: 'base', titulo: 'Base de concreto', metros: false },
  { clave: 'otro', titulo: 'Equipos y extras', metros: false },
]

export const METROS_INICIALES = 15

const num = v => {
  const n = Number(v)
  return Number.isFinite(n) ? n : 0
}
const redondear2 = v => Math.round(v * 100) / 100

export const pesos = v => num(v).toLocaleString('es-MX', { style: 'currency', currency: 'MXN' })

// Hacia arriba, pero redondeando antes a centésimos: 0.3333 × 15 = 4.9995 son 5 tubos, no 6.
export function cantidadSugerida(m, metros) {
  const extra = Math.max(0, num(metros) - num(m.metros_incluidos))
  const bruto = redondear2(num(m.cantidad_fija) + num(m.por_metro) * extra)
  return Math.ceil(bruto)
}

export function materialesDe(materiales, bloque) {
  return (materiales || [])
    .filter(m => m.activo !== false && m.bloque === bloque)
    .sort((a, b) => num(a.orden) - num(b.orden) || String(a.nombre).localeCompare(String(b.nombre)))
}

// Los grupos de un bloque (opciones que se excluyen) con sus opciones.
export function gruposDe(materiales, bloque) {
  const grupos = {}
  for (const m of materialesDe(materiales, bloque)) {
    if (!m.grupo) continue
    if (!grupos[m.grupo]) grupos[m.grupo] = []
    grupos[m.grupo].push(m)
  }
  return grupos
}

export const ETIQUETA_GRUPO = { cable_fuerza: 'Cable de fuerza', tuberia: 'Tubería' }
export const etiquetaGrupo = g => ETIQUETA_GRUPO[g] || g.replace(/_/g, ' ')

export function estadoInicial(materiales) {
  const estado = {}
  for (const b of BLOQUES) {
    const elecciones = {}
    for (const [g, ops] of Object.entries(gruposDe(materiales, b.clave))) {
      elecciones[g] = (ops.find(o => o.predeterminado) || ops[0]).id
    }
    estado[b.clave] = { activo: false, metros: b.metros ? METROS_INICIALES : 0, elecciones, cantidades: {}, precios: {} }
  }
  return estado
}

// Los renglones de un bloque con su cantidad. Un renglón de un grupo solo entra si es el elegido.
export function lineasDeBloque(materiales, bloque, eb) {
  const metros = BLOQUES.find(b => b.clave === bloque)?.metros ? num(eb?.metros) : 0
  return materialesDe(materiales, bloque)
    .filter(m => !m.grupo || eb?.elecciones?.[m.grupo] === m.id)
    .map(m => {
      const sugerida = cantidadSugerida(m, metros)
      const manual = eb?.cantidades?.[m.id]
      const hayManual = manual !== undefined && manual !== ''
      const cantidad = hayManual ? Math.max(0, num(manual)) : sugerida
      // La mano de obra se puede cobrar distinto en cada cotización (el trabajo nunca es igual);
      // los materiales siempre con su precio de lista.
      const precioManual = m.tipo === 'mano_obra' ? eb?.precios?.[m.id] : undefined
      const hayPrecio = precioManual !== undefined && precioManual !== ''
      const precio = hayPrecio ? Math.max(0, num(precioManual)) : num(m.precio)
      return {
        material: m, sugerida, cantidad, manual: hayManual, precio, precioManual: hayPrecio,
        importe: redondear2(cantidad * precio),
        costo: m.costo == null ? null : redondear2(cantidad * num(m.costo)),
      }
    })
}

export function totalesDeLineas(lineas) {
  let materiales = 0, manoObra = 0, costo = 0, sinCosto = 0
  for (const l of lineas) {
    if (!l.cantidad) continue
    if (l.material.tipo === 'mano_obra') manoObra += l.importe
    else {
      materiales += l.importe
      if (l.costo == null) sinCosto += l.importe
      else costo += l.costo
    }
  }
  return {
    materiales: redondear2(materiales), manoObra: redondear2(manoObra),
    total: redondear2(materiales + manoObra),
    // Solo de los materiales con costo capturado: la utilidad de los que no lo tienen no se inventa.
    costo: redondear2(costo), sinCosto: redondear2(sinCosto),
  }
}

const partidaLibre = (bloque, descripcion, cantidad, precio, unidad) => ({
  producto_id: null, sku: '', instalacion: bloque, unidad,
  descripcion, cantidad, precio_unitario: redondear2(precio),
})

// En el texto que ve el cliente solo se dicen los metros (cable, tubería por metro); el número de
// piezas no se menciona: es detalle de armado, no algo que el cliente necesite revisar.
// La tubería se compra en tramos (piezas) pero se dice en metros de recorrido.
function conMetros(l, metros) {
  if (l.material.unidad === 'm') return `${l.material.nombre} (${l.cantidad} m)`
  if (l.material.grupo === 'tuberia' && num(metros) > 0) return `${l.material.nombre} (${num(metros)} m)`
  return l.material.nombre
}

export function textoMateriales(bloque, metros, lineas) {
  const lista = lineas.map(l => conMetros(l, metros)).join(', ')
  if (bloque === 'electrica') {
    return `Materiales p/ instalación eléctrica: se consideran hasta ${num(metros)} m del generador al interruptor principal. Incluye: ${lista}.`
  }
  if (bloque === 'gas') {
    return `Materiales p/ instalación de gas: se consideran hasta ${num(metros)} m de distancia del tanque al generador. Incluye: ${lista}.`
  }
  return `Materiales: ${lista}.`
}

// Las partidas de la cotización. Por omisión, como se cotizaba en el Excel: los materiales de
// cada instalación en UNA partida que dice qué incluye y hasta cuántos metros, y la mano de obra
// en otra. Con `desglosar`, una partida por material. Base y extras van siempre uno por uno.
export function partidasDeInstalacion({ materiales, estado, desglosar = false }) {
  const partidas = []
  for (const b of BLOQUES) {
    const eb = estado?.[b.clave]
    if (!eb?.activo) continue
    const lineas = lineasDeBloque(materiales, b.clave, eb).filter(l => l.cantidad > 0)
    if (!lineas.length) continue

    if (desglosar || !b.metros) {
      for (const l of lineas) {
        partidas.push(partidaLibre(b.clave, l.material.descripcion || l.material.nombre,
          l.cantidad, l.precio, l.material.unidad))
      }
      continue
    }

    const mats = lineas.filter(l => l.material.tipo !== 'mano_obra')
    const mano = lineas.filter(l => l.material.tipo === 'mano_obra')
    if (mats.length) {
      partidas.push(partidaLibre(b.clave, textoMateriales(b.clave, eb.metros, mats), 1,
        totalesDeLineas(mats).total, 'lote'))
    }
    if (mano.length) {
      const principal = mano[0].material
      let texto = principal.descripcion || principal.nombre
      if (mano.length > 1) texto += ` Se consideran hasta ${num(eb.metros)} m.`
      partidas.push(partidaLibre(b.clave, texto, 1, totalesDeLineas(mano).total, 'servicio'))
    }
  }
  return partidas
}

// Nota interna para la cotización: qué se eligió y cuánto cuesta, sin que el cliente lo vea.
export function notasDeInstalacion({ materiales, estado }) {
  const renglones = ['Armada con el cotizador de instalaciones.']
  let costo = 0, sinCosto = 0
  for (const b of BLOQUES) {
    const eb = estado?.[b.clave]
    if (!eb?.activo) continue
    const t = totalesDeLineas(lineasDeBloque(materiales, b.clave, eb))
    if (!t.total) continue
    costo += t.costo; sinCosto += t.sinCosto
    renglones.push(`${b.titulo}${b.metros ? ` (${num(eb.metros)} m)` : ''}: ${pesos(t.total)} sin IVA.`)
  }
  if (costo > 0) {
    renglones.push(`Costo conocido de materiales: ${pesos(costo)}${sinCosto > 0 ? ` (sin costo capturado: ${pesos(sinCosto)} en precio)` : ''}.`)
  }
  return renglones.join('\n')
}

// ---------------------------------------------------------------------------------------------
// Base de datos (solo admin).

export async function cargarMateriales() {
  const { data, error } = await supabase.from('materiales_instalacion')
    .select('*').order('bloque').order('orden')
  return { materiales: data || [], error: error?.message || null }
}

const CAMPOS = ['bloque', 'tipo', 'nombre', 'descripcion', 'unidad', 'costo', 'precio',
  'cantidad_fija', 'por_metro', 'metros_incluidos', 'grupo', 'predeterminado', 'orden', 'activo']
const NUMERICOS = ['costo', 'precio', 'cantidad_fija', 'por_metro', 'metros_incluidos', 'orden']

// Lo que se guarda: números como número, vacíos como null (Postgres no acepta '' en numéricos).
export function paraGuardarMaterial(form) {
  const fila = {}
  for (const c of CAMPOS) {
    let v = form[c]
    if (NUMERICOS.includes(c)) v = v === '' || v == null ? null : Number(v)
    else if (typeof v === 'string') v = v.trim() || null
    fila[c] = v
  }
  for (const c of ['cantidad_fija', 'por_metro', 'metros_incluidos', 'orden']) fila[c] = fila[c] ?? 0
  fila.unidad = fila.unidad || 'pza'
  fila.tipo = fila.tipo || 'material'
  fila.predeterminado = !!fila.predeterminado && !!fila.grupo
  fila.activo = fila.activo !== false
  return fila
}

export function problemasDeMaterial(form) {
  const p = []
  if (!String(form.nombre || '').trim()) p.push('Escribe el nombre.')
  if (form.precio === '' || form.precio == null || !(Number(form.precio) >= 0)) p.push('Escribe el precio (sin IVA).')
  for (const c of ['costo', 'cantidad_fija', 'por_metro', 'metros_incluidos']) {
    if (form[c] !== '' && form[c] != null && !(Number(form[c]) >= 0)) p.push('Las cantidades y el costo no pueden ser negativos.')
  }
  return [...new Set(p)]
}

const claveNueva = (bloque, nombre) =>
  `${bloque}_${String(nombre).normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
    .replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '').slice(0, 40)}_${Date.now().toString(36)}`

export async function guardarMaterial(form, id) {
  const fila = paraGuardarMaterial(form)
  // Solo una predeterminada por grupo: la nueva le quita la marca a las demás.
  if (fila.predeterminado) {
    let q = supabase.from('materiales_instalacion').update({ predeterminado: false })
      .eq('bloque', fila.bloque).eq('grupo', fila.grupo)
    if (id) q = q.neq('id', id)
    const { error } = await q
    if (error) return { error: error.message }
  }
  const { error } = id
    ? await supabase.from('materiales_instalacion').update(fila).eq('id', id)
    : await supabase.from('materiales_instalacion').insert({ ...fila, clave: claveNueva(fila.bloque, fila.nombre) })
  return { error: error?.message || null }
}
