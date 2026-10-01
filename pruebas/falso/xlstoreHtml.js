// HTML de prueba con la MISMA forma que devuelve XLStore (tarjetas del listado, filtro de marcas,
// existencias y documentos), armado a partir de lo que se vio en el sitio real el 29/09/2026.
// Sirve para probar el extractor sin tocar el sitio de nadie. Si XLStore cambia su HTML, esto es lo que
// hay que actualizar junto con `extraer.js`.
const BASE = 'https://xlstore.exelsolar.com'

const esc = (t) => String(t).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;')

export function tarjeta(p) {
  const idMarca = p.idMarca || 'MARCA1'
  const lista = p.precioLista != null ? `<p class="text-left text-Precio-Oferta-product"><del style="text-decoration-color:#dc7b78;">USD $${p.precioLista.toLocaleString('en-US', { minimumFractionDigits: 2 })}</del></p>` : ''
  const precio = p.precio != null
    ? `<b class="text-left text-Precio-Normal-product"> USD $${p.precio.toLocaleString('en-US', { minimumFractionDigits: 2 })} </b>`
    : '<span class="cotizar">Cotizar</span>'
  const watt = p.porWatt != null ? `<div class="por-watt">USD $${p.porWatt.toFixed(3)}/w</div>` : ''
  return `
 <div class="col col-6 col-sm-6 col-md-4 col-lg-3"> <div class="card font-muli card-product ">
  <div class="card-body px-3 py-1"><div class="row"><div class="col-12" style="padding:0;">
   <a class="link-color" href="/Producto/Detalle?CodigoProducto=${p.codigo}">
    <div style="width:100%;height:158px;"><img src="${BASE}/Multimedia/Productos/${idMarca}/${p.codigo}.png" loading="lazy" alt="" />
     <img src="${BASE}/Multimedia/Marcas/${idMarca}.png" class="product-container-brand-image" alt="" /></div></a></div></div>
   <div class="row"><div style="bottom:0;left:0;">
    <a class="container-txt session link-color" href="/Producto/Detalle?CodigoProducto=${p.codigo}">
     <div class="text-ellipsis lines-1-Modificado title-color-product text-size-title-product" title="${esc(p.modelo)}"><b>${esc(p.modelo)}</b></div>
     <div class="text-ellipsis lines-2-Modificado text-color-product text-size-descrption-product" title="${esc(p.nombre)}">${esc(p.nombre)}</div></a></div></div>
   <div class="row"><div class="col">${lista}<div style="height:0px;"></div>${precio}${watt}</div></div>
  </div></div></div>`
}

export const listado = (productos) => `<div class="row px-1">${productos.map(tarjeta).join('')}</div>`

export const filtroMarcas = (marcas) => `
 <div class="h-list" id="listMarcas">
  <div class="h-item filter-marca active" data-id="TODOS" data-name="TODOS"><span>TODOS (${marcas.length})</span></div>
  ${marcas.map((m) => `<div class="h-item filter-marca" data-id="${m.id}" data-name="${esc(m.nombre)}"><img src="${BASE}/Multimedia/Marcas/${m.id}.png"/></div>`).join('')}
 </div>`

export const existencia = (codigo, s) => `
 <input type="hidden" id="${codigo}-MID-MID" data-local="${s.local}" data-cedis="${s.cedis}" data-cedis-display="${s.cedis}" data-clever="${s.clever}" data-clever-display="${s.clever}" data-nacional="${s.nacional}" data-nacional-display="${s.nacional}" data-codigo="${codigo}" data-existenciauniqueId="${codigo}-MID-MID" />
 <div class="col-6 padding-0"><span class="text-Local-existencias-product"><span>${s.local}</span></span></div>
 <script> MostrarEtiquetaProducto('${codigo}-MID-MID'); </script>`

export const documentos = (docs) => `<div id="documentosProductoList"><div class="card"><div class="card-body">
 ${docs.map((u) => `<div class="mb-2"><a href="${BASE}${u}" target="_blank"><b>${u.split('/').pop()}</b></a></div>`).join('')}
</div></div></div>`

/** Catálogo sintético: `n` productos repartidos en las categorías dadas, con casos raros incluidos. */
export function catalogoFalso(slugs, n = 12) {
  const marcas = [{ id: 'M1', nombre: 'JA SOLAR' }, { id: 'M2', nombre: 'ENPHASE' }]
  const porCategoria = {}
  slugs.forEach((slug, ci) => {
    porCategoria[slug] = Array.from({ length: n }, (_, i) => {
      const codigo = `${slug.slice(0, 3).toUpperCase()}${ci}X${String(i).padStart(3, '0')}`
      const m = marcas[i % 2]
      return {
        codigo, idMarca: m.id, modelo: `MOD-${codigo}`, nombre: `Producto ${codigo} de 1.5" "especial"`,
        precio: i === 3 ? null : 100 + i * 10.5, precioLista: i % 4 === 0 ? 200 + i * 10.5 : null, porWatt: i === 1 ? 0.17 : null,
      }
    })
  })
  return { marcas, porCategoria }
}
