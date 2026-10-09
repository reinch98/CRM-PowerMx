// Copia la consulta de supabase/sql/00_volcar_esquema.sql dentro de la función
// `_partes_esquema()` de supabase/sql/69_foto_esquema_mensual.sql, para que la foto manual y la
// mensual sean la MISMA consulta. Correr cada vez que cambie el 00:
//   node scripts/generar_foto_esquema.mjs
// Se puede repetir: reemplaza lo que haya entre `as $fe$` y el `select … from partes;` de la función.
import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const sql = join(dirname(fileURLToPath(import.meta.url)), '..', 'supabase', 'sql')
const lineas = readFileSync(join(sql, '00_volcar_esquema.sql'), 'utf8').replace(/\r\n/g, '\n').split('\n')
const ini = lineas.indexOf('with')
const fin = lineas.findIndex(l => l.startsWith('select string_agg(ddl'))
if (ini < 0 || fin < 0) throw new Error('No encontré el `with` o el `select string_agg` final del 00')

// Las CTE, sin los comentarios que preceden al select final.
let cuerpo = lineas.slice(ini, fin).join('\n').replace(/(\n--[^\n]*)*\s*$/, '\n')

// Las funciones se nombran por su firma, no por su oid: un oid cambia con drop y create, y la
// comparación mes a mes vería "quitada + agregada" donde no cambió nada.
const viejo = "(p.proname || '_' || p.oid::text)::text as nombre"
const nuevo = "(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')')::text as nombre"
const veces = cuerpo.split(viejo).length - 1
if (veces !== 2) throw new Error(`Esperaba 2 nombres de función por oid en el 00 y hay ${veces}`)
cuerpo = cuerpo.split(viejo).join(nuevo)
if (cuerpo.includes('$fe$')) throw new Error('El 00 trae la marca $fe$: cambia la marca de la función')

const ruta69 = join(sql, '69_foto_esquema_mensual.sql')
const s = readFileSync(ruta69, 'utf8').replace(/\r\n/g, '\n')
const abre = 'returns table (orden int, nombre text, ddl text)'
const a = s.indexOf('as $fe$\n', s.indexOf(abre))
const cierre = 'select orden::int, nombre, ddl from partes;'
const b = s.indexOf(cierre, a)
if (a < 0 || b < 0) throw new Error('No encontré la función _partes_esquema en el 69')

// Concatenación, no `replace`: un `$` en el texto de reemplazo de String.replace se interpreta
// (así se dañaron el 64 y el 65).
const nuevo69 = s.slice(0, a + 'as $fe$\n'.length) + cuerpo + s.slice(b)
writeFileSync(ruta69, nuevo69)
console.log(`69 actualizado: ${cuerpo.split('\n').length} líneas de consulta copiadas del 00.`)
