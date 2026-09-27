-- ---------------------------------------------------------------------------
-- Prueba de 30_modo_vistas.sql. Corre el bloque COMPLETO en el editor SQL de Supabase.
-- Todo va dentro de begin/rollback: no cambia nada (el DDL en Postgres también se revierte).
--
-- Lo que demuestra: con `catalogo` en modo invoker, un técnico de verdad ve CERO filas; con
-- el modo devuelto a definer, las ve. Sin esta prueba el arreglo sería un acto de fe, porque
-- el síntoma no es un error sino una lista vacía.
--
-- Después de aplicar el script de verdad, los pasos 2 y 4 darán los dos "ve N": eso también
-- es correcto. Lo que nunca debe pasar es que el paso 4 dé 0.
--
-- ⚠ CORRER EL BLOQUE COMPLETO, de `begin;` a `rollback;`, de una sola vez. Los pasos 5 a 7
-- le cambian el rol a un perfil REAL (la base solo tiene un técnico, así que se reutiliza ese
-- en vez de inventar uno). El `rollback` lo deja como estaba; una línea suelta, no.
--
-- Si el editor no muestra la tabla de resultados, es porque solo enseña la última sentencia:
-- correr el bloque sin la línea final `rollback;` y mandar `rollback;` aparte.
-- ---------------------------------------------------------------------------

begin;

do $$
declare
  v_tecnico uuid;
  v_n       int;
  v_modo    text;
begin
  -- Un técnico de verdad de la base. Si no hay ninguno, la prueba no puede concluir.
  select id into v_tecnico from perfiles where rol = 'tecnico' and coalesce(activo, true) limit 1;
  if v_tecnico is null then
    perform set_config('app.p0', 'FALLO: no hay ningún técnico activo en perfiles', true);
    return;
  end if;
  perform set_config('app.p0', concat('ok — técnico de prueba: ', v_tecnico::text), true);

  -- Paso 1: el modo en el que está ahora mismo.
  select coalesce((select o from unnest(c.reloptions) o where o like 'security_invoker%'),
                  'security_invoker=off (por omisión)')
    into v_modo
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'catalogo';
  perform set_config('app.p1', concat('catalogo antes: ', v_modo), true);

  -- Paso 2: cuántas filas ve el técnico ANTES.
  perform set_config('request.jwt.claims', json_build_object('sub', v_tecnico, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  execute 'select count(*) from catalogo' into v_n;
  execute 'reset role';
  perform set_config('app.p2', concat('el técnico ve ', v_n, ' en catalogo antes'), true);

  -- Paso 3: el arreglo.
  execute 'alter view public.catalogo set (security_invoker = off)';
  execute 'alter view public.resguardo_por_cliente set (security_invoker = off)';
  perform set_config('app.p3', 'ok — modo devuelto a definer', true);

  -- Paso 4: lo que ve el técnico DESPUÉS. Esto es lo que importa.
  execute 'set local role authenticated';
  execute 'select count(*) from catalogo' into v_n;
  execute 'reset role';
  perform set_config('app.p4',
    concat(case when v_n > 0 then 'ok' else 'FALLO' end,
           ' — el técnico ve ', v_n, ' en catalogo después'), true);

  -- Paso 5: el candado de la vista sigue puesto. Una cuenta SIN rol no debe ver nada, aunque
  -- la vista ahora se salte RLS: eso es lo que hace `where mi_rol() in ('admin','tecnico')`.
  -- Sin este paso, "arreglar" el modo podría estar abriendo los datos a cualquiera.
  update perfiles set rol = 'sin_rol' where id = v_tecnico;
  execute 'set local role authenticated';
  execute 'select count(*) from catalogo' into v_n;
  execute 'reset role';
  perform set_config('app.p5',
    concat(case when v_n = 0 then 'ok' else 'FALLO' end,
           ' — una cuenta sin rol ve ', v_n, ' en catalogo'), true);

  -- Paso 6: el almacenista NO debe ver el catálogo (ahí van los precios), aunque sí las
  -- existencias. Es la promesa de que el almacén nunca ve precios ni costos.
  update perfiles set rol = 'almacenista' where id = v_tecnico;
  execute 'set local role authenticated';
  execute 'select count(*) from catalogo' into v_n;
  execute 'reset role';
  perform set_config('app.p6',
    concat(case when v_n = 0 then 'ok' else 'FALLO' end,
           ' — el almacenista ve ', v_n, ' en catalogo (debe ser 0: ahí están los precios)'), true);

  execute 'set local role authenticated';
  execute 'select count(*) from existencias' into v_n;
  execute 'reset role';
  perform set_config('app.p7',
    concat(case when v_n > 0 then 'ok' else 'FALLO' end,
           ' — el almacenista ve ', v_n, ' en existencias (debe ver: es su pantalla)'), true);
end $$;

select current_setting('app.p0', true) as paso_0
union all select current_setting('app.p1', true)
union all select current_setting('app.p2', true)
union all select current_setting('app.p3', true)
union all select current_setting('app.p4', true)
union all select current_setting('app.p5', true)
union all select current_setting('app.p6', true)
union all select current_setting('app.p7', true);

rollback;
