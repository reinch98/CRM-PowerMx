import { useEffect, useState } from 'react'
import { Alerta } from './ui'
import { haceCuanto } from './lib/whatsapp'
import {
  ETIQUETA_ESTADO, ordenarSolicitudes, contarNuevas, detalleSolicitud, enlaceRespuesta,
  cargarSolicitudes, resolverSolicitud
} from './lib/solicitudesWeb'
import {
  resumenCalculo, avisosDeCalculo, barrasHistorial, partidasDePaqueteSolar, clienteDeSolicitud,
  notasDeSolicitud, cargarPaqueteParaCotizar
} from './lib/calculoSolar'
import { dejarEncargo } from './lib/encargo'

const pesos = n => '$' + Math.round(Number(n) || 0).toLocaleString('es-MX')

// ---------------------------------------------------------------------------
// Lo que calculó la calculadora solar del sitio (SQL 98) y el paso a la cotización (fase 5).
// ---------------------------------------------------------------------------
function CalculoSolar({ s, irA }) {
  const c = s.calculo
  const [variante, setVariante] = useState('interconectado')
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')
  const resumen = resumenCalculo(c)
  const avisos = avisosDeCalculo(c)
  const barras = barrasHistorial(c?.historial)
  const sku = c?.paquete?.sku

  // Arma la cotización aquí (precio de HOY y piezas de la receta) y la deja de encargo para
  // Cotizaciones, que la abre como nueva: nada se guarda hasta que el admin la revisa.
  async function crearCotizacion() {
    setOcupado(true); setError('')
    let partidas = []
    let avisosPaquete = []
    let cambio = null
    if (sku) {
      const p = await cargarPaqueteParaCotizar(sku)
      if (p.error) { setOcupado(false); setError(p.error); return }
      const r = partidasDePaqueteSolar({ producto: p.producto, lineas: p.lineas, variante, calculo: c })
      if (r.error) { setOcupado(false); setError(r.error); return }
      partidas = r.partidas; avisosPaquete = r.avisos; cambio = r.cambio
    }
    dejarEncargo('cotizaciones', {
      solicitud: { id: s.id, nombre: s.nombre },
      clienteId: s.cliente_id || null,
      clienteNuevo: clienteDeSolicitud(s, c),
      tipo: 'instalacion',
      notas: notasDeSolicitud(s, c),
      partidas,
      avisos: [...avisos.filter(a => a.nivel === 'alto').map(a => a.texto), ...avisosPaquete],
      cambio,
      aLaMedida: !sku,
    })
    setOcupado(false)
    irA('cotizaciones')
  }

  return (
    <section className="calculo-solar" aria-label="Calculadora solar">
      <h3 style={{ margin: 0 }}>Calculadora solar</h3>

      {avisos.map(a => (
        <Alerta key={a.clave} tipo={a.nivel === 'alto' ? 'error' : 'info'} palabra={a.nivel === 'alto' ? 'Importante' : 'Nota'}>
          {a.texto}
        </Alerta>
      ))}

      <dl style={{ display: 'grid', gap: 6, margin: 0 }}>
        {resumen.map(f => (
          <div key={f.etiqueta}>
            <dt className="ayuda" style={{ margin: 0 }}>{f.etiqueta}</dt>
            <dd style={{ margin: 0 }}>{f.valor}</dd>
          </div>
        ))}
      </dl>

      {barras.length > 0 && (
        <div>
          <p className="ayuda" style={{ margin: '4px 0' }}>Consumo de sus recibos (el más reciente arriba)</p>
          <ul className="historial-barras">
            {barras.map(b => (
              <li key={b.etiqueta}>
                <span>{b.etiqueta} · <strong>{b.kwh.toLocaleString('es-MX')} kWh</strong>{b.importe ? ` · pagó ${pesos(b.importe)}` : ''}</span>
                <span className="historial-barra" style={{ width: `${b.pct}%` }} aria-hidden="true" />
              </li>
            ))}
          </ul>
        </div>
      )}

      {s.cotizaciones?.folio ? (
        <Alerta tipo="ok" palabra="Ya cotizada">
          Esta solicitud ya tiene la cotización <strong>{s.cotizaciones.folio}</strong>.{' '}
          <button type="button" onClick={() => irA('cotizaciones')}>Ver Cotizaciones</button>
        </Alerta>
      ) : (
        <>
          {sku && (
            <fieldset className="campo" style={{ border: 0, padding: 0, margin: 0 }}>
              <legend className="ayuda">¿Qué sistema cotizar?</legend>
              <label className="casilla">
                <input type="radio" name={`variante-${s.id}`} checked={variante === 'interconectado'}
                  onChange={() => setVariante('interconectado')} />
                Interconectado (el que vio en la calculadora)
              </label>
              <label className="casilla">
                <input type="radio" name={`variante-${s.id}`} checked={variante === 'respaldo'}
                  onChange={() => setVariante('respaldo')} />
                Con respaldo en apagones (híbrido)
              </label>
            </fieldset>
          )}
          {error && <Alerta tipo="error">{error}</Alerta>}
          <div className="fila">
            <button type="button" className="btn-primario" disabled={ocupado} onClick={crearCotizacion}>
              {ocupado ? 'Armando la cotización…' : sku ? 'Crear cotización con este paquete' : 'Crear cotización a la medida'}
            </button>
          </div>
          <p className="ayuda" style={{ margin: 0 }}>
            {sku
              ? 'Se abre en Cotizaciones con el precio de hoy y las piezas del paquete; nada se guarda hasta que la revises.'
              : 'Se abre en Cotizaciones con el cliente y los datos del cálculo; las partidas las armas tú.'}
          </p>
        </>
      )}
    </section>
  )
}

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
        {s.calculo && (
          <p style={{ margin: 0 }}><span className="etiqueta etiqueta-aviso">Calculadora solar</span></p>
        )}
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

        {s.calculo && <CalculoSolar s={s} irA={irA} />}

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
