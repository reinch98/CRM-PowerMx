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

export async function guardarFoto({ id, orden_id, blob }) {
  const db = await abrir()
  return new Promise((resolve, reject) => {
    const tx = db.transaction(ALMACEN, 'readwrite')
    tx.objectStore(ALMACEN).put({ id, orden_id, blob })
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

export async function borrarFotosDeOrden(orden_id) {
  const fotos = await fotosDeOrden(orden_id)
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
