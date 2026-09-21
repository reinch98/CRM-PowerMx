-- ===========================================================================
-- AVISOS DE CITA: al confirmar una cita, mensaje al cliente y a los técnicos
--
-- "Confirmar" = la cita queda `programada` (con fecha, hora y técnicos). Sea por agendarla en
-- la Agenda, por aceptar una cotización con horario propuesto o por programar una que estaba
-- "por programar". Un trigger en `citas` cubre todos esos caminos: no hay que tocar las
-- funciones de 10, 11 ni 14.
--
--   · AL CLIENTE (confirmación con el horario): a quien está a cargo del equipo (el
--     responsable y quien pueda pedir citas); si no hay contactos, al teléfono de la ficha.
--   · A CADA TÉCNICO (T1 y T2): datos del cliente, contacto en sitio con teléfono, dirección,
--     referencias, mapa, equipo con serie, horario y su papel. Nunca precios ni costos.
--   · Si la cita se reprograma o cambia de técnico, o se cancela, avisa de eso, pero solo a
--     quien ya había recibido un mensaje de esa cita.
--
-- El trigger solo pone los avisos en una cola (`avisos`, estado `pendiente`). El TEXTO se arma al
-- momento de leerlos (`texto_aviso`), con los datos de ese momento; al enviarse se guarda una
-- copia (`texto_enviado`). Cómo sale el mensaje es independiente de lo anterior:
--   · hoy: el admin abre la cola en la Agenda y pulsa "Enviar por WhatsApp" (enlace wa.me con el
--     texto ya escrito; un toque por destinatario);
--   · después: una Edge Function con la API de WhatsApp lee la misma cola y manda plantillas.
--
-- Solo admin. Se puede volver a ejecutar sin problema.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Tabla
-- ---------------------------------------------------------------------------
create table if not exists avisos (
  id uuid primary key default gen_random_uuid(),
  cita_id uuid not null references citas(id) on delete cascade,
  tipo text not null check (tipo in ('confirmacion', 'reprogramacion', 'cancelacion')),
  destinatario text not null check (destinatario in ('cliente', 'tecnico')),
  llave text not null,                        -- c:<contacto> | t:<perfil> | f:<cliente> | s:<cita> (quién es)
  contacto_id uuid references contactos(id) on delete set null,
  perfil_id uuid references perfiles(id) on delete set null,
  nombre text,
  telefono text,                              -- nulo si no hay número: se ve en la cola como "sin teléfono"
  estado text not null default 'pendiente' check (estado in ('pendiente', 'enviado', 'descartado')),
  canal text,                                 -- whatsapp_manual | whatsapp_api
  texto_enviado text,                         -- copia de lo que se mandó
  enviado_at timestamptz,
  enviado_por text,
  created_at timestamptz not null default now()
);

create index if not exists idx_avisos_cita on avisos(cita_id);
create index if not exists idx_avisos_estado on avisos(estado) where estado = 'pendiente';
-- A cada quien, un solo aviso pendiente por cita (si ya espera uno, se pone al día solo).
create unique index if not exists un_aviso_pendiente on avisos(cita_id, llave) where estado = 'pendiente';

alter table avisos enable row level security;
revoke all on avisos from anon;
drop policy if exists "admin_avisos" on avisos;
create policy "admin_avisos" on avisos for all to authenticated
  using (es_admin()) with check (es_admin());

-- ---------------------------------------------------------------------------
-- 2. Quién recibe (funciones internas)
-- ---------------------------------------------------------------------------

-- Los contactos del cliente a quienes corresponde avisar de esta cita: los del equipo (el
-- responsable y quien pueda pedir citas); sin equipo, los de toda la empresa que puedan pedir citas.
create or replace function _contactos_de_aviso(p_cita uuid) returns setof contactos
language sql stable security definer set search_path = public as $$
  select ct.*
    from citas c
    join contactos ct on ct.cliente_id = c.cliente_id
   where c.id = p_cita
     and ct.activo and ct.whatsapp and ct.telefono_norm is not null
     and (
       (c.equipo_id is not null and exists (
          select 1 from contactos_por_equipo v
           where v.equipo_id = c.equipo_id and v.contacto_id = ct.id
             and (v.rol = 'responsable' or v.puede_pedir_citas)))
       or (c.equipo_id is null and ct.de_toda_la_empresa and ct.puede_pedir_citas)
     )
$$;
revoke all on function _contactos_de_aviso(uuid) from public, anon, authenticated;

-- El tipo con que se le avisa a ALGUIEN: una reprogramación solo lo es para quien ya recibió
-- un mensaje de esta cita; para quien no (un técnico recién asignado, por ejemplo) es una
-- confirmación normal.
create or replace function _tipo_para(p_cita uuid, p_llave text, p_tipo text) returns text
language sql stable security definer set search_path = public as $$
  select case
           when p_tipo = 'reprogramacion'
                and not exists (select 1 from avisos x
                                 where x.cita_id = p_cita and x.llave = p_llave and x.estado = 'enviado')
             then 'confirmacion'
           else p_tipo
         end
$$;
revoke all on function _tipo_para(uuid, text, text) from public, anon, authenticated;

-- Pone en cola el aviso `p_tipo` de la cita para los técnicos y el cliente. Si a alguien ya le
-- espera un aviso pendiente, no se duplica: el texto se arma al leerlo, así que sale al día.
create or replace function _encolar_avisos(p_cita uuid, p_tipo text) returns int
language plpgsql security definer set search_path = public as $$
declare
  c citas%rowtype;
  cl clientes%rowtype;
  n int := 0;
  k int;
  v_llave text;
begin
  select * into c from citas where id = p_cita;
  if not found then return 0; end if;

  -- Técnicos: T1 y T2, con el teléfono de su perfil (puede faltar).
  insert into avisos (cita_id, tipo, destinatario, llave, perfil_id, nombre, telefono)
  select c.id, _tipo_para(c.id, 't:' || p.id, p_tipo), 'tecnico', 't:' || p.id, p.id,
         coalesce(p.nombre, p.email), nullif(trim(p.telefono), '')
    from perfiles p
   where p.id in (c.tecnico_id, c.tecnico2_id)
  on conflict (cita_id, llave) where estado = 'pendiente' do nothing;
  get diagnostics k = row_count; n := n + k;

  -- Cliente: sus contactos (con teléfono y WhatsApp).
  if exists (select 1 from _contactos_de_aviso(c.id)) then
    insert into avisos (cita_id, tipo, destinatario, llave, contacto_id, nombre, telefono)
    select c.id, _tipo_para(c.id, 'c:' || ct.id, p_tipo), 'cliente', 'c:' || ct.id, ct.id, ct.nombre, ct.telefono
      from _contactos_de_aviso(c.id) ct
    on conflict (cita_id, llave) where estado = 'pendiente' do nothing;
    get diagnostics k = row_count; n := n + k;
  else
    -- Sin contactos: el teléfono de la ficha; si tampoco hay, un aviso sin número, para que la
    -- cola muestre que a ese cliente no hay a quién avisarle.
    select * into cl from clientes where id = c.cliente_id;
    v_llave := case when normalizar_telefono(cl.telefono) is not null then 'f:' || cl.id else 's:' || c.id end;
    insert into avisos (cita_id, tipo, destinatario, llave, nombre, telefono)
    values (c.id, _tipo_para(c.id, v_llave, p_tipo), 'cliente', v_llave,
            coalesce(nullif(trim(cl.contacto_nombre), ''), cl.nombre),
            case when normalizar_telefono(cl.telefono) is not null then cl.telefono end)
    on conflict (cita_id, llave) where estado = 'pendiente' do nothing;
    get diagnostics k = row_count; n := n + k;
  end if;

  return n;
end $$;
revoke all on function _encolar_avisos(uuid, text) from public, anon, authenticated;

-- Cancelación: solo se avisa a quien ya había recibido un mensaje de esta cita. A quien no se le
-- había avisado, se le quita lo pendiente y listo. `p_solo_tecnicos_fuera`: cuando la cita sigue
-- en pie pero un técnico ya no está asignado, solo se avisa a los técnicos que quedaron fuera.
create or replace function _cancelar_avisos(p_cita uuid, p_solo_tecnicos_fuera boolean default false)
returns void
language plpgsql security definer set search_path = public as $$
declare c citas%rowtype;
begin
  select * into c from citas where id = p_cita;

  -- Con historial de envío: el pendiente (si lo hay) pasa a ser una cancelación; si no lo hay, se crea.
  insert into avisos (cita_id, tipo, destinatario, llave, contacto_id, perfil_id, nombre, telefono)
  select distinct on (a.llave) a.cita_id, 'cancelacion', a.destinatario, a.llave, a.contacto_id, a.perfil_id, a.nombre, a.telefono
    from avisos a
   where a.cita_id = p_cita and a.estado = 'enviado' and a.tipo <> 'cancelacion'
     and not exists (select 1 from avisos b where b.cita_id = a.cita_id and b.llave = a.llave and b.tipo = 'cancelacion' and b.estado = 'enviado')
     and (not p_solo_tecnicos_fuera
          or (a.destinatario = 'tecnico' and a.perfil_id is distinct from c.tecnico_id and a.perfil_id is distinct from c.tecnico2_id))
   order by a.llave, a.enviado_at desc
  on conflict (cita_id, llave) where estado = 'pendiente'
    do update set tipo = 'cancelacion';

  -- Sin historial de envío: lo pendiente ya no tiene sentido.
  update avisos a set estado = 'descartado'
   where a.cita_id = p_cita and a.estado = 'pendiente' and a.tipo <> 'cancelacion'
     and not exists (select 1 from avisos b where b.cita_id = a.cita_id and b.llave = a.llave and b.estado = 'enviado')
     and (not p_solo_tecnicos_fuera
          or (a.destinatario = 'tecnico' and a.perfil_id is distinct from c.tecnico_id and a.perfil_id is distinct from c.tecnico2_id));
end $$;
revoke all on function _cancelar_avisos(uuid, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Trigger en citas
-- ---------------------------------------------------------------------------
create or replace function avisos_de_cita() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.estado = 'programada' and new.fecha is not null then
      perform _encolar_avisos(new.id, 'confirmacion');
    end if;
    return new;
  end if;

  -- UPDATE
  if new.estado = 'programada' and old.estado is distinct from 'programada' and new.fecha is not null then
    perform _encolar_avisos(new.id, 'confirmacion');

  elsif new.estado = 'programada' and old.estado = 'programada' and (
        new.fecha is distinct from old.fecha or new.hora is distinct from old.hora
        or new.duracion_min is distinct from old.duracion_min
        or new.tecnico_id is distinct from old.tecnico_id
        or new.tecnico2_id is distinct from old.tecnico2_id) then
    -- A quien ya recibió aviso se le manda el cambio; a quien no, se le pone al día solo lo pendiente.
    perform _encolar_avisos(new.id, 'reprogramacion');
    -- Un técnico que quedó fuera de la cita recibe un "ya no estás asignado".
    if new.tecnico_id is distinct from old.tecnico_id or new.tecnico2_id is distinct from old.tecnico2_id then
      perform _cancelar_avisos(new.id, true);
    end if;

  elsif new.estado = 'cancelada' and old.estado = 'programada' then
    perform _cancelar_avisos(new.id, false);
  end if;
  return new;
end $$;

drop trigger if exists avisos_de_cita on citas;
create trigger avisos_de_cita
  after insert or update on citas
  for each row execute function avisos_de_cita();

-- ---------------------------------------------------------------------------
-- 4. El texto del mensaje (se arma al leer, con los datos de ese momento)
-- ---------------------------------------------------------------------------
create or replace function texto_aviso(p_aviso uuid) returns text
language plpgsql stable security definer set search_path = public as $$
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
end $$;

-- ---------------------------------------------------------------------------
-- 5. Lo que ve el admin
-- ---------------------------------------------------------------------------

-- La cola: pendientes (con el texto ya armado) y lo de los últimos 3 días.
create or replace function avisos_pendientes() returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'pendientes', coalesce((
      select jsonb_agg(jsonb_build_object(
          'id', a.id, 'cita_id', a.cita_id, 'tipo', a.tipo, 'destinatario', a.destinatario,
          'nombre', a.nombre, 'telefono', a.telefono, 'telefono_norm', normalizar_telefono(a.telefono),
          'fecha', ci.fecha, 'hora', ci.hora, 'cliente', cl.nombre,
          'texto', texto_aviso(a.id)
        ) order by ci.fecha nulls last, ci.hora nulls last, a.destinatario desc, a.nombre)
        from avisos a
        join citas ci on ci.id = a.cita_id
        join clientes cl on cl.id = ci.cliente_id
       where a.estado = 'pendiente'), '[]'::jsonb),
    'recientes', coalesce((
      select jsonb_agg(jsonb_build_object(
          'id', a.id, 'tipo', a.tipo, 'destinatario', a.destinatario, 'nombre', a.nombre,
          'telefono', a.telefono, 'telefono_norm', normalizar_telefono(a.telefono),
          'estado', a.estado, 'enviado_at', a.enviado_at, 'cliente', cl.nombre,
          'fecha', ci.fecha, 'hora', ci.hora, 'texto', a.texto_enviado
        ) order by coalesce(a.enviado_at, a.created_at) desc)
        from avisos a
        join citas ci on ci.id = a.cita_id
        join clientes cl on cl.id = ci.cliente_id
       where a.estado in ('enviado', 'descartado')
         and coalesce(a.enviado_at, a.created_at) > now() - interval '3 days'), '[]'::jsonb)
  ) into r;
  return r;
end $$;

-- Marca un aviso como enviado (guarda el texto que salió) o descartado. Repetirlo no hace nada.
create or replace function marcar_aviso(p_id uuid, p_estado text, p_canal text default 'whatsapp_manual')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare a avisos%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if p_estado not in ('enviado', 'descartado') then
    raise exception 'Estado no válido: %', p_estado using errcode = '22023';
  end if;
  select * into a from avisos where id = p_id for update;
  if not found then raise exception 'El aviso no existe.' using errcode = 'P0002'; end if;
  if a.estado <> 'pendiente' then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'estado', a.estado);
  end if;

  update avisos
     set estado = p_estado,
         canal = case when p_estado = 'enviado' then p_canal end,
         texto_enviado = case when p_estado = 'enviado' then texto_aviso(p_id) end,
         enviado_at = case when p_estado = 'enviado' then now() end,
         enviado_por = coalesce(auth.jwt() ->> 'email', 'crm')
   where id = p_id;
  return jsonb_build_object('ok', true, 'estado', p_estado);
end $$;

do $$
declare f text;
begin
  foreach f in array array['texto_aviso(uuid)', 'avisos_pendientes()', 'marcar_aviso(uuid, text, text)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

notify pgrst, 'reload schema';

-- Verificación: la tabla con RLS y el trigger puesto.
select 'rls avisos' as que, relrowsecurity::text as ok from pg_class where relname = 'avisos'
union all
select 'trigger avisos_de_cita', exists (select 1 from pg_trigger where tgname = 'avisos_de_cita' and not tgisinternal)::text;
