-- ===========================================================================
-- WHATSAPP · CAMPAÑAS MENSUALES (marketing), sobre la cola de la 56
--
-- Flujo acordado con Caña (02/10/2026): el plan de servicio mensual se carga por mes; cada semana
-- se PROPONE una tanda (por omisión 37); Caña la revisa, quita a quien no quiera y la APRUEBA;
-- solo entonces entra a `salida_wa` como marketing. Las columnas de seguimiento que antes se
-- llenaban a mano en Excel (respondió, BAJA, cita) se calculan solas en `resultados_campana`.
--
-- Solo clientes de PowerMx: el CSV de cada mes sale de los marcados "PowerMx (confirmó)" en la
-- hoja Asignación. Las campañas de Dutton van en su propio proyecto.
--
-- Carga: Table Editor → `campana_envios` → Import data from CSV (`campana_powermx_<AAAA-MM>.csv`;
-- encabezados = columnas). Un número no se carga dos veces en el mismo mes.
--
-- Reglas (en la base):
--   · Nunca a un número con BAJA.
--   · Máximo una plantilla de marketing por número cada `wa_config.dias_entre_marketing` días.
--   · Sin plantilla aprobada, lo aprobado espera en la cola (la 56 no lo manda).
-- Sin `select ... into` en plpgsql. Se puede repetir. Prueba: 57_prueba_campanas_whatsapp.sql.
-- ===========================================================================

create table if not exists campana_tandas (
  id uuid primary key default gen_random_uuid(),
  mes text not null check (mes ~ '^\d{4}-\d{2}$'),
  numero int not null,
  estado text not null default 'propuesta' check (estado in ('propuesta', 'aprobada', 'cancelada')),
  propuesta_por text, aprobada_por text, aprobada_en timestamptz,
  created_at timestamptz not null default now(),
  unique (mes, numero)
);

create table if not exists campana_envios (
  id uuid primary key default gen_random_uuid(),
  -- columnas del CSV
  mes text not null check (mes ~ '^\d{4}-\d{2}$'),
  categoria text,
  prioridad text,
  telefono text not null,
  nombre text,
  equipo text,
  ultimo_servicio text,
  plantilla text references wa_plantillas(nombre),
  -- control
  telefono_norm text generated always as (normalizar_telefono(telefono)) stored,
  orden int,                                  -- posición dentro del mes (prioridad del plan)
  estado text not null default 'propuesto' check (estado in ('propuesto', 'en_tanda', 'aprobado', 'omitido')),
  motivo text,
  tanda_id uuid references campana_tandas(id) on delete set null,
  salida_id uuid references salida_wa(id) on delete set null,
  created_at timestamptz not null default now()
);
create unique index if not exists un_campana_mes_tel on campana_envios(mes, telefono_norm) where telefono_norm is not null;
create index if not exists idx_campana_mes on campana_envios(mes, estado);

-- Las plantillas de marketing de la campaña (textos en plan_agentes_whatsapp.md). Nacen en
-- 'borrador': hay que darlas de alta en Meta y, al aprobarse, ajustar variables y estado.
insert into wa_plantillas (nombre, idioma, categoria, uso, variables, estado, notas) values
  ('seguimiento_pendiente',      'es_MX', 'utilidad',  'campana:pendiente',    '{nombre,equipo}',        'borrador', 'Sigue una solicitud que ya existía'),
  ('mantenimiento_programado',   'es_MX', 'marketing', 'campana:le_toca',      '{nombre,equipo,fecha}',  'borrador', 'C: le toca este mes'),
  ('recordatorio_mantenimiento', 'es_MX', 'marketing', 'campana:atrasado',     '{nombre,equipo}',        'borrador', 'Atrasados'),
  ('reactivacion_cliente',       'es_MX', 'marketing', 'campana:reactivacion', '{nombre}',               'borrador', 'Más de un año sin servicio'),
  ('preventivo_huracanes',       'es_MX', 'marketing', 'campana:huracanes',    '{nombre,equipo}',        'borrador', 'Abril y mayo'),
  ('maintenance_reminder',       'en_US', 'marketing', 'campana:extranjero',   '{nombre,equipo}',        'borrador', 'Extranjeros, nov–mar')
on conflict (nombre) do nothing;

alter table campana_tandas enable row level security;
alter table campana_envios enable row level security;
revoke all on campana_tandas, campana_envios from anon;
grant select, insert, update, delete on campana_tandas, campana_envios to authenticated;
drop policy if exists "admin_campana_tandas" on campana_tandas;
create policy "admin_campana_tandas" on campana_tandas for all to authenticated using (es_admin()) with check (es_admin());
drop policy if exists "admin_campana_envios" on campana_envios;
create policy "admin_campana_envios" on campana_envios for all to authenticated using (es_admin()) with check (es_admin());

-- ¿Ya recibió marketing hace poco? (enviado o por salir)
create or replace function _marketing_reciente(p_norm text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from salida_wa s
     where s.telefono_norm = p_norm and s.categoria = 'marketing'
       and s.estado in ('pendiente', 'enviando', 'enviado', 'entregado', 'leido', 'sin_confirmar')
       and s.created_at > now() - make_interval(days => coalesce((select dias_entre_marketing from wa_config where id), 30)))
$$;
revoke all on function _marketing_reciente(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Proponer la tanda: los siguientes N del mes, en el orden del plan. Los que no pueden ir
-- (BAJA, marketing reciente, teléfono inválido, sin plantilla) se marcan omitidos con su motivo.
-- ---------------------------------------------------------------------------
create or replace function proponer_tanda(p_mes text, p_n int default 37) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_tanda uuid; v_num int; r record; v_n int := 0; v_omit int := 0; v_motivo text;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if exists (select 1 from campana_tandas where mes = p_mes and estado = 'propuesta') then
    raise exception 'Ya hay una tanda propuesta de % sin aprobar: apruébala o cancélala primero.', p_mes using errcode = '22023';
  end if;
  v_num := coalesce((select max(numero) from campana_tandas where mes = p_mes), 0) + 1;
  v_tanda := gen_random_uuid();
  insert into campana_tandas (id, mes, numero, propuesta_por) values (v_tanda, p_mes, v_num, coalesce(auth.jwt() ->> 'email', 'crm'));

  for r in select * from campana_envios
            where mes = p_mes and estado = 'propuesto'
            order by coalesce(orden, 999999), created_at loop
    exit when v_n >= greatest(1, least(p_n, 250));
    v_motivo := case
      when r.telefono_norm is null then 'teléfono inválido'
      when exists (select 1 from wa_bajas b where b.telefono_norm = r.telefono_norm) then 'pidió BAJA'
      when _marketing_reciente(r.telefono_norm) then 'ya recibió marketing hace poco'
      when r.plantilla is null then 'sin plantilla asignada'
      else null end;
    if v_motivo is not null then
      update campana_envios set estado = 'omitido', motivo = v_motivo where id = r.id;
      v_omit := v_omit + 1;
      continue;
    end if;
    update campana_envios set estado = 'en_tanda', tanda_id = v_tanda where id = r.id;
    v_n := v_n + 1;
  end loop;

  if v_n = 0 then
    delete from campana_tandas where id = v_tanda;
    return jsonb_build_object('ok', true, 'vacia', true, 'omitidos', v_omit);
  end if;
  return jsonb_build_object('ok', true, 'tanda_id', v_tanda, 'numero', v_num, 'en_tanda', v_n, 'omitidos', v_omit);
end $$;

-- Quitar de la tanda antes de aprobar: vuelve a "propuesto" (otra semana) u "omitido" (con motivo).
create or replace function quitar_de_tanda(p_ids uuid[], p_omitir boolean default false, p_motivo text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  update campana_envios
     set estado = case when p_omitir then 'omitido' else 'propuesto' end,
         motivo = case when p_omitir then coalesce(nullif(trim(p_motivo), ''), 'quitado por la oficina') end,
         tanda_id = null
   where id = any(p_ids) and estado = 'en_tanda';
  return jsonb_build_object('ok', true);
end $$;

-- Aprobar: cada envío de la tanda entra a la cola como marketing. Las reglas se revisan otra vez.
create or replace function aprobar_tanda(p_tanda uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t campana_tandas%rowtype; r record; v_salida uuid; v_n int := 0; v_omit int := 0; v_motivo text;
        v_pl wa_plantillas%rowtype; v_espera int := 0;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  t := (select x from campana_tandas x where x.id = p_tanda);
  if t.id is null then
    raise exception 'Esa tanda no existe.' using errcode = 'P0002';
  end if;
  if t.estado <> 'propuesta' then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'estado', t.estado);
  end if;

  for r in select * from campana_envios where tanda_id = p_tanda and estado = 'en_tanda' loop
    v_motivo := case
      when exists (select 1 from wa_bajas b where b.telefono_norm = r.telefono_norm) then 'pidió BAJA'
      when _marketing_reciente(r.telefono_norm) then 'ya recibió marketing hace poco'
      else null end;
    if v_motivo is not null then
      update campana_envios set estado = 'omitido', motivo = v_motivo where id = r.id;
      v_omit := v_omit + 1;
      continue;
    end if;
    v_pl := (select p from wa_plantillas p where p.nombre = r.plantilla);
    if v_pl.estado is distinct from 'aprobada' then v_espera := v_espera + 1; end if;
    v_salida := gen_random_uuid();
    insert into salida_wa (id, llave, telefono, tipo, plantilla, variables, texto, origen, origen_id, categoria,
                           estado, aprobado_por, aprobado_en, creado_por)
    values (v_salida, 'campana:' || r.id, r.telefono, 'plantilla', r.plantilla,
            -- Meta rechaza variables con saltos de línea o espacios seguidos: se aplanan y se recortan.
            jsonb_strip_nulls(jsonb_build_object(
              'nombre', coalesce(nullif(left(trim(regexp_replace(coalesce(r.nombre, ''), '\s+', ' ', 'g')), 60), ''), 'cliente'),
              'equipo', coalesce(nullif(left(trim(regexp_replace(coalesce(r.equipo, ''), '\s+', ' ', 'g')), 60), ''), 'su equipo'),
              'fecha', coalesce(nullif(left(trim(regexp_replace(coalesce(r.ultimo_servicio, ''), '\s+', ' ', 'g')), 40), ''), 'su último servicio'))),
            'Campaña ' || t.mes || ' · ' || coalesce(r.categoria, ''), 'campana', r.id,
            coalesce(v_pl.categoria, 'marketing'), 'pendiente',
            coalesce(auth.jwt() ->> 'email', 'crm'), now(), coalesce(auth.jwt() ->> 'email', 'crm'))
    on conflict (llave) do nothing;
    update campana_envios set estado = 'aprobado', salida_id = v_salida where id = r.id;
    v_n := v_n + 1;
  end loop;

  update campana_tandas set estado = 'aprobada', aprobada_por = coalesce(auth.jwt() ->> 'email', 'crm'), aprobada_en = now()
   where id = p_tanda;
  return jsonb_build_object('ok', true, 'a_la_cola', v_n, 'omitidos', v_omit,
                            'esperan_plantilla', v_espera);
end $$;

create or replace function cancelar_tanda(p_tanda uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  update campana_envios set estado = 'propuesto', tanda_id = null where tanda_id = p_tanda and estado = 'en_tanda';
  update campana_tandas set estado = 'cancelada' where id = p_tanda and estado = 'propuesta';
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- Resultados: lo que antes se llenaba a mano. Por envío y el resumen del mes.
--   respondió = entró un mensaje de ese número después de enviarle
--   cita      = se creó una cita de su cliente después de enviarle (si el número es de un cliente)
--   baja      = pidió BAJA después de enviarle
-- ---------------------------------------------------------------------------
create or replace function resultados_campana(p_mes text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_det jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  v_det := (
    select coalesce(jsonb_agg(x order by x ->> 'orden'), '[]'::jsonb) from (
      select jsonb_strip_nulls(jsonb_build_object(
        'id', e.id, 'orden', lpad(coalesce(e.orden, 0)::text, 6, '0'), 'nombre', e.nombre, 'telefono', e.telefono,
        'categoria', e.categoria, 'estado', e.estado, 'motivo', e.motivo,
        'envio', s.estado, 'enviado_en', s.enviado_en,
        'respondio', s.enviado_en is not null and exists (
           select 1 from mensajes_wa m join conversaciones c on c.id = m.conversacion_id
            where c.telefono_norm = e.telefono_norm and m.direccion = 'entrante' and m.created_at > s.enviado_en),
        'cita', s.enviado_en is not null and exists (
           select 1 from citas ci join contactos ct on ct.cliente_id = ci.cliente_id
            where ct.activo and ct.telefono_norm = e.telefono_norm and ci.created_at > s.enviado_en),
        'baja', exists (select 1 from wa_bajas b where b.telefono_norm = e.telefono_norm
                          and (s.enviado_en is null or b.created_at > s.enviado_en))
      )) as x
      from campana_envios e left join salida_wa s on s.id = e.salida_id
      where e.mes = p_mes) z);
  return jsonb_build_object(
    'mes', p_mes,
    'cargados', (select count(*) from campana_envios where mes = p_mes),
    'por_proponer', (select count(*) from campana_envios where mes = p_mes and estado = 'propuesto'),
    'aprobados', (select count(*) from jsonb_array_elements(v_det) d where d ->> 'estado' = 'aprobado'),
    'enviados', (select count(*) from jsonb_array_elements(v_det) d where d ->> 'enviado_en' is not null),
    'respondieron', (select count(*) from jsonb_array_elements(v_det) d where (d ->> 'respondio')::boolean),
    'citas', (select count(*) from jsonb_array_elements(v_det) d where (d ->> 'cita')::boolean),
    'bajas', (select count(*) from jsonb_array_elements(v_det) d where (d ->> 'baja')::boolean),
    'detalle', v_det);
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'proponer_tanda(text, int)', 'quitar_de_tanda(uuid[], boolean, text)', 'aprobar_tanda(uuid)',
    'cancelar_tanda(uuid)', 'resultados_campana(text)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

notify pgrst, 'reload schema';

select 'rls campana_envios' as que, relrowsecurity::text as ok from pg_class where relname = 'campana_envios';
