-- ---------------------------------------------------------------------------
-- 00_volcar_esquema.sql — SACA UNA FOTO DEL ESQUEMA `public`.
--
-- POR QUÉ EXISTE. Los scripts 09 a 29 son casi todos `alter table` sobre tablas que
-- **nunca estuvieron en el repo**: `clientes`, `equipos`, `citas`, `ordenes_servicio`,
-- `cotizaciones`, `movimientos_inventario`, `auditoria` y `datos_fiscales` solo existen
-- dentro de Supabase. Si el proyecto se pierde, se pierde el esquema y no hay forma de
-- reconstruir la base desde cero. Esto lo arregla.
--
-- POR QUÉ NO SE USA `supabase db dump`. La CLI corre `pg_dump` **dentro de Docker**, y en
-- la máquina de Caña no hay Docker ni Postgres instalado. Este script lee los catálogos
-- (`pg_class`, `pg_constraint`, `pg_policies`…) y ARMA el DDL con `pg_get_functiondef`,
-- `pg_get_indexdef`, `pg_get_constraintdef` y compañía: lo mismo que haría pg_dump, pero
-- desde el editor SQL.
--
-- NO CAMBIA NADA. Es un `select`. Se puede correr cuantas veces se quiera.
--
-- CÓMO SE USA
--   1. Pegarlo completo en el editor SQL de Supabase y correrlo.
--   2. El resultado es UNA sola celda con todo el esquema (una sola fila, para que el
--      editor no corte filas ni las reordene).
--   3. Descargar el resultado (botón de descarga / "Download CSV") y guardar el archivo
--      como `supabase/sql/00_esquema_base.sql`, quitando las comillas que mete el CSV.
--
-- ORDEN DE LO QUE SALE. Está pensado para poder correrse de arriba a abajo en una base
-- vacía, que es lo que se necesita el día que haya que reconstruirla:
--   tipos → funciones → secuencias → tablas → defaults → restricciones → índices →
--   vistas → triggers → RLS → políticas → permisos.
-- Las funciones van ANTES de las tablas porque hay columnas generadas que las llaman
-- (`conversaciones.telefono_norm` usa `normalizar_telefono`), y los `default` van DESPUÉS
-- por lo contrario: un default puede llamar a una función que todavía no existiría.
-- Aun así es una FOTO, no una migración: si una sentencia falla por el orden (una función
-- que devuelve el tipo de una tabla, una vista que depende de otra), se vuelve a correr
-- esa parte al final.
--
-- OJO: las vistas salen con su `reloptions`, así que **conservan el modo
-- `security_invoker`**. `existencias`, `resguardo_por_cliente` y `catalogo` están en
-- definer a propósito (ver "Seguridad" en CLAUDE.md): reconstruirlas en invoker dejaría
-- al técnico sin existencias ni catálogo.
-- ---------------------------------------------------------------------------

with

-- Las extensiones no se recrean aquí (Supabase ya las trae), pero hay que saber cuáles hay.
extensiones as (
  select 100 as orden, e.extname::text as nombre,
         format('-- extensión instalada: %s (esquema %s, versión %s)',
                e.extname, n.nspname, e.extversion) as ddl
  from pg_extension e
  join pg_namespace n on n.oid = e.extnamespace
),

tipos as (
  select 200 as orden, t.typname::text as nombre,
         format('create type public.%I as enum (%s);', t.typname,
                (select string_agg(quote_literal(l.enumlabel), ', ' order by l.enumsortorder)
                 from pg_enum l where l.enumtypid = t.oid)) as ddl
  from pg_type t
  join pg_namespace n on n.oid = t.typnamespace
  where n.nspname = 'public' and t.typtype = 'e'
),

-- Funciones y procedimientos propios. Se excluyen los que trae una extensión.
funciones as (
  select 300 as orden, (p.proname || '_' || p.oid::text)::text as nombre,
         pg_get_functiondef(p.oid) || ';' as ddl
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prokind in ('f', 'p')
    and not exists (
      select 1 from pg_depend d
      where d.objid = p.oid and d.classid = 'pg_proc'::regclass and d.deptype = 'e'
    )
),

-- Solo las secuencias sueltas: las de `identity` y `serial` las crea su propia tabla.
secuencias as (
  select 400 as orden, c.relname::text as nombre,
         format('create sequence if not exists public.%I;', c.relname) as ddl
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'S'
    and not exists (
      select 1 from pg_depend d
      where d.objid = c.oid and d.classid = 'pg_class'::regclass and d.deptype in ('a', 'i')
    )
),

tablas_propias as (
  select c.oid, c.relname
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r'
    and not exists (
      select 1 from pg_depend d
      where d.objid = c.oid and d.classid = 'pg_class'::regclass and d.deptype = 'e'
    )
),

-- Las columnas, con su tipo. `not null`, `identity` y las columnas GENERADAS van aquí
-- (una generada no se puede agregar después); el `default` se deja para más abajo.
columnas as (
  select t.oid, t.relname,
         string_agg(
           format('  %I %s%s%s%s',
             a.attname,
             format_type(a.atttypid, a.atttypmod),
             case when a.attgenerated = 's'
                  then format(' generated always as (%s) stored',
                              pg_get_expr(ad.adbin, ad.adrelid))
                  else '' end,
             case a.attidentity
                  when 'a' then ' generated always as identity'
                  when 'd' then ' generated by default as identity'
                  else '' end,
             case when a.attnotnull and a.attgenerated = '' then ' not null' else '' end),
           E',\n' order by a.attnum) as lista
  from tablas_propias t
  join pg_attribute a on a.attrelid = t.oid and a.attnum > 0 and not a.attisdropped
  left join pg_attrdef ad on ad.adrelid = a.attrelid and ad.adnum = a.attnum
  group by t.oid, t.relname
),

tablas as (
  select 500 as orden, relname::text as nombre,
         format(E'create table if not exists public.%I (\n%s\n);', relname, lista) as ddl
  from columnas
),

-- Los `default` se aplican después de crear las funciones: hay defaults que las llaman.
defaults as (
  select 600 as orden, (t.relname || '.' || a.attname)::text as nombre,
         format('alter table public.%I alter column %I set default %s;',
                t.relname, a.attname, pg_get_expr(ad.adbin, ad.adrelid)) as ddl
  from tablas_propias t
  join pg_attribute a on a.attrelid = t.oid and a.attnum > 0 and not a.attisdropped
  join pg_attrdef ad on ad.adrelid = a.attrelid and ad.adnum = a.attnum
  where a.attgenerated = '' and a.attidentity = ''
),

-- Primarias y únicas primero, luego los `check`, y las llaves ajenas al final: una llave
-- ajena no se puede crear antes que la tabla a la que apunta.
restricciones as (
  select 700 + case con.contype when 'p' then 0 when 'u' then 1 when 'c' then 2 else 3 end as orden,
         (t.relname || '.' || con.conname)::text as nombre,
         format('alter table public.%I add constraint %I %s;',
                t.relname, con.conname, pg_get_constraintdef(con.oid)) as ddl
  from pg_constraint con
  join tablas_propias t on t.oid = con.conrelid
  where con.contype in ('p', 'u', 'c', 'f')
    and not exists (
      select 1 from pg_depend d
      where d.objid = con.oid and d.classid = 'pg_constraint'::regclass and d.deptype = 'e'
    )
),

-- Los índices que NO respaldan una restricción (esos ya los crea el `add constraint`).
indices as (
  -- Con `if not exists` para que el archivo se pueda volver a correr, como el resto de los
  -- scripts del proyecto. `pg_get_indexdef` no lo pone.
  select 800 as orden, ci.relname::text as nombre,
         regexp_replace(pg_get_indexdef(i.indexrelid),
                        '^CREATE (UNIQUE )?INDEX ', 'CREATE \1INDEX IF NOT EXISTS ') || ';' as ddl
  from pg_index i
  join tablas_propias t on t.oid = i.indrelid
  join pg_class ci on ci.oid = i.indexrelid
  where not exists (select 1 from pg_constraint con where con.conindid = i.indexrelid)
),

-- Con sus `reloptions`: así se conserva `security_invoker`, que en este proyecto decide
-- si el técnico ve existencias o no.
vistas as (
  select 900 as orden, c.relname::text as nombre,
         format(E'create or replace view public.%I%s as\n%s',
                c.relname,
                case when c.reloptions is not null
                     then format(' with (%s)', array_to_string(c.reloptions, ', '))
                     else '' end,
                pg_get_viewdef(c.oid, true)) as ddl
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'v'
),

materializadas as (
  select 1000 as orden, c.relname::text as nombre,
         format(E'create materialized view if not exists public.%I as\n%s',
                c.relname, pg_get_viewdef(c.oid, true)) as ddl
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'm'
),

disparadores as (
  select 1100 as orden, (c.relname || '.' || tg.tgname)::text as nombre,
         pg_get_triggerdef(tg.oid) || ';' as ddl
  from pg_trigger tg
  join pg_class c on c.oid = tg.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and not tg.tgisinternal
),

rls as (
  select 1200 as orden, c.relname::text as nombre,
         format('alter table public.%I enable row level security;', c.relname)
           || case when c.relforcerowsecurity
                   then format(E'\nalter table public.%I force row level security;', c.relname)
                   else '' end as ddl
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
),

politicas as (
  select 1300 as orden, (p.tablename || '.' || p.policyname)::text as nombre,
         format('create policy %I on public.%I as %s for %s to %s%s%s;',
                p.policyname, p.tablename,
                case when p.permissive = 'PERMISSIVE' then 'permissive' else 'restrictive' end,
                lower(p.cmd),
                array_to_string(p.roles, ', '),
                case when p.qual is not null then format(' using (%s)', p.qual) else '' end,
                case when p.with_check is not null then format(' with check (%s)', p.with_check) else '' end) as ddl
  from pg_policies p
  where p.schemaname = 'public'
),

-- Los permisos que SÍ existen sobre cada tabla y vista, agrupados por quién los tiene.
permisos as (
  select 1400 as orden, (g.table_name || '.' || g.grantee)::text as nombre,
         format('grant %s on public.%I to %s;',
                string_agg(distinct lower(g.privilege_type::text), ', '),
                g.table_name::text,
                -- PUBLIC es un pseudo-rol: entrecomillarlo como identificador ("PUBLIC")
                -- crearía un rol que no existe.
                case when g.grantee::text = 'PUBLIC' then 'public'
                     else quote_ident(g.grantee::text) end) as ddl
  from information_schema.role_table_grants g
  where g.table_schema = 'public'
    and g.grantee::text in ('anon', 'authenticated', 'service_role', 'PUBLIC')
  group by g.table_name, g.grantee
),

-- Lo que NO se puede leer de una lista de `grant`: que a `anon` se le haya QUITADO todo.
-- En este proyecto eso es una promesa de seguridad (toda vista lleva revocado `anon`), así
-- que se escribe explícita en vez de quedar implícita en una ausencia.
revocaciones_anon as (
  select 1450 as orden, c.relname::text as nombre,
         format('revoke all on public.%I from anon;', c.relname) as ddl
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind in ('r', 'v', 'm')
    and not has_table_privilege('anon', c.oid, 'select')
),

-- Igual con las funciones internas: por defecto Postgres da `execute` a PUBLIC, así que una
-- función revocada (como `_fijar_componente`) solo se distingue por su revoke.
--
-- No se usa `has_function_privilege('public', …)`: PUBLIC no es un rol y esa llamada falla.
-- Se lee el ACL directo. `proacl` nulo significa el permiso por defecto (PUBLIC sí ejecuta);
-- si hay ACL y en él no aparece el otorgado 0 —que es PUBLIC— con EXECUTE, se revocó.
revocaciones_funciones as (
  select 1500 as orden, (p.proname || '_' || p.oid::text)::text as nombre,
         format('revoke execute on function public.%I(%s) from public;',
                p.proname, pg_get_function_identity_arguments(p.oid)) as ddl
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prokind in ('f', 'p')
    and p.proacl is not null
    and not exists (
      select 1 from aclexplode(p.proacl) a
      where a.grantee = 0 and a.privilege_type = 'EXECUTE'
    )
    and not exists (
      select 1 from pg_depend d
      where d.objid = p.oid and d.classid = 'pg_proc'::regclass and d.deptype = 'e'
    )
),

encabezado as (
  select 0 as orden, ''::text as nombre,
         format(E'-- Esquema `public` de crm-generadores, foto tomada el %s.\n'
                '-- Generado por supabase/sql/00_volcar_esquema.sql — no editar a mano:\n'
                '-- volver a correr ese script y reemplazar este archivo.\n'
                '--\n'
                '-- Contenido: %s tablas, %s vistas, %s funciones, %s políticas.\n'
                '-- Es una FOTO, no una migración: si una sentencia falla por el orden,\n'
                '-- se vuelve a correr al final.',
                to_char(now() at time zone 'America/Mexico_City', 'DD/MM/YYYY'),
                (select count(*) from tablas_propias),
                (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'public' and c.relkind = 'v'),
                (select count(*) from funciones),
                (select count(*) from pg_policies where schemaname = 'public')) as ddl
),

titulos as (
  select * from (values
    (90,   '-- ========== EXTENSIONES (informativo) =========='),
    (190,  '-- ========== TIPOS =========='),
    (290,  '-- ========== FUNCIONES (van antes de las tablas: hay columnas generadas que las llaman) =========='),
    (390,  '-- ========== SECUENCIAS SUELTAS =========='),
    (490,  '-- ========== TABLAS =========='),
    (590,  '-- ========== DEFAULTS (después de las funciones) =========='),
    (690,  '-- ========== RESTRICCIONES =========='),
    (790,  '-- ========== ÍNDICES =========='),
    (890,  '-- ========== VISTAS (con su modo security_invoker) =========='),
    (1090, '-- ========== TRIGGERS =========='),
    (1190, '-- ========== ROW LEVEL SECURITY =========='),
    (1290, '-- ========== POLÍTICAS =========='),
    (1390, '-- ========== PERMISOS =========='),
    (1440, '-- ========== LO REVOCADO (no se ve en un grant) ==========')
  ) as t(orden, ddl)
),

partes as (
  select orden, nombre, ddl from encabezado
  union all select orden, ''::text, ddl from titulos
  union all select orden, nombre, ddl from extensiones
  union all select orden, nombre, ddl from tipos
  union all select orden, nombre, ddl from funciones
  union all select orden, nombre, ddl from secuencias
  union all select orden, nombre, ddl from tablas
  union all select orden, nombre, ddl from defaults
  union all select orden, nombre, ddl from restricciones
  union all select orden, nombre, ddl from indices
  union all select orden, nombre, ddl from vistas
  union all select orden, nombre, ddl from materializadas
  union all select orden, nombre, ddl from disparadores
  union all select orden, nombre, ddl from rls
  union all select orden, nombre, ddl from politicas
  union all select orden, nombre, ddl from permisos
  union all select orden, nombre, ddl from revocaciones_anon
  union all select orden, nombre, ddl from revocaciones_funciones
)

-- UNA sola fila a propósito: el editor de Supabase no corta ni reordena una celda, y así
-- el archivo se descarga de una pieza.
select string_agg(ddl, E'\n\n' order by orden, nombre, ddl) as esquema
from partes;
