-- 105 · Programación mensual de visitas (26/11/2026)
--
-- Pedido de Caña: "recordatorios a inicios del mes que aparezcan en el CRM y que permitan la
-- programación mensual". Hasta hoy el reloj `citas-de-poliza` abría cada visita de póliza 21 días
-- antes, una por una, y quedaban sueltas en "Por programar" de la Agenda: nadie veía el mes entero.
--
--   · El día 1 a las 07:00 de Mérida, el reloj `programacion-mensual` llama a
--     `abrir_programacion_mensual()`: abre de golpe la cita (por_programar, con su orden) de TODAS las
--     visitas de póliza que caen en el mes y deja el recordatorio del mes en `programaciones_mensuales`.
--     El admin también puede abrir el mes siguiente por adelantado desde la pantalla.
--   · `programacion_mensual(mes)` da todo lo que hay que acomodar ese mes en una llamada: citas por
--     programar, las ya programadas del mes, visitas de póliza que aún no tienen cita y equipos SIN
--     póliza a los que les toca mantenimiento (no se les abre cita sola: no tienen contrato; se les
--     escribe). La pantalla programa cada una con `programar_cita`, que ya avisa de empalmes.
--   · `marcar_programacion_revisada(mes)`: "ya quedó programado el mes" (o se reabre).
--   · El recordatorio del día anterior al CLIENTE (`texto_aviso`, rama `recordatorio`) se reescribe
--     en 105b: dice qué visita de la póliza es, qué tener listo y pide confirmar con SÍ.
--
-- Se puede repetir sin tronar.

create table if not exists programaciones_mensuales (
  mes            date primary key check (mes = date_trunc('month', mes)::date),
  abierta_en     timestamptz not null default now(),
  citas_abiertas int not null default 0,
  revisada_en    timestamptz,
  revisada_por   text
);

alter table programaciones_mensuales enable row level security;
revoke all on programaciones_mensuales from anon;
drop policy if exists admin_programaciones on programaciones_mensuales;
create policy admin_programaciones on programaciones_mensuales
  for all to authenticated using (es_admin()) with check (es_admin());

-- ---------------------------------------------------------------------------
-- Abrir el mes: citas de todas las visitas de póliza que caen en él
-- ---------------------------------------------------------------------------
create or replace function abrir_programacion_mensual(p_mes date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_hoy  date := _hoy_merida();
  v_mes  date := date_trunc('month', coalesce(p_mes, _hoy_merida()))::date;
  v_fin  date;
  v_r    jsonb;
  v_n    int;
begin
  -- La llama el reloj (sin sesión) o un admin.
  if auth.uid() is not null and not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  v_fin := (v_mes + interval '1 month')::date - 1;
  if v_fin < v_hoy then
    raise exception 'Ese mes ya pasó.' using errcode = '22023';
  end if;
  if v_mes > (date_trunc('month', v_hoy) + interval '1 month')::date then
    raise exception 'Solo se puede abrir este mes o el siguiente.' using errcode = '22023';
  end if;

  -- generar_citas_poliza abre todo lo pendiente hasta "hoy + días": hasta el fin del mes pedido.
  v_r := generar_citas_poliza(v_fin - v_hoy);
  v_n := coalesce((v_r ->> 'citas')::int, 0);

  insert into programaciones_mensuales (mes, citas_abiertas)
  values (v_mes, v_n)
  on conflict (mes) do update
    set citas_abiertas = programaciones_mensuales.citas_abiertas + excluded.citas_abiertas;

  return jsonb_build_object('ok', true, 'mes', v_mes, 'citas', v_n);
end $$;

revoke all on function abrir_programacion_mensual(date) from public, anon;
grant execute on function abrir_programacion_mensual(date) to authenticated;

-- ---------------------------------------------------------------------------
-- Lo que hay que acomodar en un mes
-- ---------------------------------------------------------------------------
create or replace function programacion_mensual(p_mes date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_mes date := date_trunc('month', coalesce(p_mes, _hoy_merida()))::date;
  v_fin date;
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

  -- Citas: todas las por programar (sin importar el mes: son trabajo pendiente) y las programadas del mes.
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

  -- Visitas de póliza del mes que todavía no tienen cita (el mes aún no se abre).
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

  -- Equipos sin póliza vigente a los que les toca mantenimiento en el mes y no tienen cita abierta.
  v_sugeridos := coalesce((
    select jsonb_agg(jsonb_build_object(
             'equipo_id', e.id, 'proximo', e.proximo_mantenimiento, 'cliente_id', cl.id, 'cliente', cl.nombre,
             'contacto', nullif(trim(cl.contacto_nombre), ''), 'telefono', nullif(trim(cl.telefono), ''),
             'zona', coalesce(nullif(trim(cl.zona), ''), nullif(trim(cl.municipio), '')),
             'equipo_tipo', e.tipo,
             'equipo', nullif(trim(concat_ws(' ', e.marca, e.modelo,
               case when e.capacidad_kw is not null then trim(to_char(e.capacidad_kw, 'FM999990.##')) || ' kW' end)), ''))
           order by e.proximo_mantenimiento, cl.nombre)
      from equipos e
      join clientes cl on cl.id = e.cliente_id
     where e.proximo_mantenimiento between v_mes and v_fin
       and not exists (select 1 from polizas p where p.equipo_id = e.id and p.estado = 'vigente'
                          and p.fin >= v_mes)
       and not exists (select 1 from citas c where c.equipo_id = e.id
                          and c.estado in ('por_programar', 'programada'))), '[]'::jsonb);

  return jsonb_build_object(
    'mes', v_mes, 'fin', v_fin, 'hoy', _hoy_merida(),
    'abierta', v_prog.mes is not null, 'abierta_en', v_prog.abierta_en,
    'revisada_en', v_prog.revisada_en, 'revisada_por', v_prog.revisada_por,
    'citas', v_citas, 'sin_cita', v_sin_cita, 'sugeridos', v_sugeridos);
end $$;

revoke all on function programacion_mensual(date) from public, anon;
grant execute on function programacion_mensual(date) to authenticated;

-- ---------------------------------------------------------------------------
-- "Ya quedó programado el mes" (o se reabre)
-- ---------------------------------------------------------------------------
create or replace function marcar_programacion_revisada(p_mes date, p_revisada boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_mes date := date_trunc('month', p_mes)::date;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if v_mes is null then raise exception 'Falta el mes.' using errcode = '22023'; end if;
  insert into programaciones_mensuales (mes) values (v_mes) on conflict (mes) do nothing;
  update programaciones_mensuales
     set revisada_en = case when p_revisada then now() end,
         revisada_por = case when p_revisada then coalesce(auth.jwt() ->> 'email', 'crm') end
   where mes = v_mes;
  return jsonb_build_object('ok', true, 'mes', v_mes, 'revisada', p_revisada);
end $$;

revoke all on function marcar_programacion_revisada(date, boolean) from public, anon;
grant execute on function marcar_programacion_revisada(date, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Reloj: día 1 de cada mes, 13:00 UTC = 07:00 de Mérida (sin horario de verano).
-- ---------------------------------------------------------------------------
select cron.unschedule('programacion-mensual')
 where exists (select 1 from cron.job where jobname = 'programacion-mensual');
select cron.schedule('programacion-mensual', '0 13 1 * *', $cron$select public.abrir_programacion_mensual()$cron$);

-- ---------------------------------------------------------------------------
-- 105b · El recordatorio del día anterior al cliente (texto para el envío por wa.me).
-- Redefinida COMPLETA desde la versión viva (54/16); solo cambia la rama 'recordatorio'.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.texto_aviso(p_aviso uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  a avisos%rowtype;
  c citas%rowtype;
  cl clientes%rowtype;
  eq equipos%rowtype;
  v_dias text[] := array['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado'];
  v_meses text[] := array['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto',
                          'septiembre', 'octubre', 'noviembre', 'diciembre'];
  v_folio bigint;
  v_t1 text; v_t2 text; v_tec text;
  v_cuando text; v_tipo text; v_equipo text; v_dir text; v_contactos text;
  v_dur text; v_hola text; v_rol text; v_titulo text;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  select * into a from avisos where id = p_aviso;
  if not found then return null; end if;
  select * into c from citas where id = a.cita_id;
  select * into cl from clientes where id = c.cliente_id;
  if c.equipo_id is not null then select * into eq from equipos where id = c.equipo_id; end if;
  select folio into v_folio from ordenes_servicio where cita_id = c.id limit 1;   -- cita 1 : 1 orden
  select coalesce(nombre, email) into v_t1 from perfiles where id = c.tecnico_id;
  select coalesce(nombre, email) into v_t2 from perfiles where id = c.tecnico2_id;
  v_tec := concat_ws(' y ', v_t1, v_t2);

  v_cuando := case when c.fecha is null then 'por definir' else
      v_dias[extract(dow from c.fecha)::int + 1] || ' ' || extract(day from c.fecha)::int
      || ' de ' || v_meses[extract(month from c.fecha)::int]
      || case when c.hora is not null then ' a las ' || left(c.hora::text, 5) || ' h' else '' end
    end;
  v_dur := case when c.duracion_min is not null then 'Duración aproximada: ' || c.duracion_min || ' min' end;
  v_tipo := case c.tipo_servicio
              when 'preventivo' then 'mantenimiento preventivo'
              when 'correctivo' then 'servicio correctivo'
              when 'instalacion' then 'instalación'
              when 'diagnostico' then 'diagnóstico'
              when 'visita_tecnica' then 'visita técnica'
              else coalesce(c.tipo_servicio, 'servicio') end;
  v_equipo := nullif(trim(concat_ws(' ', eq.tipo, eq.marca, eq.modelo,
                case when eq.capacidad_kw is not null then eq.capacidad_kw || ' kW' end)), '');

  -- ---------------- cliente ----------------
  if a.destinatario = 'cliente' then
    v_hola := case when nullif(trim(a.nombre), '') is not null then 'Hola ' || trim(a.nombre) || ',' else 'Hola,' end;
    if a.tipo = 'cancelacion' then
      return concat_ws(E'\n', v_hola, '',
        'Le informamos que su cita de ' || v_tipo || coalesce(' de su ' || v_equipo, '')
          || ' del ' || v_cuando || ' fue cancelada.',
        '', 'Nos pondremos en contacto para reagendarla. Disculpe las molestias.', 'PowerMx');
    end if;
    if a.tipo = 'recordatorio' then
      -- (105) Dice qué visita de la póliza es, qué tener listo y pide confirmar.
      return concat_ws(E'\n', v_hola, '',
        'Le recordamos que mañana, ' || v_cuando || ', le visitamos para su '
          || coalesce((select case pv.tipo when 'menor' then 'servicio menor'
                                           when 'mayor' then 'servicio mayor'
                                           else 'visita de inspección' end
                              || ' (visita ' || pv.numero || ' de '
                              || (select count(*) from poliza_visitas z where z.poliza_id = pv.poliza_id)
                              || ' de su póliza POL-' || (select folio from polizas where id = pv.poliza_id) || ')'
                         from poliza_visitas pv where pv.cita_id = c.id limit 1), v_tipo)
          || coalesce(' de su ' || v_equipo, '') || '.',
        v_dur,
        case when v_tec <> '' then 'Lo atenderá: ' || v_tec end,
        '', 'Para que el servicio salga bien:',
        '• Que alguien nos dé acceso al equipo y pueda firmar el reporte.',
        case when eq.atributos ->> 'combustible' in ('gas_lp', 'gas_natural', 'diesel', 'gasolina')
             then '• Que el equipo tenga combustible suficiente.' end,
        case when eq.tipo = 'generador' then '• Durante las pruebas la luz puede cortarse unos minutos.' end,
        case when eq.tipo in ('solar', 'bateria') then '• Durante las pruebas el sistema puede apagarse unos minutos.' end,
        '', 'Responda SÍ para confirmar, o díganos si necesita cambiar el horario.',
        'PowerMx · 999 475 5275');
    end if;
    return concat_ws(E'\n', v_hola, '',
      case when a.tipo = 'reprogramacion'
           then 'Le informamos que su cita con PowerMx fue reprogramada: ' || v_tipo || coalesce(' de su ' || v_equipo, '') || '.'
           else 'Le confirmamos su cita con PowerMx: ' || v_tipo || coalesce(' de su ' || v_equipo, '') || '.' end,
      '',
      case when a.tipo = 'reprogramacion' then 'Nueva fecha: ' else 'Fecha: ' end || v_cuando,
      v_dur,
      case when v_tec <> '' then 'Lo atenderá: ' || v_tec end,
      '', 'Si necesita cambiar la fecha, responda a este mensaje.', 'PowerMx');
  end if;

  -- ---------------- técnico ----------------
  v_titulo := case
    when a.tipo = 'cancelacion' and c.estado = 'cancelada' then 'Servicio CANCELADO'
    when a.tipo = 'cancelacion' then 'Ya no estás asignado a este servicio'
    when a.tipo = 'reprogramacion' then 'CAMBIO en el servicio'
    else 'Nuevo servicio' end;

  if a.tipo = 'cancelacion' then
    return concat_ws(E'\n', v_titulo,
      case when v_folio is not null then 'OS-' || v_folio || ' · ' || v_tipo end,
      'Cliente: ' || cl.nombre,
      'Estaba programado: ' || v_cuando);
  end if;

  v_dir := nullif(concat_ws(', ', nullif(trim(cl.direccion), ''), nullif(trim(cl.colonia), ''), nullif(trim(cl.municipio), '')), '');

  -- Contacto en sitio: primero el responsable del equipo, luego los demás (hasta 3).
  select string_agg(x.linea, E'\n') into v_contactos from (
    select ct.nombre || case when nullif(trim(ct.puesto), '') is not null then ' (' || trim(ct.puesto) || ')' else '' end
           || coalesce(': ' || ct.telefono, '') as linea
      from contactos ct
     where ct.activo and ct.cliente_id = c.cliente_id
       and ((c.equipo_id is not null and ct.id in (select v.contacto_id from contactos_por_equipo v where v.equipo_id = c.equipo_id))
            or (c.equipo_id is null and ct.de_toda_la_empresa))
     order by (c.equipo_id is not null and ct.id in
                (select e.contacto_id from equipo_contactos e where e.equipo_id = c.equipo_id and e.rol = 'responsable')) desc,
              ct.nombre
     limit 3) x;
  if v_contactos is null then
    v_contactos := nullif(concat_ws(': ', nullif(trim(cl.contacto_nombre), ''), nullif(trim(cl.telefono), '')), '');
  end if;

  v_rol := case when a.perfil_id = c.tecnico_id
                then 'Eres el responsable' || coalesce(' · Ayudante: ' || v_t2, '')
                else 'Eres el ayudante · Responsable: ' || coalesce(v_t1, 'sin asignar') end;

  return concat_ws(E'\n', v_titulo,
    case when v_folio is not null then 'OS-' || v_folio || ' · ' || v_tipo else initcap(v_tipo) end,
    '',
    'Fecha: ' || v_cuando, v_dur,
    '',
    'Cliente: ' || cl.nombre,
    case when v_contactos is not null then 'Contacto en sitio:' || E'\n' || v_contactos end,
    case when v_dir is not null then 'Dirección: ' || v_dir end,
    case when nullif(trim(cl.referencias), '') is not null then 'Referencias: ' || trim(cl.referencias) end,
    case when nullif(trim(cl.maps_url), '') is not null then 'Cómo llegar: ' || trim(cl.maps_url) end,
    case when v_equipo is not null then 'Equipo: ' || v_equipo || coalesce(' (serie ' || eq.numero_serie || ')', '') end,
    '',
    v_rol,
    case when nullif(trim(c.notas), '') is not null then 'Notas: ' || trim(c.notas) end);
end $function$;

insert into _migraciones (archivo, tipo) values ('105_programacion_mensual.sql', 'esquema') on conflict (archivo) do nothing;
