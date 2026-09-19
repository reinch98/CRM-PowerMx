import { useEffect, useMemo, useState } from 'react'
import { supabase } from './lib/supabase'

// Requisiciones de pedido: lo que faltó en almacén al aceptar una cotización.
// El cambio de estado lo hace la base (supabase/sql/08_requisiciones.sql); al
// marcar "Recibida" ella misma registra la entrada al inventario.

const ESTADOS = [
  ['pendiente', 'Por pedir'],
  ['pedida', 'Pedidas'],
  ['recibida', 'Recibidas'],
  ['cancelada', 'Canceladas'],
  ['todas', 'Todas']
]

const ETIQUETA = { pendiente: 'Por pedir', pedida: 'Pedida', recibida: 'Recibida', cancelada: 'Cancelada' }
const COLOR = { pendiente: '#92400e', pedida: '#1565c0', recibida: '#2e7d32', cancelada: '#475569' }

export default function Requisiciones() {
  const [filas, setFilas] = useState([])
  const [filtro, setFiltro] = useState('pendiente')
  const [datos, setDatos] = useState({})          // { [id]: { proveedor, referencia } } al pedir
  const [trabajando, setTrabajando] = useState('')  // id de la requisición en curso
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState('')

  useEffect(() => { cargar() }, [])

  async function cargar() {
    const { data, error } = await supabase
      .from('requisiciones')
      .select('*, productos(sku, nombre, unidad), cotizaciones(folio), clientes(nombre)')
      .order('created_at', { ascending: false })
    if (error) return setError(error.message)
    setFilas(data || [])
  }

  const cuantas = useMemo(() => {
    const n = { todas: filas.length }
    for (const f of filas) n[f.estado] = (n[f.estado] || 0) + 1
    return n
  }, [filas])

  const visibles = filas.filter(f => filtro === 'todas' || f.estado === filtro)

  // Lo pendiente sumado por producto: es la lista de compra.
  const porProducto = useMemo(() => {
    const suma = {}
    for (const f of filas.filter(x => x.estado === 'pendiente')) {
      const clave = f.producto_id
      suma[clave] ??= { sku: f.productos?.sku, nombre: f.productos?.nombre, unidad: f.productos?.unidad, total: 0 }
      suma[clave].total += Number(f.cantidad)
    }
    return Object.values(suma).sort((a, b) => String(a.sku).localeCompare(String(b.sku)))
  }, [filas])

  async function cambiar(f, nuevo) {
    setError(''); setMensaje('')
    const nombre = `${f.productos?.sku ?? 'producto'} × ${f.cantidad}`

    if (nuevo === 'recibida' && !confirm(`¿Llegó ${nombre}?\n\nSe registrará la entrada en el inventario.`)) return
    if (nuevo === 'cancelada' && !confirm(`¿Cancelar la requisición de ${nombre}?`)) return

    setTrabajando(f.id)
    const ed = datos[f.id] || {}
    const { data, error } = await supabase.rpc('cambiar_estado_requisicion', {
      p_id: f.id,
      p_nuevo: nuevo,
      p_proveedor: ed.proveedor || null,
      p_referencia: ed.referencia || null
    })
    setTrabajando('')
    if (error) return setError(error.message)

    if (data.sin_cambio) setMensaje(`REQ-${f.folio} ya estaba ${ETIQUETA[nuevo].toLowerCase()}.`)
    else if (nuevo === 'recibida') setMensaje(`REQ-${f.folio} recibida: ${nombre} entró al inventario.`)
    else setMensaje(`REQ-${f.folio} marcada como ${ETIQUETA[nuevo].toLowerCase()}.`)
    cargar()
  }

  const campo = { padding: 6, fontSize: 14, width: 130, boxSizing: 'border-box' }
  const tab = a => ({
    padding: '8px 14px', marginRight: 6, marginBottom: 6, cursor: 'pointer',
    border: '1px solid #ccc', borderRadius: 6,
    background: a ? '#333' : '#fff', color: a ? '#fff' : '#333'
  })

  return (
    <div style={{ padding: 20, fontFamily: 'system-ui' }}>
      <h2>Requisiciones de pedido</h2>
      <p style={{ color: '#475569', marginTop: 0, fontSize: 14, maxWidth: 680 }}>
        Aquí llega lo que faltó en almacén al aceptar una cotización. Al marcar una
        como <strong>Recibida</strong> el material entra solo al inventario.
      </p>

      {error && <p style={{ color: 'crimson' }}>{error}</p>}
      {mensaje && <p style={{ color: 'green' }}>{mensaje}</p>}

      {porProducto.length > 0 && (
        <div style={{ padding: 12, background: '#fef3c7', color: '#0c1520', borderRadius: 8, marginBottom: 16, maxWidth: 680 }}>
          <strong>Por pedir ({porProducto.length} producto{porProducto.length === 1 ? '' : 's'}):</strong>
          <ul style={{ margin: '6px 0 0', paddingLeft: 20 }}>
            {porProducto.map(p => (
              <li key={p.sku}>
                <strong>{p.total}</strong> {p.unidad || 'pieza'}(s) de {p.sku} — {p.nombre}
              </li>
            ))}
          </ul>
        </div>
      )}

      <div style={{ marginBottom: 12 }}>
        {ESTADOS.map(([v, t]) => (
          <button key={v} style={tab(filtro === v)} onClick={() => setFiltro(v)}>
            {t} ({cuantas[v] || 0})
          </button>
        ))}
      </div>

      <table border="1" cellPadding="6" style={{ borderCollapse: 'collapse', fontSize: 14 }}>
        <thead>
          <tr>
            <th>Folio</th><th>Producto</th><th>Cantidad</th><th>Cotización</th>
            <th>Estado</th><th>Proveedor / referencia</th><th></th>
          </tr>
        </thead>
        <tbody>
          {visibles.map(f => {
            const ed = datos[f.id] || {}
            const abierta = f.estado === 'pendiente' || f.estado === 'pedida'
            return (
              <tr key={f.id}>
                <td>REQ-{f.folio}</td>
                <td>
                  <strong>{f.productos?.sku}</strong>
                  <div style={{ color: '#475569', fontSize: 13 }}>{f.productos?.nombre}</div>
                </td>
                <td align="right">{f.cantidad} {f.productos?.unidad || ''}</td>
                <td>
                  {f.cotizaciones ? `COT-${f.cotizaciones.folio}` : '—'}
                  <div style={{ color: '#475569', fontSize: 13 }}>{f.clientes?.nombre}</div>
                </td>
                <td><strong style={{ color: COLOR[f.estado] }}>{ETIQUETA[f.estado]}</strong></td>
                <td>
                  {f.estado === 'pendiente' ? (
                    <div style={{ display: 'grid', gap: 4 }}>
                      <input
                        placeholder="Proveedor" style={campo} value={ed.proveedor || ''}
                        onChange={e => setDatos({ ...datos, [f.id]: { ...ed, proveedor: e.target.value } })}
                      />
                      <input
                        placeholder="Orden de compra" style={campo} value={ed.referencia || ''}
                        onChange={e => setDatos({ ...datos, [f.id]: { ...ed, referencia: e.target.value } })}
                      />
                    </div>
                  ) : (
                    <>
                      {f.proveedor || '—'}
                      {f.referencia && <div style={{ color: '#475569', fontSize: 13 }}>{f.referencia}</div>}
                      {f.fecha_pedido && <div style={{ color: '#475569', fontSize: 13 }}>Pedida: {f.fecha_pedido}</div>}
                      {f.fecha_recibida && <div style={{ color: '#475569', fontSize: 13 }}>Recibida: {f.fecha_recibida}</div>}
                    </>
                  )}
                </td>
                <td>
                  {abierta && (
                    <div style={{ display: 'grid', gap: 4 }}>
                      {f.estado === 'pendiente' && (
                        <button disabled={!!trabajando} onClick={() => cambiar(f, 'pedida')}>
                          {trabajando === f.id ? 'Guardando…' : 'Marcar pedida'}
                        </button>
                      )}
                      <button disabled={!!trabajando} onClick={() => cambiar(f, 'recibida')}>Recibida</button>
                      <button disabled={!!trabajando} onClick={() => cambiar(f, 'cancelada')}>Cancelar</button>
                    </div>
                  )}
                </td>
              </tr>
            )
          })}
          {visibles.length === 0 && (
            <tr><td colSpan={7} style={{ color: '#475569', textAlign: 'center' }}>
              {filas.length === 0 ? 'Todavía no hay requisiciones.' : 'Nada en esta lista.'}
            </td></tr>
          )}
        </tbody>
      </table>
    </div>
  )
}
