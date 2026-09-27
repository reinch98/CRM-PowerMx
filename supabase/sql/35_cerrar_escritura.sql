-- ---------------------------------------------------------------------------
-- 35_cerrar_escritura.sql — cierra la escritura de `catalogos` y `auditoria`, y le quita a
-- `anon` los privilegios que RLS NO cubre.
--
-- Es el pendiente "falta restringir escritura en `catalogos` y `auditoria`" del punto 1 de la
-- ruta de mejora. Lo destapó con detalle la foto del esquema (`00_esquema_base.sql`): las
-- políticas de esas dos tablas vienen del esquema original, anterior a la disciplina de RLS
-- por rol, y nunca se revisaron.
--
-- QUÉ ESTÁ MAL HOY
--
-- 1. `catalogos` — tres políticas para `authenticated` sin ninguna comprobación de rol:
--       lee_catalogos       select  using (true)
--       escribe_catalogos   insert  with check (true)
--       actualiza_catalogos update  using (true)
--    O sea que un técnico, un almacenista, un cliente o una cuenta `sin_rol` pueden insertar
--    y modificar renglones. **El código no la usa** (no aparece en `src/` ni en las Edge
--    Functions), así que es superficie de ataque sin ninguna función a cambio. Leer sí se
--    deja abierto: es una tabla de catálogos y mañana puede hacer falta.
--
-- 2. `auditoria` — `todos_escriben_auditoria` (`insert with check (true)`) deja que cualquier
--    cuenta autenticada **invente renglones de auditoría**: puede ensuciar el rastro o
--    inundar la tabla. Y no hace falta para nada: lo único que escribe ahí es `_apunta`, que
--    es `security definer` (así que entra como su dueño y no necesita política) y además ya
--    está revocada a PUBLIC. Leer ya era solo del admin (`admin_lee_auditoria`) y se queda.
--    No hay políticas de update ni delete, así que un renglón escrito no se puede alterar:
--    eso ya estaba bien y es lo que más importa en un rastro de auditoría.
--
-- 3. `anon` tiene TODOS los privilegios sobre las 11 tablas del esquema original: auditoria,
--    catalogos, citas, clientes, cotizaciones, datos_fiscales, equipos,
--    movimientos_inventario, ordenes_servicio, perfiles y productos. Las tablas creadas
--    después (orden_partes, entregas, conversaciones…) sí llevan el revoke, y las vistas
--    también (`04_vistas_seguras.sql`); estas once se quedaron atrás.
--    **Hoy no es una puerta abierta**, y conviene decirlo con precisión: `select`, `insert`,
--    `update` y `delete` SÍ pasan por RLS, y ninguna política de este proyecto es `to anon`,
--    así que una petición anónima no ve ni toca una sola fila. Pero **`truncate` no pasa por
--    RLS** —es la única operación que se le escapa— y `references` y `trigger` tampoco son
--    cosa de un rol público. No es alcanzable por la API REST (PostgREST nunca emite un
--    `truncate`) ni hay forma de abrir una sesión como `anon`, que es `nologin`; es un
--    privilegio de más, no un agujero. Se quita porque es gratis y porque contradice la
--    doctrina del proyecto: "la llave anon es pública por diseño; lo que protege es RLS".
--    Si RLS no cubre `truncate`, entonces `truncate` no puede estar concedido.
--
-- ESTE CRM NO TIENE NADA ANÓNIMO: todas las pantallas exigen sesión y el login va por la API
-- de Auth, no por PostgREST. Por eso se revoca todo y no solo la escritura.
--
-- OJO CON LAS TABLAS FUTURAS: Supabase tiene `alter default privileges` que vuelve a conceder
-- a `anon` y `authenticated` en cada tabla nueva. Este script arregla las que existen; una
-- tabla nueva nace otra vez con los privilegios, así que su script tiene que traer su propio
-- revoke, como ya lo hacen los del 14 en adelante.
--
-- SQL plano a propósito (sin bloques plpgsql): ver "Pruebas en el editor SQL" en CLAUDE.md.
-- Repetible: `drop policy if exists` y `revoke` se pueden correr de nuevo sin tronar.
-- ---------------------------------------------------------------------------

-- ---- 1. catalogos: leer todos, escribir solo el admin ----

drop policy if exists escribe_catalogos   on catalogos;
drop policy if exists actualiza_catalogos on catalogos;
drop policy if exists lee_catalogos       on catalogos;
drop policy if exists admin_catalogos     on catalogos;

create policy lee_catalogos on catalogos
  for select to authenticated using (true);

create policy admin_catalogos on catalogos
  for all to authenticated using (es_admin()) with check (es_admin());

-- ---- 2. auditoria: nadie la escribe desde una sesión; solo `_apunta` (security definer) ----

drop policy if exists todos_escriben_auditoria on auditoria;

-- `admin_lee_auditoria` se queda como está. Se vuelve a declarar por si acaso, para que este
-- script deje la tabla en un estado conocido aunque alguien la haya quitado.
drop policy if exists admin_lee_auditoria on auditoria;
create policy admin_lee_auditoria on auditoria
  for select to authenticated using (es_admin());

-- ---- 3. anon: fuera de las once tablas del esquema original ----

revoke all on auditoria, catalogos, citas, clientes, cotizaciones, datos_fiscales,
              equipos, movimientos_inventario, ordenes_servicio, perfiles, productos
  from anon;

-- ---- comprobaciones ----

-- a) Las políticas que quedan en las dos tablas. No debe aparecer ninguna de insert o update
--    con la condición en `true`: las de escritura tienen que pedir `es_admin()`.
select tablename as tabla, policyname as politica, cmd as operacion,
       coalesce(qual, '(sin using)') as using_,
       coalesce(with_check, '(sin with check)') as with_check_
from pg_policies
where schemaname = 'public' and tablename in ('catalogos', 'auditoria')
order by tablename, policyname;

-- b) Qué le queda a `anon` en el esquema público. Lo esperado: ninguna fila.
select table_name as tabla, string_agg(distinct lower(privilege_type::text), ', ') as privilegios
from information_schema.role_table_grants
where table_schema = 'public' and grantee::text = 'anon'
group by table_name
order by table_name;
