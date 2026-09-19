import { useEffect, useMemo, useState } from 'react'
import { supabase } from './lib/supabase'

const DIAS = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom']
const MESES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre']

const TIPOS = ['preventivo', 'correctivo', 'instalacion', 'diagnostico', 'visita_tecnica']

const COLOR = { programada: '#1565c0', realizada: '#2e7d32', cancelada: '#9e9e9e' }

// Todo se maneja como texto YYYY-MM-DD. Convertir a Date para comparar trae
// problemas de zona horaria: un servicio del día 1 aparecería el 30 anterior.
const iso = (y, m, d) =>
  `${y}-${String(m + 1).padStart(2, '0')}-${String(d).padStart(2, '0')}`

const hoyIso = () => {
  const n = new Date()
  return iso(n.getFullYear(), n.getMonth(), n.getDate())
}

const vaciaCita = {
  cliente_id: '', equipo_id: '', tipo_servicio: 'preventivo',
  hora: '09:00', tecnico_id: '', zona: '', notas: ''
}

export default function Agenda() {
  const ahora = new Date()
  const [anio, setAnio] = useState(ahora.getFullYear())
  const [mes, setMes] = useState(ahora.getMonth())
  const [dia, setDia] = useState(hoyIso())

  const [citas, setCitas] = useState([])
  const [mantenimientos, setMantenimientos] = useState([])
  const [clientes, setClientes] = useState([])
  const [equipos, setEquipos] = useState([])
  const [tecnicos, setTecnicos] = useState([])
  const [rol, setRol] = useState('')

  const [nueva, setNueva] = useState(vaciaCita)
  const [abriendo, setAbriendo] = useState(false)
  const [filtroTecnico, setFiltroTecnico] = useState('')
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState('')

  const desde = iso(anio, mes, 1)
  const hasta = iso(anio, mes, new Date(anio, mes + 1, 0).getDate())

  // cargar() lee anio y mes de aquí mismo; se vuelve a llamar solo al cambiar de mes.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { cargar() }, [anio, mes])

  async function cargar() {
    const { data: r } = await supabase.rpc('mi_rol')
    setRol(r || '')

    const [ci, eq, cl, tc, mt] = await Promise.all([
      supabase.from('citas')
        .select('*, clientes(nombre), equipos(numero_serie, tipo)')
        .gte('fecha', desde).lte('fecha', hasta)
        .order('fecha').order('hora'),
      supabase.from('equipos').select('id, numero_serie, tipo, marca, cliente_id'),
      supabase.from('clientes').select('id, nombre, zona').order('nombre'),
      supabase.from('perfiles').select('id, nombre, email').eq('rol', 'tecnico').eq('activo', true),
      supabase.from('equipos')
        .select('id, numero_serie, tipo, marca, proximo_mantenimiento, clientes(nombre)')
        .gte('proximo_mantenimiento', desde).lte('proximo_mantenimiento', hasta)
    ])
    if (ci.error) return setError(ci.error.message)
    setCitas(ci.data || [])
    setEquipos(eq.data || [])
    setClientes(cl.data || [])
    setTecnicos(tc.data || [])
    setMantenimientos(mt.data || [])
  }

  const citasVisibles = useMemo(
    () => (filtroTecnico ? citas.filter(c => c.tecnico_id === filtroTecnico) : citas),
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

  async function agendar(e) {
    e.preventDefault()
    setError(''); setMensaje('')
    if (!nueva.cliente_id) return setError('Elige el cliente')

    const { error } = await supabase.from('citas').insert([{
      cliente_id: nueva.cliente_id,
      equipo_id: nueva.equipo_id || null,
      tipo_servicio: nueva.tipo_servicio,
      fecha: dia,
      hora: nueva.hora || null,
      tecnico_id: nueva.tecnico_id || null,
      tecnico: tecnicos.find(t => t.id === nueva.tecnico_id)?.nombre || null,
      zona: nueva.zona || clientes.find(c => c.id === nueva.cliente_id)?.zona || null,
      notas: nueva.notas || null,
      estado: 'programada'
    }])
    if (error) return setError(error.message)
    setNueva(vaciaCita)
    setAbriendo(false)
    setMensaje('Cita agendada.')
    cargar()
  }

  async function cambiarEstado(c, estado) {
    const { error } = await supabase.from('citas').update({ estado }).eq('id', c.id)
    if (error) return setError(error.message)
    cargar()
  }

  // Al agendar un mantenimiento vencido, se precarga el equipo y su dueño.
  function desdeMantenimiento(m) {
    setNueva({
      ...vaciaCita,
      cliente_id: equipos.find(e => e.id === m.id)?.cliente_id || '',
      equipo_id: m.id,
      tipo_servicio: 'preventivo'
    })
    setAbriendo(true)
  }

  const equiposDelCliente = equipos.filter(e => e.cliente_id === nueva.cliente_id)
  const campo = { padding: 8, fontSize: 15, width: '100%', boxSizing: 'border-box' }
  const nombreTecnico = id => tecnicos.find(t => t.id === id)?.nombre || '—'

  return (
    <div style={{ padding: 20, fontFamily: 'system-ui' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 14, flexWrap: 'wrap', marginBottom: 6 }}>
        <h2 style={{ margin: 0 }}>Agenda</h2>
        <button onClick={() => mover(-1)}>‹</button>
        <strong style={{ minWidth: 170, textAlign: 'center' }}>
          {MESES[mes]} {anio}
        </strong>
        <button onClick={() => mover(1)}>›</button>
        <button onClick={() => { const n = new Date(); setAnio(n.getFullYear()); setMes(n.getMonth()); setDia(hoyIso()) }}>
          Hoy
        </button>

        {rol === 'admin' && (
          <select value={filtroTecnico} onChange={e => setFiltroTecnico(e.target.value)} style={{ padding: 6 }}>
            <option value="">Todos los técnicos</option>
            {tecnicos.map(t => <option key={t.id} value={t.id}>{t.nombre || t.email}</option>)}
          </select>
        )}
      </div>

      <div style={{ display: 'flex', gap: 16, fontSize: 13, color: '#666', marginBottom: 12, flexWrap: 'wrap' }}>
        <span><span style={{ ...punto, background: COLOR.programada }} /> Programada</span>
        <span><span style={{ ...punto, background: COLOR.realizada }} /> Realizada</span>
        <span><span style={{ ...punto, background: COLOR.cancelada }} /> Cancelada</span>
        <span><span style={{ ...punto, background: '#fff', border: '2px solid #e08e0b' }} /> Mantenimiento por vencer</span>
      </div>

      {error && <p style={{ color: 'crimson' }}>{error}</p>}
      {mensaje && <p style={{ color: 'green' }}>{mensaje}</p>}

      {/* calendario */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(7, minmax(56px, 1fr))', gap: 4, maxWidth: 780 }}>
        {DIAS.map(d => (
          <div key={d} style={{ textAlign: 'center', fontSize: 12, color: '#888', padding: 4 }}>{d}</div>
        ))}
        {celdas.map((f, i) => {
          if (!f) return <div key={`v${i}`} />
          const cs = delDia(f)
          const ms = mantDelDia(f)
          const esHoy = f === hoyIso()
          const activo = f === dia
          return (
            <div
              key={f}
              onClick={() => { setDia(f); setAbriendo(false) }}
              style={{
                minHeight: 62, padding: 5, cursor: 'pointer', borderRadius: 6,
                border: activo ? '2px solid #333' : '1px solid #ddd',
                background: esHoy ? '#f3f7ff' : '#fff'
              }}
            >
              <div style={{ fontSize: 12, fontWeight: esHoy ? 700 : 400 }}>{Number(f.slice(8))}</div>
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: 3, marginTop: 3 }}>
                {cs.slice(0, 6).map(c => (
                  <span key={c.id} style={{ ...punto, background: COLOR[c.estado] || '#999' }} />
                ))}
                {ms.slice(0, 4).map(m => (
                  <span key={`m${m.id}`} style={{ ...punto, background: '#fff', border: '2px solid #e08e0b' }} />
                ))}
              </div>
            </div>
          )
        })}
      </div>

      {/* día seleccionado */}
      <div style={{ marginTop: 24, maxWidth: 780 }}>
        <h3>{dia}{dia === hoyIso() && ' · hoy'}</h3>

        {delDia(dia).length === 0 && mantDelDia(dia).length === 0 && (
          <p style={{ color: '#888' }}>Nada agendado este día.</p>
        )}

        {delDia(dia).map(c => (
          <div key={c.id} style={{
            padding: 12, marginBottom: 8, borderRadius: 6,
            borderLeft: `4px solid ${COLOR[c.estado] || '#999'}`, background: '#fafafa'
          }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10, flexWrap: 'wrap' }}>
              <div>
                <strong>{c.hora?.slice(0, 5) || '—'} · {c.clientes?.nombre}</strong>
                <div style={{ fontSize: 14, color: '#555' }}>
                  {c.tipo_servicio}
                  {c.equipos?.numero_serie && ` · ${c.equipos.numero_serie}`}
                  {c.zona && ` · ${c.zona}`}
                </div>
                <div style={{ fontSize: 13, color: '#777' }}>
                  Técnico: {c.tecnico || nombreTecnico(c.tecnico_id)}
                </div>
                {c.notas && <div style={{ fontSize: 13, color: '#777' }}>{c.notas}</div>}
              </div>
              {c.estado === 'programada' && (
                <div style={{ display: 'flex', gap: 6, alignItems: 'start' }}>
                  <button onClick={() => cambiarEstado(c, 'realizada')}>Realizada</button>
                  <button onClick={() => cambiarEstado(c, 'cancelada')}>Cancelar</button>
                </div>
              )}
            </div>
          </div>
        ))}

        {mantDelDia(dia).map(m => (
          <div key={`m${m.id}`} style={{
            padding: 12, marginBottom: 8, borderRadius: 6,
            border: '1px dashed #e08e0b', background: '#fffdf6'
          }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10, flexWrap: 'wrap' }}>
              <div>
                <strong>Mantenimiento por vencer</strong>
                <div style={{ fontSize: 14, color: '#555' }}>
                  {m.clientes?.nombre} · {m.numero_serie} · {m.tipo}{m.marca && ` ${m.marca}`}
                </div>
              </div>
              {rol === 'admin' && <button onClick={() => desdeMantenimiento(m)}>Agendar</button>}
            </div>
          </div>
        ))}

        {rol === 'admin' && (
          abriendo ? (
            <form onSubmit={agendar} style={{
              marginTop: 16, padding: 16, border: '1px solid #ccc', borderRadius: 8,
              display: 'grid', gap: 10, maxWidth: 460
            }}>
              <h4 style={{ margin: 0 }}>Nueva cita — {dia}</h4>

              <label>Cliente *
                <select
                  value={nueva.cliente_id}
                  onChange={e => setNueva({ ...nueva, cliente_id: e.target.value, equipo_id: '' })}
                  style={campo}
                >
                  <option value="">— Elige —</option>
                  {clientes.map(c => <option key={c.id} value={c.id}>{c.nombre}</option>)}
                </select>
              </label>

              <label>Equipo
                <select value={nueva.equipo_id} onChange={e => setNueva({ ...nueva, equipo_id: e.target.value })} style={campo}>
                  <option value="">— Ninguno —</option>
                  {equiposDelCliente.map(e => (
                    <option key={e.id} value={e.id}>{e.numero_serie} — {e.tipo}</option>
                  ))}
                </select>
              </label>

              <label>Tipo de servicio
                <select value={nueva.tipo_servicio} onChange={e => setNueva({ ...nueva, tipo_servicio: e.target.value })} style={campo}>
                  {TIPOS.map(t => <option key={t} value={t}>{t}</option>)}
                </select>
              </label>

              <label>Hora
                <input type="time" value={nueva.hora} onChange={e => setNueva({ ...nueva, hora: e.target.value })} style={campo} />
              </label>

              <label>Técnico
                <select value={nueva.tecnico_id} onChange={e => setNueva({ ...nueva, tecnico_id: e.target.value })} style={campo}>
                  <option value="">— Sin asignar —</option>
                  {tecnicos.map(t => <option key={t.id} value={t.id}>{t.nombre || t.email}</option>)}
                </select>
              </label>

              <label>Zona
                <input
                  placeholder="Se toma del cliente si lo dejas vacío"
                  value={nueva.zona}
                  onChange={e => setNueva({ ...nueva, zona: e.target.value })}
                  style={campo}
                />
              </label>

              <label>Notas
                <textarea rows={2} value={nueva.notas} onChange={e => setNueva({ ...nueva, notas: e.target.value })} style={campo} />
              </label>

              <div style={{ display: 'flex', gap: 8 }}>
                <button type="submit">Agendar</button>
                <button type="button" onClick={() => { setAbriendo(false); setNueva(vaciaCita) }}>Cancelar</button>
              </div>
            </form>
          ) : (
            <button onClick={() => setAbriendo(true)} style={{ marginTop: 12, padding: 10 }}>
              Agendar en este día
            </button>
          )
        )}
      </div>
    </div>
  )
}

const punto = { width: 9, height: 9, borderRadius: '50%', display: 'inline-block', boxSizing: 'border-box' }
