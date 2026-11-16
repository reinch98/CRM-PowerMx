-- ---------------------------------------------------------------------------
-- 98 · El cálculo de la calculadora solar llega a la solicitud (16/11/2026)
--
-- Fase 4 del plan "Calculadora solar → cotización real". La calculadora del sitio
-- (powermx.com.mx/calculadora, motor `sitio-publicar/solar-calculo.js` del repo
-- POWERMX-sitio) ya recomienda un paquete publicado con su precio. Hasta hoy eso
-- llegaba al CRM solo como texto en `notas`; desde aquí llega como DATO en
-- `solicitudes_web.calculo`, para que la fase 5 arme la cotización con un toque.
--
-- Reglas:
--  - Lo que manda el sitio es texto de un desconocido. NO se guarda tal cual: pasa por
--    `_calculo_solicitud`, una lista blanca de campos con tipo, patrón y rango. Lo que
--    no cuadra se descarta en silencio; nunca tumba la solicitud (un lead real vale más
--    que un dato extra). Sin kWh al mes no hay cálculo que guardar.
--  - Nada de datos sensibles: del número de servicio de CFE solo los últimos 4 dígitos.
--  - El precio que se guarda es el que VIO el cliente; la cotización (fase 5) usará el
--    precio de HOY y avisará si cambió.
--  - `registrar_solicitud_web` gana `p_calculo jsonb default null`. Se BORRA la firma
--    vieja de 13 argumentos para que PostgREST no vea dos funciones; la Edge Function
--    `solicitud-web` sin `p_calculo` sigue funcionando (el parámetro es opcional), y la
--    nueva reintenta sin él si la base todavía no tiene este script.
--  - Con cálculo y sin tipos marcados, la solicitud queda como "Solar".
--
-- Se puede correr dos veces. Prueba: 98_prueba_solicitud_calculo_solar.sql.
-- ---------------------------------------------------------------------------

alter table solicitudes_web add column if not exists calculo jsonb;

alter table solicitudes_web drop constraint if exists solicitudes_web_calculo_forma;
alter table solicitudes_web add constraint solicitudes_web_calculo_forma
  check (calculo is null or (jsonb_typeof(calculo) = 'object' and pg_column_size(calculo) <= 8192));

-- ---- Piezas de la lista blanca (internas) ----

-- Un número dentro de [min, max], redondeado a 4 decimales; si no, null.
create or replace function _calc_num(v jsonb, p_min numeric, p_max numeric) returns numeric
language sql immutable as $$
  select case
    when jsonb_typeof(v) = 'number' and (v #>> '{}')::numeric between p_min and p_max
      then trim_scale(round((v #>> '{}')::numeric, 4))
  end
$$;

-- Un texto que cumple el patrón (el patrón lleva ^…$ y el largo); si no, null.
create or replace function _calc_txt(v jsonb, p_patron text) returns text
language sql immutable as $$
  select case
    when jsonb_typeof(v) = 'string' and (v #>> '{}') ~ p_patron then v #>> '{}'
  end
$$;

create or replace function _calc_bool(v jsonb) returns boolean
language sql immutable as $$
  select case when jsonb_typeof(v) = 'boolean' then (v #>> '{}')::boolean end
$$;

-- El cálculo limpio, o null si no trae lo mínimo (kWh al mes).
create or replace function _calculo_solicitud(p jsonb) returns jsonb
language sql immutable as $$
  with c as (
    select case when jsonb_typeof(p) = 'object' then p else '{}'::jsonb end as p
  ),
  limpio as (
    select jsonb_strip_nulls(jsonb_build_object(
      'version',         _calc_num(c.p -> 'version', 1, 99),
      'fuente',          _calc_txt(c.p -> 'fuente', '^(recibo|manual)$'),
      'tipo',            _calc_txt(c.p -> 'tipo', '^(residencial|comercial|industrial)$'),
      'tarifa',          _calc_txt(c.p -> 'tarifa', '^[0-9A-Z]{1,8}$'),
      'hilos',           _calc_num(c.p -> 'hilos', 1, 4),
      'servicio_ult4',   _calc_txt(c.p -> 'servicio_ult4', '^[0-9]{4}$'),
      'kwh_mes',         _calc_num(c.p -> 'kwh_mes', 1, 100000),
      'gasto_mes',       _calc_num(c.p -> 'gasto_mes', 1, 1000000),
      'tarifa_efectiva', _calc_num(c.p -> 'tarifa_efectiva', 0.01, 50),
      'dap_mes',         _calc_num(c.p -> 'dap_mes', 0, 100000),
      'dias',            _calc_num(c.p -> 'dias', 1, 800),
      'crecimiento',     _calc_num(c.p -> 'crecimiento', -1, 10),
      'fuente_gasto',    _calc_txt(c.p -> 'fuente_gasto', '^(historial|recibo|estimado)$'),
      'incremento_cfe',  _calc_num(c.p -> 'incremento_cfe', 0, 1),
      'a_la_medida',     _calc_bool(c.p -> 'a_la_medida'),
      'paquete', case when jsonb_typeof(c.p -> 'paquete') = 'object' then
        nullif(jsonb_strip_nulls(jsonb_build_object(
          'sku',                _calc_txt(c.p #> '{paquete,sku}', '^[A-Z0-9-]{1,40}$'),
          'nombre',             _calc_txt(c.p #> '{paquete,nombre}', '^[^<>]{1,60}$'),
          'variante',           _calc_txt(c.p #> '{paquete,variante}', '^(interconectado|respaldo)$'),
          'paneles',            _calc_num(c.p #> '{paquete,paneles}', 1, 200),
          'kw',                 _calc_num(c.p #> '{paquete,kw}', 0.1, 1000),
          'precio',             _calc_num(c.p #> '{paquete,precio}', 1, 10000000),
          'cobertura',          _calc_num(c.p #> '{paquete,cobertura}', 0, 1),
          'ahorro_mes',         _calc_num(c.p #> '{paquete,ahorro_mes}', 0, 1000000),
          'recibo_despues_mes', _calc_num(c.p #> '{paquete,recibo_despues_mes}', 0, 1000000),
          'retorno_anios',      _calc_num(c.p #> '{paquete,retorno_anios}', 0, 100)
        )), '{}'::jsonb)
      end,
      'avisos', (
        select jsonb_agg(t.x order by t.i) from (
          select e.v #>> '{}' as x, e.i
          from jsonb_array_elements(case when jsonb_typeof(c.p -> 'avisos') = 'array'
                                         then c.p -> 'avisos' else '[]'::jsonb end) with ordinality as e(v, i)
          where jsonb_typeof(e.v) = 'string' and (e.v #>> '{}') ~ '^[a-z_]{1,30}$'
          order by e.i
          limit 10
        ) t
      ),
      'historial', (
        select jsonb_agg(t.h order by t.i) from (
          select jsonb_strip_nulls(jsonb_build_object(
                   'fin',     _calc_txt(e.v -> 'fin', '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'),
                   'dias',    _calc_num(e.v -> 'dias', 1, 400),
                   'kwh',     _calc_num(e.v -> 'kwh', 0, 1000000),
                   'importe', _calc_num(e.v -> 'importe', 0, 10000000))) as h, e.i
          from jsonb_array_elements(case when jsonb_typeof(c.p -> 'historial') = 'array'
                                         then c.p -> 'historial' else '[]'::jsonb end) with ordinality as e(v, i)
          where jsonb_typeof(e.v) = 'object' and _calc_num(e.v -> 'kwh', 0, 1000000) is not null
          order by e.i
          limit 12
        ) t
      )
    )) as j
    from c
  )
  select case when limpio.j ? 'kwh_mes' then limpio.j end from limpio
$$;

revoke all on function _calc_num(jsonb, numeric, numeric) from public, anon;
revoke all on function _calc_txt(jsonb, text) from public, anon;
revoke all on function _calc_bool(jsonb) from public, anon;
revoke all on function _calculo_solicitud(jsonb) from public, anon;

-- ---- registrar_solicitud_web con el cálculo ----
-- Misma lógica que la 36; lo nuevo va marcado con (98).

drop function if exists registrar_solicitud_web(text, text, text, text, text, text, text, text, text, text, text, text, text);

create or replace function registrar_solicitud_web(
  p_nombre text,
  p_telefono text,
  p_email text default null,
  p_ubicacion text default null,
  p_tipos text default null,
  p_uso text default null,
  p_equipo_actual text default null,
  p_consumo text default null,
  p_presupuesto text default null,
  p_plazo text default null,
  p_fuente text default null,
  p_notas text default null,
  p_origen_url text default null,
  p_calculo jsonb default null                                    -- (98)
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_nombre text := left(trim(coalesce(p_nombre, '')), 120);
  v_norm text := normalizar_telefono(p_telefono);
  v_calculo jsonb := _calculo_solicitud(p_calculo);              -- (98)
  v_tipos text := nullif(left(trim(coalesce(p_tipos, '')), 200), '');
  v_notas text := nullif(left(trim(coalesce(p_notas, '')), 2000), '');
  v_n int;
  v_id uuid;
  v_cliente uuid;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el administrador o el conector del sitio.' using errcode = '42501';
  end if;
  if length(v_nombre) < 2 then
    raise exception 'Escribe tu nombre.' using errcode = '22023';
  end if;
  if v_norm is null then
    raise exception 'El WhatsApp debe tener 10 dígitos.' using errcode = '22023';
  end if;
  if p_email is not null and length(trim(p_email)) > 0
     and trim(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'El correo no parece válido.' using errcode = '22023';
  end if;

  -- (98) Con cálculo de la calculadora y sin tipos marcados, es una solicitud solar.
  if v_calculo is not null and v_tipos is null then
    v_tipos := 'Solar';
  end if;

  -- Topes contra abuso: por hora en todo el sitio, y por día para un mismo número.
  v_n := (select count(*) from solicitudes_web where created_at > now() - interval '1 hour');
  if v_n >= 60 then
    raise exception 'Hay muchas solicitudes en este momento.' using errcode = '54000';
  end if;
  v_n := (select count(*) from solicitudes_web
           where telefono_norm = v_norm and created_at > now() - interval '1 day');
  if v_n >= 5 then
    raise exception 'Ya recibimos varias solicitudes de este número hoy.' using errcode = '54000';
  end if;

  -- Un doble clic o un reintento: mismo número y mismo contenido en 10 minutos.
  v_id := (select s.id from solicitudes_web s
            where s.telefono_norm = v_norm
              and s.created_at > now() - interval '10 minutes'
              and coalesce(s.tipos, '') = coalesce(v_tipos, '')
              and coalesce(s.notas, '') = coalesce(v_notas, '')
            limit 1);
  if v_id is not null then
    -- (98) Si el reintento trae el cálculo y la primera no lo tenía, se completa.
    update solicitudes_web set calculo = v_calculo
     where id = v_id and calculo is null and v_calculo is not null;
    return jsonb_build_object('ok', true, 'repetido', true, 'id', v_id);
  end if;

  -- Cliente sugerido: solo si el teléfono es de UNA persona activa; con dos o más
  -- clientes distintos no se adivina.
  if (select count(distinct c.cliente_id) from contactos c
       where c.activo and c.telefono_norm = v_norm) = 1 then
    v_cliente := (select c.cliente_id from contactos c
                   where c.activo and c.telefono_norm = v_norm limit 1);
  end if;

  v_id := gen_random_uuid();
  insert into solicitudes_web (
    id, nombre, telefono, telefono_norm, email, ubicacion, tipos, uso, equipo_actual,
    consumo, presupuesto, plazo, fuente, notas, origen_url, cliente_id, calculo
  ) values (
    v_id, v_nombre, left(trim(p_telefono), 30), v_norm,
    nullif(left(trim(coalesce(p_email, '')), 160), ''),
    nullif(left(trim(coalesce(p_ubicacion, '')), 200), ''),
    v_tipos,
    nullif(left(trim(coalesce(p_uso, '')), 60), ''),
    nullif(left(trim(coalesce(p_equipo_actual, '')), 100), ''),
    nullif(left(trim(coalesce(p_consumo, '')), 100), ''),
    nullif(left(trim(coalesce(p_presupuesto, '')), 100), ''),
    nullif(left(trim(coalesce(p_plazo, '')), 100), ''),
    nullif(left(trim(coalesce(p_fuente, '')), 100), ''),
    v_notas,
    nullif(left(trim(coalesce(p_origen_url, '')), 300), ''),
    v_cliente,
    v_calculo
  );

  return jsonb_build_object('ok', true, 'repetido', false, 'id', v_id,
                            'cliente_sugerido', v_cliente is not null,
                            'calculo', v_calculo is not null);          -- (98)
end $$;

revoke all on function registrar_solicitud_web(text, text, text, text, text, text, text, text, text, text, text, text, text, jsonb)
  from public, anon;
grant execute on function registrar_solicitud_web(text, text, text, text, text, text, text, text, text, text, text, text, text, jsonb)
  to authenticated;

insert into _migraciones (archivo, tipo) values ('98_solicitud_calculo_solar.sql', 'esquema')
on conflict (archivo) do nothing;
