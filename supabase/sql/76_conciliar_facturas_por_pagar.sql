-- ============================================================================
-- 76 · Conciliar un cargo del banco con una factura POR PAGAR
--
-- Requiere el 72 (cuentas por pagar) y el 75 (conciliación). Hasta el 75, un cargo de Banorte que pagaba
-- una factura que estaba en "Por pagar" salía "Sin pareja": el pago todavía no existía en el libro. Ahora
-- proponer_conciliacion también propone esas facturas (mismo monto que lo que falta por pagar, recibida,
-- por pagar, no cancelada en el SAT, fechada entre 30 días antes y 180 después del cargo) y
-- conciliar_factura_banco hace las dos cosas en una sola transacción: registra el pago con pagar_cfdi
-- (egreso con su CFDI y el IVA proporcional, fecha y cuenta del banco) y lo concilia con el renglón.
--
-- Cada candidato lleva ahora `clase`: 'libro' (como en el 75, con movimiento_id) o 'factura' (con cfdi_id).
-- "Seguro" sigue siendo: un solo candidato en total, y ese candidato no le sirve a otro renglón pendiente.
-- proponer_conciliacion y conciliar_seguros se redefinen completas (las del 75 + las facturas).
-- ============================================================================

-- Facturas por pagar que un cargo del banco podría estar pagando (interna).
create or replace function _facturas_banco(p_mov uuid) returns table (cfdi_id uuid, dias int)
language sql
stable
security definer
set search_path = public
as $$
  select c.id, b.fecha - (c.fecha at time zone 'America/Merida')::date
    from movimientos_banco b
    join cfdi c
      on c.sentido = 'recibido' and c.por_pagar and c.estado_sat <> 'cancelado'
     and b.fecha between (c.fecha at time zone 'America/Merida')::date - 30
                     and (c.fecha at time zone 'America/Merida')::date + 180
     and abs(_saldo_cfdi(c.id) - b.cargo) <= 0.01
   where b.id = p_mov and b.cargo > 0
   order by c.vence nulls last, c.fecha;
$$;
revoke execute on function _facturas_banco(uuid) from public, anon, authenticated;

create or replace function proponer_conciliacion(p_estado uuid) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not es_admin() then
    raise exception 'Solo el administrador concilia.' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'mov_banco_id', b.id, 'fecha', b.fecha, 'descripcion', b.descripcion, 'referencia', b.referencia,
             'monto', greatest(b.abono, b.cargo), 'sentido', case when b.abono > 0 then 'entrada' else 'salida' end,
             'candidatos', c.lista || f.lista,
             -- Seguro: un solo candidato, y ese candidato no aparece en ningún otro renglón pendiente.
             'seguro', jsonb_array_length(c.lista || f.lista) = 1
                       and (select count(*) from movimientos_banco b2
                             where b2.estado = 'pendiente' and b2.id <> b.id and b2.cuenta_id = b.cuenta_id
                               and (exists (select 1 from _candidatos_banco(b2.id) k
                                             where k.movimiento_id = nullif((c.lista || f.lista) -> 0 ->> 'movimiento_id', '')::uuid)
                                    or exists (select 1 from _facturas_banco(b2.id) k
                                                where k.cfdi_id = nullif((c.lista || f.lista) -> 0 ->> 'cfdi_id', '')::uuid))) = 0)
           order by b.fecha, b.created_at)
      from movimientos_banco b
      cross join lateral (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'clase', 'libro', 'movimiento_id', m.id, 'fecha', m.fecha, 'dias', k.dias, 'concepto', m.concepto,
                 'categoria', m.categoria, 'cotizacion', q.folio, 'referencia', m.referencia) order by k.dias), '[]'::jsonb) as lista
          from (select * from _candidatos_banco(b.id) limit 5) k
          join expediente_movimientos m on m.id = k.movimiento_id
          left join cotizaciones q on q.id = m.cotizacion_id
      ) c
      cross join lateral (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'clase', 'factura', 'cfdi_id', x.id, 'proveedor', coalesce(x.nombre_emisor, x.rfc_emisor),
                 'serie', x.serie, 'folio', x.folio, 'fecha', (x.fecha at time zone 'America/Merida')::date,
                 'vence', x.vence, 'dias', k.dias, 'categoria', x.categoria, 'total', x.total,
                 'saldo', _saldo_cfdi(x.id)) order by x.vence nulls last, x.fecha), '[]'::jsonb) as lista
          from (select * from _facturas_banco(b.id) limit 5) k
          join cfdi x on x.id = k.cfdi_id
      ) f
     where b.estado_id = p_estado and b.estado = 'pendiente'), '[]'::jsonb);
end;
$$;
revoke execute on function proponer_conciliacion(uuid) from public, anon;
grant execute on function proponer_conciliacion(uuid) to authenticated;

-- Registra el pago de la factura con lo que dice el banco y lo concilia, todo o nada.
create or replace function conciliar_factura_banco(p_mov_banco uuid, p_cfdi uuid) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b movimientos_banco%rowtype;
  v_pago jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador concilia.' using errcode = '42501';
  end if;
  v_b := (select b from movimientos_banco b where b.id = p_mov_banco);
  if v_b.id is null then raise exception 'No encontré el renglón.' using errcode = '22023'; end if;
  if v_b.estado <> 'pendiente' then raise exception 'Ese renglón ya no está pendiente.' using errcode = '22023'; end if;
  if v_b.cargo <= 0 then raise exception 'Una entrada del banco no paga una factura.' using errcode = '22023'; end if;
  if (select estado_sat from cfdi where id = p_cfdi) = 'cancelado' then
    raise exception 'Esa factura está cancelada en el SAT.' using errcode = '22023';
  end if;

  -- pagar_cfdi valida que la factura esté por pagar y que el cargo no pase de lo que falta.
  v_pago := pagar_cfdi(p_cfdi, v_b.cargo, v_b.fecha, v_b.cuenta_id, 'transferencia', v_b.referencia);
  perform conciliar_movimiento(p_mov_banco, (v_pago ->> 'movimiento_id')::uuid);
  return jsonb_build_object('ok', true, 'movimiento_id', v_pago ->> 'movimiento_id', 'saldo', v_pago -> 'saldo');
end;
$$;
revoke execute on function conciliar_factura_banco(uuid, uuid) from public, anon;
grant execute on function conciliar_factura_banco(uuid, uuid) to authenticated;

-- Concilia de un golpe todos los "seguros" del estado (del libro o facturas por pagar).
create or replace function conciliar_seguros(p_estado uuid) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_n int := 0;
begin
  if not es_admin() then
    raise exception 'Solo el administrador concilia.' using errcode = '42501';
  end if;
  for r in
    select (e ->> 'mov_banco_id')::uuid as banco,
           e -> 'candidatos' -> 0 ->> 'clase' as clase,
           nullif(e -> 'candidatos' -> 0 ->> 'movimiento_id', '')::uuid as libro,
           nullif(e -> 'candidatos' -> 0 ->> 'cfdi_id', '')::uuid as factura
      from jsonb_array_elements(proponer_conciliacion(p_estado)) e
     where (e ->> 'seguro')::boolean
  loop
    if (select estado from movimientos_banco where id = r.banco) = 'pendiente' then
      if r.clase = 'factura' then
        perform conciliar_factura_banco(r.banco, r.factura);
        v_n := v_n + 1;
      elsif not exists (select 1 from movimientos_banco where movimiento_id = r.libro) then
        perform conciliar_movimiento(r.banco, r.libro);
        v_n := v_n + 1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'conciliados', v_n);
end;
$$;
revoke execute on function conciliar_seguros(uuid) from public, anon;
grant execute on function conciliar_seguros(uuid) to authenticated;

insert into _migraciones (archivo, tipo) values ('76_conciliar_facturas_por_pagar.sql', 'esquema') on conflict (archivo) do nothing;
