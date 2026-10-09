import { useEffect, useState } from 'react'
import { Alerta } from './ui'
import { pesos, fechaLegible, etiquetaCategoria, CATEGORIAS_GASTO } from './lib/finanzas'
import {
  subirYLeerEstado, cuadreEstado, guardarEstado, listarEstados, cargarConciliacion,
  conciliar, conciliarSeguros, desconciliar, ignorar, registrarDesdeBanco
} from './lib/conciliacion'

// ---------------------------------------------------------------------------
// Banco: conciliación del estado de cuenta (SQL 75). La IA lee el PDF y PROPONE; la base empata con el
// libro; tú confirmas. Lo "seguro" (un solo candidato que no le sirve a otro renglón) se concilia de un
// toque; lo demás, eligiendo, registrándolo desde aquí o ignorándolo con motivo.
// ---------------------------------------------------------------------------

const CATEGORIAS_ENTRADA = [['aportacion', 'Aportación del dueño'], ['otro_ingreso', 'Otro ingreso']]
const CATEGORIAS_SALIDA = [...CATEGORIAS_GASTO, ['retiro_dueno', 'Retiro del dueño']]

function Campo({ etiqueta, children }) {
  return <label className="campo"><span>{etiqueta}</span>{children}</label>
}

function Fila({ etiqueta, valor }) {
  return <div className="fila" style={{ justifyContent: 'space-between' }}><span>{etiqueta}</span><strong className="monto">{valor}</strong></div>
}

function Lectura({ leido, cuenta, onGuardado, onDescartar }) {
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')
  const e = leido.estado
  const c = cuadreEstado(e)

  async function guardar() {
    setError(''); setOcupado(true)
    const r = await guardarEstado(cuenta.id, e, leido.ruta)
    setOcupado(false)
    if (r.error) return setError(r.error)
    onGuardado(r.data)
  }

  return (
    <section className="tarjeta" aria-label="Lo que se leyó del estado de cuenta">
      <h3>Lo que se leyó</h3>
      <Alerta tipo="info">Esto lo leyó la IA y puede equivocarse. Revisa que el periodo y los saldos coincidan con tu PDF.</Alerta>
      {error && <Alerta tipo="error">{error}</Alerta>}
      <Fila etiqueta="Periodo" valor={e.periodo_desde ? `${fechaLegible(e.periodo_desde)} a ${fechaLegible(e.periodo_hasta)}` : 'Sin leer'} />
      <Fila etiqueta="Saldo inicial" valor={e.saldo_inicial == null ? '—' : pesos(e.saldo_inicial)} />
      <Fila etiqueta={`Entradas (${e.movimientos.filter(m => m.abono > 0).length})`} valor={pesos(c.abonos)} />
      <Fila etiqueta={`Salidas (${e.movimientos.filter(m => m.cargo > 0).length})`} valor={pesos(c.cargos)} />
      <Fila etiqueta="Saldo final" valor={e.saldo_final == null ? '—' : pesos(e.saldo_final)} />
      {c.cuadra === true && <Alerta tipo="ok">El estado cuadra: saldo inicial + entradas − salidas = saldo final.</Alerta>}
      {c.cuadra === false && <Alerta tipo="aviso">No cuadra por {pesos(Math.abs(c.diferencia))}: falta o sobra algún renglón. Revisa antes de guardar.</Alerta>}
      {c.cuadra == null && <Alerta tipo="aviso">No se leyeron los saldos: no se puede comprobar que estén todos los renglones.</Alerta>}
      {e.descartados > 0 && <Alerta tipo="aviso">{e.descartados === 1 ? '1 renglón no se pudo leer y no se guardará.' : `${e.descartados} renglones no se pudieron leer y no se guardarán.`}</Alerta>}
      {e.cuenta_ultimos4 && cuenta.ultimos4 && e.cuenta_ultimos4 !== cuenta.ultimos4 && (
        <Alerta tipo="aviso">El PDF es de la cuenta que termina en {e.cuenta_ultimos4} y elegiste {cuenta.nombre} (termina en {cuenta.ultimos4}).</Alerta>
      )}
      {e.notas && <p className="ayuda">Nota de la lectura: {e.notas}</p>}
      <div className="fila">
        <button type="button" className="btn-primario" disabled={ocupado || e.movimientos.length === 0} onClick={guardar}>
          {ocupado ? 'Guardando…' : `Guardar ${e.movimientos.length} movimientos`}
        </button>
        <button type="button" onClick={onDescartar}>Descartar</button>
      </div>
    </section>
  )
}

function Pendiente({ p, onCambio }) {
  const [modo, setModo] = useState('')
  const [cat, setCat] = useState(p.sentido === 'entrada' ? 'otro_ingreso' : 'comisiones_bancarias')
  const [concepto, setConcepto] = useState('')
  const [nota, setNota] = useState('')
  const [error, setError] = useState('')
  const [ocupado, setOcupado] = useState(false)

  async function correr(fn) {
    setError(''); setOcupado(true)
    const r = await fn()
    setOcupado(false)
    if (r?.error) return setError(r.error)
    onCambio()
  }

  const categorias = p.sentido === 'entrada' ? CATEGORIAS_ENTRADA : CATEGORIAS_SALIDA
  const etiqueta = p.seguro ? 'Seguro' : p.candidatos.length ? 'Elige' : 'Sin pareja'
  const clase = p.seguro ? 'estado-aprobado' : p.candidatos.length ? 'estado-revisa' : 'estado-error'
  return (
    <section className="tarjeta" aria-label={`${p.descripcion || 'Movimiento'} ${pesos(p.monto)}`}>
      <div className="renglon-titulo">{p.descripcion || 'Sin descripción'}</div>
      <div className="renglon-datos">{[fechaLegible(p.fecha), p.referencia && `Ref. ${p.referencia}`].filter(Boolean).join(' · ')}</div>
      <div className="fila" style={{ justifyContent: 'space-between', marginTop: 6 }}>
        <span className={`estado ${clase}`}>{etiqueta}</span>
        <span>
          <span className="ayuda">{p.sentido === 'entrada' ? 'Entrada ' : 'Salida '}</span>
          <span className={`monto ${p.sentido === 'entrada' ? 'monto-entrada' : 'monto-salida'}`} style={{ fontSize: 20 }}>{pesos(p.monto)}</span>
        </span>
      </div>
      {error && <Alerta tipo="error">{error}</Alerta>}

      {p.candidatos.length > 0 && (
        <div className="buscador-lista" style={{ position: 'static', marginTop: 10 }}>
          {p.candidatos.map(c => (
            <button key={c.movimiento_id} type="button" disabled={ocupado} onClick={() => correr(() => conciliar(p.mov_banco_id, c.movimiento_id))}>
              Es: {c.concepto || etiquetaCategoria(c.categoria)}
              <span className="ayuda">
                {[fechaLegible(c.fecha), c.dias === 0 ? 'el mismo día' : `${c.dias} ${c.dias === 1 ? 'día' : 'días'} de diferencia`,
                  c.cotizacion && `Cotización ${c.cotizacion}`].filter(Boolean).join(' · ')}
              </span>
            </button>
          ))}
        </div>
      )}

      {modo === 'registrar' && (
        <div style={{ marginTop: 10 }}>
          <div className="rejilla-2">
            <Campo etiqueta="¿Qué es?">
              <select value={cat} onChange={e => setCat(e.target.value)}>
                {categorias.map(([k, t]) => <option key={k} value={k}>{t}</option>)}
              </select>
            </Campo>
            <Campo etiqueta="Concepto">
              <input value={concepto} onChange={e => setConcepto(e.target.value)} placeholder={p.descripcion || ''} />
            </Campo>
          </div>
          {p.sentido === 'entrada' && <p className="ayuda">Si es el cobro de una cotización, regístralo en su Expediente y vuelve aquí: aparecerá como candidato.</p>}
          <div className="fila">
            <button type="button" className="btn-primario" disabled={ocupado} onClick={() => correr(() => registrarDesdeBanco(p.mov_banco_id, cat, concepto))}>Registrar y conciliar</button>
            <button type="button" onClick={() => setModo('')}>Cancelar</button>
          </div>
        </div>
      )}
      {modo === 'ignorar' && (
        <div style={{ marginTop: 10 }}>
          <Campo etiqueta="¿Por qué se ignora? *">
            <input value={nota} onChange={e => setNota(e.target.value)} placeholder="Traspaso entre mis cuentas" />
          </Campo>
          <div className="fila">
            <button type="button" disabled={ocupado || !nota.trim()} onClick={() => correr(() => ignorar(p.mov_banco_id, nota.trim()))}>Ignorar</button>
            <button type="button" onClick={() => setModo('')}>Cancelar</button>
          </div>
        </div>
      )}
      {!modo && (
        <div className="fila" style={{ marginTop: 10 }}>
          <button type="button" onClick={() => setModo('registrar')}>Registrar como…</button>
          <button type="button" onClick={() => setModo('ignorar')}>Ignorar…</button>
        </div>
      )}
    </section>
  )
}

function Resueltos({ titulo, lista, accion, onAccion }) {
  if (lista.length === 0) return null
  return (
    <details className="tarjeta">
      <summary className="resumen">{titulo} ({lista.length})</summary>
      <ul style={{ listStyle: 'none', margin: 0, padding: 0 }}>
        {lista.map(x => (
          <li key={x.id} className="renglon">
            <div>
              <div className="renglon-titulo">{x.descripcion || 'Movimiento'}</div>
              <div className="renglon-datos">{[fechaLegible(x.fecha), pesos(Number(x.abono) || Number(x.cargo)), x.nota].filter(Boolean).join(' · ')}</div>
            </div>
            <button type="button" onClick={() => onAccion(x.id)}>{accion}</button>
          </li>
        ))}
      </ul>
    </details>
  )
}

function Estado({ estadoId }) {
  const [vuelta, setVuelta] = useState(0)
  const [leido, setLeido] = useState({ clave: '', datos: null })
  const [mensaje, setMensaje] = useState('')
  const [ocupado, setOcupado] = useState(false)
  const clave = `${estadoId}#${vuelta}`

  useEffect(() => {
    let vivo = true
    cargarConciliacion(estadoId).then(d => { if (vivo) setLeido({ clave: `${estadoId}#${vuelta}`, datos: d }) })
    return () => { vivo = false }
  }, [estadoId, vuelta])

  const d = leido.datos
  const recargar = () => setVuelta(v => v + 1)
  if (!d) return <p>Cargando…</p>
  const conteo = d.resumen?.conteo || {}
  const seguros = d.pendientes.filter(p => p.seguro).length
  const soloLibro = d.resumen?.solo_en_libro || []

  async function todosLosSeguros() {
    setOcupado(true)
    const r = await conciliarSeguros(estadoId)
    setOcupado(false)
    setMensaje(r.error ? '' : `${r.data?.conciliados ?? 0} conciliados.`)
    recargar()
  }
  async function volverAPendiente(id) {
    await desconciliar(id)
    recargar()
  }

  return (
    <div aria-busy={leido.clave !== clave}>
      {d.error && <Alerta tipo="error">{d.error}</Alerta>}
      <div className="kpis">
        <div className="kpi kpi-principal kpi-ancho">
          <span className="kpi-nombre">Por conciliar</span>
          <span className="kpi-valor">{conteo.pendientes ?? 0} de {conteo.total ?? 0}</span>
          <span className="kpi-nota">{conteo.conciliados ?? 0} {conteo.conciliados === 1 ? 'conciliado' : 'conciliados'} · {conteo.ignorados ?? 0} {conteo.ignorados === 1 ? 'ignorado' : 'ignorados'}</span>
        </div>
      </div>
      {d.resumen?.estado?.cuadra === false && (
        <Alerta tipo="aviso">Este estado no cuadró al guardarlo (diferencia {pesos(Math.abs(d.resumen.estado.diferencia))}).</Alerta>
      )}
      {mensaje && <Alerta tipo="ok">{mensaje}</Alerta>}
      {seguros > 0 && (
        <button type="button" className="btn-primario btn-grande" style={{ marginBottom: 16 }} disabled={ocupado} onClick={todosLosSeguros}>
          {ocupado ? 'Conciliando…' : `Conciliar los seguros (${seguros})`}
        </button>
      )}
      {d.pendientes.length === 0 && <Alerta tipo="ok">Nada pendiente en este estado de cuenta.</Alerta>}
      {d.pendientes.map(p => <Pendiente key={p.mov_banco_id} p={p} onCambio={recargar} />)}

      {soloLibro.length > 0 && (
        <details className="tarjeta">
          <summary className="resumen">En el libro pero no en el banco ({soloLibro.length})</summary>
          <p className="ayuda">Movimientos de esta cuenta y de este periodo que no aparecieron en el estado: revisa si la fecha, el monto o la cuenta están bien.</p>
          <ul style={{ listStyle: 'none', margin: 0, padding: 0 }}>
            {soloLibro.map(m => (
              <li key={m.movimiento_id} className="renglon">
                <div>
                  <div className="renglon-titulo">{m.concepto || etiquetaCategoria(m.categoria)}</div>
                  <div className="renglon-datos">{fechaLegible(m.fecha)} · {etiquetaCategoria(m.categoria)}</div>
                </div>
                <span className={`monto ${m.tipo === 'ingreso' ? 'monto-entrada' : 'monto-salida'}`}>{pesos(m.monto)}</span>
              </li>
            ))}
          </ul>
        </details>
      )}
      <Resueltos titulo="Conciliados" lista={d.resueltos.filter(x => x.estado === 'conciliado')} accion="Desconciliar" onAccion={volverAPendiente} />
      <Resueltos titulo="Ignorados" lista={d.resueltos.filter(x => x.estado === 'ignorado')} accion="Volver a pendiente" onAccion={volverAPendiente} />
    </div>
  )
}

export default function Conciliacion({ cuentas }) {
  const bancos = (cuentas || []).filter(c => c.activa && c.tipo === 'banco')
  const [cuentaId, setCuentaId] = useState(() => (bancos.find(c => /banorte/i.test(c.nombre)) || bancos[0])?.id || '')
  const [estados, setEstados] = useState({ cuenta: '', lista: [], error: '' })
  const [estadoId, setEstadoId] = useState('')
  const [leido, setLeido] = useState(null)
  const [leyendo, setLeyendo] = useState(false)
  const [error, setError] = useState('')
  const [vuelta, setVuelta] = useState(0)
  const cuenta = bancos.find(c => c.id === cuentaId)

  useEffect(() => {
    let vivo = true
    if (!cuentaId) return undefined
    listarEstados(cuentaId).then(r => { if (vivo) setEstados({ cuenta: cuentaId, lista: r.estados || [], error: r.error || '' }) })
    return () => { vivo = false }
  }, [cuentaId, vuelta])

  const elegido = estadoId || estados.lista[0]?.id || ''

  async function leer(archivo) {
    if (!archivo) return
    setError(''); setLeido(null); setLeyendo(true)
    const r = await subirYLeerEstado(archivo)
    setLeyendo(false)
    if (r.error) return setError(r.error)
    setLeido(r)
  }

  if (bancos.length === 0) return <Alerta tipo="aviso">Agrega tu cuenta de banco en Ajustes para conciliar.</Alerta>

  return (
    <>
      <Campo etiqueta="Cuenta">
        <select value={cuentaId} onChange={e => { setCuentaId(e.target.value); setEstadoId(''); setLeido(null) }}>
          {bancos.map(c => <option key={c.id} value={c.id}>{c.nombre}{c.ultimos4 ? ` (termina en ${c.ultimos4})` : ''}</option>)}
        </select>
      </Campo>

      {!leido && (
        <label className="zona-subida">
          <input type="file" accept="application/pdf,.pdf" className="oculto-accesible" disabled={leyendo}
            onChange={e => { leer(e.target.files?.[0]); e.target.value = '' }} />
          <strong>{leyendo ? 'Leyendo el estado de cuenta… (puede tardar un minuto)' : 'Sube el estado de cuenta (PDF)'}</strong>
          <span className="ayuda">La IA saca los movimientos; tú revisas y guardas. Subir dos que se traslapan no duplica nada.</span>
        </label>
      )}
      {error && <Alerta tipo="error">{error}</Alerta>}
      {leido && cuenta && (
        <Lectura leido={leido} cuenta={cuenta} onDescartar={() => setLeido(null)}
          onGuardado={r => { setLeido(null); setEstadoId(r.estado_id); setVuelta(v => v + 1) }} />
      )}

      {estados.error && <Alerta tipo="error">{estados.error}</Alerta>}
      {estados.lista.length > 0 && (
        <>
          <h3 style={{ marginTop: 20 }}>Conciliación</h3>
          <Campo etiqueta="Estado de cuenta">
            <select value={elegido} onChange={e => setEstadoId(e.target.value)}>
              {estados.lista.map(s => (
                <option key={s.id} value={s.id}>
                  {s.periodo_desde ? `${fechaLegible(s.periodo_desde)} a ${fechaLegible(s.periodo_hasta)}` : `Subido el ${fechaLegible(String(s.created_at).slice(0, 10))}`}
                </option>
              ))}
            </select>
          </Campo>
          {elegido && <Estado key={elegido} estadoId={elegido} />}
        </>
      )}
      {estados.cuenta === cuentaId && estados.lista.length === 0 && !leido && (
        <p className="ayuda" style={{ marginTop: 12 }}>Aún no has subido estados de cuenta de esta cuenta.</p>
      )}
    </>
  )
}
