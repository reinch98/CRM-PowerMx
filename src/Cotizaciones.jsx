import { useEffect, useMemo, useState } from 'react'
import { supabase } from './lib/supabase'
import { hoyLocal, sumarDias } from './lib/fechas'
import { partidasDeDiagnostico } from './lib/tarifas'
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

  const encontrados = useMemo(() => {
    const t = buscar.trim().toLowerCase()
    if (!t) return []
    return productos.filter(p =>
      p.sku.toLowerCase().includes(t) || (p.nombre || '').toLowerCase().includes(t)
    ).slice(0, 8)
  }, [buscar, productos])

  // -------------------------------------------------------------------------
  // Partidas. Se copia descripción y precio del catálogo EN ESTE MOMENTO: si
  // mañana sube el precio, esta cotización no cambia.
  // -------------------------------------------------------------------------
  function agregarProducto(p) {
    if (p.precio == null) {
      setError(`${p.sku} no tiene precio capturado. Ponlo en Inventario o agrégalo como partida libre.`)
      return
    }
    setError('')
    setPartidas([...partidas, {
      producto_id: p.id,
      sku: p.sku,
      descripcion: p.nombre,
      unidad: p.unidad || 'pieza',
      cantidad: 1,
      precio_unitario: p.precio
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

  const campo = { padding: 8, fontSize: 15, width: '100%', boxSizing: 'border-box' }
  const tab = a => ({
    padding: '8px 16px', marginRight: 6, cursor: 'pointer',
    border: '1px solid #ccc', borderRadius: 6,
    background: a ? '#333' : '#fff', color: a ? '#fff' : '#333'
  })
  const colorEstado = {
    borrador: '#757575', enviada: '#1565c0', aceptada: '#2e7d32',
    rechazada: '#c62828', vencida: '#ef6c00'
  }

  return (
    <div style={{ padding: 20, fontFamily: 'system-ui' }}>
      <h2>Cotizaciones</h2>

      <div style={{ marginBottom: 16 }}>
        <button style={tab(vista === 'lista')} onClick={() => setVista('lista')}>Lista</button>
        <button style={tab(vista === 'nueva')} onClick={() => setVista('nueva')}>Nueva</button>
      </div>

      {error && <p style={{ color: 'crimson' }}>{error}</p>}
      {mensaje && <p style={{ color: 'green' }}>{mensaje}</p>}

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
        <div style={{ padding: 12, background: '#fef3c7', color: '#0c1520', borderRadius: 8, marginBottom: 14, maxWidth: 680 }}>
          {aviso.faltantes.length > 0 && (
            <>
              <strong>Faltó material: se generó una requisición de pedido.</strong>
              <ul style={{ margin: '6px 0' , paddingLeft: 20 }}>
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
              <strong>Ojo:</strong> {aviso.enCurso} requisición(es) ya estaban pedidas al proveedor y
              siguen activas. Revisa si todavía las necesitas.
            </div>
          )}
          {irA && (
            <button onClick={() => irA('requisiciones')} style={{ marginTop: 8, padding: '8px 14px' }}>
              Ir a Requisiciones
            </button>
          )}
        </div>
      )}

      {/* ------------------------------------------------------------------ */}
      {vista === 'lista' && (
        <>
          <table border="1" cellPadding="6" style={{ borderCollapse: 'collapse', fontSize: 14 }}>
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
                  <td><strong style={{ color: colorEstado[c.estado] }}>{c.estado}</strong></td>
                  <td>
                    {citaDe[c.id]
                      ? (citaDe[c.id].estado === 'por_programar' ? 'Por programar' : citaDe[c.id].fecha)
                      : (llevaVisita(c) ? 'Sin cita' : '—')}
                  </td>
                  <td>
                    <select value="" onChange={e => e.target.value && cambiarEstado(c, e.target.value)}>
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
            </tbody>
          </table>

          {detalle && (() => {
            const c = cotizaciones.find(x => x.id === detalle)
            if (!c) return null
            return (
              <div style={{ marginTop: 20, padding: 16, border: '1px solid #ccc', borderRadius: 8, maxWidth: 720 }}>
                <h3>Cotización {c.folio} — {c.clientes?.nombre}</h3>
                <table border="1" cellPadding="6" style={{ borderCollapse: 'collapse', fontSize: 14, width: '100%' }}>
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
                <div style={{ textAlign: 'right', marginTop: 10, lineHeight: 1.8 }}>
                  <div>Subtotal: {pesos(c.subtotal)}</div>
                  {c.descuento > 0 && <div>Descuento: −{pesos(c.descuento)}</div>}
                  <div>IVA: {pesos(c.iva)}</div>
                  <div style={{ fontSize: 18 }}><strong>Total: {pesos(c.total)}</strong></div>
                </div>
                {c.condiciones && <p style={{ whiteSpace: 'pre-line', color: '#555', fontSize: 13 }}>{c.condiciones}</p>}
                {c.notas_internas && (
                  <p style={{ background: '#fff3e0', padding: 8, fontSize: 13 }}>
                    Nota interna (no se manda al cliente): {c.notas_internas}
                  </p>
                )}
              </div>
            )
          })()}
        </>
      )}

      {/* ------------------------------------------------------------------ */}
      {vista === 'nueva' && (
        <form onSubmit={guardar} style={{ maxWidth: 820 }}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 20 }}>
            <label>
              Cliente *
              <select
                value={form.cliente_id}
                onChange={e => setForm({ ...form, cliente_id: e.target.value, equipo_id: '' })}
                style={campo}
              >
                <option value="">— Elige el cliente —</option>
                {clientes.map(c => <option key={c.id} value={c.id}>{c.nombre}</option>)}
              </select>
            </label>

            <label>
              Equipo (opcional)
              <select value={form.equipo_id} onChange={e => setForm({ ...form, equipo_id: e.target.value })} style={campo}>
                <option value="">— Ninguno —</option>
                {equiposDelCliente.map(e => (
                  <option key={e.id} value={e.id}>
                    {e.numero_serie} — {e.tipo}{e.capacidad_kw ? ` ${e.capacidad_kw} kW` : ''}
                  </option>
                ))}
              </select>
            </label>

            <label>
              Tipo
              <select value={form.tipo} onChange={e => setForm({ ...form, tipo: e.target.value })} style={campo}>
                {TIPOS.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
              </select>
            </label>

            <label>
              Fecha
              <input type="date" value={form.fecha} onChange={e => setForm({ ...form, fecha: e.target.value })} style={campo} />
            </label>

            <label>
              Vigencia (días)
              <input type="number" value={form.vigencia_dias} onChange={e => setForm({ ...form, vigencia_dias: e.target.value })} style={campo} />
            </label>

            <label style={{ alignSelf: 'end' }}>
              <input
                type="checkbox"
                checked={form.requiere_visita}
                onChange={e => setForm({ ...form, requiere_visita: e.target.checked })}
              />
              {' '}Requiere visita técnica
            </label>
          </div>

          {form.requiere_visita && (
            <p style={{ background: '#fff3e0', padding: 10, borderRadius: 6, fontSize: 14 }}>
              Marcada como visita: fuera del metraje estándar el precio no sale de catálogo.
              Cotiza después de medir en sitio.
            </p>
          )}

          {llevaVisita(form) && (
            <section className="tarjeta" style={{ maxWidth: 820 }}>
              <h3>Programación propuesta</h3>
              <p className="ayuda">
                Al <strong>aceptar</strong> la cotización se abre la cita con estos datos y su orden de
                servicio. Sin fecha, la cita queda <strong>por programar</strong> en la Agenda.
              </p>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
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
            <section className="tarjeta" style={{ maxWidth: 820 }}>
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

          <div style={{ marginBottom: 10, position: 'relative', maxWidth: 420 }}>
            <input
              placeholder="Buscar producto por SKU o nombre"
              value={buscar}
              onChange={e => setBuscar(e.target.value)}
              style={campo}
            />
            {encontrados.length > 0 && (
              <div style={{
                position: 'absolute', zIndex: 10, background: '#fff', border: '1px solid #ccc',
                width: '100%', maxHeight: 260, overflowY: 'auto'
              }}>
                {encontrados.map(p => (
                  <div
                    key={p.id}
                    onClick={() => agregarProducto(p)}
                    style={{ padding: 8, cursor: 'pointer', borderBottom: '1px solid #eee', fontSize: 14 }}
                  >
                    <strong>{p.sku}</strong> — {p.nombre}
                    <div style={{ color: '#666', fontSize: 12 }}>
                      {p.precio == null ? 'sin precio' : pesos(p.precio)}
                      {' · disponible '}{dispoPorId[p.id] ?? 0}
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>

          <button type="button" onClick={agregarLibre} style={{ marginBottom: 12 }}>
            Agregar partida libre
          </button>

          <table border="1" cellPadding="6" style={{ borderCollapse: 'collapse', fontSize: 14, width: '100%', marginBottom: 16 }}>
            <thead>
              <tr>
                <th>SKU</th><th>Descripción</th><th style={{ width: 80 }}>Cant.</th>
                <th style={{ width: 110 }}>P. unitario</th><th style={{ width: 110 }}>Importe</th><th></th>
              </tr>
            </thead>
            <tbody>
              {partidas.map((p, i) => (
                <tr key={i}>
                  <td style={{ fontSize: 12 }}>
                    {p.sku || '—'}
                    {faltaDePartida(p) > 0 && (
                      <div style={{ color: '#92400e', fontWeight: 600 }}>
                        Sin existencia suficiente: faltan {faltaDePartida(p)}. Se pedirá al aceptar.
                      </div>
                    )}
                  </td>
                  <td>
                    <input
                      value={p.descripcion}
                      onChange={e => cambiarPartida(i, 'descripcion', e.target.value)}
                      style={{ width: '100%', padding: 4 }}
                    />
                  </td>
                  <td>
                    <input
                      type="number" value={p.cantidad}
                      onChange={e => cambiarPartida(i, 'cantidad', e.target.value)}
                      style={{ width: '100%', padding: 4, textAlign: 'right' }}
                    />
                  </td>
                  <td>
                    <input
                      type="number" value={p.precio_unitario}
                      onChange={e => cambiarPartida(i, 'precio_unitario', e.target.value)}
                      style={{ width: '100%', padding: 4, textAlign: 'right' }}
                    />
                  </td>
                  <td align="right">{pesos(num(p.cantidad) * num(p.precio_unitario))}</td>
                  <td><button type="button" onClick={() => quitarPartida(i)}>×</button></td>
                </tr>
              ))}
              {partidas.length === 0 && (
                <tr><td colSpan={6} style={{ color: '#888', textAlign: 'center' }}>Sin partidas todavía</td></tr>
              )}
            </tbody>
          </table>

          <div style={{ textAlign: 'right', lineHeight: 1.9, marginBottom: 16 }}>
            <div>Subtotal: {pesos(subtotal)}</div>
            <div>
              Descuento:{' '}
              <input
                type="number" value={form.descuento}
                onChange={e => setForm({ ...form, descuento: e.target.value })}
                style={{ width: 110, padding: 4, textAlign: 'right' }}
              />
            </div>
            <div>IVA ({IVA * 100}%): {pesos(iva)}</div>
            <div style={{ fontSize: 19 }}><strong>Total: {pesos(total)}</strong></div>
          </div>

          <label style={{ display: 'block', marginBottom: 10 }}>
            Condiciones (se imprimen para el cliente)
            <textarea
              rows={4} value={form.condiciones}
              onChange={e => setForm({ ...form, condiciones: e.target.value })}
              style={campo}
            />
          </label>

          <label style={{ display: 'block', marginBottom: 16 }}>
            Notas internas (nunca se mandan al cliente)
            <textarea
              rows={2} value={form.notas_internas}
              onChange={e => setForm({ ...form, notas_internas: e.target.value })}
              style={campo}
            />
          </label>

          <button type="submit" disabled={guardando} style={{ padding: 12, fontSize: 16 }}>
            {guardando ? 'Guardando…' : 'Guardar como borrador'}
          </button>
        </form>
      )}
    </div>
  )
}
