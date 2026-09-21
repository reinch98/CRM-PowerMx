-- 13 · Fase 1e: el técnico ya no crea órdenes ni toca citas por su cuenta.
--
-- Después de esto las órdenes solo nacen de una cita (agendar_cita, programar_cita o
-- aceptar una cotización) y la cita solo pasa a "realizada" con cerrar_orden. Ambas
-- funciones son security definer, así que no dependen de estas políticas.
--
-- NO CORRER hasta que los celulares de los técnicos hayan vaciado su cola vieja
-- ("Pendientes por subir" en Órdenes → Orden sin cita). Una orden libre que siga en la
-- cola ya no podría subir: el servidor la rechazaría con "permiso denegado".
--
-- Se puede repetir sin tronar.

-- 0. Antes de correr: ¿hay órdenes sin cita creadas por técnicos en los últimos días?
--    (informativo; si salen recientes, quizá alguien sigue usando el camino viejo)
-- select folio, created_at, tecnico_id from ordenes_servicio
--  where cita_id is null order by created_at desc limit 10;

-- 1. El técnico ya no inserta órdenes. Nacen de una cita.
drop policy if exists "tecnico_crea_ordenes" on ordenes_servicio;

-- 2. El técnico ya no actualiza citas: antes podía reasignarlas o cambiarles fecha y
--    estado. Sigue viéndolas (tecnico_ve_sus_citas, tecnico2_ve_sus_citas).
drop policy if exists "tecnico_actualiza_sus_citas" on citas;

-- 3. Comprobación: qué políticas de escritura quedan para el técnico.
select tablename, policyname, cmd
from pg_policies
where schemaname = 'public'
  and tablename in ('citas', 'ordenes_servicio', 'orden_partes')
  and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
order by tablename, policyname;
-- Esperado: citas → solo admin_citas; ordenes_servicio → solo admin_ordenes;
-- orden_partes → admin_orden_partes, tecnico_crea_su_parte, tecnico_actualiza_su_parte.
