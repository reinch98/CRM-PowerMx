-- 106 · Mantenimiento de equipos SIN póliza: cada 6 meses o por horómetro (26/11/2026)
--
-- Pedido de Caña: "una vez realizado el servicio y cargada la orden, se registran las horas, y cada
-- 6 meses los equipos que no tienen póliza también entran en el recordatorio, consultando si ya llegó
-- al horómetro para su mantenimiento". Decisión: air cooled cada 100 h (liquid cooled 250 h por
-- omisión; los dos se cambian en `config_mantenimiento` o por equipo en `equipos.intervalo_horas`).
--
--   · Al CERRAR una orden PREVENTIVA con equipo, el equipo guarda su último mantenimiento (fecha y
--     horómetro de esa orden) y, si no está en póliza, `proximo_mantenimiento` = fecha + frecuencia
--     (6 meses por omisión). Antes nada movía esa fecha en un equipo sin póliza.
--   · `programacion_mensual` (105, redefinida) ya no pierde a los atrasados (antes solo veía los que
--     vencían DENTRO del mes) y trae, por equipo, el motivo:
--        horas              — el horómetro ya pasó las horas desde el último servicio: toca ya.
--        tiempo_maximo      — 12 meses sin servicio: toca aunque no llegue a las horas (fabricante).
--        sin_horometro      — no se sabe cuántas horas tenía al último servicio: toca por tiempo.
--        revisar_horometro  — pasaron los 6 meses: preguntarle al cliente cuánto marca.
--   · `registrar_horometro(equipo, horas, fecha)` (admin) anota lo que reporta el cliente. Si ya llegó,
--     el equipo queda "toca ya"; si no, se vuelve a preguntar en 3 meses (nunca después de los 12).
--
-- Se puede repetir sin tronar.

alter table equipos add column if not exists ultimo_mantenimiento date;
alter table equipos add column if not exists ultimo_mantenimiento_horas numeric;
alter table equipos add column if not exists intervalo_horas integer;

create table if not exists config_mantenimiento (
  id               boolean primary key default true check (id),
  meses_revision   int not null default 6  check (meses_revision between 1 and 24),
  meses_reintento  int not null default 3  check (meses_reintento between 1 and 12),
  meses_maximo     int not null default 12 check (meses_maximo between 1 and 36),
  horas_air        int not null default 100 check (horas_air > 0),
  horas_liquid     int not null default 250 check (horas_liquid > 0)
);
insert into config_mantenimiento (id) values (true) on conflict (id) do nothing;

alter table config_mantenimiento enable row level security;
revoke all on config_mantenimiento from anon;
drop policy if exists admin_config_mantenimiento on config_mantenimiento;
create policy admin_config_mantenimiento on config_mantenimiento
  for all to authenticated using (es_admin()) with check (es_admin());

-- ---------------------------------------------------------------------------
-- Cada cuántas horas toca (solo generadores; null = el horómetro no aplica)
-- ---------------------------------------------------------------------------
create or replace function _horas_mantenimiento(e equipos)
returns int language sql stable security definer set search_path = public as $$
  select case when e.tipo <> 'generador' then null
              else coalesce(e.intervalo_horas,
                     case when e.atributos ->> 'enfriamiento' = 'liquid_cooled' then k.horas_liquid
                          else k.horas_air end) end
    from config_mantenimiento k
$$;
revoke all on function _horas_mantenimiento(equipos) from public, anon, authenticated;

-- Qué toca y por qué (ver los motivos arriba).
create or replace function _mantenimiento_equipo(e equipos, p_hoy date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  k config_mantenimiento%rowtype;
  v_int int := _horas_mantenimiento(e);
  v_desde numeric;
  v_motivo text;
begin
  k := (select c from config_mantenimiento c limit 1);
  -- Horas desde el último servicio: solo si la lectura es de ese día o posterior.
  if e.ultimo_mantenimiento_horas is not null and e.horas_uso is not null
     and coalesce(e.horas_uso_fecha, 'infinity'::date) >= coalesce(e.ultimo_mantenimiento, '-infinity'::date) then
    v_desde := e.horas_uso - e.ultimo_mantenimiento_horas;
  end if;

  v_motivo := case
    when v_int is not null and v_desde >= v_int then 'horas'
    when e.ultimo_mantenimiento is not null
         and p_hoy >= (e.ultimo_mantenimiento + make_interval(months => k.meses_maximo))::date then 'tiempo_maximo'
    when v_int is null or e.ultimo_mantenimiento_horas is null then 'sin_horometro'
    else 'revisar_horometro' end;

  return jsonb_build_object('motivo', v_motivo, 'intervalo_horas', v_int, 'horas_desde', v_desde,
    'ultimo', e.ultimo_mantenimiento, 'ultimo_horas', e.ultimo_mantenimiento_horas,
    'horas_uso', e.horas_uso, 'horas_uso_fecha', e.horas_uso_fecha);
end $$;
revoke all on function _mantenimiento_equipo(equipos, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Al cerrar una orden preventiva: último mantenimiento y próximo (sin póliza)
-- ---------------------------------------------------------------------------
create or replace function _mantenimiento_al_cerrar()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_fecha date;
  e equipos%rowtype;
  v_antes jsonb;
begin
  if new.estado <> 'cerrada' or new.equipo_id is null or new.tipo_servicio is distinct from 'preventivo' then
    return new;
  end if;
  if old.estado = 'cerrada' and old.horas_equipo is not distinct from new.horas_equipo
     and old.fecha is not distinct from new.fecha then
    return new;
  end if;
  v_fecha := coalesce(new.fecha, _hoy_merida());
  e := (select x from equipos x where x.id = new.equipo_id);
  -- Una orden vieja corregida no pisa un mantenimiento más reciente.
  if e.ultimo_mantenimiento is not null and e.ultimo_mantenimiento > v_fecha then
    return new;
  end if;
  v_antes := jsonb_build_object('ultimo_mantenimiento', e.ultimo_mantenimiento,
    'ultimo_mantenimiento_horas', e.ultimo_mantenimiento_horas, 'proximo_mantenimiento', e.proximo_mantenimiento);

  update equipos
     set ultimo_mantenimiento = v_fecha,
         ultimo_mantenimiento_horas = new.horas_equipo,
         -- Con póliza, el calendario lo lleva la póliza (97).
         proximo_mantenimiento = case when en_poliza then proximo_mantenimiento
                                      else (v_fecha + make_interval(months => coalesce(frecuencia_meses,
                                             (select meses_revision from config_mantenimiento limit 1))))::date end,
         updated_at = now()
   where id = new.equipo_id;

  perform _apunta('equipos', new.equipo_id, 'mantenimiento_realizado', v_antes,
    jsonb_build_object('ultimo_mantenimiento', v_fecha, 'ultimo_mantenimiento_horas', new.horas_equipo,
                       'orden', new.folio), 'sistema');
  return new;
end $$;

drop trigger if exists mantenimiento_al_cerrar on ordenes_servicio;
create trigger mantenimiento_al_cerrar after update on ordenes_servicio
  for each row execute function _mantenimiento_al_cerrar();

-- Lo que ya estaba cerrado: el último mantenimiento sale de la última orden preventiva cerrada.
update equipos e
   set ultimo_mantenimiento = o.fecha,
       ultimo_mantenimiento_horas = o.horas_equipo,
       proximo_mantenimiento = case when e.en_poliza or e.proximo_mantenimiento is not null then e.proximo_mantenimiento
                                    else (o.fecha + make_interval(months => coalesce(e.frecuencia_meses, 6)))::date end
  from (select distinct on (equipo_id) equipo_id, fecha, horas_equipo
          from ordenes_servicio
         where estado = 'cerrada' and tipo_servicio = 'preventivo' and equipo_id is not null and fecha is not null
         order by equipo_id, fecha desc, folio desc) o
 where o.equipo_id = e.id and e.ultimo_mantenimiento is null;

-- ---------------------------------------------------------------------------
-- Anotar el horómetro que reporta el cliente
-- ---------------------------------------------------------------------------
create or replace function registrar_horometro(p_equipo uuid, p_horas numeric, p_fecha date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  k config_mantenimiento%rowtype;
  e equipos%rowtype;
  v_fecha date := coalesce(p_fecha, _hoy_merida());
  v_m jsonb;
  v_prox date;
  v_antes numeric;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if p_horas is null or p_horas < 0 or p_horas > 200000 then
    raise exception 'Escribe las horas que marca el horómetro.' using errcode = '22023';
  end if;
  if v_fecha > _hoy_merida() then
    raise exception 'La fecha de la lectura no puede ser futura.' using errcode = '22023';
  end if;
  k := (select c from config_mantenimiento c limit 1);
  e := (select x from equipos x where x.id = p_equipo);
  if e.id is null then raise exception 'El equipo no existe.' using errcode = 'P0002'; end if;
  v_antes := e.horas_uso;

  update equipos set horas_uso = p_horas, horas_uso_fecha = v_fecha, updated_at = now()
   where id = p_equipo;
  e.horas_uso := p_horas;
  e.horas_uso_fecha := v_fecha;
  v_m := _mantenimiento_equipo(e, _hoy_merida());
  v_prox := e.proximo_mantenimiento;

  if not e.en_poliza then
    if v_m ->> 'motivo' = 'horas' then
      -- Ya llegó: toca desde hoy.
      v_prox := least(coalesce(v_prox, v_fecha), v_fecha);
    elsif v_m ->> 'motivo' = 'revisar_horometro' then
      -- No llegó: se vuelve a preguntar más adelante, nunca después del máximo.
      v_prox := greatest(coalesce(v_prox, v_fecha), least(
        (v_fecha + make_interval(months => k.meses_reintento))::date,
        (e.ultimo_mantenimiento + make_interval(months => k.meses_maximo))::date));
    end if;
    update equipos set proximo_mantenimiento = v_prox where id = p_equipo;
  end if;

  perform _apunta('equipos', p_equipo, 'horometro',
    jsonb_build_object('horas_uso', v_antes, 'proximo_mantenimiento', e.proximo_mantenimiento),
    jsonb_build_object('horas_uso', p_horas, 'fecha', v_fecha, 'reportado', 'cliente',
                       'retrocede', v_antes is not null and p_horas < v_antes, 'proximo_mantenimiento', v_prox),
    'oficina');

  return v_m || jsonb_build_object('ok', true, 'proximo', v_prox, 'en_poliza', e.en_poliza,
                                   'retrocede', v_antes is not null and p_horas < v_antes);
end $$;
revoke all on function registrar_horometro(uuid, numeric, date) from public, anon;
grant execute on function registrar_horometro(uuid, numeric, date) to authenticated;

-- ---------------------------------------------------------------------------
-- programacion_mensual (105) con los equipos sin póliza por tiempo u horómetro
-- ---------------------------------------------------------------------------
create or replace function programacion_mensual(p_mes date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_mes date := date_trunc('month', coalesce(p_mes, _hoy_merida()))::date;
  v_fin date;
  v_hoy date := _hoy_merida();
  v_citas jsonb;
  v_sin_cita jsonb;
  v_sugeridos jsonb;
  v_prog programaciones_mensuales%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  v_fin := (v_mes + interval '1 month')::date - 1;
  v_prog := (select p from programaciones_mensuales p where p.mes = v_mes);

  v_citas := coalesce((
    select jsonb_agg(to_jsonb(x) - 'orden_vista' order by x.orden_vista, x.fecha nulls first, x.hora nulls first, x.cliente)
      from (
        select c.id as cita_id, c.estado, c.fecha, left(c.hora::text, 5) as hora, c.duracion_min,
               c.tipo_servicio, c.origen, c.notas, c.tecnico_id, c.tecnico2_id,
               (select coalesce(nombre, email) from perfiles where id = c.tecnico_id) as tecnico,
               (select coalesce(nombre, email) from perfiles where id = c.tecnico2_id) as ayudante,
               (select folio from ordenes_servicio o where o.cita_id = c.id limit 1) as orden,
               cl.id as cliente_id, cl.nombre as cliente, nullif(trim(cl.contacto_nombre), '') as contacto,
               nullif(trim(cl.telefono), '') as telefono,
               coalesce(nullif(trim(c.zona), ''), nullif(trim(cl.zona), ''), nullif(trim(cl.municipio), '')) as zona,
               nullif(trim(cl.maps_url), '') as maps_url,
               e.id as equipo_id,
               nullif(trim(concat_ws(' ', e.marca, e.modelo,
                 case when e.capacidad_kw is not null then trim(to_char(e.capacidad_kw, 'FM999990.##')) || ' kW' end)), '') as equipo,
               e.tipo as equipo_tipo, e.atributos ->> 'combustible' as combustible,
               p.folio as poliza, p.nivel as poliza_nivel, pv.numero as visita,
               (select count(*) from poliza_visitas z where z.poliza_id = pv.poliza_id) as visitas,
               pv.tipo as visita_tipo, pv.fecha as fecha_sugerida,
               case when c.estado = 'por_programar' then 0 else 1 end as orden_vista
          from citas c
          join clientes cl on cl.id = c.cliente_id
          left join equipos e on e.id = c.equipo_id
          left join poliza_visitas pv on pv.cita_id = c.id
          left join polizas p on p.id = pv.poliza_id
         where c.estado = 'por_programar'
            or (c.estado = 'programada' and c.fecha between v_mes and v_fin)
      ) x), '[]'::jsonb);

  v_sin_cita := coalesce((
    select jsonb_agg(jsonb_build_object(
             'visita_id', pv.id, 'fecha_sugerida', pv.fecha, 'visita', pv.numero,
             'visitas', (select count(*) from poliza_visitas z where z.poliza_id = p.id),
             'visita_tipo', pv.tipo, 'poliza', p.folio, 'cliente', cl.nombre,
             'contacto', nullif(trim(cl.contacto_nombre), ''), 'telefono', nullif(trim(cl.telefono), ''),
             'zona', coalesce(nullif(trim(cl.zona), ''), nullif(trim(cl.municipio), '')),
             'equipo_tipo', e.tipo,
             'equipo', nullif(trim(concat_ws(' ', e.marca, e.modelo,
               case when e.capacidad_kw is not null then trim(to_char(e.capacidad_kw, 'FM999990.##')) || ' kW' end)), ''))
           order by pv.fecha)
      from poliza_visitas pv
      join polizas p on p.id = pv.poliza_id and p.estado = 'vigente'
      join clientes cl on cl.id = p.cliente_id
      join equipos e on e.id = p.equipo_id
     where pv.estado = 'pendiente' and pv.fecha between v_mes and v_fin), '[]'::jsonb);

  -- (106) Equipos sin póliza vigente: les toca por fecha (también los atrasados de meses pasados)
  -- o porque el horómetro ya llegó; sin cita abierta.
  v_sugeridos := coalesce((
    select jsonb_agg(jsonb_build_object(
             'equipo_id', x.id, 'proximo', x.proximo_mantenimiento, 'cliente_id', cl.id, 'cliente', cl.nombre,
             'contacto', nullif(trim(cl.contacto_nombre), ''), 'telefono', nullif(trim(cl.telefono), ''),
             'zona', coalesce(nullif(trim(cl.zona), ''), nullif(trim(cl.municipio), '')),
             'maps_url', nullif(trim(cl.maps_url), ''), 'ubicacion', nullif(trim(x.ubicacion_equipo), ''),
             'equipo_tipo', x.tipo, 'numero_serie', x.numero_serie,
             'equipo', nullif(trim(concat_ws(' ', x.marca, x.modelo,
               case when x.capacidad_kw is not null then trim(to_char(x.capacidad_kw, 'FM999990.##')) || ' kW' end)), ''))
             || x.m
           order by x.proximo_mantenimiento nulls first, cl.nombre)
      from (select e.*, _mantenimiento_equipo(e, v_hoy) as m from equipos e
             where coalesce(e.estado, 'activo') <> 'inactivo') x
      join clientes cl on cl.id = x.cliente_id
     where (x.proximo_mantenimiento <= v_fin or x.m ->> 'motivo' = 'horas')
       and not exists (select 1 from polizas p where p.equipo_id = x.id and p.estado = 'vigente'
                          and p.fin >= v_mes)
       and not exists (select 1 from citas c where c.equipo_id = x.id
                          and c.estado in ('por_programar', 'programada'))), '[]'::jsonb);

  return jsonb_build_object(
    'mes', v_mes, 'fin', v_fin, 'hoy', v_hoy,
    'abierta', v_prog.mes is not null, 'abierta_en', v_prog.abierta_en,
    'revisada_en', v_prog.revisada_en, 'revisada_por', v_prog.revisada_por,
    'citas', v_citas, 'sin_cita', v_sin_cita, 'sugeridos', v_sugeridos);
end $$;

revoke all on function programacion_mensual(date) from public, anon;
grant execute on function programacion_mensual(date) to authenticated;

insert into _migraciones (archivo, tipo) values ('106_mantenimiento_por_horometro.sql', 'esquema') on conflict (archivo) do nothing;
