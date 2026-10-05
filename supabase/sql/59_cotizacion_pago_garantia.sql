-- ---------------------------------------------------------------------------
-- 59_cotizacion_pago_garantia.sql — forma de pago y garantía como campos de la cotización.
--
-- Estaban en el formato de Excel de PowerMx pero en el CRM solo existían dentro del texto
-- libre de "condiciones". Como campos propios salen en el PDF con su etiqueta y se pueden
-- filtrar o reutilizar. Son texto libre y opcionales: una cotización vieja queda con ambos en
-- null y su PDF no imprime la fila. Repetible.
-- ---------------------------------------------------------------------------

alter table cotizaciones add column if not exists forma_pago text;
alter table cotizaciones add column if not exists garantia   text;

notify pgrst, 'reload schema';

select column_name, data_type from information_schema.columns
 where table_name = 'cotizaciones' and column_name in ('forma_pago', 'garantia')
 order by column_name;
