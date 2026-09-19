-- ===========================================================================
-- CERRAR LAS VISTAS
--
-- Las vistas se ejecutan con los permisos de quien las creó, no de quien las
-- consulta, así que se saltan las políticas por rol. Y Supabase, por defecto,
-- le da acceso a toda tabla o vista nueva a la llave pública (anon), que va
-- dentro del código del CRM.
--
-- Resultado: sin iniciar sesión, cualquiera con esa llave podía leer
-- resguardo_por_cliente (nombres de tus clientes) y las existencias. Peor:
-- catalogo es una vista simple sobre una sola tabla, y Postgres permite
-- escribir a través de ese tipo de vistas. O sea que se podían cambiar
-- precios de productos sin sesión.
--
-- Esto deja las cinco vistas en solo lectura, y solo para quien tenga sesión.
-- ===========================================================================

revoke all on catalogo, existencias, disponibles, por_reordenar, resguardo_por_cliente
  from anon, authenticated;

grant select on catalogo, existencias, disponibles, por_reordenar, resguardo_por_cliente
  to authenticated;

-- Verificación: debe salir 'authenticated' con SELECT en cada vista, y nada más.
select table_name, grantee, privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in ('catalogo','existencias','disponibles','por_reordenar','resguardo_por_cliente')
  and grantee in ('anon','authenticated')
order by table_name, grantee;
