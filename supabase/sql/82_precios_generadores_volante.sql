-- ============================================================================
-- 82 · Precios de generadores según los volantes de 16/10/2026
--
-- Los dos volantes (gasolina de 3 a 15 kW, y automáticos a gas LP) traen el precio al público con
-- impuestos incluidos. Aquí se llevan al CRM; el sitio los toma al correr convertir.js.
--
--   · Los 6 Air Cooled y el GP15500EFI están en DÓLARES: se guardan con moneda = 'USD' (Caña, 16/10/2026:
--     "muéstralos en USD por el momento"; la actualización diaria del precio es el siguiente paso).
--   · Se renombran los modelos viejos que ocupaban el mismo lugar (decisión de Caña): se conserva el SKU
--     (de él cuelgan la foto y la ficha del sitio) y cambian nombre, modelo, potencia y arranque.
--       GAS-CX8000   → 8000WX      GAS-CX5500  → 5500WX
--       GAS-GP8000E  → GP15500EFI  GEN-IQ2KW   → GP3000i
--   · Todos los automáticos del volante incluyen tablero de transferencia (ATS) → ats = 'si'.
--   · La potencia es la "en operación" del volante (la de arranque no cuenta).
--   · Sin tocar: AIR-20KW, GAS-GP3600, LIQ-32 y LIQ-34 (no salen en el volante).
-- Se puede repetir sin problema: fija valores, no suma.
-- ============================================================================

-- Moneda por producto: 'MXN' o 'USD' (la columna ya existía; aquí se acota a esos dos valores)
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'productos_moneda_valida') then
    alter table productos
      add constraint productos_moneda_valida check (moneda in ('MXN', 'USD'));
  end if;
end $$;

update productos p set
  nombre = v.nombre,
  modelo = v.nombre,
  precio = v.precio,
  moneda = v.moneda,
  atributos = p.atributos || jsonb_build_object(
    'kw', v.kw, 'arranque', v.arranque, 'ats', v.ats)
from (values
  -- sku,           nombre,             precio, moneda, kw,   arranque,     ats
  ('GAS-CX8000',  '8000WX',            26000,  'MXN',  8,    'Eléctrico',  'no'),
  ('GAS-CX5500',  '5500WX',            17000,  'MXN',  5.4,  'Manual',     'no'),
  ('GAS-PM3800',  'PM3800',            11500,  'MXN',  3,    'Manual',     'no'),
  ('GAS-GP8000E', 'GP15500EFI',         5700,  'USD',  15.5, 'Eléctrico',  'no'),
  ('GEN-IQ3KW',   'iQ3500 INVERTER',   19000,  'MXN',  3,    'Manual',     'no'),
  ('GEN-IQ2KW',   'GP3000i',           14000,  'MXN',  2.3,  'Manual',     'no'),
  ('AIR-10KW',    'AIRCOOLED 10KW',     6500,  'USD',  10,   'Automático', 'si'),
  ('AIR-14KW',    'AIRCOOLED 14KW',     8200,  'USD',  14,   'Automático', 'si'),
  ('AIR-18KW',    'AIRCOOLED 18KW',     9400,  'USD',  18,   'Automático', 'si'),
  ('AIR-22KW',    'AIRCOOLED 22KW',    10300,  'USD',  22,   'Automático', 'si'),
  ('AIR-24KW',    'AIRCOOLED 24KW',    10700,  'USD',  24,   'Automático', 'si'),
  ('AIR-26KW',    'AIRCOOLED 26KW',    11700,  'USD',  26,   'Automático', 'si')
) as v(sku, nombre, precio, moneda, kw, arranque, ats)
where p.sku = v.sku and p.categoria = 'generador';

insert into _migraciones (archivo, tipo) values ('82_precios_generadores_volante.sql', 'datos')
on conflict (archivo) do nothing;
