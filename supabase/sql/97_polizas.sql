-- ===========================================================================
-- 97 · Pólizas de servicio para generadores (10/11/2026)
--
-- Pedido de Caña: llevar al CRM la póliza nueva (plantilla "Póliza de servicio para generadores —
-- PowerMx"): tres niveles, vigencia de 12 meses y visitas que se agendan solas.
--
--   · `polizas`: una por equipo y vigencia (folio POL-n), con nivel (basica | estandar | integral),
--     alcance (aire | liquido: el anexo técnico A o B), precio y forma de pago. Estados
--     vigente | cancelada; "vencida" no se guarda: es una vigente con `fin` pasado.
--   · `poliza_visitas`: el calendario. Se arma solo al crear la póliza con `_plan_poliza`:
--       básica            → menor (mes 0) y mayor (mes 6)
--       estándar          → menor, inspección (3), mayor (6), inspección (9)
--       integral aire     → igual que estándar
--       integral líquido  → menor, mayor con banco de carga (6) e inspección los otros 10 meses
--   · `generar_citas_poliza(dias)` abre, para cada visita que cae en los próximos `dias`, una cita
--     `por_programar` (preventivo, origen `poliza`) con su orden, igual que la Agenda: el admin la
--     programa ahí con fecha y técnicos. La llama un reloj diario (07:00 de Mérida) y la propia
--     `crear_poliza`, para que la primera visita aparezca de inmediato.
--   · Un disparador en `citas` mantiene la visita al día: realizada → visita realizada y el
--     `proximo_mantenimiento` del equipo pasa a la siguiente; cancelada → la visita vuelve a
--     pendiente (la póliza la prometió) y el reloj abre otra cita. Para no hacerla, se omite con
--     motivo (`omitir_visita_poliza`).
--   · `cancelar_poliza` cancela las citas que aún no tienen trabajo; las demás se quedan.
--   · `equipos.en_poliza` lo mantiene la base: verdadero mientras el equipo tenga una póliza vigente.
--
-- Solo admin (aquí hay precios). SQL plano fuera de las funciones, sin `select ... into` (ver
-- CLAUDE.md). Repetible.
-- ===========================================================================

create table if not exists polizas (
  id            uuid primary key default gen_random_uuid(),
  folio         bigint generated always as identity unique,
  cliente_id    uuid not null references clientes (id),
  equipo_id     uuid not null references equipos (id),
  nivel         text not null check (nivel in ('basica', 'estandar', 'integral')),
  alcance       text not null check (alcance in ('aire', 'liquido')),
  inicio        date not null,
  fin           date not null,
  subtotal      numeric(14, 2) not null default 0 check (subtotal >= 0),
  iva           numeric(14, 2) not null default 0 check (iva >= 0),
  total         numeric(14, 2) not null default 0 check (total >= 0),
  forma_pago    text,
  estado        text not null default 'vigente' check (estado in ('vigente', 'cancelada')),
  motivo        text,
  notas         text,
  renueva_a     uuid references polizas (id),
  creada_por    text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint polizas_fechas check (fin > inicio)
);
create index if not exists idx_polizas_equipo on polizas (equipo_id, inicio desc);
create index if not exists idx_polizas_cliente on polizas (cliente_id);

create table if not exists poliza_visitas (
  id          uuid primary key default gen_random_uuid(),
  poliza_id   uuid not null references polizas (id) on delete cascade,
  numero      int not null,
  tipo        text not null check (tipo in ('menor', 'mayor', 'inspeccion')),
  banco_carga boolean not null default false,
  fecha       date not null,                       -- fecha programada (inicio + n meses)
  estado      text not null default 'pendiente'
              check (estado in ('pendiente', 'agendada', 'realizada', 'omitida', 'cancelada')),
  cita_id     uuid references citas (id) on delete set null,
  realizada_en date,
  motivo      text,
  created_at  timestamptz not null default now(),
  unique (poliza_id, numero)
);
create index if not exists idx_poliza_visitas_cita on poliza_visitas (cita_id);
create index if not exists idx_poliza_visitas_pendientes on poliza_visitas (fecha) where estado = 'pendiente';

alter table polizas enable row level security;
alter table poliza_visitas enable row level security;
drop policy if exists admin_polizas on polizas;
create policy admin_polizas on polizas for all to authenticated
  using (es_admin()) with check (es_admin());
drop policy if exists admin_poliza_visitas on poliza_visitas;
create policy admin_poliza_visitas on poliza_visitas for all to authenticated
  using (es_admin()) with check (es_admin());
revoke all on polizas, poliza_visitas from anon;
grant select, insert, update on polizas, poliza_visitas to authenticated;

-- ---------------------------------------------------------------------------
-- El calendario de cada nivel: (mes desde el inicio, tipo, banco de carga)
-- ---------------------------------------------------------------------------
create or replace function _plan_poliza(p_nivel text, p_alcance text)
returns table (mes int, tipo text, banco_carga boolean)
language sql immutable as $$
  select * from (values (0, 'menor', false), (6, 'mayor', false)) v (mes, tipo, banco_carga)
   where p_nivel = 'basica'
  union all
  select * from (values (0, 'menor', false), (3, 'inspeccion', false),
                        (6, 'mayor', false), (9, 'inspeccion', false)) v (mes, tipo, banco_carga)
   where p_nivel = 'estandar' or (p_nivel = 'integral' and p_alcance = 'aire')
  union all
  select g, case g when 0 then 'menor' when 6 then 'mayor' else 'inspeccion' end, g = 6
    from generate_series(0, 11) g
   where p_nivel = 'integral' and p_alcance = 'liquido'
  order by 1
$$;

-- Aire o líquido según el equipo: lo que diga `atributos.enfriamiento` (SQL 94), si no el
-- combustible (diésel = líquido) y la capacidad (30 kW o más = líquido).
create or replace function _alcance_de_equipo(p_equipo uuid)
returns text language sql stable set search_path = public as $$
  select case
           when e.atributos ->> 'enfriamiento' in ('liquid_cooled', 'liquido') then 'liquido'
           when e.atributos ->> 'enfriamiento' in ('air_cooled', 'aire') then 'aire'
           when e.atributos ->> 'combustible' = 'diesel' then 'liquido'
           when coalesce(e.capacidad_kw, 0) >= 30 then 'liquido'
           else 'aire'
         end
    from equipos e where e.id = p_equipo
$$;

-- `en_poliza` y `proximo_mantenimiento` del equipo, desde sus pólizas.
create or replace function _sincronizar_equipo_poliza(p_equipo uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_vigente boolean;
  v_proxima date;
begin
  v_vigente := exists (select 1 from polizas
                        where equipo_id = p_equipo and estado = 'vigente' and fin >= _hoy_merida());
  v_proxima := (select min(v.fecha) from poliza_visitas v join polizas p on p.id = v.poliza_id
                 where p.equipo_id = p_equipo and p.estado = 'vigente'
                   and v.estado in ('pendiente', 'agendada'));
  update equipos
     set en_poliza = v_vigente,
         proximo_mantenimiento = case when v_vigente then v_proxima else proximo_mantenimiento end
   where id = p_equipo;
end $$;
revoke execute on function _sincronizar_equipo_poliza(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Abrir las citas de las visitas que ya se acercan
-- ---------------------------------------------------------------------------
create or replace function generar_citas_poliza(p_dias int default 21)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v record;
  v_cita uuid;
  v_n int := 0;
begin
  -- La llama el reloj (sin sesión) o un admin. Un usuario con sesión que no sea admin, no.
  if auth.uid() is not null and not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;

  for v in
    select pv.id, pv.numero, pv.tipo, pv.banco_carga, pv.fecha, p.folio,
           p.cliente_id, p.equipo_id,
           (select count(*) from poliza_visitas x where x.poliza_id = p.id) visitas
      from poliza_visitas pv
      join polizas p on p.id = pv.poliza_id
     where pv.estado = 'pendiente'
       and p.estado = 'vigente'
       and pv.fecha <= _hoy_merida() + greatest(coalesce(p_dias, 21), 0)
     order by pv.fecha
       for update of pv skip locked
  loop
    v_cita := gen_random_uuid();
    insert into citas (id, cliente_id, equipo_id, tipo_servicio, estado, origen, notas, zona)
    values (v_cita, v.cliente_id, v.equipo_id, 'preventivo', 'por_programar', 'poliza',
            format('Póliza POL-%s · visita %s de %s · %s%s · toca el %s',
                   v.folio, v.numero, v.visitas,
                   case v.tipo when 'menor' then 'Servicio menor' when 'mayor' then 'Servicio mayor'
                               else 'Visita de inspección' end,
                   case when v.banco_carga then ' con banco de carga' else '' end,
                   to_char(v.fecha, 'DD/MM/YYYY')),
            (select zona from clientes where id = v.cliente_id));

    insert into ordenes_servicio (cliente_id, equipo_id, cita_id, tipo_servicio, estado)
    values (v.cliente_id, v.equipo_id, v_cita, 'preventivo', 'abierta');

    update poliza_visitas set estado = 'agendada', cita_id = v_cita where id = v.id;
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'citas', v_n);
end $$;

-- ---------------------------------------------------------------------------
-- La cita manda sobre la visita
-- ---------------------------------------------------------------------------
create or replace function _visita_sigue_cita()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_poliza uuid;
begin
  if new.estado is not distinct from old.estado then return new; end if;
  v_poliza := (select poliza_id from poliza_visitas where cita_id = new.id limit 1);
  if v_poliza is null then return new; end if;

  if new.estado = 'realizada' then
    update poliza_visitas
       set estado = 'realizada', realizada_en = coalesce(new.fecha, _hoy_merida())
     where cita_id = new.id and estado = 'agendada';
  elsif new.estado = 'cancelada' then
    -- La póliza prometió la visita: vuelve a pendiente y el reloj abre otra cita.
    update poliza_visitas
       set estado = 'pendiente', cita_id = null
     where cita_id = new.id and estado = 'agendada';
  end if;

  perform _sincronizar_equipo_poliza((select equipo_id from polizas where id = v_poliza));
  return new;
end $$;

drop trigger if exists visita_sigue_cita on citas;
create trigger visita_sigue_cita after update of estado on citas
  for each row execute function _visita_sigue_cita();

-- ---------------------------------------------------------------------------
-- Crear (o renovar) una póliza
-- ---------------------------------------------------------------------------
-- datos: {equipo_id, nivel, alcance?, inicio, subtotal, iva?, forma_pago?, notas?, renueva_a?}
create or replace function crear_poliza(p_datos jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_equipo   uuid := nullif(p_datos ->> 'equipo_id', '')::uuid;
  v_nivel    text := nullif(p_datos ->> 'nivel', '');
  v_alcance  text := nullif(p_datos ->> 'alcance', '');
  v_inicio   date := nullif(p_datos ->> 'inicio', '')::date;
  v_fin      date;
  v_subtotal numeric := coalesce(nullif(p_datos ->> 'subtotal', '')::numeric, 0);
  v_iva      numeric;
  v_renueva  uuid := nullif(p_datos ->> 'renueva_a', '')::uuid;
  v_cliente  uuid;
  v_id       uuid := gen_random_uuid();
  v_folio    bigint;
  v_citas    jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador da de alta pólizas.' using errcode = '42501';
  end if;
  if v_equipo is null then raise exception 'Elige el equipo.' using errcode = '22023'; end if;
  v_cliente := (select cliente_id from equipos where id = v_equipo);
  if v_cliente is null then raise exception 'Ese equipo no existe.' using errcode = '22023'; end if;
  if v_nivel is null or v_nivel not in ('basica', 'estandar', 'integral') then
    raise exception 'Elige el nivel: básica, estándar o integral.' using errcode = '22023';
  end if;
  v_alcance := coalesce(v_alcance, _alcance_de_equipo(v_equipo));
  if v_alcance not in ('aire', 'liquido') then
    raise exception 'El alcance es "aire" o "liquido".' using errcode = '22023';
  end if;
  if v_renueva is not null then
    if not exists (select 1 from polizas where id = v_renueva and equipo_id = v_equipo) then
      raise exception 'La póliza que se renueva no es de este equipo.' using errcode = '22023';
    end if;
    v_inicio := coalesce(v_inicio, (select fin + 1 from polizas where id = v_renueva));
  end if;
  if v_inicio is null then raise exception 'Falta la fecha de inicio.' using errcode = '22023'; end if;
  if v_subtotal < 0 then raise exception 'El precio no puede ser negativo.' using errcode = '22023'; end if;
  v_fin := (v_inicio + interval '12 months')::date - 1;

  if exists (select 1 from polizas
              where equipo_id = v_equipo and estado = 'vigente'
                and daterange(inicio, fin, '[]') && daterange(v_inicio, v_fin, '[]')) then
    raise exception 'Ese equipo ya tiene una póliza vigente en esas fechas. Renuévala o cancélala antes.'
      using errcode = '22023';
  end if;

  v_iva := coalesce(nullif(p_datos ->> 'iva', '')::numeric, round(v_subtotal * 0.16, 2));

  insert into polizas (id, cliente_id, equipo_id, nivel, alcance, inicio, fin, subtotal, iva, total,
                       forma_pago, notas, renueva_a, creada_por)
  values (v_id, v_cliente, v_equipo, v_nivel, v_alcance, v_inicio, v_fin, v_subtotal, v_iva,
          v_subtotal + v_iva, nullif(trim(coalesce(p_datos ->> 'forma_pago', '')), ''),
          nullif(trim(coalesce(p_datos ->> 'notas', '')), ''), v_renueva,
          coalesce(auth.jwt() ->> 'email', 'crm'));

  insert into poliza_visitas (poliza_id, numero, tipo, banco_carga, fecha)
  select v_id, row_number() over (order by pl.mes), pl.tipo, pl.banco_carga,
         (v_inicio + make_interval(months => pl.mes))::date
    from _plan_poliza(v_nivel, v_alcance) pl;

  v_folio := (select folio from polizas where id = v_id);
  perform _apunta('polizas', v_id, 'crear', null,
                  jsonb_build_object('folio', v_folio, 'nivel', v_nivel, 'alcance', v_alcance,
                                     'inicio', v_inicio, 'total', v_subtotal + v_iva), 'oficina');

  v_citas := generar_citas_poliza(21);
  perform _sincronizar_equipo_poliza(v_equipo);

  return jsonb_build_object('ok', true, 'id', v_id, 'folio', v_folio, 'fin', v_fin,
                            'visitas', (select count(*) from poliza_visitas where poliza_id = v_id),
                            'citas', v_citas -> 'citas');
end $$;

-- ---------------------------------------------------------------------------
-- Omitir una visita y cancelar una póliza
-- ---------------------------------------------------------------------------
create or replace function omitir_visita_poliza(p_visita uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v poliza_visitas%rowtype;
  v_r jsonb;
begin
  if not es_admin() then raise exception 'Solo el administrador.' using errcode = '42501'; end if;
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Escribe por qué no se hará esta visita.' using errcode = '22023';
  end if;
  v := (select x from poliza_visitas x where x.id = p_visita);
  if v.id is null then raise exception 'Esa visita no existe.' using errcode = '22023'; end if;
  if v.estado not in ('pendiente', 'agendada') then
    raise exception 'Esa visita ya está %.', v.estado using errcode = '22023';
  end if;
  if v.cita_id is not null then
    v_r := cancelar_cita(v.cita_id);
    if not coalesce((v_r ->> 'ok')::boolean, false) then
      raise exception 'Su orden ya tiene trabajo capturado: ciérrala en lugar de omitir la visita.'
        using errcode = '22023';
    end if;
  end if;
  update poliza_visitas set estado = 'omitida', cita_id = null, motivo = trim(p_motivo)
   where id = p_visita;
  perform _apunta('poliza_visitas', p_visita, 'omitir', null,
                  jsonb_build_object('motivo', trim(p_motivo)), 'oficina');
  perform _sincronizar_equipo_poliza((select equipo_id from polizas where id = v.poliza_id));
  return jsonb_build_object('ok', true);
end $$;

create or replace function cancelar_poliza(p_poliza uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  p polizas%rowtype;
  c record;
  v_r jsonb;
  v_canceladas int := 0;
  v_con_trabajo int := 0;
begin
  if not es_admin() then raise exception 'Solo el administrador.' using errcode = '42501'; end if;
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Escribe por qué se cancela la póliza.' using errcode = '22023';
  end if;
  p := (select x from polizas x where x.id = p_poliza);
  if p.id is null then raise exception 'Esa póliza no existe.' using errcode = '22023'; end if;
  if p.estado = 'cancelada' then return jsonb_build_object('ok', true, 'sin_cambio', true); end if;

  update polizas set estado = 'cancelada', motivo = trim(p_motivo), updated_at = now() where id = p_poliza;

  for c in select id, cita_id from poliza_visitas
            where poliza_id = p_poliza and estado = 'agendada' and cita_id is not null
  loop
    v_r := cancelar_cita(c.cita_id);
    if coalesce((v_r ->> 'ok')::boolean, false) then
      v_canceladas := v_canceladas + 1;
    else
      v_con_trabajo := v_con_trabajo + 1;
    end if;
  end loop;
  -- El disparador regresó a pendiente las que se cancelaron; ya no se harán.
  update poliza_visitas set estado = 'cancelada', cita_id = null
   where poliza_id = p_poliza and estado = 'pendiente';

  perform _apunta('polizas', p_poliza, 'cancelar', null,
                  jsonb_build_object('motivo', trim(p_motivo), 'citas_canceladas', v_canceladas,
                                     'citas_con_trabajo', v_con_trabajo), 'oficina');
  perform _sincronizar_equipo_poliza(p.equipo_id);
  return jsonb_build_object('ok', true, 'citas_canceladas', v_canceladas, 'citas_con_trabajo', v_con_trabajo);
end $$;

-- ---------------------------------------------------------------------------
-- Lista para la pantalla
-- ---------------------------------------------------------------------------
create or replace function polizas_lista(p_dias int default 365)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not es_admin() then raise exception 'Solo el administrador.' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', p.id, 'folio', p.folio, 'nivel', p.nivel, 'alcance', p.alcance,
             'inicio', p.inicio, 'fin', p.fin, 'subtotal', p.subtotal, 'iva', p.iva, 'total', p.total,
             'forma_pago', p.forma_pago, 'estado', p.estado, 'motivo', p.motivo, 'notas', p.notas,
             'renueva_a', p.renueva_a,
             'renovada', exists (select 1 from polizas r where r.renueva_a = p.id and r.estado = 'vigente'),
             'cliente_id', p.cliente_id, 'cliente', c.nombre, 'telefono', c.telefono,
             'equipo_id', p.equipo_id,
             'equipo', concat_ws(' ', e.marca, e.modelo,
                                 case when e.capacidad_kw is not null then e.capacidad_kw || ' kW' end),
             'serie', e.numero_serie,
             'visitas', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'id', v.id, 'numero', v.numero, 'tipo', v.tipo, 'banco_carga', v.banco_carga,
                        'fecha', v.fecha, 'estado', v.estado, 'realizada_en', v.realizada_en,
                        'motivo', v.motivo, 'cita_id', v.cita_id,
                        'cita_estado', ci.estado, 'cita_fecha', ci.fecha) order by v.numero)
                 from poliza_visitas v left join citas ci on ci.id = v.cita_id
                where v.poliza_id = p.id), '[]'::jsonb))
           order by (p.estado = 'vigente' and p.fin >= _hoy_merida()) desc, p.fin, p.folio)
      from polizas p
      join clientes c on c.id = p.cliente_id
      join equipos e on e.id = p.equipo_id
     where p.fin >= _hoy_merida() - greatest(coalesce(p_dias, 365), 0)
        or (p.estado = 'vigente' and p.fin >= _hoy_merida())
  ), '[]'::jsonb);
end $$;

revoke execute on function crear_poliza(jsonb), omitir_visita_poliza(uuid, text),
  cancelar_poliza(uuid, text), polizas_lista(int), generar_citas_poliza(int)
  from public, anon;
grant execute on function crear_poliza(jsonb), omitir_visita_poliza(uuid, text),
  cancelar_poliza(uuid, text), polizas_lista(int), generar_citas_poliza(int)
  to authenticated;

-- Reloj diario: 13:00 UTC = 07:00 de Mérida. `cron.schedule` con el mismo nombre lo reemplaza.
select cron.schedule('citas-de-poliza', '0 13 * * *', 'select public.generar_citas_poliza(21)');

notify pgrst, 'reload schema';

insert into _migraciones (archivo, tipo) values ('97_polizas.sql', 'esquema')
on conflict (archivo) do nothing;
