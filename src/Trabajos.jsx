import { useEffect, useRef, useState } from 'react'
import { usuarioLocal, leerLocal } from './lib/local'
import { redimensionar, firmaEnBlanco, dataUrlABlob } from './lib/imagen'
import { firmarEntrega } from './lib/almacen'
import { conMaterial, usoParaCierre, porDevolver, debeDevolver, pendienteDeLinea } from './lib/material'
import { fotosDeOrden } from './lib/idb'
import { cierrePendiente, pendienteDe } from './lib/cola'
import { explicarError } from './lib/errores'
import {
  cargarTrabajos, leerTrabajos, leerNombres, leerCola, parteLocal, guardarParteLocal,
  agregarFotoLocal, quitarFotoLocal, pedirCierre, descartarPendiente,
  sincronizarTrabajos, urlsFirmadas
} from './lib/trabajos'
import { Alerta } from './ui'
import Firma from './Firma'

const NOMBRE_TIPO = {
  preventivo: 'Preventivo', correctivo: 'Correctivo', instalacion: 'Instalación',
  diagnostico: 'Diagnóstico', visita_tecnica: 'Visita técnica'
}
const ESTADO = { abierta: 'Abierta', cerrada: 'Cerrada' }

const nombreDe = (nombres, id) => nombres.find(n => n.id === id)?.nombre || 'Técnico'
const cuando = o => `${o.citas?.fecha || o.fecha}${o.citas?.hora ? ' ' + o.citas.hora.slice(0, 5) : ''}`

// Cuánto ha recibido el técnico de una pieza, con palabra (no solo color).
const estadoRecibido = l =>
  Number(l.cantidad_entregada) >= Number(l.cantidad_pedida) ? 'Completo'
    : Number(l.cantidad_entregada) > 0 ? 'Parcial' : 'Por recibir'

// ---------------------------------------------------------------------------
// Material de la orden: lo que el almacén tiene que entregar y lo que ya entregó. Sin
// precios ni costos. Si hay una entrega esperando firma, el responsable (T1) la revisa y firma
// de recibido: eso necesita señal, porque es lo que descuenta el material del inventario.
// ---------------------------------------------------------------------------
function MaterialOrden({ orden, soyT1, abierta, enLinea, nombreT1, onRefrescar }) {
  const surtido = orden.orden_surtido || []
  const entregas = (orden.entregas || []).filter(e => e.estado !== 'cancelada')
  const porFirmar = entregas.filter(e => e.estado === 'pendiente')
  const hechas = entregas.filter(e => e.estado !== 'pendiente')
  const [firmando, setFirmando] = useState(null)      // id de la entrega que se está firmando
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')
  const refLienzo = useRef(null)

  if (surtido.length === 0 && entregas.length === 0) return null

  async function confirmar(e) {
    setError('')
    if (!enLinea) return setError('Sin señal. Para firmar de recibido necesitas conexión: es lo que descuenta el material del inventario.')
    if (firmaEnBlanco(refLienzo.current)) return setError('Falta tu firma.')
    setOcupado(true)
    const r = await firmarEntrega(e.id, dataUrlABlob(refLienzo.current.toDataURL('image/png')))
    setOcupado(false)
    if (!r.ok) return setError(r.texto)
    setFirmando(null)
    await onRefrescar()
  }

  return (
    <section className="tarjeta">
      <h3>Material</h3>

      {!abierta && debeDevolver(surtido).length > 0 && (
        <Alerta tipo="aviso" palabra="Devuelve al almacén">
          Te falta devolver: {debeDevolver(surtido).map(l => `${pendienteDeLinea(l)} × ${l.sku}`).join(', ')}.
        </Alerta>
      )}

      {surtido.map(l => (
        <div key={l.id} className="linea-surtido">
          <div className="fila" style={{ justifyContent: 'space-between' }}>
            <strong>{l.sku} — {l.nombre}</strong>
            <span className="etiqueta">{estadoRecibido(l)}</span>
          </div>
          <div className="ayuda">
            Recibido {l.cantidad_entregada} de {l.cantidad_pedida}{l.unidad ? ` ${l.unidad}` : ''}
            {!abierta && Number(l.cantidad_entregada) > 0 && (
              <> · Usadas {Number(l.cantidad_usada) || 0} · Por devolver {pendienteDeLinea(l)}</>
            )}
          </div>
        </div>
      ))}

      {porFirmar.map(e => (
        <div key={e.id} className="conjunto">
          <strong>Entrega ENT-{e.folio} por recibir</strong>
          <ul>
            {(e.entrega_lineas || []).map((x, i) => <li key={i}>{x.cantidad} × {x.sku} — {x.nombre}</li>)}
          </ul>
          {!soyT1 && (
            <p className="ayuda">La firma de recibido la hace {nombreT1 || 'el responsable'}, en el almacén.</p>
          )}
          {soyT1 && abierta && firmando !== e.id && (
            <button type="button" className="btn-primario" onClick={() => { setError(''); setFirmando(e.id) }}>
              Revisar y firmar de recibido
            </button>
          )}
          {soyT1 && abierta && firmando === e.id && (
            <>
              <Firma refLienzo={refLienzo}
                ayuda="Revisa que las piezas coincidan y firma con el dedo. Al firmar, el material queda a tu cargo."
                etiqueta="Espacio para tu firma de recibido" />
              {error && <Alerta tipo="error">{error}</Alerta>}
              <div className="fila" style={{ marginTop: 10 }}>
                <button type="button" className="btn-primario" disabled={ocupado} onClick={() => confirmar(e)}>
                  {ocupado ? 'Firmando…' : 'Recibí este material'}
                </button>
                <button type="button" disabled={ocupado} onClick={() => setFirmando(null)}>Ahora no</button>
              </div>
            </>
          )}
        </div>
      ))}

      {hechas.map(e => (
        <p key={e.id} className="ayuda">
          <strong>ENT-{e.folio} · {e.estado === 'firmada' ? 'Firmada' : 'Entregada sin firma'}:</strong>{' '}
          {(e.entrega_lineas || []).map(x => `${x.cantidad} × ${x.sku}`).join(', ')}
        </p>
      ))}
    </section>
  )
}

// ---------------------------------------------------------------------------
// Detalle de una orden. Componente de nivel superior (no definido dentro de otro)
// para que los campos no pierdan el foco al escribir.
// ---------------------------------------------------------------------------
function DetalleOrden({ orden, yo, esAdmin, nombres, cola, enLinea, onVolver, onCambio, onRefrescar }) {
  const soyT1 = orden.tecnico_id === yo
  const soyT2 = orden.tecnico2_id === yo
  const abierta = orden.estado === 'abierta'
  const enCierre = cierrePendiente(cola, orden.id)
  const puedoEditar = abierta && (soyT1 || soyT2) && !enCierre

  const partes = orden.orden_partes || []
  const suya = partes.find(p => p.autor_id === yo)
  const ajenas = partes.filter(p => p.autor_id !== yo)
  const pendientes = pendienteDe(cola, orden.id)

  // Mi parte: lo guardado en el celular manda; si no hay, lo que ya está en la base.
  const [notas, setNotas] = useState(() => parteLocal(orden.id)?.notas ?? suya?.notas ?? '')
  const [fotos, setFotos] = useState(() =>
    parteLocal(orden.id)?.fotos ?? (suya?.fotos || []).map(r => ({ id: r, ruta: r })))
  const [urls, setUrls] = useState({})
  const [urlsAjenas, setUrlsAjenas] = useState({})
  const [error, setError] = useState('')

  // Cierre (solo T1)
  const [c, setC] = useState({
    horas: '', observaciones: '', recomendaciones: '', seguimiento: false, fecha_seguimiento: '', sin_firma: false
  })
  const [refacciones, setRefacciones] = useState([])
  const [uso, setUso] = useState({})            // producto_id → cuántas piezas usó (sin capturar = 0)
  const refLienzo = useRef(null)
  const temporizador = useRef(null)

  // Miniaturas de mis fotos: las del celular primero; las que ya están arriba, con URL firmada.
  useEffect(() => {
    let vivo = true
    const creadas = []
    ;(async () => {
      const locales = await fotosDeOrden(orden.id).catch(() => [])
      const mapa = {}
      for (const f of fotos) {
        const b = locales.find(x => x.id === f.id)
        if (b) { const u = URL.createObjectURL(b.blob); creadas.push(u); mapa[f.id] = u }
      }
      const faltan = fotos.filter(f => f.ruta && !mapa[f.id])
      if (faltan.length && enLinea) {
        const firmadas = await urlsFirmadas(faltan.map(f => f.ruta))
        for (const f of faltan) if (firmadas[f.ruta]) mapa[f.id] = firmadas[f.ruta]
      }
      if (vivo) setUrls(mapa)
    })()
    return () => { vivo = false; creadas.forEach(u => URL.revokeObjectURL(u)) }
  }, [fotos, orden.id, enLinea])

  // Fotos de mi compañero: solo con señal.
  const rutasAjenas = ajenas.flatMap(p => p.fotos || [])
  const claveAjenas = rutasAjenas.join('|')
  useEffect(() => {
    let vivo = true
    if (rutasAjenas.length && enLinea) urlsFirmadas(rutasAjenas).then(m => { if (vivo) setUrlsAjenas(m) })
    return () => { vivo = false }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [claveAjenas, enLinea])

  useEffect(() => () => clearTimeout(temporizador.current), [])

  // Cada cambio se guarda en el celular al instante; la subida sale unos segundos después.
  function guardar(cambios) {
    guardarParteLocal(orden.id, { notas, fotos, ...cambios })
    onCambio()
    clearTimeout(temporizador.current)
    temporizador.current = setTimeout(() => { sincronizarTrabajos().then(onCambio) }, 2000)
  }

  function cambiarNotas(v) {
    setNotas(v)
    guardar({ notas: v })
  }

  async function agregarFotos(e) {
    const archivos = Array.from(e.target.files || [])
    e.target.value = ''
    let actuales = fotos
    for (const archivo of archivos) {
      const blob = await redimensionar(archivo)
      const parte = await agregarFotoLocal(orden.id, blob, actuales)
      actuales = parte.fotos
    }
    setFotos(actuales)
    onCambio()
    clearTimeout(temporizador.current)
    temporizador.current = setTimeout(() => { sincronizarTrabajos().then(onCambio) }, 2000)
  }

  async function quitarFoto(id) {
    const parte = await quitarFotoLocal(orden.id, id, fotos)
    setFotos(parte.fotos)
    onCambio()
  }

  function cambiarRefaccion(i, campo, valor) {
    setRefacciones(refacciones.map((r, j) => (j === i ? { ...r, [campo]: valor } : r)))
  }

  function cerrar() {
    setError('')
    if (!notas.trim() && !ajenas.some(p => (p.notas || '').trim())) {
      return setError('Anota los trabajos realizados antes de cerrar la orden.')
    }
    const enBlanco = firmaEnBlanco(refLienzo.current)
    if (enBlanco && !c.sin_firma) {
      return setError('Falta la firma del cliente. Si no quiso o no pudo firmar, marca la casilla de abajo.')
    }
    if (c.seguimiento && !c.fecha_seguimiento) return setError('Pon la fecha del seguimiento.')
    if (!confirm('¿Cerrar la orden?\n\nDespués nadie puede editarla.')) return

    guardarParteLocal(orden.id, { notas, fotos })        // lo último que escribió, antes del cierre
    pedirCierre(orden.id, {
      firma_data: enBlanco ? null : refLienzo.current.toDataURL('image/png'),
      sin_firma: enBlanco,
      horas: c.horas === '' ? null : Number(c.horas),
      observaciones: c.observaciones,
      recomendaciones: c.recomendaciones,
      seguimiento: c.seguimiento,
      fecha_seguimiento: c.fecha_seguimiento,
      // Lo que usó de lo que le entregaron; lo demás se devuelve al almacén.
      uso: usoParaCierre(orden.orden_surtido, uso),
      // Lo que usó y NO le entregaron: queda como adicional por conciliar.
      refacciones: refacciones.filter(r => r.descripcion.trim())
    })
    onCambio()
    sincronizarTrabajos().then(onCambio)
  }

  async function descartar(clave) {
    if (!confirm('¿Tirar lo que está pendiente de subir en esta orden?\n\nSe pierden esas notas y fotos del celular.')) return
    await descartarPendiente(clave)
    onCambio()
  }

  const cl = orden.clientes
  const direccion = [cl?.direccion, cl?.colonia, cl?.municipio].filter(Boolean).join(', ')
  const eq = orden.equipos

  return (
    <div className="pagina pagina-angosta">
      <div className="fila" style={{ marginBottom: 8 }}>
        <button onClick={onVolver}>‹ Mis trabajos</button>
      </div>

      <div className="fila" style={{ justifyContent: 'space-between' }}>
        <h2 style={{ margin: 0 }}>OS-{orden.folio}</h2>
        <span className={`estado estado-${enCierre ? 'programada' : orden.estado}`}>
          {enCierre ? 'Cierre pendiente' : ESTADO[orden.estado] || orden.estado}
        </span>
      </div>
      <p className="ayuda">
        {soyT1 && <span className="etiqueta">Eres el responsable</span>}
        {soyT2 && <span className="etiqueta">Eres el ayudante</span>}
        {esAdmin && !soyT1 && !soyT2 && 'Vista de administrador: solo lectura.'}
      </p>

      {pendientes.filter(i => i.sync?.error).map(i => (
        <Alerta key={i.clave} tipo={i.sync.temporal ? 'aviso' : 'error'} palabra={i.sync.temporal ? 'En espera' : 'No se pudo subir'}>
          {i.tipo === 'cierre' ? 'El cierre: ' : 'Tus notas y fotos: '}{i.sync.error}
          {!i.sync.temporal && (
            <div style={{ marginTop: 8 }}>
              <button className="btn-peligro" onClick={() => descartar(i.clave)}>Tirar lo pendiente</button>
            </div>
          )}
        </Alerta>
      ))}
      {pendientes.length > 0 && !pendientes.some(i => i.sync?.error) && (
        <Alerta tipo="info" palabra="Sin subir">
          Lo que escribiste está guardado en el celular y sube solo cuando haya señal.
        </Alerta>
      )}
      <section className="tarjeta">
        <h3>{cl?.nombre || 'Cliente'}</h3>
        <div className="fila" style={{ marginBottom: 10 }}>
          {cl?.telefono && <a className="btn" href={`tel:${cl.telefono}`}>Llamar</a>}
          {cl?.maps_url && <a className="btn" href={cl.maps_url} target="_blank" rel="noreferrer">Cómo llegar</a>}
        </div>
        {direccion && <p>{direccion}</p>}
        {cl?.referencias && <p className="ayuda">{cl.referencias}</p>}
        <p>
          <strong>{NOMBRE_TIPO[orden.tipo_servicio] || orden.tipo_servicio}</strong>
          {eq?.numero_serie && <> · {eq.numero_serie}{eq.marca && ` (${eq.marca}${eq.modelo ? ' ' + eq.modelo : ''})`}</>}
        </p>
        <p className="ayuda">
          {cuando(orden)}{orden.citas?.duracion_min && ` · ${orden.citas.duracion_min} min`}
          {orden.citas?.zona && ` · ${orden.citas.zona}`}
        </p>
        {orden.citas?.notas && <p className="ayuda">{orden.citas.notas}</p>}
        <p className="ayuda">
          Responsable: {nombreDe(nombres, orden.tecnico_id)}
          {orden.tecnico2_id && <> · Ayudante: {nombreDe(nombres, orden.tecnico2_id)}</>}
        </p>
      </section>

      <MaterialOrden orden={orden} soyT1={soyT1} abierta={abierta} enLinea={enLinea}
        nombreT1={nombreDe(nombres, orden.tecnico_id)} onRefrescar={onRefrescar} />

      {/* ---- orden cerrada: solo lectura ---- */}
      {!abierta && (
        <section className="tarjeta">
          <h3>Trabajo realizado</h3>
          <p style={{ whiteSpace: 'pre-line' }}>{orden.trabajos_realizados || '—'}</p>
          {orden.observaciones && <><h4>Observaciones</h4><p style={{ whiteSpace: 'pre-line' }}>{orden.observaciones}</p></>}
          {orden.recomendaciones && <><h4>Recomendaciones</h4><p style={{ whiteSpace: 'pre-line' }}>{orden.recomendaciones}</p></>}
          {orden.requiere_seguimiento && <p><strong>Requiere seguimiento</strong>{orden.fecha_seguimiento && ` para el ${orden.fecha_seguimiento}`}</p>}
        </section>
      )}

      {/* ---- mi parte ---- */}
      {abierta && (soyT1 || soyT2) && (
        <section className="tarjeta">
          <h3>Mi parte</h3>
          <label className="campo">
            <span>Lo que hice</span>
            <textarea rows={5} value={notas} disabled={!puedoEditar} onChange={e => cambiarNotas(e.target.value)} />
          </label>

          <div className="campo">
            <span>Mis fotos</span>
            {puedoEditar && (
              <label className="btn btn-primario boton-archivo">
                ＋ Agregar fotos
                <input type="file" accept="image/*" capture="environment" multiple
                  className="oculto-accesible" onChange={agregarFotos} />
              </label>
            )}
            {fotos.length > 0 && (
              <div className="fotos">
                {fotos.map((f, i) => (
                  <div key={f.id} className="foto">
                    {urls[f.id]
                      ? <img src={urls[f.id]} alt={`Foto ${i + 1}`} />
                      : <div className="foto-vacia">Foto {i + 1}</div>}
                    {puedoEditar && (
                      <button type="button" className="foto-quitar" aria-label={`Quitar foto ${i + 1}`}
                        onClick={() => quitarFoto(f.id)}>×</button>
                    )}
                  </div>
                ))}
              </div>
            )}
          </div>
        </section>
      )}

      {/* ---- parte del otro técnico (o de todos, si mira el administrador) ---- */}
      {ajenas.map(p => (
        <section key={p.id} className="tarjeta">
          <h3>Parte de {nombreDe(nombres, p.autor_id)}</h3>
          <p className="ayuda">Solo lectura.</p>
          <p style={{ whiteSpace: 'pre-line' }}>{p.notas || 'Todavía no ha escrito nada.'}</p>
          {(p.fotos || []).length > 0 && (
            <div className="fotos">
              {p.fotos.map((r, i) => (
                urlsAjenas[r]
                  ? <div key={r} className="foto"><img src={urlsAjenas[r]} alt={`Foto ${i + 1} de ${nombreDe(nombres, p.autor_id)}`} /></div>
                  : <div key={r} className="foto"><div className="foto-vacia">Foto {i + 1}</div></div>
              ))}
            </div>
          )}
          {(p.fotos || []).length > 0 && !enLinea && <p className="ayuda">Las fotos se ven cuando haya señal.</p>}
        </section>
      ))}

      {/* ---- cierre: solo el responsable ---- */}
      {abierta && soyT2 && !soyT1 && (
        <Alerta tipo="info" palabra="Aviso">
          Solo el responsable cierra la orden y recoge la firma del cliente.
        </Alerta>
      )}

      {puedoEditar && soyT1 && (
        <>
          <section className="tarjeta">
            <h3>Cierre</h3>
            <label className="campo">
              <span>Horómetro / horas del equipo</span>
              <input type="number" inputMode="decimal" value={c.horas} onChange={e => setC({ ...c, horas: e.target.value })} />
            </label>
            <label className="campo">
              <span>Observaciones</span>
              <textarea rows={3} value={c.observaciones} onChange={e => setC({ ...c, observaciones: e.target.value })} />
            </label>
            <label className="campo">
              <span>Recomendaciones</span>
              <textarea rows={3} value={c.recomendaciones} onChange={e => setC({ ...c, recomendaciones: e.target.value })} />
            </label>
            <label className="casilla">
              <input type="checkbox" checked={c.seguimiento} onChange={e => setC({ ...c, seguimiento: e.target.checked })} />
              Requiere seguimiento
            </label>
            {c.seguimiento && (
              <label className="campo">
                <span>Fecha de seguimiento</span>
                <input type="date" value={c.fecha_seguimiento} onChange={e => setC({ ...c, fecha_seguimiento: e.target.value })} />
              </label>
            )}
          </section>

          {conMaterial(orden.orden_surtido).length > 0 && (
            <section className="tarjeta">
              <h3>Material que usé</h3>
              <p className="ayuda">
                Marca lo que gastaste en este servicio. Lo que no uses lo devuelves al almacén.
              </p>
              {conMaterial(orden.orden_surtido).map(l => {
                const recibidas = Number(l.cantidad_entregada)
                const usadas = uso[l.producto_id] ?? ''
                return (
                  <div key={l.id} className="linea-surtido">
                    <strong>{l.sku} — {l.nombre}</strong>
                    <div className="ayuda">Recibí {recibidas}{l.unidad ? ` ${l.unidad}` : ''}</div>
                    {recibidas === 1 ? (
                      <label className="casilla">
                        <input type="checkbox" checked={Number(usadas) === 1}
                          onChange={e => setUso({ ...uso, [l.producto_id]: e.target.checked ? 1 : 0 })} />
                        La usé
                      </label>
                    ) : (
                      <label className="fila">
                        <span>Usadas</span>
                        <input type="number" inputMode="decimal" min="0" max={recibidas} step="any" style={{ width: 104 }}
                          aria-label={`Piezas usadas de ${l.sku}`} placeholder="0"
                          value={usadas} onChange={e => setUso({ ...uso, [l.producto_id]: e.target.value })} />
                        <span>de {recibidas}</span>
                      </label>
                    )}
                  </div>
                )
              })}
              {porDevolver(orden.orden_surtido, uso).length > 0 && (
                <Alerta tipo="info" palabra="A devolver">
                  Al cerrar, le debes al almacén:{' '}
                  {porDevolver(orden.orden_surtido, uso).map(l => `${l.aDevolver} × ${l.sku}`).join(', ')}.
                </Alerta>
              )}
            </section>
          )}

          <section className="tarjeta">
            <h3>Material usado que no me entregaron</h3>
            <p className="ayuda">
              Solo lo que gastaste y NO venía en lo que te dio el almacén. Queda como adicional para
              revisarlo con el almacén; no descuenta inventario solo.
            </p>
            {refacciones.map((r, i) => (
              <div key={i} className="refaccion">
                <input aria-label={`Descripción de la refacción ${i + 1}`} placeholder="Descripción"
                  value={r.descripcion} onChange={e => cambiarRefaccion(i, 'descripcion', e.target.value)} />
                <div className="fila">
                  <label className="fila">Cantidad
                    <input type="number" inputMode="numeric" style={{ width: 96 }}
                      value={r.cantidad} onChange={e => cambiarRefaccion(i, 'cantidad', e.target.value)} />
                  </label>
                  <button type="button" className="btn-peligro" onClick={() => setRefacciones(refacciones.filter((_, j) => j !== i))}>Quitar</button>
                </div>
              </div>
            ))}
            <button type="button" onClick={() => setRefacciones([...refacciones, { descripcion: '', cantidad: '1' }])}>
              ＋ Agregar refacción
            </button>
          </section>

          <section className="tarjeta">
            <h3>Firma del cliente</h3>
            <Firma refLienzo={refLienzo} />
            <label className="casilla" style={{ marginTop: 10 }}>
              <input type="checkbox" checked={c.sin_firma} onChange={e => setC({ ...c, sin_firma: e.target.checked })} />
              El cliente no pudo o no quiso firmar
            </label>
          </section>

          <div className="barra-accion">
            {error && <Alerta tipo="error">{error}</Alerta>}
            <button className="btn-primario btn-grande" onClick={cerrar}>Cerrar orden</button>
          </div>
        </>
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Lista de trabajos
// ---------------------------------------------------------------------------
export default function Trabajos() {
  const [ordenes, setOrdenes] = useState(leerTrabajos)
  const [nombres, setNombres] = useState(leerNombres)
  const [cola, setCola] = useState(leerCola)
  const [seleccion, setSeleccion] = useState(null)
  const [enLinea, setEnLinea] = useState(navigator.onLine)
  const [subiendo, setSubiendo] = useState(false)
  const [aviso, setAviso] = useState('')

  const yo = usuarioLocal()?.id
  const esAdmin = leerLocal('cache_perfil', null)?.rol === 'admin'

  async function refrescar() {
    const r = await cargarTrabajos()
    if (r.ok) {
      setOrdenes(r.ordenes)
      setNombres(r.nombres)
      setAviso('')
    } else {
      setAviso(explicarError(r.error).texto)
    }
    setCola(leerCola())
  }

  async function sincronizar() {
    if (leerCola().length === 0) return          // nada por subir: no hay qué mostrar ni que hacer
    setSubiendo(true)
    const r = await sincronizarTrabajos()
    setSubiendo(false)
    if (r.corrio) await refrescar()
    else setCola(leerCola())
  }

  useEffect(() => {
    function alConectar() { setEnLinea(true); sincronizar() }
    function alDesconectar() { setEnLinea(false) }
    window.addEventListener('online', alConectar)
    window.addEventListener('offline', alDesconectar)

    // Carga inicial: el estado se cambia después de esperar a la red, no al montar.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    if (navigator.onLine) { refrescar(); sincronizar() }

    // El evento "online" no salta con señal mala: se reintenta lo pendiente cada minuto
    // y se refresca la lista cada 5.
    const reintento = setInterval(() => { if (navigator.onLine) sincronizar() }, 60000)
    const actualizar = setInterval(() => { if (navigator.onLine) refrescar() }, 300000)
    return () => {
      window.removeEventListener('online', alConectar)
      window.removeEventListener('offline', alDesconectar)
      clearInterval(reintento)
      clearInterval(actualizar)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const orden = seleccion && ordenes.find(o => o.id === seleccion)
  if (orden) {
    return (
      <DetalleOrden
        key={orden.id} orden={orden} yo={yo} esAdmin={esAdmin} nombres={nombres}
        cola={cola} enLinea={enLinea}
        onVolver={() => setSeleccion(null)} onCambio={() => setCola(leerCola())} onRefrescar={refrescar}
      />
    )
  }

  const porFecha = (a, b) => cuando(a).localeCompare(cuando(b))
  const abiertas = ordenes.filter(o => o.estado === 'abierta').sort(porFecha)
  const cerradas = ordenes.filter(o => o.estado === 'cerrada').sort((a, b) => porFecha(b, a))

  function itemOrden(o) {
    const soyT1 = o.tecnico_id === yo
    const soyT2 = o.tecnico2_id === yo
    const sinSubir = cola.some(i => i.orden_id === o.id)
    return (
      <button key={o.id} className="orden-item" onClick={() => setSeleccion(o.id)}>
        <span className="fila" style={{ justifyContent: 'space-between', width: '100%' }}>
          <strong>OS-{o.folio} · {o.clientes?.nombre || 'Cliente'}</strong>
          <span className={`estado estado-${o.estado}`}>{ESTADO[o.estado]}</span>
        </span>
        <span className="ayuda">
          {NOMBRE_TIPO[o.tipo_servicio] || o.tipo_servicio}
          {o.equipos?.numero_serie && ` · ${o.equipos.numero_serie}`} · {cuando(o)}
        </span>
        <span>
          {soyT1 && <span className="etiqueta">Responsable</span>}
          {soyT2 && <span className="etiqueta">Ayudante</span>}
          {sinSubir && <span className="etiqueta etiqueta-aviso">Sin subir</span>}
        </span>
      </button>
    )
  }

  const pendientes = cola.length

  return (
    <div className="pagina pagina-angosta">
      <h2>{esAdmin ? 'Órdenes de servicio' : 'Mis trabajos'}</h2>

      {enLinea ? (
        <Alerta tipo="ok" palabra="Con señal">
          {pendientes === 0 ? 'Todo al día.' : <strong>{pendientes} por subir.</strong>}
          {pendientes > 0 && (
            <button type="button" onClick={sincronizar} disabled={subiendo} style={{ marginLeft: 8 }}>
              {subiendo ? 'Subiendo…' : 'Subir ahora'}
            </button>
          )}
        </Alerta>
      ) : (
        <Alerta tipo="aviso" palabra="Sin señal">
          Puedes seguir trabajando: lo que escribas queda en el celular y sube solo cuando haya señal.
          {pendientes > 0 && <> <strong>{pendientes} por subir.</strong></>}
        </Alerta>
      )}
      {aviso && enLinea && <Alerta tipo="aviso" palabra="No se actualizó">{aviso}</Alerta>}

      <h3>Abiertas ({abiertas.length})</h3>
      {abiertas.length === 0 && (
        <p className="ayuda">
          {ordenes.length === 0 && !enLinea
            ? 'Todavía no hay trabajos guardados en este celular. Conéctate una vez para descargarlos.'
            : 'No tienes trabajos abiertos.'}
        </p>
      )}
      {abiertas.map(itemOrden)}

      {cerradas.length > 0 && (
        <>
          <h3 style={{ marginTop: 20 }}>Cerradas hace poco ({cerradas.length})</h3>
          {cerradas.map(itemOrden)}
        </>
      )}
    </div>
  )
}
