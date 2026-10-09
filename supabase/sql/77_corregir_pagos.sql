-- ============================================================================
-- 77 · Corregir pagos ya registrados (a técnicos y a proveedores)
--
-- Requiere el 66/67/70 (pago a técnicos), el 72 (cuentas por pagar) y el 75 (conciliación).
-- Un pago registrado dejó egresos en el libro; corregirlo = DESHACER el registro (se borran esos egresos,
-- queda el rastro en `auditoria`) y volver a capturarlo bien. Nada se edita "por debajo".
--
-- Técnicos: reabrir_pago_tecnico regresa un pago aprobado o pagado a borrador ('propuesto'), donde ya se
--   puede quitar órdenes, agregar bonos o descuentos y, nuevo, cambiar el monto de una orden
--   (fijar_monto_linea_pago). Si estaba pagado, borra sus egresos. Para saber cuáles son, los egresos
--   llevan ahora `pago_tecnico_id` (se llena hacia atrás por la nota "Pago a técnicos PAGO-n" que siempre
--   escribió registrar_pago_tecnico, y la función se redefine para escribirlo).
-- Proveedores: deshacer_pago_cfdi borra un pago registrado desde "Por pagar"; la factura vuelve a deber
--   ese monto (el saldo no se guarda: se calcula). pagos_cfdi_registrados alimenta la lista.
--
-- Candados: un expediente cerrado no se toca (hay que reabrirlo antes; el trigger del 61 lo impediría de
-- todos modos, aquí se dice con palabras); un renglón del banco conciliado con ese egreso vuelve a
-- "pendiente" y se avisa cuántos; cada deshacer exige motivo.
-- ============================================================================

alter table expediente_movimientos add column if not exists pago_tecnico_id uuid references pagos_tecnico(id);
create index if not exists idx_mov_pago_tecnico on expediente_movimientos (pago_tecnico_id) where pago_tecnico_id is not null;

-- Pagos registrados antes de este script: su nota los identifica.
update expediente_movimientos m
   set pago_tecnico_id = p.id
  from pagos_tecnico p
 where m.pago_tecnico_id is null
   and m.categoria = 'tecnico'
   and m.tecnico_id = p.tecnico_id
   and m.notas = format('Pago a técnicos PAGO-%s', p.folio);

-- registrar_pago_tecnico: la del 67 (definición viva del 09/10/2026) + pago_tecnico_id en los dos inserts.
create or replace function registrar_pago_tecnico(p_pago uuid, p_forma text, p_referencia text default null,
                                                  p_fecha date default null, p_archivo text default null,
                                                  p_cuenta uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p pagos_tecnico%rowtype;
  v_nombre text;
  r record;
  v_sin_cot numeric;
  v_n_sin_cot int;
  v_cargados int := 0;
  v_ref text;
begin
  if not es_admin() then
    raise exception 'Solo el administrador registra pagos a técnicos.' using errcode = '42501';
  end if;
  v_p := (select p from pagos_tecnico p where p.id = p_pago);
  if v_p.id is null then raise exception 'Ese pago no existe.' using errcode = '22023'; end if;
  if v_p.estado = 'pagado' then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;
  if v_p.estado <> 'aprobado' then
    raise exception 'Primero aprueba el pago (está %).', v_p.estado using errcode = '22023';
  end if;
  if p_forma is null or p_forma not in ('transferencia', 'efectivo', 'otro') then
    raise exception 'Indica la forma de pago: transferencia, efectivo u otro.' using errcode = '22023';
  end if;
  if p_cuenta is not null and (select id from cuentas_financieras where id = p_cuenta) is null then
    raise exception 'Esa cuenta no existe.' using errcode = '22023';
  end if;

  v_nombre := (select nombre from perfiles where id = v_p.tecnico_id);
  v_ref := coalesce(nullif(trim(p_referencia), ''), 'PAGO-' || v_p.folio);

  for r in
    select l.cotizacion_id, sum(l.monto) as monto, count(*) as n
      from pagos_tecnico_lineas l
     where l.pago_id = p_pago and l.activa and l.clase = 'servicio' and l.cotizacion_id is not null
     group by l.cotizacion_id
  loop
    if r.monto > 0 then
      insert into expediente_movimientos
        (cotizacion_id, tipo, categoria, fecha, concepto, monto, forma, referencia, tecnico_id,
         cuenta_id, archivo, notas, creado_por, pago_tecnico_id)
      values
        (r.cotizacion_id, 'egreso', 'tecnico', coalesce(p_fecha, current_date),
         format('Pago a %s por %s servicio(s)', coalesce(v_nombre, 'técnico'), r.n),
         r.monto, p_forma, v_ref, v_p.tecnico_id, p_cuenta, p_archivo,
         format('Pago a técnicos PAGO-%s', v_p.folio), coalesce(auth.jwt() ->> 'email', 'crm'), p_pago);
      v_cargados := v_cargados + 1;
    end if;
  end loop;

  v_sin_cot := coalesce((select sum(monto) from pagos_tecnico_lineas
                          where pago_id = p_pago and activa and cotizacion_id is null), 0);
  v_n_sin_cot := (select count(*) from pagos_tecnico_lineas
                   where pago_id = p_pago and activa and cotizacion_id is null);
  if v_sin_cot > 0 then
    insert into expediente_movimientos
      (cotizacion_id, tipo, categoria, fecha, concepto, monto, forma, referencia, tecnico_id,
       cuenta_id, archivo, notas, creado_por, pago_tecnico_id)
    values
      (null, 'egreso', 'tecnico', coalesce(p_fecha, current_date),
       format('Pago a %s (%s concepto(s) sin cotización)', coalesce(v_nombre, 'técnico'), v_n_sin_cot),
       v_sin_cot, p_forma, v_ref, v_p.tecnico_id, p_cuenta, p_archivo,
       format('Pago a técnicos PAGO-%s', v_p.folio), coalesce(auth.jwt() ->> 'email', 'crm'), p_pago);
    v_cargados := v_cargados + 1;
  end if;

  update pagos_tecnico
     set estado = 'pagado', forma = p_forma, referencia = nullif(trim(p_referencia), ''),
         fecha_pago = coalesce(p_fecha, current_date), archivo = p_archivo,
         pagado_en = now(), pagado_por = coalesce(auth.jwt() ->> 'email', 'crm')
   where id = p_pago;
  perform _apunta('pagos_tecnico', p_pago, 'registrar_pago_tecnico', null,
                  jsonb_build_object('total', v_p.total, 'forma', p_forma, 'movimientos', v_cargados), 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false, 'expedientes_cargados', v_cargados);
end;
$$;
revoke execute on function registrar_pago_tecnico(uuid, text, text, date, text, uuid) from public, anon;
grant execute on function registrar_pago_tecnico(uuid, text, text, date, text, uuid) to authenticated;

-- Un renglón del banco conciliado con alguno de estos egresos vuelve a "pendiente" (interna).
create or replace function _liberar_banco(p_movimientos uuid[]) returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int;
begin
  update movimientos_banco
     set estado = 'pendiente', movimiento_id = null, nota = null, conciliado_por = null, conciliado_en = null
   where movimiento_id = any(p_movimientos);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function _liberar_banco(uuid[]) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- reabrir_pago_tecnico: aprobado o pagado → borrador. Si estaba pagado, borra sus egresos.
-- ---------------------------------------------------------------------------
create or replace function reabrir_pago_tecnico(p_pago uuid, p_motivo text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p pagos_tecnico%rowtype;
  v_movs uuid[];
  v_cerrada bigint;
  v_banco int := 0;
  v_borrados jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador corrige pagos a técnicos.' using errcode = '42501';
  end if;
  v_p := (select p from pagos_tecnico p where p.id = p_pago);
  if v_p.id is null then raise exception 'Ese pago no existe.' using errcode = '22023'; end if;
  if v_p.estado = 'propuesto' then return jsonb_build_object('ok', true, 'sin_cambio', true); end if;
  if v_p.estado = 'cancelado' then
    raise exception 'Un pago cancelado no se reabre: arma uno nuevo desde "Por pagar".' using errcode = '22023';
  end if;
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Escribe por qué se corrige el pago.' using errcode = '22023';
  end if;
  if exists (select 1 from pagos_tecnico where tecnico_id = v_p.tecnico_id and estado = 'propuesto' and id <> p_pago) then
    raise exception 'Ese técnico ya tiene otro pago en borrador (PAGO-%). Apruébalo o cancélalo antes.',
      (select folio from pagos_tecnico where tecnico_id = v_p.tecnico_id and estado = 'propuesto' and id <> p_pago limit 1)
      using errcode = '22023';
  end if;

  if v_p.estado = 'pagado' then
    v_movs := coalesce((select array_agg(id) from expediente_movimientos where pago_tecnico_id = p_pago), '{}'::uuid[]);
    v_cerrada := (select min(q.folio) from expediente_movimientos m join cotizaciones q on q.id = m.cotizacion_id
                   where m.id = any(v_movs) and q.expediente_cierre is not null);
    if v_cerrada is not null then
      raise exception 'El expediente de la cotización % ya está cerrado. Reábrelo antes de corregir este pago.', v_cerrada
        using errcode = '22023';
    end if;
    v_borrados := (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'cotizacion_id', cotizacion_id, 'monto', monto,
                                                               'fecha', fecha, 'cuenta_id', cuenta_id)), '[]'::jsonb)
                     from expediente_movimientos where id = any(v_movs));
    v_banco := _liberar_banco(v_movs);
    delete from expediente_movimientos where id = any(v_movs);
  end if;

  update pagos_tecnico
     set estado = 'propuesto', forma = null, referencia = null, fecha_pago = null, archivo = null,
         pagado_por = null, pagado_en = null, aprobado_por = null, aprobado_en = null
   where id = p_pago;
  perform _apunta('pagos_tecnico', p_pago, 'reabrir_pago_tecnico',
                  jsonb_build_object('estado', v_p.estado, 'total', v_p.total, 'forma', v_p.forma,
                                     'fecha_pago', v_p.fecha_pago, 'referencia', v_p.referencia, 'archivo', v_p.archivo,
                                     'egresos_borrados', coalesce(v_borrados, '[]'::jsonb)),
                  jsonb_build_object('motivo', trim(p_motivo), 'banco_liberados', v_banco), 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false, 'estaba', v_p.estado,
                            'egresos_borrados', coalesce(jsonb_array_length(v_borrados), 0), 'banco_liberados', v_banco);
end;
$$;
revoke execute on function reabrir_pago_tecnico(uuid, text) from public, anon;
grant execute on function reabrir_pago_tecnico(uuid, text) to authenticated;

-- Cambiar el monto de una orden en un pago en borrador (la tarifa se copió; aquí se corrige a mano).
-- Ojo: volver a armar el pago desde "Por pagar" recalcula las órdenes con la tarifa.
create or replace function fijar_monto_linea_pago(p_linea uuid, p_monto numeric) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_l pagos_tecnico_lineas%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador cambia pagos a técnicos.' using errcode = '42501';
  end if;
  v_l := (select l from pagos_tecnico_lineas l where l.id = p_linea);
  if v_l.id is null or not v_l.activa then raise exception 'Esa línea no existe.' using errcode = '22023'; end if;
  if (select estado from pagos_tecnico where id = v_l.pago_id) <> 'propuesto' then
    raise exception 'Solo se cambia el monto de un pago en borrador.' using errcode = '22023';
  end if;
  if v_l.clase <> 'servicio' then
    raise exception 'Un bono o descuento se quita y se vuelve a agregar.' using errcode = '22023';
  end if;
  if p_monto is null or p_monto < 0 then
    raise exception 'El monto no puede ser negativo.' using errcode = '22023';
  end if;
  if round(p_monto, 2) = v_l.monto then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'total', (select total from pagos_tecnico where id = v_l.pago_id));
  end if;
  update pagos_tecnico_lineas set monto = round(p_monto, 2) where id = p_linea;
  perform _recalcular_pago_tecnico(v_l.pago_id);
  perform _apunta('pagos_tecnico_lineas', p_linea, 'fijar_monto_linea_pago',
                  jsonb_build_object('monto', v_l.monto), jsonb_build_object('monto', round(p_monto, 2)), 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false, 'total', (select total from pagos_tecnico where id = v_l.pago_id));
end;
$$;
revoke execute on function fijar_monto_linea_pago(uuid, numeric) from public, anon;
grant execute on function fijar_monto_linea_pago(uuid, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- Proveedores: los pagos registrados desde "Por pagar" y cómo deshacer uno.
-- ---------------------------------------------------------------------------
create or replace function pagos_cfdi_registrados(p_dias int default 90) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not es_admin() then
    raise exception 'Solo el administrador ve los pagos a proveedores.' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'movimiento_id', m.id, 'fecha', m.fecha, 'monto', m.monto, 'iva', m.iva, 'forma', m.forma,
             'referencia', m.referencia, 'cuenta', k.nombre, 'notas', m.notas,
             'cfdi_id', c.id, 'proveedor', coalesce(c.nombre_emisor, c.rfc_emisor), 'serie', c.serie, 'folio', c.folio,
             'total', c.total, 'saldo', _saldo_cfdi(c.id),
             'conciliado', exists (select 1 from movimientos_banco b where b.movimiento_id = m.id))
           order by m.fecha desc, m.created_at desc)
      from expediente_movimientos m
      join cfdi c on c.id = m.cfdi_id
      left join cuentas_financieras k on k.id = m.cuenta_id
     where m.tipo = 'egreso' and m.cotizacion_id is null
       and c.sentido = 'recibido' and c.por_pagar
       and m.fecha >= current_date - greatest(coalesce(p_dias, 90), 1)), '[]'::jsonb);
end;
$$;
revoke execute on function pagos_cfdi_registrados(int) from public, anon;
grant execute on function pagos_cfdi_registrados(int) to authenticated;

create or replace function deshacer_pago_cfdi(p_movimiento uuid, p_motivo text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_m expediente_movimientos%rowtype;
  v_c cfdi%rowtype;
  v_banco int;
begin
  if not es_admin() then
    raise exception 'Solo el administrador corrige pagos a proveedores.' using errcode = '42501';
  end if;
  v_m := (select m from expediente_movimientos m where m.id = p_movimiento);
  if v_m.id is null then raise exception 'Ese pago no existe.' using errcode = '22023'; end if;
  v_c := (select c from cfdi c where c.id = v_m.cfdi_id);
  if v_m.tipo <> 'egreso' or v_c.id is null or v_c.sentido <> 'recibido' or not v_c.por_pagar or v_m.cotizacion_id is not null then
    raise exception 'Ese movimiento no es un pago de "Por pagar".' using errcode = '22023';
  end if;
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Escribe por qué se deshace el pago.' using errcode = '22023';
  end if;

  v_banco := _liberar_banco(array[p_movimiento]);
  delete from expediente_movimientos where id = p_movimiento;
  perform _apunta('cfdi', v_c.id, 'deshacer_pago_cfdi', to_jsonb(v_m),
                  jsonb_build_object('motivo', trim(p_motivo), 'banco_liberados', v_banco,
                                     'saldo', _saldo_cfdi(v_c.id)), 'oficina');
  return jsonb_build_object('ok', true, 'saldo', _saldo_cfdi(v_c.id), 'banco_liberados', v_banco);
end;
$$;
revoke execute on function deshacer_pago_cfdi(uuid, text) from public, anon;
grant execute on function deshacer_pago_cfdi(uuid, text) to authenticated;

insert into _migraciones (archivo, tipo) values ('77_corregir_pagos.sql', 'esquema') on conflict (archivo) do nothing;
