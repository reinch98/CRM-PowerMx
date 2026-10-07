-- ---------------------------------------------------------------------------
-- 63_cobranza_cotizacion.sql — la cobranza de una cotización se cierra cuando la IA lee el
-- comprobante bancario y su monto cuadra con la cotización.
--
-- Cada COBRO guarda además el monto que la IA leyó en su comprobante (`monto_leido`). Un cobro está
-- VERIFICADO cuando tiene archivo, lo leyó la IA y lo capturado coincide con lo leído (±1 centavo):
-- así un monto tecleado mal, o un comprobante que no es de ese pago, no cierran nada.
--
--   cobranza 'liquidada' = lo verificado alcanza el total de la cotización (±$1)
--   cobranza 'parcial'   = hay cobros, pero lo verificado no alcanza
--   cobranza 'pendiente' = sin cobros
--
-- Lo recalcula la BASE sola cada vez que un cobro entra, cambia o se borra (y si cambia el total de
-- la cotización): borrar el cobro que la cerraba la vuelve a abrir. Un cobro en efectivo o sin
-- comprobante leído suma a "parcial" pero no puede liquidar solo.
--
-- Cuando la diferencia es legítima (una retención de ISR o IVA, un descuento acordado) el admin la da
-- por liquidada A MANO, con motivo escrito (`liquidar_cobranza`); esa decisión no se mueve sola.
--
-- Esto es SOLO el lado del ingreso. No cierra el expediente (la utilidad necesita los gastos): ese
-- cierre sigue siendo `cerrar_expediente` (SQL 61). Solo admin. Repetible.
-- ---------------------------------------------------------------------------

alter table expediente_movimientos add column if not exists leido_ia boolean not null default false;
alter table expediente_movimientos add column if not exists monto_leido numeric(14, 2);

alter table cotizaciones add column if not exists cobranza_estado text not null default 'pendiente';
alter table cotizaciones add column if not exists cobranza_liquidada_en timestamptz;
alter table cotizaciones add column if not exists cobranza_manual boolean not null default false;
alter table cotizaciones add column if not exists cobranza_nota text;

alter table cotizaciones drop constraint if exists cotizaciones_cobranza_estado_check;
alter table cotizaciones add constraint cotizaciones_cobranza_estado_check
  check (cobranza_estado in ('pendiente', 'parcial', 'liquidada'));

-- ---------------------------------------------------------------------------
-- El cálculo, en un solo lugar.
-- ---------------------------------------------------------------------------
create or replace function _recalcular_cobranza(p_cotizacion uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_c cotizaciones%rowtype;
  v_total numeric;
  v_cobrado numeric;
  v_verificado numeric;
  v_estado text;
begin
  v_c := (select c from cotizaciones c where c.id = p_cotizacion);
  if v_c.id is null then return; end if;
  if v_c.cobranza_manual then return; end if;      -- una decisión manual no se mueve sola

  v_total := coalesce(v_c.total, 0);
  v_cobrado := coalesce((select sum(monto) from expediente_movimientos
                          where cotizacion_id = p_cotizacion and tipo = 'ingreso'), 0);
  v_verificado := coalesce((select sum(monto) from expediente_movimientos
                             where cotizacion_id = p_cotizacion and tipo = 'ingreso'
                               and archivo is not null and leido_ia and monto_leido is not null
                               and abs(monto_leido - monto) <= 0.01), 0);

  v_estado := case
                when v_total > 0 and v_verificado >= v_total - 1 then 'liquidada'
                when v_cobrado > 0 then 'parcial'
                else 'pendiente'
              end;

  if v_estado is distinct from v_c.cobranza_estado then
    update cotizaciones
       set cobranza_estado = v_estado,
           cobranza_liquidada_en = case when v_estado = 'liquidada' then now() else null end
     where id = p_cotizacion;
    perform _apunta('cotizaciones', p_cotizacion, 'cobranza_' || v_estado,
                    jsonb_build_object('estado', v_c.cobranza_estado),
                    jsonb_build_object('verificado', v_verificado, 'cobrado', v_cobrado, 'total', v_total),
                    'oficina');
  end if;
end;
$$;

create or replace function _cobranza_tras_movimiento() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(new.tipo, old.tipo) = 'ingreso' then
    perform _recalcular_cobranza(coalesce(new.cotizacion_id, old.cotizacion_id));
  end if;
  return null;
end;
$$;
drop trigger if exists cobranza_tras_movimiento on expediente_movimientos;
create trigger cobranza_tras_movimiento after insert or update or delete on expediente_movimientos
  for each row execute function _cobranza_tras_movimiento();

-- Si cambia el total de la cotización (se edita un borrador), lo ya cobrado se vuelve a comparar.
create or replace function _cobranza_tras_total() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform _recalcular_cobranza(new.id);
  return null;
end;
$$;
drop trigger if exists cobranza_tras_total on cotizaciones;
create trigger cobranza_tras_total after update of total on cotizaciones
  for each row when (old.total is distinct from new.total) execute function _cobranza_tras_total();

-- Lo que ya existía: una cotización con cobros pasa a "parcial". Un cobro viejo no tiene monto leído, así
-- que ninguno liquida solo (se vuelve a leer su comprobante o se da por liquidada a mano).
update cotizaciones set cobranza_estado = 'parcial'
 where cobranza_estado = 'pendiente'
   and exists (select 1 from expediente_movimientos m where m.cotizacion_id = cotizaciones.id and m.tipo = 'ingreso');

-- ---------------------------------------------------------------------------
-- Dar por liquidada a mano (una retención, un descuento) y deshacerlo.
-- ---------------------------------------------------------------------------
create or replace function liquidar_cobranza(p_cotizacion uuid, p_motivo text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_c cotizaciones%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador liquida cobranzas.' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_motivo, ''))) < 3 then
    raise exception 'Escribe por qué se da por liquidada (por ejemplo, una retención o un descuento).' using errcode = '22023';
  end if;
  v_c := (select c from cotizaciones c where c.id = p_cotizacion);
  if v_c.id is null then
    raise exception 'Esa cotización ya no existe.' using errcode = '22023';
  end if;
  if v_c.expediente_cerrado_en is not null then
    raise exception 'Su expediente está cerrado: reábrelo antes de cambiar la cobranza.' using errcode = '22023';
  end if;
  if v_c.cobranza_manual and v_c.cobranza_estado = 'liquidada' then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;

  update cotizaciones
     set cobranza_estado = 'liquidada', cobranza_manual = true,
         cobranza_nota = trim(p_motivo), cobranza_liquidada_en = now()
   where id = p_cotizacion;
  perform _apunta('cotizaciones', p_cotizacion, 'cobranza_liquidada_a_mano',
                  jsonb_build_object('estado', v_c.cobranza_estado),
                  jsonb_build_object('motivo', trim(p_motivo)), 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false);
end;
$$;

create or replace function reabrir_cobranza(p_cotizacion uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_c cotizaciones%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador reabre cobranzas.' using errcode = '42501';
  end if;
  v_c := (select c from cotizaciones c where c.id = p_cotizacion);
  if v_c.id is null then
    raise exception 'Esa cotización ya no existe.' using errcode = '22023';
  end if;
  if v_c.expediente_cerrado_en is not null then
    raise exception 'Su expediente está cerrado: reábrelo antes de cambiar la cobranza.' using errcode = '22023';
  end if;
  if not v_c.cobranza_manual then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;

  -- Se suelta la decisión manual y se vuelve a calcular con lo que de verdad hay.
  update cotizaciones set cobranza_manual = false, cobranza_nota = null where id = p_cotizacion;
  perform _recalcular_cobranza(p_cotizacion);
  -- Si el cálculo coincide con el estado de antes, `_recalcular_cobranza` no toca nada: la fecha de
  -- liquidación sale solo si de verdad queda liquidada.
  update cotizaciones
     set cobranza_liquidada_en = null
   where id = p_cotizacion and cobranza_estado <> 'liquidada';
  perform _apunta('cotizaciones', p_cotizacion, 'cobranza_reabierta',
                  jsonb_build_object('nota', v_c.cobranza_nota), null, 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false);
end;
$$;

-- ---------------------------------------------------------------------------
-- expediente_resumen: la misma de la 61 más el estado de la cobranza y sus avisos.
-- ---------------------------------------------------------------------------
create or replace function expediente_resumen(p_cotizacion uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_c cotizaciones%rowtype;
  v_base numeric;
  v_cobrado numeric;
  v_comprobado numeric;
  v_verificado numeric;
  v_sin_comprobar int;
  v_sin_verificar int;
  v_material jsonb;
  v_material_total numeric;
  v_sin_costo int;
  v_otros numeric;
  v_por_cat jsonb;
  v_utilidad numeric;
  v_avisos text[] := '{}';
  v_hay_tecnico boolean;
begin
  if not es_admin() then
    raise exception 'Solo el administrador ve el expediente.' using errcode = '42501';
  end if;
  v_c := (select c from cotizaciones c where c.id = p_cotizacion);
  if v_c.id is null then
    raise exception 'Esa cotización ya no existe.' using errcode = '22023';
  end if;

  v_base := coalesce(v_c.total, 0) - coalesce(v_c.iva, 0);          -- subtotal − descuento

  v_cobrado := coalesce((select sum(monto) from expediente_movimientos
                          where cotizacion_id = p_cotizacion and tipo = 'ingreso'), 0);
  v_comprobado := coalesce((select sum(monto) from expediente_movimientos
                             where cotizacion_id = p_cotizacion and tipo = 'ingreso' and archivo is not null), 0);
  v_verificado := coalesce((select sum(monto) from expediente_movimientos
                             where cotizacion_id = p_cotizacion and tipo = 'ingreso'
                               and archivo is not null and leido_ia and monto_leido is not null
                               and abs(monto_leido - monto) <= 0.01), 0);
  v_sin_comprobar := (select count(*) from expediente_movimientos
                       where cotizacion_id = p_cotizacion and tipo = 'ingreso' and archivo is null);
  v_sin_verificar := (select count(*) from expediente_movimientos
                       where cotizacion_id = p_cotizacion and tipo = 'ingreso' and archivo is not null
                         and not (leido_ia and monto_leido is not null and abs(monto_leido - monto) <= 0.01));

  if v_c.expediente_cerrado_en is not null and v_c.expediente_cierre ? 'material' then
    v_material := v_c.expediente_cierre -> 'material' -> 'lineas';
  else
    v_material := coalesce((
      select jsonb_agg(jsonb_build_object(
               'producto_id', q.pid, 'sku', p.sku, 'nombre', p.nombre, 'cantidad', q.cant,
               'costo_unitario', coalesce(p.costo, 0), 'importe', round(q.cant * coalesce(p.costo, 0), 2),
               'sin_costo', coalesce(p.costo, 0) = 0) order by p.sku)
        from (select (e ->> 'producto_id')::uuid as pid, sum((e ->> 'cantidad')::numeric) as cant
                from jsonb_array_elements(v_c.partidas) e
               where nullif(e ->> 'producto_id', '') is not null
               group by 1) q
        join productos p on p.id = q.pid), '[]'::jsonb);
  end if;
  v_material_total := coalesce((select sum((l ->> 'importe')::numeric) from jsonb_array_elements(v_material) l), 0);
  v_sin_costo := (select count(*) from jsonb_array_elements(v_material) l where (l ->> 'sin_costo')::boolean);

  v_por_cat := coalesce((
    select jsonb_object_agg(categoria, jsonb_build_object('n', n, 'monto', monto, 'sin_iva', sin_iva))
      from (select categoria, count(*) as n, sum(monto) as monto, sum(monto - iva) as sin_iva
              from expediente_movimientos
             where cotizacion_id = p_cotizacion and tipo = 'egreso'
             group by categoria) x), '{}'::jsonb);
  v_otros := coalesce((select sum(monto - iva) from expediente_movimientos
                        where cotizacion_id = p_cotizacion and tipo = 'egreso'), 0);
  v_hay_tecnico := exists (select 1 from expediente_movimientos
                            where cotizacion_id = p_cotizacion and categoria = 'tecnico');

  v_utilidad := v_base - v_material_total - v_otros;

  -- Avisos (no impiden cerrar; se muestran para cerrar con conocimiento).
  if v_c.estado <> 'aceptada' then
    v_avisos := v_avisos || format('La cotización está en estado %s, no Aceptada.', v_c.estado);
  end if;
  if v_c.total - v_cobrado > 0.009 then
    v_avisos := v_avisos || format('Falta cobrar $%s.', to_char(v_c.total - v_cobrado, 'FM999,999,990.00'));
  end if;
  if v_cobrado - v_c.total > 1 then
    v_avisos := v_avisos || format('Se cobró de más: $%s sobre el total.', to_char(v_cobrado - v_c.total, 'FM999,999,990.00'));
  end if;
  if v_sin_comprobar > 0 then
    v_avisos := v_avisos || format('%s cobro(s) sin comprobante bancario.', v_sin_comprobar);
  end if;
  if v_sin_verificar > 0 then
    v_avisos := v_avisos || format('%s cobro(s) con comprobante que no se ha leído o cuyo monto no coincide.', v_sin_verificar);
  end if;
  if v_sin_costo > 0 then
    v_avisos := v_avisos || format('%s pieza(s) de la cotización sin costo capturado: la utilidad sale inflada.', v_sin_costo);
  end if;
  if not v_hay_tecnico then
    v_avisos := array_append(v_avisos, 'No hay pago de técnicos capturado.'::text);
  end if;

  return jsonb_build_object(
    'folio', v_c.folio, 'estado', v_c.estado,
    'cerrado', v_c.expediente_cerrado_en is not null, 'cerrado_en', v_c.expediente_cerrado_en,
    'ingreso', jsonb_build_object(
      'base', v_base, 'iva', coalesce(v_c.iva, 0), 'total', coalesce(v_c.total, 0),
      'cobrado', v_cobrado, 'comprobado', v_comprobado, 'verificado', v_verificado,
      'por_cobrar', greatest(coalesce(v_c.total, 0) - v_cobrado, 0),
      'cobranza', jsonb_build_object(
        'estado', v_c.cobranza_estado, 'liquidada_en', v_c.cobranza_liquidada_en,
        'manual', v_c.cobranza_manual, 'nota', v_c.cobranza_nota,
        'falta_verificar', greatest(coalesce(v_c.total, 0) - 1 - v_verificado, 0))),
    'material', jsonb_build_object('lineas', v_material, 'total', v_material_total, 'sin_costo', v_sin_costo),
    'egresos', jsonb_build_object('por_categoria', v_por_cat, 'total_sin_iva', v_otros),
    'utilidad', v_utilidad,
    'margen_pct', case when v_base > 0 then round(v_utilidad / v_base * 100, 1) else null end,
    'avisos', to_jsonb(v_avisos));
end;
$$;

revoke all on function _recalcular_cobranza(uuid) from public, anon, authenticated;
revoke all on function _cobranza_tras_movimiento() from public, anon, authenticated;
revoke all on function _cobranza_tras_total() from public, anon, authenticated;
revoke all on function liquidar_cobranza(uuid, text) from public;
revoke all on function liquidar_cobranza(uuid, text) from anon;
revoke all on function reabrir_cobranza(uuid) from public;
revoke all on function reabrir_cobranza(uuid) from anon;
grant execute on function liquidar_cobranza(uuid, text) to authenticated;
grant execute on function reabrir_cobranza(uuid) to authenticated;

notify pgrst, 'reload schema';
