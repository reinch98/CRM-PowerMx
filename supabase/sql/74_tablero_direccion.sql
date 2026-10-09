-- ============================================================================
-- 74 · Tablero de dirección
--
-- Requiere el 61 (expediente_resumen), 63 (cobranza), 66–67 (pagos a técnicos y libro). Una sola
-- llamada, solo admin, con todo lo que dirección necesita ver de un vistazo para un periodo de N meses.
-- La utilidad de cada cotización sale de `expediente_resumen` (la MISMA fórmula del Expediente; la del
-- cierre congelado si ya se cerró): no hay un segundo cálculo que pueda contradecirlo.
--
-- Líneas de negocio (_linea_de_cotizacion):
--   rentas      = cotización de tipo renta
--   polizas     = mantenimiento a un equipo en póliza
--   solar       = equipo solar o batería; sin equipo, partidas de panel/inversor/accesorio/paquete/batería
--   generadores = equipo generador; sin equipo, partidas de generador o refacción
--   otros       = lo que no se puede clasificar
-- ============================================================================

create or replace function _linea_de_cotizacion(p_cot uuid) returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when q.tipo = 'renta' then 'rentas'
    when q.tipo = 'mantenimiento' and coalesce(e.en_poliza, false) then 'polizas'
    when e.tipo in ('solar', 'bateria') then 'solar'
    when e.tipo = 'generador' then 'generadores'
    when exists (select 1 from jsonb_array_elements(coalesce(q.partidas, '[]'::jsonb)) x
                   join productos p on p.id::text = x ->> 'producto_id'
                  where p.categoria in ('panel', 'inversor', 'accesorio_solar', 'paquete_solar', 'bateria')) then 'solar'
    when exists (select 1 from jsonb_array_elements(coalesce(q.partidas, '[]'::jsonb)) x
                   join productos p on p.id::text = x ->> 'producto_id'
                  where p.categoria in ('generador', 'refaccion')) then 'generadores'
    when exists (select 1 from jsonb_array_elements(coalesce(q.partidas, '[]'::jsonb)) x
                   join productos p on p.id::text = x ->> 'producto_id'
                  where p.categoria = 'renta') then 'rentas'
    else 'otros'
  end
  from cotizaciones q
  left join equipos e on e.id = q.equipo_id
  where q.id = p_cot;
$$;
revoke execute on function _linea_de_cotizacion(uuid) from public, anon, authenticated;

create or replace function tablero_direccion(p_meses int default 6) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_meses int := least(greatest(coalesce(p_meses, 6), 1), 24);
  v_desde date;
  v_hasta date := current_date;
  v_mensual jsonb;
  v_lineas jsonb;
  v_cxc jsonb;
  v_tecnicos jsonb;
  v_operacion jsonb;
  v_ingresos numeric;
  v_gastos numeric;
begin
  if not es_admin() then
    raise exception 'Solo el administrador ve el tablero.' using errcode = '42501';
  end if;
  v_desde := (date_trunc('month', current_date) - make_interval(months => v_meses - 1))::date;

  -- ---- mes a mes (libro: ingresos y gastos del negocio; retiros y aportaciones aparte) ----
  v_mensual := (
    select jsonb_agg(jsonb_build_object(
             'mes', to_char(m, 'YYYY-MM'),
             'ingresos', coalesce((select sum(x.monto) from expediente_movimientos x
                                    where x.tipo = 'ingreso' and x.categoria in ('cobro', 'otro_ingreso')
                                      and date_trunc('month', x.fecha) = m), 0),
             'gastos', coalesce((select sum(x.monto) from expediente_movimientos x
                                  where x.tipo = 'egreso' and x.categoria <> 'retiro_dueno'
                                    and date_trunc('month', x.fecha) = m), 0)) order by m)
      from generate_series(v_desde, date_trunc('month', current_date)::date, interval '1 month') as m);
  v_ingresos := (select sum((e ->> 'ingresos')::numeric) from jsonb_array_elements(v_mensual) e);
  v_gastos := (select sum((e ->> 'gastos')::numeric) from jsonb_array_elements(v_mensual) e);

  -- ---- margen por línea (cotizaciones aceptadas del periodo) ----
  v_lineas := coalesce((
    select jsonb_agg(jsonb_build_object(
             'linea', linea, 'cotizaciones', n, 'cerradas', cerradas,
             'venta', round(venta, 2), 'material', round(material, 2), 'utilidad', round(utilidad, 2),
             'margen_cotizado', case when venta > 0 then round((venta - material) / venta * 100, 1) end,
             'margen_real', case when venta > 0 then round(utilidad / venta * 100, 1) end) order by venta desc)
      from (
        select _linea_de_cotizacion(q.id) as linea, count(*) as n,
               count(*) filter (where q.expediente_cerrado_en is not null) as cerradas,
               sum((r #>> '{ingreso,base}')::numeric) as venta,
               sum((r #>> '{material,total}')::numeric) as material,
               sum(coalesce((q.expediente_cierre ->> 'utilidad')::numeric, (r ->> 'utilidad')::numeric)) as utilidad
          from cotizaciones q
          cross join lateral (select expediente_resumen(q.id) as r) z
         where q.estado = 'aceptada' and q.fecha between v_desde and v_hasta
         group by 1
      ) l), '[]'::jsonb);

  -- ---- por cobrar (aceptadas sin liquidar) ----
  v_cxc := (
    with c as (
      select q.folio, cl.nombre as cliente, q.fecha, current_date - q.fecha as dias,
             greatest(coalesce(q.total, 0) - coalesce((select sum(m.monto) from expediente_movimientos m
                                                         where m.cotizacion_id = q.id and m.tipo = 'ingreso'), 0), 0) as saldo
        from cotizaciones q join clientes cl on cl.id = q.cliente_id
       where q.estado = 'aceptada' and coalesce(q.cobranza_estado, 'pendiente') <> 'liquidada' and coalesce(q.total, 0) > 0
    )
    select jsonb_build_object(
      'total', coalesce(sum(saldo), 0),
      'vencido', coalesce(sum(saldo) filter (where dias > 30), 0),
      'vencidas', count(*) filter (where dias > 30 and saldo > 0),
      'mayores', coalesce((select jsonb_agg(jsonb_build_object('folio', folio, 'cliente', cliente, 'saldo', saldo, 'dias', dias)
                                            order by saldo desc)
                             from (select * from c where saldo > 0 order by saldo desc limit 5) t), '[]'::jsonb))
      from c where saldo > 0);

  -- ---- técnicos: órdenes, pago y lo que facturaron sus servicios ----
  v_tecnicos := coalesce((
    select jsonb_agg(jsonb_build_object(
             'tecnico_id', t.id, 'nombre', t.nombre, 'ordenes', t.ordenes, 'pago', t.pago,
             'ingreso', round(t.ingreso, 2),
             'pago_pct', case when t.ingreso > 0 then round(t.pago / t.ingreso * 100, 1) end) order by t.ordenes desc)
      from (
        select p.id, p.nombre,
               (select count(*) from ordenes_servicio o
                 where o.estado = 'cerrada' and o.fecha between v_desde and v_hasta
                   and (o.tecnico_id = p.id or o.tecnico2_id = p.id)) as ordenes,
               coalesce((select sum(l.monto) from pagos_tecnico_lineas l
                          join pagos_tecnico pg on pg.id = l.pago_id
                          join ordenes_servicio o on o.id = l.orden_id
                         where l.tecnico_id = p.id and l.activa and l.clase = 'servicio'
                           and pg.estado in ('aprobado', 'pagado') and o.fecha between v_desde and v_hasta), 0) as pago,
               -- Lo que facturó lo que hizo como responsable: la base de la cotización repartida entre
               -- las órdenes de esa cotización (una instalación de tres visitas no se cuenta tres veces).
               coalesce((select sum((q.total - coalesce(q.iva, 0))
                                    / nullif((select count(*) from ordenes_servicio o2 join citas c2 on c2.id = o2.cita_id
                                               where c2.cotizacion_id = q.id), 0))
                           from ordenes_servicio o join citas c on c.id = o.cita_id join cotizaciones q on q.id = c.cotizacion_id
                          where o.tecnico_id = p.id and o.estado = 'cerrada' and o.fecha between v_desde and v_hasta), 0) as ingreso
          from perfiles p
         where p.rol = 'tecnico' and coalesce(p.activo, true)
      ) t), '[]'::jsonb);

  -- ---- operación ----
  v_operacion := jsonb_build_object(
    'ordenes_abiertas', (select count(*) from ordenes_servicio where estado = 'abierta'),
    'mas_antigua_dias', (select current_date - min(fecha) from ordenes_servicio where estado = 'abierta'),
    'por_programar', (select count(*) from citas where estado = 'por_programar'),
    'dias_respuesta', (select round(avg(o.fecha - c.created_at::date), 1)
                         from ordenes_servicio o join citas c on c.id = o.cita_id
                        where o.estado = 'cerrada' and o.fecha between v_desde and v_hasta),
    'cerradas', (select count(*) from ordenes_servicio where estado = 'cerrada' and fecha between v_desde and v_hasta),
    'en_poliza', (select count(*) from equipos where en_poliza),
    'polizas_vencidas', (select count(*) from equipos where en_poliza and proximo_mantenimiento < current_date));

  return jsonb_build_object(
    'periodo', jsonb_build_object('desde', v_desde, 'hasta', v_hasta, 'meses', v_meses),
    'resumen', jsonb_build_object('ingresos', coalesce(v_ingresos, 0), 'gastos', coalesce(v_gastos, 0),
                                  'resultado', coalesce(v_ingresos, 0) - coalesce(v_gastos, 0)),
    'mensual', coalesce(v_mensual, '[]'::jsonb),
    'lineas', v_lineas,
    'cxc', coalesce(v_cxc, jsonb_build_object('total', 0, 'vencido', 0, 'vencidas', 0, 'mayores', '[]'::jsonb)),
    'tecnicos', v_tecnicos,
    'operacion', v_operacion);
end;
$$;
revoke execute on function tablero_direccion(int) from public, anon;
grant execute on function tablero_direccion(int) to authenticated;

-- Registro (ver 68).
insert into _migraciones (archivo, tipo) values ('74_tablero_direccion.sql', 'esquema')
on conflict (archivo) do nothing;
