import { test } from 'node:test'
import assert from 'node:assert/strict'
import { normalizarHoja } from '../scripts/proveedor/adaptadores/normalizar.js'
import { adaptador } from '../scripts/proveedor/adaptadores/index.js'
import { parsearFix, tipoDeCambio } from '../scripts/proveedor/banxico.js'
import { partir, leerArgumentos } from '../scripts/proveedor/sync.js'

// Encabezados tal como los deja el Excel de XLStore (con acentos y mayúsculas).
const ENCABEZADO = ['Código', 'Categoría', 'Marca', 'Modelo', 'Descripción', 'Precio lista (USD)',
  'Tu precio (USD)', 'Stock local MID', 'Stock nacional', 'Imagen', 'Ficha técnica', 'Garantía']

const fila = (sku, costo, extra = {}) => [sku, 'Paneles solares', 'JA SOLAR', 'JA-M66', `Panel ${sku}`, 200, costo,
  extra.local ?? 1, extra.nacional ?? 449, extra.imagen ?? 'https://x/i.png', extra.ficha ?? '', extra.garantia ?? '']

test('normaliza una fila de XLStore: costo = "Tu precio", no el de lista', () => {
  const { filas, avisos } = normalizarHoja([ENCABEZADO, fila('P1', 4050.87)])
  assert.equal(avisos.length, 0)
  assert.deepEqual(filas[0], {
    sku_proveedor: 'P1', nombre: 'Panel P1', categoria: 'Paneles solares', marca: 'JA SOLAR',
    modelo: 'JA-M66', costo: 4050.87, moneda: 'USD', stock_local: 1, stock_proveedor: 449,
    tiempo_entrega_dias: null, url_imagen: 'https://x/i.png', documentos: {},
  })
})

test('la moneda sale del encabezado "(USD)" y una opción la sobreescribe', () => {
  assert.equal(normalizarHoja([ENCABEZADO, fila('P1', 10)]).filas[0].moneda, 'USD')
  const sinMoneda = [['Código', 'Costo'], ['P1', 10]]
  assert.throws(() => normalizarHoja(sinMoneda), /moneda/)
  assert.equal(normalizarHoja(sinMoneda, { monedaPorOmision: 'MXN' }).filas[0].moneda, 'MXN')
})

test('sin costo se conserva (null) y se avisa: no es un error', () => {
  const { filas, avisos } = normalizarHoja([ENCABEZADO, fila('P1', null)])
  assert.equal(filas[0].costo, null)
  assert.match(avisos[0], /P1.*sin costo/)
})

test('los documentos se separan por renglón y se quitan repetidos', () => {
  const { filas } = normalizarHoja([ENCABEZADO,
    fila('P1', 1, { ficha: 'https://x/a.pdf\nhttps://x/a.pdf\nhttps://x/b.pdf', garantia: 'https://x/g.pdf' })])
  assert.deepEqual(filas[0].documentos, {
    ficha_tecnica: ['https://x/a.pdf', 'https://x/b.pdf'], garantia: ['https://x/g.pdf'],
  })
})

test('rechaza lo que corrompería una lectura', () => {
  assert.throws(() => normalizarHoja([ENCABEZADO, fila('P1', 1), fila('P1', 2)]), /repetido.*P1/)
  assert.throws(() => normalizarHoja([ENCABEZADO, fila('P1', -5)]), /negativo/)
  assert.throws(() => normalizarHoja([ENCABEZADO, fila('P1', 'abc')]), /inválido/)
  assert.throws(() => normalizarHoja([ENCABEZADO]), /vacía/)
  assert.throws(() => normalizarHoja([['Nombre', 'Costo'], ['x', 1]], { monedaPorOmision: 'USD' }), /código/)
})

test('ignora renglones vacíos al final y acepta costos escritos como texto', () => {
  const { filas } = normalizarHoja([ENCABEZADO, fila('P1', '$1,234.50'), [null, null], ['', '']])
  assert.equal(filas.length, 1)
  assert.equal(filas[0].costo, 1234.5)
})

test('los adaptadores se piden por nombre', () => {
  assert.equal(typeof adaptador('excel'), 'function')
  assert.throws(() => adaptador('feed_que_no_existe'), /No existe/)
})

const respuestaBanxico = (dato, fecha = '29/09/2026') =>
  ({ bmx: { series: [{ idSerie: 'SF43718', datos: [{ fecha, dato }] }] } })

test('Banxico: lee el FIX y convierte la fecha a ISO', () => {
  assert.deepEqual(parsearFix(respuestaBanxico('18.4321')),
    { valor: 18.4321, fecha: '2026-09-29', fuente: 'banxico:SF43718' })
})

test('Banxico: una respuesta rara se rechaza en vez de inventar un tipo de cambio', () => {
  assert.throws(() => parsearFix({}), /válido/)
  assert.throws(() => parsearFix(respuestaBanxico('N/E')), /válido/)
  assert.throws(() => parsearFix(respuestaBanxico('1.5')), /válido/)
})

test('tipo de cambio: el manual gana; sin token no hay tipo de cambio', async () => {
  assert.deepEqual(await tipoDeCambio({ TIPO_CAMBIO: '19.5' }), { valor: 19.5, fecha: null, fuente: 'manual' })
  await assert.rejects(tipoDeCambio({ TIPO_CAMBIO: '3' }), /fuera de rango/)
  await assert.rejects(tipoDeCambio({}), /BANXICO_TOKEN/)
  const falso = async () => ({ ok: true, json: async () => respuestaBanxico('18.1') })
  assert.equal((await tipoDeCambio({ BANXICO_TOKEN: 't' }, falso)).valor, 18.1)
  const caido = async () => ({ ok: false, status: 503 })
  await assert.rejects(tipoDeCambio({ BANXICO_TOKEN: 't' }, caido), /503/)
})

test('lotes y argumentos', () => {
  assert.deepEqual(partir([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]])
  assert.deepEqual(partir([], 2), [])
  assert.deepEqual(leerArgumentos(['--archivo', 'a.xlsx', '--seco']),
    { proveedor: 'xlstore', adaptador: 'excel', lote: 200, seco: true, archivo: 'a.xlsx' })
  assert.throws(() => leerArgumentos(['--lote', '0']), /lote/)
  assert.throws(() => leerArgumentos(['--raro']), /desconocido/)
  assert.throws(() => leerArgumentos(['--archivo']), /valor/)
})
