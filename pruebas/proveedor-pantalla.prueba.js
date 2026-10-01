// Reglas puras de la pantalla Proveedor (SQL 44): orden de la cola, textos, validación de las
// reglas de margen y el saneo de la búsqueda. El precio NO se calcula aquí (lo calcula la base).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  ordenarCola, contarPorTipo, detalleDeCambio, esAprobable, explicacion, alcanceDeRegla, textoDeRegla,
  ordenarReglas, validarRegla, reglaVacia, reglaInicial, MARGEN_INICIAL_PCT, estadoDeVinculo, patronDeBusqueda, totalPorTraer, nombreCategoriaCRM, faltanConPrecioAuto,
  textoDeMargen, proveedoresDe, proveedoresLibres, ultimaPorProveedor, nombreProveedor, valorDeParametro,
  descuentoDe, ordenarPromociones, esParametroDePromocion, DIAS_LISTA_VIEJA,
  textoDeCorrida, pesos,
} from '../src/lib/proveedor.js'

const q = (tipo, nombre, extra = {}) => ({ id: nombre, tipo, detalle: { nombre, ...extra } })

test('la cola pone primero lo que más urge: desaparecidos, saltos de precio, primeros precios', () => {
  const lista = [q('sin_costo', 'E'), q('precio_inicial', 'B'), q('cambio_precio', 'C'),
    q('sku_desaparecido', 'D'), q('precio_inicial', 'A'), q('sin_regla', 'F')]
  assert.deepEqual(ordenarCola(lista).map(x => x.id), ['D', 'C', 'A', 'B', 'F', 'E'])
  assert.deepEqual(ordenarCola(null), [])
})

test('contarPorTipo', () => {
  assert.deepEqual(contarPorTipo([q('precio_inicial', 'a'), q('precio_inicial', 'b'), q('sin_regla', 'c')]),
    { precio_inicial: 2, sin_regla: 1 })
})

test('solo se aprueba lo que tiene qué aprobar', () => {
  assert.equal(esAprobable('cambio_precio'), true)
  assert.equal(esAprobable('precio_inicial'), true)
  assert.equal(esAprobable('sku_desaparecido'), true)
  assert.equal(esAprobable('sin_regla'), false)
  assert.equal(esAprobable('sin_costo'), false)
  assert.match(explicacion('sin_regla'), /regla de margen/)
})

test('un cambio de precio dice si sube o baja con palabra, no solo con signo', () => {
  const sube = detalleDeCambio(q('cambio_precio', 'X', { precio_actual: 1000, precio: 1300, variacion_pct: 30, costo_mxn: 900, margen_pct: 30 }))
  assert.deepEqual(sube.find(f => f.etiqueta === 'Variación'), { etiqueta: 'Variación', valor: 'Sube 30 %' })
  assert.equal(sube.find(f => f.etiqueta === 'Precio nuevo').valor, pesos(1300))
  const baja = detalleDeCambio(q('cambio_precio', 'X', { precio_actual: 1000, precio: 700, variacion_pct: 30 }))
  assert.equal(baja.find(f => f.etiqueta === 'Variación').valor, 'Baja 30 %')
})

test('un primer precio dice "Sin precio" y toma el precio actual del producto si el detalle no lo trae', () => {
  const f = detalleDeCambio({ tipo: 'precio_inicial', detalle: { precio: 2160 }, productos: { precio: null } })
  assert.equal(f.find(x => x.etiqueta === 'Precio ahora').valor, 'Sin precio')
  const g = detalleDeCambio({ tipo: 'cambio_precio', detalle: { precio: 500 }, productos: { precio: 400 } })
  assert.equal(g.find(x => x.etiqueta === 'Precio ahora').valor, pesos(400))
})

test('las reglas se describen por su alcance y se ordenan de la más específica a la general', () => {
  const general = { id: 1, categoria: null, marca: null, margen_pct: 30, margen_minimo_mxn: 100, redondeo: 10, activo: true }
  const marca = { id: 2, categoria: null, marca: 'JA SOLAR', margen_pct: 20, margen_minimo_mxn: 0, redondeo: 1, activo: true }
  const ambas = { id: 3, categoria: 'panel', marca: 'JA SOLAR', margen_pct: 15, margen_minimo_mxn: 0, redondeo: 1, activo: true }
  const apagada = { id: 4, categoria: 'panel', marca: null, margen_pct: 25, margen_minimo_mxn: 0, redondeo: 1, activo: false }
  assert.equal(alcanceDeRegla(general), 'Todos los productos (regla general)')
  assert.equal(alcanceDeRegla(marca), 'Todo lo de JA SOLAR')
  assert.equal(alcanceDeRegla(ambas), 'Paneles de JA SOLAR')
  assert.deepEqual(ordenarReglas([general, apagada, marca, ambas]).map(r => r.id), [3, 2, 1, 4])
  assert.match(textoDeRegla(general), /30 % sobre el costo · mínimo .*100.* · redondeo hacia arriba a .*10/)
  assert.match(textoDeRegla({ ...general, sobre: 'precio' }), /^30 % del precio de venta \(= 42\.9 % sobre el costo\) · mínimo/)
  assert.doesNotMatch(textoDeRegla(marca), /mínimo/)
})

test('validarRegla: lo vacío va como null y lo absurdo se rechaza', () => {
  const ok = validarRegla({ ...reglaVacia, categoria: 'panel', marca: '  ', margen_pct: '30', margen_minimo_mxn: '', redondeo: '10' })
  // Por omisión el margen es sobre el costo (Caña, 01/10/2026).
  assert.deepEqual(ok, { ok: true, regla: { categoria: 'panel', marca: null, margen_pct: 30, margen_minimo_mxn: 0, redondeo: 10, sobre: 'costo' } })
  assert.equal(validarRegla({ ...reglaVacia, margen_pct: '30', sobre: 'precio' }).regla.sobre, 'precio')
  // 100 % del precio de venta sería dividir entre cero; sobre el costo sí se vale.
  assert.equal(validarRegla({ ...reglaVacia, margen_pct: '100', sobre: 'precio' }).ok, false)
  assert.equal(validarRegla({ ...reglaVacia, margen_pct: '100', sobre: 'costo' }).ok, true)
  assert.equal(validarRegla({ ...reglaVacia, margen_pct: '' }).ok, false)
  assert.equal(validarRegla({ ...reglaVacia, margen_pct: '-5' }).ok, false)
  assert.equal(validarRegla({ ...reglaVacia, margen_pct: '10', redondeo: '0' }).ok, false)
  assert.equal(validarRegla({ ...reglaVacia, margen_pct: '10', margen_minimo_mxn: '-1' }).ok, false)
  assert.equal(validarRegla({ ...reglaVacia, margen_pct: '0', redondeo: '1' }).ok, true)
})

test('el estado del vínculo se dice en palabras', () => {
  assert.equal(estadoDeVinculo({ proveedor_sku: null }), 'sin_vincular')
  assert.equal(estadoDeVinculo({ proveedor_sku: 'X', precio_auto: false }), 'vinculado')
  assert.equal(estadoDeVinculo({ proveedor_sku: 'X', precio_auto: true }), 'automatico')
})

test('la búsqueda quita lo que rompería el filtro de PostgREST', () => {
  assert.equal(patronDeBusqueda('  JA-M66,(D45)%  *x '), 'JA-M66 D45 x')
  assert.equal(patronDeBusqueda(null), '')
})

test('totalPorTraer suma solo lo marcado y solo lo que tiene categoría equivalente en el CRM', () => {
  const resumen = [
    { categoria: 'Paneles solares', total: 23, por_traer: 23, equivale: true },
    { categoria: 'Inversores', total: 87, por_traer: 80, equivale: true },
    { categoria: 'Kits', total: 18, por_traer: 0, equivale: true },
    { categoria: 'Servicios', total: 5, por_traer: 5, equivale: false },
  ]
  assert.equal(totalPorTraer(resumen, ['Paneles solares', 'Inversores']), 103)
  assert.equal(totalPorTraer(resumen, ['Paneles solares', 'Servicios']), 23)   // Servicios no equivale: no cuenta
  assert.equal(totalPorTraer(resumen, []), 0)
  assert.equal(totalPorTraer(null, ['Kits']), 0)
})

test('las categorías nuevas del CRM tienen nombre y lo desconocido se muestra tal cual', () => {
  assert.equal(nombreCategoriaCRM('inversor'), 'Inversores')
  assert.equal(nombreCategoriaCRM('accesorio_solar'), 'Accesorios solares')
  assert.equal(nombreCategoriaCRM('otra_cosa'), 'otra_cosa')
})

test('faltanConPrecioAuto: cuántos vinculados no siguen aún el precio del proveedor', () => {
  assert.equal(faltanConPrecioAuto({ total: 23, con_auto: 3 }), 20)
  assert.equal(faltanConPrecioAuto({ total: 5, con_auto: 5 }), 0)
  assert.equal(faltanConPrecioAuto({ total: 5, con_auto: 9 }), 0)   // nunca negativo
  assert.equal(faltanConPrecioAuto(null), 0)
})

test('textoDeCorrida: una lectura fallida se dice fuerte, con su motivo', () => {
  const base = { iniciada_en: '2026-09-29T18:00:00Z' }
  assert.equal(textoDeCorrida(null), null)
  const ok = textoDeCorrida({ ...base, estado: 'aplicada', filas: 908, resumen: { aplicados: 4, en_revision: 2 } })
  assert.equal(ok.tipo, 'ok')
  assert.match(ok.texto, /908 productos; 4 precios aplicados, 2 esperando/)
  const mal = textoDeCorrida({ ...base, estado: 'fallida', error: 'Lectura sospechosa' })
  assert.equal(mal.tipo, 'error')
  assert.match(mal.texto, /no se aplicó nada: Lectura sospechosa/)
  assert.equal(textoDeCorrida({ ...base, estado: 'leida' }).tipo, 'aviso')
})

test('la regla inicial es el 30 % sobre el costo (Caña, 01/10/2026): sin mínimo, al peso, y pasa la validación', () => {
  assert.equal(MARGEN_INICIAL_PCT, 30)
  const v = validarRegla(reglaInicial)
  assert.deepEqual(v, { ok: true, regla: { categoria: null, marca: null, margen_pct: 30, margen_minimo_mxn: 0, redondeo: 1, sobre: 'costo' } })
  assert.equal(alcanceDeRegla(v.regla), 'Todos los productos (regla general)')
  assert.match(textoDeRegla(v.regla), /^30 % sobre el costo · redondeo hacia arriba a /)
})

test('promociones: el descuento en % entero, y el más grande primero', () => {
  assert.equal(descuentoDe(9133, 7097), 22)
  assert.equal(descuentoDe(2600, 1960), 25)
  assert.equal(descuentoDe(2600, 2600), null)   // no baja: no es promoción
  assert.equal(descuentoDe(2600, null), null)
  assert.equal(descuentoDe(0, 100), null)
  const lista = ordenarPromociones([
    { nombre: 'B', precio: 263, precio_promocion: 208 },
    { nombre: 'A', precio: 9133, precio_promocion: 7097 },
    { nombre: 'C', precio: 1000, precio_promocion: 700 },
  ])
  assert.deepEqual(lista.map(p => p.nombre), ['C', 'A', 'B'])
  assert.equal(esParametroDePromocion({ clave: 'promo_margen_pct' }), true)
  assert.equal(esParametroDePromocion({ clave: 'mano_obra_panel' }), false)
})

test('una lista de proveedor con más de 150 días se avisa (Solarama manda la suya cada ~5 meses)', () => {
  const c = { proveedor: 'solarama', estado: 'aplicada', iniciada_en: '2026-05-01T12:00:00Z', filas: 429, resumen: {} }
  const vieja = textoDeCorrida(c, new Date('2026-10-01T12:00:00Z'))
  assert.equal(vieja.tipo, 'aviso')
  assert.match(vieja.texto, /ya tiene 153 días: pide la nueva/)
  assert.equal(textoDeCorrida(c, new Date('2026-06-01T12:00:00Z')).tipo, 'ok')
  assert.equal(DIAS_LISTA_VIEJA, 150)
})

test('textoDeMargen: el equivalente sobre el costo se dice, porque es fácil confundirlos', () => {
  assert.equal(textoDeMargen(30, 'precio'), '30 % del precio de venta (= 42.9 % sobre el costo)')
  assert.equal(textoDeMargen(35, 'costo'), '35 % sobre el costo')
  assert.equal(textoDeMargen(35, undefined), '35 % sobre el costo')   // reglas de antes de la 51
  assert.equal(textoDeMargen(null, 'precio'), '—')
})

test('un repetido en dos proveedores: el detalle dice de quién es el costo y con quién se calculó el precio', () => {
  const filas = detalleDeCambio({ tipo: 'cambio_precio', detalle: {
    precio: 11341, precio_actual: 10716, costo_mxn: 7825.5, costo_alto_mxn: 7938.17, proveedor: 'solarama',
    proveedor_precio: 'xlstore', margen_pct: 30, margen_sobre: 'precio', variacion_pct: 5.8 } })
  const valor = etiqueta => filas.find(x => x.etiqueta === etiqueta)?.valor
  assert.match(valor('Costo (opción 1, el más barato)'), /7,825\.50 · Solarama/)
  assert.match(valor('Precio calculado con'), /7,938\.17 · XLStore/)
  assert.equal(valor('Margen de la regla'), '30 % del precio de venta (= 42.9 % sobre el costo)')
  // Con un solo proveedor no hay renglón de "precio calculado con".
  const uno = detalleDeCambio({ tipo: 'precio_inicial', detalle: { precio: 100, costo_mxn: 70, proveedor: 'xlstore', proveedor_precio: 'xlstore' } })
  assert.equal(uno.some(x => x.etiqueta === 'Precio calculado con'), false)
})

test('proveedores de un producto: la opción 1 primero; lo recién ligado al final', () => {
  const p = { producto_proveedores: [
    { proveedor: 'xlstore', opcion: 2 }, { proveedor: 'nuevo', opcion: null }, { proveedor: 'solarama', opcion: 1 }] }
  assert.deepEqual(proveedoresDe(p).map(l => l.proveedor), ['solarama', 'xlstore', 'nuevo'])
  assert.deepEqual(proveedoresLibres({ producto_proveedores: [{ proveedor: 'xlstore' }] }), ['solarama'])
  assert.deepEqual(proveedoresLibres({}), ['xlstore', 'solarama'])
  assert.equal(estadoDeVinculo({ proveedor_sku: null, producto_proveedores: [{ proveedor: 'solarama' }] }), 'vinculado')
  assert.equal(nombreProveedor('solarama'), 'Solarama')
  assert.equal(nombreProveedor('otro'), 'otro')
})

test('ultimaPorProveedor: la lectura más reciente de cada uno, XLStore primero', () => {
  const lista = [
    { id: 1, proveedor: 'solarama', iniciada_en: '2026-10-01T10:00:00Z' },
    { id: 2, proveedor: 'xlstore', iniciada_en: '2026-09-30T10:00:00Z' },
    { id: 3, proveedor: 'xlstore', iniciada_en: '2026-10-01T09:00:00Z' },
  ]
  assert.deepEqual(ultimaPorProveedor(lista).map(c => c.id), [3, 1])
  assert.deepEqual(ultimaPorProveedor(null), [])
  assert.match(textoDeCorrida({ proveedor: 'solarama', estado: 'aplicada', iniciada_en: '2026-10-01T10:00:00Z', filas: 429, resumen: {} }).texto,
    /^Solarama, última lectura/)
})

test('valorDeParametro: lo que se escribe en la mano de obra, como número de 0 en adelante', () => {
  assert.equal(valorDeParametro('800'), 800)
  assert.equal(valorDeParametro('$1,500'), 1500)
  assert.equal(valorDeParametro(' 3.5 '), 3.5)
  assert.equal(valorDeParametro(''), null)
  assert.equal(valorDeParametro('-1'), null)
  assert.equal(valorDeParametro('mucho'), null)
})
