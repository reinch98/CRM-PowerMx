import { useEffect, useRef, useState } from 'react'
import { supabase } from './lib/supabase'
import { Alerta } from './ui'

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

  return (
    <div className="pagina pagina-angosta">
      <div className="fila" style={{ justifyContent: 'space-between' }}>
        <h2 style={{ margin: 0 }}>Agente</h2>
        {historial.length > 0 && <button onClick={limpiar}>Empezar de nuevo</button>}
      </div>
      <p className="ayuda">
        Consulta clientes, equipos, historial, inventario, mantenimientos y cotizaciones. No puede modificar nada.
      </p>

      <div className="chat" aria-live="polite">
        {visibles.length === 0 && !pensando && (
          <div className="chat-vacio">
            <p>Pregúntale algo.</p>
            <div className="fila" style={{ justifyContent: 'center' }}>
              {EJEMPLOS.map(e => <button key={e} onClick={() => preguntar(e)}>{e}</button>)}
            </div>
          </div>
        )}

        {visibles.map(m => (
          <div key={m.i} className={`burbuja${m.role === 'user' ? ' burbuja-mia' : ''}`}>{m.texto}</div>
        ))}

        {pensando && <div className="burbuja">Buscando…</div>}

        <div ref={final} />
      </div>

      {ultimasHerramientas.length > 0 && !pensando && (
        <p className="ayuda">Consultó: {ultimasHerramientas.join(', ')}</p>
      )}

      {error && <Alerta tipo="error">{error}</Alerta>}

      <form onSubmit={e => { e.preventDefault(); preguntar() }} className="fila" style={{ flexWrap: 'nowrap' }}>
        <input
          value={pregunta}
          onChange={e => setPregunta(e.target.value)}
          placeholder="Escribe tu pregunta"
          aria-label="Tu pregunta"
          disabled={pensando}
          style={{ flex: 1, minWidth: 0 }}
        />
        <button type="submit" className="btn-primario" disabled={pensando || !pregunta.trim()}>
          Enviar
        </button>
      </form>
    </div>
  )
}
