import { useRef } from 'react'

// ---------------------------------------------------------------------------
// Lienzo de firma. El cliente firma con el dedo; sale un PNG de ~10 KB.
// El componente padre guarda `refLienzo` para leer el dibujo (toDataURL) y saber
// si está en blanco (firmaEnBlanco).
// ---------------------------------------------------------------------------
export default function Firma({
  refLienzo,
  ayuda = 'Pídele al cliente que firme aquí con el dedo.',
  etiqueta = 'Espacio para la firma del cliente'
}) {
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
    ctx.lineWidth = 3
    ctx.lineCap = 'round'
    ctx.strokeStyle = '#0c1520'
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
    <div>
      <p className="ayuda">{ayuda}</p>
      <canvas
        ref={refLienzo}
        className="firma-lienzo"
        width={600}
        height={240}
        aria-label={etiqueta}
        onPointerDown={iniciar}
        onPointerMove={mover}
        onPointerUp={terminar}
        onPointerLeave={terminar}
      />
      <button type="button" onClick={limpiar}>Borrar y firmar de nuevo</button>
    </div>
  )
}
