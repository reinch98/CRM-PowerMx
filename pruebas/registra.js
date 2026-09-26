// Prende los enlaces de módulos antes de que se cargue cualquier prueba.
// Se usa con `node --import ./pruebas/registra.js --test ...` (ver `npm test`).
import { register } from 'node:module'

register('./enlaces.js', import.meta.url)
