-- ---------------------------------------------------------------------------
-- 50_sync_conserva_documentos.sql — una lectura sin documentos no borra los que ya se conocían.
--
-- La lectura periódica de XLStore (opciones C y D, 30/09/2026) trae precios y existencias, pero NO los
-- enlaces a fichas y manuales: pedirlos son 900 peticiones más al sitio del proveedor, y casi nunca cambian.
-- Con la 44, `sync_recibir_lote` reemplazaba `documentos` y `url_imagen` por lo que llegara, así que cada
-- lectura rápida los dejaba vacíos. Ahora un valor vacío NO pisa lo que ya había (misma idea que
-- `_fijar_componente`: un campo vacío no borra lo ya sabido). Un valor nuevo sí lo reemplaza.
--
-- Es la MISMA función de la 44 con dos líneas cambiadas en su `on conflict`. Repetible.
-- ---------------------------------------------------------------------------

create or replace function sync_recibir_lote(p_corrida uuid, p_filas jsonb)
returns int
language plpgsql security definer set search_path = public as $fn$
declare
  v_c sync_corridas;
  v_f jsonb;
  v_n int := 0;
  v_moneda text;
  v_costo numeric;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector.' using errcode = '42501';
  end if;
  v_c := (select c from sync_corridas c where c.id = p_corrida);
  if v_c.id is null or v_c.estado <> 'leyendo' then
    raise exception 'La corrida no existe o ya no recibe filas.' using errcode = '22023';
  end if;
  if jsonb_typeof(p_filas) <> 'array' then
    raise exception 'Las filas deben ir en un arreglo.' using errcode = '22023';
  end if;

  for v_f in select value from jsonb_array_elements(p_filas) loop
    if coalesce(trim(v_f ->> 'sku_proveedor'), '') = '' then
      raise exception 'Una fila no trae sku_proveedor.' using errcode = '22023';
    end if;
    v_moneda := upper(coalesce(nullif(v_f ->> 'moneda', ''), ''));
    if v_moneda not in ('MXN', 'USD') then
      raise exception 'Moneda inválida en %: "%".', v_f ->> 'sku_proveedor', v_f ->> 'moneda'
        using errcode = '22023';
    end if;
    v_costo := nullif(v_f ->> 'costo', '')::numeric;
    if v_costo is not null and v_costo < 0 then
      raise exception 'Costo negativo en %.', v_f ->> 'sku_proveedor' using errcode = '22023';
    end if;

    insert into proveedor_productos (proveedor, sku_proveedor, nombre, categoria, marca, modelo,
                                     descripcion, costo, moneda, stock_local, stock_proveedor,
                                     tiempo_entrega_dias, url_imagen, documentos,
                                     corrida_id, vigente, leido_en)
    values (v_c.proveedor, trim(v_f ->> 'sku_proveedor'), v_f ->> 'nombre', v_f ->> 'categoria',
            v_f ->> 'marca', v_f ->> 'modelo', v_f ->> 'descripcion', v_costo, v_moneda,
            nullif(v_f ->> 'stock_local', '')::int, nullif(v_f ->> 'stock_proveedor', '')::int,
            nullif(v_f ->> 'tiempo_entrega_dias', '')::int, nullif(v_f ->> 'url_imagen', ''),
            coalesce(v_f -> 'documentos', '{}'::jsonb), p_corrida, true, now())
    on conflict (proveedor, sku_proveedor) do update
      set nombre = excluded.nombre, categoria = excluded.categoria, marca = excluded.marca,
          modelo = excluded.modelo, descripcion = excluded.descripcion, costo = excluded.costo,
          moneda = excluded.moneda, stock_local = excluded.stock_local,
          stock_proveedor = excluded.stock_proveedor,
          tiempo_entrega_dias = excluded.tiempo_entrega_dias,
          url_imagen = coalesce(excluded.url_imagen, proveedor_productos.url_imagen),
          documentos = case when excluded.documentos = '{}'::jsonb then proveedor_productos.documentos
                            else excluded.documentos end,
          corrida_id = excluded.corrida_id,
          vigente = true, leido_en = excluded.leido_en;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $fn$;

revoke all on function sync_recibir_lote(uuid, jsonb) from public;
grant execute on function sync_recibir_lote(uuid, jsonb) to authenticated;
