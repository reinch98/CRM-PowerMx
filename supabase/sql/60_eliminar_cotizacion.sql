-- ---------------------------------------------------------------------------
-- 60_eliminar_cotizacion.sql — borrar una cotización de prueba junto con sus citas y órdenes.
--
--   eliminar_cotizacion(id)                  → VISTA PREVIA: qué se borraría y qué lo impide
--   eliminar_cotizacion(id, p_ejecutar=true) → borra de verdad (solo si nada lo impide)
--
-- Solo admin. Es para datos de prueba, así que se niega a borrar lo que ya tuvo efectos reales:
--   · material entregado al técnico (entrega firmada o sin firma), devoluciones, o cualquier
--     movimiento de inventario que no sea apartar/liberar (entradas, consumos, ventas…);
--   · un pedido ya pedido o recibido, o ligado a una compra;
--   · una orden que ya se envió al cliente.
-- Los avisos de WhatsApp de esas citas que aún no salieron se quitan de la cola; si alguno ya salió, se niega.
-- Lo único del inventario que se borra son los `apartado` / `libera_apartado` de esa cotización,
-- y solo si por producto quedan en CERO (nada apartado): así el libro de movimientos no pierde
-- ningún efecto sobre las existencias. Una cotización aún Aceptada se cambia primero a Borrador.
-- Los archivos de Storage (fotos, firmas, PDF) no se borran: quedan sueltos y sin ninguna
-- referencia. El borrado queda anotado en `auditoria`. Repetible.
-- ---------------------------------------------------------------------------

create or replace function eliminar_cotizacion(p_cotizacion uuid, p_ejecutar boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cot cotizaciones%rowtype;
  v_citas uuid[];
  v_ordenes uuid[];
  v_reqs uuid[];
  v_bloqueos text[] := '{}';
  v_n int;
  v_folios_os text;
  v_resumen jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador puede eliminar cotizaciones.' using errcode = '42501';
  end if;

  v_cot := (select c from cotizaciones c where c.id = p_cotizacion);
  if v_cot.id is null then
    raise exception 'Esa cotización ya no existe.' using errcode = '22023';
  end if;

  v_citas   := array(select id from citas where cotizacion_id = p_cotizacion);
  v_ordenes := array(select id from ordenes_servicio where cita_id = any(v_citas));
  v_reqs    := array(select id from requisiciones where cotizacion_id = p_cotizacion);

  -- ---- lo que lo impide ----
  v_n := (select count(*) from entregas
           where orden_id = any(v_ordenes) and estado not in ('pendiente', 'cancelada'));
  if v_n > 0 then
    v_bloqueos := v_bloqueos || format('Ya se entregó material al técnico (%s entrega(s)). Hay que recibir la devolución antes.', v_n);
  end if;

  v_n := (select count(*) from devoluciones where orden_id = any(v_ordenes));
  if v_n > 0 then
    v_bloqueos := v_bloqueos || format('Tiene %s devolución(es) registradas en el almacén.', v_n);
  end if;

  v_n := (select count(*) from envios_orden where orden_id = any(v_ordenes));
  if v_n > 0 then
    v_bloqueos := v_bloqueos || format('La orden ya se envió al cliente (%s envío(s) registrados).', v_n);
  end if;

  v_n := (select count(*) from movimientos_inventario
           where tipo not in ('apartado', 'libera_apartado')
             and (cotizacion_id = p_cotizacion
                  or orden_id = any(v_ordenes) or orden_servicio_id = any(v_ordenes)));
  if v_n > 0 then
    v_bloqueos := v_bloqueos || format('Tiene %s movimiento(s) de inventario que no son apartado (entradas, consumos, ventas…).', v_n);
  end if;

  v_n := (select count(*) from (
            select producto_id
              from movimientos_inventario
             where tipo in ('apartado', 'libera_apartado') and cotizacion_id = p_cotizacion
             group by producto_id
            having sum(case tipo when 'apartado' then cantidad else -cantidad end) <> 0
          ) x);
  if v_n > 0 then
    v_bloqueos := v_bloqueos || format('Todavía tiene material apartado de %s producto(s). Cámbiala primero a Borrador para liberarlo.', v_n);
  end if;

  v_n := (select count(*) from salida_wa
           where origen = 'aviso' and estado in ('enviando', 'enviado', 'entregado', 'leido', 'sin_confirmar')
             and origen_id in (select id from avisos where cita_id = any(v_citas)));
  if v_n > 0 then
    v_bloqueos := v_bloqueos || format('Ya se mandaron %s aviso(s) de la cita por WhatsApp al cliente o al técnico.', v_n);
  end if;

  v_n := (select count(*) from requisiciones
           where id = any(v_reqs) and estado in ('pedida', 'recibida'));
  if v_n > 0 then
    v_bloqueos := v_bloqueos || format('Tiene %s pedido(s) al proveedor ya pedidos o recibidos. Cancélalos primero en Pedidos.', v_n);
  end if;

  v_n := (select count(*) from compra_lineas where requisicion_id = any(v_reqs));
  if v_n > 0 then
    v_bloqueos := v_bloqueos || 'Un pedido suyo está ligado a una compra.';
  end if;

  v_folios_os := coalesce((select string_agg('OS-' || folio, ', ' order by folio)
                             from ordenes_servicio where id = any(v_ordenes)), '');

  v_resumen := jsonb_build_object(
    'folio', v_cot.folio,
    'estado', v_cot.estado,
    'citas', coalesce(array_length(v_citas, 1), 0),
    'ordenes', coalesce(array_length(v_ordenes, 1), 0),
    'ordenes_folios', v_folios_os,
    'movimientos_apartado', (select count(*) from movimientos_inventario
                              where tipo in ('apartado', 'libera_apartado')
                                and (cotizacion_id = p_cotizacion
                                     or orden_id = any(v_ordenes) or orden_servicio_id = any(v_ordenes))),
    'pedidos', coalesce(array_length(v_reqs, 1), 0),
    'solicitudes_material', (select count(*) from solicitudes_material where orden_id = any(v_ordenes)),
    'entregas_sin_firmar', (select count(*) from entregas
                             where orden_id = any(v_ordenes) and estado in ('pendiente', 'cancelada'))
  );

  if array_length(v_bloqueos, 1) is not null then
    return jsonb_build_object('ok', false, 'ejecutado', false, 'bloqueos', to_jsonb(v_bloqueos), 'resumen', v_resumen);
  end if;

  if not p_ejecutar then
    return jsonb_build_object('ok', true, 'ejecutado', false, 'bloqueos', '[]'::jsonb, 'resumen', v_resumen);
  end if;

  -- ---- el borrado, de lo más dependiente a la cotización ----
  delete from solicitudes_material where orden_id = any(v_ordenes);
  delete from entregas where orden_id = any(v_ordenes);                  -- sus líneas se van en cascada
  delete from orden_surtido where orden_id = any(v_ordenes) or cotizacion_id = p_cotizacion;
  delete from movimientos_inventario
   where tipo in ('apartado', 'libera_apartado')
     and (cotizacion_id = p_cotizacion
          or orden_id = any(v_ordenes) or orden_servicio_id = any(v_ordenes));
  delete from requisiciones where id = any(v_reqs);
  delete from ordenes_servicio where id = any(v_ordenes);                -- partes, revisión y PDF en cascada
  -- Los avisos sin mandar que esperan en la cola de WhatsApp: si no se quitan, saldría un mensaje
  -- de una cita que ya no existe. (Esa cola no tiene llave foránea hacia los avisos.)
  delete from salida_wa
   where origen = 'aviso'
     and origen_id in (select id from avisos where cita_id = any(v_citas));
  delete from citas where id = any(v_citas);                             -- sus avisos en cascada
  delete from cotizaciones where id = p_cotizacion;

  perform _apunta('cotizaciones', p_cotizacion, 'eliminar', v_resumen, null, 'oficina');
  return jsonb_build_object('ok', true, 'ejecutado', true, 'bloqueos', '[]'::jsonb, 'resumen', v_resumen);
end;
$$;

revoke all on function eliminar_cotizacion(uuid, boolean) from public;
revoke all on function eliminar_cotizacion(uuid, boolean) from anon;
grant execute on function eliminar_cotizacion(uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
