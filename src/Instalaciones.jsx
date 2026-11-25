import { useEffect, useMemo, useState } from 'react'
import { Alerta } from './ui'
import { dejarEncargo } from './lib/encargo'
import {
  BLOQUES, pesos, gruposDe, etiquetaGrupo, estadoInicial, lineasDeBloque, totalesDeLineas,
  partidasDeInstalacion, notasDeInstalacion, cargarMateriales, guardarMaterial, problemasDeMaterial,
} from './lib/instalaciones'

// ---------------------------------------------------------------------------
// Cotizador de instalaciones (SQL 104). Solo admin.
//
// Materiales y mano de obra de una instalación (eléctrica y de gas de un generador, base de
// concreto, transferencia, tanque), con las cantidades sacadas de los metros. Lo que sale son
// partidas LIBRES que se abren en Cotizaciones como cotización nueva: nada se guarda aquí, y
// nada aparta inventario (estos materiales no están en el catálogo).
// La lista de precios vino de ESTRUCTURA.xlsx y se corrige en la pestaña de al lado.
// ---------------------------------------------------------------------------

const UNIDADES = ['pza', 'm', 'servicio', 'lote', 'kg', 'l']

function reglaTexto(m) {
  const partes = []
  if (Number(m.cantidad_fija)) partes.push(`${Number(m.cantidad_fija)} fijo`)
  if (Number(m.por_metro)) {
    partes.push(`${Number(m.por_metro)} por metro${Number(m.metros_incluidos) ? ` después de ${Number(m.metros_incluidos)} m` : ''}`)
  }
  return partes.length ? partes.join(' + ') : 'opcional (0: se pone a mano)'
}

function LineaBloque({ l, onCantidad, onPrecio }) {
  const m = l.material
  const servicio = m.tipo === 'mano_obra'
  return (
    <tr>
      <td>
        <div className="renglon-titulo">{m.nombre}</div>
        {servicio && <div className="ayuda">Servicio · precio ajustable</div>}
      </td>
      <td>
        <input
          type="number" min="0" step="any" inputMode="decimal" style={{ width: 96 }}
          aria-label={`Cantidad de ${m.nombre}`}
          value={l.manual ? l.cantidad : ''}
          placeholder={String(l.sugerida)}
          onChange={e => onCantidad(m.id, e.target.value)}
        />
        <div className="ayuda">{m.unidad}{l.manual ? ' · a mano' : ''}</div>
      </td>
      <td style={{ textAlign: 'right' }}>
        {servicio ? (
          <>
            <input
              type="number" min="0" step="any" inputMode="decimal" style={{ width: 120 }}
              aria-label={`Precio de ${m.nombre}`}
              value={l.precioManual ? l.precio : ''}
              placeholder={String(Number(m.precio))}
              onChange={e => onPrecio(m.id, e.target.value)}
            />
            <div className="ayuda">{l.precioManual ? 'a mano' : 'de lista'}</div>
          </>
        ) : pesos(m.precio)}
      </td>
      <td style={{ textAlign: 'right', fontWeight: 700 }}>{pesos(l.importe)}</td>
    </tr>
  )
}

function BloqueInstalacion({ def, materiales, eb, onCambio }) {
  const grupos = gruposDe(materiales, def.clave)
  const lineas = lineasDeBloque(materiales, def.clave, eb)
  const t = totalesDeLineas(lineas)
  const fijar = cambio => onCambio({ ...eb, ...cambio })

  if (!lineas.length && !Object.keys(grupos).length) return null

  return (
    <section className="tarjeta" aria-label={def.titulo}>
      <label className="fila" style={{ gap: 10, alignItems: 'center', minHeight: 48, cursor: 'pointer' }}>
        <input type="checkbox" checked={eb.activo} onChange={e => fijar({ activo: e.target.checked })} />
        <span className="renglon-titulo" style={{ fontSize: 20 }}>{def.titulo}</span>
        <span className="ayuda" style={{ marginLeft: 'auto' }}>{eb.activo ? pesos(t.total) : 'No incluida'}</span>
      </label>

      {eb.activo && (
        <>
          <div className="rejilla-2" style={{ marginTop: 8 }}>
            {def.metros && (
              <div className="campo">
                <label htmlFor={`metros-${def.clave}`}>Distancia (m)</label>
                <input
                  id={`metros-${def.clave}`} type="number" min="0" step="1" inputMode="numeric"
                  value={eb.metros} onChange={e => fijar({ metros: e.target.value })}
                />
                <span className="ayuda">{def.ayudaMetros}</span>
              </div>
            )}
            {Object.entries(grupos).map(([g, ops]) => (
              <div className="campo" key={g}>
                <label htmlFor={`grupo-${def.clave}-${g}`}>{etiquetaGrupo(g)}</label>
                <select
                  id={`grupo-${def.clave}-${g}`} value={eb.elecciones[g] || ''}
                  onChange={e => fijar({ elecciones: { ...eb.elecciones, [g]: e.target.value } })}
                >
                  {ops.map(o => <option key={o.id} value={o.id}>{o.nombre} · {pesos(o.precio)}/{o.unidad}</option>)}
                </select>
              </div>
            ))}
          </div>

          <p className="ayuda" style={{ margin: '8px 0' }}>
            Lo gris es lo sugerido (la cantidad por los metros, el precio de lista de la mano de obra). Escribe
            otro valor para cambiarlo; bórralo para volver al sugerido.
          </p>
          <div className="tabla-scroll">
            <table>
              <thead>
                <tr><th>Concepto</th><th>Cantidad</th><th style={{ textAlign: 'right' }}>Precio</th><th style={{ textAlign: 'right' }}>Importe</th></tr>
              </thead>
              <tbody>
                {lineas.map(l => (
                  <LineaBloque
                    key={l.material.id} l={l}
                    onCantidad={(id, v) => fijar({ cantidades: { ...eb.cantidades, [id]: v } })}
                    onPrecio={(id, v) => fijar({ precios: { ...eb.precios, [id]: v } })}
                  />
                ))}
              </tbody>
            </table>
          </div>
          <div className="kpis" style={{ marginTop: 8 }}>
            <div className="kpi"><span className="kpi-nombre">Materiales</span><span className="kpi-valor">{pesos(t.materiales)}</span></div>
            <div className="kpi"><span className="kpi-nombre">Mano de obra</span><span className="kpi-valor">{pesos(t.manoObra)}</span></div>
          </div>
        </>
      )}
    </section>
  )
}

function Cotizar({ materiales, irA }) {
  const [estado, setEstado] = useState(() => estadoInicial(materiales))
  const [desglosar, setDesglosar] = useState(false)
  const partidas = useMemo(() => partidasDeInstalacion({ materiales, estado, desglosar }), [materiales, estado, desglosar])
  const subtotal = partidas.reduce((s, p) => s + p.cantidad * p.precio_unitario, 0)

  function crear() {
    dejarEncargo('cotizaciones', {
      origen: 'instalaciones',
      tipo: 'instalacion',
      partidas,
      notas: notasDeInstalacion({ materiales, estado }),
    })
    irA('cotizaciones')
  }

  return (
    <>
      {BLOQUES.map(def => (
        <BloqueInstalacion
          key={def.clave} def={def} materiales={materiales} eb={estado[def.clave]}
          onCambio={eb => setEstado(s => ({ ...s, [def.clave]: eb }))}
        />
      ))}

      <section className="tarjeta" aria-label="Así saldrá en la cotización">
        <h3 style={{ marginTop: 0 }}>Así saldrá en la cotización</h3>
        {!partidas.length ? (
          <p className="ayuda">Marca al menos una instalación para armar la cotización.</p>
        ) : (
          <>
            <label className="fila" style={{ gap: 10, alignItems: 'center', minHeight: 48, cursor: 'pointer' }}>
              <input type="checkbox" checked={desglosar} onChange={e => setDesglosar(e.target.checked)} />
              <span>Desglosar los materiales (una partida por material)</span>
            </label>
            <ol style={{ paddingLeft: 22, display: 'grid', gap: 8 }}>
              {partidas.map((p, i) => (
                <li key={i}>
                  <div>{p.descripcion}</div>
                  <div className="ayuda">{p.cantidad} {p.unidad} × {pesos(p.precio_unitario)} = <strong>{pesos(p.cantidad * p.precio_unitario)}</strong></div>
                </li>
              ))}
            </ol>
            <div className="kpis">
              <div className="kpi"><span className="kpi-nombre">Subtotal sin IVA</span><span className="kpi-valor">{pesos(subtotal)}</span></div>
              <div className="kpi kpi-principal"><span className="kpi-nombre">Total con IVA</span><span className="kpi-valor">{pesos(subtotal * 1.16)}</span></div>
            </div>
            <button type="button" className="btn-primario btn-grande" style={{ marginTop: 12 }} onClick={crear}>
              Crear cotización con estas partidas
            </button>
            <p className="ayuda">Se abre en Cotizaciones como nueva; nada se guarda hasta que la revises.</p>
          </>
        )}
      </section>
    </>
  )
}

const VACIO = { bloque: 'electrica', tipo: 'material', nombre: '', descripcion: '', unidad: 'pza', costo: '', precio: '',
  cantidad_fija: '', por_metro: '', metros_incluidos: '', grupo: '', predeterminado: false, orden: '', activo: true }

const aForm = m => Object.fromEntries(Object.keys(VACIO).map(k => [k, m[k] ?? VACIO[k]]))

function FormMaterial({ inicial, id, onGuardado, onCancelar }) {
  const [form, setForm] = useState(inicial)
  const [error, setError] = useState('')
  const [ocupado, setOcupado] = useState(false)
  const poner = (k, v) => setForm(f => ({ ...f, [k]: v }))
  const campo = (k, etiqueta, props = {}) => (
    <div className="campo">
      <label htmlFor={`mat-${k}`}>{etiqueta}</label>
      <input id={`mat-${k}`} value={form[k] ?? ''} onChange={e => poner(k, e.target.value)} {...props} />
    </div>
  )

  async function guardar(e) {
    e.preventDefault()
    const p = problemasDeMaterial(form)
    if (p.length) return setError(p.join(' '))
    setError(''); setOcupado(true)
    const r = await guardarMaterial(form, id)
    setOcupado(false)
    if (r.error) return setError(r.error)
    onGuardado(id ? `${form.nombre}: guardado.` : `${form.nombre}: agregado.`)
  }

  return (
    <form onSubmit={guardar}>
      <div className="rejilla-2">
        <div className="campo">
          <label htmlFor="mat-bloque">Instalación</label>
          <select id="mat-bloque" value={form.bloque} onChange={e => poner('bloque', e.target.value)}>
            {BLOQUES.map(b => <option key={b.clave} value={b.clave}>{b.titulo}</option>)}
          </select>
        </div>
        <div className="campo">
          <label htmlFor="mat-tipo">Tipo</label>
          <select id="mat-tipo" value={form.tipo} onChange={e => poner('tipo', e.target.value)}>
            <option value="material">Material</option>
            <option value="mano_obra">Mano de obra</option>
          </select>
        </div>
        {campo('nombre', 'Nombre')}
        <div className="campo">
          <label htmlFor="mat-unidad">Unidad</label>
          <select id="mat-unidad" value={form.unidad} onChange={e => poner('unidad', e.target.value)}>
            {[...new Set([...UNIDADES, form.unidad])].map(u => <option key={u} value={u}>{u}</option>)}
          </select>
        </div>
        {campo('precio', 'Precio al cliente, sin IVA', { type: 'number', min: 0, step: 'any', inputMode: 'decimal' })}
        {campo('costo', 'Costo (interno, opcional)', { type: 'number', min: 0, step: 'any', inputMode: 'decimal' })}
        {campo('cantidad_fija', 'Cantidad fija', { type: 'number', min: 0, step: 'any', inputMode: 'decimal' })}
        {campo('por_metro', 'Cantidad por metro', { type: 'number', min: 0, step: 'any', inputMode: 'decimal' })}
        {campo('metros_incluidos', 'Metros que no cuentan', { type: 'number', min: 0, step: 'any', inputMode: 'decimal' })}
        {campo('grupo', 'Grupo de opciones (ej. cable_fuerza)')}
      </div>
      <div className="campo">
        <label htmlFor="mat-descripcion">Texto en la cotización (opcional)</label>
        <textarea id="mat-descripcion" rows={2} value={form.descripcion ?? ''} onChange={e => poner('descripcion', e.target.value)} />
      </div>
      {form.grupo && (
        <label className="fila" style={{ gap: 10, alignItems: 'center', minHeight: 48 }}>
          <input type="checkbox" checked={!!form.predeterminado} onChange={e => poner('predeterminado', e.target.checked)} />
          <span>Es la opción que se elige de inicio en su grupo</span>
        </label>
      )}
      <label className="fila" style={{ gap: 10, alignItems: 'center', minHeight: 48 }}>
        <input type="checkbox" checked={form.activo !== false} onChange={e => poner('activo', e.target.checked)} />
        <span>Se usa (apágalo en vez de borrarlo)</span>
      </label>
      <p className="ayuda">Cantidad = fija + por metro × (metros − metros que no cuentan), hacia arriba.</p>
      {error && <Alerta tipo="error">{error}</Alerta>}
      <div className="fila" style={{ gap: 8 }}>
        <button type="submit" className="btn-primario" disabled={ocupado}>{ocupado ? 'Guardando…' : 'Guardar'}</button>
        <button type="button" onClick={onCancelar}>Cancelar</button>
      </div>
    </form>
  )
}

function ListaMateriales({ materiales, onCambio }) {
  const [editando, setEditando] = useState(null) // id, 'nuevo' o null
  const [mensaje, setMensaje] = useState('')

  function listo(t) { setEditando(null); setMensaje(t); onCambio() }

  return (
    <>
      {mensaje && <Alerta tipo="ok">{mensaje}</Alerta>}
      <details className="tarjeta" open={editando === 'nuevo'} onToggle={e => setEditando(e.currentTarget.open ? 'nuevo' : null)}>
        <summary className="resumen">Agregar material o mano de obra</summary>
        {editando === 'nuevo' && (
          <FormMaterial inicial={VACIO} onGuardado={listo} onCancelar={() => setEditando(null)} />
        )}
      </details>

      {BLOQUES.map(b => {
        const lista = materiales.filter(m => m.bloque === b.clave)
        if (!lista.length) return null
        return (
          <section className="tarjeta" key={b.clave} aria-label={b.titulo}>
            <h3 style={{ marginTop: 0 }}>{b.titulo}</h3>
            <ul style={{ listStyle: 'none', padding: 0, margin: 0, display: 'grid', gap: 10 }}>
              {lista.map(m => (
                <li key={m.id} style={{ borderTop: '1px solid var(--linea)', paddingTop: 10 }}>
                  {editando === m.id ? (
                    <FormMaterial inicial={aForm(m)} id={m.id} onGuardado={listo} onCancelar={() => setEditando(null)} />
                  ) : (
                    <div className="fila" style={{ justifyContent: 'space-between', alignItems: 'center', gap: 8 }}>
                      <div style={{ minWidth: 0 }}>
                        <div className="renglon-titulo">
                          {m.nombre}{m.activo === false && ' · No se usa'}
                        </div>
                        <div className="renglon-datos">
                          {pesos(m.precio)}/{m.unidad}
                          {m.costo != null && ` · costo ${pesos(m.costo)}`}
                          {m.tipo === 'mano_obra' && ' · mano de obra'}
                        </div>
                        <div className="ayuda">
                          {reglaTexto(m)}{m.grupo && ` · opción de ${etiquetaGrupo(m.grupo).toLowerCase()}${m.predeterminado ? ' (de inicio)' : ''}`}
                        </div>
                      </div>
                      <button type="button" onClick={() => { setMensaje(''); setEditando(m.id) }}>Editar</button>
                    </div>
                  )}
                </li>
              ))}
            </ul>
          </section>
        )
      })}
    </>
  )
}

export default function Instalaciones({ irA }) {
  const [materiales, setMateriales] = useState(null)
  const [error, setError] = useState('')
  const [vista, setVista] = useState('cotizar')
  const [version, setVersion] = useState(0)

  useEffect(() => {
    let vivo = true
    cargarMateriales().then(r => {
      if (!vivo) return
      setError(r.error || '')
      setMateriales(r.materiales)
    })
    return () => { vivo = false }
  }, [version])

  let contenido
  if (!materiales) contenido = <p className="ayuda">Cargando la lista de materiales…</p>
  else if (vista === 'lista') contenido = <ListaMateriales materiales={materiales} onCambio={() => setVersion(v => v + 1)} />
  else if (!materiales.length) {
    contenido = !error && <Alerta tipo="aviso">No hay materiales capturados. Agrega el primero en "Materiales y mano de obra".</Alerta>
  } else contenido = <Cotizar key={version} materiales={materiales} irA={irA} />

  return (
    <div className="pagina">
      <h2>Cotizador de instalaciones</h2>
      <div className="pestanas" role="group" aria-label="Vista">
        <button type="button" className="pestana" aria-pressed={vista === 'cotizar'} onClick={() => setVista('cotizar')}>Cotizar</button>
        <button type="button" className="pestana" aria-pressed={vista === 'lista'} onClick={() => setVista('lista')}>Materiales y mano de obra</button>
      </div>
      {error && <Alerta tipo="error">{error}</Alerta>}
      {contenido}
    </div>
  )
}
