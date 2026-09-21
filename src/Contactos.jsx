import { useEffect, useState } from 'react'
import { supabase } from './lib/supabase'
import { Alerta } from './ui'
import {
  ROLES, etiquetaRol, permisosEnPalabras, descripcionEquipo,
  armarContacto, problemaDeContacto, textoDeError
} from './lib/contactos'

const VACIO = {
  nombre: '', puesto: '', telefono: '', email: '', notas: '',
  whatsapp: true, verificado: false, de_toda_la_empresa: false,
  puede_pedir_citas: false, recibe_ordenes: false, recibe_cotizaciones: false
}

// ---------------------------------------------------------------------------
// Buscar por teléfono: lo que hará el agente al recibir un mensaje. Sirve para comprobar
// que un número se reconoce (en cualquier formato) y de qué equipos es responsable.
// ---------------------------------------------------------------------------
function BuscadorTelefono() {
  const [telefono, setTelefono] = useState('')
  const [resultado, setResultado] = useState(null)      // null = aún no se busca
  const [error, setError] = useState('')
  const [buscando, setBuscando] = useState(false)

  async function buscar(e) {
    e.preventDefault()
    setError(''); setResultado(null); setBuscando(true)
    const { data, error } = await supabase.rpc('identificar_telefono', { p_telefono: telefono })
    setBuscando(false)
    if (error) return setError(textoDeError(error))
    setResultado(data || [])
  }

  return (
    <details className="tarjeta">
      <summary className="resumen">Buscar por teléfono</summary>
      <p className="ayuda">
        Escribe un número en cualquier formato (+52 1…, con guiones, con espacios) y mira a quién
        reconoce y de qué equipos está a cargo.
      </p>
      <form onSubmit={buscar} className="fila" style={{ flexWrap: 'nowrap' }}>
        <input type="tel" inputMode="tel" placeholder="999 123 4567" aria-label="Teléfono a buscar"
          value={telefono} onChange={e => setTelefono(e.target.value)} style={{ flex: 1, minWidth: 0 }} />
        <button type="submit" className="btn-primario" disabled={buscando || !telefono.trim()}>
          {buscando ? 'Buscando…' : 'Buscar'}
        </button>
      </form>

      {error && <Alerta tipo="error">{error}</Alerta>}
      {resultado && resultado.length === 0 && (
        <Alerta tipo="info" palabra="Sin coincidencias">
          Ese número no está registrado (o no tiene 10 dígitos). Un número desconocido no ve datos de nadie.
        </Alerta>
      )}
      {(resultado || []).map(p => (
        <div key={p.contacto_id} className="linea-surtido" style={{ marginTop: 10 }}>
          <div className="fila" style={{ justifyContent: 'space-between' }}>
            <strong>{p.nombre}{p.puesto ? ` · ${p.puesto}` : ''}</strong>
            <span className="etiqueta">{p.verificado ? 'Verificado' : 'Sin verificar'}</span>
          </div>
          <div className="ayuda">
            {p.cliente}{p.de_toda_la_empresa && ' · de toda la empresa'}
            {!p.whatsapp && ' · no usa WhatsApp'}
          </div>
          {(p.equipos || []).length === 0 && <div className="ayuda">Sin equipos ligados.</div>}
          {(p.equipos || []).map(x => (
            <div key={x.equipo_id} className="ayuda">
              <strong>{x.descripcion || 'Equipo'}</strong> · serie {x.numero_serie} · {etiquetaRol(x.rol)}
              {x.origen === 'empresa' && ' (por ser de toda la empresa)'}
              <br />{permisosEnPalabras(x)}
              {x.ultima_orden && <> · última orden OS-{x.ultima_orden.folio} ({x.ultima_orden.fecha})</>}
            </div>
          ))}
        </div>
      ))}
    </details>
  )
}

// ---------------------------------------------------------------------------
// Formulario de una persona (alta o edición). Componente de nivel superior para que los
// campos no pierdan el foco al escribir.
// ---------------------------------------------------------------------------
function FormContacto({ inicial, clienteId, onGuardado, onCancelar }) {
  // Lo que viene de la base como null se muestra vacío (un campo controlado no acepta null).
  const [form, setForm] = useState(() => {
    const f = { ...VACIO }
    for (const k of Object.keys(VACIO)) if (inicial && inicial[k] != null) f[k] = inicial[k]
    return f
  })
  const [error, setError] = useState('')
  const [guardando, setGuardando] = useState(false)
  const cambiar = (campo, valor) => setForm({ ...form, [campo]: valor })

  async function guardar(e) {
    e.preventDefault()
    const datos = armarContacto(form)
    const problema = problemaDeContacto(datos)
    if (problema) return setError(problema)
    setError(''); setGuardando(true)
    const r = inicial?.id
      ? await supabase.from('contactos').update(datos).eq('id', inicial.id)
      : await supabase.from('contactos').insert([{ ...datos, cliente_id: clienteId }])
    setGuardando(false)
    if (r.error) return setError(textoDeError(r.error))
    onGuardado()
  }

  return (
    <form onSubmit={guardar}>
      <div className="rejilla-2">
        <label className="campo"><span>Nombre *</span>
          <input value={form.nombre} onChange={e => cambiar('nombre', e.target.value)} />
        </label>
        <label className="campo"><span>Puesto</span>
          <input value={form.puesto} onChange={e => cambiar('puesto', e.target.value)} placeholder="Encargado de mantenimiento" />
        </label>
        <label className="campo"><span>Teléfono</span>
          <input type="tel" inputMode="tel" value={form.telefono} onChange={e => cambiar('telefono', e.target.value)} placeholder="999 123 4567" />
        </label>
        <label className="campo"><span>Correo</span>
          <input type="email" value={form.email} onChange={e => cambiar('email', e.target.value)} />
        </label>
      </div>
      <label className="campo"><span>Notas</span>
        <input value={form.notas} onChange={e => cambiar('notas', e.target.value)} placeholder="Ej. solo contestar de lunes a viernes" />
      </label>

      <label className="casilla">
        <input type="checkbox" checked={form.whatsapp} onChange={e => cambiar('whatsapp', e.target.checked)} />
        Ese número usa WhatsApp
      </label>
      <label className="casilla">
        <input type="checkbox" checked={form.verificado} onChange={e => cambiar('verificado', e.target.checked)} />
        Verificado (confirmé que es de esta persona)
      </label>
      <label className="casilla">
        <input type="checkbox" checked={form.de_toda_la_empresa} onChange={e => cambiar('de_toda_la_empresa', e.target.checked)} />
        De toda la empresa (aplica a todos sus equipos, por ejemplo administración)
      </label>
      {form.de_toda_la_empresa && (
        <div className="conjunto">
          <strong>Qué puede hacer en todos los equipos</strong>
          <label className="casilla">
            <input type="checkbox" checked={form.puede_pedir_citas} onChange={e => cambiar('puede_pedir_citas', e.target.checked)} />
            Pedir citas
          </label>
          <label className="casilla">
            <input type="checkbox" checked={form.recibe_ordenes} onChange={e => cambiar('recibe_ordenes', e.target.checked)} />
            Recibir órdenes de servicio
          </label>
          <label className="casilla">
            <input type="checkbox" checked={form.recibe_cotizaciones} onChange={e => cambiar('recibe_cotizaciones', e.target.checked)} />
            Recibir cotizaciones
          </label>
        </div>
      )}

      {error && <Alerta tipo="error">{error}</Alerta>}
      <div className="fila" style={{ marginTop: 10 }}>
        <button type="submit" className="btn-primario" disabled={guardando}>
          {guardando ? 'Guardando…' : inicial?.id ? 'Guardar cambios' : 'Agregar persona'}
        </button>
        {onCancelar && <button type="button" onClick={onCancelar} disabled={guardando}>Cancelar</button>}
      </div>
    </form>
  )
}

// ---------------------------------------------------------------------------
// Un equipo, con las personas a su cargo y el formulario para ligar a otra.
// ---------------------------------------------------------------------------
function TarjetaEquipo({ equipo, vinculos, personas, onCambio }) {
  const [persona, setPersona] = useState('')
  const [rol, setRol] = useState('encargado')
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')

  const hayResponsable = vinculos.some(v => v.rol === 'responsable')
  const yaLigadas = new Set(vinculos.filter(v => v.origen === 'equipo').map(v => v.contacto_id))
  const disponibles = personas.filter(p => !yaLigadas.has(p.id))

  async function vincular() {
    if (!persona) return setError('Elige a la persona.')
    const actual = vinculos.find(v => v.rol === 'responsable')
    if (rol === 'responsable' && actual && actual.contacto_id !== persona &&
        !confirm(`${actual.nombre} deja de ser el responsable de este equipo y pasa a encargado.\n\n¿Continuar?`)) return
    setError(''); setOcupado(true)
    const { error } = await supabase.rpc('vincular_contacto', { p_equipo: equipo.id, p_contacto: persona, p_rol: rol })
    setOcupado(false)
    if (error) return setError(textoDeError(error))
    setPersona('')
    onCambio()
  }

  async function quitar(v) {
    if (!confirm(`¿Quitar a ${v.nombre} de este equipo?\n\nLa persona sigue registrada en el cliente.`)) return
    setOcupado(true)
    const { error } = await supabase.from('equipo_contactos').delete()
      .eq('equipo_id', equipo.id).eq('contacto_id', v.contacto_id)
    setOcupado(false)
    if (error) return setError(textoDeError(error))
    onCambio()
  }

  return (
    <div className="tarjeta">
      <div className="fila" style={{ justifyContent: 'space-between' }}>
        <strong>{descripcionEquipo(equipo)}</strong>
        {equipo.en_poliza && <span className="etiqueta">En póliza</span>}
      </div>
      <div className="ayuda">Serie {equipo.numero_serie}</div>

      {!hayResponsable && (
        <Alerta tipo="aviso" palabra="Sin responsable">
          Nadie está como responsable de este equipo: a él se le manda la orden de servicio por defecto.
        </Alerta>
      )}

      {vinculos.length === 0 && <p className="ayuda">Nadie a cargo todavía.</p>}
      {vinculos.map(v => (
        <div key={`${v.contacto_id}-${v.origen}`} className="linea-surtido" style={{ marginTop: 8 }}>
          <div className="fila" style={{ justifyContent: 'space-between' }}>
            <strong>{v.nombre}</strong>
            <span className="etiqueta">{etiquetaRol(v.rol)}</span>
          </div>
          <div className="ayuda">
            {v.telefono || 'Sin teléfono'}{!v.verificado && ' · sin verificar'}
            {v.origen === 'empresa' && ' · por ser de toda la empresa'}
            <br />{permisosEnPalabras(v)}
          </div>
          {v.origen === 'equipo' && (
            <button type="button" className="btn-peligro" onClick={() => quitar(v)} disabled={ocupado}>
              Quitar de este equipo
            </button>
          )}
        </div>
      ))}

      {personas.length === 0 ? (
        <p className="ayuda">Agrega personas al cliente para poder ligarlas a sus equipos.</p>
      ) : (
        <div style={{ marginTop: 10 }}>
          <div className="rejilla-2">
            <label className="campo"><span>Persona</span>
              <select value={persona} onChange={e => setPersona(e.target.value)}>
                <option value="">— Elige —</option>
                {disponibles.map(p => <option key={p.id} value={p.id}>{p.nombre}{p.telefono ? ` · ${p.telefono}` : ''}</option>)}
              </select>
            </label>
            <label className="campo"><span>Papel en este equipo</span>
              <select value={rol} onChange={e => setRol(e.target.value)}>
                {ROLES.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
              </select>
            </label>
          </div>
          <button type="button" onClick={vincular} disabled={ocupado || !persona}>＋ Ligar a este equipo</button>
        </div>
      )}
      {error && <Alerta tipo="error">{error}</Alerta>}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Pantalla
// ---------------------------------------------------------------------------
export default function Contactos() {
  const [clientes, setClientes] = useState([])
  const [clienteId, setClienteId] = useState('')
  const [personas, setPersonas] = useState([])
  const [equipos, setEquipos] = useState([])
  const [vinculos, setVinculos] = useState([])
  const [editando, setEditando] = useState(null)     // id de la persona que se edita
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState('')
  const [cargando, setCargando] = useState(false)

  async function cargarCliente(id) {
    if (!id) return
    setCargando(true)
    const [p, e, v] = await Promise.all([
      supabase.from('contactos').select('*').eq('cliente_id', id).eq('activo', true).order('nombre'),
      supabase.from('equipos').select('id, numero_serie, tipo, marca, modelo, capacidad_kw, en_poliza')
        .eq('cliente_id', id).order('numero_serie'),
      supabase.from('contactos_por_equipo').select('*').eq('cliente_id', id)
    ])
    setCargando(false)
    const fallo = p.error || e.error || v.error
    if (fallo) return setError(textoDeError(fallo))
    setError('')
    setPersonas(p.data || []); setEquipos(e.data || []); setVinculos(v.data || [])
  }

  useEffect(() => {
    supabase.from('clientes').select('id, nombre').order('nombre').then(({ data, error }) => {
      if (error) setError(textoDeError(error))
      else setClientes(data || [])
    })
  }, [])

  function elegirCliente(id) {
    setClienteId(id); setEditando(null); setMensaje(''); setPersonas([]); setEquipos([]); setVinculos([])
    cargarCliente(id)
  }

  const recargar = () => cargarCliente(clienteId)

  async function quitarPersona(p) {
    if (!confirm(`¿Quitar a ${p.nombre}?\n\nDeja de recibir avisos y de ser reconocida por su número. Su historial no se pierde.`)) return
    const { error } = await supabase.from('contactos').update({ activo: false }).eq('id', p.id)
    if (error) return setError(textoDeError(error))
    setMensaje(`${p.nombre} quitada.`)
    recargar()
  }

  async function verificar(p) {
    const { error } = await supabase.from('contactos').update({ verificado: true }).eq('id', p.id)
    if (error) return setError(textoDeError(error))
    recargar()
  }

  const cliente = clientes.find(c => c.id === clienteId)
  const vinculosDe = id => vinculos.filter(v => v.equipo_id === id)

  return (
    <div className="pagina pagina-angosta">
      <h2>Contactos</h2>
      <p className="ayuda">
        Las personas de cada cliente y quién está a cargo de cada equipo. De aquí saldrá a quién
        se le manda la orden de servicio y a quién reconoce el agente de WhatsApp.
      </p>

      <BuscadorTelefono />

      <label className="campo">
        <span>Cliente</span>
        <select value={clienteId} onChange={e => elegirCliente(e.target.value)}>
          <option value="">— Elige un cliente —</option>
          {clientes.map(c => <option key={c.id} value={c.id}>{c.nombre}</option>)}
        </select>
      </label>

      {error && <Alerta tipo="error">{error}</Alerta>}
      {mensaje && <Alerta tipo="ok" palabra="Listo">{mensaje}</Alerta>}
      {cargando && <p>Cargando…</p>}

      {clienteId && !cargando && (
        <>
          <h3>Personas de {cliente?.nombre}</h3>
          {personas.length === 0 && <p className="ayuda">Todavía no hay personas registradas.</p>}
          {personas.map(p => (
            editando === p.id ? (
              <div key={p.id} className="tarjeta">
                <FormContacto inicial={p} clienteId={clienteId}
                  onGuardado={() => { setEditando(null); setMensaje('Cambios guardados.'); recargar() }}
                  onCancelar={() => setEditando(null)} />
              </div>
            ) : (
              <div key={p.id} className="tarjeta">
                <div className="fila" style={{ justifyContent: 'space-between' }}>
                  <strong>{p.nombre}{p.puesto ? ` · ${p.puesto}` : ''}</strong>
                  <span className="etiqueta">{p.verificado ? 'Verificado' : 'Sin verificar'}</span>
                </div>
                <div className="ayuda">
                  {p.telefono || 'Sin teléfono'}{p.telefono && !p.whatsapp && ' · no usa WhatsApp'}
                  {p.email && <> · {p.email}</>}
                  {p.de_toda_la_empresa && <><br />De toda la empresa · {permisosEnPalabras(p)}</>}
                  {p.notas && <><br />{p.notas}</>}
                </div>
                <div className="fila" style={{ marginTop: 8 }}>
                  <button type="button" onClick={() => { setEditando(p.id); setMensaje('') }}>Editar</button>
                  {!p.verificado && <button type="button" onClick={() => verificar(p)}>Marcar verificado</button>}
                  <button type="button" className="btn-peligro" onClick={() => quitarPersona(p)}>Quitar</button>
                </div>
              </div>
            )
          ))}

          <details className="tarjeta">
            <summary className="resumen">＋ Agregar persona</summary>
            <FormContacto key={`nueva-${personas.length}`} clienteId={clienteId}
              onGuardado={() => { setMensaje('Persona agregada.'); recargar() }} />
          </details>

          <h3 style={{ marginTop: 24 }}>Equipos y responsables</h3>
          <p className="ayuda">
            Cada equipo tiene un solo responsable (a él se le manda la orden de servicio por defecto);
            los encargados y los demás pueden ser los que hagan falta.
          </p>
          {equipos.length === 0 && <p className="ayuda">Este cliente no tiene equipos registrados.</p>}
          {equipos.map(eq => (
            <TarjetaEquipo key={eq.id} equipo={eq} vinculos={vinculosDe(eq.id)} personas={personas} onCambio={recargar} />
          ))}
        </>
      )}
    </div>
  )
}
