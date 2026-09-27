-- ---------------------------------------------------------------------------
-- 34_cliente_necesita_cliente_id.sql — un perfil con rol `cliente` tiene que estar ligado.
--
-- LO ENCONTRÓ LA PRUEBA 33 (26/09/2026). En la base hay un perfil con `rol = 'cliente'` y
-- `cliente_id` en null. La pantalla Usuarios **ya lo impide** ("Un usuario con rol cliente
-- necesita tener un cliente asignado", `Tecnicos.jsx`), así que ese perfil se creó por fuera,
-- desde el Table Editor. La validación vivía solo en el navegador.
--
-- POR QUÉ IMPORTA. `mi_cliente()` lee esa columna, y RLS la usa en las políticas del cliente
-- (`cliente_ve_lo_suyo`) y en la rama de cliente de `resguardo_por_cliente`. Con la columna en
-- null la cuenta **no ve nada**: falla cerrada, que para la seguridad está bien, pero el día
-- que exista el portal sería una pantalla en blanco sin explicación, y el error no estaría
-- donde se busca (en el portal) sino en un campo vacío de otra tabla.
--
-- ORDEN. **Primero hay que ligar el perfil**, en la pantalla Usuarios: con rol "Cliente"
-- aparece un selector de cliente. Si no, este script se detiene a propósito — no tiene
-- sentido poner la regla y dejar un renglón que la rompe. Se detiene con un mensaje que dice
-- QUIÉN falta, en vez del «is violated by some row» de Postgres, que no dice cuál ni qué hacer.
--
-- Se pone como `check` y no como trigger porque no depende de otra tabla ni del orden de las
-- operaciones: es una regla sobre el propio renglón.
--
-- Repetible: las restricciones se borran y se vuelven a crear.
-- ---------------------------------------------------------------------------

-- Para elegir: los clientes que hay, con su id. (Conviene hacerlo en Usuarios, que es la
-- pantalla para eso; esto es solo para ver las opciones o para el update de emergencia.)
select id, nombre from clientes order by nombre;

do $$
declare
  v_faltan text;
  v_n      int;
begin
  select count(*), string_agg(coalesce(email, id::text), ', ')
    into v_n, v_faltan
  from perfiles where rol = 'cliente' and cliente_id is null;

  if v_n > 0 then
    raise exception
      'Falta ligar % perfil(es) con rol cliente a su cliente: %. Hazlo en la pantalla Usuarios (con rol "Cliente" sale un selector) y vuelve a correr este script. Sin eso la cuenta no ve nada y el portal saldría en blanco.',
      v_n, v_faltan;
  end if;
end $$;

-- Un perfil que NO es cliente no debería arrastrar un cliente_id. La pantalla ya lo suelta al
-- cambiar de rol (`payload.cliente_id = null`), pero por la misma razón de arriba conviene que
-- lo garantice la base: un técnico con `cliente_id` colgado no rompe nada hoy, pero hace dudar
-- a quien lea la tabla mañana.
update perfiles set cliente_id = null where rol <> 'cliente' and cliente_id is not null;

alter table perfiles drop constraint if exists perfiles_cliente_ligado;
alter table perfiles add constraint perfiles_cliente_ligado
  check (rol <> 'cliente' or cliente_id is not null);

alter table perfiles drop constraint if exists perfiles_solo_cliente_ligado;
alter table perfiles add constraint perfiles_solo_cliente_ligado
  check (rol = 'cliente' or cliente_id is null);

-- Comprobación: las dos columnas deben salir en 0.
select
  count(*) filter (where rol = 'cliente' and cliente_id is null)      as clientes_sin_ligar,
  count(*) filter (where rol <> 'cliente' and cliente_id is not null) as otros_con_cliente
from perfiles;
