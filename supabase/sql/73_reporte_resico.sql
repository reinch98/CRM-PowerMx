-- ============================================================================
-- 73 · Reporte mensual RESICO (persona física) — ESTIMADO para revisar con el contador
--
-- Requiere el 67 y el 72. Caña tributa en RESICO desde el 22/09/2026 (Constancia de Situación Fiscal)
-- y declara IVA mensual. Este reporte NO es una declaración: es el cálculo que el contador revisa.
--
-- Reglas (flujo de efectivo):
--   · Ingresos = cobros del mes (Expediente) + otros ingresos. Las aportaciones del dueño NO son ingreso.
--     El IVA de un cobro sale en proporción al de su cotización (iva / total). Base del ISR = sin IVA.
--   · ISR = base × tasa RESICO del tramo que corresponde al TOTAL del mes (no es marginal), menos el ISR
--     que retuvieron clientes personas morales (de las facturas emitidas ligadas a la cotización, en
--     proporción a lo cobrado).
--   · IVA = trasladado cobrado − acreditable pagado (solo egresos con CFDI) − IVA retenido.
--   · Gastos: todos los egresos del mes menos los retiros del dueño. En RESICO los gastos no bajan el ISR;
--     sirven para el IVA y para saber cuánto deja el negocio.
--   · Tasas en `resico_tasas_isr`, editables por año. Las sembradas son la tabla mensual de RESICO para
--     personas físicas tal como la conocemos al 09/10/2026: CONFIRMARLAS CON EL CONTADOR.
-- ============================================================================

alter table empresa_fiscal add column if not exists resico_desde date;
update empresa_fiscal set resico_desde = '2026-09-22' where id and resico_desde is null;

create table if not exists resico_tasas_isr (
  anio        int not null,
  desde       numeric(14, 2) not null,
  hasta       numeric(14, 2) not null,
  tasa        numeric(6, 4) not null check (tasa >= 0 and tasa < 0.5),   -- 0.0100 = 1 %
  notas       text,
  primary key (anio, desde),
  constraint resico_tramo check (hasta >= desde)
);
insert into resico_tasas_isr (anio, desde, hasta, tasa, notas)
select a, t.desde, t.hasta, t.tasa, 'Tabla mensual RESICO personas físicas. Confirmar con el contador.'
  from unnest(array[2026, 2027]) as a,
       (values (0.00, 25000.00, 0.0100), (25000.01, 50000.00, 0.0110), (50000.01, 83333.33, 0.0150),
               (83333.34, 208333.33, 0.0200), (208333.34, 3500000.00, 0.0250)) as t(desde, hasta, tasa)
on conflict (anio, desde) do nothing;

alter table resico_tasas_isr enable row level security;
drop policy if exists admin_resico_tasas on resico_tasas_isr;
create policy admin_resico_tasas on resico_tasas_isr for all to authenticated using (es_admin()) with check (es_admin());
revoke all on resico_tasas_isr from anon;
grant select, insert, update, delete on resico_tasas_isr to authenticated;

-- ---------------------------------------------------------------------------
-- reporte_resico(mes): cualquier día del mes; devuelve el resumen, el detalle y los avisos.
-- ---------------------------------------------------------------------------
create or replace function reporte_resico(p_mes date default current_date) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_inicio_mes date := date_trunc('month', p_mes)::date;
  v_fin date := (date_trunc('month', p_mes) + interval '1 month - 1 day')::date;
  v_resico date;
  v_desde date;
  v_ingresos jsonb;
  v_gastos jsonb;
  v_cobrado numeric; v_iva_trasl numeric; v_base numeric; v_isr_ret numeric; v_iva_ret numeric;
  v_gasto_total numeric; v_iva_acred numeric; v_gasto_sin_cfdi numeric;
  v_tasa numeric; v_isr_causado numeric; v_isr_pagar numeric; v_iva_neto numeric;
  v_acum numeric; v_sin_factura int;
  v_avisos text[] := array[]::text[];
begin
  if not es_admin() then
    raise exception 'Solo el administrador ve el reporte fiscal.' using errcode = '42501';
  end if;
  v_resico := (select resico_desde from empresa_fiscal where id);
  v_desde := greatest(v_inicio_mes, coalesce(v_resico, v_inicio_mes));
  if v_resico is not null and v_fin < v_resico then
    return jsonb_build_object('ok', false, 'motivo', format('Ese mes es anterior a tu alta en RESICO (%s).', to_char(v_resico, 'DD/MM/YYYY')));
  end if;

  -- Ingresos del periodo, con su IVA y retenciones en proporción a lo cobrado.
  v_ingresos := coalesce((
    select jsonb_agg(jsonb_build_object(
             'fecha', x.fecha, 'cliente', x.cliente, 'cotizacion', x.folio, 'concepto', x.concepto,
             'monto', x.monto, 'iva', x.iva, 'base', x.monto - x.iva,
             'isr_retenido', x.isr_ret, 'iva_retenido', x.iva_ret,
             'factura', x.uuids, 'forma', x.forma, 'referencia', x.referencia) order by x.fecha, x.folio)
      from (
        select m.fecha, cl.nombre as cliente, q.folio, m.concepto, m.monto, m.forma, m.referencia,
               case when m.categoria = 'cobro' and coalesce(q.total, 0) > 0
                    then round(m.monto * coalesce(q.iva, 0) / q.total, 2) else coalesce(m.iva, 0) end as iva,
               case when m.categoria = 'cobro' and coalesce(q.total, 0) > 0
                    then round(m.monto / q.total * coalesce((select sum(cf.isr_retenido) from cfdi cf
                          where cf.cotizacion_id = q.id and cf.sentido = 'emitido' and cf.tipo_comprobante = 'I'), 0), 2)
                    else 0 end as isr_ret,
               case when m.categoria = 'cobro' and coalesce(q.total, 0) > 0
                    then round(m.monto / q.total * coalesce((select sum(cf.iva_retenido) from cfdi cf
                          where cf.cotizacion_id = q.id and cf.sentido = 'emitido' and cf.tipo_comprobante = 'I'), 0), 2)
                    else 0 end as iva_ret,
               (select string_agg(cf.uuid_fiscal, ', ') from cfdi cf
                 where cf.cotizacion_id = m.cotizacion_id and cf.sentido = 'emitido' and cf.tipo_comprobante = 'I') as uuids
          from expediente_movimientos m
          left join cotizaciones q on q.id = m.cotizacion_id
          left join clientes cl on cl.id = q.cliente_id
         where m.tipo = 'ingreso' and m.categoria in ('cobro', 'otro_ingreso')
           and m.fecha between v_desde and v_fin
      ) x), '[]'::jsonb);

  -- Gastos del periodo (sin retiros del dueño). Solo los que tienen CFDI acreditan IVA.
  v_gastos := coalesce((
    select jsonb_agg(jsonb_build_object(
             'fecha', m.fecha, 'categoria', m.categoria, 'concepto', m.concepto,
             'proveedor', cf.nombre_emisor, 'rfc', cf.rfc_emisor, 'factura', cf.uuid_fiscal,
             'monto', m.monto, 'iva', case when m.cfdi_id is not null then m.iva else 0 end,
             'con_cfdi', m.cfdi_id is not null, 'cotizacion', q.folio) order by m.fecha)
      from expediente_movimientos m
      left join cfdi cf on cf.id = m.cfdi_id
      left join cotizaciones q on q.id = m.cotizacion_id
     where m.tipo = 'egreso' and m.categoria <> 'retiro_dueno'
       and m.fecha between v_desde and v_fin), '[]'::jsonb);

  v_cobrado := coalesce((select sum((e ->> 'monto')::numeric) from jsonb_array_elements(v_ingresos) e), 0);
  v_iva_trasl := coalesce((select sum((e ->> 'iva')::numeric) from jsonb_array_elements(v_ingresos) e), 0);
  v_isr_ret := coalesce((select sum((e ->> 'isr_retenido')::numeric) from jsonb_array_elements(v_ingresos) e), 0);
  v_iva_ret := coalesce((select sum((e ->> 'iva_retenido')::numeric) from jsonb_array_elements(v_ingresos) e), 0);
  v_base := v_cobrado - v_iva_trasl;
  v_gasto_total := coalesce((select sum((e ->> 'monto')::numeric) from jsonb_array_elements(v_gastos) e), 0);
  v_iva_acred := coalesce((select sum((e ->> 'iva')::numeric) from jsonb_array_elements(v_gastos) e), 0);
  v_gasto_sin_cfdi := coalesce((select sum((e ->> 'monto')::numeric) from jsonb_array_elements(v_gastos) e
                                 where not (e ->> 'con_cfdi')::boolean), 0);

  v_tasa := (select t.tasa from resico_tasas_isr t
              where t.anio = extract(year from v_inicio_mes)::int and v_base between t.desde and t.hasta
              order by t.desde desc limit 1);
  if v_base > 0 and v_tasa is null then
    v_avisos := array_append(v_avisos, format('No hay tasa de ISR capturada para %s con ingresos de $%s: captúrala en Ajustes.',
                                              extract(year from v_inicio_mes), to_char(v_base, 'FM999,999,990.00')));
  end if;
  v_isr_causado := round(v_base * coalesce(v_tasa, 0), 2);
  v_isr_pagar := greatest(v_isr_causado - v_isr_ret, 0);
  v_iva_neto := round(v_iva_trasl - v_iva_acred - v_iva_ret, 2);

  -- Acumulado del año (desde el alta en RESICO) contra el tope de 3.5 millones.
  v_acum := coalesce((
    select sum(case when m.categoria = 'cobro' and coalesce(q.total, 0) > 0
                    then m.monto - round(m.monto * coalesce(q.iva, 0) / q.total, 2)
                    else m.monto - coalesce(m.iva, 0) end)
      from expediente_movimientos m left join cotizaciones q on q.id = m.cotizacion_id
     where m.tipo = 'ingreso' and m.categoria in ('cobro', 'otro_ingreso')
       and m.fecha between greatest(date_trunc('year', v_inicio_mes)::date, coalesce(v_resico, date_trunc('year', v_inicio_mes)::date)) and v_fin), 0);

  v_sin_factura := (select count(*) from jsonb_array_elements(v_ingresos) e where coalesce(e ->> 'factura', '') = '');
  if v_sin_factura > 0 then
    v_avisos := array_append(v_avisos, format('%s %s sin factura emitida ligada: en RESICO todo ingreso se factura. Sube el XML en Finanzas y lígalo a su cotización.',
                                              v_sin_factura, case when v_sin_factura = 1 then 'cobro' else 'cobros' end));
  end if;
  if v_gasto_sin_cfdi > 0 then
    v_avisos := array_append(v_avisos, format('$%s de gastos sin CFDI: su IVA no se acredita.', to_char(v_gasto_sin_cfdi, 'FM999,999,990.00')));
  end if;
  if v_acum > 3500000 * 0.8 then
    v_avisos := array_append(v_avisos, format('Llevas $%s en el año: %s%% del tope de RESICO ($3,500,000).',
                                              to_char(v_acum, 'FM999,999,990.00'), round(v_acum / 3500000 * 100)));
  end if;
  if v_desde > v_inicio_mes then
    v_avisos := array_append(v_avisos, format('Mes parcial: cuenta desde tu alta en RESICO (%s).', to_char(v_desde, 'DD/MM/YYYY')));
  end if;

  return jsonb_build_object(
    'ok', true,
    'periodo', jsonb_build_object('desde', v_desde, 'hasta', v_fin,
                                  'limite_pago', (v_inicio_mes + interval '1 month')::date + 16),
    'ingresos', jsonb_build_object('cobrado', v_cobrado, 'iva', v_iva_trasl, 'base', v_base,
                                   'isr_retenido', v_isr_ret, 'iva_retenido', v_iva_ret,
                                   'sin_factura', v_sin_factura, 'detalle', v_ingresos),
    'isr', jsonb_build_object('tasa', v_tasa, 'causado', v_isr_causado, 'retenido', v_isr_ret, 'a_pagar', v_isr_pagar),
    'iva', jsonb_build_object('trasladado', v_iva_trasl, 'acreditable', v_iva_acred, 'retenido', v_iva_ret,
                              'a_cargo', greatest(v_iva_neto, 0), 'a_favor', greatest(-v_iva_neto, 0)),
    'gastos', jsonb_build_object('total', v_gasto_total, 'iva_acreditable', v_iva_acred,
                                 'sin_cfdi', v_gasto_sin_cfdi, 'detalle', v_gastos),
    'anual', jsonb_build_object('acumulado', v_acum, 'tope', 3500000, 'pct', round(v_acum / 3500000 * 100, 1)),
    'avisos', to_jsonb(v_avisos));
end;
$$;
revoke execute on function reporte_resico(date) from public, anon;
grant execute on function reporte_resico(date) to authenticated;

-- Registro (ver 68).
insert into _migraciones (archivo, tipo) values ('73_reporte_resico.sql', 'esquema')
on conflict (archivo) do nothing;
