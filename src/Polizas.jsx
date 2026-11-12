import { useEffect, useMemo, useState } from 'react'
import { Alerta } from './ui'
import { hoyLocal } from './lib/fechas'
import {
  NIVELES, ALCANCES, tituloNivel, textoTipoVisita, fechaCorta, alcanceDeEquipo, planDeVisitas, finDePoliza,
  totalesPoliza, estadoPoliza, estadoVisita, resumenPolizas, filtrarPolizas, faltasPoliza, describirEquipo,
  buscarEquipos, cargarPolizas, crearPoliza, cancelarPoliza, omitirVisita, cargarEquiposParaPoliza
} from './lib/polizas'

// ---------------------------------------------------------------------------
// Pólizas de servicio (SQL 97). Solo admin.
//
// Dar de alta una póliza arma su calendario y abre la cita de la primera visita en la Agenda
// ("Por programar"); el resto las abre un reloj diario tres semanas antes de su fecha. Aquí se ve
// cómo va cada póliza, qué visita está atrasada y cuáles hay que renovar.
// ---------------------------------------------------------------------------

const pesos = n => Number(n || 0).toLocaleString('es-MX', { style: 'currency', currency: 'MXN' })
const VACIO = { equipo_id: '', nivel: 'estandar', alcance: '', inicio: '', subtotal: '', forma_pago: 'Contado', notas: '', renueva_a: '' }

function FormularioPoliza({ equipos, inicial, onListo, onCancelar }) {
  const [f, setF] = useState(() => ({ ...VACIO, inicio: hoyLocal(), ...inicial }))
  const [busca, setBusca] = useState('')
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')
  const cambia = (k, v) => setF(x => ({ ...x, [k]: v }))

  const equipo = equipos.find(e => e.id === f.equipo_id)
  const alcance = f.alcance || (equipo ? alcanceDeEquipo(equipo) : 'aire')
  const plan = planDeVisitas(f.nivel, alcance, f.inicio)
  const t = totalesPoliza(f.subtotal)
  // Una renovación no lleva inicio: lo pone la base (el día siguiente al fin de la anterior).
  const faltas = faltasPoliza({ ...f, inicio: f.renueva_a ? 'auto' : f.inicio })
  const resultados = buscarEquipos(equipos, busca).slice(0, 8)

  async function guardar() {
    setOcupado(true); setError('')
    const r = await crearPoliza({
      equipo_id: f.equipo_id, nivel: f.nivel, alcance, inicio: f.renueva_a ? null : f.inicio,
      subtotal: Number(f.subtotal), forma_pago: f.forma_pago, notas: f.notas, renueva_a: f.renueva_a || null
    })
    setOcupado(false)
    if (r.error) return setError(r.error)
    const citas = Number(r.data?.citas || 0)
    onListo(`Póliza POL-${r.data.folio} guardada con ${r.data.visitas} visitas.`
      + (citas > 0 ? ' La primera ya está en la Agenda, en "Por programar".' : ' Las citas se abrirán tres semanas antes de cada visita.'))
  }

  return (
    <div style={{ display: 'grid', gap: 12 }}>
      {f.renueva_a ? (
        <Alerta tipo="info">Renovación: empieza el día siguiente al fin de la póliza actual, con el mismo equipo.</Alerta>
      ) : equipo ? (
        <div className="renglon">
          <div>
            <div className="renglon-titulo">{equipo.clientes?.nombre || 'Sin cliente'}</div>
            <div className="renglon-datos">{describirEquipo(equipo)}{equipo.numero_serie ? ` · serie ${equipo.numero_serie}` : ' · serie pendiente'}</div>
          </div>
          <button type="button" onClick={() => cambia('equipo_id', '')}>Cambiar equipo</button>
        </div>
      ) : (
        <div>
          <label className="campo">
            <span>Equipo *</span>
            <input value={busca} onChange={e => setBusca(e.target.value)} placeholder="Cliente, marca, modelo o serie" />
          </label>
          <div className="buscador">
            {resultados.map(e => (
              <button key={e.id} type="button" onClick={() => { cambia('equipo_id', e.id); setBusca('') }}>
                <strong>{e.clientes?.nombre || 'Sin cliente'}</strong> · {describirEquipo(e)}
                {e.en_poliza ? ' · ya en póliza' : ''}
              </button>
            ))}
            {resultados.length === 0 && <p style={{ margin: 0 }}>Ningún generador coincide.</p>}
          </div>
        </div>
      )}

      <fieldset style={{ border: 0, padding: 0, margin: 0, display: 'grid', gap: 8 }}>
        <legend style={{ fontWeight: 700, marginBottom: 8 }}>Nivel *</legend>
        {NIVELES.map(n => (
          <button key={n.clave} type="button" className="pestana" aria-pressed={f.nivel === n.clave}
            style={{ textAlign: 'left', display: 'block' }} onClick={() => cambia('nivel', n.clave)}>
            <strong>{n.titulo}</strong> — {n.resumen}
          </button>
        ))}
      </fieldset>

      <div className="rejilla-2">
        <label className="campo">
          <span>Alcance técnico</span>
          <select value={alcance} onChange={e => cambia('alcance', e.target.value)}>
            {ALCANCES.map(a => <option key={a.clave} value={a.clave}>{a.titulo}</option>)}
          </select>
        </label>
        {!f.renueva_a && (
          <label className="campo">
            <span>Inicio *</span>
            <input type="date" value={f.inicio} onChange={e => cambia('inicio', e.target.value)} />
          </label>
        )}
        <label className="campo">
          <span>Precio antes de IVA *</span>
          <input type="number" min="0" step="100" inputMode="decimal" value={f.subtotal} onChange={e => cambia('subtotal', e.target.value)} />
        </label>
        <label className="campo">
          <span>Forma de pago</span>
          <input value={f.forma_pago} onChange={e => cambia('forma_pago', e.target.value)} />
        </label>
      </div>
      <label className="campo">
        <span>Notas</span>
        <textarea rows={2} value={f.notas} onChange={e => cambia('notas', e.target.value)} />
      </label>

      {plan.length > 0 && (
        <div>
          <p style={{ margin: '0 0 4px', fontWeight: 700 }}>
            {plan.length} visitas{f.inicio && !f.renueva_a ? ` · vigencia al ${fechaCorta(finDePoliza(f.inicio))}` : ''}
          </p>
          {plan.map(v => (
            <div key={v.numero} className="renglon-datos">
              {v.numero}. {textoTipoVisita(v)}{v.fecha && !f.renueva_a ? ` · ${fechaCorta(v.fecha)}` : ''}
            </div>
          ))}
        </div>
      )}
      {Number(f.subtotal) > 0 && (
        <p style={{ margin: 0 }}>Subtotal {pesos(t.subtotal)} · IVA {pesos(t.iva)} · <strong>Total {pesos(t.total)}</strong></p>
      )}

      {error && <Alerta tipo="error">{error}</Alerta>}
      {faltas.length > 0 && <Alerta tipo="aviso" palabra="Falta">{faltas.join(' ')}</Alerta>}
      <div className="fila" style={{ flexWrap: 'wrap' }}>
        <button type="button" className="btn-primario" disabled={ocupado || faltas.length > 0} onClick={guardar}>
          {ocupado ? 'Guardando…' : f.renueva_a ? 'Guardar la renovación' : 'Guardar la póliza'}
        </button>
        {onCancelar && <button type="button" disabled={ocupado} onClick={onCancelar}>Cancelar</button>}
      </div>
    </div>
  )
}

function Visita({ v, hoy, vigente, irA, onCambio, onAviso }) {
  const [omitiendo, setOmitiendo] = useState(false)
  const [motivo, setMotivo] = useState('')
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')
  const e = estadoVisita(v, hoy)
  const abierta = vigente && ['pendiente', 'agendada'].includes(v.estado)

  async function omitir() {
    setOcupado(true); setError('')
    const r = await omitirVisita(v.id, motivo)
    setOcupado(false)
    if (r.error) return setError(r.error)
    setOmitiendo(false); setMotivo('')
    onAviso(`Visita ${v.numero} omitida.`); onCambio()
  }

  return (
    <div style={{ padding: '8px 0', borderTop: '1px solid var(--borde)' }}>
      <div className="fila" style={{ justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
        <div>
          <div style={{ fontWeight: 600 }}>{v.numero}. {textoTipoVisita(v)}</div>
          <div className="renglon-datos">Toca el {fechaCorta(v.fecha)}{v.motivo ? ` · ${v.motivo}` : ''}</div>
        </div>
        <span className={e.clase}><strong>{e.atrasada ? '⚠ ' : ''}{e.etiqueta}</strong></span>
      </div>
      {abierta && !omitiendo && (
        <div className="fila" style={{ flexWrap: 'wrap', marginTop: 4 }}>
          {v.estado === 'agendada' && <button type="button" onClick={() => irA?.('agenda')}>Ir a la Agenda</button>}
          <button type="button" onClick={() => setOmitiendo(true)}>No hacer esta visita…</button>
        </div>
      )}
      {omitiendo && (
        <div style={{ display: 'grid', gap: 8, marginTop: 8 }}>
          <label className="campo">
            <span>¿Por qué no se hará? *</span>
            <input value={motivo} onChange={ev => setMotivo(ev.target.value)} />
          </label>
          {error && <Alerta tipo="error">{error}</Alerta>}
          <div className="fila" style={{ flexWrap: 'wrap' }}>
            <button type="button" className="btn-peligro" disabled={ocupado || !motivo.trim()} onClick={omitir}>
              {ocupado ? 'Guardando…' : 'Omitir la visita'}
            </button>
            <button type="button" disabled={ocupado} onClick={() => { setOmitiendo(false); setMotivo(''); setError('') }}>No</button>
          </div>
        </div>
      )}
    </div>
  )
}

function TarjetaPoliza({ p, hoy, equipos, irA, onCambio, onAviso }) {
  const [modo, setModo] = useState('')   // '' | 'renovar' | 'cancelar'
  const [motivo, setMotivo] = useState('')
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')
  const e = estadoPoliza(p, hoy)
  const visitas = p.visitas || []
  const hechas = visitas.filter(v => v.estado === 'realizada').length
  const cuentan = visitas.filter(v => !['omitida', 'cancelada'].includes(v.estado)).length
  const vigente = p.estado === 'vigente' && p.fin >= hoy
  const sePuedeRenovar = p.estado === 'vigente' && !p.renovada
  const urgeRenovar = ['por_vencer', 'vencida'].includes(e.clave)

  async function cancelar() {
    setOcupado(true); setError('')
    const r = await cancelarPoliza(p.id, motivo)
    setOcupado(false)
    if (r.error) return setError(r.error)
    const conTrabajo = Number(r.data?.citas_con_trabajo || 0)
    setModo(''); setMotivo('')
    onAviso(`POL-${p.folio} cancelada.` + (conTrabajo > 0 ? ` ${conTrabajo} cita(s) ya tenían trabajo y se quedaron: ciérralas en Órdenes.` : ''))
    onCambio()
  }

  return (
    <div className="tarjeta" style={{ display: 'grid', gap: 8 }}>
      <div className="fila" style={{ justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
        <div style={{ minWidth: 0 }}>
          <div className="renglon-titulo">POL-{p.folio} · {p.cliente}</div>
          <div className="renglon-datos">
            {p.equipo}{p.serie ? ` · serie ${p.serie}` : ''} · {tituloNivel(p.nivel)} · {p.alcance === 'liquido' ? 'enfriado por líquido' : 'enfriado por aire'}
          </div>
          <div className="renglon-datos">
            Del {fechaCorta(p.inicio)} al {fechaCorta(p.fin)} · {hechas} de {cuentan} visitas hechas
            {p.forma_pago ? ` · ${p.forma_pago}` : ''}
          </div>
          {p.motivo && p.estado === 'cancelada' && <div className="renglon-datos">Motivo: {p.motivo}</div>}
        </div>
        <div className="renglon-lado">
          <span className="monto">{pesos(p.total)}</span>
          <span className={e.clase}><strong>{e.etiqueta}</strong></span>
        </div>
      </div>

      <details>
        <summary style={{ padding: '12px 0', fontWeight: 600, cursor: 'pointer' }}>Ver las visitas</summary>
        {visitas.map(v => (
          <Visita key={v.id} v={v} hoy={hoy} vigente={vigente} irA={irA} onCambio={onCambio} onAviso={onAviso} />
        ))}
      </details>

      {error && <Alerta tipo="error">{error}</Alerta>}

      {modo === 'renovar' && (
        <FormularioPoliza equipos={equipos}
          inicial={{ equipo_id: p.equipo_id, nivel: p.nivel, alcance: p.alcance, renueva_a: p.id, subtotal: String(p.subtotal || '') }}
          onListo={t => { setModo(''); onAviso(t); onCambio() }} onCancelar={() => setModo('')} />
      )}
      {modo === 'cancelar' && (
        <div style={{ display: 'grid', gap: 8 }}>
          <Alerta tipo="aviso" palabra="Confirma">
            Se cancelan las visitas que faltan y sus citas sin trabajo. El equipo deja de estar en póliza.
          </Alerta>
          <label className="campo">
            <span>¿Por qué se cancela? *</span>
            <input value={motivo} onChange={ev => setMotivo(ev.target.value)} />
          </label>
          <div className="fila" style={{ flexWrap: 'wrap' }}>
            <button type="button" className="btn-peligro" disabled={ocupado || !motivo.trim()} onClick={cancelar}>
              {ocupado ? 'Guardando…' : 'Cancelar la póliza'}
            </button>
            <button type="button" disabled={ocupado} onClick={() => { setModo(''); setMotivo(''); setError('') }}>No</button>
          </div>
        </div>
      )}
      {!modo && p.estado === 'vigente' && (
        <div className="fila" style={{ flexWrap: 'wrap' }}>
          {sePuedeRenovar && (
            <button type="button" className={urgeRenovar ? 'btn-primario' : undefined} onClick={() => setModo('renovar')}>Renovar…</button>
          )}
          {vigente && <button type="button" onClick={() => setModo('cancelar')}>Cancelar la póliza…</button>}
        </div>
      )}
    </div>
  )
}

export default function Polizas({ irA }) {
  const [datos, setDatos] = useState(null)
  const [equipos, setEquipos] = useState([])
  const [vuelta, setVuelta] = useState(0)
  const [filtro, setFiltro] = useState('vigentes')
  const [alta, setAlta] = useState(false)
  const [aviso, setAviso] = useState('')
  const hoy = hoyLocal()

  useEffect(() => {
    let vivo = true
    Promise.all([cargarPolizas(), cargarEquiposParaPoliza()]).then(([p, e]) => {
      if (!vivo) return
      setDatos(p)
      if (e.data) setEquipos(e.data)
    })
    return () => { vivo = false }
  }, [vuelta])

  const lista = useMemo(() => datos?.data || [], [datos])
  const r = resumenPolizas(lista, hoy)
  const visibles = filtrarPolizas(lista, filtro, hoy)
  const recargar = () => setVuelta(v => v + 1)

  return (
    <div className="pagina">
      <h2>Pólizas de servicio</h2>
      <p className="ayuda" style={{ marginTop: 0 }}>
        Al guardar una póliza, su primera visita aparece en la Agenda como "Por programar". Las siguientes se abren solas tres semanas antes de su fecha.
      </p>

      {aviso && <Alerta tipo="ok">{aviso}</Alerta>}

      <div className="kpis">
        <div className="kpi kpi-principal">
          <span className="kpi-nombre">Vigentes</span>
          <span className="kpi-valor">{r.vigentes}</span>
        </div>
        <div className="kpi">
          <span className="kpi-nombre">Por vencer</span>
          <span className="kpi-valor">{r.porVencer}</span>
          <span className="kpi-nota">30 días o menos, sin renovar</span>
        </div>
        <div className="kpi">
          <span className="kpi-nombre">Visitas atrasadas</span>
          <span className="kpi-valor">{r.atrasadas}</span>
        </div>
        <div className="kpi">
          <span className="kpi-nombre">Vencidas sin renovar</span>
          <span className="kpi-valor">{r.vencidas}</span>
        </div>
      </div>

      <details className="tarjeta" open={alta} onToggle={ev => setAlta(ev.currentTarget.open)}>
        <summary className="resumen">Nueva póliza</summary>
        {alta && (
          <FormularioPoliza key={vuelta} equipos={equipos}
            onListo={t => { setAviso(t); setAlta(false); recargar() }} />
        )}
      </details>

      <div className="pestanas">
        {[['vigentes', 'Vigentes'], ['atender', 'Por atender'], ['todas', 'Todas']].map(([k, t]) => (
          <button key={k} type="button" className="pestana" aria-pressed={filtro === k} onClick={() => setFiltro(k)}>{t}</button>
        ))}
      </div>

      {!datos && <p>Cargando…</p>}
      {datos?.error && <Alerta tipo="error">{datos.error}</Alerta>}
      {datos && !datos.error && visibles.length === 0 && (
        <p>{lista.length === 0 ? 'Todavía no hay pólizas. Da de alta la primera arriba.' : 'Nada en esta lista.'}</p>
      )}
      {visibles.map(p => (
        <TarjetaPoliza key={p.id} p={p} hoy={hoy} equipos={equipos} irA={irA}
          onCambio={recargar} onAviso={t => setAviso(t)} />
      ))}
    </div>
  )
}
