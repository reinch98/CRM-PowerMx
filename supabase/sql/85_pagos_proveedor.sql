-- ===========================================================================
-- 85 · Comprobantes de pago a proveedor y anticipos (parte C del ciclo de compras, 18/10/2026)
--
-- Decisiones de Caña: un comprobante de pago a un proveedor (SPEI, depósito, transferencia) va al
-- libro como EGRESO y a la carpeta de ese proveedor. Si hay una factura por pagar de ese proveedor,
-- la paga (el monto debe cuadrar con su saldo; un pago menor es parcial y se dice). Si todavía no hay
-- factura, queda como ANTICIPO (de una cotización de proveedor, o suelto). Cuando llega la factura,
-- el anticipo se le aplica y su saldo baja solo (el saldo no se guarda: total − pagos que la citan).
-- Los cobros de clientes NO entran por aquí: siguen por el Expediente de su cotización.
--
-- · El comprobante entra por la bandeja de Finanzas (ahí se cuida que el mismo archivo no se
--   registre dos veces); al registrarlo, el documento queda "aprobado" y ligado al movimiento.
-- · Antes de escribir se buscan pagos que PARECEN el mismo: la misma clave de rastreo, o el mismo
--   proveedor y monto con menos de 7 días de diferencia. Si hay, no se registra nada hasta que se
--   confirme ("sí, es otro pago"): una transferencia contada dos veces haría pasar por pagado lo
--   que no se pagó.
-- · Un anticipo no lleva IVA acreditable (no hay CFDI). Al aplicarlo a su factura, gana el IVA en
--   proporción, igual que un pago normal (pagar_cfdi).
-- · Nada se borra: aplicar y quitar un anticipo de una factura cambian su `cfdi_id` y dejan rastro.
--
-- SQL plano fuera de las funciones, sin `select ... into` (ver CLAUDE.md). Repetible.
-- ===========================================================================

alter table expediente_movimientos
  add column if not exists cotizacion_proveedor_id uuid references cotizaciones_proveedor (id);
create index if not exists idx_exp_mov_cotprov on expediente_movimientos (cotizacion_proveedor_id);

-- Pagos que parecen el mismo: misma referencia (clave de rastreo), o mismo proveedor y monto ±1 centavo
-- con menos de 7 días de diferencia. Devuelve las frases para avisar.
create or replace function _pagos_parecidos(p_proveedor uuid, p_monto numeric, p_fecha date, p_referencia text)
returns text[]
language sql stable security definer set search_path = public as $fn$
  select coalesce(array_agg(format('Ya hay un pago de %s el %s%s%s.',
                                   to_char(m.monto, 'FM$999,999,990.00'), to_char(m.fecha, 'DD/MM/YYYY'),
                                   case when m.referencia is not null then ' (ref. ' || m.referencia || ')' else '' end,
                                   case when nullif(trim(p_referencia), '') is not null and m.referencia = trim(p_referencia)
                                        then ': tiene la MISMA referencia' else ' al mismo proveedor por el mismo monto' end)
                            order by m.fecha desc), '{}')
    from expediente_movimientos m
   where m.tipo = 'egreso'
     and ((nullif(trim(p_referencia), '') is not null and m.referencia = trim(p_referencia))
          or (p_proveedor is not null and m.proveedor_id = p_proveedor and abs(m.monto - p_monto) <= 0.01
              and abs(m.fecha - p_fecha) <= 7))
$fn$;
revoke execute on function _pagos_parecidos(uuid, numeric, date, text) from public, anon, authenticated;

-- ---- lo que se le puede pagar a un proveedor con un monto ----
-- Para la pantalla: reconoce al proveedor (sin crear fichas) y lista sus facturas por pagar y sus
-- cotizaciones vivas, marcando la factura cuyo saldo es EXACTAMENTE el monto.
-- No es `stable`: _proveedor_id puede aprender un alias (escribe), y una función stable no puede.
create or replace function opciones_pago_proveedor(p_proveedor text, p_monto numeric default null)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_prov proveedores;
begin
  if not es_admin() then
    raise exception 'Solo el administrador registra pagos a proveedores.' using errcode = '42501';
  end if;
  v_prov := (select p from proveedores p
              where p.id = coalesce((select x.id from proveedores x where x.id::text = p_proveedor),
                                    _proveedor_id(p_proveedor, null, false)));
  if v_prov.id is null then
    return jsonb_build_object('proveedor', null, 'facturas', '[]'::jsonb, 'cotizaciones', '[]'::jsonb);
  end if;
  return jsonb_build_object(
    'proveedor', jsonb_build_object('id', v_prov.id, 'nombre', v_prov.nombre),
    'facturas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'cfdi_id', f.id, 'serie', f.serie, 'folio', f.folio, 'fecha', (f.fecha at time zone 'America/Merida')::date,
               'vence', f.vence, 'total', f.total, 'saldo', _saldo_cfdi(f.id),
               'exacta', p_monto is not null and abs(_saldo_cfdi(f.id) - p_monto) <= 0.01)
             order by (p_monto is not null and abs(_saldo_cfdi(f.id) - p_monto) <= 0.01) desc, f.vence nulls last, f.fecha)
        from cfdi f
       where f.proveedor_id = v_prov.id and f.sentido = 'recibido' and f.por_pagar and f.estado_sat <> 'cancelado'
         and _saldo_cfdi(f.id) > 0.01), '[]'::jsonb),
    'cotizaciones', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'folio', c.folio, 'numero', c.numero, 'estado', c.estado, 'fecha', c.fecha,
               'moneda', c.moneda, 'tipo_cambio', c.tipo_cambio, 'total', c.total,
               'total_mxn', round(c.total * coalesce(c.tipo_cambio, 1), 2),
               'anticipos', coalesce((select sum(m.monto) from expediente_movimientos m
                                       where m.cotizacion_proveedor_id = c.id and m.tipo = 'egreso'), 0))
             order by (c.estado = 'aceptada') desc, c.fecha desc)
        from cotizaciones_proveedor c
       where c.proveedor_id = v_prov.id and c.estado in ('vigente', 'aceptada')), '[]'::jsonb)
  );
end $fn$;

-- ---- registrar el pago ----
-- p_datos: proveedor_id | proveedor (texto), monto, fecha, forma, referencia, cuenta_id, notas,
--          cfdi_id (paga esa factura) | cotizacion_proveedor_id (anticipo de esa cotización) | nada
--          (anticipo suelto), documento_id (el comprobante en la bandeja).
-- Con pagos parecidos y sin p_confirmar, NO escribe: devuelve { ok:false, requiere_confirmar, avisos }.
create or replace function registrar_pago_proveedor(p_datos jsonb, p_confirmar boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_prov      proveedores;
  v_pid       uuid;
  v_monto     numeric := nullif(p_datos ->> 'monto', '')::numeric;
  v_fecha     date := coalesce(nullif(p_datos ->> 'fecha', '')::date, _hoy_merida());
  v_forma     text := nullif(trim(coalesce(p_datos ->> 'forma', '')), '');
  v_ref       text := nullif(trim(coalesce(p_datos ->> 'referencia', '')), '');
  v_cuenta    uuid := nullif(p_datos ->> 'cuenta_id', '')::uuid;
  v_notas     text := nullif(trim(coalesce(p_datos ->> 'notas', '')), '');
  v_cfdi      cfdi;
  v_cotp      cotizaciones_proveedor;
  v_doc       documentos;
  v_saldo     numeric;
  v_mov       uuid;
  v_r         jsonb;
  v_parecidos text[];
  v_tipo      text;
begin
  if not es_admin() then
    raise exception 'Solo el administrador registra pagos a proveedores.' using errcode = '42501';
  end if;
  if coalesce(v_monto, 0) <= 0 then
    raise exception 'El pago debe ser mayor a cero.' using errcode = '22023';
  end if;
  if v_cuenta is not null and not exists (select 1 from cuentas_financieras where id = v_cuenta) then
    raise exception 'Esa cuenta no existe.' using errcode = '22023';
  end if;

  v_prov := (select p from proveedores p where p.id = nullif(p_datos ->> 'proveedor_id', '')::uuid);
  if v_prov.id is null then
    -- En dos pasos: si _proveedor_id crea la ficha, la misma sentencia no la vería.
    v_pid := _proveedor_id(p_datos ->> 'proveedor', null, true);
    v_prov := (select p from proveedores p where p.id = v_pid);
  end if;
  if v_prov.id is null then
    raise exception 'Escribe a qué proveedor se le pagó.' using errcode = '22023';
  end if;

  if nullif(p_datos ->> 'documento_id', '') is not null then
    v_doc := (select d from documentos d where d.id = (p_datos ->> 'documento_id')::uuid);
    if v_doc.id is null then
      raise exception 'Ese comprobante no existe en la bandeja.' using errcode = '22023';
    end if;
    if v_doc.estado not in ('pendiente', 'propuesto') then
      raise exception 'Ese comprobante ya se procesó en la bandeja (está %).', v_doc.estado using errcode = '22023';
    end if;
  end if;

  if nullif(p_datos ->> 'cfdi_id', '') is not null then
    v_cfdi := (select c from cfdi c where c.id = (p_datos ->> 'cfdi_id')::uuid);
    if v_cfdi.id is null then
      raise exception 'Esa factura no existe.' using errcode = '22023';
    end if;
    if v_cfdi.proveedor_id is distinct from v_prov.id then
      raise exception 'Esa factura es de otro proveedor.' using errcode = '22023';
    end if;
    v_saldo := _saldo_cfdi(v_cfdi.id);
    if v_monto > v_saldo + 0.01 then
      raise exception 'El pago (%) es mayor que lo que falta por pagar de esa factura (%): regístralo como anticipo o elige otra.',
        to_char(v_monto, 'FM$999,999,990.00'), to_char(v_saldo, 'FM$999,999,990.00') using errcode = '22023';
    end if;
  elsif nullif(p_datos ->> 'cotizacion_proveedor_id', '') is not null then
    v_cotp := (select c from cotizaciones_proveedor c where c.id = (p_datos ->> 'cotizacion_proveedor_id')::uuid);
    if v_cotp.id is null or v_cotp.proveedor_id <> v_prov.id then
      raise exception 'Esa cotización no es de este proveedor.' using errcode = '22023';
    end if;
    if v_cotp.estado not in ('vigente', 'aceptada') then
      raise exception 'Esa cotización está %: no se le puede dar un anticipo.', v_cotp.estado using errcode = '22023';
    end if;
  end if;

  v_parecidos := _pagos_parecidos(v_prov.id, v_monto, v_fecha, v_ref);
  if array_length(v_parecidos, 1) > 0 and not coalesce(p_confirmar, false) then
    return jsonb_build_object('ok', false, 'requiere_confirmar', true, 'avisos', to_jsonb(v_parecidos));
  end if;

  if v_cfdi.id is not null then
    v_r := pagar_cfdi(v_cfdi.id, v_monto, v_fecha, v_cuenta, v_forma, v_ref);
    v_mov := (v_r ->> 'movimiento_id')::uuid;
    update expediente_movimientos
       set proveedor_id = v_prov.id,
           archivo = coalesce(v_doc.archivo, archivo),
           archivo_nombre = coalesce(v_doc.nombre_original, archivo_nombre),
           documento_id = coalesce(v_doc.id, documento_id),
           notas = nullif(concat_ws(' · ', notas, v_notas), '')
     where id = v_mov;
    v_tipo := case when (v_r ->> 'saldo')::numeric > 0.01 then 'pago_parcial' else 'pago_factura' end;
  else
    v_mov := gen_random_uuid();
    insert into expediente_movimientos
      (id, cotizacion_id, tipo, categoria, fecha, concepto, monto, iva, forma, referencia, cuenta_id,
       proveedor_id, cotizacion_proveedor_id, documento_id, archivo, archivo_nombre, notas, creado_por)
    values
      (v_mov, null, 'egreso', 'pago_proveedor', v_fecha,
       concat('Anticipo a ', v_prov.nombre, case when v_cotp.id is not null then ' · COTP-' || v_cotp.folio end),
       v_monto, 0, v_forma, v_ref, v_cuenta, v_prov.id, v_cotp.id, v_doc.id, v_doc.archivo, v_doc.nombre_original,
       v_notas, coalesce(auth.jwt() ->> 'email', 'crm'));
    v_tipo := 'anticipo';
  end if;

  if v_doc.id is not null then
    update documentos
       set estado = 'aprobado', movimiento_id = v_mov,
           aprobado_por = coalesce(auth.jwt() ->> 'email', 'crm'), aprobado_en = now(),
           correccion = coalesce(correccion, '{}'::jsonb) || jsonb_build_object('registrado_como', v_tipo)
     where id = v_doc.id;
  end if;

  perform _apunta('expediente_movimientos', v_mov, 'registrar_pago_proveedor', null,
                  jsonb_build_object('tipo', v_tipo, 'proveedor', v_prov.nombre, 'monto', v_monto,
                                     'cfdi', v_cfdi.id, 'cotizacion_proveedor', v_cotp.id,
                                     'confirmado_pese_a', to_jsonb(v_parecidos)), 'oficina');
  return jsonb_build_object('ok', true, 'movimiento_id', v_mov, 'tipo', v_tipo, 'proveedor', v_prov.nombre,
                            'saldo', case when v_cfdi.id is not null then (v_r ->> 'saldo')::numeric end);
end $fn$;

-- ---- anticipos: los pagos a proveedor que todavía no tienen factura ----
create or replace function anticipos_proveedor(p_proveedor uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
begin
  if not es_admin() then
    raise exception 'Solo el administrador ve los anticipos a proveedores.' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'movimiento_id', m.id, 'fecha', m.fecha, 'monto', m.monto, 'referencia', m.referencia,
             'concepto', m.concepto, 'proveedor_id', m.proveedor_id, 'proveedor', p.nombre,
             'cotizacion_proveedor', (select 'COTP-' || c.folio from cotizaciones_proveedor c where c.id = m.cotizacion_proveedor_id),
             'archivo', m.archivo,
             'facturas', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'cfdi_id', f.id, 'serie', f.serie, 'folio', f.folio,
                        'fecha', (f.fecha at time zone 'America/Merida')::date, 'saldo', _saldo_cfdi(f.id),
                        'exacta', abs(_saldo_cfdi(f.id) - m.monto) <= 0.01)
                      order by abs(_saldo_cfdi(f.id) - m.monto), f.fecha)
                 from cfdi f
                where f.proveedor_id = m.proveedor_id and f.sentido = 'recibido' and f.por_pagar
                  and f.estado_sat <> 'cancelado' and _saldo_cfdi(f.id) >= m.monto - 0.01), '[]'::jsonb))
           order by m.fecha, m.created_at)
      from expediente_movimientos m
      left join proveedores p on p.id = m.proveedor_id
     where m.tipo = 'egreso' and m.categoria = 'pago_proveedor' and m.cfdi_id is null
       and m.proveedor_id is not null
       and (p_proveedor is null or m.proveedor_id = p_proveedor)
  ), '[]'::jsonb);
end $fn$;

-- Aplica un anticipo a una factura del mismo proveedor: el saldo de la factura baja y el pago gana
-- el IVA en proporción. El anticipo no puede ser mayor que lo que falta por pagar.
create or replace function aplicar_anticipo(p_movimiento uuid, p_cfdi uuid)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_m     expediente_movimientos;
  v_c     cfdi;
  v_saldo numeric;
  v_iva   numeric;
begin
  if not es_admin() then
    raise exception 'Solo el administrador aplica anticipos.' using errcode = '42501';
  end if;
  v_m := (select m from expediente_movimientos m where m.id = p_movimiento);
  if v_m.id is null or v_m.tipo <> 'egreso' or v_m.categoria <> 'pago_proveedor' then
    raise exception 'Ese movimiento no es un pago a proveedor.' using errcode = '22023';
  end if;
  if v_m.cfdi_id is not null then
    raise exception 'Ese pago ya está aplicado a una factura.' using errcode = '22023';
  end if;
  v_c := (select c from cfdi c where c.id = p_cfdi);
  if v_c.id is null or v_c.sentido <> 'recibido' or not v_c.por_pagar or v_c.estado_sat = 'cancelado' then
    raise exception 'Esa factura no está por pagar.' using errcode = '22023';
  end if;
  if v_m.proveedor_id is distinct from v_c.proveedor_id then
    raise exception 'La factura es de otro proveedor.' using errcode = '22023';
  end if;
  v_saldo := _saldo_cfdi(p_cfdi);
  if v_m.monto > v_saldo + 0.01 then
    raise exception 'El anticipo (%) es mayor que lo que falta por pagar de esa factura (%).',
      to_char(v_m.monto, 'FM$999,999,990.00'), to_char(v_saldo, 'FM$999,999,990.00') using errcode = '22023';
  end if;
  v_iva := case when v_c.total > 0 then least(round(v_c.iva_trasladado * v_m.monto / v_c.total, 2), v_m.monto) else 0 end;
  update expediente_movimientos
     set cfdi_id = p_cfdi, iva = v_iva,
         notas = nullif(concat_ws(' · ', notas, format('Anticipo aplicado a la factura %s', nullif(concat_ws(' ', v_c.serie, v_c.folio), ''))), '')
   where id = p_movimiento;
  perform _apunta('expediente_movimientos', p_movimiento, 'aplicar_anticipo', jsonb_build_object('cfdi_id', null, 'iva', v_m.iva),
                  jsonb_build_object('cfdi_id', p_cfdi, 'iva', v_iva, 'saldo_factura', v_saldo - v_m.monto), 'oficina');
  return jsonb_build_object('ok', true, 'saldo', round(v_saldo - v_m.monto, 2));
end $fn$;

-- Lo contrario, por si se aplicó a la factura equivocada: vuelve a ser anticipo, sin IVA.
create or replace function quitar_anticipo_de_factura(p_movimiento uuid, p_motivo text)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_m expediente_movimientos;
begin
  if not es_admin() then
    raise exception 'Solo el administrador corrige anticipos.' using errcode = '42501';
  end if;
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Escribe por qué.' using errcode = '22023';
  end if;
  v_m := (select m from expediente_movimientos m where m.id = p_movimiento);
  if v_m.id is null or v_m.categoria <> 'pago_proveedor' or v_m.cfdi_id is null then
    raise exception 'Ese movimiento no es un anticipo aplicado a una factura.' using errcode = '22023';
  end if;
  update expediente_movimientos set cfdi_id = null, iva = 0 where id = p_movimiento;
  perform _apunta('expediente_movimientos', p_movimiento, 'quitar_anticipo_de_factura',
                  jsonb_build_object('cfdi_id', v_m.cfdi_id, 'iva', v_m.iva),
                  jsonb_build_object('cfdi_id', null, 'motivo', trim(p_motivo)), 'oficina');
  return jsonb_build_object('ok', true);
end $fn$;

-- ---- la carpeta del proveedor sabe de anticipos ----
-- Misma función de la 80 con un dato más: lo que se le ha dado como anticipo y aún no tiene factura.
create or replace function _resumen_proveedor(p_id uuid) returns jsonb
language sql stable security definer set search_path = public as $fn$
  select jsonb_build_object(
    'compras', (select count(*) from compras c where c.proveedor_id = p_id and c.estado <> 'cancelada'),
    'comprado_12m', coalesce((select sum(c.total) from compras c
                               where c.proveedor_id = p_id and c.estado <> 'cancelada'
                                 and c.fecha >= _hoy_merida() - 365), 0),
    'facturas', (select count(*) from cfdi f where f.proveedor_id = p_id and f.estado_sat <> 'cancelado'),
    'por_pagar', coalesce((select sum(_saldo_cfdi(f.id)) from cfdi f
                            where f.proveedor_id = p_id and f.por_pagar and f.estado_sat <> 'cancelado'), 0),
    'vencido', coalesce((select sum(_saldo_cfdi(f.id)) from cfdi f
                          where f.proveedor_id = p_id and f.por_pagar and f.estado_sat <> 'cancelado'
                            and f.vence < _hoy_merida()), 0),
    'pagado_12m', coalesce((select sum(m.monto) from expediente_movimientos m
                             where m.proveedor_id = p_id and m.tipo = 'egreso'
                               and m.fecha >= _hoy_merida() - 365), 0),
    'anticipos', coalesce((select sum(m.monto) from expediente_movimientos m
                            where m.proveedor_id = p_id and m.tipo = 'egreso' and m.categoria = 'pago_proveedor'
                              and m.cfdi_id is null), 0),
    'productos', (select count(*) from producto_proveedores pp where pp.proveedor_id = p_id),
    'pedidos_abiertos', (select count(*) from requisiciones r
                          where r.proveedor_id = p_id and r.estado in ('pendiente', 'pedida')),
    'ultima', greatest((select max(c.fecha) from compras c where c.proveedor_id = p_id),
                       (select max(f.fecha)::date from cfdi f where f.proveedor_id = p_id),
                       (select max(m.fecha) from expediente_movimientos m where m.proveedor_id = p_id),
                       (select max(r.created_at)::date from requisiciones r where r.proveedor_id = p_id))
  )
$fn$;
revoke execute on function _resumen_proveedor(uuid) from public, anon, authenticated;

revoke execute on function opciones_pago_proveedor(text, numeric), registrar_pago_proveedor(jsonb, boolean),
  anticipos_proveedor(uuid), aplicar_anticipo(uuid, uuid), quitar_anticipo_de_factura(uuid, text)
  from public, anon;
grant execute on function opciones_pago_proveedor(text, numeric), registrar_pago_proveedor(jsonb, boolean),
  anticipos_proveedor(uuid), aplicar_anticipo(uuid, uuid), quitar_anticipo_de_factura(uuid, text)
  to authenticated;

notify pgrst, 'reload schema';

insert into _migraciones (archivo, tipo) values ('85_pagos_proveedor.sql', 'esquema')
on conflict (archivo) do nothing;
