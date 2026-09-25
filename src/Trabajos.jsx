import { useEffect, useRef, useState } from 'react'
import { usuarioLocal, leerLocal } from './lib/local'
import { redimensionar, firmaEnBlanco, dataUrlABlob } from './lib/imagen'
import { firmarEntrega, cargarExistencias } from './lib/almacen'
import { conMaterial, usoParaCierre, porDevolver, debeDevolver, pendienteDeLinea } from './lib/material'
import {
  etiquetaEstado, nombrePieza, problemaDeSolicitud,
  crearSolicitud, cargarSolicitudesDeOrden, cancelarSolicitud
} from './lib/solicitudes'
import {
  construirPdfOrden, guardarPdfExpediente, cargarPdfDeOrden, cargarEnviosDeOrden,
  cargarDestinatariosOrden, registrarEnvio, urlDePdf
} from './lib/documentos'
import { enlaceWhatsApp } from './lib/avisos'
import {
  FORMATO_SOLAR, FORMATO_GENERADOR, COMBUSTIBLES_GEN, TIPOS_SERVICIO_GEN,
  CALIFICACIONES, DICTAMENES, seccionesVisibles, avanceSeccion, aplica,
  dictamenSugerido, loQueFalta, avisosMediciones, veredictoString,
  LECTURAS_GEN, TIPOS_TRANSFERENCIA, TRANSFERENCIA_GEN, AC_SOLAR, BANCO_SOLAR,
  COLUMNAS_STRING, VEREDICTOS, stringNuevo, PLACAS_SOLAR, PLACAS_GENERADOR, placaGuardada
} from './lib/revision'
import {
  TIPOS_EQUIPO, COMBUSTIBLES, nombreTipoEquipo, descripcionEquipo, textoHorometro,
  revisarDatosEquipo, datosParaGuardar, cargarEquiposDeCliente, ligarEquipo, altaEquipoEnOrden
} from './lib/equipoCampo'
import { fotosDeOrden } from './lib/idb'
import { cierrePendiente, pendienteDe } from './lib/cola'
import { explicarError } from './lib/errores'
import {
  cargarTrabajos, leerTrabajos, leerNombres, leerCola, parteLocal, guardarParteLocal,
  agregarFotoLocal, quitarFotoLocal, pedirCierre, descartarPendiente,
  sincronizarTrabajos, urlsFirmadas, marcarEnviarAlCerrar,
  revisionDeOrden, guardarRevisionLocal, guardarFotoRevision, olvidarFotoRevision
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
// Pedir una pieza que hace falta (típicamente para la próxima visita). Es una solicitud, no
// una requisición: no mueve inventario ni ve costos, solo avisa al almacén/admin. Necesita
// señal (como el resto del almacén); no hay cola sin conexión para esto.
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Qué equipo es (SQL 23). La orden puede nacer SIN equipo: el cliente casi nunca sabe el
// modelo ni la serie, y el técnico sí, porque está frente a la placa. Aquí lo elige de los
// que el cliente ya tiene guardados, o lo da de alta. Sin serie también se puede: una placa
// borrada no detiene el trabajo.
//
// Necesita señal, como pedir material. El equipo hay que fijarlo ANTES de cerrar: al cerrar,
// el horómetro sube solo al equipo que tenga la orden en ese momento.
// ---------------------------------------------------------------------------
const EQUIPO_VACIO = {
  tipo: 'generador', marca: '', modelo: '', capacidad_kw: '',
  combustible: '', numero_serie: '', ubicacion_equipo: ''
}

function EquipoOrden({ orden, puedeEditar, enLinea, onRefrescar }) {
  const [guardados, setGuardados] = useState(null)   // null = aún no se piden
  const [eligiendo, setEligiendo] = useState(false)
  const [form, setForm] = useState(EQUIPO_VACIO)
  const [alta, setAlta] = useState(false)
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState('')

  const eq = orden.equipos
  const sinEquipo = !orden.equipo_id

  async function abrirEleccion() {
    setEligiendo(true); setError(''); setMensaje('')
    if (guardados === null) {
      const r = await cargarEquiposDeCliente(orden.cliente_id)
      if (r.ok) setGuardados(r.equipos.filter(x => x.id !== orden.equipo_id))
      else setError(r.texto)
    }
  }

  async function elegir(id) {
    setOcupado(true); setError('')
    const r = await ligarEquipo(orden.id, id)
    setOcupado(false)
    if (!r.ok) return setError(r.texto)
    setMensaje('Listo, la orden ya quedó en ese equipo.')
    setEligiendo(false); setGuardados(null)
    onRefrescar()
  }

  async function darDeAlta() {
    const problema = revisarDatosEquipo(form)
    if (problema) return setError(problema)
    setError(''); setOcupado(true)
    const r = await altaEquipoEnOrden(orden.id, datosParaGuardar(form))
    setOcupado(false)
    if (!r.ok) return setError(r.texto)
    setMensaje(r.data?.reusado
      ? 'Ese equipo ya estaba registrado con esa serie: se completó y quedó ligado a la orden.'
      : 'Equipo dado de alta y ligado a la orden.')
    setForm(EQUIPO_VACIO); setAlta(false); setEligiendo(false); setGuardados(null)
    onRefrescar()
  }

  return (
    <section className="tarjeta">
      <h3>Equipo</h3>

      {sinEquipo ? (
        <Alerta tipo="aviso" palabra="Falta">
          Esta orden todavía no dice de qué equipo es. Dilo antes de cerrarla: el horómetro se
          guarda en el equipo que quede elegido.
        </Alerta>
      ) : (
        <>
          <p style={{ margin: '4px 0' }}>
            <strong>{descripcionEquipo(eq)}</strong>
          </p>
          <p className="ayuda">
            {nombreTipoEquipo(eq?.tipo)}
            {eq?.numero_serie
              ? <> · Serie {eq.numero_serie}</>
              : <> · <span className="etiqueta etiqueta-aviso">Serie pendiente</span></>}
            {textoHorometro(eq) && <> · {textoHorometro(eq)}</>}
          </p>
        </>
      )}

      {mensaje && <Alerta tipo="ok" palabra="Listo">{mensaje}</Alerta>}
      {error && <Alerta tipo="error">{error}</Alerta>}

      {puedeEditar && !enLinea && (
        <Alerta tipo="aviso" palabra="Sin señal">Para elegir o dar de alta el equipo necesitas conexión.</Alerta>
      )}

      {puedeEditar && enLinea && !eligiendo && (
        <button className={sinEquipo ? 'btn-primario' : undefined} onClick={abrirEleccion}>
          {sinEquipo ? '¿Qué equipo es?' : 'No es este equipo'}
        </button>
      )}

      {puedeEditar && enLinea && eligiendo && (
        <>
          {guardados === null && <p className="ayuda">Cargando los equipos de este cliente…</p>}

          {guardados?.length > 0 && (
            <>
              <p className="ayuda">Equipos que este cliente ya tiene guardados:</p>
              {guardados.map(g => (
                <button key={g.id} className="orden-item" disabled={ocupado} onClick={() => elegir(g.id)}>
                  <strong>{descripcionEquipo(g)}</strong>
                  <span className="ayuda">
                    {nombreTipoEquipo(g.tipo)}
                    {g.numero_serie ? <> · Serie {g.numero_serie}</> : <> · Serie pendiente</>}
                  </span>
                </button>
              ))}
            </>
          )}
          {guardados?.length === 0 && (
            <p className="ayuda">Este cliente no tiene ningún otro equipo guardado.</p>
          )}

          {!alta && guardados !== null && (
            <div className="fila">
              <button className="btn-primario" onClick={() => { setAlta(true); setError('') }}>
                Es un equipo nuevo
              </button>
              <button onClick={() => { setEligiendo(false); setAlta(false); setError('') }}>Cancelar</button>
            </div>
          )}

          {alta && (
            <div style={{ marginTop: 12 }}>
              <label className="campo">
                <span>Tipo de equipo</span>
                <select value={form.tipo} onChange={e => setForm({ ...form, tipo: e.target.value })}>
                  {TIPOS_EQUIPO.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
                </select>
              </label>
              <div className="rejilla-2">
                <label className="campo">
                  <span>Marca</span>
                  <input value={form.marca} onChange={e => setForm({ ...form, marca: e.target.value })} />
                </label>
                <label className="campo">
                  <span>Modelo</span>
                  <input value={form.modelo} onChange={e => setForm({ ...form, modelo: e.target.value })} />
                </label>
                <label className="campo">
                  <span>Capacidad (kW)</span>
                  <input type="number" inputMode="decimal" value={form.capacidad_kw}
                    onChange={e => setForm({ ...form, capacidad_kw: e.target.value })} />
                </label>
                {form.tipo === 'generador' && (
                  <label className="campo">
                    <span>Combustible</span>
                    <select value={form.combustible} onChange={e => setForm({ ...form, combustible: e.target.value })}>
                      <option value="">— Elige —</option>
                      {COMBUSTIBLES.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
                    </select>
                  </label>
                )}
              </div>
              <label className="campo">
                <span>Número de serie</span>
                <input value={form.numero_serie} onChange={e => setForm({ ...form, numero_serie: e.target.value })} />
              </label>
              <p className="ayuda">
                Si la placa está borrada o no alcanzas a leerla, déjalo vacío y escribe dónde
                está el equipo. Se guarda igual y en la oficina consiguen la serie después.
              </p>
              <label className="campo">
                <span>Dónde está</span>
                <input value={form.ubicacion_equipo} placeholder="Atrás del taller, junto al tinaco"
                  onChange={e => setForm({ ...form, ubicacion_equipo: e.target.value })} />
              </label>
              <div className="fila">
                <button className="btn-primario" disabled={ocupado} onClick={darDeAlta}>
                  {ocupado ? 'Guardando…' : 'Guardar el equipo'}
                </button>
                <button onClick={() => { setAlta(false); setError('') }}>Cancelar</button>
              </div>
            </div>
          )}
        </>
      )}
    </section>
  )
}

// ---------------------------------------------------------------------------
// El formato de mantenimiento en el celular (SQL 24 y `lib/revision.js`).
//
// Se guarda en el celular en CADA toque, sin botón de guardar, y sube cuando hay señal:
// esto se llena en una azotea, muchas veces sin cobertura.
//
// Lo que hace corto el formato: la caja de hallazgo solo aparece al marcar Regular o Malo,
// las secciones van plegadas con su contador, y la de baterías no existe si el sistema no
// las tiene.
// ---------------------------------------------------------------------------
const CLIMAS = [['despejado', 'Despejado'], ['parcial', 'Parcial'], ['nublado', 'Nublado']]

function PuntoRevision({ punto, valor, puedeEditar, onCambio, onFoto }) {
  const v = valor?.v || ''
  const exigeTexto = v === 'R' || v === 'M'
  return (
    <div className="refaccion">
      <strong>{punto.titulo}</strong>
      {punto.detalle && <span className="ayuda">{punto.detalle}</span>}
      <div className="fila">
        {CALIFICACIONES.map(([k, t]) => (
          <button key={k} type="button" disabled={!puedeEditar}
            className={v === k ? 'btn-primario' : undefined}
            aria-pressed={v === k}
            onClick={() => onCambio({ ...(valor || {}), v: k })}>
            {t}
          </button>
        ))}
      </div>
      {exigeTexto && (
        <label className="campo">
          <span>{v === 'M' ? 'Qué encontraste y qué hiciste' : 'Hallazgo'}</span>
          <textarea rows={2} value={valor?.obs || ''} disabled={!puedeEditar}
            onChange={e => onCambio({ ...(valor || {}), obs: e.target.value })} />
        </label>
      )}
      {exigeTexto && (
        <>
          <div className="fila">
            {puedeEditar && (
              <label className="btn boton-archivo">
                ＋ Foto del hallazgo
                <input type="file" accept="image/*" capture="environment" multiple
                  className="oculto-accesible" onChange={e => onFoto(e)} />
              </label>
            )}
            {(valor?.fotos?.length > 0) && (
              <span className="etiqueta">
                {valor.fotos.length} foto{valor.fotos.length === 1 ? '' : 's'}
              </span>
            )}
          </div>
          {v === 'M' && !(valor?.fotos?.length > 0) && (
            <span className="ayuda">
              Todo punto en "Malo" se documenta con fotografía.
            </span>
          )}
        </>
      )}
      {v && v !== 'NA' && (punto.campos || []).map(([clave, etiqueta]) => (
        <label key={clave} className="campo">
          <span>{etiqueta}</span>
          <input value={valor?.[clave] || ''} disabled={!puedeEditar}
            onChange={e => onCambio({ ...(valor || {}), [clave]: e.target.value })} />
        </label>
      ))}
    </div>
  )
}

// Una lectura con su unidad. En el papel son tablas anchas; aquí cada renglón cabe en el
// celular, con el rango esperado a la vista para no tener que recordarlo.
function Lectura({ campo, valor, puedeEditar, columnas, onCambio }) {
  return (
    <div className="refaccion">
      <strong>{campo.titulo}{campo.unidad ? ` (${campo.unidad})` : ''}</strong>
      {campo.espera && <span className="ayuda">Se espera: {campo.espera}</span>}
      <div className="rejilla-2">
        {columnas.map(([k, t]) => (
          <label key={k} className="campo">
            <span>{t}</span>
            <input type="number" inputMode="decimal" disabled={!puedeEditar}
              value={valor?.[k] ?? ''} onChange={e => onCambio({ ...(valor || {}), [k]: e.target.value })} />
          </label>
        ))}
      </div>
    </div>
  )
}

function MedicionesGenerador({ med, ctx, puedeEditar, onCambio }) {
  const lecturas = med.lecturas || {}
  const trans = med.transferencia || {}
  // El tipo A es solo inspección con prueba en vacío: no se pide la columna de carga.
  const conCarga = ctx.tipo_servicio !== 'A'
  const columnas = conCarga ? [['vacio', 'En vacío'], ['carga', 'Con carga']] : [['vacio', 'En vacío']]

  return (
    <>
      {conCarga && (
        <label className="campo">
          <span>Carga de la prueba (%)</span>
          <input type="number" inputMode="decimal" disabled={!puedeEditar}
            value={med.carga_pct ?? ''} onChange={e => onCambio({ ...med, carga_pct: e.target.value })} />
        </label>
      )}
      <p className="ayuda">
        Mínimo 15 min en vacío. Con carga, al menos 30 min al 30 % o más de la capacidad.
      </p>

      {LECTURAS_GEN.filter(c => aplica(c, ctx)).map(c => (
        <Lectura key={c.clave} campo={c} columnas={columnas} puedeEditar={puedeEditar}
          valor={lecturas[c.clave]}
          onCambio={v => onCambio({ ...med, lecturas: { ...lecturas, [c.clave]: v } })} />
      ))}

      <h4>Prueba de transferencia</h4>
      <label className="campo">
        <span>Cómo se probó</span>
        <select value={trans.tipo || ''} disabled={!puedeEditar}
          onChange={e => onCambio({ ...med, transferencia: { ...trans, tipo: e.target.value } })}>
          <option value="">— Elige —</option>
          {TIPOS_TRANSFERENCIA.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
        </select>
      </label>
      <div className="rejilla-2">
        {TRANSFERENCIA_GEN.map(([k, t]) => (
          <label key={k} className="campo">
            <span>{t}</span>
            <input type="number" inputMode="decimal" disabled={!puedeEditar} value={trans[k] ?? ''}
              onChange={e => onCambio({ ...med, transferencia: { ...trans, [k]: e.target.value } })} />
          </label>
        ))}
      </div>
      <div className="fila">
        {[['aprobada', 'Transferencia aprobada'], ['no_aprobada', 'No aprobada']].map(([v, t]) => (
          <button key={v} type="button" disabled={!puedeEditar}
            className={trans.resultado === v ? 'btn-primario' : undefined}
            aria-pressed={trans.resultado === v}
            onClick={() => onCambio({ ...med, transferencia: { ...trans, resultado: v } })}>
            {t}
          </button>
        ))}
      </div>
    </>
  )
}

function MedicionesSolar({ med, ctx, puedeEditar, onCambio }) {
  const strings = med.strings || []
  const ac = med.ac || {}
  const banco = med.banco || {}

  const cambiarString = (i, campo, v) =>
    onCambio({ ...med, strings: strings.map((s, k) => (k === i ? { ...s, [campo]: v } : s)) })

  return (
    <>
      <h4>Strings</h4>
      <p className="ayuda">
        Agrega solo los que tenga la instalación. El veredicto se propone solo: aislamiento
        por debajo de 1 MΩ no pasa, y una Voc que se aleje más del 10 % de la teórica se revisa.
      </p>
      {strings.map((s, i) => {
        const v = veredictoString(s)
        return (
          <div key={i} className="refaccion">
            <span className="fila" style={{ justifyContent: 'space-between' }}>
              <strong>String {i + 1}</strong>
              {v && <span className={`etiqueta${v === 'pasa' ? '' : ' etiqueta-aviso'}`}>{VEREDICTOS[v]}</span>}
            </span>
            <div className="rejilla-2">
              {COLUMNAS_STRING.map(([k, t]) => (
                <label key={k} className="campo">
                  <span>{t}</span>
                  <input type={k === 'mppt' ? 'text' : 'number'} inputMode={k === 'mppt' ? 'text' : 'decimal'}
                    disabled={!puedeEditar} value={s[k] ?? ''}
                    onChange={e => cambiarString(i, k, e.target.value)} />
                </label>
              ))}
            </div>
            {puedeEditar && (
              <button type="button" className="btn-peligro"
                onClick={() => onCambio({ ...med, strings: strings.filter((_, k) => k !== i) })}>
                Quitar este string
              </button>
            )}
          </div>
        )
      })}
      {puedeEditar && (
        <button type="button" onClick={() => onCambio({ ...med, strings: [...strings, stringNuevo()] })}>
          ＋ Agregar string
        </button>
      )}

      <h4 style={{ marginTop: 16 }}>Parámetros AC en el tablero</h4>
      <div className="rejilla-2">
        {AC_SOLAR.filter(c => aplica(c, ctx)).map(c => (
          <label key={c.clave} className="campo">
            <span>{c.titulo} ({c.unidad})</span>
            <input type="number" inputMode="decimal" disabled={!puedeEditar} value={ac[c.clave] ?? ''}
              onChange={e => onCambio({ ...med, ac: { ...ac, [c.clave]: e.target.value } })} />
          </label>
        ))}
      </div>

      <h4 style={{ marginTop: 16 }}>Banco y tierra</h4>
      <div className="rejilla-2">
        {BANCO_SOLAR.filter(c => aplica(c, ctx)).map(c => (
          <label key={c.clave} className="campo">
            <span>{c.titulo} ({c.unidad})</span>
            <input type="number" inputMode="decimal" disabled={!puedeEditar} value={banco[c.clave] ?? ''}
              onChange={e => onCambio({ ...med, banco: { ...banco, [c.clave]: e.target.value } })} />
          </label>
        ))}
      </div>
    </>
  )
}

function RevisionOrden({ orden, puedeEditar }) {
  const guardada = revisionDeOrden(orden)
  const [datos, setDatos] = useState(guardada?.datos || {})
  const [abierta, setAbierta] = useState(null)

  const eq = orden.equipos
  // El tipo de trabajo sale del equipo: un fotovoltaico y un generador no se revisan igual.
  // Sin equipo todavía (primera visita), se asume generador, que es lo más común.
  const esSolar = eq?.tipo === 'solar' || eq?.tipo === 'bateria' || guardada?.tipo === 'solar'
  const tipo = esSolar ? 'solar' : 'generador'
  const formato = esSolar ? FORMATO_SOLAR : FORMATO_GENERADOR
  const llegada = datos.llegada || {}

  // Por defecto, un equipo de tipo batería sí tiene banco; en un fotovoltaico lo dice el técnico.
  const bess = llegada.bess ?? (eq?.tipo === 'bateria')
  const plomo = !!llegada.plomo
  // El combustible decide qué puntos existen. Sale del equipo; si no está capturado,
  // lo elige el técnico aquí (y queda anotado para este servicio).
  const combustible = llegada.combustible || eq?.atributos?.combustible || ''
  // Las fases que el equipo no tiene no se preguntan: en el papel siempre venían las tres.
  const trifasico = llegada.trifasico ?? false
  const ctx = esSolar
    ? { bess, plomo, trifasico }
    : { combustible, trifasico, tipo_servicio: llegada.tipo_servicio, mayor: llegada.tipo_servicio === 'C' }
  const secciones = seccionesVisibles(formato, ctx)

  function escribir(cambio) {
    const nuevos = { ...datos, ...cambio }
    setDatos(nuevos)
    guardarRevisionLocal(orden.id, tipo, nuevos)
  }
  const cambiarLlegada = c => escribir({ llegada: { ...llegada, ...c } })
  const cambiarPunto = (clave, valor) => escribir({ puntos: { ...(datos.puntos || {}), [clave]: valor } })

  // La foto se queda en el celular pegada a SU punto. En el papel todas caían en un montón
  // y el formato solo apuntaba cuántas eran; aquí la del hot spot queda en el punto del
  // hot spot, y así se puede ver el historial de ese punto en ese equipo.
  async function agregarFotosPunto(clave, e) {
    const archivos = [...e.target.files]
    e.target.value = ''
    const previo = datos.puntos?.[clave] || {}
    const fotos = [...(previo.fotos || [])]
    for (const archivo of archivos) {
      const blob = await redimensionar(archivo)
      fotos.push({ id: await guardarFotoRevision(orden.id, blob, 'revision'), ruta: null })
    }
    cambiarPunto(clave, { ...previo, fotos })
  }

  async function agregarPlaca(rol, e) {
    const archivo = e.target.files?.[0]
    e.target.value = ''
    if (!archivo) return
    const blob = await redimensionar(archivo)
    const previa = datos.placas?.[rol]
    if (previa?.id) olvidarFotoRevision(previa.id)       // se reemplaza: la vieja ya no sirve
    const id = await guardarFotoRevision(orden.id, blob, 'placa')
    escribir({ placas: { ...(datos.placas || {}), [rol]: { id, ruta: null } } })
  }

  const faltas = loQueFalta(datos, formato, ctx)
  const avisos = avisosMediciones(datos, ctx)
  const sugerido = dictamenSugerido(datos, formato)
  const placas = (esSolar ? PLACAS_SOLAR : PLACAS_GENERADOR).filter(p => aplica(p, ctx))
  const placasFaltan = placas.filter(p => !datos.placas?.[p.rol] && !placaGuardada(eq, p.rol)?.foto).length

  return (
    <section className="tarjeta">
      <h3>{esSolar ? 'Mantenimiento solar' : 'Revisión del generador'}</h3>
      <p className="ayuda">
        Se guarda solo en tu celular en cada toque y sube cuando haya señal.
      </p>

      {!esSolar && (
        <>
          <p className="ayuda">Tipo de servicio</p>
          <div style={{ display: 'grid', gap: 8, marginBottom: 12 }}>
            {TIPOS_SERVICIO_GEN.map(([k, t, d]) => (
              <button key={k} type="button" disabled={!puedeEditar}
                className={llegada.tipo_servicio === k ? 'btn-primario' : undefined}
                aria-pressed={llegada.tipo_servicio === k}
                onClick={() => cambiarLlegada({ tipo_servicio: k })}>
                <strong>{t}</strong>
                <span className="ayuda" style={{ display: 'block' }}>{d}</span>
              </button>
            ))}
          </div>
          <label className="campo">
            <span>Combustible</span>
            <select value={combustible} disabled={!puedeEditar}
              onChange={e => cambiarLlegada({ combustible: e.target.value })}>
              <option value="">— Elige —</option>
              {COMBUSTIBLES_GEN.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
            </select>
          </label>
          {!combustible && (
            <Alerta tipo="aviso" palabra="Falta">
              Dinos de qué es la planta: cambian los puntos a revisar. Un diésel lleva trampa
              de agua y dos filtros; una de gas, prueba de fugas y bujías.
            </Alerta>
          )}
        </>
      )}

      {esSolar && (
      <div className="rejilla-2">
        <label className="campo">
          <span>Clima</span>
          <select value={llegada.clima || ''} disabled={!puedeEditar}
            onChange={e => cambiarLlegada({ clima: e.target.value })}>
            <option value="">— Elige —</option>
            {CLIMAS.map(([v, t]) => <option key={v} value={v}>{t}</option>)}
          </select>
        </label>
        <label className="campo">
          <span>Irradiancia (W/m²)</span>
          <input type="number" inputMode="decimal" value={llegada.irradiancia || ''} disabled={!puedeEditar}
            onChange={e => cambiarLlegada({ irradiancia: e.target.value })} />
        </label>
        <label className="campo">
          <span>Temperatura ambiente (°C)</span>
          <input type="number" inputMode="decimal" value={llegada.temp || ''} disabled={!puedeEditar}
            onChange={e => cambiarLlegada({ temp: e.target.value })} />
        </label>
      </div>
      )}
      {esSolar && llegada.irradiancia !== undefined && llegada.irradiancia !== '' && Number(llegada.irradiancia) < 600 && (
        <Alerta tipo="aviso" palabra="Ojo">
          Con menos de 600 W/m² la termografía no es concluyente. Márcala como "No aplica" y
          anota por qué, o espera a que suba la radiación.
        </Alerta>
      )}

      {esSolar && (
        <label className="casilla">
          <input type="checkbox" checked={bess} disabled={!puedeEditar}
            onChange={e => cambiarLlegada({ bess: e.target.checked })} />
          El sistema tiene banco de baterías
        </label>
      )}
      {esSolar && bess && (
        <label className="casilla">
          <input type="checkbox" checked={plomo} disabled={!puedeEditar}
            onChange={e => cambiarLlegada({ plomo: e.target.checked })} />
          Son de plomo inundado (llevan revisión de electrolito)
        </label>
      )}

      {secciones.map(s => {
        const a = avanceSeccion(datos, s)
        const esta = abierta === s.clave
        return (
          <div key={s.clave} style={{ marginTop: 10 }}>
            <button type="button" className="orden-item" aria-expanded={esta}
              onClick={() => setAbierta(esta ? null : s.clave)}>
              <span className="fila" style={{ justifyContent: 'space-between', width: '100%' }}>
                <strong>{s.clave}. {s.titulo}</strong>
                <span className={`etiqueta${a.completa ? '' : ' etiqueta-aviso'}`}>
                  {a.hechos} de {a.total}
                </span>
              </span>
              {s.ayuda && <span className="ayuda">{s.ayuda}</span>}
            </button>
            {esta && s.puntos.map(p => (
              <PuntoRevision key={p.clave} punto={p} valor={datos.puntos?.[p.clave]}
                puedeEditar={puedeEditar} onCambio={val => cambiarPunto(p.clave, val)}
                onFoto={e => agregarFotosPunto(p.clave, e)} />
            ))}
          </div>
        )
      })}

      <div style={{ marginTop: 10 }}>
        <button type="button" className="orden-item" aria-expanded={abierta === 'placas'}
          onClick={() => setAbierta(abierta === 'placas' ? null : 'placas')}>
          <span className="fila" style={{ justifyContent: 'space-between', width: '100%' }}>
            <strong>Placas de identificación</strong>
            <span className={`etiqueta${placasFaltan > 0 ? ' etiqueta-aviso' : ''}`}>
              {placasFaltan > 0 ? `Faltan ${placasFaltan}` : 'Completas'}
            </span>
          </span>
          <span className="ayuda">Se toman una vez y se quedan en el equipo.</span>
        </button>
        {abierta === 'placas' && (
          <>
            {!orden.equipo_id && (
              <Alerta tipo="aviso" palabra="Falta">
                Primero di de qué equipo es la orden, arriba: las placas se guardan en el equipo.
              </Alerta>
            )}
            {placas.map(p => {
              const local = datos.placas?.[p.rol]
              const yaEstaba = placaGuardada(eq, p.rol)
              const lista = !!local || !!yaEstaba?.foto
              return (
                <div key={p.rol} className="refaccion">
                  <span className="fila" style={{ justifyContent: 'space-between' }}>
                    <strong>{p.titulo}</strong>
                    {lista && <span className="etiqueta">{local && !local.ruta ? 'Por subir' : 'Guardada'}</span>}
                  </span>
                  {yaEstaba && (
                    <span className="ayuda">
                      {[yaEstaba.marca, yaEstaba.modelo].filter(Boolean).join(' ')}
                      {yaEstaba.serie && ` · Serie ${yaEstaba.serie}`}
                    </span>
                  )}
                  {puedeEditar && orden.equipo_id && (
                    <label className="btn boton-archivo">
                      {lista ? 'Cambiar la foto' : '＋ Foto de la placa'}
                      <input type="file" accept="image/*" capture="environment"
                        className="oculto-accesible" onChange={e => agregarPlaca(p.rol, e)} />
                    </label>
                  )}
                </div>
              )
            })}
            <p className="ayuda">
              Con la foto basta: en la oficina se leen marca, modelo y serie. Si no hay placa
              legible, sáltala y captúralos a mano en el equipo.
            </p>
          </>
        )}
      </div>

      <div style={{ marginTop: 10 }}>
        <button type="button" className="orden-item" aria-expanded={abierta === 'med'}
          onClick={() => setAbierta(abierta === 'med' ? null : 'med')}>
          <span className="fila" style={{ justifyContent: 'space-between', width: '100%' }}>
            <strong>Mediciones</strong>
            <span className="etiqueta">{esSolar ? 'Strings, AC y banco' : 'Prueba de funcionamiento'}</span>
          </span>
        </button>
        {abierta === 'med' && (
          <>
            <label className="casilla">
              <input type="checkbox" checked={trifasico} disabled={!puedeEditar}
                onChange={e => cambiarLlegada({ trifasico: e.target.checked })} />
              El equipo es trifásico
            </label>
            {esSolar
              ? <MedicionesSolar med={datos.mediciones || {}} ctx={ctx} puedeEditar={puedeEditar}
                  onCambio={m => escribir({ mediciones: m })} />
              : <MedicionesGenerador med={datos.mediciones || {}} ctx={ctx} puedeEditar={puedeEditar}
                  onCambio={m => escribir({ mediciones: m })} />}
          </>
        )}
      </div>

      {avisos.length > 0 && (
        <Alerta tipo="aviso" palabra="Revisa">
          <ul style={{ margin: '4px 0', paddingLeft: 20 }}>
            {avisos.map((a, i) => <li key={i}>{a}</li>)}
          </ul>
        </Alerta>
      )}

      <h4 style={{ marginTop: 16 }}>Dictamen del servicio</h4>
      <p className="ayuda">
        Por lo que llevas capturado, correspondería: <strong>{
          DICTAMENES.find(([k]) => k === sugerido)?.[1]
        }</strong>. Tú decides.
      </p>
      <div style={{ display: 'grid', gap: 8 }}>
        {DICTAMENES.map(([k, t, d]) => (
          <button key={k} type="button" disabled={!puedeEditar}
            className={datos.dictamen === k ? 'btn-primario' : undefined}
            aria-pressed={datos.dictamen === k}
            onClick={() => escribir({ dictamen: k })}>
            <strong>{t}</strong>
            <span className="ayuda" style={{ display: 'block' }}>{d}</span>
          </button>
        ))}
      </div>
      {datos.dictamen === 'no_aprobado' && (
        <label className="campo">
          <span>Por qué no se aprueba</span>
          <textarea rows={3} value={datos.motivo_dictamen || ''} disabled={!puedeEditar}
            onChange={e => escribir({ motivo_dictamen: e.target.value })} />
        </label>
      )}

      <label className="casilla">
        <input type="checkbox" checked={!!datos.reporte_termico} disabled={!puedeEditar}
          onChange={e => escribir({ reporte_termico: e.target.checked })} />
        Se entrega reporte térmico
      </label>

      {puedeEditar && faltas.length > 0 && (
        <Alerta tipo="aviso" palabra="Falta">
          <ul style={{ margin: '4px 0', paddingLeft: 20 }}>
            {faltas.map((f, i) => <li key={i}>{f}</li>)}
          </ul>
        </Alerta>
      )}
      {puedeEditar && faltas.length === 0 && (
        <Alerta tipo="ok" palabra="Completo">El formato está lleno.</Alerta>
      )}
    </section>
  )
}

function SolicitarMaterial({ ordenId, tecnicoId }) {
  const [solicitudes, setSolicitudes] = useState(null)   // null = aún no carga
  const [piezas, setPiezas] = useState([])
  const [piezasCargadas, setPiezasCargadas] = useState(false)
  const [buscar, setBuscar] = useState('')
  const [elegida, setElegida] = useState(null)
  const [libre, setLibre] = useState(false)
  const [descripcion, setDescripcion] = useState('')
  const [cantidad, setCantidad] = useState('1')
  const [nota, setNota] = useState('')
  const [enviando, setEnviando] = useState(false)
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState('')

  async function cargar() {
    const r = await cargarSolicitudesDeOrden(ordenId)
    if (r.ok) setSolicitudes(r.solicitudes)
  }
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    cargar()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ordenId])

  async function abrirBuscador() {
    if (piezasCargadas) return
    setPiezasCargadas(true)
    const r = await cargarExistencias()
    if (r.ok) setPiezas(r.piezas)
    else setPiezasCargadas(false)
  }

  function limpiar() {
    setElegida(null); setBuscar(''); setLibre(false); setDescripcion(''); setCantidad('1'); setNota('')
  }

  async function enviar() {
    setError(''); setMensaje('')
    const problema = problemaDeSolicitud({ productoId: elegida?.id, descripcion, cantidad })
    if (problema) return setError(problema)
    setEnviando(true)
    const r = await crearSolicitud({
      ordenId, tecnicoId, productoId: elegida?.id, descripcion, cantidad, nota
    })
    setEnviando(false)
    if (!r.ok) return setError(r.texto)
    setMensaje('Pedido registrado. Lo revisa el almacén.')
    limpiar()
    cargar()
  }

  async function cancelar(s) {
    if (!confirm('¿Cancelar este pedido?')) return
    const r = await cancelarSolicitud(s.id)
    if (!r.ok) return setError(r.texto)
    cargar()
  }

  const encontrados = !libre && buscar.trim().length >= 2
    ? piezas.filter(p => `${p.sku} ${p.nombre}`.toLowerCase().includes(buscar.trim().toLowerCase())).slice(0, 8)
    : []

  return (
    <section className="tarjeta">
      <h3>Pedir material</h3>
      <p className="ayuda">
        Si te falta una pieza para esta orden o para la próxima visita, pídela aquí. El almacén la
        revisa; no ves precios ni costos.
      </p>

      {(solicitudes || []).map(s => (
        <div key={s.id} className="linea-surtido">
          <div className="fila" style={{ justifyContent: 'space-between' }}>
            <strong>{s.cantidad} × {nombrePieza(s)}</strong>
            <span className="etiqueta">{etiquetaEstado(s.estado)}</span>
          </div>
          {s.nota && <div className="ayuda">{s.nota}</div>}
          {s.resolucion && <div className="ayuda">{s.resolucion}</div>}
          {s.estado === 'pendiente' && (
            <button type="button" className="btn-peligro" onClick={() => cancelar(s)}>Cancelar pedido</button>
          )}
        </div>
      ))}

      {!libre && (
        <div className="buscador">
          <input placeholder="Buscar pieza por SKU o nombre" aria-label="Buscar pieza por SKU o nombre"
            value={elegida ? `${elegida.sku} — ${elegida.nombre}` : buscar}
            onFocus={abrirBuscador}
            onChange={e => { setElegida(null); setBuscar(e.target.value) }} />
          {!elegida && encontrados.length > 0 && (
            <div className="buscador-lista">
              {encontrados.map(p => (
                <button key={p.id} type="button" onClick={() => setElegida(p)}>
                  <strong>{p.sku}</strong> — {p.nombre}
                </button>
              ))}
            </div>
          )}
        </div>
      )}
      <label className="casilla">
        <input type="checkbox" checked={libre}
          onChange={e => { setLibre(e.target.checked); setElegida(null); setBuscar('') }} />
        No está en el catálogo: la describo
      </label>
      {libre && (
        <label className="campo">
          <span>Descripción</span>
          <input value={descripcion} onChange={e => setDescripcion(e.target.value)}
            placeholder="Ej. banda de repuesto para el generador" />
        </label>
      )}

      <label className="fila">Cantidad
        <input type="number" inputMode="numeric" min="1" step="1" style={{ width: 96 }}
          value={cantidad} onChange={e => setCantidad(e.target.value)} />
      </label>
      <label className="campo">
        <span>Nota (opcional)</span>
        <input value={nota} onChange={e => setNota(e.target.value)} placeholder="Ej. para la próxima visita" />
      </label>

      {error && <Alerta tipo="error">{error}</Alerta>}
      {mensaje && <Alerta tipo="ok" palabra="Listo">{mensaje}</Alerta>}
      <button type="button" className="btn-primario" onClick={enviar} disabled={enviando}>
        {enviando ? 'Enviando…' : 'Pedir esta pieza'}
      </button>
    </section>
  )
}

// ---------------------------------------------------------------------------
// PDF de la orden ya cerrada, y su envío (fase 4). Solo admin. El PDF se arma en este mismo
// celular/computadora (jsPDF); "Enviar al cliente" registra a quién y cuándo, guarda una copia
// fechada, y descarga el archivo para que el admin lo comparta a mano (todavía sin la API de
// WhatsApp: ver CLAUDE.md).
// ---------------------------------------------------------------------------
function DocumentoOrden({ orden, nombreT1, nombreT2 }) {
  const [pdfs, setPdfs] = useState(null)             // { cliente: {...}, interno: {...} }
  const [envios, setEnvios] = useState(null)
  const [destinatarios, setDestinatarios] = useState(null)   // null = aún no se abrió
  const [elegidos, setElegidos] = useState({})
  const [ocupado, setOcupado] = useState('')         // '' | 'cliente' | 'interno' | 'enviar'
  const [error, setError] = useState('')
  const [mensaje, setMensaje] = useState('')

  async function cargar() {
    const [p, e] = await Promise.all([cargarPdfDeOrden(orden.id), cargarEnviosDeOrden(orden.id)])
    if (p.ok) setPdfs(Object.fromEntries(p.pdfs.map(x => [x.tipo, x])))
    if (e.ok) setEnvios(e.envios)
  }
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    cargar()
    // Si se marcó "enviar al cerrar", el panel ya nace abierto (más abajo): se cargan los
    // destinatarios de una vez, sin esperar un toque que el admin no tiene por qué dar.
    if (orden.enviar_al_cerrar) abrirDestinatarios()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [orden.id])

  async function abrirDestinatarios() {
    if (destinatarios) return
    const r = await cargarDestinatariosOrden(orden)
    if (!r.ok) return setError(r.texto)
    setDestinatarios(r.contactos)
    setElegidos(Object.fromEntries(r.contactos.map(c => [c.contacto_id, true])))   // todos ya cumplen "recibe órdenes"
  }

  async function generar(tipo) {
    setError(''); setMensaje(''); setOcupado(tipo)
    const blob = await construirPdfOrden(orden, nombreT1, nombreT2, tipo)
    const r = await guardarPdfExpediente(orden, tipo, blob)
    setOcupado('')
    if (!r.ok) return setError(r.texto)
    setMensaje(`Copia ${tipo === 'interno' ? 'interna' : 'del cliente'} generada.`)
    cargar()
  }

  async function verPdf(tipo) {
    const info = pdfs?.[tipo]
    if (!info) return
    setError('')
    const r = await urlDePdf(info.ruta)
    if (!r.ok) return setError(r.texto)
    window.open(r.url, '_blank', 'noopener')
  }

  async function enviar() {
    setError(''); setMensaje('')
    const lista = (destinatarios || []).filter(c => elegidos[c.contacto_id])
    if (lista.length === 0) return setError('Elige al menos un destinatario.')
    setOcupado('enviar')
    const blob = await construirPdfOrden(orden, nombreT1, nombreT2, 'cliente')
    await guardarPdfExpediente(orden, 'cliente', blob)          // deja también actualizado el expediente
    const r = await registrarEnvio(orden, blob, lista)
    if (!r.ok) { setOcupado(''); return setError(r.texto) }
    const u = await urlDePdf(r.ruta)
    setOcupado('')
    setMensaje('Envío registrado. Se abrió el PDF: descárgalo y adjúntalo en el chat de WhatsApp de cada destinatario.')
    if (u.ok) window.open(u.url, '_blank', 'noopener')
    cargar()
  }

  const mensajeWhatsApp = `Hola, le comparto la orden de servicio OS-${orden.folio} de PowerMx.`

  return (
    <section className="tarjeta">
      <h3>Documento de la orden</h3>
      <p className="ayuda">
        Genera el PDF para el expediente. Cuando quieras mandárselo al cliente, regístralo aquí:
        se guarda una copia fechada y tú lo compartes (todavía no hay envío automático).
      </p>

      {orden.enviar_al_cerrar && (
        <Alerta tipo="aviso" palabra="Marcada para enviar">
          Se marcó para mandarla al cliente en cuanto se cerrara. Ya está cerrada: complétalo abajo.
        </Alerta>
      )}

      {error && <Alerta tipo="error">{error}</Alerta>}
      {mensaje && <Alerta tipo="ok" palabra="Listo">{mensaje}</Alerta>}

      <div className="fila">
        <button type="button" onClick={() => generar('cliente')} disabled={!!ocupado}>
          {ocupado === 'cliente' ? 'Generando…' : pdfs?.cliente ? 'Regenerar copia del cliente' : 'Generar copia del cliente'}
        </button>
        {pdfs?.cliente && <button type="button" onClick={() => verPdf('cliente')}>Ver</button>}
      </div>
      <div className="fila" style={{ marginTop: 8 }}>
        <button type="button" onClick={() => generar('interno')} disabled={!!ocupado}>
          {ocupado === 'interno' ? 'Generando…' : pdfs?.interno ? 'Regenerar copia interna' : 'Generar copia interna'}
        </button>
        {pdfs?.interno && <button type="button" onClick={() => verPdf('interno')}>Ver</button>}
      </div>

      <details style={{ marginTop: 12 }} open={!!orden.enviar_al_cerrar}
        onToggle={e => { if (e.currentTarget.open) abrirDestinatarios() }}>
        <summary className="resumen">Enviar al cliente</summary>
        {destinatarios === null && <p className="ayuda">Cargando destinatarios…</p>}
        {destinatarios && destinatarios.length === 0 && (
          <Alerta tipo="aviso" palabra="Sin destinatarios">
            Nadie en Contactos tiene "Recibe órdenes" para este equipo. Agrégalo en Contactos.
          </Alerta>
        )}
        {(destinatarios || []).map(c => {
          const enlace = enlaceWhatsApp(c.telefono, mensajeWhatsApp)
          return (
            <div key={c.contacto_id} className="fila" style={{ justifyContent: 'space-between' }}>
              <label className="casilla">
                <input type="checkbox" checked={!!elegidos[c.contacto_id]}
                  onChange={e => setElegidos({ ...elegidos, [c.contacto_id]: e.target.checked })} />
                {c.nombre}{c.telefono ? ` · ${c.telefono}` : ' · sin teléfono'}
              </label>
              {enlace && <a className="btn" href={enlace} target="_blank" rel="noreferrer">Abrir WhatsApp</a>}
            </div>
          )
        })}
        {destinatarios && destinatarios.length > 0 && (
          <button type="button" className="btn-primario" onClick={enviar} disabled={!!ocupado} style={{ marginTop: 8 }}>
            {ocupado === 'enviar' ? 'Enviando…' : 'Registrar envío y descargar PDF'}
          </button>
        )}
      </details>

      {envios && envios.length > 0 && (
        <>
          <h4 style={{ marginTop: 12 }}>Envíos anteriores</h4>
          {envios.map(e => (
            <p key={e.id} className="ayuda">
              {new Date(e.enviado_en).toLocaleString('es-MX', { dateStyle: 'short', timeStyle: 'short' })}
              {' · '}{(e.destinatarios || []).map(d => d.nombre).join(', ') || 'sin destinatarios'}
            </p>
          ))}
        </>
      )}
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
  const [errorEnvio, setErrorEnvio] = useState('')
  const refLienzo = useRef(null)
  const temporizador = useRef(null)

  async function cambiarEnviarAlCerrar(valor) {
    setErrorEnvio('')
    const r = await marcarEnviarAlCerrar(orden.id, valor)
    if (!r.ok) return setErrorEnvio(r.texto)
    onRefrescar()
  }

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
        {esAdmin && enLinea && (
          <label className="casilla" style={{ marginTop: 6 }}>
            <input type="checkbox" checked={!!orden.enviar_al_cerrar}
              onChange={e => cambiarEnviarAlCerrar(e.target.checked)} />
            Enviar al cliente en cuanto se cierre
          </label>
        )}
        {errorEnvio && <Alerta tipo="error">{errorEnvio}</Alerta>}
        <p className="ayuda">
          Responsable: {nombreDe(nombres, orden.tecnico_id)}
          {orden.tecnico2_id && <> · Ayudante: {nombreDe(nombres, orden.tecnico2_id)}</>}
        </p>
      </section>

      <EquipoOrden orden={orden} enLinea={enLinea} onRefrescar={onRefrescar}
        puedeEditar={abierta && (soyT1 || soyT2)} />

      <RevisionOrden orden={orden} puedeEditar={puedoEditar} />

      <MaterialOrden orden={orden} soyT1={soyT1} abierta={abierta} enLinea={enLinea}
        nombreT1={nombreDe(nombres, orden.tecnico_id)} onRefrescar={onRefrescar} />

      {(soyT1 || soyT2) && (enLinea
        ? <SolicitarMaterial ordenId={orden.id} tecnicoId={yo} />
        : <Alerta tipo="aviso" palabra="Sin señal">Para pedir material necesitas conexión.</Alerta>)}

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

      {esAdmin && orden.estado === 'cerrada' && (enLinea
        ? <DocumentoOrden orden={orden} nombreT1={nombreDe(nombres, orden.tecnico_id)}
            nombreT2={orden.tecnico2_id ? nombreDe(nombres, orden.tecnico2_id) : null} />
        : <Alerta tipo="aviso" palabra="Sin señal">Para generar o enviar el PDF necesitas conexión.</Alerta>)}

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
          {esAdmin && o.estado === 'cerrada' && o.enviar_al_cerrar && (
            <span className="etiqueta etiqueta-aviso">Por enviar</span>
          )}
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
