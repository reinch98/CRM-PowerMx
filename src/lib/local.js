// ---------------------------------------------------------------------------
// Lo que el celular guarda para poder trabajar sin señal: la cola de órdenes,
// el catálogo de equipos y el perfil. Todo pasa por aquí para que un
// almacenamiento lleno o bloqueado nunca tumbe la app.
// ---------------------------------------------------------------------------

export function leerLocal(clave, porDefecto) {
  try {
    const crudo = localStorage.getItem(clave)
    return crudo ? JSON.parse(crudo) : porDefecto
  } catch {
    return porDefecto
  }
}

export function escribirLocal(clave, valor) {
  try {
    localStorage.setItem(clave, JSON.stringify(valor))
  } catch {
    // Si el almacenamiento está lleno o bloqueado, no tumbamos la app.
  }
}

export function borrarLocal(clave) {
  try {
    localStorage.removeItem(clave)
  } catch {
    // Nada que hacer.
  }
}

// ---------------------------------------------------------------------------
// Sesión guardada por Supabase.
//
// Con el token vencido (dura una hora) y sin señal, supabase.auth.getSession()
// devuelve session: null aunque la sesión sigue guardada: intenta renovarla, no
// puede, y no dice quién eres. Sin esto, un técnico que recarga la app a media
// jornada vería el Login sin poder entrar. Aquí se lee lo guardado, solo para
// saber quién es; el servidor sigue exigiendo un token válido para todo.
// ---------------------------------------------------------------------------
export function usuarioLocal() {
  try {
    for (let i = 0; i < localStorage.length; i++) {
      const clave = localStorage.key(i)
      if (/^sb-.+-auth-token$/.test(clave)) {
        const guardado = JSON.parse(localStorage.getItem(clave))
        if (guardado?.user?.id) return guardado.user
      }
    }
  } catch {
    // Almacenamiento bloqueado o dato dañado: se trata como sin sesión.
  }
  return null
}
