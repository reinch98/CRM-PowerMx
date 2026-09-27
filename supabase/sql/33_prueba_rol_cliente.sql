-- ---------------------------------------------------------------------------
-- 33_prueba_rol_cliente.sql — lo que ve (y lo que no) una cuenta con rol `cliente`.
--
-- POR QUÉ. `05_vistas_por_rol.sql` se probó el 19/09/2026 con admin, técnico y una cuenta sin
-- rol, pero **nunca con un cliente**: no había ninguno. Es lo último que falta del punto 1 de
-- la ruta de mejora.
--
-- LO QUE DE VERDAD FALTA PROBAR es la rama de cliente de `resguardo_por_cliente`:
--
--   where ... or (mi_rol() = 'cliente' and m.cliente_id = mi_cliente())
--
-- Esa condición **nunca se ha ejecutado**. Y tiene una trampa: si al perfil le falta
-- `cliente_id`, `mi_cliente()` devuelve null y el cliente ve 0 filas — exactamente lo mismo
-- que se vería si el filtro estuviera mal escrito. Un 0 ahí no prueba nada.
--
-- ES AUTOSUFICIENTE. Al 26/09/2026 el perfil cliente de la base no está ligado a ningún
-- cliente y no hay ni un movimiento `a_resguardo`, así que la prueba **fabrica lo que le
-- falta** dentro del `begin/rollback`: un cliente de prueba, el enlace del perfil y resguardo
-- de dos clientes distintos. Así se puede responder la pregunta de seguridad hoy, sin esperar
-- a que alguien decida a qué cliente real corresponde esa cuenta (eso es de `34_...`).
--
-- CÓMO SE CUIDA EL DATO REAL. La prueba 30 le cambió el rol a una persona real y dependía del
-- `rollback` para devolverlo; si esa ejecución se hubiera cerrado con un commit, el único
-- técnico habría quedado como almacenista sin que nadie lo supiera. Aquí:
--   · lo único que se toca de una fila real es `perfiles.cliente_id`, que hoy está en null;
--   · y se **deshace explícitamente al final**, además del `rollback`. Nada que toque una fila
--     real depende de una sola red de seguridad.
-- Si el perfil YA está ligado (después de correr el 34), la prueba lo usa tal cual y no toca
-- `perfiles` para nada.
--
-- Correr el bloque COMPLETO, de `begin;` a `rollback;`.
-- ---------------------------------------------------------------------------

begin;

do $$
declare
  v_perfil       uuid;
  v_cliente      uuid;
  v_otro         uuid;
  v_producto     uuid;
  v_lo_ligue     boolean := false;
  v_n            int;
  v_otros        int;
begin
  select id, cliente_id into v_perfil, v_cliente
  from perfiles where rol = 'cliente' and coalesce(activo, true) limit 1;

  if v_perfil is null then
    perform set_config('app.p0', 'FALLO: no hay ningún perfil con rol cliente', true);
    return;
  end if;

  select id into v_producto from productos limit 1;
  if v_producto is null then
    perform set_config('app.p0', 'FALLO: no hay productos, no se puede fabricar resguardo', true);
    return;
  end if;

  if v_cliente is null then
    -- Cliente de prueba y enlace temporal. `clientes` exige nombre y teléfono.
    insert into clientes (id, nombre, telefono)
    values (gen_random_uuid(), 'Cliente de prueba (33)', '9990000033')
    returning id into v_cliente;
    update perfiles set cliente_id = v_cliente where id = v_perfil;
    v_lo_ligue := true;
    perform set_config('app.p0', concat('ok — el perfil no estaba ligado, así que se ligó a un ',
      'cliente de prueba solo durante esta transacción (se deshace al final)'), true);
  else
    perform set_config('app.p0', concat('ok — el perfil ya estaba ligado al cliente ',
      v_cliente::text, '; no se toca nada'), true);
  end if;

  -- El otro cliente, para tener con qué comparar. Si no hay, se crea.
  select id into v_otro from clientes where id is distinct from v_cliente limit 1;
  if v_otro is null then
    insert into clientes (id, nombre, telefono)
    values (gen_random_uuid(), 'Otro cliente de prueba (33)', '9990000034')
    returning id into v_otro;
  end if;

  -- Resguardo de los dos: 2 piezas en poder del cliente de la prueba, 5 en poder del otro.
  insert into movimientos_inventario (id, tipo, cantidad, cliente_id, producto_id, referencia, notas, created_at)
  values (gen_random_uuid(), 'a_resguardo', 2, v_cliente, v_producto, 'PRUEBA-33', 'prueba del rol cliente', now()),
         (gen_random_uuid(), 'a_resguardo', 5, v_otro,    v_producto, 'PRUEBA-33', 'prueba del rol cliente', now());
  perform set_config('app.p1', 'escenario listo — resguardo de 2 clientes distintos', true);

  -- ---- a partir de aquí, todo se lee COMO EL CLIENTE ----
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_perfil, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- 1) El catálogo lleva precios: el cliente no lo ve (`catalogo` solo abre a admin y técnico).
  execute 'select count(*) from catalogo' into v_n;
  perform set_config('app.p2', concat(case when v_n = 0 then 'ok' else 'FALLO' end,
    ' — el cliente ve ', v_n, ' en catalogo (debe ser 0: ahí están los precios)'), true);

  -- 2) Tampoco `productos`, que además trae `costo`.
  execute 'select count(*) from productos' into v_n;
  perform set_config('app.p3', concat(case when v_n = 0 then 'ok' else 'FALLO' end,
    ' — el cliente ve ', v_n, ' en productos (debe ser 0: ahí está el costo)'), true);

  -- 3) Ni existencias: cuánto material hay en el almacén no es asunto suyo.
  execute 'select count(*) from existencias' into v_n;
  perform set_config('app.p4', concat(case when v_n = 0 then 'ok' else 'FALLO' end,
    ' — el cliente ve ', v_n, ' en existencias (debe ser 0)'), true);

  -- 4) De `clientes`, solo su propia ficha (política `cliente_ve_lo_suyo`). Ver 0 sería un
  --    filtro roto; ver 2 o más, una fuga.
  execute 'select count(*) from clientes' into v_n;
  perform set_config('app.p5', concat(case when v_n = 1 then 'ok' else 'FALLO' end,
    ' — el cliente ve ', v_n, ' ficha(s) en clientes (debe ver exactamente 1, la suya)'), true);

  -- 5) Las cotizaciones son de la oficina.
  execute 'select count(*) from cotizaciones' into v_n;
  perform set_config('app.p6', concat(case when v_n = 0 then 'ok' else 'FALLO' end,
    ' — el cliente ve ', v_n, ' en cotizaciones (debe ser 0)'), true);

  -- 6) LA QUE FALTABA: su resguardo, y SOLO el suyo. Hay resguardo de dos clientes, así que
  --    ahora sí se distingue "el filtro funciona" de "no hay nada que ver".
  execute 'select count(*) from resguardo_por_cliente' into v_n;
  execute format('select count(*) from resguardo_por_cliente where cliente_id is distinct from %L', v_cliente)
    into v_otros;
  perform set_config('app.p7', concat(
    case when v_n = 1 and v_otros = 0 then 'ok' else 'FALLO' end,
    ' — el cliente ve ', v_n, ' renglón(es) en resguardo_por_cliente y ', v_otros,
    ' de otros clientes (debe ver 1, el suyo, y 0 de otros)'), true);

  execute 'reset role';

  -- ---- deshacer a mano lo que se tocó de una fila real ----
  if v_lo_ligue then
    update perfiles set cliente_id = null where id = v_perfil;
    perform set_config('app.p8', 'ok — el enlace temporal del perfil se deshizo a mano (además del rollback)', true);
  else
    perform set_config('app.p8', 'ok — no se tocó ninguna fila real', true);
  end if;
end $$;

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
