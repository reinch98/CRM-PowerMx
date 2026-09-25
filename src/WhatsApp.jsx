import { useEffect, useState } from 'react'
import { Alerta } from './ui'
import {
  nombreConversacion, haceCuanto, estadoVentana, enlaceWhatsApp, esBorrador,
  cargarBandeja, cargarMensajes, cargarContactos, registrarRespuesta,
  marcarLeida, cerrarConversacion, vincularConversacion,
  cargarAgente, guardarAgente, marcarBorradorEnviado
} from './lib/whatsapp'

const cuando = iso => iso ? new Date(iso).toLocaleString('es-MX', { dateStyle: 'short', timeStyle: 'short' }) : ''

// ---------------------------------------------------------------------------
// Una conversación abierta: los mensajes y la caja para responder. Componente de nivel
// superior (no dentro de otro) para que la caja de texto no pierda el foco al escribir.
// ---------------------------------------------------------------------------
function Conversacion({ conv, contactos, onVolver, onCambio }) {
  const [mensajes, setMensajes] = useState(null)
  const [texto, setTexto] = useState('')
  const [contacto, setContacto] = useState('')
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState('')

  async function cargar() {
    const r = await cargarMensajes(conv.id)
    if (r.ok) setMensajes(r.mensajes)
    else setError(r.texto)
  }
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    cargar()
    if (conv.sin_leer > 0) marcarLeida(conv.id).then(onCambio)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [conv.id])

  const ventana = estadoVentana(conv)
  const enlace = enlaceWhatsApp(conv.telefono, texto)

  async function responder() {
    setError(''); setMensaje('')
    if (!texto.trim()) return setError('Escribe la respuesta.')
    setOcupado(true)
    const r = await registrarRespuesta(conv.id, texto)
    setOcupado(false)
    if (!r.ok) return setError(r.texto)
    setMensaje('Respuesta guardada en la conversación. Se abrió WhatsApp: ahí la mandas.')
    setTexto('')
    cargar(); onCambio()
  }

  async function ligar() {
    if (!contacto) return setError('Elige a la persona.')
    setError('')
    const r = await vincularConversacion(conv.id, contacto)
    if (!r.ok) return setError(r.texto)
    setMensaje('Número ligado. Desde ahora se sabe de quién es.')
    onCambio()
  }

  async function cambiarEstado() {
    const r = await cerrarConversacion(conv.id, conv.estado === 'cerrada')
    if (!r.ok) return setError(r.texto)
    onCambio()
  }

  return (
    <div className="pagina pagina-angosta">
      <div className="fila" style={{ marginBottom: 8 }}>
        <button onClick={onVolver}>‹ Bandeja</button>
      </div>

      <div className="fila" style={{ justifyContent: 'space-between' }}>
        <h2 style={{ margin: 0 }}>{nombreConversacion(conv)}</h2>
        <span className="etiqueta">{conv.estado === 'cerrada' ? 'Cerrada' : 'Abierta'}</span>
      </div>
      <p className="ayuda">
        {conv.telefono}
        {conv.cliente && <> · {conv.cliente}</>}
        {(conv.equipos || []).length > 0 && <> · {conv.equipos.join(', ')}</>}
      </p>

      {!conv.contacto_id && (
        <section className="tarjeta">
          <h3>Número sin identificar</h3>
          <p className="ayuda">
            Este número no está en Contactos, o está en más de un cliente. Mientras no se ligue,
            el agente no le puede dar datos de nadie.
          </p>
          <label className="campo">
            <span>Es esta persona</span>
            <select value={contacto} onChange={e => setContacto(e.target.value)}>
              <option value="">— Elige —</option>
              {contactos.map(c => (
                <option key={c.id} value={c.id}>
                  {c.nombre}{c.clientes?.nombre ? ` · ${c.clientes.nombre}` : ''}{c.telefono ? ` · ${c.telefono}` : ''}
                </option>
              ))}
            </select>
          </label>
          <button type="button" className="btn-primario" onClick={ligar}>Ligar a esta persona</button>
        </section>
      )}

      <Alerta tipo={ventana.puede ? 'ok' : 'aviso'} palabra={ventana.puede ? 'Puedes responder' : 'Ventana cerrada'}>
        {ventana.texto}
      </Alerta>

      {error && <Alerta tipo="error">{error}</Alerta>}
      {mensaje && <Alerta tipo="ok" palabra="Listo">{mensaje}</Alerta>}

      <div className="chat" aria-live="polite">
        {mensajes === null && <p className="ayuda">Cargando…</p>}
        {mensajes?.length === 0 && <p className="ayuda">Todavía no hay mensajes en esta conversación.</p>}
        {(mensajes || []).map(m => (
          <div key={m.id} className={`burbuja${m.direccion === 'saliente' ? ' burbuja-mia' : ''}`}>
            {m.texto || `(${m.tipo})`}
            <span className="ayuda" style={{ display: 'block' }}>
              {cuando(m.wa_timestamp || m.created_at)}
              {m.direccion === 'saliente' && m.enviado_por && <> · {m.enviado_por}</>}
            </span>
            {/* Un borrador NO se ha mandado. Se marca fuerte porque en la burbuja se ve
                igual que lo enviado, y confundirlos sería creer que ya contestaste. */}
            {esBorrador(m) && (
              <div style={{ marginTop: 6 }}>
                <span className="etiqueta etiqueta-aviso">Borrador del agente · sin enviar</span>
                {enlaceWhatsApp(conv.telefono, m.texto) && (
                  <div style={{ marginTop: 6 }}>
                    <a className="btn btn-primario" href={enlaceWhatsApp(conv.telefono, m.texto)}
                      target="_blank" rel="noreferrer"
                      onClick={() => marcarBorradorEnviado(m.id).then(cargar)}>
                      Mandar este borrador
                    </a>
                  </div>
                )}
              </div>
            )}
          </div>
        ))}
      </div>

      <label className="campo">
        <span>Responder</span>
        <textarea rows={3} value={texto} onChange={e => setTexto(e.target.value)}
          placeholder="Escribe la respuesta…" />
      </label>
      <p className="ayuda">
        Todavía no hay envío automático: al guardar se abre WhatsApp con el texto listo y ahí lo
        mandas. La respuesta queda en esta conversación de todos modos.
      </p>
      <div className="fila">
        {!enlace ? (
          <span className="etiqueta etiqueta-aviso">El número no sirve para WhatsApp</span>
        ) : texto.trim() ? (
          <a className="btn btn-primario" href={enlace} target="_blank" rel="noreferrer" onClick={responder}>
            {ocupado ? 'Guardando…' : 'Guardar y abrir WhatsApp'}
          </a>
        ) : (
          // Sin texto no se abre nada: mandar un mensaje vacío solo confunde al cliente.
          <button type="button" className="btn-primario" disabled>Guardar y abrir WhatsApp</button>
        )}
        <button type="button" onClick={cambiarEstado}>
          {conv.estado === 'cerrada' ? 'Volver a abrir' : 'Marcar como cerrada'}
        </button>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Pantalla
// ---------------------------------------------------------------------------
export default function WhatsApp() {
  const [conversaciones, setConversaciones] = useState(null)
  const [contactos, setContactos] = useState([])
  const [agente, setAgente] = useState(null)
  const [incluirCerradas, setIncluirCerradas] = useState(false)
  const [seleccion, setSeleccion] = useState(null)
  const [error, setError] = useState('')
  const [enLinea, setEnLinea] = useState(navigator.onLine)

  async function recargar(cerradas = incluirCerradas) {
    const [b, c, a] = await Promise.all([cargarBandeja(cerradas), cargarContactos(), cargarAgente()])
    if (b.ok) { setConversaciones(b.conversaciones); setError('') }
    else setError(b.texto)
    if (c.ok) setContactos(c.contactos)
    if (a.ok) setAgente(a.agente)
  }

  // Se guarda al momento: son tres ajustes, un botón de guardar solo estorbaría.
  async function cambiarAgente(cambios) {
    setAgente(a => ({ ...a, ...cambios }))
    const r = await guardarAgente(cambios)
    if (!r.ok) setError(r.texto)
  }

  useEffect(() => {
    function alConectar() { setEnLinea(true); recargar() }
    function alDesconectar() { setEnLinea(false) }
    window.addEventListener('online', alConectar)
    window.addEventListener('offline', alDesconectar)
    // eslint-disable-next-line react-hooks/set-state-in-effect
    if (navigator.onLine) recargar()
    return () => {
      window.removeEventListener('online', alConectar)
      window.removeEventListener('offline', alDesconectar)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  function cambiarFiltro(valor) {
    setIncluirCerradas(valor)
    recargar(valor)
  }

  const abierta = seleccion && (conversaciones || []).find(c => c.id === seleccion)
  if (abierta) {
    return (
      <Conversacion
        key={abierta.id} conv={abierta} contactos={contactos}
        onVolver={() => setSeleccion(null)} onCambio={() => recargar()}
      />
    )
  }

  const sinLeer = (conversaciones || []).reduce((s, c) => s + (c.sin_leer || 0), 0)

  return (
    <div className="pagina pagina-angosta">
      <div className="fila" style={{ justifyContent: 'space-between' }}>
        <h2 style={{ margin: 0 }}>WhatsApp</h2>
        <button onClick={() => recargar()} disabled={!enLinea}>Actualizar</button>
      </div>
      <p className="ayuda">
        Los mensajes que te escriben los clientes. Un número que ya está en Contactos se
        reconoce solo; uno nuevo lo ligas tú antes de que el agente pueda darle datos.
      </p>

      {!enLinea && <Alerta tipo="aviso" palabra="Sin señal">La bandeja necesita conexión.</Alerta>}
      {error && <Alerta tipo="error">{error}</Alerta>}

      {/* El agente arranca apagado y en borrador: redacta y tú mandas. Se pasa a
          automático cuando lo hayas visto contestar unas cuantas veces. */}
      {agente && (
        <details className="tarjeta">
          <summary className="resumen">
            Agente · {agente.activo ? (agente.modo === 'automatico' ? 'contestando solo' : 'redactando borradores') : 'apagado'}
          </summary>
          <p className="ayuda" style={{ marginTop: 8 }}>
            Contesta con lo que sabe del número: sus equipos y su próxima visita. Nunca da
            precios ni confirma fechas; lo único que puede dejar anotado es una solicitud de
            visita, que tú confirmas en la Agenda.
          </p>
          <label className="casilla">
            <input type="checkbox" checked={!!agente.activo}
              onChange={e => cambiarAgente({ activo: e.target.checked })} />
            Encendido
          </label>
          <label className="campo">
            <span>Qué hace al llegar un mensaje</span>
            <select value={agente.modo} onChange={e => cambiarAgente({ modo: e.target.value })}>
              <option value="borrador">Redactar un borrador y esperar a que yo lo mande</option>
              <option value="automatico">Contestar solo</option>
            </select>
          </label>
          {agente.modo === 'automatico' && (
            <Alerta tipo="aviso" palabra="Ojo">
              Va a escribirle a tus clientes sin que nadie lea antes. Déjalo en borrador
              hasta que lo hayas visto contestar unas cuantas veces.
            </Alerta>
          )}
          <label className="campo">
            <span>Máximo de respuestas al día por número</span>
            <input type="number" inputMode="numeric" value={agente.tope_dia}
              onChange={e => cambiarAgente({ tope_dia: Number(e.target.value) || 1 })} />
          </label>
          <label className="campo">
            <span>Algo que quieras que diga o evite</span>
            <textarea rows={2} value={agente.instrucciones || ''}
              onChange={e => cambiarAgente({ instrucciones: e.target.value })} />
          </label>
        </details>
      )}

      <label className="casilla">
        <input type="checkbox" checked={incluirCerradas} onChange={e => cambiarFiltro(e.target.checked)} />
        Ver también las cerradas
      </label>

      {conversaciones === null && enLinea && !error && <p>Cargando…</p>}

      {conversaciones?.length === 0 && (
        <section className="tarjeta">
          <h3>Todavía no llega nada</h3>
          <p className="ayuda">
            Falta conectar el número con Meta. Son cuatro pasos; los primeros tres se hacen en
            un rato y no necesitan que el negocio esté verificado:
          </p>
          <ol style={{ paddingLeft: 20, display: 'grid', gap: 8 }}>
            <li>Crea una cuenta en <strong>developers.facebook.com</strong> con tu Facebook.</li>
            <li>Crea una app de tipo <strong>Negocios</strong> y agrégale el producto <strong>WhatsApp</strong>.</li>
            <li>
              Meta te da un <strong>número de prueba</strong> al instante. Autoriza tu celular
              como destinatario: con eso ya se puede mandar y recibir de verdad.
            </li>
            <li>
              Pásame el <strong>identificador del número</strong>, el <strong>token</strong> y el
              <strong> identificador de la cuenta</strong>. Con eso conecto el webhook y los mensajes
              empiezan a caer aquí.
            </li>
          </ol>
          <Alerta tipo="info" palabra="Después">
            La verificación del negocio y las plantillas aprobadas solo hacen falta para escribirle
            a clientes reales fuera de las 24 horas. Eso tarda días y se puede ir haciendo aparte.
          </Alerta>
        </section>
      )}

      {sinLeer > 0 && (
        <Alerta tipo="aviso" palabra="Sin leer">
          {sinLeer} mensaje{sinLeer === 1 ? '' : 's'} sin leer.
        </Alerta>
      )}

      {(conversaciones || []).map(c => {
        const ventana = estadoVentana(c)
        return (
          <button key={c.id} className="orden-item" onClick={() => setSeleccion(c.id)}>
            <span className="fila" style={{ justifyContent: 'space-between', width: '100%' }}>
              <strong>{nombreConversacion(c)}</strong>
              {c.sin_leer > 0 && <span className="etiqueta etiqueta-aviso">{c.sin_leer} sin leer</span>}
            </span>
            <span className="ayuda">
              {c.telefono}{c.cliente && <> · {c.cliente}</>}
              {c.ultimo_mensaje_at && <> · {haceCuanto(c.ultimo_mensaje_at)}</>}
            </span>
            {c.ultimo_texto && <span className="ayuda">{c.ultimo_texto}</span>}
            <span>
              {!c.contacto_id && <span className="etiqueta etiqueta-aviso">Sin identificar</span>}
              {!ventana.puede && <span className="etiqueta">Ventana cerrada</span>}
            </span>
          </button>
        )
      })}
    </div>
  )
}
