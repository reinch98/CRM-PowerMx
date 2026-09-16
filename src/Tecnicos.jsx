import { useEffect, useState } from 'react'
import { supabase } from './lib/supabase'

const ROLES = [
  ['admin', 'Administrador', 'Ve y hace todo: precios, costos, cotizaciones e inventario.'],
  ['tecnico', 'Técnico', 'Ve sus citas y captura órdenes. No ve costos ni cotizaciones.'],
  ['cliente', 'Cliente', 'Solo su propia ficha, sus equipos y su historial. Requiere elegir el cliente.'],
  ['sin_rol', 'Sin permisos', 'Entra al sistema pero no ve nada. Es el estado inicial de toda cuenta nueva.']
]

export default function Tecnicos() {
  const [perfiles, setPerfiles] = useState([])
  const [clientes, setClientes] = useState([])
  const [edicion, setEdicion] = useState({})
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState('')

  useEffect(() => { cargar() }, [])

  async function cargar() {
    const [p, c] = await Promise.all([
      supabase.from('perfiles').select('*').order('rol').order('nombre'),
      supabase.from('clientes').select('id, nombre').order('nombre')
    ])
    if (p.error) return setError(p.error.message)
    setPerfiles(p.data || [])
    setClientes(c.data || [])
  }

  function editar(id, campo, valor) {
    setEdicion({ ...edicion, [id]: { ...(edicion[id] || {}), [campo]: valor } })
  }

  async function guardar(p) {
    const cambios = edicion[p.id]
    if (!cambios) return
    setError(''); setMensaje('')

    if ((cambios.rol ?? p.rol) === 'cliente' && !(cambios.cliente_id ?? p.cliente_id)) {
      return setError('Un usuario con rol cliente necesita tener un cliente asignado')
    }
    // Si deja de ser cliente, se suelta el amarre para que no quede colgado.
    const payload = { ...cambios }
    if ((cambios.rol ?? p.rol) !== 'cliente') payload.cliente_id = null

    const { error } = await supabase.from('perfiles').update(payload).eq('id', p.id)
    if (error) return setError(error.message)

    const { [p.id]: _, ...resto } = edicion
    setEdicion(resto)
    setMensaje(`${p.email} actualizado.`)
    cargar()
  }

  const val = (p, campo) => (campo in (edicion[p.id] || {}) ? edicion[p.id][campo] : (p[campo] ?? ''))
  const campo = { padding: 5, fontSize: 14, width: '100%', boxSizing: 'border-box' }
  const sinRol = perfiles.filter(p => p.rol === 'sin_rol').length

  return (
    <div style={{ padding: 20, fontFamily: 'system-ui' }}>
      <h2>Usuarios y técnicos</h2>

      <div style={{ padding: 12, background: '#e8eaf6', borderRadius: 6, marginBottom: 16, maxWidth: 720, fontSize: 14 }}>
        Las cuentas se crean en Supabase, en Authentication → Add user. En cuanto
        el usuario existe aparece aquí solo, sin permisos, y tú le das su rol.
        Mientras tanto puede entrar pero no ve nada.
      </div>

      {sinRol > 0 && (
        <p style={{ padding: 10, background: '#fff3e0', borderRadius: 6, maxWidth: 720 }}>
          Hay <strong>{sinRol}</strong> cuenta(s) esperando rol.
        </p>
      )}

      {error && <p style={{ color: 'crimson' }}>{error}</p>}
      {mensaje && <p style={{ color: 'green' }}>{mensaje}</p>}

      <table border="1" cellPadding="6" style={{ borderCollapse: 'collapse', fontSize: 14 }}>
        <thead>
          <tr>
            <th>Correo</th><th>Nombre</th><th>Rol</th><th>Cliente</th>
            <th>Teléfono</th><th>Zona</th><th>Activo</th><th></th>
          </tr>
        </thead>
        <tbody>
          {perfiles.map(p => {
            const rolActual = val(p, 'rol')
            return (
              <tr key={p.id} style={p.rol === 'sin_rol' ? { background: '#fff8e1' } : undefined}>
                <td style={{ fontSize: 13 }}>{p.email}</td>
                <td><input value={val(p, 'nombre')} onChange={e => editar(p.id, 'nombre', e.target.value)} style={{ ...campo, width: 130 }} /></td>
                <td>
                  <select value={rolActual} onChange={e => editar(p.id, 'rol', e.target.value)} style={campo}>
                    {ROLES.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
                  </select>
                </td>
                <td>
                  {rolActual === 'cliente' ? (
                    <select value={val(p, 'cliente_id')} onChange={e => editar(p.id, 'cliente_id', e.target.value)} style={campo}>
                      <option value="">— Elige —</option>
                      {clientes.map(c => <option key={c.id} value={c.id}>{c.nombre}</option>)}
                    </select>
                  ) : <span style={{ color: '#aaa' }}>—</span>}
                </td>
                <td><input value={val(p, 'telefono')} onChange={e => editar(p.id, 'telefono', e.target.value)} style={{ ...campo, width: 110 }} /></td>
                <td><input value={val(p, 'zona')} onChange={e => editar(p.id, 'zona', e.target.value)} style={{ ...campo, width: 100 }} /></td>
                <td align="center">
                  <input
                    type="checkbox"
                    checked={'activo' in (edicion[p.id] || {}) ? edicion[p.id].activo : p.activo}
                    onChange={e => editar(p.id, 'activo', e.target.checked)}
                  />
                </td>
                <td>{edicion[p.id] && <button onClick={() => guardar(p)}>Guardar</button>}</td>
              </tr>
            )
          })}
        </tbody>
      </table>

      <h3 style={{ marginTop: 28 }}>Qué ve cada rol</h3>
      <div style={{ display: 'grid', gap: 10, maxWidth: 640 }}>
        {ROLES.map(([v, t, d]) => (
          <div key={v} style={{ padding: 12, border: '1px solid #ddd', borderRadius: 6 }}>
            <strong>{t}</strong>
            <div style={{ color: '#666', fontSize: 14 }}>{d}</div>
          </div>
        ))}
      </div>

      <p style={{ color: '#666', fontSize: 13, marginTop: 20, maxWidth: 640 }}>
        Desactivar a alguien es mejor que borrarlo: las órdenes que capturó siguen
        apuntando a su nombre, y si lo borras se pierde quién hizo cada servicio.
      </p>
    </div>
  )
}
