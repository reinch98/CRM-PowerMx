import { useEffect, useState } from 'react'
import { Alerta } from './ui'
import { haceCuanto } from './lib/whatsapp'
import {
  ETIQUETA_ESTADO, ordenarSolicitudes, contarNuevas, detalleSolicitud, enlaceRespuesta,
  cargarSolicitudes, resolverSolicitud
} from './lib/solicitudesWeb'

// ---------------------------------------------------------------------------
// Una solicitud del sitio. Componente de nivel superior (no dentro de otro) para que la
// caja de la nota no pierda el foco al escribir.
// ---------------------------------------------------------------------------
function TarjetaSolicitud({ s, irA, onCambio }) {
  const [nota, setNota] = useState(s.nota_interna || '')
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')

  async function resolver(estado) {
    setOcupado(true); setError('')
    const r = await resolverSolicitud(s.id, estado, nota)
    setOcupado(false)
    if (!r.ok) { setError(r.texto); return }
    onCambio()
  }

  const enlace = enlaceRespuesta(s)
  const detalle = detalleSolicitud(s)

  return (
    <details className="tarjeta">
      <summary className="resumen">
        <strong>{s.nombre}</strong>
        {' '}
        <span className={s.estado === 'nueva' ? 'etiqueta etiqueta-aviso' : 'etiqueta'}>
          {ETIQUETA_ESTADO[s.estado]}
        </span>
        <span className="ayuda"> · {s.telefono} · {haceCuanto(s.created_at)}</span>
      </summary>

      <div style={{ display: 'grid', gap: 10, marginTop: 10 }}>
        {s.clientes?.nombre ? (
          <Alerta tipo="info" palabra="Ya es cliente">
            Este número coincide con <strong>{s.clientes.nombre}</strong>.
          </Alerta>
        ) : (
          <p className="ayuda">Número nuevo: todavía no está en Clientes ni en Contactos.</p>
        )}

        <dl style={{ display: 'grid', gap: 6, margin: 0 }}>
          {detalle.map(f => (
            <div key={f.etiqueta}>
              <dt className="ayuda" style={{ margin: 0 }}>{f.etiqueta}</dt>
              <dd style={{ margin: 0 }}>{f.valor}</dd>
            </div>
          ))}
          {s.notas && (
            <div>
              <dt className="ayuda" style={{ margin: 0 }}>Lo que escribió</dt>
              <dd style={{ margin: 0, whiteSpace: 'pre-wrap' }}>{s.notas}</dd>
            </div>
          )}
        </dl>

        {s.estado !== 'nueva' && s.atendida_por && (
          <p className="ayuda">
            {ETIQUETA_ESTADO[s.estado]} por {s.atendida_por}
            {s.atendida_en && <> · {new Date(s.atendida_en).toLocaleString('es-MX', { dateStyle: 'short', timeStyle: 'short' })}</>}
          </p>
        )}

        <label className="campo">
          <span>Nota interna (qué pasó con esta solicitud)</span>
          <textarea rows={2} value={nota} onChange={e => setNota(e.target.value)} />
        </label>

        {error && <Alerta tipo="error">{error}</Alerta>}

        <div className="fila" style={{ flexWrap: 'wrap', gap: 8 }}>
          {enlace && (
            <a className="btn-primario" href={enlace} target="_blank" rel="noreferrer">
              Responder por WhatsApp
            </a>
          )}
          {s.estado === 'nueva' ? (
            <>
              <button disabled={ocupado} onClick={() => resolver('atendida')}>Marcar atendida</button>
              <button disabled={ocupado} onClick={() => resolver('descartada')}>Descartar</button>
            </>
          ) : (
            <button disabled={ocupado} onClick={() => resolver('nueva')}>Reabrir</button>
          )}
          {!s.clientes?.nombre && irA && (
            <button onClick={() => irA('clientes')}>Ir a Clientes para darlo de alta</button>
          )}
        </div>
      </div>
    </details>
  )
}

export default function Solicitudes({ irA }) {
  const [solicitudes, setSolicitudes] = useState(null)
  const [error, setError] = useState('')
  const [verTodas, setVerTodas] = useState(false)

  async function cargar() {
    const r = await cargarSolicitudes()
    if (r.ok) { setSolicitudes(r.solicitudes); setError('') }
    else setError(r.texto)
  }
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    cargar()
  }, [])

  const ordenadas = ordenarSolicitudes(solicitudes)
  const nuevas = contarNuevas(solicitudes)
  const visibles = verTodas ? ordenadas : ordenadas.filter(s => s.estado === 'nueva')

  return (
    <div className="pagina-angosta">
      <h2>Solicitudes del sitio</h2>
      <p className="ayuda">
        Lo que la gente llena en powermx.com.mx → Cotizar. Aquí nada se convierte en cliente
        solo: tú decides cuáles atender.
      </p>

      {error && <Alerta tipo="error">{error}</Alerta>}
      {solicitudes === null && !error && <p>Cargando…</p>}

      {solicitudes && nuevas > 0 && (
        <Alerta tipo="aviso" palabra="Por atender">
          {nuevas} solicitud{nuevas === 1 ? '' : 'es'} nueva{nuevas === 1 ? '' : 's'}.
        </Alerta>
      )}

      <label className="casilla">
        <input type="checkbox" checked={verTodas} onChange={e => setVerTodas(e.target.checked)} />
        Ver también las atendidas y descartadas
      </label>

      {solicitudes && visibles.length === 0 && (
        <section className="tarjeta">
          <h3>{verTodas ? 'Todavía no ha llegado ninguna' : 'No hay solicitudes nuevas'}</h3>
          <p className="ayuda">Cuando alguien llene el formulario del sitio, aparecerá aquí.</p>
        </section>
      )}

      {visibles.map(s => <TarjetaSolicitud key={s.id} s={s} irA={irA} onCambio={cargar} />)}
    </div>
  )
}
