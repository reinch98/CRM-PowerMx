// Traducir un error de Supabase a algo que un técnico en campo pueda actuar.
//
// `temporal` es lo importante: separa lo que se arregla solo (señal) de lo que necesita que
// alguien haga algo. La cola reintenta lo temporal y deja de intentar lo que no lo es; si un
// error de permisos se marcara temporal, el celular reintentaría para siempre en silencio.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { explicarError } from '../src/lib/errores.js'

test('sin señal es TEMPORAL: se reintenta solo', () => {
  for (const mensaje of ['Failed to fetch', 'NetworkError when attempting to fetch', 'Load failed', 'network request failed', 'timeout']) {
    const r = explicarError({ message: mensaje })
    assert.equal(r.temporal, true, `"${mensaje}" debería ser temporal`)
    assert.match(r.texto, /señal|conexión/i)
  }
})

test('la sesión vencida NO es temporal: hay que salir y entrar', () => {
  const r = explicarError({ code: 'PGRST301' })
  assert.equal(r.temporal, false)
  assert.match(r.texto, /sesión/i)
  assert.match(r.texto, /no se pierde/)   // al técnico hay que decirle que su trabajo sigue ahí
  assert.equal(explicarError({ message: 'JWT expired' }).temporal, false)
})

test('un permiso denegado NO es temporal: reintentarlo no lo arregla', () => {
  for (const error of [
    { code: '42501' },
    { code: '403' },
    { message: 'new row violates row-level security policy' },
    { message: 'permission denied for table ordenes_servicio' },
  ]) {
    const r = explicarError(error)
    assert.equal(r.temporal, false)
    assert.match(r.texto, /permiso/i)
  }
})

test('el cliente o el equipo borrado se explica, no se muestra el código', () => {
  const r = explicarError({ code: '23503' })
  assert.match(r.texto, /ya no existe/)
  assert.equal(r.temporal, false)
})

test('un dato inválido incluye el mensaje, para poder corregirlo', () => {
  const r = explicarError({ code: '22P02', message: 'invalid input syntax for type numeric: ""' })
  assert.match(r.texto, /no es válido/)
  assert.match(r.texto, /numeric/)   // el detalle se conserva
})

test('el bucket que falta manda avisar al administrador', () => {
  // Esto pasó de verdad: un bucket `Ordenes` con mayúscula rompió la subida de fotos.
  const r = explicarError({ message: 'Bucket not found' })
  assert.match(r.texto, /fotos/)
  assert.equal(r.temporal, false)
})

test('un error desconocido muestra su mensaje y no se reintenta a ciegas', () => {
  assert.equal(explicarError({ message: 'algo raro' }).texto, 'algo raro')
  assert.equal(explicarError({ message: 'algo raro' }).temporal, false)
  assert.equal(explicarError(null).texto, 'Error desconocido.')
  assert.equal(explicarError('texto suelto').texto, 'texto suelto')
})

test('ningún texto deja al técnico sin saber qué hacer', () => {
  for (const error of [{ code: 'PGRST301' }, { code: '42501' }, { code: '23503' }, { message: 'Failed to fetch' }]) {
    const t = explicarError(error).texto
    assert.ok(t.length > 20, `"${t}" es demasiado corto para explicar algo`)
    assert.doesNotMatch(t, /^[A-Z]{2,}\d/)   // que no empiece por un código crudo
  }
})
