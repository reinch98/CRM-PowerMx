-- 89 · Margen propio para los paquetes híbridos (22/10/2026, pedido de Caña).
--
-- Hasta aquí todas las variantes de un paquete solar usaban la MISMA regla de margen (la general, 30 % sobre
-- el costo). Caña decidió publicar los híbridos (A: interconectado + respaldo; B: todo en el LUX) con 22 %:
-- con 30 % quedaban muy por encima de lo que se ve en el mercado, y los de Essential a Elite seguían
-- publicados con precios viejos POR DEBAJO del costo.
--
-- No sirve escribir el precio a mano: recalcular_paquetes() (SQL 78) lo volvería a llevar al 30 % en la
-- siguiente sincronización, porque la diferencia cae dentro del ±15 % que se aplica solo. Por eso el margen
-- vive en la base, en parametros_costeo (se edita en Precios → Costeo de paquetes solares, con auditoría):
--   · margen_hibrido_pct presente → los híbridos usan ese % SOBRE EL COSTO (redondeo y mínimo de la regla);
--   · borrado → los híbridos vuelven a la regla de margen, como antes de este script.
-- El interconectado NO cambia: sigue con la regla de margen.
--
-- costear_paquete se redefine COMPLETA desde la versión viva (idéntica a la del 78); lo nuevo va marcado (89).
-- Se puede correr dos veces: el parámetro es "on conflict do nothing" (no pisa lo que Caña haya corregido).

insert into parametros_costeo (clave, etiqueta, valor, unidad, nota, orden) values
  ('margen_hibrido_pct', 'Margen de los paquetes híbridos, sobre el costo', 22, '%',
   'Solo híbrido A y B. El interconectado usa la regla de margen (Proveedor → Reglas de margen).', 6)
on conflict (clave) do nothing;

create or replace function costear_paquete(p_paquete uuid) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_p productos%rowtype;
  v_regla reglas_margen;
  v_regla_var reglas_margen;  -- (89) la regla que usa cada variante
  v_mh numeric;               -- (89) margen de los híbridos, si está capturado
  v_imp numeric;
  v_red numeric;
  v_resta numeric;
  v_paneles numeric;
  v_kwp numeric;
  v_out jsonb := '{}'::jsonb;
  v_c jsonb;
  v_costo numeric;
  v_sin_iva numeric;
  v_precio numeric;
  v_pub numeric;
  v_cambio numeric;
  v_estado text;
  v_primera boolean;
  r record;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador ve el costo de los paquetes.' using errcode = '42501';
  end if;
  v_p := (select p from productos p where p.id = p_paquete);
  if v_p.id is null or v_p.categoria <> 'paquete_solar' then
    raise exception 'Ese producto no es un paquete solar.' using errcode = '22023';
  end if;
  v_regla := _regla_margen('paquete_solar', null);
  v_mh := (select valor from parametros_costeo where clave = 'margen_hibrido_pct');  -- (89)
  v_imp := coalesce((select valor from parametros_costeo where clave = 'imprevistos_pct'), 0);
  v_red := greatest(coalesce((select valor from parametros_costeo where clave = 'paquete_redondeo'), 1), 1);
  v_resta := coalesce((select valor from parametros_costeo where clave = 'paquete_terminacion'), 0);
  v_paneles := coalesce((select sum(cantidad) from paquete_solar_lineas
                          where paquete_id = p_paquete and variante = 'interconectado' and grupo = 'Paneles'), 0);
  v_kwp := round(v_paneles * coalesce((select valor from parametros_costeo where clave = 'potencia_panel_w'), 0) / 1000, 2);

  for r in
    select * from (values ('interconectado', 'estandar', array['interconectado'], 'interconectado'),
                          ('hibrido_a', 'hibrido', array['interconectado', 'respaldo'], 'respaldo'),
                          ('hibrido_b', 'hibrido_b', array['hibrido_b'], 'hibrido_b')) as t(variante, clave, vars, requiere)
  loop
    -- Una variante existe si su receta tiene líneas propias (el híbrido A, si hay respaldo).
    continue when not exists (select 1 from paquete_solar_lineas where paquete_id = p_paquete and variante = r.requiere);
    v_c := _costear_variante(p_paquete, r.vars);
    v_costo := round((v_c ->> 'base')::numeric * (1 + v_imp / 100), 2);
    -- (89) Los híbridos usan su propio margen sobre el costo, con el redondeo y el mínimo de la regla.
    v_regla_var := v_regla;
    if r.variante <> 'interconectado' and v_mh is not null and v_regla.id is not null then
      v_regla_var.margen_pct := v_mh;
      v_regla_var.sobre := 'costo';
    end if;
    v_sin_iva := case when v_regla.id is null then null else _precio_venta(v_costo, v_regla_var) end;
    v_precio := case when v_sin_iva is null or jsonb_array_length(v_c -> 'faltan') > 0 then null
                     else ceil(v_sin_iva * 1.16 / v_red) * v_red - v_resta end;
    v_pub := nullif(v_p.precios ->> r.clave, '')::numeric;
    v_cambio := case when v_pub > 0 and v_precio is not null then round((v_precio - v_pub) / v_pub * 100, 1) end;
    -- La PRIMERA vez que una variante se publica desde la receta es siempre a mano: cambia también lo que
    -- el sitio dice del paquete (kWp, "incluye"), y no debe pasar en un paquete sí y en otro no.
    v_primera := not coalesce(v_p.atributos -> 'receta_publicada' ? r.clave, false);
    v_estado := case when jsonb_array_length(v_c -> 'faltan') > 0 then 'falta_costo'
                     when v_regla.id is null then 'sin_regla'
                     when v_pub is null or v_pub <= 0 or v_primera then 'por_aprobar'
                     when v_precio = v_pub then 'al_dia'
                     when abs(v_cambio) <= 15 then 'automatico'
                     else 'por_aprobar' end;
    v_out := v_out || jsonb_build_object(r.variante, v_c || jsonb_build_object(
               'clave', r.clave, 'imprevistos', round(v_costo - (v_c ->> 'base')::numeric, 2), 'costo', v_costo,
               'precio_sin_iva', v_sin_iva, 'precio', v_precio, 'publicado', v_pub, 'cambio_pct', v_cambio,
               'margen_pct', v_regla_var.margen_pct, 'sobre', v_regla_var.sobre,  -- (89)
               'primera', v_primera, 'estado', v_estado));
  end loop;

  return jsonb_build_object(
    'paquete_id', v_p.id, 'sku', v_p.sku, 'nombre', v_p.nombre, 'publicar', v_p.publicar, 'activo', v_p.activo,
    'paneles', v_paneles, 'kwp', v_kwp,
    'ahorro_mensual', case when v_kwp > 0 then format('$%s–$%s',
        to_char(round(v_kwp * coalesce((select valor from parametros_costeo where clave = 'ahorro_kwp_min'), 0), -2), 'FM999,999'),
        to_char(round(v_kwp * coalesce((select valor from parametros_costeo where clave = 'ahorro_kwp_max'), 0), -2), 'FM999,999')) end,
    'regla', case when v_regla.id is null then null
                  else jsonb_build_object('categoria', v_regla.categoria, 'margen_pct', v_regla.margen_pct, 'sobre', v_regla.sobre) end,
    'margen_hibrido_pct', v_mh,  -- (89)
    'imprevistos_pct', v_imp,
    'receta', v_p.atributos -> 'receta',
    'variantes', v_out,
    'calculado_en', now());
end;
$$;
revoke execute on function costear_paquete(uuid) from public, anon;
grant execute on function costear_paquete(uuid) to authenticated;

insert into _migraciones (archivo, tipo) values ('89_margen_hibridos.sql', 'esquema') on conflict (archivo) do nothing;
