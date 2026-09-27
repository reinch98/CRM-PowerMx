-- ---------------------------------------------------------------------------
-- 33_prueba_rol_cliente.sql — lo que ve (y lo que no) una cuenta con rol `cliente`.
-- Lo que falta probar es la rama de cliente de `resguardo_por_cliente`, que nunca se ha
-- ejecutado. El razonamiento completo está en CLAUDE.md ("Cerrar seguridad de datos").
--
-- SIN BLOQUE plpgsql, A PROPÓSITO: el editor de Supabase mutila los bloques con comillas de
-- dólar (ver "Pruebas en el editor SQL" en CLAUDE.md). Todo es SQL plano y los resultados se
-- cargan en `app.*` con `set_config`, que es el patrón que ya usa el proyecto. En este archivo
-- no aparece ni una comilla de dólar, ni siquiera en los comentarios.
--
-- Fabrica lo que le falta (el cliente de prueba, el enlace del perfil y resguardo de dos
-- clientes) y lo DESHACE al final, además del `rollback`. Correr el bloque COMPLETO.
-- ---------------------------------------------------------------------------

begin;

-- El perfil cliente y un producto cualquiera. Vacío = no hay.
select set_config('app.perfil',
         coalesce((select id::text from perfiles where rol = 'cliente' and coalesce(activo, true) limit 1), ''), true),
       set_config('app.producto',
         coalesce((select id::text from productos limit 1), ''), true);

-- Su cliente actual (puede venir vacío: es justo el caso que hay hoy).
select set_config('app.cliente',
         coalesce((select cliente_id::text from perfiles
                   where id = nullif(current_setting('app.perfil'), '')::uuid), ''), true);

select set_config('app.ligue',
         case when nullif(current_setting('app.perfil'), '') is null then 'no'
              when current_setting('app.cliente') = '' then 'si' else 'no' end, true);

select set_config('app.p0',
         case when nullif(current_setting('app.perfil'), '') is null
                then 'FALLO: no hay ningún perfil con rol cliente'
              when nullif(current_setting('app.producto'), '') is null
                then 'FALLO: no hay productos, no se puede fabricar resguardo'
              when current_setting('app.ligue') = 'si'
                then 'ok — el perfil no estaba ligado: se liga a un cliente de prueba solo en esta transacción'
              else concat('ok — ya estaba ligado al cliente ', current_setting('app.cliente'),
                          '; no se toca nada') end, true);

-- Si no estaba ligado, se inventa el cliente de prueba y se liga.
select set_config('app.cliente',
         case when current_setting('app.ligue') = 'si' then gen_random_uuid()::text
              else current_setting('app.cliente') end, true);

insert into clientes (id, nombre, telefono)
select current_setting('app.cliente')::uuid, 'Cliente de prueba (33)', '9990000033'
where current_setting('app.ligue') = 'si';

update perfiles set cliente_id = current_setting('app.cliente')::uuid
where current_setting('app.ligue') = 'si'
  and id = nullif(current_setting('app.perfil'), '')::uuid;

-- El OTRO cliente: sin él, un 0 no distingue "el filtro funciona" de "no hay nada que ver".
select set_config('app.otro',
         coalesce((select id::text from clientes
                   where id is distinct from nullif(current_setting('app.cliente'), '')::uuid
                   limit 1), ''), true);
select set_config('app.otro',
         case when current_setting('app.otro') = '' then gen_random_uuid()::text
              else current_setting('app.otro') end, true);

insert into clientes (id, nombre, telefono)
select current_setting('app.otro')::uuid, 'Otro cliente de prueba (33)', '9990000034'
where not exists (select 1 from clientes where id = nullif(current_setting('app.otro'), '')::uuid);

-- Resguardo de los dos: 2 piezas en poder del cliente de la prueba, 5 en poder del otro.
insert into movimientos_inventario
  (id, tipo, cantidad, cliente_id, producto_id, referencia, notas, created_at)
select gen_random_uuid(), 'a_resguardo', d.cantidad, d.cliente,
       nullif(current_setting('app.producto'), '')::uuid, 'PRUEBA-33', 'prueba del rol cliente', now()
from (values (2::numeric, nullif(current_setting('app.cliente'), '')::uuid),
             (5::numeric, nullif(current_setting('app.otro'), '')::uuid)) as d(cantidad, cliente)
where d.cliente is not null
  and nullif(current_setting('app.producto'), '') is not null;

select set_config('app.p1', 'escenario listo — resguardo de 2 clientes distintos', true);

-- ---- de aquí en adelante se lee COMO EL CLIENTE ----
select set_config('request.jwt.claims',
         json_build_object('sub', current_setting('app.perfil'), 'role', 'authenticated')::text, true);

set local role authenticated;

-- El catálogo lleva precios: solo abre a admin y técnico.
select set_config('app.p2', concat(
         case when (select count(*) from catalogo) = 0 then 'ok' else 'FALLO' end,
         ' — el cliente ve ', (select count(*) from catalogo),
         ' en catalogo (debe ser 0: ahí están los precios)'), true);

-- `productos` además trae `costo`.
select set_config('app.p3', concat(
         case when (select count(*) from productos) = 0 then 'ok' else 'FALLO' end,
         ' — el cliente ve ', (select count(*) from productos),
         ' en productos (debe ser 0: ahí está el costo)'), true);

-- Cuánto material hay en el almacén no es asunto suyo.
select set_config('app.p4', concat(
         case when (select count(*) from existencias) = 0 then 'ok' else 'FALLO' end,
         ' — el cliente ve ', (select count(*) from existencias), ' en existencias (debe ser 0)'), true);

-- De `clientes`, solo su ficha: 0 sería un filtro roto y 2 o más una fuga.
select set_config('app.p5', concat(
         case when (select count(*) from clientes) = 1 then 'ok' else 'FALLO' end,
         ' — el cliente ve ', (select count(*) from clientes),
         ' ficha(s) en clientes (debe ver exactamente 1, la suya)'), true);

-- Las cotizaciones son de la oficina.
select set_config('app.p6', concat(
         case when (select count(*) from cotizaciones) = 0 then 'ok' else 'FALLO' end,
         ' — el cliente ve ', (select count(*) from cotizaciones), ' en cotizaciones (debe ser 0)'), true);

-- LA QUE FALTABA: su resguardo, y solo el suyo.
select set_config('app.p7', concat(
         case when (select count(*) from resguardo_por_cliente) = 1
               and (select count(*) from resguardo_por_cliente
                    where cliente_id is distinct from nullif(current_setting('app.cliente'), '')::uuid) = 0
              then 'ok' else 'FALLO' end,
         ' — el cliente ve ', (select count(*) from resguardo_por_cliente),
         ' renglón(es) en resguardo_por_cliente y ',
         (select count(*) from resguardo_por_cliente
          where cliente_id is distinct from nullif(current_setting('app.cliente'), '')::uuid),
         ' de otros clientes (debe ver 1, el suyo, y 0 de otros)'), true);

reset role;

-- ---- deshacer a mano lo que se tocó de una fila real ----
update perfiles set cliente_id = null
where current_setting('app.ligue') = 'si'
  and id = nullif(current_setting('app.perfil'), '')::uuid;

select set_config('app.p8',
         case when current_setting('app.ligue') = 'si'
              then 'ok — el enlace temporal se deshizo a mano (además del rollback)'
              else 'ok — no se tocó ninguna fila real' end, true);

select current_setting('app.p0', true) as resultado
union all select current_setting('app.p1', true)
union all select current_setting('app.p2', true)
union all select current_setting('app.p3', true)
union all select current_setting('app.p4', true)
union all select current_setting('app.p5', true)
union all select current_setting('app.p6', true)
union all select current_setting('app.p7', true)
union all select current_setting('app.p8', true);

rollback;
