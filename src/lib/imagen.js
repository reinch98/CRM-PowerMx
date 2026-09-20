// ---------------------------------------------------------------------------
// Encoge las fotos antes de guardarlas.
//
// Una foto de celular pesa de 2 a 5 MB. Reducida a 1200 px de ancho y calidad
// media baja a unos 200 KB, que para documentar un mantenimiento se ve igual
// de bien. Con mala señal, subir 200 KB en vez de 4 MB cambia todo.
// ---------------------------------------------------------------------------

export async function redimensionar(archivo, ladoMaximo = 1200, calidad = 0.7) {
  const imagen = await createImageBitmap(archivo)

  let { width, height } = imagen
  const escala = Math.min(1, ladoMaximo / Math.max(width, height))
  width = Math.round(width * escala)
  height = Math.round(height * escala)

  const lienzo = document.createElement('canvas')
  lienzo.width = width
  lienzo.height = height
  lienzo.getContext('2d').drawImage(imagen, 0, 0, width, height)
  imagen.close()

  return new Promise(resolve => {
    lienzo.toBlob(blob => resolve(blob), 'image/jpeg', calidad)
  })
}

// Convierte la firma (que el lienzo entrega como texto base64) en archivo.
export function dataUrlABlob(dataUrl) {
  const [encabezado, datos] = dataUrl.split(',')
  const tipo = encabezado.match(/:(.*?);/)[1]
  const binario = atob(datos)
  const bytes = new Uint8Array(binario.length)
  for (let i = 0; i < binario.length; i++) bytes[i] = binario.charCodeAt(i)
  return new Blob([bytes], { type: tipo })
}

// ¿El lienzo de la firma no tiene ningún trazo?
export function firmaEnBlanco(lienzo) {
  const { data } = lienzo.getContext('2d').getImageData(0, 0, lienzo.width, lienzo.height)
  for (let i = 3; i < data.length; i += 4) if (data[i] !== 0) return false
  return true
}
