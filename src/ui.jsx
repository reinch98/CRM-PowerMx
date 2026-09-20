// ---------------------------------------------------------------------------
// Piezas compartidas de interfaz. Los estilos viven en index.css; aquí solo
// está lo que necesita un poco de estructura para no repetirse en cada pantalla.
// ---------------------------------------------------------------------------

// Hexágono ámbar con la P. Marcador hasta tener el logotipo real
// (POWERMX-sitio/LOGOS); al sustituirlo, cambia solo este componente.
// `sobreClaro`: el ámbar no se ve como línea sobre un fondo claro (contraste 2.1),
// así que ahí el logotipo lleva su propio recuadro azul noche.
export function Logo({ tam = 34, sobreClaro = false }) {
  return (
    <svg width={tam} height={tam} viewBox="0 0 512 512" role="img" aria-label="PowerMx" style={{ flex: 'none' }}>
      {sobreClaro && <rect width="512" height="512" rx="96" fill="#0c1520" />}
      <polygon
        points="256,56 428,156 428,356 256,456 84,356 84,156"
        fill="none" stroke="#f59e0b" strokeWidth="26" strokeLinejoin="round"
      />
      <path
        d="M206 168h94c40 0 66 24 66 62s-26 62-66 62h-46v58h-48zM254 210v40h42c14 0 22-8 22-20s-8-20-22-20z"
        fill="#f59e0b" fillRule="evenodd"
      />
    </svg>
  )
}

const ALERTAS = {
  ok:    { icono: '✓', palabra: 'Listo' },
  error: { icono: '✕', palabra: 'Error' },
  info:  { icono: 'i', palabra: 'Aviso' },
  aviso: { icono: '!', palabra: 'Ojo' },
}

// Mensaje con color, ícono y palabra: no depende de distinguir colores.
// `palabra` reemplaza la palabra por defecto ("Error", "Listo"...).
export function Alerta({ tipo = 'info', palabra, children }) {
  const a = ALERTAS[tipo]
  return (
    <div className={`alerta alerta-${tipo}`} role={tipo === 'error' ? 'alert' : 'status'}>
      <span className="alerta-icono" aria-hidden="true">{a.icono}</span>
      <div>
        <strong>{palabra ?? a.palabra}:</strong> {children}
      </div>
    </div>
  )
}
