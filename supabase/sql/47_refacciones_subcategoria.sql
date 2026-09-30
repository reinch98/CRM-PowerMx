-- ---------------------------------------------------------------------------
-- 47_refacciones_subcategoria.sql — restaura la subcategoría y la línea de las refacciones.
--
-- Al publicar el catálogo desde el CRM (30/09/2026) se vio que las 52 refacciones del CRM traen
-- `atributos.subcategoria` MEZCLADA: unas dicen el tipo de pieza ("FILTRO DE ACEITE", "ARRANQUE") y otras
-- la línea del equipo ("GENERACION AIRCOOLED"), y `atributos.linea` se perdió. La página de refacciones
-- arma sus filtros con la subcategoría: publicado así, sus filtros se degradarían.
--
-- Los valores buenos son los del catálogo que hoy muestra el sitio (vienen del Excel original y están en
-- Git, POWERMX-sitio/sitio-publicar/productos-refacciones.json). Este script los vuelve a poner en el CRM.
--
--   · Solo toca `atributos.subcategoria` y `atributos.linea`; las demás llaves de `atributos` se quedan.
--   · Solo productos de categoría "refaccion" y solo si el valor es distinto (repetirlo no cambia nada).
--   · Un valor vacío en la lista NO borra lo que ya hubiera en el CRM.
--   · El precio no se toca: el del CRM es el bueno (p. ej. 0663860SRV ya tiene 350).
--
-- Antes de correrlo, para ver el problema:
--   select atributos ->> 'subcategoria' as subcategoria, count(*) from productos
--    where categoria = 'refaccion' group by 1 order by 2 desc;
-- ---------------------------------------------------------------------------

with buenos (sku, subcategoria, linea) as (values
  ('REF-FILTRO-CAT-001', 'SELLOS Y FLEXIBLES', null),
  ('0E6154', 'ATS Y TRANSFERENCIA', null),
  ('0E7079', 'BUJIAS', null),
  ('0F3158', 'ENFRIAMIENTO', null),
  ('0C4138', 'EMPAQUES', null),
  ('0C4647', 'EMPAQUES', null),
  ('0C3150', 'EMPAQUES', null),
  ('0C2979', 'EMPAQUES', null),
  ('0L3081A', 'SISTEMA DE GAS', null),
  ('070185ES-G', 'FILTRO DE ACEITE', null),
  ('0F5419', 'FILTRO DE AIRE', null),
  ('22676', 'FUSIBLES', null),
  ('99727', 'FUSIBLES', null),
  ('0A9611', 'FUSIBLES', null),
  ('0D7178T', 'FUSIBLES', null),
  ('0663860SRV', 'ARRANQUE', 'AIRCOOLED'),
  ('0K2098', 'CONTROL Y TABLERO', 'AIRCOOLED'),
  ('0K2035', 'SELLOS Y FLEXIBLES', 'AIRCOOLED'),
  ('0C3025', 'SENSORES', 'AIRCOOLED'),
  ('0L2910', 'ATS Y TRANSFERENCIA', null),
  ('0E4494', 'CONTROL Y TABLERO', 'GASOLINA'),
  ('0H06430SRV', 'CONTROL Y TABLERO', 'AIRCOOLED'),
  ('0D5419', 'FILTRO DE ACEITE', null),
  ('0E2507', 'SENSORES', null),
  ('0E0502', 'SENSORES', null),
  ('0G0952', 'BANDAS', null),
  ('0G8853', 'BOBINAS DE ENCENDIDO', 'LIQUIDCOOLED'),
  ('0D2244M', 'SENSORES', 'LIQUIDCOOLED'),
  ('0H1827', 'SENSORES', 'LIQUIDCOOLED'),
  ('0E42710SRV', 'ARRANQUE', 'AIRCOOLED'),
  ('0A8584', 'SENSORES', 'AIRCOOLED'),
  ('0E4394', 'ACTUADORES', 'LIQUIDCOOLED'),
  ('0G3553', 'ENFRIAMIENTO', 'LIQUIDCOOLED'),
  ('0J8415', 'ARRANQUE', 'AIRCOOLED'),
  ('077220A', 'ATS Y TRANSFERENCIA', null),
  ('0F3869', 'SENSORES', 'LIQUIDCOOLED'),
  ('0A45310244', 'FILTRO DE ACEITE', 'LIQUIDCOOLED'),
  ('0E9368', 'BUJIAS', 'GASOLINA'),
  ('G059402', 'FILTRO DE AIRE', 'LIQUIDCOOLED'),
  ('0E7080', 'FILTRO DE ACEITE', 'LIQUIDCOOLED'),
  ('070185ES', 'FILTRO DE ACEITE', 'AIRCOOLED'),
  ('0G5894', 'FILTRO DE AIRE', 'AIRCOOLED'),
  ('0E9371AS', 'FILTRO DE AIRE', 'AIRCOOLED'),
  ('0D9723S', 'FILTRO DE AIRE', 'AIRCOOLED'),
  ('0J8371C', 'CONTROL Y TABLERO', 'AIRCOOLED'),
  ('10000027421', 'SISTEMA DE GAS', 'AIRCOOLED'),
  ('10000004916', 'BOBINAS DE ENCENDIDO', 'AIRCOOLED'),
  ('10000004931', 'BOBINAS DE ENCENDIDO', 'AIRCOOLED'),
  ('0G3224TA', 'BOBINAS DE ENCENDIDO', 'AIRCOOLED'),
  ('0G3224TB', 'BOBINAS DE ENCENDIDO', 'AIRCOOLED'),
  ('10000003275', 'CONTROL Y TABLERO', 'AIRCOOLED'),
  ('A0000501971', 'ARRANQUE', 'AIRCOOLED')
), cambios as (
  select p.id, p.sku,
         coalesce(b.subcategoria, p.atributos ->> 'subcategoria') as subcategoria,
         coalesce(b.linea, p.atributos ->> 'linea') as linea
    from productos p
    join buenos b on b.sku = p.sku
   where p.categoria = 'refaccion'
     and ( p.atributos ->> 'subcategoria' is distinct from coalesce(b.subcategoria, p.atributos ->> 'subcategoria')
        or p.atributos ->> 'linea' is distinct from coalesce(b.linea, p.atributos ->> 'linea') )
), actualizadas as (
  update productos p
     set atributos = jsonb_strip_nulls(
           coalesce(p.atributos, '{}'::jsonb)
           || jsonb_build_object('subcategoria', c.subcategoria, 'linea', c.linea)),
         updated_at = now()
    from cambios c
   where p.id = c.id
  returning p.sku
)
select count(*) as refacciones_corregidas,
       (select count(*) from productos where categoria = 'refaccion') as refacciones_en_el_crm,
       52 as refacciones_en_la_lista
  from actualizadas;
