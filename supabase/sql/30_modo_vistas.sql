-- ---------------------------------------------------------------------------
-- 30_modo_vistas.sql — devuelve `catalogo` y `resguardo_por_cliente` a modo DEFINER.
--
-- LO ENCONTRÓ LA FOTO DEL ESQUEMA (26/09/2026). CLAUDE.md dice, desde el 19/09, que
-- `existencias`, `resguardo_por_cliente` y `catalogo` están en definer **a propósito**. La
-- base decía otra cosa:
--
--   existencias            security_invoker = off   ← como debe
--   catalogo               security_invoker = on    ← se volteó
--   resguardo_por_cliente  security_invoker = on    ← se volteó
--   disponibles            security_invoker = on    ← correcto (lee de existencias y hereda)
--   por_reordenar          security_invoker = on    ← correcto
--
-- POR QUÉ IMPORTA. Las dos volteadas llevan su propio candado adentro
-- (`where mi_rol() in ('admin','tecnico')`, y en el resguardo una rama para
-- `mi_rol() = 'cliente' and m.cliente_id = mi_cliente()`). Ese candado solo tiene sentido en
-- una vista definer: es lo que reemplaza a RLS cuando la vista se salta RLS. En modo invoker
-- se aplica además la RLS de las tablas de abajo, y `productos` tiene UNA sola política:
--
--   create policy admin_productos on public.productos ... using (es_admin())
--
-- así que **quien no es admin ve las dos vistas VACÍAS**. No hay error, no hay permiso
-- denegado: cero filas. La rama de `cliente` del resguardo no puede dispararse nunca.
--
-- HOY NO SE NOTA porque ninguna pantalla las lee: el código solo usa `disponibles`
-- (Cotizaciones e Inventario, las dos de admin) y `existencias` (Almacén y el buscador de
-- "Pedir material" del técnico), y `existencias` sigue en definer e incluye al almacenista.
-- Se notaría en dos lugares en cuanto se avance:
--   · la Edge Function `agente` consulta `catalogo` y `resguardo_por_cliente`; con el admin
--     funciona (el admin sí lee `productos`), pero un técnico que la llamara directo
--     recibiría listas vacías sin enterarse;
--   · el portal del cliente, cuando exista, vería su resguardo vacío.
--
-- CAUSA PROBABLE. El asesor de Supabase marca las vistas definer como "Security Definer
-- View" y ofrece un botón de arreglo. CLAUDE.md advierte de no usarlo justamente porque
-- **deja al técnico sin existencias ni catálogo**; parece que se usó en dos de las tres.
-- Si el aviso vuelve a aparecer, es esperado: esas vistas están así a propósito.
--
-- `create or replace view` NO cambia el modo: hace falta `alter view ... set`. Por eso este
-- script no toca las definiciones, solo el modo. Es repetible: volver a correrlo no hace nada.
-- ---------------------------------------------------------------------------

alter view public.catalogo               set (security_invoker = off);
alter view public.resguardo_por_cliente  set (security_invoker = off);

-- No se toca: ya estaba bien. Se deja escrito para que el trío quede junto en un solo lugar
-- y la próxima vez se vea de un golpe cuál debe estar en qué modo.
alter view public.existencias            set (security_invoker = off);

-- `disponibles` y `por_reordenar` se quedan en invoker: leen de `existencias`, que ya se
-- salta RLS, así que heredan el acceso sin necesitar candado propio.

-- Comprobación: las tres primeras deben decir `off`, las dos últimas `on`.
select c.relname as vista,
       coalesce(
         (select o from unnest(c.reloptions) o where o like 'security_invoker%'),
         'security_invoker=off (por omisión)') as modo
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('existencias', 'catalogo', 'resguardo_por_cliente', 'disponibles', 'por_reordenar')
order by c.relname;
