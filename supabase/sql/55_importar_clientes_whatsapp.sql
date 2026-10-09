-- ===========================================================================
-- IMPORTAR CLIENTES DESDE EL HISTORIAL DE WHATSAPP (solo los que confirmaron con PowerMx)
--
-- De dónde sale: `agente_powermx_contexto.csv`, que arma el reporte con los clientes marcados
-- "PowerMx (confirmó)" en la hoja Asignación. Se sube a la tabla `importacion_whatsapp` con
-- Supabase → Table Editor → importacion_whatsapp → Insert → Import data from CSV (los
-- encabezados del CSV son los nombres de las columnas).
--
-- POR QUÉ UNA TABLA DE PASO Y NO DIRECTO A `contactos`:
-- el trigger de la 22 liga una conversación al contacto con solo estar ACTIVO, y desde ese
-- momento el agente ve los datos de ese cliente (`_cliente_de_conversacion`). Un número mal
-- capturado en el CSV le daría datos de un cliente a otra persona. Así que nada entra a
-- `contactos` hasta que el admin lo acepta, uno por uno, con `aceptar_importacion_whatsapp`
-- (la regla de siempre: el cliente lo crea el admin).
--
-- Además, `wa_contexto` gana dos datos para que el agente no vuelva a preguntar lo que ya se
-- sabe: el PENDIENTE que quedó en el historial y la RAZÓN SOCIAL a la que se factura (de
-- `datos_fiscales` si existe; si no, la del historial).
--
-- Sin `select ... into` en los bloques plpgsql: el editor de Supabase los mutila (ver
-- CLAUDE.md). Se usa asignación. Se puede repetir. Prueba: 55_prueba_importar_clientes_whatsapp.sql.
-- ===========================================================================

create table if not exists importacion_whatsapp (
  id uuid primary key default gen_random_uuid(),
  -- columnas del CSV (mismos nombres que sus encabezados)
  telefono text not null,
  nombre text,
  empresa text,
  ciudad text,
  equipo text,
  ultimo_servicio text,
  pendiente text,
  segmento text,
  factura text,
  razon_social text,
  nota text,
  -- revisión
  telefono_norm text generated always as (normalizar_telefono(telefono)) stored,
  estado text not null default 'por_revisar' check (estado in ('por_revisar', 'aceptada', 'descartada')),
  cliente_id uuid references clientes(id) on delete set null,
  contacto_id uuid references contactos(id) on delete set null,
  motivo text,
  revisado_por text,
  revisado_en timestamptz,
  created_at timestamptz not null default now()
);

-- Un número no se importa dos veces (subir el mismo CSV otra vez no duplica: falla esa fila).
create unique index if not exists un_importacion_whatsapp_tel
  on importacion_whatsapp(telefono_norm) where telefono_norm is not null;

alter table importacion_whatsapp enable row level security;
revoke all on importacion_whatsapp from anon;
-- Supabase ya lo concede por defecto; explícito para no depender de eso (RLS sigue mandando).
grant select, insert, update, delete on importacion_whatsapp to authenticated;
drop policy if exists "admin_importacion_whatsapp" on importacion_whatsapp;
create policy "admin_importacion_whatsapp" on importacion_whatsapp for all to authenticated
  using (es_admin()) with check (es_admin());

-- ---------------------------------------------------------------------------
-- Aceptar: crea (o usa) el cliente, crea el contacto VERIFICADO y liga la conversación
-- que ya exista de ese número. Con p_cliente se liga a un cliente que ya está en el CRM.
-- ---------------------------------------------------------------------------
create or replace function aceptar_importacion_whatsapp(p_id uuid, p_cliente uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_fila importacion_whatsapp%rowtype;
  v_cliente uuid;
  v_contacto uuid;
  v_nombre text;
  v_conv uuid;
  v_n int;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;

  v_fila := (select i from importacion_whatsapp i where i.id = p_id);
  if v_fila.id is null then
    raise exception 'Esa fila no existe.' using errcode = 'P0002';
  end if;
  if v_fila.estado = 'aceptada' then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'cliente_id', v_fila.cliente_id);
  end if;
  if v_fila.telefono_norm is null then
    raise exception 'El teléfono no trae 10 dígitos: %', v_fila.telefono using errcode = '22023';
  end if;

  v_nombre := coalesce(nullif(trim(v_fila.nombre), ''), nullif(trim(v_fila.empresa), ''), 'Cliente de WhatsApp');

  if p_cliente is not null then
    if not exists (select 1 from clientes where id = p_cliente) then
      raise exception 'Ese cliente no existe.' using errcode = 'P0002';
    end if;
    v_cliente := p_cliente;
  else
    v_cliente := gen_random_uuid();
    insert into clientes (id, nombre, nombre_comercial, telefono, municipio, origen, notas)
    values (v_cliente,
            coalesce(nullif(trim(v_fila.empresa), ''), v_nombre),
            nullif(trim(v_fila.empresa), ''),
            v_fila.telefono_norm,
            nullif(trim(v_fila.ciudad), ''),
            'whatsapp_historial',
            nullif(trim(concat_ws(' · ', nullif(v_fila.equipo, ''), nullif(v_fila.ultimo_servicio, ''))), ''));
  end if;

  -- El contacto: si ese número ya es de ese cliente, se reutiliza.
  v_contacto := (select c.id from contactos c
                  where c.cliente_id = v_cliente and c.telefono_norm = v_fila.telefono_norm
                  limit 1);
  if v_contacto is null then
    v_contacto := gen_random_uuid();
    insert into contactos (id, cliente_id, nombre, telefono, verificado, activo,
                           de_toda_la_empresa, puede_pedir_citas, recibe_ordenes, recibe_cotizaciones, notas)
    values (v_contacto, v_cliente, v_nombre, v_fila.telefono_norm, true, true,
            true, true, true, true, 'Importado del historial de WhatsApp');
  else
    update contactos set activo = true, verificado = true, updated_at = now() where id = v_contacto;
  end if;

  -- Si ese número ya escribió, se liga su conversación (solo si no hay ambigüedad).
  v_n := (select count(*) from contactos c where c.activo and c.telefono_norm = v_fila.telefono_norm);
  v_conv := (select v.id from conversaciones v
              where v.telefono_norm = v_fila.telefono_norm and v.contacto_id is null);
  if v_conv is not null and v_n = 1 then
    update conversaciones set contacto_id = v_contacto, cliente_id = v_cliente where id = v_conv;
  end if;

  update importacion_whatsapp
     set estado = 'aceptada', cliente_id = v_cliente, contacto_id = v_contacto,
         revisado_por = coalesce(auth.jwt() ->> 'email', 'crm'), revisado_en = now()
   where id = p_id;

  perform _apunta('importacion_whatsapp', p_id, 'aceptada', null,
    jsonb_build_object('cliente', v_cliente, 'contacto', v_contacto, 'conversacion_ligada', v_conv is not null and v_n = 1),
    'oficina');

  return jsonb_build_object('ok', true, 'cliente_id', v_cliente, 'contacto_id', v_contacto,
                            'conversacion_ligada', v_conv is not null and v_n = 1);
end $$;

create or replace function descartar_importacion_whatsapp(p_id uuid, p_motivo text)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if nullif(trim(coalesce(p_motivo, '')), '') is null then
    raise exception 'Escribe por qué se descarta.' using errcode = '22023';
  end if;
  update importacion_whatsapp
     set estado = 'descartada', motivo = trim(p_motivo),
         revisado_por = coalesce(auth.jwt() ->> 'email', 'crm'), revisado_en = now()
   where id = p_id and estado = 'por_revisar';
  if not found then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- wa_contexto (de la 27) con dos datos más: pendiente y razón social.
-- Misma lógica y mismos candados; reescrita con asignación en lugar de `select ... into`.
-- ---------------------------------------------------------------------------
create or replace function wa_contexto(p_conversacion uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_cliente uuid;
  v_contacto text;
  v_nombre_cliente text;
  v_equipos jsonb;
  v_n int;
  v_cita jsonb;
  v_hist jsonb;
  v_razon text;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el conector de WhatsApp o el administrador.' using errcode = '42501';
  end if;

  v_cliente := _cliente_de_conversacion(p_conversacion);
  if v_cliente is null then
    -- Número sin identificar: no se le da un solo dato de nadie.
    return jsonb_build_object('conocido', false);
  end if;

  v_contacto := (select c.nombre from conversaciones v join contactos c on c.id = v.contacto_id
                  where v.id = p_conversacion);
  v_nombre_cliente := (select nombre from clientes where id = v_cliente);
  v_n := (select count(*) from equipos
           where cliente_id = v_cliente and coalesce(estado, 'activo') = 'activo');

  v_equipos := (
    select coalesce(jsonb_agg(x order by x ->> 'descripcion'), '[]'::jsonb)
    from (
      select jsonb_strip_nulls(jsonb_build_object(
        'equipo_id', e.id,
        'descripcion', concat_ws(' ', nullif(e.marca, ''), nullif(e.modelo, ''),
                                 case when e.capacidad_kw is not null then e.capacidad_kw || ' kW' end),
        'tipo', e.tipo,
        'en_poliza', e.en_poliza,
        'ubicacion', nullif(e.ubicacion_equipo, ''),
        'proximo_mantenimiento', e.proximo_mantenimiento,
        'ultima_visita', (select max(o.fecha) from ordenes_servicio o
                           where o.equipo_id = e.id and o.estado = 'cerrada'),
        'numero_serie', case when v_n = 1 then e.numero_serie end
      )) as x
      from equipos e
      where e.cliente_id = v_cliente and coalesce(e.estado, 'activo') = 'activo'
    ) z);

  v_cita := (
    select jsonb_strip_nulls(jsonb_build_object(
             'fecha', c.fecha, 'hora', c.hora, 'estado', c.estado, 'tipo', c.tipo_servicio))
      from citas c
     where c.cliente_id = v_cliente and c.estado in ('programada', 'por_programar')
     order by c.fecha nulls last
     limit 1);

  -- Lo que se trajo del historial (lo más reciente aceptado de ese cliente).
  v_hist := (
    select jsonb_strip_nulls(jsonb_build_object(
             'equipo', nullif(i.equipo, ''),
             'ultimo_servicio', nullif(i.ultimo_servicio, ''),
             'pendiente', nullif(i.pendiente, ''),
             'importado_el', i.revisado_en::date))
      from importacion_whatsapp i
     where i.cliente_id = v_cliente and i.estado = 'aceptada'
     order by i.revisado_en desc
     limit 1);

  -- Razón social: la de datos_fiscales manda; si no hay, la del historial.
  v_razon := coalesce(
    (select d.razon_social from datos_fiscales d where d.cliente_id = v_cliente limit 1),
    (select nullif(i.razon_social, '') from importacion_whatsapp i
      where i.cliente_id = v_cliente and i.estado = 'aceptada'
      order by i.revisado_en desc limit 1));

  return jsonb_strip_nulls(jsonb_build_object(
    'conocido', true,
    'contacto', v_contacto,
    'cliente', v_nombre_cliente,
    'equipos', v_equipos,
    'proxima_cita', v_cita,
    'historial', v_hist,
    'razon_social', v_razon));
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'aceptar_importacion_whatsapp(uuid, uuid)',
    'descartar_importacion_whatsapp(uuid, text)',
    'wa_contexto(uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

notify pgrst, 'reload schema';

-- Registro (ver 68).
insert into _migraciones (archivo, tipo) values ('55_importar_clientes_whatsapp.sql', 'esquema')
on conflict (archivo) do nothing;

select 'rls importacion_whatsapp' as que, relrowsecurity::text as ok
  from pg_class where relname = 'importacion_whatsapp';
