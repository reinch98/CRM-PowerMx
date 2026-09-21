import { useEffect, useState } from 'react'
import { supabase } from './lib/supabase'
import { explicarError } from './lib/errores'
import { Alerta } from './ui'
import {
  etiquetaTipo, etiquetaPara, enlaceWhatsApp, agruparPorCita, cuandoCorto
} from './lib/avisos'

const cuandoEnvio = iso =>
  iso ? new Date(iso).toLocaleString('es-MX', { dateStyle: 'short', timeStyle: 'short' }) : ''

// ---------------------------------------------------------------------------
// Cola de avisos de las citas confirmadas (la arma un trigger de la base: 16_avisos_de_cita.sql).
// Un mensaje por persona: al cliente su horario, a cada técnico los datos del servicio. El admin
// pulsa "Enviar por WhatsApp": se abre WhatsApp con el mensaje ya escrito y el aviso queda marcado
// como enviado. Más adelante la API de WhatsApp leerá esta misma cola y lo hará sola.
// ---------------------------------------------------------------------------
export default function AvisosPendientes({ recarga }) {
  const [datos, setDatos] = useState(null)      // { pendientes, recientes }
  const [error, setError] = useState('')
  const [ocupado, setOcupado] = useState('')    // id del aviso que se está marcando
  const [copiado, setCopiado] = useState('')

  async function cargar() {
    const { data, error } = await supabase.rpc('avisos_pendientes')
    if (error) return setError(explicarError(error).texto)
    setError('')
    setDatos(data)
  }

  // Se vuelve a leer cada vez que la Agenda cambia algo (agendar, programar, cancelar).
  // eslint-disable-next-line react-hooks/set-state-in-effect
  useEffect(() => { cargar() }, [recarga])

  async function marcar(id, estado) {
    setOcupado(id)
    const { error } = await supabase.rpc('marcar_aviso', { p_id: id, p_estado: estado })
    setOcupado('')
    if (error) return setError(explicarError(error).texto)
    cargar()
  }

  async function copiar(a) {
    try {
      await navigator.clipboard.writeText(a.texto)
      setCopiado(a.id)
      setTimeout(() => setCopiado(''), 2500)
    } catch {
      setError('No se pudo copiar. Abre "Ver mensaje" y cópialo a mano.')
    }
  }

  function descartar(a) {
    if (!confirm(`¿Descartar el aviso a ${a.nombre}?\n\nNo se le manda nada.`)) return
    marcar(a.id, 'descartado')
  }

  if (error && !datos) return <Alerta tipo="aviso" palabra="Avisos">No se pudieron cargar los avisos de cita: {error}</Alerta>
  if (!datos) return null

  const pendientes = datos.pendientes || []
  const recientes = datos.recientes || []
  if (pendientes.length === 0 && recientes.length === 0) return null

  return (
    <section style={{ marginBottom: 16 }}>
      {error && <Alerta tipo="error">{error}</Alerta>}

      {pendientes.length > 0 && (
        <>
          <Alerta tipo="aviso" palabra="Avisos por enviar">
            {pendientes.length} mensaje{pendientes.length === 1 ? '' : 's'} de citas confirmadas.
            Al pulsar “Enviar por WhatsApp” se abre el chat con el mensaje ya escrito y el aviso queda como enviado.
          </Alerta>

          {agruparPorCita(pendientes).map(g => (
            <div key={g.cita_id} className="tarjeta">
              <strong>{g.cliente} · {cuandoCorto(g.fecha, g.hora)}</strong>

              {g.avisos.map(a => {
                const enlace = enlaceWhatsApp(a.telefono, a.texto)
                return (
                  <div key={a.id} className="linea-surtido" style={{ marginTop: 10 }}>
                    <div className="fila" style={{ justifyContent: 'space-between' }}>
                      <strong>{etiquetaPara(a.destinatario)} · {a.nombre || 'Sin nombre'}</strong>
                      <span className="etiqueta">{etiquetaTipo(a.tipo)}</span>
                    </div>
                    <div className="ayuda">
                      {a.telefono || (a.destinatario === 'tecnico'
                        ? 'Sin teléfono: captúralo en Usuarios.'
                        : 'Sin teléfono: captúralo en Contactos.')}
                    </div>

                    <details>
                      <summary className="resumen">Ver mensaje</summary>
                      <pre className="mensaje-aviso">{a.texto}</pre>
                    </details>

                    <div className="fila">
                      {enlace
                        ? (
                          <a className="btn btn-primario" href={enlace} target="_blank" rel="noreferrer"
                            onClick={() => marcar(a.id, 'enviado')}>
                            Enviar por WhatsApp
                          </a>
                        )
                        : <span className="etiqueta etiqueta-aviso">Falta el teléfono</span>}
                      <button type="button" onClick={() => copiar(a)}>
                        {copiado === a.id ? 'Copiado' : 'Copiar mensaje'}
                      </button>
                      <button type="button" className="btn-peligro" onClick={() => descartar(a)} disabled={ocupado === a.id}>
                        Descartar
                      </button>
                    </div>
                  </div>
                )
              })}
            </div>
          ))}
        </>
      )}

      {recientes.length > 0 && (
        <details className="tarjeta">
          <summary className="resumen">Avisos de los últimos 3 días ({recientes.length})</summary>
          {recientes.map(a => {
            const enlace = a.estado === 'enviado' ? enlaceWhatsApp(a.telefono, a.texto) : null
            return (
              <div key={a.id} className="linea-surtido" style={{ marginTop: 8 }}>
                <div className="fila" style={{ justifyContent: 'space-between' }}>
                  <strong>{etiquetaPara(a.destinatario)} · {a.nombre || 'Sin nombre'}</strong>
                  <span className="etiqueta">{a.estado === 'enviado' ? 'Enviado' : 'Descartado'}</span>
                </div>
                <div className="ayuda">
                  {etiquetaTipo(a.tipo)} · {a.cliente} · {cuandoCorto(a.fecha, a.hora)}
                  {a.enviado_at && <> · {cuandoEnvio(a.enviado_at)}</>}
                </div>
                {enlace && (
                  <div>
                    <a className="btn" href={enlace} target="_blank" rel="noreferrer">Enviar de nuevo</a>
                  </div>
                )}
              </div>
            )
          })}
        </details>
      )}
    </section>
  )
}
