import { useEffect, useMemo, useState } from 'react'
import { supabase } from './lib/supabase'
import { hoyLocal, sumarDias } from './lib/fechas'
import { partidasDeDiagnostico, tarifasDeCatalogo } from './lib/tarifas'
import {
  TIPOS_PREVENTIVO, cargarPaquete, opcionSugerida, problemasDelPaquete,
  faltantes, partidasDePreventivo, esIncluida
} from './lib/preventivo'
import { Alerta } from './ui'

const IVA = 0.16

// Tipos que abren cita y orden al aceptarse. Venta, refacciones y renta solo si
// se marca "requiere visita".
const TIPOS_CON_VISITA = ['instalacion', 'mantenimiento', 'diagnostico']

const ESTADOS = [
  ['borrador', 'Borrador'],
  ['enviada', 'Enviada'],
  ['aceptada', 'Aceptada'],
  ['rechazada', 'Rechazada'],
  ['vencida', 'Vencida']
]

const TIPOS = [
  ['venta', 'Venta de equipo'],
  ['instalacion', 'Instalación'],
  ['mantenimiento', 'Mantenimiento'],
  ['diagnostico', 'Diagnóstico'],
  ['refacciones', 'Refacciones'],
  ['renta', 'Renta']
]

const CONDICIONES = `Precios en pesos mexicanos, más IVA.
Tiempo de entrega sujeto a existencia al momento de la aprobación.
Anticipo del 60% para iniciar, saldo contra entrega.
La instalación incluye 30 m de panel a inversor y 10 m de inversor a la conexión.`

const num = v => (v === '' || v == null ? 0 : Number(v))
const pesos = v =>
  Number(v || 0).toLocaleString('es-MX', { style: 'currency', currency: 'MXN' })

// Función y no objeto: la fecha se calcula al abrir el formulario, no al
// cargar la app, que puede llevar días abierta.
const vacio = () => ({
  cliente_id: '',
  equipo_id: '',
  fecha: hoyLocal(),
  vigencia_dias: 15,
  tipo: 'venta',
  descuento: '',
  requiere_visita: false,
  condiciones: CONDICIONES,
  notas_internas: '',
  // Programación propuesta: se vuelve cita real al aceptar la cotización.
  prog_fecha: '',
  prog_hora: '09:00',
  prog_duracion_min: 120,
  prog_tecnico_id: '',
  prog_tecnico2_id: ''
})

// ---------------------------------------------------------------------------
// Mantenimiento preventivo de un equipo (SQL 28).
//
// El cliente ve UN precio: el del servicio, fijo y tabulado por clase y capacidad. Las
// refacciones entran a cero y marcadas como incluidas — así no se cobran dos veces pero
// **sí apartan inventario**, porque apartar solo mira el producto y la cantidad.
//
// Lo que cambia de un equipo a otro no es el precio sino qué código se usa: cada línea
// trae el original y sus genéricos con lo disponible de cada uno, y aquí se elige.
// ---------------------------------------------------------------------------
function PreventivoDeEquipo({ equipoId, onAgregar }) {
  const [tipo, setTipo] = useState('menor')
  const [paquete, setPaquete] = useState(null)
  const [elegidas, setElegidas] = useState({})
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')

  if (!equipoId) return null

  async function consultar(cual = tipo) {
    setOcupado(true); setError(''); setPaquete(null); setElegidas({})
    const r = await cargarPaquete(equipoId, cual)
    setOcupado(false)
    if (!r.ok) return setError(r.texto)
    setPaquete(r.paquete)
  }

  const problemas = paquete ? problemasDelPaquete(paquete, elegidas) : []
  const porComprar = paquete ? faltantes(paquete, elegidas) : []
  const sePuede = paquete?.servicio && problemas.length === 0

  return (
    <details className="tarjeta" style={{ marginTop: 12 }}>
      <summary className="resumen">＋ Mantenimiento preventivo de este equipo</summary>

      <div className="fila" style={{ marginTop: 10 }}>
        {TIPOS_PREVENTIVO.map(([v, t]) => (
          <button key={v} type="button" className={tipo === v ? 'btn-primario' : undefined}
            aria-pressed={tipo === v}
            onClick={() => { setTipo(v); consultar(v) }}>
            {t}
          </button>
        ))}
      </div>

      {ocupado && <p className="ayuda">Buscando el paquete…</p>}
      {error && <Alerta tipo="error">{error}</Alerta>}

      {paquete && !paquete.servicio && (
        <Alerta tipo="aviso" palabra="No se puede">{paquete.falta}</Alerta>
      )}

      {paquete?.servicio && (
        <>
          <p style={{ margin: '10px 0 4px' }}>
            <strong>{paquete.servicio.nombre}</strong> — {pesos(paquete.servicio.precio)}
          </p>
          <p className="ayuda">
            Precio fijo. Las refacciones de abajo van incluidas: no se le cobran aparte,
            pero sí se apartan del inventario al aceptar la cotización.
          </p>

          {paquete.falta && <Alerta tipo="aviso" palabra="Ojo">{paquete.falta}</Alerta>}

          {(paquete.lineas || []).map(l => {
            const sugerida = opcionSugerida(l)
            const valor = elegidas[l.linea_id] ?? sugerida?.producto_id ?? ''
            const elegida = (l.opciones || []).find(o => o.producto_id === valor)
            const corta = elegida && Number(elegida.disponible) < Number(l.cantidad)
            return (
              <div key={l.linea_id} className="refaccion">
                <strong>{l.cantidad} × {l.descripcion}</strong>
                {(l.opciones || []).length === 0 ? (
                  <span className="ayuda">Sin ningún código capturado para esta pieza.</span>
                ) : (
                  <label className="campo">
                    <span>Con qué código</span>
                    <select value={valor}
                      onChange={e => setElegidas({ ...elegidas, [l.linea_id]: e.target.value })}>
                      {l.opciones.map(o => (
                        <option key={o.producto_id} value={o.producto_id}>
                          {o.sku} — {o.nombre} · hay {o.disponible}{o.preferido ? ' · original' : ''}
                        </option>
                      ))}
                    </select>
                  </label>
                )}
                {corta && (
                  <span className="ayuda">
                    Solo hay {elegida.disponible} y se necesitan {l.cantidad}. Se puede
                    cotizar igual: al aceptar se genera la requisición por lo que falte.
                  </span>
                )}
              </div>
            )
          })}

          {porComprar.length > 0 && (
            <Alerta tipo="aviso" palabra="Habrá que pedir">
              {porComprar.map(f => `${f.falta} × ${f.sku}`).join(' · ')}
            </Alerta>
          )}
          {problemas.length > 0 && <Alerta tipo="aviso" palabra="Falta">{problemas.join(' ')}</Alerta>}

          <button type="button" className="btn-primario" disabled={!sePuede}
            onClick={() => { onAgregar(partidasDePreventivo(paquete, elegidas)); setPaquete(null) }}>
            Agregar a la cotización
          </button>
        </>
      )}
    </details>
  )
}

export default function Cotizaciones({ irA }) {
  const [vista, setVista] = useState('lista')
  const [cotizaciones, setCotizaciones] = useState([])
  const [clientes, setClientes] = useState([])
  const [equipos, setEquipos] = useState([])
  const [productos, setProductos] = useState([])
  const [disponibles, setDisponibles] = useState([])
  const [tecnicos, setTecnicos] = useState([])
  const [tarifas, setTarifas] = useState([])
  const [citas, setCitas] = useState([])      // citas ligadas a cotizaciones
  const [avisosDiag, setAvisosDiag] = useState([])

  const [form, setForm] = useState(vacio)  // useState llama a la función una vez
  const [partidas, setPartidas] = useState([])
  const [buscar, setBuscar] = useState('')
  const [guardando, setGuardando] = useState(false)
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState('')
  const [aviso, setAviso] = useState(null)   // requisiciones generadas o canceladas por el último cambio
  const [detalle, setDetalle] = useState(null)

  useEffect(() => { cargar() }, [])

  async function cargar() {
    const [co, cl, eq, pr, di, te, ta, ci] = await Promise.all([
      supabase.from('cotizaciones').select('*, clientes(nombre)').order('folio', { ascending: false }),
      supabase.from('clientes').select('id, nombre, distancia_km'),
      supabase.from('equipos').select('id, numero_serie, cliente_id, tipo, marca, capacidad_kw, atributos'),
      supabase.from('productos').select('id, sku, nombre, precio, unidad, categoria').eq('activo', true).order('sku'),
      supabase.from('disponibles').select('id, disponible'),
      supabase.from('perfiles').select('id, nombre').eq('rol', 'tecnico').eq('activo', true).order('nombre'),
      supabase.from('tarifas_servicio').select('*').eq('activo', true),
      supabase.from('citas').select('id, cotizacion_id, estado, fecha, hora').not('cotizacion_id', 'is', null)
    ])
    if (co.error) return setError(co.error.message)
    setCotizaciones(co.data || [])
    setClientes((cl.data || []).sort((a, b) => a.nombre.localeCompare(b.nombre)))
    setEquipos(eq.data || [])
    setProductos(pr.data || [])
    setDisponibles(di.data || [])
    setTecnicos(te.data || [])
    setTarifas(ta.data || [])
    setCitas(ci.data || [])
  }

  // Cita activa de cada cotización (por programar o programada).
  const citaDe = useMemo(() => {
    const m = {}
    for (const ci of citas) {
      if (ci.estado === 'por_programar' || ci.estado === 'programada') m[ci.cotizacion_id] ??= ci
    }
    return m
  }, [citas])

  const llevaVisita = f => TIPOS_CON_VISITA.includes(f.tipo) || f.requiere_visita

  // Diagnóstico: arma las partidas de servicio según la clase y capacidad del equipo
  // y la distancia del cliente. Reemplaza las que ya cargó antes, sin tocar el resto.
  function cargarDiagnostico() {
    setError('')
    const cliente = clientes.find(c => c.id === form.cliente_id)
    if (!cliente) return setError('Elige el cliente primero')
    const equipo = equipos.find(e => e.id === form.equipo_id)
    const { partidas: nuevas, avisos } = partidasDeDiagnostico({ tarifas, equipo, cliente })
    setAvisosDiag(avisos)
    setPartidas([...partidas.filter(p => !p.servicio), ...nuevas])
  }

  const dispoPorId = useMemo(
    () => Object.fromEntries(disponibles.map(d => [d.id, d.disponible])),
    [disponibles]
  )

  const equiposDelCliente = equipos.filter(e => e.cliente_id === form.cliente_id)

  // Servicios de catálogo (correctivo, preventivo, instalaciones…): cada uno tiene su
  // propio SKU y se busca igual que un producto, en el mismo cuadro.
  const serviciosCatalogo = useMemo(() => tarifasDeCatalogo(tarifas), [tarifas])

  const encontrados = useMemo(() => {
    const t = buscar.trim().toLowerCase()
    if (!t) return []
    const prods = productos
      .filter(p => p.sku.toLowerCase().includes(t) || (p.nombre || '').toLowerCase().includes(t))
      .map(p => ({ tipo: 'producto', id: p.id, sku: p.sku, nombre: p.nombre, precio: p.precio, unidad: p.unidad }))
    const servs = serviciosCatalogo
      .filter(s => s.sku.toLowerCase().includes(t) || s.nombre.toLowerCase().includes(t))
      .map(s => ({ tipo: 'servicio', id: s.id, sku: s.sku, nombre: s.nombre, precio: s.precio }))
    return [...prods, ...servs].slice(0, 8)
  }, [buscar, productos, serviciosCatalogo])

  // -------------------------------------------------------------------------
  // Partidas. Se copia descripción y precio EN ESTE MOMENTO: si mañana sube el
  // precio, esta cotización no cambia. Un servicio de catálogo nunca lleva
  // producto_id: es una partida libre, igual que el diagnóstico y el traslado, así
  // que no mueve inventario ni genera requisiciones.
  // -------------------------------------------------------------------------
  function agregarResultado(item) {
    if (item.tipo === 'producto' && item.precio == null) {
      setError(`${item.sku} no tiene precio capturado. Ponlo en Inventario o agrégalo como partida libre.`)
      return
    }
    setError('')
    setPartidas([...partidas, {
      producto_id: item.tipo === 'producto' ? item.id : null,
      sku: item.sku,
      descripcion: item.nombre,
      unidad: item.tipo === 'producto' ? (item.unidad || 'pieza') : 'servicio',
      cantidad: 1,
      precio_unitario: item.precio
    }])
    setBuscar('')
  }

  function agregarLibre() {
    setPartidas([...partidas, {
      producto_id: null, sku: '', descripcion: '', unidad: 'servicio',
      cantidad: 1, precio_unitario: ''
    }])
  }

  function cambiarPartida(i, campo, valor) {
    const copia = [...partidas]
    copia[i] = { ...copia[i], [campo]: valor }
    setPartidas(copia)
  }

  function quitarPartida(i) {
    setPartidas(partidas.filter((_, j) => j !== i))
  }

  const subtotal = partidas.reduce((s, p) => s + num(p.cantidad) * num(p.precio_unitario), 0)
  const descuento = num(form.descuento)
  const base = Math.max(0, subtotal - descuento)
  const iva = base * IVA
  const total = base + iva

  // -------------------------------------------------------------------------
  async function guardar(e) {
    e.preventDefault()
    setError(''); setMensaje('')
    if (!form.cliente_id) return setError('Elige el cliente')
    if (partidas.length === 0) return setError('Agrega al menos una partida')
    if (partidas.some(p => !p.descripcion.trim())) return setError('Hay partidas sin descripción')
    if (form.prog_tecnico_id && form.prog_tecnico_id === form.prog_tecnico2_id) {
      return setError('El técnico responsable y su ayudante no pueden ser la misma persona')
    }
    if (form.prog_tecnico2_id && !form.prog_tecnico_id) {
      return setError('Elige al técnico responsable antes que a su ayudante')
    }

    setGuardando(true)
    const { error } = await supabase.from('cotizaciones').insert([{
      cliente_id: form.cliente_id,
      equipo_id: form.equipo_id || null,
      fecha: form.fecha,
      vigencia_dias: num(form.vigencia_dias) || 15,
      tipo: form.tipo,
      partidas: partidas.map(p => ({
        ...p,
        cantidad: num(p.cantidad),
        precio_unitario: num(p.precio_unitario),
        importe: num(p.cantidad) * num(p.precio_unitario)
      })),
      subtotal, descuento, iva, total,
      requiere_visita: form.requiere_visita,
      condiciones: form.condiciones,
      notas_internas: form.notas_internas || null,
      // Programación propuesta: solo se guarda si la cotización lleva visita.
      prog_fecha: llevaVisita(form) ? form.prog_fecha || null : null,
      prog_hora: llevaVisita(form) ? form.prog_hora || null : null,
      prog_duracion_min: llevaVisita(form) ? num(form.prog_duracion_min) || null : null,
      prog_tecnico_id: llevaVisita(form) ? form.prog_tecnico_id || null : null,
      prog_tecnico2_id: llevaVisita(form) ? form.prog_tecnico2_id || null : null,
      estado: 'borrador',
      creada_por: (await supabase.auth.getUser()).data.user?.email || 'crm'
    }])
    setGuardando(false)
    if (error) return setError(error.message)

    setForm(vacio()); setPartidas([]); setAvisosDiag([]); setVista('lista')
    setMensaje('Cotización guardada como borrador.')
    cargar()
  }

  // -------------------------------------------------------------------------
  // Cambiar de estado mueve inventario: aceptar aparta, salir de aceptada libera.
  // Todo eso ocurre DENTRO de la base (supabase/sql/08_requisiciones.sql), en una
  // sola operación: o se cambia el estado y se mueve el inventario, o no se hace
  // nada. Si al aceptar falta material, la cotización se acepta igual y lo que
  // falta se manda a Requisiciones. Aquí solo se pide y se cuenta lo que respondió.
  // -------------------------------------------------------------------------
  async function cambiarEstado(c, nuevo) {
    setError(''); setMensaje(''); setAviso(null)
    if (c.estado === nuevo) return

    // Si la cotización tiene una visita agendada, avisar antes de cancelarla.
    const cita = citaDe[c.id]
    const cancelaVisita = nuevo !== 'aceptada' && (c.estado === 'aceptada' || nuevo === 'rechazada' || nuevo === 'vencida')
    if (cita && cancelaVisita) {
      const cuando = cita.estado === 'por_programar' ? 'por programar' : `del ${cita.fecha}`
      if (!confirm(`Esta cotización tiene una cita ${cuando}.\n\nAl cambiarla a "${nuevo}" se cancelan la cita y su orden de servicio, salvo que ya tengan trabajo capturado.\n\n¿Continuar?`)) return
    }

    const { data, error } = await supabase.rpc('cambiar_estado_cotizacion', {
      p_id: c.id, p_nuevo: nuevo
    })
    if (error) return setError(error.message)

    // La versión anterior de la función devolvía ok:false al faltar material y no
    // cambiaba nada. Si eso llega aquí, la base no tiene 08_requisiciones.sql.
    if (data.ok === false) {
      return setError('La base tiene una versión vieja de cambiar_estado_cotizacion y no se cambió nada. Corre supabase/sql/08_requisiciones.sql.')
    }

    if (data.sin_cambio) {
      setMensaje('La cotización ya estaba en ese estado.')
    } else if (data.movimientos > 0) {
      setMensaje(`${data.movimiento === 'apartado' ? 'Apartadas' : 'Liberadas'} ${data.movimientos} partida(s) en almacén.`)
    } else {
      setMensaje(`Cotización marcada como ${nuevo}.`)
    }

    const visita = nuevo === 'aceptada' && data.orden_folio
      ? { estado: data.cita_estado, fecha: data.cita_fecha, folio: data.orden_folio, nueva: data.cita_nueva }
      : null

    if (data.requisiciones > 0 || data.requisiciones_canceladas > 0 || data.requisiciones_en_curso > 0 ||
        visita || data.citas_canceladas > 0 || data.citas_con_trabajo > 0) {
      setAviso({
        faltantes: data.faltantes || [],
        canceladas: data.requisiciones_canceladas || 0,
        enCurso: data.requisiciones_en_curso || 0,
        visita,
        citasCanceladas: data.citas_canceladas || 0,
        citasConTrabajo: data.citas_con_trabajo || 0
      })
    }
    cargar()
  }

  // Cuánto de una partida no tiene existencia. El disponible negativo (material ya
  // prometido a otra cotización) cuenta como cero: falta todo lo que se pide.
  const faltaDePartida = p =>
    p.producto_id ? Math.max(0, num(p.cantidad) - Math.max(dispoPorId[p.producto_id] ?? 0, 0)) : 0

  const vence = c => sumarDias(c.fecha, c.vigencia_dias || 15)

  return (
    <div className="pagina">
      <h2>Cotizaciones</h2>

      <div className="pestanas">
        <button className="pestana" aria-pressed={vista === 'lista'} onClick={() => setVista('lista')}>Lista</button>
        <button className="pestana" aria-pressed={vista === 'nueva'} onClick={() => setVista('nueva')}>Nueva</button>
      </div>

      {error && <Alerta tipo="error">{error}</Alerta>}
      {mensaje && <Alerta tipo="ok" palabra="Listo">{mensaje}</Alerta>}

      {aviso?.visita && (
        <Alerta tipo="ok" palabra="Visita">
          {aviso.visita.nueva ? 'Se abrió' : 'Se enlazó'} la cita{' '}
          {aviso.visita.estado === 'por_programar'
            ? <strong>por programar</strong>
            : <>programada el <strong>{aviso.visita.fecha}</strong></>}
          {' '}y la orden de servicio <strong>OS-{aviso.visita.folio}</strong>.
          {aviso.visita.estado === 'por_programar' && ' Falta ponerle fecha, hora y técnicos en la Agenda.'}
          {irA && (
            <div style={{ marginTop: 8 }}>
              <button onClick={() => irA('agenda')}>Ir a la Agenda</button>
            </div>
          )}
        </Alerta>
      )}

      {aviso?.citasCanceladas > 0 && (
        <Alerta tipo="info" palabra="Cita cancelada">
          Se cancelaron {aviso.citasCanceladas} cita(s) y su orden de servicio.
        </Alerta>
      )}
      {aviso?.citasConTrabajo > 0 && (
        <Alerta tipo="aviso" palabra="Ojo">
          {aviso.citasConTrabajo} cita(s) ya tienen trabajo capturado y <strong>no se cancelaron</strong>.
          Revísalas en la Agenda.
        </Alerta>
      )}

      {aviso && (aviso.faltantes.length > 0 || aviso.canceladas > 0 || aviso.enCurso > 0) && (
        <Alerta tipo="aviso" palabra={aviso.faltantes.length > 0 ? 'Faltó material' : 'Requisiciones'}>
          {aviso.faltantes.length > 0 && (
            <>
              Se generó una requisición de pedido.
              <ul style={{ margin: '6px 0', paddingLeft: 20 }}>
                {aviso.faltantes.map(f => (
                  <li key={f.sku}>
                    {f.sku}: se piden {f.pide}, hay {Math.max(f.disponible, 0)} → <strong>a pedir {f.a_pedir}</strong>
                  </li>
                ))}
              </ul>
            </>
          )}
          {aviso.canceladas > 0 && (
            <div>Se cancelaron {aviso.canceladas} requisición(es) que aún no se pedían.</div>
          )}
          {aviso.enCurso > 0 && (
            <div>
              {aviso.enCurso} requisición(es) ya estaban pedidas al proveedor y
              siguen activas. Revisa si todavía las necesitas.
            </div>
          )}
          {irA && (
            <div style={{ marginTop: 8 }}>
              <button onClick={() => irA('requisiciones')}>Ir a Requisiciones</button>
            </div>
          )}
        </Alerta>
      )}

      {/* ------------------------------------------------------------------ */}
      {vista === 'lista' && (
        <>
          <div className="tabla-scroll">
            <table>
              <thead>
                <tr>
                  <th>Folio</th><th>Cliente</th><th>Fecha</th><th>Vence</th>
                  <th>Tipo</th><th>Total</th><th>Estado</th><th>Visita</th><th>Cambiar a</th><th></th>
                </tr>
              </thead>
              <tbody>
                {cotizaciones.map(c => (
                  <tr key={c.id}>
                    <td>{c.folio}</td>
                    <td>{c.clientes?.nombre}</td>
                    <td>{c.fecha}</td>
                    <td>{vence(c)}</td>
                    <td>{c.tipo}{c.requiere_visita && ' · visita'}</td>
                    <td align="right">{pesos(c.total)}</td>
                    <td><span className={`estado estado-${c.estado}`}>{c.estado}</span></td>
                    <td>
                      {citaDe[c.id]
                        ? (citaDe[c.id].estado === 'por_programar' ? 'Por programar' : citaDe[c.id].fecha)
                        : (llevaVisita(c) ? 'Sin cita' : '—')}
                    </td>
                    <td>
                      <select value="" aria-label={`Cambiar el estado de la cotización ${c.folio}`}
                        onChange={e => e.target.value && cambiarEstado(c, e.target.value)}>
                        <option value="">—</option>
                        {ESTADOS.filter(([v]) => v !== c.estado).map(([v, t]) => (
                          <option key={v} value={v}>{t}</option>
                        ))}
                      </select>
                    </td>
                    <td><button onClick={() => setDetalle(detalle === c.id ? null : c.id)}>
                      {detalle === c.id ? 'Cerrar' : 'Ver'}
                    </button></td>
                  </tr>
                ))}
                {cotizaciones.length === 0 && (
                  <tr><td colSpan={10} className="ayuda">Todavía no hay cotizaciones.</td></tr>
                )}
              </tbody>
            </table>
          </div>

          {detalle && (() => {
            const c = cotizaciones.find(x => x.id === detalle)
            if (!c) return null
            return (
              <section className="tarjeta" style={{ maxWidth: 760 }}>
                <h3>Cotización {c.folio} — {c.clientes?.nombre}</h3>
                <div className="tabla-scroll">
                  <table style={{ width: '100%' }}>
                    <thead>
                      <tr><th>SKU</th><th>Descripción</th><th>Cant.</th><th>P. unitario</th><th>Importe</th></tr>
                    </thead>
                    <tbody>
                      {(c.partidas || []).map((p, i) => (
                        <tr key={i}>
                          <td>{p.sku || '—'}</td>
                          <td>{p.descripcion}</td>
                          <td align="right">{p.cantidad}</td>
                          <td align="right">{pesos(p.precio_unitario)}</td>
                          <td align="right">{pesos(p.importe)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
                <div style={{ textAlign: 'right', lineHeight: 1.8 }}>
                  <div>Subtotal: {pesos(c.subtotal)}</div>
                  {c.descuento > 0 && <div>Descuento: −{pesos(c.descuento)}</div>}
                  <div>IVA: {pesos(c.iva)}</div>
                  <div style={{ fontSize: 20 }}><strong>Total: {pesos(c.total)}</strong></div>
                </div>
                {c.condiciones && <p className="ayuda" style={{ whiteSpace: 'pre-line' }}>{c.condiciones}</p>}
                {c.notas_internas && (
                  <Alerta tipo="aviso" palabra="Nota interna">
                    No se manda al cliente: {c.notas_internas}
                  </Alerta>
                )}
              </section>
            )
          })()}
        </>
      )}

      {/* ------------------------------------------------------------------ */}
      {vista === 'nueva' && (
        <form onSubmit={guardar} style={{ maxWidth: 820 }}>
          <div className="rejilla-2">
            <label className="campo">
              <span>Cliente *</span>
              <select
                value={form.cliente_id}
                onChange={e => setForm({ ...form, cliente_id: e.target.value, equipo_id: '' })}
              >
                <option value="">— Elige el cliente —</option>
                {clientes.map(c => <option key={c.id} value={c.id}>{c.nombre}</option>)}
              </select>
            </label>

            <label className="campo">
              <span>Equipo (opcional)</span>
              <select value={form.equipo_id} onChange={e => setForm({ ...form, equipo_id: e.target.value })}>
                <option value="">— Ninguno —</option>
                {equiposDelCliente.map(e => (
                  <option key={e.id} value={e.id}>
                    {e.numero_serie} — {e.tipo}{e.capacidad_kw ? ` ${e.capacidad_kw} kW` : ''}
                  </option>
                ))}
              </select>
            </label>

            <label className="campo">
              <span>Tipo</span>
              <select value={form.tipo} onChange={e => setForm({ ...form, tipo: e.target.value })}>
                {TIPOS.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
              </select>
            </label>

            <label className="campo">
              <span>Fecha</span>
              <input type="date" value={form.fecha} onChange={e => setForm({ ...form, fecha: e.target.value })} />
            </label>

            <label className="campo">
              <span>Vigencia (días)</span>
              <input type="number" value={form.vigencia_dias}
                onChange={e => setForm({ ...form, vigencia_dias: e.target.value })} />
            </label>

            <label className="casilla">
              <input
                type="checkbox"
                checked={form.requiere_visita}
                onChange={e => setForm({ ...form, requiere_visita: e.target.checked })}
              />
              Requiere visita técnica
            </label>
          </div>

          {form.requiere_visita && (
            <Alerta tipo="aviso" palabra="Visita">
              Fuera del metraje estándar el precio no sale de catálogo. Cotiza después de medir en sitio.
            </Alerta>
          )}

          {llevaVisita(form) && (
            <section className="tarjeta">
              <h3>Programación propuesta</h3>
              <p className="ayuda">
                Al <strong>aceptar</strong> la cotización se abre la cita con estos datos y su orden de
                servicio. Sin fecha, la cita queda <strong>por programar</strong> en la Agenda.
              </p>
              <div className="rejilla-2">
                <label className="campo">
                  <span>Fecha</span>
                  <input type="date" value={form.prog_fecha}
                    onChange={e => setForm({ ...form, prog_fecha: e.target.value })} />
                </label>
                <label className="campo">
                  <span>Hora</span>
                  <input type="time" value={form.prog_hora}
                    onChange={e => setForm({ ...form, prog_hora: e.target.value })} />
                </label>
                <label className="campo">
                  <span>Duración estimada (minutos)</span>
                  <input type="number" min="15" step="15" value={form.prog_duracion_min}
                    onChange={e => setForm({ ...form, prog_duracion_min: e.target.value })} />
                </label>
                <span />
                <label className="campo">
                  <span>Técnico responsable</span>
                  <select value={form.prog_tecnico_id}
                    onChange={e => setForm({ ...form, prog_tecnico_id: e.target.value })}>
                    <option value="">— Sin asignar —</option>
                    {tecnicos.map(t => <option key={t.id} value={t.id}>{t.nombre}</option>)}
                  </select>
                </label>
                <label className="campo">
                  <span>Ayudante (técnico 2)</span>
                  <select value={form.prog_tecnico2_id}
                    onChange={e => setForm({ ...form, prog_tecnico2_id: e.target.value })}>
                    <option value="">— Ninguno —</option>
                    {tecnicos.filter(t => t.id !== form.prog_tecnico_id).map(t =>
                      <option key={t.id} value={t.id}>{t.nombre}</option>)}
                  </select>
                </label>
              </div>
            </section>
          )}

          {form.tipo === 'diagnostico' && (
            <section className="tarjeta">
              <h3>Diagnóstico y traslado</h3>
              <p className="ayuda">
                El precio del diagnóstico sale de la clase y capacidad del equipo. El traslado
                aplica desde los 40 km del cliente (solo ida) y se cobran todos los km.
              </p>
              <button type="button" className="btn-primario" onClick={cargarDiagnostico}>
                Cargar diagnóstico y traslado
              </button>
              {avisosDiag.map((a, i) => (
                <div key={i} style={{ marginTop: 10 }}><Alerta tipo="aviso" palabra="Falta">{a}</Alerta></div>
              ))}
            </section>
          )}

          <h3>Partidas</h3>

          <div className="buscador">
            <input
              placeholder="Buscar producto por SKU o nombre"
              aria-label="Buscar producto por SKU o nombre"
              value={buscar}
              onChange={e => setBuscar(e.target.value)}
            />
            {encontrados.length > 0 && (
              <div className="buscador-lista">
                {encontrados.map(p => (
                  <button key={`${p.tipo}-${p.id}`} type="button" onClick={() => agregarResultado(p)}>
                    <strong>{p.sku}</strong> — {p.nombre}
                    <span className="ayuda">
                      {p.tipo === 'servicio' ? (
                        <><span className="etiqueta">Servicio</span> {pesos(p.precio)}</>
                      ) : (
                        <>{p.precio == null ? 'sin precio' : pesos(p.precio)}{' · disponible '}{dispoPorId[p.id] ?? 0}</>
                      )}
                    </span>
                  </button>
                ))}
              </div>
            )}
          </div>

          <PreventivoDeEquipo equipoId={form.equipo_id} onAgregar={ps => {
            setPartidas([...partidas, ...ps]); setError('')
          }} />

          <button type="button" onClick={agregarLibre} style={{ marginBottom: 12 }}>
            ＋ Agregar partida libre
          </button>

          <div className="tabla-scroll">
            <table style={{ width: '100%', minWidth: 640 }}>
              <thead>
                <tr>
                  <th>SKU</th><th>Descripción</th><th style={{ width: 96 }}>Cant.</th>
                  <th style={{ width: 130 }}>P. unitario</th><th style={{ width: 130 }}>Importe</th><th></th>
                </tr>
              </thead>
              <tbody>
                {partidas.map((p, i) => (
                  <tr key={i}>
                    <td>
                      {p.sku || '—'}
                      {/* Sin esta etiqueta, una pieza a $0 parece un precio que se olvidó
                          capturar. Va incluida en el servicio, pero sí aparta inventario. */}
                      {esIncluida(p) && (
                        <div><span className="etiqueta">Incluida en el servicio</span></div>
                      )}
                      {faltaDePartida(p) > 0 && (
                        <div className="estado-pendiente" style={{ fontWeight: 700 }}>
                          Sin existencia suficiente: faltan {faltaDePartida(p)}. Se pedirá al aceptar.
                        </div>
                      )}
                    </td>
                    <td>
                      <input
                        aria-label={`Descripción de la partida ${i + 1}`} style={{ width: '100%' }}
                        value={p.descripcion}
                        onChange={e => cambiarPartida(i, 'descripcion', e.target.value)}
                      />
                    </td>
                    <td>
                      <input
                        type="number" aria-label={`Cantidad de la partida ${i + 1}`}
                        style={{ width: '100%', textAlign: 'right' }} value={p.cantidad}
                        onChange={e => cambiarPartida(i, 'cantidad', e.target.value)}
                      />
                    </td>
                    <td>
                      <input
                        type="number" aria-label={`Precio unitario de la partida ${i + 1}`}
                        style={{ width: '100%', textAlign: 'right' }} value={p.precio_unitario}
                        onChange={e => cambiarPartida(i, 'precio_unitario', e.target.value)}
                      />
                    </td>
                    <td align="right">{pesos(num(p.cantidad) * num(p.precio_unitario))}</td>
                    <td><button type="button" className="btn-peligro" aria-label={`Quitar la partida ${i + 1}`}
                      onClick={() => quitarPartida(i)}>×</button></td>
                  </tr>
                ))}
                {partidas.length === 0 && (
                  <tr><td colSpan={6} className="ayuda" style={{ textAlign: 'center' }}>Sin partidas todavía</td></tr>
                )}
              </tbody>
            </table>
          </div>

          <div style={{ textAlign: 'right', lineHeight: 1.9, marginBottom: 16 }}>
            <div>Subtotal: {pesos(subtotal)}</div>
            <div>
              <label className="fila" style={{ justifyContent: 'flex-end' }}>
                Descuento
                <input
                  type="number" style={{ width: 130, textAlign: 'right' }} value={form.descuento}
                  onChange={e => setForm({ ...form, descuento: e.target.value })}
                />
              </label>
            </div>
            <div>IVA ({IVA * 100}%): {pesos(iva)}</div>
            <div style={{ fontSize: 22 }}><strong>Total: {pesos(total)}</strong></div>
          </div>

          <label className="campo">
            <span>Condiciones (se imprimen para el cliente)</span>
            <textarea rows={4} value={form.condiciones}
              onChange={e => setForm({ ...form, condiciones: e.target.value })} />
          </label>

          <label className="campo">
            <span>Notas internas (nunca se mandan al cliente)</span>
            <textarea rows={2} value={form.notas_internas}
              onChange={e => setForm({ ...form, notas_internas: e.target.value })} />
          </label>

          <button type="submit" className="btn-primario btn-grande" disabled={guardando}>
            {guardando ? 'Guardando…' : 'Guardar como borrador'}
          </button>
        </form>
      )}
    </div>
  )
}
