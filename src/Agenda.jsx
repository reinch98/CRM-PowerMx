import { useEffect, useMemo, useState } from 'react'
import { supabase } from './lib/supabase'
import { usuarioLocal, leerLocal } from './lib/local'
import { hoyLocal } from './lib/fechas'
import { explicarError } from './lib/errores'
import { partidasDeDiagnostico, importe } from './lib/tarifas'
import { Alerta } from './ui'

const DIAS = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom']
const MESES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre']

const TIPOS = [
  ['preventivo', 'Preventivo'],
  ['correctivo', 'Correctivo'],
  ['instalacion', 'Instalación'],
  ['diagnostico', 'Diagnóstico'],
  ['visita_tecnica', 'Visita técnica']
]
const NOMBRE_TIPO = Object.fromEntries(TIPOS)

const ESTADO = {
  por_programar: 'Por programar',
  programada: 'Programada',
  realizada: 'Realizada',
  cancelada: 'Cancelada'
}

const IVA = 0.16

// Todo se maneja como texto YYYY-MM-DD. Convertir a Date para comparar trae
// problemas de zona horaria: un servicio del día 1 aparecería el 30 anterior.
const iso = (y, m, d) =>
  `${y}-${String(m + 1).padStart(2, '0')}-${String(d).padStart(2, '0')}`

// Cita con lo que la Agenda necesita mostrar: cliente, equipo, su orden y su cotización.
const SELECCION_CITA =
  '*, clientes(nombre), equipos(numero_serie, tipo), ordenes_servicio(id, folio, estado), cotizaciones(folio, estado)'

// ---------------------------------------------------------------------------
// Panel para agendar una cita nueva, o programar / reasignar una existente. Es un
// componente de nivel superior (no definido dentro de Agenda) para que sus campos no
// pierdan el foco al escribir.
// ---------------------------------------------------------------------------
function PanelCita({ modo, cita, preset, dia, clientes, equipos, tecnicos, cotizaciones, tarifas, onCerrar, onHecho }) {
  const nueva = modo === 'nueva'
  const [f, setF] = useState(() => ({
    cliente_id: preset?.cliente_id || cita?.cliente_id || '',
    equipo_id: preset?.equipo_id || cita?.equipo_id || '',
    tipo: preset?.tipo || cita?.tipo_servicio || 'correctivo',
    fecha: cita?.fecha || dia || hoyLocal(),
    hora: cita?.hora?.slice(0, 5) || '09:00',
    duracion: cita?.duracion_min || 120,
    t1: cita?.tecnico_id || '',
    t2: cita?.tecnico2_id || '',
    zona: '',
    notas: '',
    cotizacion_id: '',
    modoCot: 'crear'                 // diagnóstico: 'crear' una nueva o 'enlazar' una existente
  }))
  const [error, setError] = useState('')
  const [enviando, setEnviando] = useState(false)

  const cliente = clientes.find(c => c.id === f.cliente_id)
  const equipo = equipos.find(e => e.id === f.equipo_id)
  const equiposDelCliente = equipos.filter(e => e.cliente_id === f.cliente_id)
  const esPoliza = nueva && f.tipo === 'preventivo' && !!equipo?.en_poliza
  const esDiag = nueva && f.tipo === 'diagnostico'
  const crearCot = esDiag && f.modoCot === 'crear'

  const enlazables = cotizaciones.filter(c =>
    c.cliente_id === f.cliente_id && !['rechazada', 'vencida'].includes(c.estado) &&
    (esDiag ? c.tipo === 'diagnostico' : true))

  // Cotización de diagnóstico que se crearía: precios copiados de las tarifas.
  const previa = useMemo(() => {
    if (!crearCot || !cliente) return null
    const { partidas, avisos } = partidasDeDiagnostico({ tarifas, equipo, cliente })
    const lineas = partidas.map(p => ({
      ...p, cantidad: Number(p.cantidad), precio_unitario: Number(p.precio_unitario) || 0,
      importe: importe(p.cantidad, p.precio_unitario)
    }))
    const subtotal = lineas.reduce((s, p) => s + p.importe, 0)
    const iva = Math.round(subtotal * IVA * 100) / 100
    return { lineas, avisos, subtotal, iva, total: subtotal + iva }
  }, [crearCot, cliente, equipo, tarifas])

  const pesos = v => Number(v || 0).toLocaleString('es-MX', { style: 'currency', currency: 'MXN' })
  const set = (campo, valor) => setF(x => ({ ...x, [campo]: valor }))

  async function enviar(e, confirmar = false) {
    e?.preventDefault()
    setError('')
    if (nueva && !f.cliente_id) return setError('Elige el cliente')
    if (!f.fecha) return setError('Falta la fecha')
    if (f.t1 && f.t1 === f.t2) return setError('El responsable y su ayudante no pueden ser la misma persona')
    if (f.t2 && !f.t1) return setError('Elige al técnico responsable antes que a su ayudante')

    setEnviando(true)
    const comunes = {
      p_fecha: f.fecha, p_hora: f.hora || null, p_duracion: Number(f.duracion) || null,
      p_t1: f.t1 || null, p_t2: f.t2 || null, p_confirmar: confirmar
    }
    const { data, error } = nueva
      ? await supabase.rpc('agendar_cita', {
          ...comunes,
          p_cliente: f.cliente_id, p_equipo: f.equipo_id || null, p_tipo: f.tipo,
          p_zona: f.zona || null, p_notas: f.notas || null,
          p_cotizacion: f.cotizacion_id || null,
          p_nueva_cotizacion: crearCot && previa
            ? { partidas: previa.lineas, subtotal: previa.subtotal, iva: previa.iva, total: previa.total }
            : null
        })
      : await supabase.rpc('programar_cita', { ...comunes, p_cita: cita.id })
    setEnviando(false)
    if (error) return setError(error.message)

    // La base avisa antes de hacer algo dudoso; solo sigue si se confirma.
    if (data.ok === false) {
      const partes = []
      if (data.empalmes?.length) {
        partes.push('Se empalma con: ' + data.empalmes
          .map(x => `${x.hora?.slice(0, 5) || ''} ${x.cliente} (${x.tecnicos})`).join('; '))
      }
      if (data.orden_con_trabajo) {
        partes.push('La orden ya tiene trabajo capturado y al cambiar de técnico quien la llenó dejará de verla.')
      }
      if (confirm(`${partes.join('\n\n')}\n\n¿Continuar de todos modos?`)) return enviar(null, true)
      return
    }
    onHecho(data, nueva)
  }

  const nombreT = id => tecnicos.find(t => t.id === id)?.nombre

  return (
    <form onSubmit={enviar} className="tarjeta" style={{ maxWidth: 560 }}>
      <h3>{nueva ? 'Nueva cita' : (cita.estado === 'por_programar' ? 'Programar cita' : 'Reprogramar o reasignar')}</h3>

      {!nueva && (
        <p className="ayuda">
          {cita.clientes?.nombre} · {NOMBRE_TIPO[cita.tipo_servicio] || cita.tipo_servicio}
          {cita.cotizaciones?.folio && ` · COT-${cita.cotizaciones.folio}`}
        </p>
      )}

      {error && <Alerta tipo="error">{error}</Alerta>}

      {nueva && (
        <>
          <label className="campo">
            <span>Cliente *</span>
            <select value={f.cliente_id} onChange={e => setF({ ...f, cliente_id: e.target.value, equipo_id: '', cotizacion_id: '' })}>
              <option value="">— Elige —</option>
              {clientes.map(c => <option key={c.id} value={c.id}>{c.nombre}</option>)}
            </select>
          </label>
          <label className="campo">
            <span>Equipo</span>
            <select value={f.equipo_id} onChange={e => set('equipo_id', e.target.value)}>
              <option value="">— Ninguno —</option>
              {equiposDelCliente.map(e => (
                <option key={e.id} value={e.id}>
                  {e.numero_serie} — {e.tipo}{e.capacidad_kw ? ` ${e.capacidad_kw} kW` : ''}{e.en_poliza ? ' · póliza' : ''}
                </option>
              ))}
            </select>
          </label>
          <label className="campo">
            <span>Tipo de servicio</span>
            <select value={f.tipo} onChange={e => set('tipo', e.target.value)}>
              {TIPOS.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
            </select>
          </label>
        </>
      )}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
        <label className="campo">
          <span>Fecha *</span>
          <input type="date" value={f.fecha} onChange={e => set('fecha', e.target.value)} />
        </label>
        <label className="campo">
          <span>Hora</span>
          <input type="time" value={f.hora} onChange={e => set('hora', e.target.value)} />
        </label>
      </div>
      <label className="campo">
        <span>Duración estimada (minutos)</span>
        <input type="number" min="15" step="15" value={f.duracion} onChange={e => set('duracion', e.target.value)} />
      </label>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
        <label className="campo">
          <span>Técnico responsable</span>
          <select value={f.t1} onChange={e => set('t1', e.target.value)}>
            <option value="">— Sin asignar —</option>
            {tecnicos.map(t => <option key={t.id} value={t.id}>{t.nombre}</option>)}
          </select>
        </label>
        <label className="campo">
          <span>Ayudante (técnico 2)</span>
          <select value={f.t2} onChange={e => set('t2', e.target.value)}>
            <option value="">— Ninguno —</option>
            {tecnicos.filter(t => t.id !== f.t1).map(t => <option key={t.id} value={t.id}>{t.nombre}</option>)}
          </select>
        </label>
      </div>
      {!nueva && f.t1 && f.t1 !== cita.tecnico_id && cita.tecnico_id && (
        <p className="ayuda">Cambia de {nombreT(cita.tecnico_id) || cita.tecnico} a {nombreT(f.t1)}. La orden abierta lo sigue.</p>
      )}

      {esPoliza && (
        <Alerta tipo="info" palabra="Póliza">
          Es un mantenimiento de póliza: abre solo la orden de servicio, sin cotización.
        </Alerta>
      )}

      {esDiag && (
        <div className="campo">
          <span>Cotización del diagnóstico</span>
          <div className="opciones">
            <button type="button" className="opcion" role="radio" aria-checked={f.modoCot === 'crear'}
              onClick={() => set('modoCot', 'crear')}>
              {f.modoCot === 'crear' && <span aria-hidden="true">✓</span>} Crear una
            </button>
            <button type="button" className="opcion" role="radio" aria-checked={f.modoCot === 'enlazar'}
              onClick={() => set('modoCot', 'enlazar')}>
              {f.modoCot === 'enlazar' && <span aria-hidden="true">✓</span>} Enlazar existente
            </button>
          </div>
        </div>
      )}

      {crearCot && cliente && previa && (
        <div style={{ marginBottom: 14 }}>
          {previa.avisos.map((a, i) => <Alerta key={i} tipo="aviso" palabra="Falta">{a}</Alerta>)}
          <table style={{ width: '100%' }}>
            <tbody>
              {previa.lineas.map((p, i) => (
                <tr key={i}>
                  <td>{p.descripcion}</td>
                  <td align="right">{p.cantidad} × {pesos(p.precio_unitario)}</td>
                  <td align="right">{pesos(p.importe)}</td>
                </tr>
              ))}
              <tr><td colSpan={2} align="right">IVA</td><td align="right">{pesos(previa.iva)}</td></tr>
              <tr><td colSpan={2} align="right"><strong>Total</strong></td><td align="right"><strong>{pesos(previa.total)}</strong></td></tr>
            </tbody>
          </table>
          <p className="ayuda">Se guarda como borrador. Los precios que falten se completan en Cotizaciones.</p>
        </div>
      )}

      {nueva && (!esDiag || f.modoCot === 'enlazar') && !esPoliza && f.cliente_id && (
        <label className="campo">
          <span>{esDiag ? 'Cotización de diagnóstico' : 'Cotización (opcional)'}</span>
          <select value={f.cotizacion_id} onChange={e => set('cotizacion_id', e.target.value)}>
            <option value="">{esDiag ? '— Elige —' : '— Sin cotización —'}</option>
            {enlazables.map(c => <option key={c.id} value={c.id}>COT-{c.folio} · {c.tipo} · {c.estado}</option>)}
          </select>
        </label>
      )}
      {nueva && !esDiag && !esPoliza && f.cliente_id && !f.cotizacion_id && (
        <p className="ayuda">Sin cotización enlazada: la cita y su orden se abren igual, pero nada respalda el cobro.</p>
      )}

      {nueva && (
        <>
          <label className="campo">
            <span>Zona</span>
            <input placeholder="Se toma del cliente si lo dejas vacío" value={f.zona} onChange={e => set('zona', e.target.value)} />
          </label>
          <label className="campo">
            <span>Notas</span>
            <textarea rows={2} value={f.notas} onChange={e => set('notas', e.target.value)} />
          </label>
        </>
      )}

      <div className="fila">
        <button type="submit" className="btn-primario" disabled={enviando || (esDiag && f.modoCot === 'enlazar' && !f.cotizacion_id)}>
          {enviando ? 'Guardando…' : (nueva ? 'Agendar' : 'Guardar')}
        </button>
        <button type="button" onClick={onCerrar}>Cancelar</button>
      </div>
    </form>
  )
}

export default function Agenda({ irA }) {
  const ahora = new Date()
  const [anio, setAnio] = useState(ahora.getFullYear())
  const [mes, setMes] = useState(ahora.getMonth())
  const [dia, setDia] = useState(hoyLocal())

  const [citas, setCitas] = useState([])
  const [porProgramar, setPorProgramar] = useState([])
  const [mantenimientos, setMantenimientos] = useState([])
  const [clientes, setClientes] = useState([])
  const [equipos, setEquipos] = useState([])
  const [tecnicos, setTecnicos] = useState([])
  const [cotizaciones, setCotizaciones] = useState([])
  const [tarifas, setTarifas] = useState([])
  const [rol, setRol] = useState('')

  const [panel, setPanel] = useState(null)   // null | { modo: 'nueva', preset? } | { modo: 'programar', cita }
  const [filtroTecnico, setFiltroTecnico] = useState('')
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState(null)   // { texto, cotizacion } tras agendar

  const yo = usuarioLocal()?.id
  const desde = iso(anio, mes, 1)
  const hasta = iso(anio, mes, new Date(anio, mes + 1, 0).getDate())

  // cargar() lee anio y mes de aquí mismo; se vuelve a llamar solo al cambiar de mes.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { cargar() }, [anio, mes])

  async function cargar() {
    const { data } = await supabase.rpc('mi_rol')
    // Sin señal la base no contesta: se usa el perfil guardado en el celular. Solo decide
    // qué botones se ven; el servidor sigue aplicando los permisos de verdad.
    const r = data || leerLocal('cache_perfil', null)?.rol || ''
    setRol(r)
    const admin = r === 'admin'
    const nada = Promise.resolve({ data: [] })

    const [ci, pp, eq, cl, tc, mt, co, ta] = await Promise.all([
      supabase.from('citas').select(SELECCION_CITA)
        .gte('fecha', desde).lte('fecha', hasta)
        .order('fecha').order('hora'),
      admin ? supabase.from('citas').select(SELECCION_CITA).eq('estado', 'por_programar').order('created_at') : nada,
      supabase.from('equipos').select('id, numero_serie, tipo, marca, cliente_id, en_poliza, capacidad_kw, atributos'),
      supabase.from('clientes').select('id, nombre, zona, distancia_km').order('nombre'),
      supabase.rpc('lista_tecnicos'),
      supabase.from('equipos')
        .select('id, numero_serie, tipo, marca, proximo_mantenimiento, clientes(nombre)')
        .gte('proximo_mantenimiento', desde).lte('proximo_mantenimiento', hasta),
      admin ? supabase.from('cotizaciones').select('id, folio, estado, tipo, cliente_id') : nada,
      admin ? supabase.from('tarifas_servicio').select('*').eq('activo', true) : nada
    ])
    if (ci.error) return setError(explicarError(ci.error).texto)
    setError('')
    setCitas(ci.data || [])
    setPorProgramar(pp.data || [])
    setEquipos(eq.data || [])
    setClientes(cl.data || [])
    setTecnicos(tc.data || [])
    setMantenimientos(mt.data || [])
    setCotizaciones(co.data || [])
    setTarifas(ta.data || [])
  }

  const nombreTecnico = id => tecnicos.find(t => t.id === id)?.nombre

  const citasVisibles = useMemo(
    () => (filtroTecnico ? citas.filter(c => c.tecnico_id === filtroTecnico || c.tecnico2_id === filtroTecnico) : citas),
    [citas, filtroTecnico]
  )

  // Celdas del mes, empezando en lunes.
  const celdas = useMemo(() => {
    const primero = new Date(anio, mes, 1).getDay()        // 0 = domingo
    const offset = (primero + 6) % 7                        // 0 = lunes
    const total = new Date(anio, mes + 1, 0).getDate()
    const out = Array(offset).fill(null)
    for (let d = 1; d <= total; d++) out.push(iso(anio, mes, d))
    return out
  }, [anio, mes])

  const delDia = f => citasVisibles.filter(c => c.fecha === f)
  const mantDelDia = f => mantenimientos.filter(m => m.proximo_mantenimiento === f)

  function mover(n) {
    const d = new Date(anio, mes + n, 1)
    setAnio(d.getFullYear())
    setMes(d.getMonth())
  }

  function hecho(data, esNueva) {
    setPanel(null)
    setError('')
    const orden = data.orden_folio ? ` Se abrió la orden de servicio OS-${data.orden_folio}.` : ''
    const cot = data.cotizacion_folio
      ? ` ${data.cotizacion_nueva ? 'Se creó' : 'Se enlazó'} la cotización COT-${data.cotizacion_folio}.`
      : ''
    setMensaje({
      texto: (esNueva ? 'Cita agendada.' : 'Cita programada.') + orden + cot,
      cotizacion: !!data.cotizacion_nueva
    })
    cargar()
  }

  async function cancelar(c) {
    if (!confirm(`¿Cancelar la cita de ${c.clientes?.nombre}?\n\nSe cancela también su orden de servicio.`)) return
    setError(''); setMensaje(null)
    const { data, error } = await supabase.rpc('cancelar_cita', { p_cita: c.id })
    if (error) return setError(error.message)
    if (data.ok === false) {
      return setError(`No se canceló: la orden OS-${data.orden_folio} ya tiene trabajo capturado.`)
    }
    setMensaje({ texto: 'Cita cancelada.' + (data.cotizacion_folio ? ` Su cotización COT-${data.cotizacion_folio} sigue como estaba; revísala si ya no aplica.` : '') })
    cargar()
  }

  async function marcarRealizada(c) {
    const ordenAbierta = (c.ordenes_servicio || []).some(o => o.estado === 'abierta')
    if (ordenAbierta && !confirm('La orden de servicio de esta cita sigue abierta.\n\n¿Marcar la cita como realizada de todos modos?')) return
    setError(''); setMensaje(null)
    const { error } = await supabase.from('citas').update({ estado: 'realizada' }).eq('id', c.id)
    if (error) return setError(error.message)
    cargar()
  }

  // Al agendar un mantenimiento vencido, se precarga el equipo y su dueño.
  function desdeMantenimiento(m) {
    setPanel({
      modo: 'nueva',
      preset: { cliente_id: equipos.find(e => e.id === m.id)?.cliente_id || '', equipo_id: m.id, tipo: 'preventivo' }
    })
  }

  const admin = rol === 'admin'

  // Una tarjeta por cita: se llama como función (no como componente) para no
  // recrearla en cada render.
  function tarjetaCita(c) {
    const orden = (c.ordenes_servicio || [])[0]
    const soyT1 = yo && c.tecnico_id === yo
    const soyT2 = yo && c.tecnico2_id === yo
    return (
      <div key={c.id} className="tarjeta">
        <div className="fila" style={{ justifyContent: 'space-between', alignItems: 'flex-start' }}>
          <div>
            <strong>
              {c.estado === 'por_programar' ? 'Sin fecha' : (c.hora?.slice(0, 5) || 'Sin hora')} · {c.clientes?.nombre}
            </strong>
            <div className="ayuda">
              {NOMBRE_TIPO[c.tipo_servicio] || c.tipo_servicio}
              {c.equipos?.numero_serie && ` · ${c.equipos.numero_serie}`}
              {c.zona && ` · ${c.zona}`}
              {c.duracion_min && ` · ${c.duracion_min} min`}
            </div>
          </div>
          <span className={`estado estado-${c.estado}`}>{ESTADO[c.estado] || c.estado}</span>
        </div>

        <div style={{ marginTop: 8 }}>
          {c.tecnico_id || c.tecnico
            ? <>Responsable: <strong>{nombreTecnico(c.tecnico_id) || c.tecnico}</strong></>
            : <strong>Sin técnico asignado</strong>}
          {c.tecnico2_id && <> · Ayudante: <strong>{nombreTecnico(c.tecnico2_id) || '—'}</strong></>}
        </div>
        {(soyT1 || soyT2) && (
          <div><span className="etiqueta">{soyT1 ? 'Eres el responsable' : 'Eres el ayudante'}</span></div>
        )}

        <div className="ayuda" style={{ marginTop: 6 }}>
          {orden && <>Orden OS-{orden.folio} ({orden.estado})</>}
          {c.cotizaciones?.folio && <>{orden ? ' · ' : ''}Cotización COT-{c.cotizaciones.folio} ({c.cotizaciones.estado})</>}
          {c.origen === 'poliza' && ' · Póliza'}
        </div>
        {c.notas && <div className="ayuda">{c.notas}</div>}

        {admin && (c.estado === 'programada' || c.estado === 'por_programar') && (
          <div className="fila" style={{ marginTop: 10 }}>
            <button className={c.estado === 'por_programar' ? 'btn-primario' : undefined}
              onClick={() => setPanel({ modo: 'programar', cita: c })}>
              {c.estado === 'por_programar' ? 'Programar' : 'Reprogramar / reasignar'}
            </button>
            {c.estado === 'programada' && <button onClick={() => marcarRealizada(c)}>Realizada</button>}
            <button className="btn-peligro" onClick={() => cancelar(c)}>Cancelar</button>
          </div>
        )}
      </div>
    )
  }

  return (
    <div className="pagina">
      <div className="fila" style={{ marginBottom: 8 }}>
        <h2 style={{ margin: 0 }}>Agenda</h2>
        <button onClick={() => mover(-1)} aria-label="Mes anterior">‹</button>
        <strong style={{ minWidth: 150, textAlign: 'center' }}>{MESES[mes]} {anio}</strong>
        <button onClick={() => mover(1)} aria-label="Mes siguiente">›</button>
        <button onClick={() => { const n = new Date(); setAnio(n.getFullYear()); setMes(n.getMonth()); setDia(hoyLocal()) }}>
          Hoy
        </button>
        {admin && (
          <select value={filtroTecnico} onChange={e => setFiltroTecnico(e.target.value)} aria-label="Filtrar por técnico">
            <option value="">Todos los técnicos</option>
            {tecnicos.map(t => <option key={t.id} value={t.id}>{t.nombre}</option>)}
          </select>
        )}
      </div>

      <p className="ayuda">
        En cada día, el número negro es la cantidad de citas y la <strong>M</strong> marca un
        mantenimiento por vencer.
      </p>

      {error && <Alerta tipo="error">{error}</Alerta>}
      {mensaje && (
        <Alerta tipo="ok" palabra="Listo">
          {mensaje.texto}
          {mensaje.cotizacion && irA && (
            <div style={{ marginTop: 8 }}><button onClick={() => irA('cotizaciones')}>Ir a Cotizaciones</button></div>
          )}
        </Alerta>
      )}

      {admin && porProgramar.length > 0 && (
        <section style={{ marginBottom: 16 }}>
          <Alerta tipo="aviso" palabra="Por programar">
            {porProgramar.length} cita{porProgramar.length === 1 ? '' : 's'} de cotizaciones aceptadas sin fecha.
            Ponles fecha, hora y técnicos.
          </Alerta>
          {porProgramar.map(tarjetaCita)}
        </section>
      )}

      {panel && (
        <PanelCita
          key={panel.modo + (panel.cita?.id || '')}
          modo={panel.modo} cita={panel.cita} preset={panel.preset} dia={dia}
          clientes={clientes} equipos={equipos} tecnicos={tecnicos}
          cotizaciones={cotizaciones} tarifas={tarifas}
          onCerrar={() => setPanel(null)} onHecho={hecho}
        />
      )}

      {/* calendario */}
      <div className="calendario">
        {DIAS.map(d => <div key={d} className="calendario-dia-semana">{d}</div>)}
        {celdas.map((f, i) => {
          if (!f) return <div key={`v${i}`} />
          const n = delDia(f).length
          const m = mantDelDia(f).length
          return (
            <button
              key={f}
              className={`dia${f === hoyLocal() ? ' dia-hoy' : ''}${f === dia ? ' dia-activo' : ''}`}
              onClick={() => setDia(f)}
              aria-pressed={f === dia}
              aria-label={`${Number(f.slice(8))} de ${MESES[mes]}${n ? `, ${n} cita${n > 1 ? 's' : ''}` : ''}${m ? ', mantenimiento por vencer' : ''}`}
            >
              <span>{Number(f.slice(8))}</span>
              <span className="dia-marcas">
                {n > 0 && <span className="marca-dia marca-cita">{n}</span>}
                {m > 0 && <span className="marca-dia marca-mtto">M</span>}
              </span>
            </button>
          )
        })}
      </div>

      {/* día seleccionado */}
      <section style={{ marginTop: 24, maxWidth: 780 }}>
        <h3>{dia}{dia === hoyLocal() && ' · hoy'}</h3>

        {delDia(dia).length === 0 && mantDelDia(dia).length === 0 && (
          <p className="ayuda">Nada agendado este día.</p>
        )}

        {delDia(dia).map(tarjetaCita)}

        {mantDelDia(dia).map(m => (
          <div key={`m${m.id}`} className="tarjeta">
            <div className="fila" style={{ justifyContent: 'space-between' }}>
              <div>
                <strong>Mantenimiento por vencer</strong>
                <div className="ayuda">
                  {m.clientes?.nombre} · {m.numero_serie} · {m.tipo}{m.marca && ` ${m.marca}`}
                </div>
              </div>
              {admin && <button onClick={() => desdeMantenimiento(m)}>Agendar</button>}
            </div>
          </div>
        ))}

        {admin && !panel && (
          <button className="btn-primario" onClick={() => setPanel({ modo: 'nueva' })} style={{ marginTop: 8 }}>
            ＋ Agendar en este día
          </button>
        )}
      </section>
    </div>
  )
}
