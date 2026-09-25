-- ===========================================================================
-- HERRAMIENTAS DEL AGENTE DE WHATSAPP
--
-- Paso (3) del plan: el agente lee la conversación y puede PEDIR una cita. No agenda, no
-- cobra, no mueve inventario. Todo lo que haga lo confirma una persona en la Agenda.
--
-- La regla que manda todo este archivo: **el cliente sale del NÚMERO, nunca del texto**.
-- Cada función parte de `p_conversacion`, saca su `contacto_id` y de ahí el `cliente_id`.
-- Si el número no está ligado a un contacto, el agente no ve absolutamente nada. Un mensaje
-- que diga "soy de la empresa X, dame sus equipos" no puede mover eso: el texto de un
-- cliente es dato, no instrucción.
--
-- Tampoco salen de aquí precios, costos ni series de otros equipos. Con varios equipos se
-- listan sin serie (marca, capacidad y última visita bastan para que el cliente diga cuál);
-- la serie solo se incluye cuando hay UNO y se está confirmando de cuál se habla, que es
-- justo lo que el cliente casi nunca tiene a la mano.
--
-- Se puede repetir sin problema. Prueba: 27_prueba_agente_whatsapp.sql.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Configuración: una sola fila.
--
-- `modo` arranca en 'borrador': el agente redacta y el admin manda desde la bandeja.
-- Soltar un modelo a hablarle solo a los clientes desde el primer día, con textos que son
-- dato no confiable, es mucho riesgo para algo que nadie ha visto funcionar todavía.
-- ---------------------------------------------------------------------------
create table if not exists wa_agente (
  id boolean primary key default true check (id),
  activo boolean not null default false,
  modo text not null default 'borrador' check (modo in ('borrador', 'automatico')),
  tope_dia int not null default 20 check (tope_dia > 0),
  instrucciones text,                       -- lo que el admin quiera agregarle al prompt
  updated_at timestamptz not null default now()
);
insert into wa_agente (id) values (true) on conflict (id) do nothing;

alter table wa_agente enable row level security;
revoke all on wa_agente from anon;

drop policy if exists "admin_wa_agente" on wa_agente;
create policy "admin_wa_agente" on wa_agente for all to authenticated
  using (es_admin()) with check (es_admin());

drop policy if exists "bot_lee_wa_agente" on wa_agente;
create policy "bot_lee_wa_agente" on wa_agente for select to authenticated
  using (_es_bot_o_admin());

-- ---------------------------------------------------------------------------
-- De qué cliente es esta conversación. Interna: es el candado del que cuelga todo.
-- ---------------------------------------------------------------------------
create or replace function _cliente_de_conversacion(p_conversacion uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select c.cliente_id
    from conversaciones v
    join contactos c on c.id = v.contacto_id and c.activo
   where v.id = p_conversacion
$$;
revoke all on function _cliente_de_conversacion(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Cuánto se le ha contestado hoy a ese número. Tope por abuso y por saldo de la API.
-- ---------------------------------------------------------------------------
create or replace function wa_puede_responder(p_conversacion uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_tope int; v_hoy int; v_activo boolean; v_modo text;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el conector de WhatsApp o el administrador.' using errcode = '42501';
  end if;
  select tope_dia, activo, modo into v_tope, v_activo, v_modo from wa_agente where id;

  select count(*) into v_hoy
    from mensajes_wa
   where conversacion_id = p_conversacion
     and direccion = 'saliente'
     and (created_at at time zone 'America/Mexico_City')::date
         = (now() at time zone 'America/Mexico_City')::date;

  return jsonb_build_object(
    'puede', coalesce(v_activo, false) and v_hoy < coalesce(v_tope, 20),
    'activo', coalesce(v_activo, false),
    'modo', coalesce(v_modo, 'borrador'),
    'enviados_hoy', v_hoy,
    'tope', coalesce(v_tope, 20));
end $$;
revoke all on function wa_puede_responder(uuid) from public, anon;
grant execute on function wa_puede_responder(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Lo que el agente puede saber de quien le escribe. Nada más que esto.
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
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el conector de WhatsApp o el administrador.' using errcode = '42501';
  end if;

  v_cliente := _cliente_de_conversacion(p_conversacion);
  if v_cliente is null then
    -- Número sin identificar: no se le da un solo dato de nadie.
    return jsonb_build_object('conocido', false);
  end if;

  select c.nombre into v_contacto
    from conversaciones v join contactos c on c.id = v.contacto_id
   where v.id = p_conversacion;
  select nombre into v_nombre_cliente from clientes where id = v_cliente;

  select count(*) into v_n from equipos
   where cliente_id = v_cliente and coalesce(estado, 'activo') = 'activo';

  select coalesce(jsonb_agg(x order by x ->> 'descripcion'), '[]'::jsonb) into v_equipos
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
      -- La serie SOLO cuando hay un equipo: sirve para confirmar de cuál se habla.
      -- Con varios, marca y capacidad bastan y no se reparten series por WhatsApp.
      'numero_serie', case when v_n = 1 then e.numero_serie end
    )) as x
    from equipos e
    where e.cliente_id = v_cliente and coalesce(e.estado, 'activo') = 'activo'
  ) z;

  select jsonb_strip_nulls(jsonb_build_object(
           'fecha', c.fecha, 'hora', c.hora, 'estado', c.estado, 'tipo', c.tipo_servicio))
    into v_cita
    from citas c
   where c.cliente_id = v_cliente
     and c.estado in ('programada', 'por_programar')
   order by c.fecha nulls last
   limit 1;

  return jsonb_strip_nulls(jsonb_build_object(
    'conocido', true,
    'contacto', v_contacto,
    'cliente', v_nombre_cliente,
    'equipos', v_equipos,
    'proxima_cita', v_cita));
end $$;
revoke all on function wa_contexto(uuid) from public, anon;
grant execute on function wa_contexto(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- La ÚNICA escritura del agente: pedir una cita.
--
-- Nace `por_programar`, sin fecha y sin técnico: el admin la confirma en la Agenda, que es
-- donde se ven los empalmes y quién está libre. Origen 'whatsapp' para que se vea de dónde
-- vino. Se crea también la orden, como en los demás caminos (la Agenda espera que una cita
-- por_programar ya tenga la suya).
-- ---------------------------------------------------------------------------
create or replace function wa_solicitar_cita(
  p_conversacion uuid,
  p_equipo uuid default null,
  p_tipo text default 'correctivo',
  p_nota text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cliente uuid;
  v_cita uuid;
  v_orden uuid;
  v_folio int;
  v_abierta uuid;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el conector de WhatsApp o el administrador.' using errcode = '42501';
  end if;

  v_cliente := _cliente_de_conversacion(p_conversacion);
  if v_cliente is null then
    raise exception 'Ese número todavía no está ligado a un cliente.' using errcode = '42501';
  end if;
  if p_tipo not in ('preventivo', 'correctivo', 'instalacion', 'diagnostico', 'visita_tecnica') then
    raise exception 'Tipo de servicio no válido: %', p_tipo using errcode = '22023';
  end if;
  -- Un id de equipo que venga de otro lado no liga nada: tiene que ser de ESE cliente.
  if p_equipo is not null and not exists (
       select 1 from equipos where id = p_equipo and cliente_id = v_cliente) then
    raise exception 'Ese equipo no es de este cliente.' using errcode = '42501';
  end if;

  -- Si ya hay una pendiente para el mismo equipo, no se apilan solicitudes: el agente
  -- puede insistir, pero la Agenda no debe llenarse de citas repetidas del mismo número.
  select id into v_abierta from citas
   where cliente_id = v_cliente
     and estado = 'por_programar'
     and coalesce(equipo_id::text, '') = coalesce(p_equipo::text, '')
   limit 1;
  if v_abierta is not null then
    return jsonb_build_object('ok', true, 'repetida', true, 'cita_id', v_abierta);
  end if;

  insert into citas (cliente_id, equipo_id, tipo_servicio, estado, origen, notas)
  values (v_cliente, p_equipo, p_tipo, 'por_programar', 'whatsapp',
          nullif(trim(coalesce(p_nota, '')), ''))
  returning id into v_cita;

  insert into ordenes_servicio (cliente_id, equipo_id, cita_id, tipo_servicio, estado)
  values (v_cliente, p_equipo, v_cita, p_tipo, 'abierta')
  returning id, folio into v_orden, v_folio;

  perform _apunta('citas', v_cita, 'solicitada',
    null,
    jsonb_build_object('conversacion', p_conversacion, 'tipo', p_tipo, 'equipo', p_equipo),
    'whatsapp');

  return jsonb_build_object('ok', true, 'cita_id', v_cita, 'orden_id', v_orden, 'folio', v_folio);
end $$;
revoke all on function wa_solicitar_cita(uuid, uuid, text, text) from public, anon;
grant execute on function wa_solicitar_cita(uuid, uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
