-- ===========================================================================
-- FLUJO DE SERVICIO · FASE 1d · CERRAR UNA ORDEN
--
-- Cerrar la orden es cosa del técnico responsable (T1), y lo hace una sola función:
--   · junta las partes de los dos técnicos en `trabajos_realizados` (la de T1 primero),
--   · junta las fotos de las dos partes en `fotos`,
--   · guarda la firma del cliente y los datos de cierre,
--   · marca la orden `cerrada` y su cita `realizada`.
-- Nadie más puede editar una orden cerrada (las políticas de orden_partes ya lo exigen).
--
-- Es idempotente: si el celular no supo que el cierre ya se guardó y lo reintenta, la
-- segunda llamada no hace nada y contesta que ya estaba cerrada. Eso importa porque el
-- cierre se hace muchas veces sin señal y se reenvía hasta que llega.
--
-- security definer: el técnico no tiene permiso de editar `ordenes_servicio` ni `citas`;
-- la función revisa por su cuenta que quien llama sea T1 de esa orden (o el admin).
-- Se puede volver a ejecutar sin problema.
-- ===========================================================================

create or replace function cerrar_orden(
  p_orden uuid,
  p_firma text,                          -- ruta de la firma en el bucket `ordenes`
  p_sin_firma boolean default false,     -- el cliente no pudo o no quiso firmar
  p_horas numeric default null,          -- horómetro
  p_observaciones text default null,
  p_recomendaciones text default null,
  p_seguimiento boolean default false,
  p_fecha_seguimiento date default null,
  p_refacciones jsonb default null       -- lista manual (hasta que el almacén las entregue)
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  o ordenes_servicio%rowtype;
  v_trabajos text;
  v_fotos jsonb;
  v_obs text;
begin
  select * into o from ordenes_servicio where id = p_orden for update;
  if not found then
    raise exception 'La orden no existe.' using errcode = 'P0002';
  end if;

  if not (es_admin() or (mi_rol() = 'tecnico' and o.tecnico_id = auth.uid())) then
    raise exception 'Solo el técnico responsable puede cerrar la orden.' using errcode = '42501';
  end if;

  -- Ya cerrada: el reintento de un cierre que sí llegó. No se toca nada.
  if o.estado = 'cerrada' then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'folio', o.folio);
  end if;
  if o.estado <> 'abierta' then
    raise exception 'La orden OS-% está % y ya no se puede cerrar.', o.folio, o.estado
      using errcode = '22023';
  end if;

  -- Las partes de los dos técnicos, la del responsable primero.
  select string_agg(trim(p.notas), E'\n\n' order by (p.autor_id = o.tecnico_id) desc, p.created_at)
    into v_trabajos
  from orden_partes p
  where p.orden_id = o.id and coalesce(trim(p.notas), '') <> '';

  if coalesce(v_trabajos, '') = '' then
    raise exception 'Anota los trabajos realizados antes de cerrar la orden.' using errcode = '22023';
  end if;

  if p_firma is null and not coalesce(p_sin_firma, false) then
    raise exception 'Falta la firma del cliente.' using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(f.valor), '[]'::jsonb) into v_fotos
  from orden_partes p, jsonb_array_elements(p.fotos) as f(valor)
  where p.orden_id = o.id;

  v_obs := nullif(trim(coalesce(p_observaciones, '')), '');
  if p_firma is null then
    v_obs := coalesce(v_obs || E'\n', '') || 'El cliente no firmó la orden.';
  end if;

  update ordenes_servicio
     set trabajos_realizados = v_trabajos,
         fotos = v_fotos,
         firma_cliente = p_firma,
         horas_equipo = p_horas,
         observaciones = v_obs,
         recomendaciones = nullif(trim(coalesce(p_recomendaciones, '')), ''),
         requiere_seguimiento = coalesce(p_seguimiento, false),
         fecha_seguimiento = case when coalesce(p_seguimiento, false) then p_fecha_seguimiento else null end,
         refacciones = coalesce(p_refacciones, '[]'::jsonb),
         estado = 'cerrada'
   where id = o.id;

  update citas set estado = 'realizada'
   where id = o.cita_id and estado in ('programada', 'por_programar');

  return jsonb_build_object('ok', true, 'folio', o.folio, 'fotos', jsonb_array_length(v_fotos));
end;
$$;

revoke all on function cerrar_orden(uuid, text, boolean, numeric, text, text, boolean, date, jsonb) from public, anon;
grant execute on function cerrar_orden(uuid, text, boolean, numeric, text, text, boolean, date, jsonb) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- PRUEBA (begin/rollback SÍ deshace; solo se ve el resultado de la ÚLTIMA sentencia, por eso
-- cada paso se guarda con set_config). Correr SIEMPRE el bloque completo.
--
-- Necesitas una orden `abierta` con cita (las abre 1b o 1c), el uuid de su técnico
-- responsable (T1) y, si quieres probar al ayudante, el de T2:
--   select o.id as orden, o.tecnico_id as t1, o.tecnico2_id as t2, o.folio
--   from ordenes_servicio o where o.estado = 'abierta' and o.cita_id is not null;
--
--   begin;
--   set local role authenticated;
--   select set_config('request.jwt.claims',
--     json_build_object('sub', '<UUID-T1>', 'role', 'authenticated')::text, true);
--
--   -- T1 escribe su parte (RLS: solo la suya) y cierra
--   insert into orden_partes (orden_id, autor_id, notas, fotos)
--     values ('<UUID-ORDEN>', '<UUID-T1>', 'Cambié filtros y revisé baterías.', '["x/1.jpg"]');
--   select set_config('app.a', cerrar_orden('<UUID-ORDEN>', 'x/firma.png', false, 120)::text, true);
--   select set_config('app.b', cerrar_orden('<UUID-ORDEN>', 'x/firma.png', false, 120)::text, true);  -- reintento
--   select set_config('app.c', (select jsonb_build_object('estado', estado, 'trabajos', trabajos_realizados,
--       'fotos', fotos, 'firma', firma_cliente) from ordenes_servicio where id = '<UUID-ORDEN>')::text, true);
--   select set_config('app.d', (select estado from citas where id =
--       (select cita_id from ordenes_servicio where id = '<UUID-ORDEN>')), true);
--
--   select current_setting('app.a')::jsonb as cerrar,       -- ok true, fotos 1
--          current_setting('app.b')::jsonb as reintento,    -- sin_cambio true
--          current_setting('app.c')::jsonb as orden,        -- estado cerrada, trabajos, firma
--          current_setting('app.d') as cita;                -- realizada
--   rollback;
--
-- Otra prueba, con T2 (o un uuid inventado): cerrar_orden debe fallar con
-- "Solo el técnico responsable puede cerrar la orden."
-- ---------------------------------------------------------------------------
