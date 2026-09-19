-- ===========================================================================
-- CAMBIO DE ESTADO DE UNA COTIZACIÓN, EN UNA SOLA OPERACIÓN
--
-- ⚠ REEMPLAZADO por 08_requisiciones.sql: esa versión de la función también genera
-- requisiciones y ya no pregunta por faltantes. Este archivo se conserva para la
-- historia y para reconstruir la base en orden (07 y luego 08). NO correrlo solo
-- después del 08: dejaría la función vieja.
--
-- Antes el CRM hacía dos escrituras desde el navegador: cambiar el estado y luego
-- insertar los movimientos de inventario. Si la segunda fallaba (señal, permisos),
-- la cotización quedaba aceptada sin material apartado, o liberada sin haberse
-- liberado. Aquí todo va dentro de una función: o se hace completo o no se hace.
--
-- Reglas (las mismas de siempre, ahora en un solo lugar):
--   · Pasar a "aceptada"  → un movimiento `apartado` por partida con producto.
--   · Salir de "aceptada" hacia cualquier otro estado → `libera_apartado`.
--   · Si al aceptar no alcanza el disponible, NO hace nada y devuelve la lista de
--     faltantes; el CRM pregunta y vuelve a llamar con p_forzar = true.
--
-- Solo admin. La función corre con los permisos de quien la llama (no es
-- security definer), así que las políticas por rol siguen aplicando debajo.
-- Se puede volver a ejecutar sin problema.
-- ===========================================================================

create or replace function cambiar_estado_cotizacion(
  p_id uuid,
  p_nuevo text,
  p_forzar boolean default false
) returns jsonb
language plpgsql
set search_path = public
as $$
declare
  c cotizaciones%rowtype;
  faltantes jsonb;
  n_mov int := 0;
  quien text := coalesce(auth.jwt() ->> 'email', 'crm');
begin
  if not es_admin() then
    raise exception 'Solo el administrador puede cambiar el estado de una cotización.'
      using errcode = '42501';
  end if;

  if p_nuevo not in ('borrador', 'enviada', 'aceptada', 'rechazada', 'vencida') then
    raise exception 'Estado no válido: %', p_nuevo using errcode = '22023';
  end if;

  -- for update: si dos pestañas cambian la misma cotización a la vez, la segunda
  -- espera a la primera y ve el estado ya cambiado, en vez de duplicar movimientos.
  select * into c from cotizaciones where id = p_id for update;
  if not found then
    raise exception 'La cotización no existe.' using errcode = 'P0002';
  end if;

  if c.estado = p_nuevo then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'folio', c.folio, 'estado', c.estado);
  end if;

  -- Al aceptar: revisar que alcance el disponible (sumando si un producto se
  -- repite en dos partidas). Un producto sin fila en `disponibles` cuenta como 0.
  if p_nuevo = 'aceptada' and not p_forzar then
    select coalesce(jsonb_agg(jsonb_build_object(
             'sku', coalesce(d.sku, q.producto_id::text),
             'disponible', coalesce(d.disponible, 0),
             'pide', q.pide)), '[]'::jsonb)
      into faltantes
    from (
      select (p ->> 'producto_id')::uuid as producto_id,
             sum((p ->> 'cantidad')::numeric) as pide
      from jsonb_array_elements(coalesce(c.partidas, '[]'::jsonb)) p
      where nullif(p ->> 'producto_id', '') is not null
        and (p ->> 'cantidad')::numeric > 0
      group by 1
    ) q
    left join disponibles d on d.id = q.producto_id
    where coalesce(d.disponible, 0) < q.pide;

    if jsonb_array_length(faltantes) > 0 then
      return jsonb_build_object('ok', false, 'faltantes', faltantes, 'folio', c.folio);
    end if;
  end if;

  if p_nuevo = 'aceptada' then
    insert into movimientos_inventario
      (producto_id, tipo, cantidad, cliente_id, cotizacion_id, referencia, notas, usuario)
    select (p ->> 'producto_id')::uuid, 'apartado', (p ->> 'cantidad')::numeric,
           c.cliente_id, c.id, 'COT-' || c.folio,
           'Apartado al aprobar la cotización', quien
    from jsonb_array_elements(coalesce(c.partidas, '[]'::jsonb)) p
    where nullif(p ->> 'producto_id', '') is not null
      and (p ->> 'cantidad')::numeric > 0;
    get diagnostics n_mov = row_count;

  elsif c.estado = 'aceptada' then
    insert into movimientos_inventario
      (producto_id, tipo, cantidad, cliente_id, cotizacion_id, referencia, notas, usuario)
    select (p ->> 'producto_id')::uuid, 'libera_apartado', (p ->> 'cantidad')::numeric,
           c.cliente_id, c.id, 'COT-' || c.folio,
           'Liberado: la cotización pasó a ' || p_nuevo, quien
    from jsonb_array_elements(coalesce(c.partidas, '[]'::jsonb)) p
    where nullif(p ->> 'producto_id', '') is not null
      and (p ->> 'cantidad')::numeric > 0;
    get diagnostics n_mov = row_count;
  end if;

  update cotizaciones
     set estado = p_nuevo,
         aprobada_por     = case when p_nuevo = 'aceptada' then quien else aprobada_por end,
         fecha_aprobacion = case when p_nuevo = 'aceptada' then now() else fecha_aprobacion end
   where id = p_id;

  return jsonb_build_object(
    'ok', true,
    'folio', c.folio,
    'anterior', c.estado,
    'estado', p_nuevo,
    'movimientos', n_mov,
    'movimiento', case
      when p_nuevo = 'aceptada' then 'apartado'
      when c.estado = 'aceptada' then 'libera_apartado'
      else null end
  );
end;
$$;

revoke all on function cambiar_estado_cotizacion(uuid, text, boolean) from public, anon;
grant execute on function cambiar_estado_cotizacion(uuid, text, boolean) to authenticated;

-- Que la API de Supabase vea la función nueva sin esperar.
notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- PRUEBA. Cambia los dos uuid: el de una cuenta admin (select id, email from
-- perfiles where rol = 'admin') y el de una cotización en borrador con al menos
-- una partida con producto. Todo termina en rollback: no deja nada cambiado.
--
--   begin;
--   set local role authenticated;
--   select set_config('request.jwt.claims',
--     json_build_object('sub', '<UUID-ADMIN>', 'role', 'authenticated',
--                       'email', 'prueba@powermx')::text, true);
--
--   -- 1) Aceptar: devuelve ok:true con movimiento 'apartado' (o ok:false si falta stock)
--   select cambiar_estado_cotizacion('<UUID-COTIZACION>', 'aceptada');
--   select tipo, cantidad, referencia, usuario from movimientos_inventario
--    where cotizacion_id = '<UUID-COTIZACION>';
--
--   -- 2) Rechazar: 'libera_apartado', un movimiento por partida
--   select cambiar_estado_cotizacion('<UUID-COTIZACION>', 'rechazada');
--   select tipo, cantidad from movimientos_inventario
--    where cotizacion_id = '<UUID-COTIZACION>';   -- verás apartado y libera_apartado
--   rollback;
--
--   -- 3) Cuenta que no es admin (uuid inventado): debe fallar con "Solo el administrador"
--   begin;
--   set local role authenticated;
--   select set_config('request.jwt.claims',
--     json_build_object('sub', '00000000-0000-0000-0000-000000000001', 'role', 'authenticated')::text, true);
--   select cambiar_estado_cotizacion('<UUID-COTIZACION>', 'aceptada');
--   rollback;
-- ---------------------------------------------------------------------------
