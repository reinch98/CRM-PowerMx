import { useEffect, useState } from 'react'
import { supabase } from './lib/supabase'
import { Alerta } from './ui'

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
  const sinRol = perfiles.filter(p => p.rol === 'sin_rol').length

  return (
    <div className="pagina">
      <h2>Usuarios y técnicos</h2>

      <Alerta tipo="info" palabra="Cómo se crean">
        Las cuentas se crean en Supabase, en Authentication → Add user. En cuanto el usuario
        existe aparece aquí solo, sin permisos, y tú le das su rol. Mientras tanto puede
        entrar pero no ve nada.
      </Alerta>

      {sinRol > 0 && (
        <Alerta tipo="aviso" palabra="Esperando rol">
          Hay <strong>{sinRol}</strong> cuenta(s) sin rol asignado.
        </Alerta>
      )}

      {error && <Alerta tipo="error">{error}</Alerta>}
      {mensaje && <Alerta tipo="ok" palabra="Listo">{mensaje}</Alerta>}

      <div className="tabla-scroll">
        <table>
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
                <tr key={p.id} style={p.rol === 'sin_rol' ? { background: 'var(--aviso-fondo)' } : undefined}>
                  <td>
                    {p.email}
                    {p.rol === 'sin_rol' && <div><span className="estado estado-pendiente">Sin rol</span></div>}
                  </td>
                  <td><input aria-label={`Nombre de ${p.email}`} style={{ width: 150 }}
                    value={val(p, 'nombre')} onChange={e => editar(p.id, 'nombre', e.target.value)} /></td>
                  <td>
                    <select aria-label={`Rol de ${p.email}`} value={rolActual} onChange={e => editar(p.id, 'rol', e.target.value)}>
                      {ROLES.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
                    </select>
                  </td>
                  <td>
                    {rolActual === 'cliente' ? (
                      <select aria-label={`Cliente de ${p.email}`} value={val(p, 'cliente_id')} onChange={e => editar(p.id, 'cliente_id', e.target.value)}>
                        <option value="">— Elige —</option>
                        {clientes.map(c => <option key={c.id} value={c.id}>{c.nombre}</option>)}
                      </select>
                    ) : <span className="ayuda">—</span>}
                  </td>
                  <td><input aria-label={`Teléfono de ${p.email}`} style={{ width: 130 }}
                    value={val(p, 'telefono')} onChange={e => editar(p.id, 'telefono', e.target.value)} /></td>
                  <td><input aria-label={`Zona de ${p.email}`} style={{ width: 120 }}
                    value={val(p, 'zona')} onChange={e => editar(p.id, 'zona', e.target.value)} /></td>
                  <td align="center">
                    <label className="fila" style={{ justifyContent: 'center' }}>
                      <input
                        type="checkbox"
                        checked={'activo' in (edicion[p.id] || {}) ? edicion[p.id].activo : p.activo}
                        onChange={e => editar(p.id, 'activo', e.target.checked)}
                      />
                      {('activo' in (edicion[p.id] || {}) ? edicion[p.id].activo : p.activo) ? 'Sí' : 'No'}
                    </label>
                  </td>
                  <td>{edicion[p.id] && <button className="btn-primario" onClick={() => guardar(p)}>Guardar</button>}</td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>

      <h3 style={{ marginTop: 24 }}>Qué ve cada rol</h3>
      <div style={{ maxWidth: 640 }}>
        {ROLES.map(([v, t, d]) => (
          <div key={v} className="tarjeta" style={{ marginBottom: 10 }}>
            <strong>{t}</strong>
            <div className="ayuda">{d}</div>
          </div>
        ))}
      </div>

      <p className="ayuda" style={{ maxWidth: 640 }}>
        Desactivar a alguien es mejor que borrarlo: las órdenes que capturó siguen
        apuntando a su nombre, y si lo borras se pierde quién hizo cada servicio.
      </p>
    </div>
  )
}
