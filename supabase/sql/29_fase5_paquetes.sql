-- ===========================================================================
-- FASE 5 · EL PAQUETE SE APRENDE Y PRECARGA EL SURTIDO
--
-- Dos cosas que el plan dejó para el final porque exigían que las piezas usadas quedaran
-- estructuradas. Ya lo están desde la 18 (`orden_surtido.cantidad_usada`).
--
-- 1. **Precargar el surtido de una póliza.** Una cita de póliza abre orden **sin
--    cotización** (regla de la 1c), así que hoy el almacén no tiene nada que preparar: la
--    lista de surtido se arma de las partidas de la cotización aceptada. Aquí el paquete
--    del equipo hace ese trabajo.
--
-- 2. **Aprender de lo que de verdad se usó.** En vez de que alguien adivine qué lleva un
--    preventivo, se mira qué se consumió en las visitas cerradas de equipos parecidos y se
--    propone. **Solo propone**: quien decide sigue siendo una persona, porque una pieza que
--    se usó tres veces puede ser casualidad y no parte del mantenimiento.
--
-- **Por qué se reescribe `paquete_preventivo` (de la 28):** el almacén también necesita
-- saber qué piezas lleva un paquete, pero **no puede ver precios**. Si `surtido_desde_paquete`
-- llamara a `paquete_preventivo`, un almacenista chocaría con su `es_admin()` — y aflojarlo
-- le abriría los precios. Así que la parte común (qué códigos sirven para una línea y cuánto
-- hay de cada uno) se saca a funciones internas **sin precio**, y `paquete_preventivo` les
-- agrega el precio encima. Una sola lógica, dos puertas con permisos distintos.
--
-- Se puede repetir sin problema. Prueba: 29_prueba_fase5_paquetes.sql.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Qué paquete le toca a un equipo. Gana el específico: modelo, luego marca, luego clase.
-- ---------------------------------------------------------------------------
create or replace function _paquete_de_equipo(p_equipo uuid, p_tipo text) returns uuid
language sql stable security definer set search_path = public as $$
  select p.id
    from paquetes_mantenimiento p, equipos e
   where e.id = p_equipo
     and p.activo and p.tipo = p_tipo
     and (p.marca is null or lower(p.marca) = lower(coalesce(e.marca, '')))
     and (p.modelo is null or lower(p.modelo) = lower(coalesce(e.modelo, '')))
     and (p.clase is null or p.clase = _clase_de_equipo(e))
     and (p.kw_desde is null or _capacidad_de_equipo(e) >= p.kw_desde)
     and (p.kw_hasta is null or _capacidad_de_equipo(e) <= p.kw_hasta)
   order by (p.modelo is not null) desc, (p.marca is not null) desc,
            (p.clase is not null) desc, p.kw_desde desc nulls last
   limit 1
$$;
revoke all on function _paquete_de_equipo(uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Los códigos que sirven para una línea: el producto de cabecera y todo lo que comparta su
-- grupo equivalente, con lo disponible de cada uno. **Sin precio**: esto lo lee el almacén.
-- ---------------------------------------------------------------------------
create or replace function _codigos_de_linea(p_linea uuid)
returns table (producto_id uuid, sku text, nombre text, unidad text,
               disponible numeric, preferido boolean)
language sql stable security definer set search_path = public as $$
  select pr.id, pr.sku, pr.nombre, pr.unidad,
         coalesce(d.disponible, 0), pr.id = l.producto_id
    from paquete_lineas l
    join productos pr
      on pr.id = l.producto_id
      or (l.grupo is not null and pr.grupo_equivalente = l.grupo)
      or (l.producto_id is not null and pr.grupo_equivalente is not null
          and pr.grupo_equivalente = (select grupo_equivalente from productos where id = l.producto_id))
    left join disponibles d on d.id = pr.id
   where l.id = p_linea
   order by (pr.id = l.producto_id) desc, coalesce(d.disponible, 0) desc
$$;
revoke all on function _codigos_de_linea(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- La de la 28, ahora apoyada en las dos de arriba. Misma respuesta, una sola lógica.
-- Sigue siendo **solo admin o bot**: devuelve precios.
-- ---------------------------------------------------------------------------
create or replace function paquete_preventivo(p_equipo uuid, p_tipo text default 'menor')
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  e equipos%rowtype;
  v_clase text;
  v_cap numeric;
  v_tarifa record;
  v_paquete paquetes_mantenimiento%rowtype;
  v_lineas jsonb;
begin
  if not es_admin() and not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector de WhatsApp.' using errcode = '42501';
  end if;
  if p_tipo not in ('menor', 'mayor') then
    raise exception 'El mantenimiento es menor o mayor: %', p_tipo using errcode = '22023';
  end if;

  select * into e from equipos where id = p_equipo;
  if not found then raise exception 'Ese equipo no existe.' using errcode = 'P0002'; end if;

  v_clase := _clase_de_equipo(e);
  v_cap := _capacidad_de_equipo(e);

  select t.sku, t.nombre, t.precio into v_tarifa
    from tarifas_servicio t
   where t.activo
     and t.concepto = 'preventivo_' || p_tipo
     and (t.clase is null or t.clase = v_clase)
     and (t.kw_desde is null or (v_cap is not null and v_cap >= t.kw_desde))
     and (t.kw_hasta is null or (v_cap is not null and v_cap <= t.kw_hasta))
   order by (t.clase is not null) desc, t.kw_desde desc nulls last
   limit 1;

  select * into v_paquete from paquetes_mantenimiento
   where id = _paquete_de_equipo(p_equipo, p_tipo);

  if v_paquete.id is not null then
    select coalesce(jsonb_agg(x order by x ->> 'orden'), '[]'::jsonb) into v_lineas
    from (
      select jsonb_build_object(
        'linea_id', l.id,
        'descripcion', l.descripcion,
        'cantidad', l.cantidad,
        'orden', lpad(l.orden::text, 4, '0'),
        'opciones', (
          select coalesce(jsonb_agg(jsonb_build_object(
                   'producto_id', c.producto_id, 'sku', c.sku, 'nombre', c.nombre,
                   'unidad', c.unidad, 'precio', pr.precio,
                   'disponible', c.disponible, 'preferido', c.preferido)), '[]'::jsonb)
            from _codigos_de_linea(l.id) c
            join productos pr on pr.id = c.producto_id
        )) as x
      from paquete_lineas l
      where l.paquete_id = v_paquete.id
    ) z;
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'ok', true,
    'equipo_id', e.id,
    'clase', v_clase,
    'capacidad', v_cap,
    'tipo', p_tipo,
    'servicio', case when v_tarifa.sku is not null then jsonb_build_object(
        'sku', v_tarifa.sku, 'nombre', v_tarifa.nombre, 'precio', v_tarifa.precio) end,
    'paquete', case when v_paquete.id is not null then jsonb_build_object(
        'paquete_id', v_paquete.id, 'nombre', v_paquete.nombre) end,
    'lineas', coalesce(v_lineas, '[]'::jsonb),
    'falta', case
      when v_clase is null then 'No se sabe de qué clase es el equipo: captura el combustible.'
      when v_cap is null then 'El equipo no tiene capacidad capturada.'
      when v_tarifa.sku is null then 'No hay tarifa de mantenimiento ' || p_tipo ||
                                    ' para esa clase y capacidad: captúrala en Tarifas.'
      when v_paquete.id is null then 'No hay paquete de refacciones para ese equipo todavía.'
      end));
end $$;
revoke all on function paquete_preventivo(uuid, text) from public, anon;
grant execute on function paquete_preventivo(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 1. El paquete llena la lista de surtido de una orden.
--
-- Para pólizas, que no tienen cotización, pero sirve en cualquier orden abierta con equipo.
-- Lo que ya estaba en la lista **no se toca**: llamarla dos veces no duplica ni pisa lo que
-- el almacén ya ajustó a mano.
--
-- De cada línea se toma el código con **más disponible**: si el original está agotado y el
-- genérico no, se prepara el genérico. El almacén puede cambiarlo después.
-- ---------------------------------------------------------------------------
create or replace function surtido_desde_paquete(p_orden uuid, p_tipo text default 'menor')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  o ordenes_servicio%rowtype;
  v_paquete uuid;
  l record;
  c record;
  n int := 0;
  v_sin_codigo text := '';
begin
  if not _es_almacen() then
    raise exception 'Solo el almacén o el administrador.' using errcode = '42501';
  end if;
  if p_tipo not in ('menor', 'mayor') then
    raise exception 'El mantenimiento es menor o mayor: %', p_tipo using errcode = '22023';
  end if;

  select * into o from ordenes_servicio where id = p_orden;
  if not found then raise exception 'La orden no existe.' using errcode = 'P0002'; end if;
  if o.estado <> 'abierta' then
    raise exception 'La orden ya está cerrada.' using errcode = '22023';
  end if;
  if o.equipo_id is null then
    raise exception 'La orden no dice de qué equipo es: sin eso no se sabe qué preparar.'
      using errcode = '22023';
  end if;

  v_paquete := _paquete_de_equipo(o.equipo_id, p_tipo);
  if v_paquete is null then
    return jsonb_build_object('ok', true, 'agregadas', 0,
      'motivo', 'Ese equipo no tiene paquete de mantenimiento ' || p_tipo || ' todavía.');
  end if;

  for l in select * from paquete_lineas where paquete_id = v_paquete order by orden loop
    -- El que más haya. `_codigos_de_linea` ya ordena por disponible dentro de cada grupo,
    -- pero aquí manda la existencia aunque no sea el preferido: es para surtir hoy.
    select * into c from _codigos_de_linea(l.id) order by disponible desc limit 1;

    if c.producto_id is null then
      v_sin_codigo := concat_ws(', ', nullif(v_sin_codigo, ''), l.descripcion);
      continue;
    end if;

    insert into orden_surtido (orden_id, producto_id, sku, nombre, unidad, cantidad_pedida, origen)
    values (p_orden, c.producto_id, c.sku, c.nombre, c.unidad, l.cantidad, 'paquete')
    on conflict (orden_id, producto_id) do nothing;
    if found then n := n + 1; end if;
  end loop;

  perform _apunta('ordenes_servicio', p_orden, 'surtido_de_paquete', null,
    jsonb_build_object('tipo', p_tipo, 'paquete', v_paquete, 'agregadas', n), 'paquete');

  return jsonb_build_object('ok', true, 'agregadas', n, 'sin_codigo', nullif(v_sin_codigo, ''));
end $$;
revoke all on function surtido_desde_paquete(uuid, text) from public, anon;
grant execute on function surtido_desde_paquete(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Qué se ha usado de verdad en equipos parecidos.
--
-- Mira las órdenes CERRADAS con material declarado como usado (`cantidad_usada`, de la 18)
-- en equipos de la misma clase y tramo, o de la misma marca y modelo si se piden.
--
-- **`visitas` es el dato que importa**, no el total de piezas: un producto que aparece en 9
-- de 10 visitas es parte del mantenimiento; uno que salió 20 veces en una sola visita fue
-- una reparación. Por eso va también `de_visitas`, para leer la proporción.
-- ---------------------------------------------------------------------------
create or replace function piezas_que_se_repiten(
  p_clase text default null,
  p_kw_desde numeric default null,
  p_kw_hasta numeric default null,
  p_marca text default null,
  p_modelo text default null,
  p_desde date default null          -- por si se quiere mirar solo lo reciente
) returns table (
  producto_id uuid, sku text, nombre text, unidad text,
  visitas bigint, de_visitas bigint, cantidad_tipica numeric, ultima_vez date
)
language sql stable security definer set search_path = public as $$
  with parecidos as (
    select e.id
      from equipos e
     where (p_clase is null or _clase_de_equipo(e) = p_clase)
       and (p_kw_desde is null or _capacidad_de_equipo(e) >= p_kw_desde)
       and (p_kw_hasta is null or _capacidad_de_equipo(e) <= p_kw_hasta)
       and (p_marca is null or lower(e.marca) = lower(p_marca))
       and (p_modelo is null or lower(e.modelo) = lower(p_modelo))
  ),
  cerradas as (
    select o.id, o.fecha
      from ordenes_servicio o
      join parecidos p on p.id = o.equipo_id
     where o.estado = 'cerrada'
       and (p_desde is null or o.fecha >= p_desde)
  ),
  usado as (
    select s.producto_id, v.id as orden_id, v.fecha, s.cantidad_usada
      from orden_surtido s
      join cerradas v on v.id = s.orden_id
     where coalesce(s.cantidad_usada, 0) > 0
  )
  select u.producto_id, p.sku, p.nombre, p.unidad,
         count(distinct u.orden_id),
         (select count(*) from cerradas),
         mode() within group (order by u.cantidad_usada),
         max(u.fecha)
    from usado u
    join productos p on p.id = u.producto_id
   where es_admin()
   group by u.producto_id, p.sku, p.nombre, p.unidad
   order by count(distinct u.orden_id) desc, p.sku;
$$;
revoke all on function piezas_que_se_repiten(text, numeric, numeric, text, text, date)
  from public, anon;
grant execute on function piezas_que_se_repiten(text, numeric, numeric, text, text, date)
  to authenticated;

notify pgrst, 'reload schema';
