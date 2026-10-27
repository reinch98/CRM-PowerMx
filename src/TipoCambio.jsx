// La franja del encabezado con el dólar del DOF (SQL 91). Solo el admin la ve: es quien cotiza,
// y no se le agrega una consulta al arranque del técnico (ver los contadores en App.jsx).
//
// Lo que muestra es lo que Cotizaciones aplica a los equipos en dólares, porque los dos leen el
// último valor de `tipos_cambio`. Lo guarda la Edge Function `tipo-cambio` cada mañana; "Actualizar"
// la despierta a mano (por si el DOF publicó tarde).
//
// Si no se actualiza en varios días, la franja lo dice con palabras y con un ícono: un número
// viejo con cara de bueno es peor que ninguno.
import { useEffect, useState } from 'react'
import { supabase } from './lib/supabase'
import { hoyLocal } from './lib/fechas'
import { resumenTipoCambio } from './lib/tipoCambio'

async function pedirActualizacion() {
  const { data, error } = await supabase.functions.invoke('tipo-cambio', { body: {} })
  if (error) {
    let detalle = ''
    try { detalle = (await error.context?.json())?.error || '' } catch { /* sin cuerpo */ }
    throw new Error(detalle || 'No se pudo hablar con el servicio del tipo de cambio.')
  }
  if (data?.ok === false) throw new Error(data.error || 'No se pudo actualizar.')
  return data
}

export default function TipoCambio({ pantalla }) {
  const [fila, setFila] = useState(undefined) // undefined = todavía leyendo
  const [trabajando, setTrabajando] = useState(false)
  const [error, setError] = useState('')
  const [lectura, setLectura] = useState(0)

  // Se relee al cambiar de pantalla (barato, una fila) y después de actualizar a mano.
  useEffect(() => {
    let vigente = true
    supabase.rpc('tipo_cambio_actual').then(({ data, error: e }) => {
      if (vigente) setFila(!e && data && data.valor ? data : null)
    })
    return () => { vigente = false }
  }, [pantalla, lectura])

  async function actualizar() {
    setTrabajando(true)
    setError('')
    try {
      await pedirActualizacion()
      setLectura(n => n + 1)
    } catch (e) {
      setError(e?.message || 'No se pudo actualizar.')
    } finally {
      setTrabajando(false)
    }
  }

  if (fila === undefined) return null
  const r = resumenTipoCambio(fila, hoyLocal())

  return (
    <div className="barra-cambio" role="group" aria-label="Tipo de cambio del dólar">
      {r.hay ? (
        <>
          <span className="cambio-dato">
            <span className="cambio-etiqueta">Dólar {r.fuente}</span>
            <strong className="cambio-valor">{r.valor}</strong>
            {/* Si está vencido, el aviso ya dice desde cuándo: no se repite la fecha. */}
            {!r.vencido && <span className="cambio-fecha">al {r.fecha}</span>}
          </span>
          {r.vencido && <span className="cambio-aviso"><span aria-hidden="true">⚠ </span>{r.aviso}</span>}
        </>
      ) : (
        <span className="cambio-aviso"><span aria-hidden="true">⚠ </span>{r.aviso}</span>
      )}
      {/* En el celular solo el ícono (la palabra no cabe junto al dato sin partir el renglón); el
          nombre accesible y el `title` dicen siempre qué hace. */}
      <button type="button" onClick={actualizar} disabled={trabajando}
        aria-label={trabajando ? 'Buscando el tipo de cambio' : 'Actualizar el tipo de cambio'}
        title="Buscar ahora el tipo de cambio del DOF">
        <span aria-hidden="true">{trabajando ? '…' : '↻'}</span>
        <span className="cambio-boton-texto" aria-hidden="true">{trabajando ? ' Buscando' : ' Actualizar'}</span>
      </button>
      {error && <span className="cambio-aviso" role="alert"><span aria-hidden="true">⚠ </span>{error}</span>}
    </div>
  )
}
