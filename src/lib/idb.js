// ---------------------------------------------------------------------------
// Almacén local para las fotos.
//
// localStorage solo aguanta ~5 MB y guarda texto: una sola foto de celular lo
// revienta y se pierde toda la cola de órdenes. IndexedDB guarda archivos
// binarios y tiene mucho más espacio, así que las fotos viven aquí y las
// órdenes (que son texto) siguen en localStorage.
// ---------------------------------------------------------------------------

const BASE = 'crm-powermx'
const ALMACEN = 'fotos'

function abrir() {
  return new Promise((resolve, reject) => {
    const peticion = indexedDB.open(BASE, 1)
    peticion.onupgradeneeded = () => {
      const db = peticion.result
      if (!db.objectStoreNames.contains(ALMACEN)) {
        const almacen = db.createObjectStore(ALMACEN, { keyPath: 'id' })
        almacen.createIndex('orden_id', 'orden_id')
      }
    }
    peticion.onsuccess = () => resolve(peticion.result)
    peticion.onerror = () => reject(peticion.error)
  })
}

// `destino` dice a qué pertenece la foto: la parte del técnico, un punto de la revisión o
// la placa de un componente. Las tres viven en la misma orden, pero suben por caminos
// distintos y no deben mezclarse: sin esto, la foto de una placa acabaría en la lista de
// fotos de la parte.
export async function guardarFoto({ id, orden_id, blob, destino = 'parte' }) {
  const db = await abrir()
  return new Promise((resolve, reject) => {
    const tx = db.transaction(ALMACEN, 'readwrite')
    tx.objectStore(ALMACEN).put({ id, orden_id, blob, destino })
    tx.oncomplete = () => resolve()
    tx.onerror = () => reject(tx.error)
  })
}

export async function fotosDeOrden(orden_id) {
  const db = await abrir()
  return new Promise((resolve, reject) => {
    const tx = db.transaction(ALMACEN, 'readonly')
    const peticion = tx.objectStore(ALMACEN).index('orden_id').getAll(orden_id)
    peticion.onsuccess = () => resolve(peticion.result)
    peticion.onerror = () => reject(peticion.error)
  })
}

// `destinos` acota qué se tira: tirar la parte pendiente no debe llevarse por delante las
// fotos de la revisión, que viven en la misma orden.
export async function borrarFotosDeOrden(orden_id, destinos = null) {
  const todas = await fotosDeOrden(orden_id)
  const fotos = destinos ? todas.filter(f => destinos.includes(f.destino || 'parte')) : todas
  const db = await abrir()
  return new Promise((resolve, reject) => {
    const tx = db.transaction(ALMACEN, 'readwrite')
    const almacen = tx.objectStore(ALMACEN)
    fotos.forEach(f => almacen.delete(f.id))
    tx.oncomplete = () => resolve()
    tx.onerror = () => reject(tx.error)
  })
}

// Quita una sola foto (la que el técnico descartó antes de subirla).
export async function borrarFoto(id) {
  const db = await abrir()
  return new Promise((resolve, reject) => {
    const tx = db.transaction(ALMACEN, 'readwrite')
    tx.objectStore(ALMACEN).delete(id)
    tx.oncomplete = () => resolve()
    tx.onerror = () => reject(tx.error)
  })
}
