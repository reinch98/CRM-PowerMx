-- ===========================================================================
-- VISTAS POR ROL
--
-- Estado real, comprobado en la base (19/09/2026): las cinco vistas tenían
-- security_invoker = on, o sea que corren con los permisos de quien consulta.
-- Con eso las políticas sí se aplican, pero `productos` solo la lee el admin:
-- al técnico le salían vacías Existencias y el catálogo (y con ellas las
-- herramientas del agente). El modo invoker vino, casi seguro, del botón de
-- arreglo del asesor de seguridad de Supabase ("Security Definer View").
--
-- Solución: las tres vistas que leen `productos` pasan a modo definer (corren
-- con los permisos de su dueño) y se cierran ellas mismas con mi_rol(), que
-- lee auth.uid() del token de la petición y funciona igual en ese modo.
--
--   existencias, resguardo_por_cliente, catalogo → definer + filtro por rol
--   disponibles, por_reordenar → siguen en invoker: solo leen `existencias`,
--                                que ya tiene el filtro, y heredan su resultado
--
--   admin, tecnico  → ven todo
--   cliente         → nada de inventario ni catálogo; en resguardo, solo lo suyo
--   sin_rol         → nada
--
-- El asesor de Supabase va a marcar esas tres vistas como "Security Definer
-- View". Es a propósito: no usar su botón de arreglo, rompe al técnico. La
-- alternativa limpia (mover `costo` a una tabla solo-admin y dejar todo en
-- invoker) está en la ruta de mejora del CLAUDE.md.
--
-- Se puede volver a ejecutar sin problema.
-- ===========================================================================

create or replace view existencias as
select p.id,
    p.sku,
    p.categoria,
    p.nombre,
    p.marca,
    p.unidad,
    p.minimo,
    coalesce(sum(
        case m.tipo
            when 'entrada'::text then m.cantidad
            when 'salida_venta'::text then (- m.cantidad)
            when 'consumo_resguardo'::text then (- m.cantidad)
            when 'consumo_servicio'::text then (- m.cantidad)
            when 'ajuste'::text then m.cantidad
            else (0)::numeric
        end), (0)::numeric) as fisico,
    coalesce(sum(
        case m.tipo
            when 'apartado'::text then m.cantidad
            when 'libera_apartado'::text then (- m.cantidad)
            when 'salida_venta'::text then (- m.cantidad)
            when 'a_resguardo'::text then (- m.cantidad)
            else (0)::numeric
        end), (0)::numeric) as apartado,
    coalesce(sum(
        case m.tipo
            when 'a_resguardo'::text then m.cantidad
            when 'consumo_resguardo'::text then (- m.cantidad)
            else (0)::numeric
        end), (0)::numeric) as resguardo
   from (productos p
     left join movimientos_inventario m on ((m.producto_id = p.id)))
  where p.activo
    and mi_rol() in ('admin', 'tecnico')
  group by p.id;

create or replace view resguardo_por_cliente as
select m.cliente_id,
    c.nombre as cliente,
    m.producto_id,
    p.sku,
    p.nombre as producto,
    sum(
        case m.tipo
            when 'a_resguardo'::text then m.cantidad
            when 'consumo_resguardo'::text then (- m.cantidad)
            else (0)::numeric
        end) as en_resguardo
   from ((movimientos_inventario m
     join productos p on ((p.id = m.producto_id)))
     join clientes c on ((c.id = m.cliente_id)))
  where (m.tipo = any (array['a_resguardo'::text, 'consumo_resguardo'::text]))
    and (mi_rol() in ('admin', 'tecnico')
         or (mi_rol() = 'cliente' and m.cliente_id = mi_cliente()))
  group by m.cliente_id, c.nombre, m.producto_id, p.sku, p.nombre
 having (sum(
        case m.tipo
            when 'a_resguardo'::text then m.cantidad
            else (- m.cantidad)
        end) > (0)::numeric);

-- catalogo: mismas columnas que en 03_roles.sql (sin costo), ahora con filtro.
create or replace view catalogo as
select id, sku, categoria, nombre, marca, modelo, descripcion,
       precio, precios, unidad, minimo, atributos, clave_producto_sat, clave_unidad_sat
from productos
where activo
  and mi_rol() in ('admin', 'tecnico');

-- create or replace NO cambia el modo de la vista: hay que pedirlo aparte.
alter view existencias           set (security_invoker = off);
alter view resguardo_por_cliente set (security_invoker = off);
alter view catalogo              set (security_invoker = off);

-- Los permisos se reafirman por si acaso: solo lectura y solo con sesión.
revoke all on catalogo, existencias, disponibles, por_reordenar, resguardo_por_cliente
  from anon, authenticated;
grant select on catalogo, existencias, disponibles, por_reordenar, resguardo_por_cliente
  to authenticated;

-- ---------------------------------------------------------------------------
-- PRUEBA. En el SQL Editor, corre cada bloque por separado. Cambia el uuid por
-- el `id` de una cuenta de esa clase (select id, email, rol from perfiles).
-- Con `rollback` no queda nada cambiado.
--
-- 0) Modo de las vistas: existencias, resguardo_por_cliente y catalogo deben
--    salir SIN security_invoker; disponibles y por_reordenar, con él.
--   select relname, reloptions from pg_class
--   where relnamespace = 'public'::regnamespace
--     and relname in ('existencias','resguardo_por_cliente','catalogo','disponibles','por_reordenar');
--
-- 1) Técnico: existencias y catálogo iguales a lo que ve el admin (no 0).
--   begin;
--   set local role authenticated;
--   select set_config('request.jwt.claims',
--     json_build_object('sub', '<UUID-DE-UN-TECNICO>', 'role', 'authenticated')::text, true);
--   select mi_rol(),
--          (select count(*) from disponibles)           as disponibles,
--          (select count(*) from catalogo)              as catalogo,
--          (select count(*) from resguardo_por_cliente) as resguardo,
--          (select count(*) from productos)             as productos_directo;  -- sigue en 0: costo cerrado
--   rollback;
--
-- 2) Cliente o cuenta sin rol (sirve un uuid inventado con formato válido):
--    todo en 0.
--   begin;
--   set local role authenticated;
--   select set_config('request.jwt.claims',
--     json_build_object('sub', '<UUID-DE-UN-CLIENTE>', 'role', 'authenticated')::text, true);
--   select mi_rol(),
--          (select count(*) from disponibles)           as disponibles,   -- 0
--          (select count(*) from catalogo)              as catalogo,      -- 0
--          (select count(*) from resguardo_por_cliente) as resguardo;     -- 0 o solo lo suyo
--   rollback;
--
-- 3) Sin sesión: debe fallar con "permission denied".
--   begin;
--   set local role anon;
--   select count(*) from disponibles;
--   rollback;
-- ---------------------------------------------------------------------------
