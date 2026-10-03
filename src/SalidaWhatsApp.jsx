import { useEffect, useState } from 'react'
import { Alerta } from './ui'
import {
  etiquetaEstado, etiquetaOrigen, agruparCola, esperanPorPlantilla, leerVariables, variablesValidas,
  nombreMes, mesesCampana, mesInicial, resultadoEnvio, porcentaje,
  cargarCola, aprobarSalida, cancelarSalida, cargarConfig, guardarConfig, cargarPlantillas, guardarPlantilla,
  cargarCampana, proponerTanda, quitarDeTanda, aprobarTanda, cancelarTanda,
} from './lib/salidaWa'

const cuando = iso => iso ? new Date(iso).toLocaleString('es-MX', { dateStyle: 'short', timeStyle: 'short' }) : ''

// ---------------------------------------------------------------------------
// Un renglón de la cola. Nivel superior (no dentro de otro componente).
// ---------------------------------------------------------------------------
function FilaCola({ f, acciones }) {
  return (
    <div className="orden-item" style={{ cursor: 'default' }}>
      <span className="fila" style={{ justifyContent: 'space-between', width: '100%' }}>
        <strong>{etiquetaOrigen(f.origen)}</strong>
        <span className="etiqueta">{etiquetaEstado(f.estado)}</span>
      </span>
      <span className="ayuda">{f.telefono}{f.plantilla && <> · plantilla {f.plantilla}</>} · {cuando(f.creado)}</span>
      {f.texto && <span>{f.texto}</span>}
      {f.error && <span className="ayuda">Motivo: {f.error}</span>}
      {acciones && <span className="fila" style={{ marginTop: 6 }}>{acciones}</span>}
    </div>
  )
}

function EditorPlantilla({ p, onGuardada }) {
  const [vars, setVars] = useState((p.variables || []).join(', '))
  const [estado, setEstado] = useState(p.estado)
  const [error, setError] = useState('')
  const [ok, setOk] = useState('')
  async function guardar() {
    setError(''); setOk('')
    const lista = leerVariables(vars)
    if (!variablesValidas(lista)) return setError('Las variables van en minúsculas, sin espacios ni acentos (ej. nombre, fecha_cita).')
    if (estado === 'aprobada' && lista.length === 0) return setError('Una plantilla aprobada necesita sus variables (o confirma que no lleva ninguna dejándolo en revisión).')
    const r = await guardarPlantilla(p.nombre, { variables: lista, estado })
    if (!r.ok) return setError(r.texto)
    setOk('Guardada.'); onGuardada()
  }
  return (
    <section className="tarjeta">
      <div className="fila" style={{ justifyContent: 'space-between' }}>
        <h3 style={{ margin: 0 }}>{p.nombre}</h3>
        <span className="etiqueta">{p.estado === 'aprobada' ? 'Aprobada' : p.estado === 'rechazada' ? 'Rechazada' : p.estado === 'borrador' ? 'Sin mandar a Meta' : 'En revisión'}</span>
      </div>
      <p className="ayuda">
        {p.categoria === 'marketing' ? 'Marketing' : 'Utilidad'} · {p.idioma}
        {p.encabezado === 'documento' && ' · lleva el PDF como encabezado'}
        {p.notas && <> · {p.notas}</>}
      </p>
      <label className="campo">
        <span>Variables, como quedaron en Meta</span>
        <input value={vars} onChange={e => setVars(e.target.value)} placeholder="nombre, servicio, fecha" />
      </label>
      <label className="campo">
        <span>Estado en Meta</span>
        <select value={estado} onChange={e => setEstado(e.target.value)}>
          <option value="borrador">Todavía no la mando</option>
          <option value="en_revision">En revisión</option>
          <option value="aprobada">Aprobada</option>
          <option value="rechazada">Rechazada</option>
        </select>
      </label>
      {estado === 'aprobada' && p.estado !== 'aprobada' && (
        <Alerta tipo="aviso" palabra="Antes">
          Revisa que las variables sean exactamente las de Meta, en el mismo orden. Si no coinciden, Meta rechaza cada envío.
        </Alerta>
      )}
      {error && <Alerta tipo="error">{error}</Alerta>}
      {ok && <Alerta tipo="ok" palabra="Listo">{ok}</Alerta>}
      <button type="button" className="btn-primario" onClick={guardar}>Guardar</button>
    </section>
  )
}

// ---------------------------------------------------------------------------
// Pestaña "Por enviar": la cola, el interruptor y las plantillas.
// ---------------------------------------------------------------------------
export function ColaSalida({ onCambio }) {
  const [filas, setFilas] = useState(null)
  const [config, setConfig] = useState(null)
  const [plantillas, setPlantillas] = useState([])
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState('')

  async function recargar() {
    const [c, k, p] = await Promise.all([cargarCola(), cargarConfig(), cargarPlantillas()])
    if (c.ok) { setFilas(c.filas); setError('') } else setError(c.texto)
    if (k.ok) setConfig(k.config)
    if (p.ok) setPlantillas(p.plantillas)
    onCambio?.()
  }
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    recargar()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  async function cambiarConfig(cambios) {
    setConfig(k => ({ ...k, ...cambios }))
    const r = await guardarConfig(cambios)
    if (!r.ok) setError(r.texto)
  }
  async function aprobar(ids) {
    setMensaje('')
    const r = await aprobarSalida(ids)
    if (!r.ok) return setError(r.texto)
    setMensaje(ids.length === 1 ? 'Aprobado.' : `${ids.length} aprobados.`); recargar()
  }
  async function cancelar(ids, motivo) {
    setMensaje('')
    const r = await cancelarSalida(ids, motivo)
    if (!r.ok) return setError(r.texto)
    setMensaje('Quitado de la cola.'); recargar()
  }

  const g = agruparCola(filas || [])
  const aprobadas = plantillas.filter(p => p.estado === 'aprobada').length

  return (
    <>
      {error && <Alerta tipo="error">{error}</Alerta>}
      {mensaje && <Alerta tipo="ok" palabra="Listo">{mensaje}</Alerta>}

      {config && (
        <section className="tarjeta">
          <h3>Envío por la API de Meta</h3>
          <label className="casilla">
            <input type="checkbox" checked={!!config.envio_activo}
              onChange={e => cambiarConfig({ envio_activo: e.target.checked })} />
            {config.envio_activo ? 'Encendido: lo aprobado sale solo' : 'Apagado: nada sale todavía'}
          </label>
          {!config.envio_activo && (
            <p className="ayuda">
              Enciéndelo cuando el número real esté verificado y el token permanente esté guardado en Supabase.
              Mientras tanto puedes aprobar: lo aprobado espera aquí.
            </p>
          )}
          <label className="casilla">
            <input type="checkbox" checked={!!config.avisos_automaticos}
              onChange={e => cambiarConfig({ avisos_automaticos: e.target.checked })} />
            Los avisos de cita salen solos al confirmar la cita
          </label>
          <p className="ayuda">
            {config.avisos_automaticos
              ? 'Al confirmar una cita, su aviso pasa directo a la cola.'
              : 'Cada aviso espera tu aprobación aquí abajo. Enciéndelo cuando veas que el envío funciona bien.'}
          </p>
        </section>
      )}

      {filas === null && !error && <p>Cargando…</p>}

      {filas && (
        <>
          <div className="fila" style={{ justifyContent: 'space-between' }}>
            <h3 style={{ margin: 0 }}>Por aprobar ({g.porAprobar.length})</h3>
            {g.porAprobar.length > 1 && (
              <button type="button" className="btn-primario" onClick={() => aprobar(g.porAprobar.map(f => f.id))}>
                Aprobar todos
              </button>
            )}
          </div>
          {g.porAprobar.length === 0 && <p className="ayuda">Nada esperando tu aprobación.</p>}
          {g.porAprobar.map(f => (
            <FilaCola key={f.id} f={f} acciones={<>
              <button type="button" className="btn-primario" onClick={() => aprobar([f.id])}>Aprobar</button>
              <button type="button" onClick={() => cancelar([f.id], 'no se mandó')}>No mandar</button>
            </>} />
          ))}

          {g.problemas.length > 0 && (
            <>
              <h3>Con problema ({g.problemas.length})</h3>
              <Alerta tipo="aviso" palabra="Revisa">
                "Sin confirmar" quiere decir que el envío se cortó a la mitad: puede que sí haya llegado.
                Revisa el chat en el celular antes de volver a mandarlo. No se reintenta solo para no duplicar.
              </Alerta>
              {g.problemas.map(f => (
                <FilaCola key={f.id} f={f} acciones={
                  <button type="button" onClick={() => cancelar([f.id], 'revisado por la oficina')}>Ya lo revisé, quitar</button>
                } />
              ))}
            </>
          )}

          {g.esperanMeta.length > 0 && (
            <section className="tarjeta">
              <h3>Esperan a que Meta apruebe la plantilla ({g.esperanMeta.length})</h3>
              <ul style={{ paddingLeft: 20 }}>
                {esperanPorPlantilla(g.esperanMeta).map(([pl, n]) => <li key={pl}>{pl}: {n}</li>)}
              </ul>
              <p className="ayuda">Ya están aprobados por ti. Salen solos en cuanto marques la plantilla como aprobada.</p>
            </section>
          )}

          {g.enCamino.length > 0 && (
            <p className="ayuda">
              {g.enCamino.length} listo{g.enCamino.length === 1 ? '' : 's'} para salir
              {config?.envio_activo ? ' en el siguiente minuto.' : ' en cuanto enciendas el envío.'}
            </p>
          )}
        </>
      )}

      <details className="tarjeta">
        <summary className="resumen">Plantillas · {aprobadas} aprobada{aprobadas === 1 ? '' : 's'} de {plantillas.length}</summary>
        <p className="ayuda" style={{ marginTop: 8 }}>
          Cuando Meta apruebe una, copia aquí sus variables tal como quedaron y márcala aprobada. Si la rechaza,
          márcala rechazada y anota el motivo para reescribirla.
        </p>
        {plantillas.map(p => <EditorPlantilla key={p.nombre + p.estado} p={p} onGuardada={recargar} />)}
      </details>
    </>
  )
}

// ---------------------------------------------------------------------------
// Pestaña "Campañas": el mes, la tanda de la semana y los resultados.
// ---------------------------------------------------------------------------
export function Campanas() {
  const meses = mesesCampana()
  const [mes, setMes] = useState(mesInicial(new Date(), meses))
  const [datos, setDatos] = useState(null)
  const [n, setN] = useState(37)
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState('')
  const [ocupado, setOcupado] = useState(false)

  async function recargar(m = mes) {
    setDatos(null)
    const r = await cargarCampana(m)
    if (r.ok) { setDatos(r); setError('') } else setError(r.texto)
  }
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    recargar()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  function cambiarMes(m) { setMes(m); setMensaje(''); recargar(m) }

  async function accion(fn, exito) {
    setError(''); setMensaje(''); setOcupado(true)
    const r = await fn()
    setOcupado(false)
    if (!r.ok) return setError(r.texto)
    setMensaje(exito(r.data || {})); recargar()
  }

  const res = datos?.resultados
  const p = datos?.propuesta

  return (
    <>
      <label className="campo">
        <span>Mes</span>
        <select value={mes} onChange={e => cambiarMes(e.target.value)}>
          {meses.map(m => <option key={m} value={m}>{nombreMes(m)}</option>)}
        </select>
      </label>

      {error && <Alerta tipo="error">{error}</Alerta>}
      {mensaje && <Alerta tipo="ok" palabra="Listo">{mensaje}</Alerta>}
      {!datos && !error && <p>Cargando…</p>}

      {res && res.cargados === 0 && (
        <section className="tarjeta">
          <h3>{nombreMes(mes)} todavía no está cargado</h3>
          <ol style={{ paddingLeft: 20, display: 'grid', gap: 8 }}>
            <li>Marca en la hoja Asignación a los clientes que confirmaron con PowerMx.</li>
            <li>Corre <strong>campanas_csv.py</strong>: deja <strong>campana_powermx_{mes}.csv</strong> en la carpeta campanas.</li>
            <li>Supabase → Table Editor → <strong>campana_envios</strong> → Insert → Import data from CSV.</li>
          </ol>
        </section>
      )}

      {res && res.cargados > 0 && (
        <section className="tarjeta">
          <h3>{nombreMes(mes)}</h3>
          <div className="rejilla-2">
            <p>Cargados: <strong>{res.cargados}</strong></p>
            <p>Por proponer: <strong>{res.por_proponer}</strong></p>
            <p>Enviados: <strong>{res.enviados}</strong></p>
            <p>Respondieron: <strong>{res.respondieron}</strong> ({porcentaje(res.respondieron, res.enviados)})</p>
            <p>Sacaron cita: <strong>{res.citas}</strong></p>
            <p>Pidieron BAJA: <strong>{res.bajas}</strong></p>
          </div>
        </section>
      )}

      {res && res.cargados > 0 && !p && res.por_proponer > 0 && (
        <section className="tarjeta">
          <h3>Tanda de esta semana</h3>
          <label className="campo">
            <span>Cuántos</span>
            <input type="number" inputMode="numeric" min={1} max={250} value={n}
              onChange={e => setN(Number(e.target.value) || 1)} />
          </label>
          <p className="ayuda">Toma a los siguientes en el orden del plan. Quien pidió BAJA o recibió algo hace poco se deja fuera con el motivo.</p>
          <button type="button" className="btn-primario" disabled={ocupado}
            onClick={() => accion(() => proponerTanda(mes, n),
              d => d.vacia ? 'No quedó nadie para esta tanda.' : `Tanda ${d.numero}: ${d.en_tanda} para revisar${d.omitidos ? `, ${d.omitidos} omitidos` : ''}.`)}>
            Proponer tanda
          </button>
        </section>
      )}

      {p && (
        <section className="tarjeta">
          <h3>Tanda {p.numero} · por revisar ({datos.enTanda.length})</h3>
          <p className="ayuda">Quita a quien no quieras escribirle esta semana; vuelve a la lista para otra tanda.</p>
          {datos.enTanda.map(e => (
            <div key={e.id} className="orden-item" style={{ cursor: 'default' }}>
              <strong>{e.nombre || e.telefono}</strong>
              <span className="ayuda">{e.telefono} · {e.categoria}{e.equipo && <> · {e.equipo}</>} · {e.plantilla}</span>
              <span className="fila" style={{ marginTop: 6 }}>
                <button type="button" onClick={() => accion(() => quitarDeTanda([e.id]), () => 'Quitado; queda para otra semana.')}>Quitar</button>
                <button type="button" onClick={() => accion(() => quitarDeTanda([e.id], true, 'no escribirle'), () => 'No se le volverá a proponer este mes.')}>No escribirle</button>
              </span>
            </div>
          ))}
          <div className="fila" style={{ marginTop: 12 }}>
            <button type="button" className="btn-primario" disabled={ocupado || datos.enTanda.length === 0}
              onClick={() => accion(() => aprobarTanda(p.id),
                d => `${d.a_la_cola} a la cola${d.omitidos ? `, ${d.omitidos} omitidos` : ''}${d.esperan_plantilla ? `. ${d.esperan_plantilla} esperan a que Meta apruebe su plantilla` : ''}.`)}>
              Aprobar tanda
            </button>
            <button type="button" disabled={ocupado} onClick={() => accion(() => cancelarTanda(p.id), () => 'Tanda cancelada; todos vuelven a la lista.')}>
              Cancelar tanda
            </button>
          </div>
        </section>
      )}

      {res && (res.detalle || []).some(d => d.estado === 'aprobado' || d.estado === 'omitido') && (
        <details className="tarjeta">
          <summary className="resumen">Quién ya recibió o se omitió</summary>
          {(res.detalle || []).filter(d => d.estado === 'aprobado' || d.estado === 'omitido').map(d => (
            <div key={d.id} className="orden-item" style={{ cursor: 'default' }}>
              <span className="fila" style={{ justifyContent: 'space-between', width: '100%' }}>
                <strong>{d.nombre || d.telefono}</strong>
                <span className="etiqueta">{resultadoEnvio(d)}</span>
              </span>
              <span className="ayuda">{d.telefono} · {d.categoria}{d.enviado_en && <> · enviado {cuando(d.enviado_en)}</>}</span>
            </div>
          ))}
        </details>
      )}
    </>
  )
}
