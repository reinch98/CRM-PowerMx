# Leer XLStore (Exel Solar) con tu sesión

XLStore no tiene API ni feed, y su login lleva reCAPTCHA. Estas herramientas **no saltan ningún captcha**:
reutilizan una sesión que **tú** iniciaste en tu navegador. Hay dos caminos, y los dos usan el mismo código
(`extraer.js`), así que leen exactamente lo mismo.

| | Qué es | Cuándo usarlo |
|---|---|---|
| **C — herramienta del navegador** | Un código que pegas en la consola de Chrome estando en XLStore. Baja `xlstore_catalogo.csv`. | Cuando quieras refrescar a mano. No guarda nada. |
| **D — lectura con tu sesión** | `sync.js --adaptador xlstore` usa la cookie de tu sesión. Se puede programar cada 12 horas en Windows. | Para que se actualice solo mientras la sesión viva. |

Todo se maneja desde el menú de `C:\Users\USER\powermx.ps1`.

## C — a mano
1. Menú **8**: copia la herramienta al portapapeles.
2. Chrome → `xlstore.exelsolar.com` con tu sesión iniciada → F12 → **Consola** → pegar → Enter (si Chrome pide
   que escribas `allow pasting`, hazlo).
3. Tarda 2–3 minutos y baja `xlstore_catalogo.csv` a Descargas.
4. Menú **1**: toma el archivo más reciente (`.xlsx` o `.csv`) y sincroniza.

## D — con la sesión guardada
1. Menú **5**: pegas la cookie (se guarda **cifrada** con Windows; solo tu usuario en esta compu la abre).
   Cómo copiarla: F12 → Red → recarga → primera petición → *Encabezados de la solicitud* → `Cookie:`.
2. Menú **4**: lee XLStore directo y sincroniza (una vez, a mano).
3. Menú **6**: programa Windows para correrlo a las 12:07 am y 12:07 pm. Pide el token (gratis) de Banxico
   para el dólar y la contraseña del conector; ambos se guardan cifrados. Menú **7** lo quita.

**Límites que hay que conocer**
- La sesión **caduca**. Cuando pase, la lectura falla con "La sesión de XLStore no está activa…" y el CRM lo
  muestra en *Proveedor* ("la última lectura falló"); se arregla repitiendo el menú 5.
- La compu debe estar encendida (si estaba apagada, corre al prenderla).
- Reutilizar una sesión de forma automática puede ir contra los términos de uso de XLStore.
- Los registros quedan en `%USERPROFILE%\.powermx\logs` (30 días); **no llevan secretos**.

## Qué lee y a qué ritmo
~1 + 8 + 900 peticiones (una por producto para las existencias), de 4 en 4 con una pausa corta. **No** pide fichas
ni manuales (otras 900 peticiones; casi nunca cambian) y la base conserva los que ya tenía (SQL 50). Si la
lectura trae casi nada, no trae precios, o la sesión se cae a medias, **se rechaza completa**.

## Si XLStore cambia su HTML
Se actualiza `extraer.js` (y `pruebas/falso/xlstoreHtml.js`, que imita su forma) y se vuelve a generar la
herramienta del navegador: `node scripts/proveedor/xlstore/crear-herramienta.js`. La prueba falla si
`xlstore-descargar.js` quedó desactualizado.
