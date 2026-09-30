import { useEffect, useState } from 'react'
import { Alerta } from './ui'
import { cargarInicio, porNivel, cuantasEsperan, textoCita, hayDia } from './lib/inicio'

// ---------------------------------------------------------------------------
// El inicio del admin (SQL 42).
//
// Antes se entraba a la Agenda, que muestra el calendario pero **no lo que está esperando**:
// una devolución de seis días o una solicitud del sitio sin ver no se notaban hasta abrir esa
// pantalla. Esto convierte el CRM en algo que dice qué atender.
//
// Cada aviso es un BOTÓN que lleva a su pantalla: leer que hay tres cotizaciones por revisar
// y tener que ir a buscarlas sería la mitad del trabajo.
//
// El técnico y el almacenista no ven esta pantalla: su lista ya es su inicio.
// ---------------------------------------------------------------------------

const DIAS = ['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado']
const MESES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre']

// La fecha en palabras, leída como fecha local: `new Date('2026-09-28')` se interpreta en UTC
// y en Mérida mostraría el día anterior.
function fechaLarga(iso) {
  if (!iso) return ''
  const [a, m, d] = String(iso).split('-').map(Number)
  if (!a || !m || !d) return iso
  const f = new Date(a, m - 1, d)
  return `${DIAS[f.getDay()]} ${d} de ${MESES[m - 1]}`
}

export default function Inicio({ irA }) {
  const [datos, setDatos] = useState(null)
  const [error, setError] = useState('')

  useEffect(() => {
    let vigente = true
    cargarInicio().then(r => {
      if (!vigente) return
      if (!r.ok) setError(r.texto)
      else setDatos(r.datos)
    })
    return () => { vigente = false }
  }, [])

  if (error) {
    return (
      <div className="pagina">
        <h2>Inicio</h2>
        <Alerta tipo="error">{error}</Alerta>
      </div>
    )
  }
  if (!datos) return <div className="pagina"><p className="ayuda">Viendo qué está esperando…</p></div>

  const urgente = datos.urgente || []
  const hoy = datos.hoy || []
  const total = cuantasEsperan(urgente)
  const grupos = porNivel(urgente)

  return (
    <div className="pagina">
      <h2>{fechaLarga(datos.fecha)}</h2>

      {/* ---- lo que está esperando ---- */}
      {total === 0 ? (
        <Alerta tipo="ok" palabra="Al día">
          No hay nada esperando. {hayDia(hoy) ? 'Revisa las citas de hoy.' : 'Tampoco hay citas hoy.'}
        </Alerta>
      ) : (
        <>
          <p className="ayuda">
            {total === 1 ? '1 cosa esperando' : `${total} cosas esperando`}
          </p>
          {grupos.map(g => (
            <div key={g.nivel} style={{ marginTop: 12 }}>
              {/* El nivel va con palabra, no con color: "Atender hoy", no un punto rojo. */}
              <h3>{g.etiqueta}</h3>
              <div className="fila" style={{ flexWrap: 'wrap' }}>
                {g.items.map(u => (
                  <button key={u.clave} type="button"
                    className={g.nivel === 'alto' ? 'btn-primario' : undefined}
                    onClick={() => irA(u.pantalla)}>
                    {u.texto}
                  </button>
                ))}
              </div>
            </div>
          ))}
        </>
      )}

      {/* ---- el día ---- */}
      <h3 style={{ marginTop: 22 }}>Hoy</h3>
      {!hayDia(hoy) ? (
        <p className="ayuda">No hay citas programadas para hoy.</p>
      ) : (
        <div className="items-lista">
          {hoy.map(c => (
            <div key={c.cita_id} className="tarjeta" style={{ marginTop: 8 }}>
              <div className="fila" style={{ justifyContent: 'space-between', flexWrap: 'wrap' }}>
                <strong>{textoCita(c)}</strong>
                <span className={`estado estado-${c.estado}`}>{String(c.estado || "").replace(/_/g, " ")}</span>
              </div>
              <div className="ayuda">
                {c.tipo || 'servicio'}
                {c.orden ? ` · orden ${c.orden}` : ' · sin orden'}
              </div>
            </div>
          ))}
        </div>
      )}

      <div className="fila" style={{ marginTop: 16, flexWrap: 'wrap' }}>
        <button type="button" onClick={() => irA('agenda')}>Ver la Agenda</button>
        <button type="button" onClick={() => irA('ordenes')}>Ver las órdenes</button>
      </div>
    </div>
  )
}
