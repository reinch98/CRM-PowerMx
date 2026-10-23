-- Prueba del 89 (margen propio de los híbridos). SQL plano, sin plpgsql; todo dentro de begin/rollback.
-- Correr con: npx supabase db query --linked -f supabase/sql/89_prueba_margen_hibridos.sql
-- Se recalcula la fórmula a mano con el costo que devuelve costear_paquete, así que la prueba no depende de
-- los costos del día. Fórmula (redondeo de la regla general = 1, paquete_redondeo = 1000, terminación = 1):
--   precio = ceil(ceil(costo × (1 + margen)) × 1.16 / 1000) × 1000 − 1

begin;
select set_config('request.jwt.claims', json_build_object(
  'sub', (select id from perfiles where rol = 'admin' and activo limit 1)::text, 'role', 'authenticated')::text, true);
set local role authenticated;

-- El editor y la CLI solo muestran la ÚLTIMA consulta: los pasos 1–4 se guardan en app.pasos.
select set_config('app.pasos', (select string_agg(paso || ': ' || r, chr(10)) from (
with c as (
  select p.sku, costear_paquete(p.id) j
    from productos p
   where p.categoria = 'paquete_solar' and p.activo
     and exists (select 1 from paquete_solar_lineas l where l.paquete_id = p.id)
), v as (
  select sku, (j ->> 'margen_hibrido_pct')::numeric mh, (j -> 'regla' ->> 'margen_pct')::numeric mr,
         k.key variante, (k.value ->> 'costo')::numeric costo, (k.value ->> 'precio')::numeric precio,
         (k.value ->> 'margen_pct')::numeric margen
    from c, jsonb_each(j -> 'variantes') k
), chequeo as (
  select sku, variante, precio,
         case when variante = 'interconectado' then mr else mh end esperado_margen,
         ceil(ceil(costo * (1 + (case when variante = 'interconectado' then mr else mh end) / 100)) * 1.16 / 1000)
           * 1000 - 1 esperado
    from v
)
select '1. el parámetro existe y vale 22' paso,
       case when (select valor from parametros_costeo where clave = 'margen_hibrido_pct') = 22 then 'ok' else 'FALLA' end r
union all
select '2. cada híbrido sale con el 22 % sobre el costo',
       case when count(*) > 0 and bool_and(precio = esperado) then 'ok'
            else 'FALLA: ' || string_agg(sku || ' ' || variante || ' ' || precio || ' vs ' || esperado, '; ') end
  from chequeo where variante <> 'interconectado'
union all
select '3. el interconectado sigue con la regla (' || max(esperado_margen) || ' %)',
       case when count(*) > 0 and bool_and(precio = esperado) then 'ok'
            else 'FALLA: ' || string_agg(sku || ' ' || precio || ' vs ' || esperado, '; ') end
  from chequeo where variante = 'interconectado'
union all
select '4. costear_paquete dice qué margen usó cada variante',
       case when bool_and(margen = case when variante = 'interconectado' then mr else mh end) then 'ok' else 'FALLA' end
  from v
) pasos), true);

-- 5. Sin el parámetro, los híbridos vuelven a la regla de margen (como antes del 89).
reset role;
delete from parametros_costeo where clave = 'margen_hibrido_pct';
set local role authenticated;
select current_setting('app.pasos') || chr(10) || '5. sin el parámetro, el híbrido usa la regla: ' ||
       case when (j -> 'variantes' -> 'hibrido_a' ->> 'margen_pct')::numeric = (j -> 'regla' ->> 'margen_pct')::numeric
             and j ->> 'margen_hibrido_pct' is null then 'ok' else 'FALLA' end resultado
  from (select costear_paquete(id) j from productos where sku = 'PKG-ESSENTIAL') x;

rollback;
