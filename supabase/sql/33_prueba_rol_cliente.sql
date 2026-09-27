-- ---------------------------------------------------------------------------
-- 33_prueba_rol_cliente.sql — lo que ve (y lo que no) una cuenta con rol `cliente`.
--
-- POR QUÉ AHORA. `05_vistas_por_rol.sql` se probó el 19/09/2026 con admin, técnico y una
-- cuenta sin rol, pero **nunca con un cliente**: no había ninguno. Al 26/09/2026 la base ya
-- tiene un perfil con rol `cliente`, así que se puede cerrar el punto 1 de la ruta de mejora
-- sin esperar al portal.
--
-- LO QUE DE VERDAD FALTA PROBAR es la rama de cliente de `resguardo_por_cliente`:
--
--   where ... or (mi_rol() = 'cliente' and m.cliente_id = mi_cliente())
--
-- Esa condición **nunca se ha ejecutado**. Y tiene una trampa: si al perfil le falta
-- `cliente_id`, `mi_cliente()` no devuelve nada y el cliente ve 0 filas — que es lo mismo que
-- se vería si el filtro estuviera mal escrito. Un 0 aquí no prueba nada, así que la prueba
-- distingue los dos casos en vez de cantar victoria.
--
-- NO TOCA `perfiles` NI NINGUNA TABLA. Solo lee, con el rol simulado. (La prueba 30 sí le
-- cambiaba el rol a una persona real y dependía del `rollback` para devolverlo; no repetir
-- eso: si hace falta un rol distinto, se crea un perfil desechable como en la prueba de la 19.)
--
-- Correr el bloque COMPLETO, de `begin;` a `rollback;`.
-- ---------------------------------------------------------------------------

begin;

do $$
declare
  v_cliente_perfil uuid;
  v_cliente_id     uuid;
  v_n              int;
  v_total          int;
  v_otros          int;
begin
  select id, cliente_id into v_cliente_perfil, v_cliente_id
  from perfiles where rol = 'cliente' and coalesce(activo, true) limit 1;

  if v_cliente_perfil is null then
    perform set_config('app.p0', 'FALLO: no hay ningún perfil con rol cliente', true);
    return;
  end if;

  if v_cliente_id is null then
    perform set_config('app.p0', concat(
      '⚠ el perfil cliente ', v_cliente_perfil::text, ' NO tiene cliente_id: ',
      'mi_cliente() devuelve null y verá 0 en todo. Asignarlo en Usuarios y repetir; ',
      'sin eso la prueba del resguardo no concluye.'), true);
  else
    perform set_config('app.p0', concat('ok — perfil cliente ligado al cliente ', v_cliente_id::text), true);
  end if;

  -- Cuánto resguardo hay, leído de la TABLA y no de la vista. Ojo: `resguardo_por_cliente` es
  -- definer y lleva su propio `where mi_rol() in (...)`, así que también le cierra la puerta al
  -- editor mientras no haya claims puestas — consultarla aquí daría 0 y haría creer que no hay
  -- nada con qué comparar. El rol `postgres` de Supabase sí se salta la RLS de las tablas.
  select count(distinct cliente_id) into v_total
  from movimientos_inventario where tipo = 'a_resguardo' and cliente_id is not null;
  select count(distinct cliente_id) into v_otros
  from movimientos_inventario
  where tipo = 'a_resguardo' and cliente_id is not null and cliente_id is distinct from v_cliente_id;
  perform set_config('app.p1', concat('hay resguardo de ', v_total, ' cliente(s), ',
                                      v_otros, ' de ellos distintos del de esta prueba'), true);

  -- A partir de aquí, todo se lee COMO EL CLIENTE.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_cliente_perfil, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- 1) El catálogo lleva precios: el cliente no lo ve. (`catalogo` solo abre a admin y técnico.)
  execute 'select count(*) from catalogo' into v_n;
  perform set_config('app.p2', concat(case when v_n = 0 then 'ok' else 'FALLO' end,
    ' — el cliente ve ', v_n, ' en catalogo (debe ser 0: ahí están los precios)'), true);

  -- 2) Tampoco `productos`, que además trae `costo`.
  execute 'select count(*) from productos' into v_n;
  perform set_config('app.p3', concat(case when v_n = 0 then 'ok' else 'FALLO' end,
    ' — el cliente ve ', v_n, ' en productos (debe ser 0: ahí está el costo)'), true);

  -- 3) Ni existencias ni disponibles: cuánto material hay en el almacén no es asunto suyo.
  execute 'select count(*) from existencias' into v_n;
  perform set_config('app.p4', concat(case when v_n = 0 then 'ok' else 'FALLO' end,
    ' — el cliente ve ', v_n, ' en existencias (debe ser 0)'), true);

  -- 4) De `clientes` solo su propia ficha (política `cliente_ve_lo_suyo`).
  execute 'select count(*) from clientes' into v_n;
  perform set_config('app.p5', concat(case when v_n <= 1 then 'ok' else 'FALLO' end,
    ' — el cliente ve ', v_n, ' ficha(s) en clientes (debe ver 1, la suya, o 0 si no está ligado)'), true);

  -- 5) Las cotizaciones son de la oficina.
  execute 'select count(*) from cotizaciones' into v_n;
  perform set_config('app.p6', concat(case when v_n = 0 then 'ok' else 'FALLO' end,
    ' — el cliente ve ', v_n, ' en cotizaciones (debe ser 0)'), true);

  -- 6) LA PRUEBA QUE FALTABA: su resguardo, y SOLO el suyo.
  execute 'select count(*) from resguardo_por_cliente' into v_n;
  if v_cliente_id is null then
    perform set_config('app.p7', concat('⚠ sin concluir — el cliente ve ', v_n,
      ' en resguardo_por_cliente, pero su perfil no tiene cliente_id: un 0 aquí no prueba el filtro'), true);
  elsif v_total = 0 then
    perform set_config('app.p7', '⚠ sin concluir — no hay ningún movimiento a_resguardo en la base todavía', true);
  elsif v_otros = 0 then
    perform set_config('app.p7', concat('⚠ sin concluir — el cliente ve ', v_n,
      ', pero no hay resguardo de OTROS clientes con el que comparar'), true);
  else
    -- Hay resguardo de otros: si viera más que lo suyo, el filtro estaría abierto.
    execute format('select count(*) from resguardo_por_cliente where cliente_id is distinct from %L', v_cliente_id) into v_otros;
    perform set_config('app.p7', concat(case when v_otros = 0 then 'ok' else 'FALLO' end,
      ' — el cliente ve ', v_n, ' renglones en resguardo_por_cliente y ', v_otros,
      ' de otros clientes (debe ser 0)'), true);
  end if;

  execute 'reset role';
end $$;

select current_setting('app.p0', true) as resultado
union all select current_setting('app.p1', true)
union all select current_setting('app.p2', true)
union all select current_setting('app.p3', true)
union all select current_setting('app.p4', true)
union all select current_setting('app.p5', true)
union all select current_setting('app.p6', true)
union all select current_setting('app.p7', true);

rollback;
