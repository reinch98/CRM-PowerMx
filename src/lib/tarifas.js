// ---------------------------------------------------------------------------
// Precio del diagnóstico, del traslado y de los servicios de catálogo. Funciones
// puras: reciben las tarifas ya cargadas y devuelven qué partidas armar y qué
// avisar. Las tarifas viven en la tabla `tarifas_servicio` (solo admin) y aquí
// solo se COPIAN a la cotización.
//
//   diagnóstico: depende de la CLASE del equipo y de su capacidad. Se carga con el
//                botón "Cargar diagnóstico y traslado".
//   traslado:    precio fijo por km, solo ida. Aplica desde los 40 km y, una vez
//                rebasados, se cobran TODOS los km (no solo los que pasan de 40).
//   catálogo:    correctivo, preventivo, instalación de gas o eléctrica, u otro. A
//                diferencia de los dos anteriores, cada uno tiene su propio SKU y se
//                busca y se agrega a la cotización igual que un producto (21_tarifas_catalogo.sql).
//                Sigue siendo una partida LIBRE (sin producto_id): no mueve inventario.
// ---------------------------------------------------------------------------

const KM_DESDE_POR_DEFECTO = 40

export const CLASES = [
  ['gasolina', 'Gasolina'],
  ['gas_lp', 'Gas LP / natural'],
  ['diesel', 'Diésel'],
  ['solar', 'Solar'],
  ['bateria', 'Baterías']
]

const NOMBRE_CLASE = Object.fromEntries(CLASES)

// Clase de precio de un equipo. El gas natural entra con el gas LP.
export function claseDeEquipo(equipo) {
  if (!equipo) return null
  if (equipo.tipo === 'solar') return 'solar'
  if (equipo.tipo === 'bateria') return 'bateria'
  if (equipo.tipo === 'generador') {
    const c = equipo.atributos?.combustible
    if (c === 'gasolina') return 'gasolina'
    if (c === 'gas_lp' || c === 'gas_natural') return 'gas_lp'
    if (c === 'diesel') return 'diesel'
  }
  return null
}

// Capacidad con la que se busca el tramo. Generadores y solares se miden en kW;
// las baterías en kWh (los tramos de la tabla usan la misma columna para ambas).
export function capacidadDeEquipo(equipo) {
  if (!equipo) return null
  const candidatos = [equipo.capacidad_kw]
  if (equipo.tipo === 'solar') candidatos.push(equipo.atributos?.potencia_inversor_kw)
  if (equipo.tipo === 'bateria') candidatos.push(equipo.atributos?.capacidad_kwh)
  for (const v of candidatos) {
    const n = Number(v)
    if (v !== '' && v != null && Number.isFinite(n) && n > 0) return n
  }
  return null
}

const num = v => (v === '' || v == null ? null : Number(v))

// Tarifa de diagnóstico que corresponde a esa clase y capacidad. Si dos tramos
// coinciden, gana el más específico (el que empieza más arriba).
export function tarifaDiagnostico(tarifas, clase, capacidad) {
  if (!clase || capacidad == null) return null
  const coinciden = (tarifas || []).filter(t => {
    if (!t.activo || t.concepto !== 'diagnostico' || t.clase !== clase) return false
    const desde = num(t.kw_desde), hasta = num(t.kw_hasta)
    return (desde == null || capacidad >= desde) && (hasta == null || capacidad <= hasta)
  })
  coinciden.sort((a, b) => (num(b.kw_desde) ?? -Infinity) - (num(a.kw_desde) ?? -Infinity))
  return coinciden[0] || null
}

export function tarifaTraslado(tarifas) {
  return (tarifas || []).find(t => t.activo && t.concepto === 'traslado') || null
}

const redondear = n => Math.round(n * 100) / 100

// Arma las partidas de un diagnóstico para ese equipo y cliente. Devuelve
// { partidas, avisos }: si falta un dato o una tarifa, no inventa un precio; deja la
// partida (o nada) y explica qué falta.
export function partidasDeDiagnostico({ tarifas, equipo, cliente }) {
  const partidas = []
  const avisos = []

  if (!equipo) {
    avisos.push('Elige el equipo: el precio del diagnóstico depende de su clase y capacidad.')
  } else {
    const clase = claseDeEquipo(equipo)
    const capacidad = capacidadDeEquipo(equipo)
    if (!clase) {
      avisos.push('No se pudo saber la clase del equipo (en generadores falta elegir el combustible en Equipos). Captura el precio a mano.')
    } else if (capacidad == null) {
      avisos.push('Al equipo le falta la capacidad. Captura el precio a mano o completa el equipo.')
    }
    const tarifa = clase && capacidad != null ? tarifaDiagnostico(tarifas, clase, capacidad) : null
    if (clase && capacidad != null && !tarifa) {
      avisos.push(`No hay tarifa de diagnóstico para ${NOMBRE_CLASE[clase] || clase} de ${capacidad} kW. Captúrala en Tarifas o pon el precio a mano.`)
    }
    partidas.push({
      producto_id: null, sku: '', servicio: 'diagnostico', unidad: 'servicio', cantidad: 1,
      descripcion: `Servicio de diagnóstico${clase ? ` — ${NOMBRE_CLASE[clase]}` : ''}${capacidad != null ? ` ${capacidad} kW` : ''}`,
      precio_unitario: tarifa ? Number(tarifa.precio) : ''
    })
  }

  const km = num(cliente?.distancia_km)
  const traslado = tarifaTraslado(tarifas)
  if (km == null || !Number.isFinite(km)) {
    avisos.push('El cliente no tiene la distancia capturada (km). Sin ella no se puede calcular el traslado.')
  } else if (!traslado) {
    avisos.push('No hay tarifa de traslado capturada en Tarifas.')
  } else {
    const desde = num(traslado.km_desde) ?? KM_DESDE_POR_DEFECTO
    if (km >= desde) {
      partidas.push({
        producto_id: null, sku: '', servicio: 'traslado', unidad: 'km',
        descripcion: `Servicio de traslado (${km} km, solo ida)`,
        cantidad: km, precio_unitario: Number(traslado.precio)
      })
    }
  }

  return { partidas, avisos }
}

// Importe de una línea, redondeado a centavos.
export const importe = (cantidad, precio) => redondear(Number(cantidad || 0) * Number(precio || 0))

// ---------------------------------------------------------------------------
// Tarifas de catálogo: correctivo, preventivo, instalación de gas o eléctrica, u
// otro. Cada una tiene su propio SKU (21_tarifas_catalogo.sql) y se agrega a una
// cotización buscándola, igual que un producto — nunca con una fórmula.
// ---------------------------------------------------------------------------

export const CONCEPTOS_CATALOGO = [
  ['correctivo', 'Servicio correctivo'],
  // Menor y mayor son dos servicios con precio propio, tabulado por clase y tramo de kW
  // (SQL 28). `preventivo` a secas se queda para lo que ya estuviera capturado.
  ['preventivo_menor', 'Mantenimiento menor'],
  ['preventivo_mayor', 'Mantenimiento mayor'],
  ['preventivo', 'Mantenimiento preventivo'],
  ['instalacion_gas', 'Instalación de gas'],
  ['instalacion_electrica', 'Instalación eléctrica'],
  ['otro', 'Otro servicio']
]
const NOMBRE_CONCEPTO_CATALOGO = Object.fromEntries(CONCEPTOS_CATALOGO)
const CONCEPTOS_FORMULA = ['diagnostico', 'traslado']

export const esConceptoCatalogo = concepto => !CONCEPTOS_FORMULA.includes(concepto)

// Cómo se ve una tarifa de catálogo: su nombre (si lo capturaron a mano, como en
// "otro"), o el concepto más la clase y el tramo si aplican
// ("Servicio correctivo — Gas LP / natural, 8–26 kW").
export function nombreTarifaCatalogo(t) {
  if (t.nombre) return t.nombre
  const base = NOMBRE_CONCEPTO_CATALOGO[t.concepto] || t.concepto
  const partes = []
  if (t.clase) partes.push(NOMBRE_CLASE[t.clase] || t.clase)
  if (t.kw_desde != null || t.kw_hasta != null) partes.push(`${t.kw_desde ?? '…'}–${t.kw_hasta ?? '…'} kW`)
  return partes.length ? `${base} — ${partes.join(', ')}` : base
}

// Las tarifas que se pueden buscar y agregar por SKU: todas menos diagnóstico y
// traslado, que se cargan aparte porque dependen de una fórmula.
export function tarifasDeCatalogo(tarifas) {
  return (tarifas || [])
    .filter(t => t.activo && t.sku && esConceptoCatalogo(t.concepto))
    .map(t => ({ id: t.id, sku: t.sku, nombre: nombreTarifaCatalogo(t), precio: Number(t.precio) }))
}

const ABREV_CONCEPTO = {
  correctivo: 'COR', preventivo: 'PRE',
  preventivo_menor: 'PMEN', preventivo_mayor: 'PMAY',
  instalacion_gas: 'INSGAS', instalacion_electrica: 'INSELEC', otro: 'SERV'
}
const ABREV_CLASE = { gasolina: 'GAS', gas_lp: 'GLP', diesel: 'DIE', solar: 'SOL', bateria: 'BAT' }

// Propone un SKU a partir del concepto y, si la hay, la clase. Es solo una sugerencia
// editable: si dos tramos de la misma clase comparten concepto, hay que diferenciarla
// a mano (la base exige que el SKU sea único).
export function sugerirSkuTarifa(concepto, clase) {
  const base = ABREV_CONCEPTO[concepto] || 'SERV'
  return clase ? `SRV-${base}-${ABREV_CLASE[clase] || clase.toUpperCase()}` : `SRV-${base}`
}
