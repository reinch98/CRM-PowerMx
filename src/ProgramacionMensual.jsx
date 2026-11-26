import { useEffect, useState } from 'react'
import { Alerta } from './ui'
import {
  cargarProgramacion, abrirMes, marcarRevisada, cargarTecnicos, programarCita,
  nombreMes, mesSiguiente, primeroDeMes, fechaLarga, queVisita, resumenMes, pendientesDelMes,
  porZona, fechaPropuesta, enlaceCoordinar, mesInicial
} from './lib/programacion'
import { hoyLocal } from './lib/fechas'

// ---------------------------------------------------------------------------
// Programación mensual (SQL 105), arriba del Inicio del admin.
//
// El día 1 la base abre las citas de todas las visitas de póliza del mes. Esta tarjeta es el
// recordatorio: dice cuántas faltan por programar, las agrupa por zona para armar rutas, deja
// escribirle al cliente con un mensaje ya escrito y programar cada una aquí mismo (fecha, hora y
// técnico, con el mismo aviso de empalmes de la Agenda). Al terminar: "Ya quedó programado el mes".
// ---------------------------------------------------------------------------

export default function ProgramacionMensual({ irA }) {
  const [mes, setMes] = useState(() => mesInicial(hoyLocal()))
  const [datos, setDatos] = useState(null)
  const [error, setError] = useState('')
  const [tecnicos, setTecnicos] = useState([])
  const [abierta, setAbierta] = useState(null)  // null = según haya pendientes
  const [vuelta, setVuelta] = useState(0)
  const [aviso, setAviso] = useState('')

  useEffect(() => {
    let vivo = true
    cargarProgramacion(mes).then(r => {
      if (!vivo) return
      if (r.error) setError(r.error)
      else { setError(''); setDatos(r.data) }
    })
    return () => { vivo = false }
  }, [mes, vuelta])

  useEffect(() => {
    let vivo = true
    cargarTecnicos().then(r => { if (vivo && r.data) setTecnicos(r.data) })
    return () => { vivo = false }
  }, [])

  if (error) return <Alerta tipo="error">No se pudo leer la programación del mes: {error}</Alerta>
  if (!datos) return null

  const recargar = () => setVuelta(v => v + 1)
  const hoy = datos.hoy
  const esteMes = primeroDeMes(hoy)
  const elMes = datos.mes
  const nm = nombreMes(elMes)
  const r = resumenMes(datos)
  const faltan = pendientesDelMes(r)
  const revisada = !!datos.revisada_en
  const estaAbierta = abierta ?? (faltan > 0 && !revisada)
  const citas = datos.citas || []
  const porProgramar = citas.filter(c => c.estado === 'por_programar')
  const programadas = citas.filter(c => c.estado === 'programada')
  const plural = (n, uno, varios) => (n === 1 ? uno : varios)

  const abrir = async () => {
    setAviso('')
    const res = await abrirMes(elMes)
    if (res.error) return setAviso(res.error)
    setAviso(res.data.citas === 1 ? 'Se abrió 1 cita.' : `Se abrieron ${res.data.citas} citas.`)
    recargar()
  }
  const revisar = async valor => {
    const res = await marcarRevisada(elMes, valor)
    if (res.error) return setAviso(res.error)
    if (valor) setAbierta(false)
    recargar()
  }

  const extras = [
    r.programadas ? `${r.programadas} ${plural(r.programadas, 'ya programada', 'ya programadas')}` : null,
    r.sugeridos ? `${r.sugeridos} ${plural(r.sugeridos, 'cliente sin póliza por contactar', 'clientes sin póliza por contactar')}` : null
  ].filter(Boolean)

  return (
    <section className="tarjeta" style={{ marginBottom: 16 }} aria-labelledby="programacion-titulo">
      <div className="fila" style={{ justifyContent: 'space-between', flexWrap: 'wrap' }}>
        <h3 id="programacion-titulo" style={{ margin: 0 }}>Programación de {nm}</h3>
        <div className="fila" style={{ flexWrap: 'wrap' }}>
          <button type="button" aria-pressed={elMes === esteMes} onClick={() => setMes(esteMes)}>Este mes</button>
          <button type="button" aria-pressed={elMes !== esteMes} onClick={() => setMes(mesSiguiente(esteMes))}>
            Mes siguiente
          </button>
        </div>
      </div>

      {revisada ? (
        <Alerta tipo="ok" palabra="Programado">
          El mes quedó revisado{faltan > 0 ? `, pero aún ${plural(faltan, 'hay 1 visita', `hay ${faltan} visitas`)} sin fecha` : ''}.
        </Alerta>
      ) : faltan > 0 ? (
        <Alerta tipo="aviso" palabra="Por programar">
          {plural(faltan, '1 visita', `${faltan} visitas`)} de {nm} sin fecha{extras.length ? ` · ${extras.join(' · ')}` : ''}.
        </Alerta>
      ) : (
        <p className="ayuda">Nada por programar en {nm}{extras.length ? ` · ${extras.join(' · ')}` : ''}.</p>
      )}

      {aviso && <Alerta tipo="info">{aviso}</Alerta>}

      <button type="button" onClick={() => setAbierta(!estaAbierta)} aria-expanded={estaAbierta}>
        {estaAbierta ? 'Ocultar el detalle' : 'Programar el mes'}
      </button>

      {estaAbierta && (
        <div style={{ marginTop: 12 }}>
          {r.sinCita > 0 && (
            <div style={{ marginBottom: 12 }}>
              <h4>Visitas de póliza sin cita todavía ({r.sinCita})</h4>
              <p className="ayuda">
                Sus citas se abren solas el día 1 a las 7:00. Si quieres acomodarlas desde ya, ábrelas ahora.
              </p>
              <button type="button" className="btn-primario" onClick={abrir}>Abrir las citas de {nm}</button>
              <Grupos items={datos.sin_cita} render={v => (
                <TarjetaVisita key={v.visita_id} v={v} mes={elMes} pie="Sin cita: ábrela para programarla." />
              )} />
            </div>
          )}

          {porProgramar.length > 0 && (
            <div style={{ marginBottom: 12 }}>
              <h4>Por programar ({porProgramar.length})</h4>
              <Grupos items={porProgramar} render={c => (
                <TarjetaVisita key={c.cita_id} v={c} mes={elMes}>
                  <Programar cita={c} hoy={hoy} tecnicos={tecnicos} onHecho={recargar} />
                </TarjetaVisita>
              )} />
            </div>
          )}

          {programadas.length > 0 && (
            <div style={{ marginBottom: 12 }}>
              <h4>Programadas en {nm} ({programadas.length})</h4>
              {programadas.map(c => (
                <div key={c.cita_id} className="tarjeta" style={{ marginTop: 8 }}>
                  <div className="fila" style={{ justifyContent: 'space-between', flexWrap: 'wrap' }}>
                    <strong>{fechaLarga(c.fecha)}{c.hora ? ` · ${c.hora} h` : ''} · {c.cliente}</strong>
                    <span className="estado estado-programada">✓ Programada</span>
                  </div>
                  <div className="ayuda">
                    {queVisita(c)}{c.equipo ? ` · ${c.equipo}` : ''} · {c.tecnico || 'sin técnico'}
                    {c.ayudante ? ` y ${c.ayudante}` : ''}{c.orden ? ` · orden ${c.orden}` : ''}
                  </div>
                </div>
              ))}
            </div>
          )}

          {r.sugeridos > 0 && (
            <div style={{ marginBottom: 12 }}>
              <h4>Sin póliza: les toca mantenimiento ({r.sugeridos})</h4>
              <p className="ayuda">No tienen contrato, así que no se les abre cita sola: escríbeles y, si aceptan, agéndalos en la Agenda.</p>
              <Grupos items={datos.sugeridos} render={v => (
                <TarjetaVisita key={v.equipo_id} v={v} mes={elMes} pie={`Le toca el ${fechaLarga(v.proximo)}.`}>
                  <button type="button" style={{ marginTop: 6 }} onClick={() => irA('agenda')}>Ir a la Agenda</button>
                </TarjetaVisita>
              )} />
            </div>
          )}

          <div className="fila" style={{ flexWrap: 'wrap', marginTop: 8 }}>
            {revisada
              ? <button type="button" onClick={() => revisar(false)}>Reabrir la programación de {nm}</button>
              : <button type="button" className="btn-primario" onClick={() => revisar(true)}>Ya quedó programado {nm}</button>}
            <button type="button" onClick={() => irA('agenda')}>Ver la Agenda</button>
          </div>
        </div>
      )}
    </section>
  )
}

function Grupos({ items, render }) {
  return porZona(items).map(g => (
    <div key={g.zona} style={{ marginTop: 8 }}>
      <p className="ayuda" style={{ fontWeight: 700, margin: '8px 0 0' }}>
        {g.zona} · {g.lista.length === 1 ? '1 visita' : `${g.lista.length} visitas`}
      </p>
      {g.lista.map(render)}
    </div>
  ))
}

function TarjetaVisita({ v, mes, pie, children }) {
  const wa = enlaceCoordinar(v, mes)
  return (
    <div className="tarjeta" style={{ marginTop: 8 }}>
      <div className="fila" style={{ justifyContent: 'space-between', flexWrap: 'wrap' }}>
        <strong>{v.cliente}</strong>
        <span className="estado estado-por_programar">⏳ Sin fecha</span>
      </div>
      <div className="ayuda">
        {queVisita(v)}{v.equipo ? ` · ${v.equipo}` : ''}
        {v.fecha_sugerida ? ` · toca el ${fechaLarga(v.fecha_sugerida)}` : ''}
        {v.contacto ? ` · ${v.contacto}` : ''}{v.telefono ? ` ${v.telefono}` : ''}
      </div>
      {pie && <div className="ayuda">{pie}</div>}
      <div className="fila" style={{ flexWrap: 'wrap', marginTop: 6 }}>
        {wa
          ? <a className="btn" href={wa} target="_blank" rel="noreferrer">Escribirle por WhatsApp</a>
          : <span className="ayuda">Sin teléfono en la ficha</span>}
        {v.maps_url && <a className="btn" href={v.maps_url} target="_blank" rel="noreferrer">Cómo llegar</a>}
      </div>
      {children}
    </div>
  )
}

function Programar({ cita, hoy, tecnicos, onHecho }) {
  const [abierto, setAbierto] = useState(false)
  const [f, setF] = useState(() => ({
    fecha: fechaPropuesta(cita, hoy), hora: '09:00', duracion: '120', t1: cita.tecnico_id || '', t2: cita.tecnico2_id || ''
  }))
  const [error, setError] = useState('')
  const [enviando, setEnviando] = useState(false)
  const cambia = k => e => setF({ ...f, [k]: e.target.value })

  const enviar = async (e, confirmar = false) => {
    e?.preventDefault()
    setError('')
    if (!f.fecha) return setError('Falta la fecha')
    if (f.t1 && f.t1 === f.t2) return setError('El responsable y su ayudante no pueden ser la misma persona')
    if (f.t2 && !f.t1) return setError('Elige al técnico responsable antes que a su ayudante')
    setEnviando(true)
    const r = await programarCita(cita.cita_id, f, confirmar)
    setEnviando(false)
    if (r.error) return setError(r.error)
    if (r.data?.ok === false) {
      const partes = []
      if (r.data.empalmes?.length) {
        partes.push('Se empalma con: ' + r.data.empalmes
          .map(x => `${x.hora?.slice(0, 5) || ''} ${x.cliente} (${x.tecnicos})`).join('; '))
      }
      if (r.data.orden_con_trabajo) partes.push('La orden ya tiene trabajo capturado.')
      if (confirm(`${partes.join('\n\n')}\n\n¿Programarla de todos modos?`)) return enviar(null, true)
      return
    }
    onHecho()
  }

  if (!abierto) {
    return <button type="button" className="btn-primario" style={{ marginTop: 6 }} onClick={() => setAbierto(true)}>Programar</button>
  }
  return (
    <form onSubmit={enviar} style={{ marginTop: 8 }}>
      <div className="rejilla-2">
        <label className="campo">Fecha<input type="date" value={f.fecha} min={hoy} onChange={cambia('fecha')} required /></label>
        <label className="campo">Hora<input type="time" value={f.hora} onChange={cambia('hora')} /></label>
        <label className="campo">Duración (min)<input type="number" min="15" step="15" value={f.duracion} onChange={cambia('duracion')} /></label>
        <label className="campo">Técnico responsable
          <select value={f.t1} onChange={cambia('t1')}>
            <option value="">Sin asignar</option>
            {tecnicos.map(t => <option key={t.id} value={t.id}>{t.nombre}</option>)}
          </select>
        </label>
        <label className="campo">Ayudante
          <select value={f.t2} onChange={cambia('t2')}>
            <option value="">Sin ayudante</option>
            {tecnicos.map(t => <option key={t.id} value={t.id}>{t.nombre}</option>)}
          </select>
        </label>
      </div>
      {error && <Alerta tipo="error">{error}</Alerta>}
      <div className="fila" style={{ flexWrap: 'wrap' }}>
        <button type="submit" className="btn-primario" disabled={enviando}>{enviando ? 'Guardando…' : 'Guardar la cita'}</button>
        <button type="button" onClick={() => setAbierto(false)}>Cancelar</button>
      </div>
    </form>
  )
}
