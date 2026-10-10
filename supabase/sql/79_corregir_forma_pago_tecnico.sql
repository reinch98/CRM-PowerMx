-- ============================================================================
-- 79 · Corregir la forma de pago de un pago a técnico ya registrado
--
-- Requiere el 77 (egresos ligados a su pago por expediente_movimientos.pago_tecnico_id). Pedido de Caña
-- (09/10/2026): "corregir también el método de pago en pagos a técnicos". A diferencia del 77 (monto u
-- órdenes: se deshace y se vuelve a registrar), aquí el pago sigue registrado y solo se corrigen sus
-- datos: forma (transferencia, efectivo u otro), cuenta de donde salió, fecha y referencia — en el pago
-- y en cada uno de sus egresos del libro, en una sola transacción.
--
-- Candados: un expediente cerrado no se toca (reabrirlo antes). Si cambia la cuenta, un renglón del banco
-- conciliado con esos egresos vuelve a "pendiente" (pertenecía a la otra cuenta) y se avisa cuántos.
-- Todo queda en `auditoria` con los valores de antes.
-- ============================================================================

create or replace function corregir_forma_pago_tecnico(
  p_pago uuid, p_forma text, p_fecha date, p_referencia text default null, p_cuenta uuid default null,
  p_motivo text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p pagos_tecnico%rowtype;
  v_movs uuid[];
  v_cerrada bigint;
  v_cuenta_antes uuid;
  v_banco int := 0;
  v_antes jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador corrige pagos a técnicos.' using errcode = '42501';
  end if;
  v_p := (select p from pagos_tecnico p where p.id = p_pago);
  if v_p.id is null then raise exception 'Ese pago no existe.' using errcode = '22023'; end if;
  if v_p.estado <> 'pagado' then
    raise exception 'Solo se corrige la forma de pago de un pago ya registrado.' using errcode = '22023';
  end if;
  if p_forma is null or p_forma not in ('transferencia', 'efectivo', 'otro') then
    raise exception 'Indica la forma de pago: transferencia, efectivo u otro.' using errcode = '22023';
  end if;
  if p_fecha is null then raise exception 'Escribe la fecha del pago.' using errcode = '22023'; end if;
  if p_cuenta is not null and (select id from cuentas_financieras where id = p_cuenta) is null then
    raise exception 'Esa cuenta no existe.' using errcode = '22023';
  end if;

  v_movs := coalesce((select array_agg(id) from expediente_movimientos where pago_tecnico_id = p_pago), '{}'::uuid[]);
  v_cerrada := (select min(q.folio) from expediente_movimientos m join cotizaciones q on q.id = m.cotizacion_id
                 where m.id = any(v_movs) and q.expediente_cierre is not null);
  if v_cerrada is not null then
    raise exception 'El expediente de la cotización % ya está cerrado. Reábrelo antes de corregir este pago.', v_cerrada
      using errcode = '22023';
  end if;

  v_cuenta_antes := (select cuenta_id from expediente_movimientos where id = any(v_movs) limit 1);
  v_antes := jsonb_build_object('forma', v_p.forma, 'fecha_pago', v_p.fecha_pago, 'referencia', v_p.referencia,
                                'cuenta_id', v_cuenta_antes);
  -- Otra cuenta: lo conciliado pertenecía a la de antes.
  if p_cuenta is distinct from v_cuenta_antes then
    v_banco := _liberar_banco(v_movs);
  end if;

  update pagos_tecnico
     set forma = p_forma, fecha_pago = p_fecha, referencia = nullif(trim(p_referencia), '')
   where id = p_pago;
  update expediente_movimientos
     set forma = p_forma, fecha = p_fecha, cuenta_id = p_cuenta,
         referencia = coalesce(nullif(trim(p_referencia), ''), 'PAGO-' || v_p.folio)
   where id = any(v_movs);

  perform _apunta('pagos_tecnico', p_pago, 'corregir_forma_pago_tecnico', v_antes,
                  jsonb_build_object('forma', p_forma, 'fecha_pago', p_fecha, 'referencia', nullif(trim(p_referencia), ''),
                                     'cuenta_id', p_cuenta, 'motivo', nullif(trim(p_motivo), ''),
                                     'egresos', coalesce(array_length(v_movs, 1), 0), 'banco_liberados', v_banco), 'oficina');
  return jsonb_build_object('ok', true, 'egresos', coalesce(array_length(v_movs, 1), 0), 'banco_liberados', v_banco);
end;
$$;
revoke execute on function corregir_forma_pago_tecnico(uuid, text, date, text, uuid, text) from public, anon;
grant execute on function corregir_forma_pago_tecnico(uuid, text, date, text, uuid, text) to authenticated;

insert into _migraciones (archivo, tipo) values ('79_corregir_forma_pago_tecnico.sql', 'esquema') on conflict (archivo) do nothing;
