-- ============================================================================
-- 66 · Pago a técnicos por servicio (fijo por tipo de servicio y rol)
--
-- Contexto (Caña, 09/10/2026): los técnicos NO están dados de alta en el IMSS; se les paga una
-- cantidad fija por tipo de servicio (correctivo, preventivo…). Por eso esto NO es nómina legal:
-- no calcula ISR, IMSS, aguinaldo ni timbra nada. Es un control interno de "qué órdenes cerró
-- cada técnico, cuánto toca por cada una y cuándo se le pagó".
--
-- Está pensado para crecer sin romperse el día que haga falta una nómina formal:
--   · `tecnicos_pago` ya lleva el esquema de pago y si está dado de alta (hoy todos 'por_servicio'
--     y sin alta). Un esquema 'fijo' o 'mixto' se agrega sin tocar las demás tablas.
--   · cada línea de pago COPIA la tarifa del momento (como las partidas de una cotización),
--     así que cambiar una tarifa no altera pagos pasados.
--   · el pago es un documento con estados propuesto → aprobado → pagado: el sistema propone,
--     tú apruebas, nada se paga solo.
--
-- Flujo:
--   proponer_pago_tecnico(técnico, desde, hasta) → junta las órdenes CERRADAS del periodo que
--       aún no se han pagado y les pone su tarifa. Las que no tienen tarifa NO se pagan: se avisan.
--   ajustar_pago_tecnico / quitar_linea_pago_tecnico → bonos, descuentos, anticipos o quitar una orden.
--   aprobar_pago_tecnico → congela el total.
--   registrar_pago_tecnico → lo marca pagado y carga el egreso 'tecnico' al expediente de cada
--       cotización (hoy se captura a mano en el Expediente: no repetirlo).
--
-- Una orden nunca se paga dos veces al mismo técnico (índice único sobre líneas activas).
-- Solo admin. Orden de despliegue: este SQL primero, después el código que lo llame.
-- ============================================================================

-- ---- el técnico: cómo se le paga ----

create table if not exists tecnicos_pago (
  perfil_id      uuid primary key references perfiles(id) on delete cascade,
  esquema_pago   text not null default 'por_servicio'
                 check (esquema_pago in ('por_servicio', 'fijo', 'comision', 'mixto')),
  alta_imss      boolean not null default false,
  rfc            text,
  banco          text,
  cuenta_ultimos4 text check (cuenta_ultimos4 is null or cuenta_ultimos4 ~ '^[0-9]{4}$'),
  notas          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- ---- tarifas: cuánto se paga por tipo de servicio y rol ----

create table if not exists tarifas_pago_tecnico (
  id             uuid primary key default gen_random_uuid(),
  tipo_servicio  text not null
                 check (tipo_servicio in ('preventivo', 'correctivo', 'instalacion', 'diagnostico', 'visita_tecnica')),
  rol            text not null default 'responsable' check (rol in ('responsable', 'ayudante')),
  tecnico_id     uuid references perfiles(id) on delete cascade,   -- null = tarifa general; con id, la de esa persona
  monto          numeric(12, 2) not null check (monto >= 0),
  vigente_desde  date not null default current_date,
  vigente_hasta  date,
  notas          text,
  created_at     timestamptz not null default now(),
  constraint tarifas_pago_vigencia check (vigente_hasta is null or vigente_hasta >= vigente_desde)
);
create unique index if not exists tarifas_pago_unica
  on tarifas_pago_tecnico (tipo_servicio, rol, coalesce(tecnico_id, '00000000-0000-0000-0000-000000000000'::uuid), vigente_desde);

-- ---- el pago (documento) y sus líneas ----

create table if not exists pagos_tecnico (
  id             uuid primary key default gen_random_uuid(),
  folio          bigint generated always as identity,
  tecnico_id     uuid not null references perfiles(id),
  periodo_desde  date not null,
  periodo_hasta  date not null,
  estado         text not null default 'propuesto'
                 check (estado in ('propuesto', 'aprobado', 'pagado', 'cancelado')),
  total          numeric(14, 2) not null default 0,
  forma          text,                      -- transferencia | efectivo | otro
  referencia     text,
  fecha_pago     date,
  archivo        text,                      -- comprobante, ruta en el bucket `finanzas`
  motivo_cancelacion text,
  notas          text,
  creado_por     text,
  aprobado_por   text,
  aprobado_en    timestamptz,
  pagado_por     text,
  pagado_en      timestamptz,
  created_at     timestamptz not null default now(),
  constraint pagos_tecnico_periodo check (periodo_hasta >= periodo_desde)
);
create index if not exists idx_pagos_tecnico_tecnico on pagos_tecnico (tecnico_id, estado);
-- Un solo borrador abierto por técnico: proponer de nuevo lo recalcula, no apila.
create unique index if not exists un_pago_propuesto_por_tecnico
  on pagos_tecnico (tecnico_id) where estado = 'propuesto';

create table if not exists pagos_tecnico_lineas (
  id             uuid primary key default gen_random_uuid(),
  pago_id        uuid not null references pagos_tecnico(id) on delete cascade,
  tecnico_id     uuid not null references perfiles(id),
  clase          text not null default 'servicio' check (clase in ('servicio', 'ajuste')),
  orden_id       uuid references ordenes_servicio(id),
  cotizacion_id  uuid references cotizaciones(id),   -- la de la cita de esa orden, si tiene
  tipo_servicio  text,
  rol            text check (rol in ('responsable', 'ayudante')),
  concepto       text,
  monto          numeric(12, 2) not null,            -- copia de la tarifa del momento (un ajuste puede ser negativo)
  activa         boolean not null default true,
  created_at     timestamptz not null default now(),
  constraint pagos_linea_servicio_con_orden check ((clase = 'servicio') = (orden_id is not null)),
  constraint pagos_linea_servicio_positiva check (clase = 'ajuste' or monto >= 0)
);
create index if not exists idx_pagos_lineas_pago on pagos_tecnico_lineas (pago_id);
-- Una orden se paga UNA vez a cada técnico (mientras la línea siga activa).
create unique index if not exists una_orden_un_pago_por_tecnico
  on pagos_tecnico_lineas (orden_id, tecnico_id) where activa and clase = 'servicio';

alter table tecnicos_pago         enable row level security;
alter table tarifas_pago_tecnico  enable row level security;
alter table pagos_tecnico         enable row level security;
alter table pagos_tecnico_lineas  enable row level security;

drop policy if exists admin_tecnicos_pago on tecnicos_pago;
drop policy if exists admin_tarifas_pago  on tarifas_pago_tecnico;
drop policy if exists admin_pagos_tecnico on pagos_tecnico;
drop policy if exists admin_pagos_lineas  on pagos_tecnico_lineas;
-- Aquí vive lo que se le paga a cada persona: un técnico no ve ni lo suyo desde la base.
create policy admin_tecnicos_pago on tecnicos_pago        for all to authenticated using (es_admin()) with check (es_admin());
create policy admin_tarifas_pago  on tarifas_pago_tecnico for all to authenticated using (es_admin()) with check (es_admin());
create policy admin_pagos_tecnico on pagos_tecnico        for all to authenticated using (es_admin()) with check (es_admin());
create policy admin_pagos_lineas  on pagos_tecnico_lineas for all to authenticated using (es_admin()) with check (es_admin());

revoke all on tecnicos_pago, tarifas_pago_tecnico, pagos_tecnico, pagos_tecnico_lineas from anon;

-- El total SIEMPRE lo recalcula esta función: quien escriba directo en el Table Editor no
-- puede dejarlo desactualizado sin que el siguiente cambio lo corrija.
create or replace function _recalcular_pago_tecnico(p_pago uuid) returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total numeric;
begin
  v_total := (select coalesce(sum(monto), 0) from pagos_tecnico_lineas where pago_id = p_pago and activa);
  update pagos_tecnico set total = v_total where id = p_pago;
  return v_total;
end;
$$;
revoke execute on function _recalcular_pago_tecnico(uuid) from public, anon, authenticated;

-- La tarifa que aplica: la de esa persona si existe; si no, la general. Siempre la vigente
-- en la fecha del servicio (no la de hoy).
create or replace function _tarifa_pago_tecnico(p_tecnico uuid, p_tipo text, p_rol text, p_fecha date)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select t.monto
    from tarifas_pago_tecnico t
   where t.tipo_servicio = p_tipo
     and t.rol = p_rol
     and (t.tecnico_id = p_tecnico or t.tecnico_id is null)
     and t.vigente_desde <= p_fecha
     and (t.vigente_hasta is null or t.vigente_hasta >= p_fecha)
   order by (t.tecnico_id is not null) desc, t.vigente_desde desc
   limit 1;
$$;
revoke execute on function _tarifa_pago_tecnico(uuid, text, text, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- por_pagar_tecnicos: lo que está cerrado y todavía no se ha pagado, por persona.
-- Sirve para el Inicio ("a Fulano le debes N órdenes") sin tener que armar un pago.
-- ---------------------------------------------------------------------------
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
        from ordenes_servicio o where o.estado = 'cerrada' and o.tecnico_id is not null and o.fecha <= p_hasta
      union all
      select o.id, o.fecha, o.tipo_servicio, o.tecnico2_id, 'ayudante'
        from ordenes_servicio o where o.estado = 'cerrada' and o.tecnico2_id is not null and o.fecha <= p_hasta
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

-- ---------------------------------------------------------------------------
-- proponer_pago_tecnico: arma (o rehace) el borrador de pago de una persona.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- ajustar / quitar: solo mientras el pago sigue en borrador.
-- ---------------------------------------------------------------------------
create or replace function ajustar_pago_tecnico(p_pago uuid, p_concepto text, p_monto numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p pagos_tecnico%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador ajusta pagos a técnicos.' using errcode = '42501';
  end if;
  v_p := (select p from pagos_tecnico p where p.id = p_pago);
  if v_p.id is null then raise exception 'Ese pago no existe.' using errcode = '22023'; end if;
  if v_p.estado <> 'propuesto' then
    raise exception 'Solo se ajusta un pago en borrador.' using errcode = '22023';
  end if;
  if coalesce(trim(p_concepto), '') = '' then
    raise exception 'Escribe el concepto del ajuste (bono, descuento, anticipo…).' using errcode = '22023';
  end if;
  if p_monto is null or p_monto = 0 then
    raise exception 'El ajuste no puede ser de cero.' using errcode = '22023';
  end if;

  insert into pagos_tecnico_lineas (pago_id, tecnico_id, clase, concepto, monto)
  values (p_pago, v_p.tecnico_id, 'ajuste', trim(p_concepto), p_monto);
  perform _recalcular_pago_tecnico(p_pago);
  return jsonb_build_object('ok', true, 'total', (select total from pagos_tecnico where id = p_pago));
end;
$$;
revoke execute on function ajustar_pago_tecnico(uuid, text, numeric) from public, anon;
grant execute on function ajustar_pago_tecnico(uuid, text, numeric) to authenticated;

create or replace function quitar_linea_pago_tecnico(p_linea uuid) returns jsonb
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
  if v_l.id is null then raise exception 'Esa línea no existe.' using errcode = '22023'; end if;
  if (select estado from pagos_tecnico where id = v_l.pago_id) <> 'propuesto' then
    raise exception 'Solo se quitan líneas de un pago en borrador.' using errcode = '22023';
  end if;
  -- Se borra de verdad: es un borrador, no un libro. La orden queda libre para el siguiente pago.
  delete from pagos_tecnico_lineas where id = p_linea;
  perform _recalcular_pago_tecnico(v_l.pago_id);
  return jsonb_build_object('ok', true, 'total', (select total from pagos_tecnico where id = v_l.pago_id));
end;
$$;
revoke execute on function quitar_linea_pago_tecnico(uuid) from public, anon;
grant execute on function quitar_linea_pago_tecnico(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- aprobar_pago_tecnico: congela el total.
-- ---------------------------------------------------------------------------
create or replace function aprobar_pago_tecnico(p_pago uuid) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p pagos_tecnico%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador aprueba pagos a técnicos.' using errcode = '42501';
  end if;
  v_p := (select p from pagos_tecnico p where p.id = p_pago);
  if v_p.id is null then raise exception 'Ese pago no existe.' using errcode = '22023'; end if;
  if v_p.estado = 'aprobado' then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;
  if v_p.estado <> 'propuesto' then
    raise exception 'Ese pago está %; ya no se puede aprobar.', v_p.estado using errcode = '22023';
  end if;
  if _recalcular_pago_tecnico(p_pago) <= 0 then
    raise exception 'El pago no tiene nada que pagar.' using errcode = '22023';
  end if;

  update pagos_tecnico
     set estado = 'aprobado', aprobado_en = now(), aprobado_por = coalesce(auth.jwt() ->> 'email', 'crm')
   where id = p_pago;
  perform _apunta('pagos_tecnico', p_pago, 'aprobar_pago_tecnico', null,
                  jsonb_build_object('total', (select total from pagos_tecnico where id = p_pago)), 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false);
end;
$$;
revoke execute on function aprobar_pago_tecnico(uuid) from public, anon;
grant execute on function aprobar_pago_tecnico(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- registrar_pago_tecnico: lo marca pagado y carga el egreso 'tecnico' al expediente de cada
-- cotización (la suma de sus líneas). Las órdenes sin cotización (una póliza, por ejemplo) quedan
-- solo en el pago hasta que exista el libro general de gastos.
-- Todo en una transacción: si el expediente de alguna cotización ya está cerrado, el trigger
-- _expediente_cerrado_bloquea lo detiene y no se paga a medias.
-- ---------------------------------------------------------------------------
create or replace function registrar_pago_tecnico(
  p_pago uuid, p_forma text, p_referencia text default null,
  p_fecha date default null, p_archivo text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p pagos_tecnico%rowtype;
  v_nombre text;
  r record;
  v_cargados int := 0;
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

  v_nombre := (select nombre from perfiles where id = v_p.tecnico_id);

  for r in
    select l.cotizacion_id, sum(l.monto) as monto, count(*) as n
      from pagos_tecnico_lineas l
     where l.pago_id = p_pago and l.activa and l.clase = 'servicio' and l.cotizacion_id is not null
     group by l.cotizacion_id
  loop
    if r.monto > 0 then
      insert into expediente_movimientos
        (cotizacion_id, tipo, categoria, fecha, concepto, monto, forma, referencia, tecnico_id, archivo, notas, creado_por)
      values
        (r.cotizacion_id, 'egreso', 'tecnico', coalesce(p_fecha, current_date),
         format('Pago a %s por %s servicio(s)', coalesce(v_nombre, 'técnico'), r.n),
         r.monto, p_forma, coalesce(nullif(trim(p_referencia), ''), 'PAGO-' || v_p.folio),
         v_p.tecnico_id, p_archivo, format('Pago a técnicos PAGO-%s', v_p.folio),
         coalesce(auth.jwt() ->> 'email', 'crm'));
      v_cargados := v_cargados + 1;
    end if;
  end loop;

  update pagos_tecnico
     set estado = 'pagado', forma = p_forma, referencia = nullif(trim(p_referencia), ''),
         fecha_pago = coalesce(p_fecha, current_date), archivo = p_archivo,
         pagado_en = now(), pagado_por = coalesce(auth.jwt() ->> 'email', 'crm')
   where id = p_pago;
  perform _apunta('pagos_tecnico', p_pago, 'registrar_pago_tecnico', null,
                  jsonb_build_object('total', v_p.total, 'forma', p_forma, 'expedientes', v_cargados), 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false, 'expedientes_cargados', v_cargados);
end;
$$;
revoke execute on function registrar_pago_tecnico(uuid, text, text, date, text) from public, anon;
grant execute on function registrar_pago_tecnico(uuid, text, text, date, text) to authenticated;

-- ---------------------------------------------------------------------------
-- cancelar_pago_tecnico: solo un borrador o uno aprobado sin pagar. Uno ya pagado dejó
-- movimientos en los expedientes; deshacerlos es una decisión manual, no un botón.
-- ---------------------------------------------------------------------------
create or replace function cancelar_pago_tecnico(p_pago uuid, p_motivo text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p pagos_tecnico%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador cancela pagos a técnicos.' using errcode = '42501';
  end if;
  v_p := (select p from pagos_tecnico p where p.id = p_pago);
  if v_p.id is null then raise exception 'Ese pago no existe.' using errcode = '22023'; end if;
  if v_p.estado = 'cancelado' then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;
  if v_p.estado = 'pagado' then
    raise exception 'Un pago ya registrado dejó egresos en los expedientes; corrígelo desde ahí.' using errcode = '22023';
  end if;
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Escribe el motivo de la cancelación.' using errcode = '22023';
  end if;

  update pagos_tecnico_lineas set activa = false where pago_id = p_pago;   -- las órdenes quedan libres
  update pagos_tecnico set estado = 'cancelado', motivo_cancelacion = trim(p_motivo) where id = p_pago;
  perform _apunta('pagos_tecnico', p_pago, 'cancelar_pago_tecnico',
                  jsonb_build_object('estado', v_p.estado, 'total', v_p.total),
                  jsonb_build_object('motivo', trim(p_motivo)), 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false);
end;
$$;
revoke execute on function cancelar_pago_tecnico(uuid, text) from public, anon;
grant execute on function cancelar_pago_tecnico(uuid, text) to authenticated;

-- Registro (ver 68).
insert into _migraciones (archivo, tipo) values ('66_pago_tecnicos.sql', 'esquema')
on conflict (archivo) do nothing;
