// Sincroniza los precios y existencias de un proveedor con el CRM (SQL 44).
//
//   node scripts/proveedor/sync.js --archivo C:\ruta\xlstore_catalogo.xlsx
//   node scripts/proveedor/sync.js --archivo x.xlsx --seco     (solo lee y revisa; no toca nada)
//   node scripts/proveedor/sync.js --proveedor solarama --archivo "LISTA DE PRECIOS SOLARAMA <MES>.pdf"
//
// Variables de entorno (las mismas cuentas que el webhook de WhatsApp y `convertir.js`):
//   SUPABASE_URL, SUPABASE_ANON_KEY, BOT_EMAIL, BOT_PASSWORD
//   BANXICO_TOKEN  (o TIPO_CAMBIO a mano si Banxico no responde)
//
// Este script NO calcula precios ni decide qué se publica: eso vive en la base
// (`sync_aplicar`, con sus candados). Aquí solo se lee al proveedor, se entrega la lectura
// y se pide aplicar. Si algo falla, la corrida queda "fallida" y el proceso sale con error
// para que GitHub Actions avise.
import { pathToFileURL } from 'node:url'
import { adaptador } from './adaptadores/index.js'
import { tipoDeCambio } from './banxico.js'

export function partir(filas, n) {
  const trozos = []
  for (let i = 0; i < filas.length; i += n) trozos.push(filas.slice(i, i + n))
  return trozos
}

export function leerArgumentos(argv) {
  const o = { proveedor: 'xlstore', adaptador: 'excel', lote: 200, seco: false }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--seco') o.seco = true
    else if (a === '--con-documentos') o.conDocumentos = true
    else if (['--proveedor', '--adaptador', '--archivo', '--moneda', '--hoja', '--lote', '--cookie-archivo'].includes(a)) {
      const v = argv[++i]
      if (v === undefined) throw new Error(`Falta el valor de ${a}.`)
      o[a === '--cookie-archivo' ? 'cookieArchivo' : a.slice(2)] = a === '--lote' ? Number(v) : v
    } else throw new Error(`Argumento desconocido: ${a}`)
  }
  if (!Number.isInteger(o.lote) || o.lote < 1 || o.lote > 1000) throw new Error('--lote debe ser de 1 a 1000.')
  // Solarama solo publica su lista en PDF: si no se dice otro adaptador, se usa el suyo.
  if (o.proveedor === 'solarama' && !argv.includes('--adaptador')) o.adaptador = 'solarama'
  return o
}

function exigir(env, nombres) {
  const faltan = nombres.filter((n) => !env[n])
  if (faltan.length) throw new Error(`Faltan variables de entorno: ${faltan.join(', ')}.`)
}

function resumenLectura(filas) {
  const conCosto = filas.filter((f) => f.costo !== null).length
  const porCategoria = {}
  for (const f of filas) porCategoria[f.categoria ?? '(sin categoría)'] = (porCategoria[f.categoria ?? '(sin categoría)'] ?? 0) + 1
  return { total: filas.length, conCosto, sinCosto: filas.length - conCosto, porCategoria }
}

export async function main(argv = process.argv.slice(2), env = process.env) {
  const args = leerArgumentos(argv)
  const leer = adaptador(args.adaptador)

  if (args.seco) {
    const lectura = await leer({
      archivo: args.archivo, hoja: args.hoja, moneda: args.moneda,
      cookieArchivo: args.cookieArchivo, conDocumentos: args.conDocumentos,
    })
    console.log('Lectura en seco (no se tocó la base):')
    console.log(resumenLectura(lectura.filas))
    lectura.avisos.slice(0, 15).forEach((a) => console.log('  aviso:', a))
    if (lectura.avisos.length > 15) console.log(`  … y ${lectura.avisos.length - 15} avisos más.`)
    return 0
  }

  exigir(env, ['SUPABASE_URL', 'SUPABASE_ANON_KEY', 'BOT_EMAIL', 'BOT_PASSWORD'])
  // Import dinámico: la lectura en seco y las pruebas no necesitan el cliente.
  const { createClient } = await import('@supabase/supabase-js')
  const supabase = createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, { auth: { persistSession: false } })
  const { error: errLogin } = await supabase.auth.signInWithPassword({
    email: env.BOT_EMAIL, password: env.BOT_PASSWORD,
  })
  if (errLogin) throw new Error(`No pude entrar como el conector: ${errLogin.message}`)

  const rpc = async (nombre, params) => {
    const { data, error } = await supabase.rpc(nombre, params)
    if (error) throw new Error(`${nombre}: ${error.message}`)
    return data
  }

  const corrida = await rpc('sync_iniciar', { p_proveedor: args.proveedor, p_fuente: args.adaptador })
  try {
    const lectura = await leer({
      archivo: args.archivo, hoja: args.hoja, moneda: args.moneda,
      cookieArchivo: args.cookieArchivo, conDocumentos: args.conDocumentos,
    })
    console.log(`Leí ${lectura.filas.length} productos (${lectura.fuente}).`)
    lectura.avisos.slice(0, 10).forEach((a) => console.log('  aviso:', a))

    for (const trozo of partir(lectura.filas, args.lote)) {
      await rpc('sync_recibir_lote', { p_corrida: corrida, p_filas: trozo })
    }
    const cierre = await rpc('sync_cerrar_lectura', { p_corrida: corrida })
    if (!cierre.ok) {
      throw new Error(`Lectura rechazada: ${cierre.filas} filas contra ${cierre.previas} de la anterior. No se aplicó nada.`)
    }

    const fix = await tipoDeCambio(env)
    console.log(`Tipo de cambio: ${fix.valor} (${fix.fuente}${fix.fecha ? `, ${fix.fecha}` : ''}).`)
    const r = await rpc('sync_aplicar', {
      p_corrida: corrida, p_tipo_cambio: fix.valor, p_tc_fecha: fix.fecha, p_tc_fuente: fix.fuente,
    })
    console.log('Resultado:', r)
    if (r.en_revision > 0) console.log(`→ ${r.en_revision} cambios esperan tu aprobación en la cola de revisión.`)
    if (r.sin_regla_o_costo > 0) console.log(`→ ${r.sin_regla_o_costo} productos sin regla de margen o sin costo.`)

    // Los paquetes solares se arman con estos costos: se recalculan al final (SQL 78). Si esto falla, la
    // sincronización ya quedó aplicada; solo se avisa.
    try {
      const p = await rpc('recalcular_paquetes', {})
      console.log(`Paquetes solares: ${p.aplicados} precios actualizados solos, ${p.por_aprobar} esperan tu aprobación` +
        (p.faltan > 0 ? `, ${p.faltan} sin precio por falta de costo.` : '.'))
    } catch (e) {
      console.log('Paquetes solares: no se pudieron recalcular:', e.message)
    }
    return 0
  } catch (e) {
    // Si esto también falla no hay mucho más que hacer: el error original es el que importa.
    try {
      await supabase.rpc('sync_registrar_error', { p_corrida: corrida, p_error: e.message })
    } catch { /* se ignora: importa el error original */ }
    throw e
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  main().then((codigo) => process.exit(codigo), (e) => {
    console.error(`✗ ${e.message}`)
    process.exit(1)
  })
}
