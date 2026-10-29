import { useEffect, useState } from 'react'
import { Alerta } from './ui'
import {
  cargarPlantillas, plantillasParaEscribir, etiquetaVariable, datosQueFaltan, escribirACliente
} from './lib/salidaWa'

// ---------------------------------------------------------------------------
// Escribirle a un cliente con una plantilla aprobada (SQL 93). Con la ventana de 24 h cerrada, o a
// un cliente que nunca escribió, WhatsApp solo deja mandar plantillas. Sale por el número de
// PowerMx, por la misma cola que los avisos de cita.
//
// · En la bandeja: se elige a la persona (de Contactos) o se escribe el número.
// · En una conversación con la ventana cerrada: el número ya viene fijo (`telefonoFijo`).
// ---------------------------------------------------------------------------
export default function EscribirACliente({ contactos = [], telefonoFijo = '', nombreSugerido = '', onEnviado }) {
  const [plantillas, setPlantillas] = useState(null)
  const [contactoId, setContactoId] = useState('')
  const [telefono, setTelefono] = useState(telefonoFijo)
  const [nombrePlantilla, setNombrePlantilla] = useState('')
  const [valores, setValores] = useState({ nombre: nombreSugerido })
  const [confirmar, setConfirmar] = useState(false)
  const [ocupado, setOcupado] = useState(false)
  const [resultado, setResultado] = useState(null)

  useEffect(() => {
    let vivo = true
    cargarPlantillas().then(r => {
      if (!vivo) return
      if (r.ok) setPlantillas(plantillasParaEscribir(r.plantillas))
      else setResultado({ tipo: 'error', texto: r.texto })
    })
    return () => { vivo = false }
  }, [])

  const plantilla = (plantillas || []).find(p => p.nombre === nombrePlantilla) || null
  const faltan = datosQueFaltan(plantilla, valores)
  const digitos = telefono.replace(/\D/g, '')
  const telefonoValido = digitos.length >= 10

  function elegirContacto(id) {
    setContactoId(id)
    const c = contactos.find(x => x.id === id)
    if (c) {
      setTelefono(c.telefono || '')
      setValores(v => ({ ...v, nombre: c.nombre || v.nombre }))
    }
    setConfirmar(false); setResultado(null)
  }

  async function enviar() {
    setOcupado(true); setResultado(null)
    const datos = Object.fromEntries((plantilla.variables || []).map(v => [v, valores[v] || '']))
    const r = await escribirACliente(digitos, plantilla.nombre, datos)
    setOcupado(false); setConfirmar(false)
    if (!r.ok) return setResultado({ tipo: 'error', texto: r.texto })
    const d = r.data || {}
    if (d.repetido) {
      setResultado({ tipo: 'info', texto: 'Ya habías mandado esta misma plantilla a este número hace unos minutos: no se repitió.' })
    } else if (!d.envio_activo) {
      setResultado({ tipo: 'aviso', texto: 'Quedó en la cola, pero el envío por la API está apagado: enciéndelo en WhatsApp → Por enviar.' })
    } else {
      setResultado({ tipo: 'ok', texto: 'En la cola: sale por el número de PowerMx en el siguiente minuto.' })
    }
    onEnviado?.()
  }

  if (plantillas === null) return <p className="ayuda">Cargando plantillas…</p>
  if (plantillas.length === 0) {
    return (
      <Alerta tipo="aviso" palabra="Sin plantillas">
        No hay plantillas aprobadas que se puedan mandar a mano. Dalas de alta en Meta y márcalas
        como aprobadas en WhatsApp → Por enviar.
      </Alerta>
    )
  }

  return (
    <div>
      <p className="ayuda">
        WhatsApp solo deja escribir primero con una plantilla que aprobó Meta. El cliente recibe el
        texto aprobado con los datos que pongas aquí. Si contesta, se abre la ventana de 24 horas y
        ya le escribes libre.
      </p>

      {!telefonoFijo && (
        <>
          <label className="campo">
            <span>A quién</span>
            <select value={contactoId} onChange={e => elegirContacto(e.target.value)}>
              <option value="">— Elige de Contactos o escribe el número abajo —</option>
              {contactos.filter(c => c.telefono).map(c => (
                <option key={c.id} value={c.id}>
                  {c.nombre}{c.clientes?.nombre ? ` · ${c.clientes.nombre}` : ''} · {c.telefono}
                </option>
              ))}
            </select>
          </label>
          <label className="campo">
            <span>Teléfono (10 dígitos)</span>
            <input type="tel" inputMode="tel" value={telefono}
              onChange={e => { setTelefono(e.target.value); setContactoId(''); setConfirmar(false) }} />
          </label>
        </>
      )}

      <label className="campo">
        <span>Plantilla</span>
        <select value={nombrePlantilla}
          onChange={e => { setNombrePlantilla(e.target.value); setConfirmar(false); setResultado(null) }}>
          <option value="">— Elige —</option>
          {plantillas.map(p => (
            <option key={p.nombre} value={p.nombre}>
              {p.nombre}{p.categoria === 'marketing' ? ' (publicidad)' : ''}
            </option>
          ))}
        </select>
      </label>

      {plantilla && (
        <>
          {plantilla.notas && <p className="ayuda" style={{ whiteSpace: 'pre-wrap' }}>{plantilla.notas}</p>}
          {plantilla.categoria === 'marketing' && (
            <p className="ayuda">
              <span className="etiqueta etiqueta-aviso">Publicidad</span> Meta la cobra más cara y el
              cliente puede pedir BAJA. Para dar seguimiento a un trabajo, mejor una de utilidad.
            </p>
          )}
          {(plantilla.variables || []).map(v => (
            <label key={v} className="campo">
              <span>{etiquetaVariable(v)}</span>
              <input value={valores[v] || ''}
                onChange={e => { setValores(x => ({ ...x, [v]: e.target.value })); setConfirmar(false) }} />
            </label>
          ))}

          {!confirmar ? (
            <button type="button" className="btn-primario"
              disabled={!telefonoValido || faltan.length > 0}
              onClick={() => { setConfirmar(true); setResultado(null) }}>
              Revisar y enviar
            </button>
          ) : (
            <div className="tarjeta" style={{ padding: 10 }}>
              <p style={{ margin: '0 0 6px' }}>
                Se va a mandar <strong>{plantilla.nombre}</strong> al <strong>{telefono}</strong> con:
              </p>
              <ul style={{ margin: '0 0 8px', paddingLeft: 20 }}>
                {(plantilla.variables || []).map(v => <li key={v}>{etiquetaVariable(v)}: {valores[v]}</li>)}
              </ul>
              <div className="fila">
                <button type="button" className="btn-primario" disabled={ocupado} onClick={enviar}>
                  {ocupado ? 'Enviando…' : 'Sí, mandarlo'}
                </button>
                <button type="button" disabled={ocupado} onClick={() => setConfirmar(false)}>Corregir</button>
              </div>
            </div>
          )}
          {!telefonoValido && <p className="ayuda">Falta el teléfono.</p>}
          {telefonoValido && faltan.length > 0 && (
            <p className="ayuda">Falta: {faltan.map(etiquetaVariable).join(', ')}.</p>
          )}
        </>
      )}

      {resultado && <Alerta tipo={resultado.tipo}>{resultado.texto}</Alerta>}
    </div>
  )
}
