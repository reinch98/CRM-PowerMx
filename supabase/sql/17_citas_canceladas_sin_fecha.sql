-- ===========================================================================
-- CORRECCIÓN: una cita "por programar" (sin fecha) se puede cancelar
--
-- La regla de 09_flujo_servicio_base.sql era:  fecha is not null OR estado = 'por_programar'.
-- Una cita sin fecha solo podía estar "por programar": al cancelarla (estado → 'cancelada') la
-- base la rechazaba con «violates check constraint "citas_fecha_segun_estado"». Lo mismo le pasaba
-- a rechazar o vencer una cotización cuya cita todavía no tenía fecha.
--
-- Ahora una cita sin fecha puede estar "por programar" o "cancelada". Programada y realizada
-- siguen exigiendo fecha. Se puede volver a ejecutar sin problema.
-- ===========================================================================

alter table citas drop constraint if exists citas_fecha_segun_estado;
alter table citas add constraint citas_fecha_segun_estado
  check (fecha is not null or estado in ('por_programar', 'cancelada'));

-- Verificación: la regla nueva.
select conname, pg_get_constraintdef(oid) as regla
from pg_constraint
where conrelid = 'public.citas'::regclass and conname = 'citas_fecha_segun_estado';
