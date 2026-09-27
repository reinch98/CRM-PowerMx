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
-- NO TOCA `perfiles`. La prueba 30 sí le cambiaba el rol a una persona real y dependía del
-- `rollback` para devolverlo; aquí no se repite. Lo que sí hace es **fabricar su propio
-- resguardo** —dos movimientos `a_resguardo`, uno del cliente de la prueba y otro de OTRO
-- cliente— porque al 26/09/2026 la base no tiene ninguno y sin datos de dos clientes
-- distintos el filtro no se puede comprobar. Todo eso se va con el `rollback`.
--
-- REQUISITO: el perfil con rol `cliente` tiene que tener `cliente_id`. Se asigna en la
-- pantalla Usuarios (con rol "Cliente" aparece un selector de cliente). Si está vacío, la
-- prueba lo dice y se detiene antes de fingir un resultado.
--
-- Correr el bloque COMPLETO, de `begin;` a `rollback;`.
-- ---------------------------------------------------------------------------

begin;

do $$
declare
  v_cliente_perfil uuid;
  v_cliente_id     uuid;
  v_otro_cliente   uuid;
  v_producto       uuid;
  v_n              int;
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
      'mi_cliente() devuelve null y verá 0 en todo. Asignarlo en la pantalla Usuarios ',
      '(rol "Cliente" muestra un selector) y repetir. Sin eso la prueba no concluye.'), true);
    return;
  end if;
  perform set_config('app.p0', concat('ok — perfil cliente ligado al cliente ', v_cliente_id::text), true);

  -- El escenario: hace falta OTRO cliente y un producto para poder fabricar resguardo de dos
  -- clientes distintos. Sin los dos, el filtro no se puede comprobar.
  select id into v_otro_cliente from clientes where id is distinct from v_cliente_id limit 1;
  select id into v_producto from productos limit 1;
  if v_otro_cliente is null or v_producto is null then
    perform set_config('app.p1',
      '⚠ sin concluir — hace falta otro cliente y al menos un producto para fabricar el escenario', true);
    return;
  end if;

  -- Resguardo de prueba: 2 piezas en poder del cliente de la prueba y 5 en poder de otro. Se
  -- inserta con `insert` directo porque el editor se salta la RLS; se va con el `rollback`.
  insert into movimientos_inventario (id, tipo, cantidad, cliente_id, producto_id, referencia, notas, created_at)
  values (gen_random_uuid(), 'a_resguardo', 2, v_cliente_id,   v_producto, 'PRUEBA-33', 'prueba del rol cliente', now()),
         (gen_random_uuid(), 'a_resguardo', 5, v_otro_cliente, v_producto, 'PRUEBA-33', 'prueba del rol cliente', now());
  perform set_config('app.p1', concat('escenario listo — 2 piezas en resguardo del cliente de la prueba y ',
                                      '5 de otro cliente (', v_otro_cliente::text, ')'), true);

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
  -- Ya se sabe que está ligado (si no, la prueba se detuvo arriba), así que aquí debe ver
  -- exactamente una: la suya. Ver 0 sería un filtro roto y ver 2 o más, una fuga.
  execute 'select count(*) from clientes' into v_n;
  perform set_config('app.p5', concat(case when v_n = 1 then 'ok' else 'FALLO' end,
    ' — el cliente ve ', v_n, ' ficha(s) en clientes (debe ver exactamente 1, la suya)'), true);

  -- 5) Las cotizaciones son de la oficina.
  execute 'select count(*) from cotizaciones' into v_n;
  perform set_config('app.p6', concat(case when v_n = 0 then 'ok' else 'FALLO' end,
    ' — el cliente ve ', v_n, ' en cotizaciones (debe ser 0)'), true);

  -- 6) LA PRUEBA QUE FALTABA: su resguardo, y SOLO el suyo. Hay resguardo de dos clientes,
  --    así que ahora sí distingue entre "el filtro funciona" y "no hay nada que ver".
  execute 'select count(*) from resguardo_por_cliente' into v_n;
  execute format('select count(*) from resguardo_por_cliente where cliente_id is distinct from %L', v_cliente_id)
    into v_otros;
  perform set_config('app.p7', concat(
    case when v_n > 0 and v_otros = 0 then 'ok' else 'FALLO' end,
    ' — el cliente ve ', v_n, ' renglón(es) en resguardo_por_cliente, ', v_otros,
    ' de otros clientes (debe ver lo suyo y 0 de otros)'), true);

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
