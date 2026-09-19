import { useEffect, useRef, useState } from 'react'
import { supabase } from './lib/supabase'

// Preguntas de arranque, para probar sin pensar qué escribir.
const EJEMPLOS = [
  '¿Qué clientes tengo?',
  '¿Qué mantenimientos vencen este mes?',
  '¿Qué hay que reordenar?',
  '¿Cuántos filtros de aire hay disponibles?',
]

export default function Agente() {
  // historial guarda el formato que espera la API, con todo y los bloques de
  // herramientas. Lo que se dibuja se filtra de ahí mismo, para no llevar dos
  // listas que se puedan desincronizar.
  const [historial, setHistorial] = useState([])
  const [pregunta, setPregunta] = useState('')
  const [pensando, setPensando] = useState(false)
  const [error, setError] = useState('')
  const [ultimasHerramientas, setUltimasHerramientas] = useState([])
  const final = useRef(null)

  useEffect(() => {
    final.current?.scrollIntoView({ behavior: 'smooth' })
  }, [historial, pensando])

  async function preguntar(texto) {
    const t = (texto ?? pregunta).trim()
    if (!t || pensando) return

    setError('')
    setPregunta('')
    setPensando(true)

    // Se pinta de inmediato lo que escribiste, sin esperar a la respuesta.
    const previo = [...historial, { role: 'user', content: t }]
    setHistorial(previo)

    try {
      const { data, error } = await supabase.functions.invoke('agente', {
        body: { pregunta: t, historial },
      })

      if (error) {
        // Cuando la función responde con error, el mensaje útil viene en el
        // cuerpo de la respuesta, no en error.message (que solo dice "non-2xx").
        let detalle = error.message
        try {
          const cuerpo = await error.context?.json?.()
          if (cuerpo?.error) detalle = cuerpo.detalle ? `${cuerpo.error}: ${cuerpo.detalle}` : cuerpo.error
          else if (cuerpo?.message) detalle = cuerpo.message
        } catch { /* la respuesta no era JSON; se queda el mensaje original */ }
        throw new Error(detalle)
      }
      if (data?.error) throw new Error(data.detalle || data.error)

      setHistorial(data.historial)
      setUltimasHerramientas(data.herramientas || [])
    } catch (e) {
      setError(e.message || String(e))
      setHistorial(historial) // se deshace el mensaje que no llegó a ningún lado
    } finally {
      setPensando(false)
    }
  }

  function limpiar() {
    setHistorial([])
    setUltimasHerramientas([])
    setError('')
  }

  // De cada mensaje se saca solo el texto legible. Los bloques de herramientas
  // no se muestran: son plomería, no conversación.
  function textoDe(m) {
    if (typeof m.content === 'string') return m.content
    if (!Array.isArray(m.content)) return ''
    return m.content.filter(b => b.type === 'text').map(b => b.text).join('\n')
  }

  const visibles = historial
    .map((m, i) => ({ ...m, i, texto: textoDe(m) }))
    .filter(m => m.texto.trim() !== '')

  const burbuja = mio => ({
    maxWidth: '80%',
    alignSelf: mio ? 'flex-end' : 'flex-start',
    background: mio ? '#14314F' : '#fff',
    color: mio ? '#fff' : '#111',
    border: mio ? 'none' : '1px solid #ddd',
    borderRadius: 10,
    padding: '10px 14px',
    whiteSpace: 'pre-wrap',
    lineHeight: 1.5,
  })

  return (
    <div style={{ padding: 20, fontFamily: 'system-ui', maxWidth: 760, margin: '0 auto' }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 12, marginBottom: 4 }}>
        <h2 style={{ margin: 0 }}>Agente</h2>
        {historial.length > 0 && (
          <button onClick={limpiar} style={{ marginLeft: 'auto' }}>Empezar de nuevo</button>
        )}
      </div>
      <p style={{ color: '#666', marginTop: 0, fontSize: 14 }}>
        Consulta clientes, equipos, historial, inventario, mantenimientos y cotizaciones. No puede modificar nada.
      </p>

      <div style={{
        display: 'flex', flexDirection: 'column', gap: 10,
        minHeight: 260, padding: 14, background: '#f6f7f9',
        borderRadius: 10, marginBottom: 12,
      }}>
        {visibles.length === 0 && !pensando && (
          <div style={{ color: '#888', margin: 'auto', textAlign: 'center' }}>
            <p>Pregúntale algo.</p>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8, justifyContent: 'center' }}>
              {EJEMPLOS.map(e => (
                <button key={e} onClick={() => preguntar(e)} style={{ padding: '6px 12px' }}>
                  {e}
                </button>
              ))}
            </div>
          </div>
        )}

        {visibles.map(m => (
          <div key={m.i} style={burbuja(m.role === 'user')}>{m.texto}</div>
        ))}

        {pensando && (
          <div style={{ ...burbuja(false), color: '#888' }}>Buscando…</div>
        )}

        <div ref={final} />
      </div>

      {ultimasHerramientas.length > 0 && !pensando && (
        <p style={{ fontSize: 12, color: '#888', marginTop: 0 }}>
          Consultó: {ultimasHerramientas.join(', ')}
        </p>
      )}

      {error && (
        <p style={{ color: 'crimson', fontSize: 14 }}>{error}</p>
      )}

      <form
        onSubmit={e => { e.preventDefault(); preguntar() }}
        style={{ display: 'flex', gap: 8 }}
      >
        <input
          value={pregunta}
          onChange={e => setPregunta(e.target.value)}
          placeholder="Escribe tu pregunta"
          disabled={pensando}
          style={{ flex: 1, padding: 12, fontSize: 16, boxSizing: 'border-box' }}
        />
        <button type="submit" disabled={pensando || !pregunta.trim()} style={{ padding: '12px 20px' }}>
          Enviar
        </button>
      </form>
    </div>
  )
}
