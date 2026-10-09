-- ---------------------------------------------------------------------------
-- 54_recordatorio_cita.sql — el recordatorio del día anterior, que faltaba.
--
-- Estaba en el plan original de avisos de cita ("confirmación por plantilla →
-- recordatorio el día anterior → ...") pero nunca se construyó: `avisos.tipo` solo
-- aceptaba confirmacion/reprogramacion/cancelacion. Se agrega aquí, pensado para
-- cuando las plantillas de Meta estén aprobadas y se pueda mandar de verdad por la
-- API — mientras tanto, sale igual en la cola de "Avisos pendientes" de la Agenda y
-- se manda a mano con el enlace de WhatsApp, como los demás.
--
-- Solo para el CLIENTE: el técnico ya ve su agenda en la app; no se le agregó un
-- recordatorio aparte (se puede sumar después si hace falta).
--
-- Repetible: la restricción se busca por su definición (no por nombre, como ya se
-- aprendió en 21_tarifas_catalogo.sql) y las funciones son `create or replace`.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. `avisos.tipo` gana 'recordatorio'
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select con.conname
      from pg_constraint con
      join pg_class rel on rel.oid = con.conrelid
     where rel.relname = 'avisos' and con.contype = 'c'
       and pg_get_constraintdef(con.oid) ilike '%confirmacion%reprogramacion%cancelacion%'
  loop
    execute format('alter table avisos drop constraint %I', r.conname);
  end loop;
end $$;

alter table avisos add constraint avisos_tipo_check
  check (tipo in ('confirmacion', 'reprogramacion', 'cancelacion', 'recordatorio'));

-- ---------------------------------------------------------------------------
-- 2. Generarlo: un recordatorio por cada cliente de cada cita `programada` para
-- MAÑANA (hora de Mérida). Set-based, no por cita una por una, y se puede llamar
-- varias veces el mismo día sin duplicar — no depende solo del índice de "un
-- pendiente por llave" (ese se salta si ya se MANDÓ), sino de que nunca haya
-- existido un recordatorio para esa cita y ese destinatario.
-- ---------------------------------------------------------------------------
create or replace function generar_recordatorios() returns int
language plpgsql security definer set search_path = public as $$
declare
  v_manana date := (now() at time zone 'America/Mexico_City')::date + 1;
  n int := 0;
  k int;
begin
  -- Con contactos del equipo (o de toda la empresa, si no hay equipo): uno por contacto.
  insert into avisos (cita_id, tipo, destinatario, llave, contacto_id, nombre, telefono)
  select c.id, 'recordatorio', 'cliente', 'c:' || ct.id, ct.id, ct.nombre, ct.telefono
    from citas c
    cross join lateral _contactos_de_aviso(c.id) ct
   where c.estado = 'programada' and c.fecha = v_manana
     and not exists (
       select 1 from avisos x where x.cita_id = c.id and x.llave = 'c:' || ct.id and x.tipo = 'recordatorio')
  on conflict (cita_id, llave) where estado = 'pendiente' do nothing;
  get diagnostics k = row_count; n := n + k;

  -- Sin contactos: el teléfono de la ficha del cliente, si tiene.
  insert into avisos (cita_id, tipo, destinatario, llave, nombre, telefono)
  select c.id, 'recordatorio', 'cliente', 'f:' || cl.id,
         coalesce(nullif(trim(cl.contacto_nombre), ''), cl.nombre), cl.telefono
    from citas c
    join clientes cl on cl.id = c.cliente_id
   where c.estado = 'programada' and c.fecha = v_manana
     and normalizar_telefono(cl.telefono) is not null
     and not exists (select 1 from _contactos_de_aviso(c.id))
     and not exists (
       select 1 from avisos x where x.cita_id = c.id and x.llave = 'f:' || cl.id and x.tipo = 'recordatorio')
  on conflict (cita_id, llave) where estado = 'pendiente' do nothing;
  get diagnostics k = row_count; n := n + k;

  return n;
end $$;

-- Revocada a todos: no es para llamarla por la API. La llama el cron (como dueño de
-- la base, que no pasa por estos permisos) o tú a mano desde el editor SQL para probar.
revoke all on function generar_recordatorios() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. El texto del recordatorio. Redefine texto_aviso() completa (igual que hizo la
-- 29 con paquete_preventivo): una función, no se puede "parchar" una rama sola.
-- Única rama nueva: cliente + recordatorio, entre cancelacion y confirmacion/reprogramacion.
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
    if a.tipo = 'recordatorio' then
      return concat_ws(E'\n', v_hola, '',
        'Le recordamos su cita con PowerMx mañana: ' || v_tipo || coalesce(' de su ' || v_equipo, '') || '.',
        '', 'Fecha: ' || v_cuando, v_dur,
        case when v_tec <> '' then 'Lo atenderá: ' || v_tec end,
        '', 'Si necesita cambiar la fecha, responda a este mensaje.', 'PowerMx');
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
-- 4. Programar el cron — ESTO LO TIENES QUE HACER TÚ, UNA VEZ, a mano:
--
-- a) Supabase → Database → Extensions → busca "pg_cron" → Enable.
-- b) En el editor SQL, corre (una sola vez; con esto ya queda guardado):
--
--      select cron.schedule(
--        'recordatorios-de-cita',
--        '0 14 * * *',                 -- 14:00 UTC = 08:00 en Mérida (sin horario de verano)
--        $$select generar_recordatorios()$$
--      );
--
-- c) Para comprobar que quedó: select * from cron.job;
-- d) Para cambiar la hora o quitarlo después:
--      select cron.alter_job((select jobid from cron.job where jobname = 'recordatorios-de-cita'), schedule => '...');
--      select cron.unschedule('recordatorios-de-cita');
--
-- Mientras no lo programes, `generar_recordatorios()` existe pero nadie la llama —
-- no pasa nada malo, simplemente no salen recordatorios. También la puedes llamar
-- a mano desde el editor para probarla: select generar_recordatorios();
-- ---------------------------------------------------------------------------

notify pgrst, 'reload schema';

-- Registro (ver 68).
insert into _migraciones (archivo, tipo) values ('54_recordatorio_cita.sql', 'esquema')
on conflict (archivo) do nothing;
