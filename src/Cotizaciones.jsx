import { useEffect, useMemo, useState } from 'react'
import { supabase } from './lib/supabase'
import { hoyLocal, sumarDias } from './lib/fechas'

const IVA = 0.16

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
  notas_internas: ''
})

export default function Cotizaciones() {
  const [vista, setVista] = useState('lista')
  const [cotizaciones, setCotizaciones] = useState([])
  const [clientes, setClientes] = useState([])
  const [equipos, setEquipos] = useState([])
  const [productos, setProductos] = useState([])
  const [disponibles, setDisponibles] = useState([])

  const [form, setForm] = useState(vacio)  // useState llama a la función una vez
  const [partidas, setPartidas] = useState([])
  const [buscar, setBuscar] = useState('')
  const [guardando, setGuardando] = useState(false)
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState('')
  const [detalle, setDetalle] = useState(null)

  useEffect(() => { cargar() }, [])

  async function cargar() {
    const [co, cl, eq, pr, di] = await Promise.all([
      supabase.from('cotizaciones').select('*, clientes(nombre)').order('folio', { ascending: false }),
      supabase.from('clientes').select('id, nombre').order('nombre'),
      supabase.from('equipos').select('id, numero_serie, cliente_id, tipo, marca'),
      supabase.from('productos').select('id, sku, nombre, precio, unidad, categoria').eq('activo', true).order('sku'),
      supabase.from('disponibles').select('id, disponible')
    ])
    if (co.error) return setError(co.error.message)
    setCotizaciones(co.data || [])
    setClientes(cl.data || [])
    setEquipos(eq.data || [])
    setProductos(pr.data || [])
    setDisponibles(di.data || [])
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
      estado: 'borrador',
      creada_por: (await supabase.auth.getUser()).data.user?.email || 'crm'
    }])
    setGuardando(false)
    if (error) return setError(error.message)

    setForm(vacio()); setPartidas([]); setVista('lista')
    setMensaje('Cotización guardada como borrador.')
    cargar()
  }

  // -------------------------------------------------------------------------
  // Cambiar de estado mueve inventario: aceptar aparta, salir de aceptada libera.
  // Todo eso ocurre DENTRO de la base (supabase/sql/07_cotizacion_estado.sql), en
  // una sola operación: o se cambia el estado y se mueve el inventario, o no se
  // hace nada. Aquí solo se pide y se cuenta lo que respondió.
  // -------------------------------------------------------------------------
  async function cambiarEstado(c, nuevo, forzar = false) {
    setError(''); setMensaje('')
    if (c.estado === nuevo) return

    const { data, error } = await supabase.rpc('cambiar_estado_cotizacion', {
      p_id: c.id, p_nuevo: nuevo, p_forzar: forzar
    })
    if (error) return setError(error.message)

    // No alcanza el disponible: la base no cambió nada y devolvió qué falta.
    if (!data.ok) {
      const lista = (data.faltantes || [])
        .map(f => `${f.sku} (hay ${f.disponible}, piden ${f.pide})`).join(', ')
      if (!confirm(`No alcanza el disponible en: ${lista}.\n\n¿Aceptar de todos modos? El disponible quedará en negativo y se verá en Inventario.`)) return
      return cambiarEstado(c, nuevo, true)
    }

    if (data.sin_cambio) {
      setMensaje('La cotización ya estaba en ese estado.')
    } else if (data.movimientos > 0) {
      setMensaje(`${data.movimiento === 'apartado' ? 'Apartadas' : 'Liberadas'} ${data.movimientos} partida(s) en almacén.`)
    } else {
      setMensaje(`Cotización marcada como ${nuevo}.`)
    }
    cargar()
  }

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

      {/* ------------------------------------------------------------------ */}
      {vista === 'lista' && (
        <>
          <table border="1" cellPadding="6" style={{ borderCollapse: 'collapse', fontSize: 14 }}>
            <thead>
              <tr>
                <th>Folio</th><th>Cliente</th><th>Fecha</th><th>Vence</th>
                <th>Tipo</th><th>Total</th><th>Estado</th><th>Cambiar a</th><th></th>
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
                  <option key={e.id} value={e.id}>{e.numero_serie} — {e.tipo}</option>
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
                  <td style={{ fontSize: 12 }}>{p.sku || '—'}</td>
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
