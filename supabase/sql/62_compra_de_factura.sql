-- ---------------------------------------------------------------------------
-- 62_compra_de_factura.sql — registrar una compra leída de una factura (foto o PDF).
--
-- La función `leer-comprobante` (modo factura) solo PROPONE (proveedor, folio, líneas); el admin revisa cada línea
-- y decide: una pieza que ya existe en el catálogo, una pieza NUEVA, o no es material. Esto
-- registra lo decidido en UNA transacción:
--
--   · crea los productos nuevos (sin publicar y sin precio: no salen al sitio hasta que alguien
--     les ponga precio) ligados al proveedor y al código que ese proveedor maneja;
--   · guarda el código del proveedor de cada pieza (producto_proveedores) para que la próxima
--     factura de ese proveedor se empate sola por código;
--   · registra la compra con `registrar_compra` (SQL 41): ENTRADA al almacén general, costo real
--     y el archivo de la factura.
--
-- Si algo falla —un SKU repetido, una cantidad en cero— no queda nada a medias: ni la compra ni
-- los productos nuevos. Solo admin. Repetible.
--
-- Y el bucket de facturas `compras` ahora acepta también fotos (antes solo XML y PDF).
-- ---------------------------------------------------------------------------

update storage.buckets
   set allowed_mime_types = array['application/xml', 'text/xml', 'application/pdf',
                                  'image/jpeg', 'image/png', 'image/webp']
 where id = 'compras';

create or replace function registrar_compra_de_factura(p_datos jsonb, p_lineas jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_linea jsonb;
  v_lineas jsonb := '[]'::jsonb;
  v_nuevo jsonb;
  v_prod uuid;
  v_prov text;
  v_codigo text;
  v_sku text;
  v_creados int := 0;
  v_codigos int := 0;
  v_actualizar boolean;
  v_res jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador registra compras.' using errcode = '42501';
  end if;
  v_prov := trim(coalesce(p_datos ->> 'proveedor', ''));
  if v_prov = '' then
    raise exception 'Escribe de quién se compró.' using errcode = '22023';
  end if;
  if jsonb_typeof(p_lineas) <> 'array' or jsonb_array_length(p_lineas) = 0 then
    raise exception 'Una compra necesita al menos una pieza.' using errcode = '22023';
  end if;

  for v_linea in select * from jsonb_array_elements(p_lineas) loop
    v_prod := nullif(v_linea ->> 'producto_id', '')::uuid;
    v_codigo := nullif(trim(coalesce(v_linea ->> 'codigo', '')), '');
    v_nuevo := v_linea -> 'nuevo';
    v_actualizar := coalesce((v_linea ->> 'actualizar_costo')::boolean, false);

    if v_prod is null then
      if v_nuevo is null or jsonb_typeof(v_nuevo) <> 'object' then
        raise exception 'Una línea no trae pieza del catálogo ni datos de una pieza nueva.' using errcode = '22023';
      end if;
      v_sku := upper(trim(coalesce(v_nuevo ->> 'sku', '')));
      if v_sku = '' then
        raise exception 'Una pieza nueva necesita su SKU.' using errcode = '22023';
      end if;
      if trim(coalesce(v_nuevo ->> 'nombre', '')) = '' then
        raise exception 'La pieza nueva % necesita su nombre.', v_sku using errcode = '22023';
      end if;
      if trim(coalesce(v_nuevo ->> 'categoria', '')) = '' then
        raise exception 'La pieza nueva % necesita su categoría.', v_sku using errcode = '22023';
      end if;
      if exists (select 1 from productos where upper(sku) = v_sku) then
        raise exception 'Ya existe un producto con el SKU %. Elígelo de la lista o cámbiale el SKU a la pieza nueva.', v_sku
          using errcode = '22023';
      end if;
      v_prod := gen_random_uuid();
      insert into productos (id, sku, nombre, categoria, unidad, activo, publicar, proveedor, proveedor_sku)
      values (v_prod, v_sku, trim(v_nuevo ->> 'nombre'), trim(v_nuevo ->> 'categoria'),
              coalesce(nullif(trim(coalesce(v_nuevo ->> 'unidad', '')), ''), 'pieza'),
              true, false, v_prov, v_codigo);
      v_creados := v_creados + 1;
      -- Una pieza nueva no tiene costo de referencia: el de la factura es el primero.
      v_actualizar := true;
    elsif v_codigo is not null then
      -- El código que este proveedor le da a esta pieza. Si ya estaba (o ese código ya sigue a
      -- otra pieza), no se toca: la llave única del código lo impide.
      insert into producto_proveedores (producto_id, proveedor, proveedor_sku)
      values (v_prod, v_prov, v_codigo)
      on conflict do nothing;
    end if;

    if v_codigo is not null
       and exists (select 1 from producto_proveedores
                    where producto_id = v_prod and proveedor = v_prov and proveedor_sku = v_codigo) then
      v_codigos := v_codigos + 1;
    end if;

    v_lineas := v_lineas || jsonb_build_array(jsonb_build_object(
      'producto_id', v_prod,
      'cantidad', v_linea -> 'cantidad',
      'costo_unitario', v_linea -> 'costo_unitario',
      'actualizar_costo', v_actualizar));
  end loop;

  v_res := registrar_compra(p_datos, v_lineas);
  return v_res || jsonb_build_object('productos_nuevos', v_creados, 'codigos_guardados', v_codigos);
end $fn$;

revoke all on function registrar_compra_de_factura(jsonb, jsonb) from public;
revoke all on function registrar_compra_de_factura(jsonb, jsonb) from anon;
grant execute on function registrar_compra_de_factura(jsonb, jsonb) to authenticated;

notify pgrst, 'reload schema';
