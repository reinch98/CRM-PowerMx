import { useEffect, useRef, useState } from 'react'
import { supabase } from './lib/supabase'
import { guardarFoto, fotosDeOrden, borrarFotosDeOrden } from './lib/idb'
import { redimensionar, dataUrlABlob } from './lib/imagen'
import { hoyLocal } from './lib/fechas'

const COLA = 'ordenes_pendientes'
const CACHE_EQUIPOS = 'cache_equipos'
const BUCKET = 'ordenes'

function leerLocal(clave, porDefecto) {
  try {
    const crudo = localStorage.getItem(clave)
    return crudo ? JSON.parse(crudo) : porDefecto
  } catch {
    return porDefecto
  }
}

function escribirLocal(clave, valor) {
  try {
    localStorage.setItem(clave, JSON.stringify(valor))
  } catch {
    // Si el almacenamiento está lleno o bloqueado, no tumbamos la app.
  }
}

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

// ---------------------------------------------------------------------------
// Lienzo de firma. El cliente firma con el dedo; sale un PNG de ~10 KB.
// ---------------------------------------------------------------------------
function Firma({ refLienzo }) {
  const dibujando = useRef(false)

  function posicion(e) {
    const lienzo = refLienzo.current
    const caja = lienzo.getBoundingClientRect()
    return {
      x: (e.clientX - caja.left) * (lienzo.width / caja.width),
      y: (e.clientY - caja.top) * (lienzo.height / caja.height)
    }
  }

  function iniciar(e) {
    e.preventDefault()
    dibujando.current = true
    const ctx = refLienzo.current.getContext('2d')
    const { x, y } = posicion(e)
    ctx.beginPath()
    ctx.moveTo(x, y)
  }

  function mover(e) {
    if (!dibujando.current) return
    e.preventDefault()
    const ctx = refLienzo.current.getContext('2d')
    const { x, y } = posicion(e)
    ctx.lineWidth = 2
    ctx.lineCap = 'round'
    ctx.strokeStyle = '#000'
    ctx.lineTo(x, y)
    ctx.stroke()
  }

  function terminar() {
    dibujando.current = false
  }

  function limpiar() {
    const lienzo = refLienzo.current
    lienzo.getContext('2d').clearRect(0, 0, lienzo.width, lienzo.height)
  }

  return (
    <div style={{ marginBottom: 12 }}>
      <div style={{ marginBottom: 4 }}>Firma del cliente</div>
      <canvas
        ref={refLienzo}
        width={600}
        height={200}
        onPointerDown={iniciar}
        onPointerMove={mover}
        onPointerUp={terminar}
        onPointerLeave={terminar}
        style={{
          width: '100%',
          height: 160,
          border: '1px solid #999',
          borderRadius: 6,
          background: '#fff',
          touchAction: 'none'   // sin esto, arrastrar el dedo desplaza la página
        }}
      />
      <button type="button" onClick={limpiar}>Limpiar firma</button>
    </div>
  )
}

export default function Ordenes() {
  const [equipos, setEquipos] = useState(() => leerLocal(CACHE_EQUIPOS, []))
  const [pendientes, setPendientes] = useState(() => leerLocal(COLA, []))
  const [form, setForm] = useState(vacio)
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

    return () => {
      window.removeEventListener('online', alConectar)
      window.removeEventListener('offline', alDesconectar)
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
  async function subirOrden(orden) {
    const rutas = []

    const guardadas = await fotosDeOrden(orden.id)
    for (const foto of guardadas) {
      const ruta = `${orden.id}/${foto.id}.jpg`
      const { error } = await supabase.storage
        .from(BUCKET)
        .upload(ruta, foto.blob, { contentType: 'image/jpeg', upsert: true })
      if (error) return false
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
      if (error) return false
    }

    // firma_data solo existe mientras la orden está en la cola: a la base va la ruta.
    const { firma_data, ...limpio } = orden
    const { error } = await supabase
      .from('ordenes_servicio')
      .insert([{ ...limpio, fotos: rutas, firma_cliente: rutaFirma }])

    // 23505 = ya existía ese id. Pasó en un intento anterior que se cortó; cuenta como subida.
    if (error && error.code !== '23505') return false

    await borrarFotosDeOrden(orden.id)
    return true
  }

  async function sincronizar() {
    const cola = leerLocal(COLA, [])
    if (cola.length === 0 || sincronizando.current) return

    sincronizando.current = true
    setSubiendo(true)
    const quedan = []
    let subidas = 0

    for (const orden of cola) {
      const ok = await subirOrden(orden)
      if (ok) subidas++
      else quedan.push(orden)
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

  function firmaEnBlanco(lienzo) {
    const { data } = lienzo.getContext('2d').getImageData(0, 0, lienzo.width, lienzo.height)
    for (let i = 3; i < data.length; i += 4) if (data[i] !== 0) return false
    return true
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
      // getSession lee la sesión guardada en el celular. getUser hace una
      // petición de red y sin señal devolvería null, dejando la orden huérfana.
      tecnico_id: (await supabase.auth.getSession()).data.session?.user?.id || null,
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

    if (navigator.onLine) sincronizar()
  }

  const etiqueta = eq =>
    `${eq.numero_serie} — ${eq.clientes?.nombre || 'sin cliente'}${eq.marca ? ` (${eq.marca})` : ''}`

  const campo = { width: '100%', padding: 10, fontSize: 16, boxSizing: 'border-box' }
  const bloque = { display: 'block', marginBottom: 12 }

  return (
    <div style={{ padding: 16, fontFamily: 'system-ui', maxWidth: 560, margin: '0 auto' }}>
      <h2>Orden de servicio</h2>

      <div style={{
        padding: 10,
        marginBottom: 16,
        borderRadius: 6,
        background: enLinea ? '#e8f5e9' : '#fff3e0'
      }}>
        {enLinea ? 'Con señal' : 'Sin señal — se guarda en el celular'}
        {pendientes.length > 0 && (
          <>
            {' · '}
            <strong>{pendientes.length} por subir</strong>
            {enLinea && (
              <button onClick={sincronizar} disabled={subiendo} style={{ marginLeft: 10 }}>
                {subiendo ? 'Subiendo…' : 'Subir ahora'}
              </button>
            )}
          </>
        )}
      </div>

      <form onSubmit={guardar}>
        <label style={bloque}>
          Equipo *<br />
          <select value={form.equipo_id} onChange={e => cambiar('equipo_id', e.target.value)} style={campo}>
            <option value="">— Elige el equipo —</option>
            {equipos.map(eq => (
              <option key={eq.id} value={eq.id}>{etiqueta(eq)}</option>
            ))}
          </select>
          {equipos.length === 0 && (
            <small>No hay equipos guardados en este celular. Conéctate una vez para descargarlos.</small>
          )}
        </label>

        <label style={bloque}>
          Fecha<br />
          <input type="date" value={form.fecha} onChange={e => cambiar('fecha', e.target.value)} style={campo} />
        </label>

        <label style={bloque}>
          Tipo de servicio<br />
          <select value={form.tipo_servicio} onChange={e => cambiar('tipo_servicio', e.target.value)} style={campo}>
            <option value="preventivo">Preventivo</option>
            <option value="correctivo">Correctivo</option>
            <option value="instalacion">Instalación</option>
            <option value="diagnostico">Diagnóstico</option>
          </select>
        </label>

        <label style={bloque}>
          Técnico<br />
          <input value={form.tecnico} onChange={e => cambiar('tecnico', e.target.value)} style={campo} />
        </label>

        <label style={bloque}>
          Horómetro / horas del equipo<br />
          <input
            type="number"
            inputMode="decimal"
            value={form.horas_equipo}
            onChange={e => cambiar('horas_equipo', e.target.value)}
            style={campo}
          />
        </label>

        <label style={bloque}>
          Trabajos realizados *<br />
          <textarea
            rows={4}
            value={form.trabajos_realizados}
            onChange={e => cambiar('trabajos_realizados', e.target.value)}
            style={campo}
          />
        </label>

        <fieldset style={{ border: '1px solid #ccc', padding: 12, marginBottom: 12 }}>
          <legend>Refacciones</legend>
          {refacciones.map((r, i) => (
            <div key={i} style={{ display: 'flex', gap: 6, marginBottom: 6 }}>
              <input
                placeholder="Descripción"
                value={r.descripcion}
                onChange={e => cambiarRefaccion(i, 'descripcion', e.target.value)}
                style={{ ...campo, flex: 3 }}
              />
              <input
                type="number"
                inputMode="numeric"
                value={r.cantidad}
                onChange={e => cambiarRefaccion(i, 'cantidad', e.target.value)}
                style={{ ...campo, flex: 1 }}
              />
              <button type="button" onClick={() => quitarRefaccion(i)}>×</button>
            </div>
          ))}
          <button type="button" onClick={agregarRefaccion}>Agregar refacción</button>
        </fieldset>

        <fieldset style={{ border: '1px solid #ccc', padding: 12, marginBottom: 12 }}>
          <legend>Fotos</legend>
          <input
            type="file"
            accept="image/*"
            capture="environment"
            multiple
            onChange={agregarFotos}
            style={{ marginBottom: 8 }}
          />
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
            {fotos.map(f => (
              <div key={f.id} style={{ position: 'relative' }}>
                <img
                  src={f.url}
                  alt=""
                  style={{ width: 90, height: 90, objectFit: 'cover', borderRadius: 4 }}
                />
                <button
                  type="button"
                  onClick={() => quitarFoto(f.id)}
                  style={{ position: 'absolute', top: 2, right: 2 }}
                >
                  ×
                </button>
              </div>
            ))}
          </div>
        </fieldset>

        <label style={bloque}>
          Observaciones<br />
          <textarea
            rows={3}
            value={form.observaciones}
            onChange={e => cambiar('observaciones', e.target.value)}
            style={campo}
          />
        </label>

        <label style={bloque}>
          Recomendaciones<br />
          <textarea
            rows={3}
            value={form.recomendaciones}
            onChange={e => cambiar('recomendaciones', e.target.value)}
            style={campo}
          />
        </label>

        <label style={bloque}>
          <input
            type="checkbox"
            checked={form.requiere_seguimiento}
            onChange={e => cambiar('requiere_seguimiento', e.target.checked)}
          />
          {' '}Requiere seguimiento
        </label>

        {form.requiere_seguimiento && (
          <label style={bloque}>
            Fecha de seguimiento<br />
            <input
              type="date"
              value={form.fecha_seguimiento}
              onChange={e => cambiar('fecha_seguimiento', e.target.value)}
              style={campo}
            />
          </label>
        )}

        <Firma refLienzo={refLienzo} />

        <button type="submit" style={{ ...campo, padding: 14, fontSize: 17 }}>
          Guardar orden
        </button>

        {error && <p style={{ color: 'crimson' }}>{error}</p>}
        {mensaje && <p style={{ color: 'green' }}>{mensaje}</p>}
      </form>

      {pendientes.length > 0 && (
        <>
          <h3>Pendientes por subir</h3>
          <ul>
            {pendientes.map(o => (
              <li key={o.id}>
                {o.fecha} — {equipos.find(eq => eq.id === o.equipo_id)?.numero_serie || 'equipo'} — {o.tipo_servicio}
              </li>
            ))}
          </ul>
        </>
      )}
    </div>
  )
}
