-- ---------------------------------------------------------------------------
-- 34_cliente_necesita_cliente_id.sql — un perfil con rol `cliente` tiene que estar ligado.
--
-- LO ENCONTRÓ LA PRUEBA 33 (26/09/2026). En la base había un perfil con `rol = 'cliente'` y
-- `cliente_id` en null. La pantalla Usuarios **ya lo impide** ("Un usuario con rol cliente
-- necesita tener un cliente asignado", `Tecnicos.jsx`), así que ese perfil se creó por fuera,
-- desde el Table Editor. La validación vivía solo en el navegador.
--
-- POR QUÉ IMPORTA. `mi_cliente()` lee esa columna, y RLS la usa en todas las políticas del
-- cliente (`cliente_ve_lo_suyo`) y en la rama de cliente de `resguardo_por_cliente`. Con la
-- columna en null la cuenta **no ve nada**: falla cerrada, que es lo correcto para la
-- seguridad, pero el día que exista el portal sería una pantalla en blanco sin explicación, y
-- el error no estaría donde se busca (en el portal) sino en un campo vacío de otra tabla.
--
-- Se pone como `check` y no como trigger porque no depende de otra tabla ni del orden de las
-- operaciones: es una regla sobre el propio renglón.
--
-- REQUISITO: no puede haber ningún perfil cliente sin ligar, o el `alter table` falla. Eso es
-- a propósito — si falla, el mensaje dice cuántos hay y se arreglan en Usuarios. La consulta
-- de abajo los lista antes de intentarlo.
--
-- Repetible: la restricción se borra y se vuelve a crear.
-- ---------------------------------------------------------------------------

-- Quiénes estorbarían. Si devuelve renglones, arreglarlos en Usuarios antes de seguir.
select id, email, rol, 'le falta el cliente' as problema
from perfiles
where rol = 'cliente' and cliente_id is null;

alter table perfiles drop constraint if exists perfiles_cliente_ligado;

alter table perfiles add constraint perfiles_cliente_ligado
  check (rol <> 'cliente' or cliente_id is not null);

-- Y al revés: un perfil que NO es cliente no debería arrastrar un cliente_id. La pantalla ya
-- lo suelta al cambiar de rol (`payload.cliente_id = null`), pero por la misma razón que
-- arriba conviene que lo garantice la base: un técnico con `cliente_id` colgado no rompe nada
-- hoy, pero hace dudar a quien lea la tabla mañana.
update perfiles set cliente_id = null where rol <> 'cliente' and cliente_id is not null;

alter table perfiles drop constraint if exists perfiles_solo_cliente_ligado;

alter table perfiles add constraint perfiles_solo_cliente_ligado
  check (rol = 'cliente' or cliente_id is null);

-- Comprobación: debe salir 0 en las dos columnas.
select
  count(*) filter (where rol = 'cliente' and cliente_id is null)  as clientes_sin_ligar,
  count(*) filter (where rol <> 'cliente' and cliente_id is not null) as otros_con_cliente
from perfiles;
