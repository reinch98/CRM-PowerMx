import { useEffect, useRef, useState } from 'react'
import { supabase } from './lib/supabase'
import { guardarFoto, fotosDeOrden, borrarFotosDeOrden } from './lib/idb'
import { redimensionar, dataUrlABlob, firmaEnBlanco } from './lib/imagen'
import { hoyLocal } from './lib/fechas'
import { explicarError } from './lib/errores'
import { leerLocal, escribirLocal, usuarioLocal } from './lib/local'
import { Alerta } from './ui'
import Firma from './Firma'

const TIPOS_SERVICIO = [
  ['preventivo', 'Preventivo'],
  ['correctivo', 'Correctivo'],
  ['instalacion', 'Instalación'],
  ['diagnostico', 'Diagnóstico']
]

const COLA = 'ordenes_pendientes'
const CACHE_EQUIPOS = 'cache_equipos'
const BUCKET = 'ordenes'

// Función y no objeto: la fecha se calcula al abrir la orden, no al cargar la
// app, que en el celular puede quedar abierta de un día para otro.
const vacio = () => ({
  equipo_id: '',
  fecha: hoyLocal(),
  tipo_servicio: 'preventivo',
  tecnico: '',
  horas_equipo: '',
  trabajos_realizados: '',
  observaciones: '',
  recomendaciones: '',
  requiere_seguimiento: false,
  fecha_seguimiento: ''
})

export default function Ordenes() {
  const [equipos, setEquipos] = useState(() => leerLocal(CACHE_EQUIPOS, []))
  const [pendientes, setPendientes] = useState(() => leerLocal(COLA, []))
  // El técnico llega con su nombre puesto (del perfil guardado en el celular).
  const [form, setForm] = useState(() => ({ ...vacio(), tecnico: leerLocal('cache_perfil', null)?.nombre || '' }))
  const [refacciones, setRefacciones] = useState([])
  const [fotos, setFotos] = useState([])          // { id, blob, url } antes de guardar
  const [enLinea, setEnLinea] = useState(navigator.onLine)
  const [subiendo, setSubiendo] = useState(false)
  // El estado no sirve de candado: sincronizar() lo lee de una versión vieja de
  // sí misma (la del primer render) y siempre lo vería en false.
  const sincronizando = useRef(false)
  const [mensaje, setMensaje] = useState('')
  const [error, setError] = useState('')
  const refLienzo = useRef(null)

  useEffect(() => {
    function alConectar() { setEnLinea(true); sincronizar() }
    function alDesconectar() { setEnLinea(false) }

    window.addEventListener('online', alConectar)
    window.addEventListener('offline', alDesconectar)

    if (navigator.onLine) { cargarEquipos(); sincronizar() }

    // El evento "online" no salta cuando hay señal pero es mala. Cada minuto se
    // reintenta lo pendiente; con la cola vacía sincronizar() no hace nada.
    const reintento = setInterval(() => { if (navigator.onLine) sincronizar() }, 60000)

    return () => {
      window.removeEventListener('online', alConectar)
      window.removeEventListener('offline', alDesconectar)
      clearInterval(reintento)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  async function cargarEquipos() {
    const { data, error } = await supabase
      .from('equipos')
      .select('id, numero_serie, marca, modelo, tipo, cliente_id, clientes(nombre)')
      .eq('estado', 'activo')
      .order('numero_serie')

    if (!error && data) {
      setEquipos(data)
      escribirLocal(CACHE_EQUIPOS, data)
    }
  }

  // -------------------------------------------------------------------------
  // Sincronización. Orden estricto: primero los archivos, luego el renglón.
  // Si la orden se insertara antes, podría quedar apuntando a fotos que nunca
  // subieron.
  // -------------------------------------------------------------------------
  // Devuelve { ok: true } o { ok: false, motivo, temporal }. El motivo ya viene
  // en español para mostrarlo tal cual en la lista de pendientes.
  async function subirOrden(orden) {
    try {
      const rutas = []

      const guardadas = await fotosDeOrden(orden.id)
      for (const foto of guardadas) {
        const ruta = `${orden.id}/${foto.id}.jpg`
        const { error } = await supabase.storage
          .from(BUCKET)
          .upload(ruta, foto.blob, { contentType: 'image/jpeg', upsert: true })
        if (error) return fallo(error)
        rutas.push(ruta)
      }

      let rutaFirma = null
      if (orden.firma_data) {
        rutaFirma = `${orden.id}/firma.png`
        const { error } = await supabase.storage
          .from(BUCKET)
          .upload(rutaFirma, dataUrlABlob(orden.firma_data), {
            contentType: 'image/png',
            upsert: true
          })
        if (error) return fallo(error)
      }

      // firma_data y sync solo existen mientras la orden está en la cola: a la
      // base va la ruta de la firma, y sync es la libreta de intentos.
      const { firma_data, sync, ...limpio } = orden
      const { error } = await supabase
        .from('ordenes_servicio')
        .insert([{ ...limpio, fotos: rutas, firma_cliente: rutaFirma }])

      // 23505 = ya existía ese id. Pasó en un intento anterior que se cortó; cuenta como subida.
      if (error && error.code !== '23505') return fallo(error)

      await borrarFotosDeOrden(orden.id)
      return { ok: true }
    } catch (e) {
      // fetch lanza en vez de devolver error cuando no hay red.
      return fallo(e)
    }
  }

  function fallo(error) {
    const { texto, temporal } = explicarError(error)
    return { ok: false, motivo: texto, temporal }
  }

  async function sincronizar() {
    const cola = leerLocal(COLA, [])
    if (cola.length === 0 || sincronizando.current) return

    sincronizando.current = true
    setSubiendo(true)
    const quedan = []
    let subidas = 0

    for (const orden of cola) {
      const r = await subirOrden(orden)
      if (r.ok) {
        subidas++
      } else {
        quedan.push({
          ...orden,
          sync: {
            error: r.motivo,
            temporal: r.temporal,
            intentos: (orden.sync?.intentos || 0) + 1,
            ultimo_intento: new Date().toISOString()
          }
        })
      }
    }

    // Las órdenes que se guardaron mientras subíamos no estaban en `cola`:
    // se conservan, o esta escritura las borraría de la cola.
    const subidasIds = new Set(cola.map(o => o.id))
    const nuevas = leerLocal(COLA, []).filter(o => !subidasIds.has(o.id))
    const restante = [...quedan, ...nuevas]

    escribirLocal(COLA, restante)
    setPendientes(restante)
    sincronizando.current = false
    setSubiendo(false)
    if (subidas > 0) setMensaje(`Se subieron ${subidas} orden(es).`)
    // Los motivos por orden están en la lista de pendientes; aquí solo el aviso.
    // Solo se avisa en rojo lo que no se arregla solo: la señal débil no.
    const atoradas = quedan.filter(o => !o.sync.temporal).length
    setError(atoradas > 0
      ? `${atoradas} orden(es) no se pudieron subir. Revisa el motivo en "Pendientes por subir".`
      : '')
  }

  function cambiar(campo, valor) {
    setForm({ ...form, [campo]: valor })
  }

  function agregarRefaccion() {
    setRefacciones([...refacciones, { descripcion: '', cantidad: '1' }])
  }

  function cambiarRefaccion(i, campo, valor) {
    const copia = [...refacciones]
    copia[i] = { ...copia[i], [campo]: valor }
    setRefacciones(copia)
  }

  function quitarRefaccion(i) {
    setRefacciones(refacciones.filter((_, j) => j !== i))
  }

  async function agregarFotos(e) {
    const archivos = Array.from(e.target.files || [])
    const nuevas = []
    for (const archivo of archivos) {
      const blob = await redimensionar(archivo)
      nuevas.push({ id: crypto.randomUUID(), blob, url: URL.createObjectURL(blob) })
    }
    setFotos([...fotos, ...nuevas])
    e.target.value = '' // permite volver a elegir la misma foto
  }

  function quitarFoto(id) {
    setFotos(fotos.filter(f => f.id !== id))
  }

  async function guardar(e) {
    e.preventDefault()
    setError('')
    setMensaje('')

    if (!form.equipo_id) { setError('Elige el equipo'); return }
    if (!form.trabajos_realizados.trim()) { setError('Anota los trabajos realizados'); return }

    const equipo = equipos.find(eq => eq.id === form.equipo_id)
    const id = crypto.randomUUID()

    const lienzo = refLienzo.current
    const firma_data = lienzo && !firmaEnBlanco(lienzo) ? lienzo.toDataURL('image/png') : null

    const orden = {
      id,                                // el folio consecutivo lo pone la base al subir
      cliente_id: equipo?.cliente_id,
      equipo_id: form.equipo_id,
      fecha: form.fecha,
      tipo_servicio: form.tipo_servicio,
      tecnico: form.tecnico || null,
      // Lo guardado en el celular va primero: es instantáneo. getUser() pide red
      // y devolvería null sin señal; getSession() con el token vencido intenta
      // renovarlo y con señal mala se queda esperando, congelando el botón.
      tecnico_id: usuarioLocal()?.id || (await supabase.auth.getSession()).data.session?.user?.id || null,
      horas_equipo: form.horas_equipo === '' ? null : form.horas_equipo,
      trabajos_realizados: form.trabajos_realizados,
      refacciones: refacciones.filter(r => r.descripcion.trim() !== ''),
      observaciones: form.observaciones || null,
      recomendaciones: form.recomendaciones || null,
      requiere_seguimiento: form.requiere_seguimiento,
      fecha_seguimiento: form.fecha_seguimiento === '' ? null : form.fecha_seguimiento,
      estado: 'cerrada',
      firma_data                          // se cambia por la ruta al subir
    }

    for (const foto of fotos) {
      await guardarFoto({ id: foto.id, orden_id: id, blob: foto.blob })
    }

    const cola = [...leerLocal(COLA, []), orden]
    escribirLocal(COLA, cola)
    setPendientes(cola)

    setForm({ ...vacio(), tecnico: form.tecnico })  // el técnico se queda, captura varias seguidas
    setRefacciones([])
    fotos.forEach(f => URL.revokeObjectURL(f.url))
    setFotos([])
    if (lienzo) lienzo.getContext('2d').clearRect(0, 0, lienzo.width, lienzo.height)
    setMensaje('Orden guardada en el celular.')
    // La pantalla es larga y el botón está abajo: sin esto el aviso queda fuera de vista.
    window.scrollTo({ top: 0, behavior: 'smooth' })

    if (navigator.onLine) sincronizar()
  }

  const etiqueta = eq =>
    `${eq.numero_serie} — ${eq.clientes?.nombre || 'sin cliente'}${eq.marca ? ` (${eq.marca})` : ''}`

  const nombreTipo = v => TIPOS_SERVICIO.find(([k]) => k === v)?.[1] || v

  return (
    <div className="pagina pagina-angosta">
      <h2>Orden de servicio</h2>

      {enLinea ? (
        <Alerta tipo="ok" palabra="Con señal">
          {pendientes.length === 0 ? 'Todo al día.' : <strong>{pendientes.length} por subir.</strong>}
          {pendientes.length > 0 && (
            <button type="button" onClick={sincronizar} disabled={subiendo} style={{ marginLeft: 8 }}>
              {subiendo ? 'Subiendo…' : 'Subir ahora'}
            </button>
          )}
        </Alerta>
      ) : (
        <Alerta tipo="aviso" palabra="Sin señal">
          Puedes seguir capturando: la orden se guarda en el celular y sube sola cuando haya señal.
          {pendientes.length > 0 && <> <strong>{pendientes.length} por subir.</strong></>}
        </Alerta>
      )}

      {mensaje && <Alerta tipo="ok" palabra="Listo">{mensaje}</Alerta>}

      <form onSubmit={guardar}>
        <section className="tarjeta">
          <h3>1 · Equipo y fecha</h3>

          <label className="campo">
            <span>Equipo *</span>
            <select value={form.equipo_id} onChange={e => cambiar('equipo_id', e.target.value)}>
              <option value="">— Elige el equipo —</option>
              {equipos.map(eq => (
                <option key={eq.id} value={eq.id}>{etiqueta(eq)}</option>
              ))}
            </select>
          </label>
          {equipos.length === 0 && (
            <Alerta tipo="aviso">
              No hay equipos guardados en este celular. Conéctate una vez para descargarlos.
            </Alerta>
          )}

          <label className="campo">
            <span>Fecha</span>
            <input type="date" value={form.fecha} onChange={e => cambiar('fecha', e.target.value)} />
          </label>

          <div className="campo" role="radiogroup" aria-label="Tipo de servicio">
            <span>Tipo de servicio</span>
            <div className="opciones">
              {TIPOS_SERVICIO.map(([v, t]) => (
                <button
                  type="button" key={v} className="opcion" role="radio"
                  aria-checked={form.tipo_servicio === v}
                  onClick={() => cambiar('tipo_servicio', v)}
                >
                  {form.tipo_servicio === v && <span aria-hidden="true">✓</span>} {t}
                </button>
              ))}
            </div>
          </div>

          <label className="campo">
            <span>Técnico</span>
            <input value={form.tecnico} onChange={e => cambiar('tecnico', e.target.value)} autoComplete="name" />
          </label>

          <label className="campo">
            <span>Horómetro / horas del equipo</span>
            <input
              type="number" inputMode="decimal"
              value={form.horas_equipo} onChange={e => cambiar('horas_equipo', e.target.value)}
            />
          </label>
        </section>

        <section className="tarjeta">
          <h3>2 · Trabajo realizado</h3>

          <label className="campo">
            <span>Trabajos realizados *</span>
            <textarea rows={4} value={form.trabajos_realizados}
              onChange={e => cambiar('trabajos_realizados', e.target.value)} />
          </label>

          <label className="campo">
            <span>Observaciones</span>
            <textarea rows={3} value={form.observaciones}
              onChange={e => cambiar('observaciones', e.target.value)} />
          </label>

          <label className="campo">
            <span>Recomendaciones</span>
            <textarea rows={3} value={form.recomendaciones}
              onChange={e => cambiar('recomendaciones', e.target.value)} />
          </label>

          <label className="casilla">
            <input type="checkbox" checked={form.requiere_seguimiento}
              onChange={e => cambiar('requiere_seguimiento', e.target.checked)} />
            Requiere seguimiento
          </label>

          {form.requiere_seguimiento && (
            <label className="campo">
              <span>Fecha de seguimiento</span>
              <input type="date" value={form.fecha_seguimiento}
                onChange={e => cambiar('fecha_seguimiento', e.target.value)} />
            </label>
          )}
        </section>

        <section className="tarjeta">
          <h3>3 · Refacciones</h3>

          {refacciones.map((r, i) => (
            <div key={i} className="refaccion">
              <input
                aria-label={`Descripción de la refacción ${i + 1}`} placeholder="Descripción"
                value={r.descripcion} onChange={e => cambiarRefaccion(i, 'descripcion', e.target.value)}
              />
              <div className="fila">
                <label className="fila">
                  Cantidad
                  <input
                    type="number" inputMode="numeric" style={{ width: 96 }}
                    value={r.cantidad} onChange={e => cambiarRefaccion(i, 'cantidad', e.target.value)}
                  />
                </label>
                <button type="button" className="btn-peligro" onClick={() => quitarRefaccion(i)}>
                  Quitar
                </button>
              </div>
            </div>
          ))}
          {refacciones.length === 0 && <p className="ayuda">Sin refacciones. Agrega solo si se usó alguna.</p>}

          <button type="button" onClick={agregarRefaccion}>＋ Agregar refacción</button>
        </section>

        <section className="tarjeta">
          <h3>4 · Fotos</h3>

          <label className="btn btn-primario boton-archivo">
            ＋ Agregar fotos
            <input type="file" accept="image/*" capture="environment" multiple
              className="oculto-accesible" onChange={agregarFotos} />
          </label>

          {fotos.length > 0 && (
            <div className="fotos">
              {fotos.map((f, i) => (
                <div key={f.id} className="foto">
                  <img src={f.url} alt={`Foto ${i + 1}`} />
                  <button type="button" className="foto-quitar" aria-label={`Quitar foto ${i + 1}`}
                    onClick={() => quitarFoto(f.id)}>×</button>
                </div>
              ))}
            </div>
          )}
        </section>

        <section className="tarjeta">
          <h3>5 · Firma del cliente</h3>
          <Firma refLienzo={refLienzo} />
        </section>

        <div className="barra-accion">
          {error && <Alerta tipo="error">{error}</Alerta>}
          <button type="submit" className="btn-primario btn-grande">Guardar orden</button>
        </div>
      </form>

      {pendientes.length > 0 && (
        <section>
          <h3>Pendientes por subir ({pendientes.length})</h3>
          {pendientes.map(o => {
            const eq = equipos.find(x => x.id === o.equipo_id)
            return (
              <div key={o.id} className="tarjeta">
                <strong>{eq?.numero_serie || 'Equipo'}</strong> — {nombreTipo(o.tipo_servicio)}
                <div className="ayuda">{eq?.clientes?.nombre || 'sin cliente'} · {o.fecha}</div>
                {o.sync?.error && (
                  <div style={{ marginTop: 10 }}>
                    <Alerta tipo={o.sync.temporal ? 'aviso' : 'error'} palabra={o.sync.temporal ? 'En espera' : 'No se pudo subir'}>
                      {o.sync.error}{o.sync.intentos > 1 && ` (intento ${o.sync.intentos})`}
                    </Alerta>
                  </div>
                )}
              </div>
            )
          })}
        </section>
      )}
    </div>
  )
}
