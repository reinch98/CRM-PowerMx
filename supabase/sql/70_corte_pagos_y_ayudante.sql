-- ============================================================================
-- 70 · Tarifa base del ayudante y corte de fecha para el pago a técnicos
--
-- Requiere el 66 y el 67 ya aplicados (lo están desde el 09/10/2026). Va en un script aparte y no
-- dentro del 66/67 porque esos ya corrieron: el registro `_migraciones` (68) los da por aplicados.
--
-- 1. "El ayudante cobra al menos 300 por servicio" (Caña, 09/10/2026): se siembra una tarifa general
--    de 300 para el ayudante en los cinco tipos de servicio. Un servicio que pague más lleva su propia
--    tarifa; la del responsable la captura Caña en Pago a técnicos → Tarifas.
-- 2. Corte `pagos_tecnico_config.pagar_desde`: antes de este sistema los técnicos se pagaban a mano.
--    Sin un corte, TODAS las órdenes cerradas desde el inicio del CRM saldrían "por pagar" y el técnico
--    vería las viejas "en revisión" para siempre. Las órdenes con fecha anterior se dan por pagadas
--    fuera del sistema y no aparecen ni al admin ni al técnico. Nace con el día en que se aplica este
--    script; se mueve en Pago a técnicos → Tarifas.
--    Lo leen `por_pagar_tecnicos`, `proponer_pago_tecnico` (66) y `mis_comisiones` (67), que se
--    redefinen aquí completas con esa única condición de más.
-- ============================================================================

insert into tarifas_pago_tecnico (tipo_servicio, rol, monto, vigente_desde, notas)
select t, 'ayudante', 300, '2026-01-01', 'Base del ayudante: al menos 300 por servicio'
  from unnest(array['preventivo', 'correctivo', 'instalacion', 'diagnostico', 'visita_tecnica']) as t
 where not exists (select 1 from tarifas_pago_tecnico x
                    where x.tipo_servicio = t and x.rol = 'ayudante' and x.tecnico_id is null);

create table if not exists pagos_tecnico_config (
  id           boolean primary key default true check (id),
  pagar_desde  date not null default current_date,
  updated_at   timestamptz not null default now()
);
insert into pagos_tecnico_config (id) values (true) on conflict (id) do nothing;

alter table pagos_tecnico_config enable row level security;
drop policy if exists admin_pagos_config on pagos_tecnico_config;
create policy admin_pagos_config on pagos_tecnico_config for all to authenticated using (es_admin()) with check (es_admin());
revoke all on pagos_tecnico_config from anon;
grant select, insert, update on pagos_tecnico_config to authenticated;

create or replace function _pagar_desde() returns date
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select pagar_desde from pagos_tecnico_config where id), current_date);
$$;
revoke execute on function _pagar_desde() from public, anon, authenticated;

-- ---- por_pagar_tecnicos (66) + corte ----
create or replace function por_pagar_tecnicos(p_hasta date default current_date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_res jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador ve los pagos a técnicos.' using errcode = '42501';
  end if;

  v_res := (
    with servicios as (
      select o.id as orden_id, o.fecha, o.tipo_servicio, o.tecnico_id as persona, 'responsable'::text as rol
        from ordenes_servicio o where o.estado = 'cerrada' and o.tecnico_id is not null
                                  and o.fecha <= p_hasta and o.fecha >= _pagar_desde()
      union all
      select o.id, o.fecha, o.tipo_servicio, o.tecnico2_id, 'ayudante'
        from ordenes_servicio o where o.estado = 'cerrada' and o.tecnico2_id is not null
                                  and o.fecha <= p_hasta and o.fecha >= _pagar_desde()
    ), pendientes as (
      select s.*, _tarifa_pago_tecnico(s.persona, s.tipo_servicio, s.rol, s.fecha) as tarifa
        from servicios s
       where not exists (select 1 from pagos_tecnico_lineas l
                          where l.orden_id = s.orden_id and l.tecnico_id = s.persona
                            and l.activa and l.clase = 'servicio')
    )
    select coalesce(jsonb_agg(jsonb_build_object(
             'tecnico_id', x.persona,
             'nombre', (select nombre from perfiles where id = x.persona),
             'ordenes', x.n,
             'estimado', x.estimado,
             'sin_tarifa', x.sin_tarifa,
             'mas_antigua', x.mas_antigua) order by x.mas_antigua), '[]'::jsonb)
      from (
        select persona, count(*) as n,
               coalesce(sum(tarifa), 0) as estimado,
               count(*) filter (where tarifa is null) as sin_tarifa,
               min(fecha) as mas_antigua
          from pendientes group by persona
      ) x
  );
  return v_res;
end;
$$;
revoke execute on function por_pagar_tecnicos(date) from public, anon;
grant execute on function por_pagar_tecnicos(date) to authenticated;

-- ---- proponer_pago_tecnico (66) + corte ----
create or replace function proponer_pago_tecnico(p_tecnico uuid, p_desde date, p_hasta date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pago_id uuid;
  v_sin_tarifa jsonb := '[]'::jsonb;
  v_n int := 0;
  r record;
  v_monto numeric;
begin
  if not es_admin() then
    raise exception 'Solo el administrador propone pagos a técnicos.' using errcode = '42501';
  end if;
  if p_desde is null or p_hasta is null or p_hasta < p_desde then
    raise exception 'El periodo no es válido.' using errcode = '22023';
  end if;
  if (select id from perfiles where id = p_tecnico) is null then
    raise exception 'Ese técnico no existe.' using errcode = '22023';
  end if;

  -- Ficha de pago: si no tenía, nace con los valores de hoy (por servicio, sin alta).
  insert into tecnicos_pago (perfil_id) values (p_tecnico) on conflict (perfil_id) do nothing;

  -- Un borrador abierto se rehace; uno ya aprobado estorba (primero hay que pagarlo o cancelarlo).
  if (select count(*) from pagos_tecnico where tecnico_id = p_tecnico and estado = 'aprobado') > 0 then
    raise exception 'Ese técnico tiene un pago aprobado sin registrar. Regístralo o cancélalo antes de proponer otro.'
      using errcode = '22023';
  end if;

  v_pago_id := (select id from pagos_tecnico where tecnico_id = p_tecnico and estado = 'propuesto');
  if v_pago_id is null then
    v_pago_id := gen_random_uuid();
    insert into pagos_tecnico (id, tecnico_id, periodo_desde, periodo_hasta, creado_por)
    values (v_pago_id, p_tecnico, p_desde, p_hasta, coalesce(auth.jwt() ->> 'email', 'crm'));
  else
    -- Se conservan los ajustes manuales; las líneas de servicio se vuelven a calcular.
    delete from pagos_tecnico_lineas where pago_id = v_pago_id and clase = 'servicio';
    update pagos_tecnico set periodo_desde = p_desde, periodo_hasta = p_hasta where id = v_pago_id;
  end if;

  for r in
    select s.orden_id, s.fecha, s.tipo_servicio, s.rol, s.cotizacion_id
      from (
        select o.id as orden_id, o.fecha, o.tipo_servicio, 'responsable'::text as rol, o.tecnico_id as persona,
               (select c.cotizacion_id from citas c where c.id = o.cita_id) as cotizacion_id
          from ordenes_servicio o where o.estado = 'cerrada'
        union all
        select o.id, o.fecha, o.tipo_servicio, 'ayudante', o.tecnico2_id,
               (select c.cotizacion_id from citas c where c.id = o.cita_id)
          from ordenes_servicio o where o.estado = 'cerrada'
      ) s
     where s.persona = p_tecnico
       and s.fecha between p_desde and p_hasta
       and s.fecha >= _pagar_desde()          -- lo anterior al corte se pagó fuera del sistema
       and not exists (select 1 from pagos_tecnico_lineas l
                        where l.orden_id = s.orden_id and l.tecnico_id = p_tecnico
                          and l.activa and l.clase = 'servicio')
     order by s.fecha, s.orden_id
  loop
    v_monto := _tarifa_pago_tecnico(p_tecnico, r.tipo_servicio, r.rol, r.fecha);
    if v_monto is null then
      -- Sin tarifa NO se paga ni se inventa una: se avisa para que la captures.
      v_sin_tarifa := v_sin_tarifa || jsonb_build_array(jsonb_build_object(
        'orden_id', r.orden_id, 'fecha', r.fecha, 'tipo_servicio', r.tipo_servicio, 'rol', r.rol));
    else
      insert into pagos_tecnico_lineas (pago_id, tecnico_id, clase, orden_id, cotizacion_id, tipo_servicio, rol, monto)
      values (v_pago_id, p_tecnico, 'servicio', r.orden_id, r.cotizacion_id, r.tipo_servicio, r.rol, v_monto);
      v_n := v_n + 1;
    end if;
  end loop;

  perform _recalcular_pago_tecnico(v_pago_id);
  perform _apunta('pagos_tecnico', v_pago_id, 'proponer_pago_tecnico', null,
                  jsonb_build_object('tecnico_id', p_tecnico, 'desde', p_desde, 'hasta', p_hasta,
                                     'servicios', v_n, 'sin_tarifa', jsonb_array_length(v_sin_tarifa)), 'oficina');

  return jsonb_build_object('ok', true, 'pago_id', v_pago_id, 'servicios', v_n,
                            'total', (select total from pagos_tecnico where id = v_pago_id),
                            'sin_tarifa', v_sin_tarifa);
end;
$$;
revoke execute on function proponer_pago_tecnico(uuid, date, date) from public, anon;
grant execute on function proponer_pago_tecnico(uuid, date, date) to authenticated;

-- ---- mis_comisiones (67) + corte ----
create or replace function mis_comisiones(p_dias int default 120) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_yo uuid := auth.uid();
  v_ordenes jsonb;
  v_ajustes jsonb;
  v_por_cobrar numeric;
  v_pagado_mes numeric;
  v_revision int;
  v_dias int := least(greatest(coalesce(p_dias, 120), 1), 400);
begin
  if v_yo is null or coalesce(mi_rol(), '') not in ('tecnico', 'admin') then
    return jsonb_build_object('ordenes', '[]'::jsonb, 'ajustes', '[]'::jsonb,
                              'resumen', jsonb_build_object('por_cobrar', 0, 'pagado_mes', 0, 'en_revision', 0));
  end if;

  v_ordenes := coalesce((
    select jsonb_agg(jsonb_build_object(
             'orden_id', m.orden_id, 'folio', m.folio, 'fecha', m.fecha,
             'tipo_servicio', m.tipo_servicio, 'rol', m.rol,
             'cliente', (select nombre from clientes where id = m.cliente_id),
             'estado', case x.pago_estado when 'pagado' then 'pagada' when 'aprobado' then 'aprobada' else 'en_revision' end,
             'monto', x.monto, 'pago_folio', x.folio, 'fecha_pago', x.fecha_pago)
           order by m.fecha desc, m.folio desc)
      from (
        select o.id as orden_id, o.folio, o.fecha, o.tipo_servicio, o.cliente_id, 'responsable'::text as rol
          from ordenes_servicio o
         where o.tecnico_id = v_yo and o.estado = 'cerrada' and o.fecha >= current_date - v_dias
           and o.fecha >= _pagar_desde()   -- lo anterior al corte (66) se pagó fuera del sistema
        union all
        select o.id, o.folio, o.fecha, o.tipo_servicio, o.cliente_id, 'ayudante'
          from ordenes_servicio o
         where o.tecnico2_id = v_yo and o.estado = 'cerrada' and o.fecha >= current_date - v_dias
           and o.fecha >= _pagar_desde()
      ) m
      left join lateral (
        select l.monto, p.estado as pago_estado, p.folio, p.fecha_pago
          from pagos_tecnico_lineas l
          join pagos_tecnico p on p.id = l.pago_id
         where l.orden_id = m.orden_id and l.tecnico_id = v_yo and l.activa and l.clase = 'servicio'
           and p.estado in ('aprobado', 'pagado')
         order by p.created_at desc limit 1
      ) x on true), '[]'::jsonb);

  -- Bonos, descuentos y anticipos ya aprobados: se ven, para que el total cuadre.
  v_ajustes := coalesce((
    select jsonb_agg(jsonb_build_object(
             'concepto', l.concepto, 'monto', l.monto,
             'estado', case p.estado when 'pagado' then 'pagada' else 'aprobada' end,
             'pago_folio', p.folio, 'fecha_pago', p.fecha_pago) order by p.created_at desc)
      from pagos_tecnico_lineas l
      join pagos_tecnico p on p.id = l.pago_id
     where l.tecnico_id = v_yo and l.activa and l.clase = 'ajuste' and p.estado in ('aprobado', 'pagado')
       and p.created_at >= now() - make_interval(days => v_dias)), '[]'::jsonb);

  v_por_cobrar := coalesce((
    select sum(l.monto) from pagos_tecnico_lineas l join pagos_tecnico p on p.id = l.pago_id
     where l.tecnico_id = v_yo and l.activa and p.estado = 'aprobado'), 0);
  v_pagado_mes := coalesce((
    select sum(l.monto) from pagos_tecnico_lineas l join pagos_tecnico p on p.id = l.pago_id
     where l.tecnico_id = v_yo and l.activa and p.estado = 'pagado'
       and date_trunc('month', p.fecha_pago) = date_trunc('month', (now() at time zone 'America/Merida')::date)), 0);
  v_revision := (select count(*) from jsonb_array_elements(v_ordenes) e where e ->> 'estado' = 'en_revision');

  return jsonb_build_object(
    'resumen', jsonb_build_object('por_cobrar', v_por_cobrar, 'pagado_mes', v_pagado_mes, 'en_revision', v_revision),
    'ordenes', v_ordenes, 'ajustes', v_ajustes);
end;
$$;
revoke execute on function mis_comisiones(int) from public, anon;
grant execute on function mis_comisiones(int) to authenticated;

-- Registro (ver 68).
insert into _migraciones (archivo, tipo) values ('70_corte_pagos_y_ayudante.sql', 'esquema')
on conflict (archivo) do nothing;
