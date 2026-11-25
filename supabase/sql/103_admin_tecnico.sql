-- 103 · El administrador también puede ser técnico de campo (22/11/2026)
--
-- Pedido de Caña: agregarse como técnico a las citas. Las citas solo aceptaban perfiles con
-- rol 'tecnico' y su cuenta es 'admin'. En vez de darle dos cuentas, un admin marca
-- perfiles.hace_campo y desde entonces sale en la lista de técnicos, se puede poner como
-- responsable o ayudante, y en "Órdenes" escribe su parte y cierra como cualquier técnico
-- (cerrar_orden, orden_partes y el material ya miran tecnico_id = auth.uid(), no el rol).
--
-- Lo que NO cambia: el pago a técnicos no le propone pagos al admin (es el dueño).
-- agendar_cita, programar_cita y por_pagar_tecnicos se redefinen COMPLETAS desde la versión
-- viva (generadas con un script; solo cambian los renglones marcados "(103)").

alter table perfiles add column if not exists hace_campo boolean not null default false;
comment on column perfiles.hace_campo is
  'Solo para admin: también trabaja en campo y puede ser T1/T2 de una cita (103).';

create or replace function _tecnico_de_campo(p_id uuid)
returns boolean language sql stable security definer set search_path = public as $f$
  select exists (select 1 from perfiles
                  where id = p_id and activo
                    and (rol = 'tecnico' or (rol = 'admin' and hace_campo)))
$f$;
revoke all on function _tecnico_de_campo(uuid) from public, anon;
grant execute on function _tecnico_de_campo(uuid) to authenticated;

create or replace function public.lista_tecnicos()
 returns table(id uuid, nombre text)
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select p.id, coalesce(p.nombre, p.email)
  from perfiles p
  where (p.rol = 'tecnico' or (p.rol = 'admin' and p.hace_campo))   -- (103)
    and p.activo and mi_rol() in ('admin', 'tecnico')
  order by 2
$function$;

CREATE OR REPLACE FUNCTION public.agendar_cita(p_cliente uuid, p_equipo uuid, p_tipo text, p_fecha date, p_hora time without time zone, p_duracion integer, p_t1 uuid, p_t2 uuid, p_zona text, p_notas text, p_cotizacion uuid DEFAULT NULL::uuid, p_nueva_cotizacion jsonb DEFAULT NULL::jsonb, p_confirmar boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  hoy date := (now() at time zone 'America/Mexico_City')::date;   -- el servidor está en UTC
  quien text := coalesce(auth.jwt() ->> 'email', 'crm');
  v_empalmes jsonb;
  v_poliza boolean := false;
  v_origen text;
  v_cita citas%rowtype;
  v_cot_id uuid := p_cotizacion;
  v_cot_folio int;
  v_orden uuid;
  v_orden_folio int;
begin
  if not es_admin() then
    raise exception 'Solo el administrador puede agendar citas.' using errcode = '42501';
  end if;
  if p_cliente is null then raise exception 'Falta el cliente.' using errcode = '22023'; end if;
  if p_fecha is null then raise exception 'Falta la fecha.' using errcode = '22023'; end if;
  if p_tipo not in ('preventivo', 'correctivo', 'instalacion', 'diagnostico', 'visita_tecnica') then
    raise exception 'Tipo de servicio no válido: %', p_tipo using errcode = '22023';
  end if;
  if p_t2 is not null and p_t1 is null then
    raise exception 'Elige al técnico responsable antes que a su ayudante.' using errcode = '22023';
  end if;
  if p_t1 is not null and p_t1 = p_t2 then
    raise exception 'El responsable y su ayudante no pueden ser la misma persona.' using errcode = '22023';
  end if;
  if p_t1 is not null and not _tecnico_de_campo(p_t1) /* (103) */ then
    raise exception 'El técnico responsable no es un técnico activo.' using errcode = '22023';
  end if;
  if p_t2 is not null and not _tecnico_de_campo(p_t2) /* (103) */ then
    raise exception 'El ayudante no es un técnico activo.' using errcode = '22023';
  end if;
  if p_equipo is not null and not exists (select 1 from equipos where id = p_equipo and cliente_id = p_cliente) then
    raise exception 'Ese equipo no es del cliente elegido.' using errcode = '22023';
  end if;
  if p_cotizacion is not null and not exists (select 1 from cotizaciones where id = p_cotizacion and cliente_id = p_cliente) then
    raise exception 'Esa cotización no es del cliente elegido.' using errcode = '22023';
  end if;

  v_empalmes := empalmes_de(p_fecha, p_hora, p_duracion, p_t1, p_t2, null);
  if jsonb_array_length(v_empalmes) > 0 and not p_confirmar then
    return jsonb_build_object('ok', false, 'motivo', 'empalme', 'empalmes', v_empalmes);
  end if;

  -- Póliza: mantenimiento preventivo de un equipo en póliza. Solo cita y orden.
  if p_tipo = 'preventivo' and p_equipo is not null then
    select coalesce(en_poliza, false) into v_poliza from equipos where id = p_equipo;
  end if;
  v_origen := case when v_poliza then 'poliza' else 'agenda' end;

  -- Diagnóstico: cotización de diagnóstico, nueva o enlazada.
  if p_tipo = 'diagnostico' and v_cot_id is null then
    insert into cotizaciones
      (cliente_id, equipo_id, fecha, tipo, partidas, subtotal, descuento, iva, total,
       requiere_visita, condiciones, notas_internas, estado, creada_por,
       prog_fecha, prog_hora, prog_duracion_min, prog_tecnico_id, prog_tecnico2_id)
    values
      (p_cliente, p_equipo, hoy, 'diagnostico',
       coalesce(p_nueva_cotizacion -> 'partidas', '[]'::jsonb),
       coalesce((p_nueva_cotizacion ->> 'subtotal')::numeric, 0), 0,
       coalesce((p_nueva_cotizacion ->> 'iva')::numeric, 0),
       coalesce((p_nueva_cotizacion ->> 'total')::numeric, 0),
       true, p_nueva_cotizacion ->> 'condiciones',
       'Creada desde una cita de diagnóstico del ' || p_fecha,
       'borrador', quien,
       p_fecha, p_hora, p_duracion, p_t1, p_t2)
    returning id, folio into v_cot_id, v_cot_folio;
  elsif v_cot_id is not null then
    select folio into v_cot_folio from cotizaciones where id = v_cot_id;
  end if;

  insert into citas
    (cliente_id, equipo_id, tipo_servicio, fecha, hora, duracion_min,
     tecnico_id, tecnico2_id, tecnico, zona, notas, estado, origen, cotizacion_id)
  values
    (p_cliente, p_equipo, p_tipo, p_fecha, p_hora, p_duracion,
     p_t1, p_t2, (select nombre from perfiles where id = p_t1),
     coalesce(nullif(p_zona, ''), (select zona from clientes where id = p_cliente)),
     nullif(p_notas, ''), 'programada', v_origen, v_cot_id)
  returning * into v_cita;

  insert into ordenes_servicio
    (cliente_id, equipo_id, cita_id, fecha, tipo_servicio, tecnico_id, tecnico2_id, tecnico, estado)
  values
    (v_cita.cliente_id, v_cita.equipo_id, v_cita.id, v_cita.fecha, v_cita.tipo_servicio,
     v_cita.tecnico_id, v_cita.tecnico2_id, v_cita.tecnico, 'abierta')
  returning id, folio into v_orden, v_orden_folio;

  return jsonb_build_object(
    'ok', true,
    'cita_id', v_cita.id,
    'origen', v_origen,
    'orden_id', v_orden,
    'orden_folio', v_orden_folio,
    'cotizacion_id', v_cot_id,
    'cotizacion_folio', v_cot_folio,
    'cotizacion_nueva', (p_tipo = 'diagnostico' and p_cotizacion is null),
    'empalmes', v_empalmes
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.programar_cita(p_cita uuid, p_fecha date, p_hora time without time zone, p_duracion integer, p_t1 uuid, p_t2 uuid, p_confirmar boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  ci citas%rowtype;
  v_orden ordenes_servicio%rowtype;
  v_hay_orden boolean;
  v_con_trabajo boolean := false;
  v_cambia boolean;
  v_empalmes jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador puede programar citas.' using errcode = '42501';
  end if;

  select * into ci from citas where id = p_cita for update;
  if not found then raise exception 'La cita no existe.' using errcode = 'P0002'; end if;
  if ci.estado in ('realizada', 'cancelada') then
    raise exception 'La cita ya está %: no se puede programar.', ci.estado using errcode = '22023';
  end if;
  if p_fecha is null then raise exception 'Falta la fecha.' using errcode = '22023'; end if;
  if p_t2 is not null and p_t1 is null then
    raise exception 'Elige al técnico responsable antes que a su ayudante.' using errcode = '22023';
  end if;
  if p_t1 is not null and p_t1 = p_t2 then
    raise exception 'El responsable y su ayudante no pueden ser la misma persona.' using errcode = '22023';
  end if;
  if p_t1 is not null and not _tecnico_de_campo(p_t1) /* (103) */ then
    raise exception 'El técnico responsable no es un técnico activo.' using errcode = '22023';
  end if;
  if p_t2 is not null and not _tecnico_de_campo(p_t2) /* (103) */ then
    raise exception 'El ayudante no es un técnico activo.' using errcode = '22023';
  end if;

  v_empalmes := empalmes_de(p_fecha, p_hora, p_duracion, p_t1, p_t2, ci.id);

  select * into v_orden from ordenes_servicio where cita_id = ci.id;
  v_hay_orden := found;
  if v_hay_orden then
    v_con_trabajo := coalesce(v_orden.trabajos_realizados, '') <> ''
      or exists (select 1 from orden_partes where orden_id = v_orden.id);
  end if;
  v_cambia := (p_t1 is distinct from ci.tecnico_id) or (p_t2 is distinct from ci.tecnico2_id);

  -- Cambiar de técnico una orden que ya tiene trabajo capturado deja a quien la llenó
  -- sin acceso: se pide confirmar.
  if not p_confirmar and (jsonb_array_length(v_empalmes) > 0 or (v_con_trabajo and v_cambia and ci.tecnico_id is not null)) then
    return jsonb_build_object('ok', false,
      'motivo', case when jsonb_array_length(v_empalmes) > 0 then 'empalme' else 'trabajo' end,
      'empalmes', v_empalmes,
      'orden_con_trabajo', v_con_trabajo and v_cambia and ci.tecnico_id is not null);
  end if;

  update citas
     set fecha = p_fecha, hora = p_hora,
         duracion_min = coalesce(p_duracion, duracion_min),
         tecnico_id = p_t1, tecnico2_id = p_t2,
         tecnico = (select nombre from perfiles where id = p_t1),
         estado = 'programada'
   where id = ci.id;

  -- La orden abierta sigue a la cita.
  update ordenes_servicio
     set fecha = p_fecha, tecnico_id = p_t1, tecnico2_id = p_t2,
         tecnico = (select nombre from perfiles where id = p_t1)
   where cita_id = ci.id and estado = 'abierta';

  return jsonb_build_object('ok', true, 'cita_id', ci.id, 'anterior', ci.estado,
                            'empalmes', v_empalmes, 'orden_folio', v_orden.folio);
end;
$function$;

CREATE OR REPLACE FUNCTION public.por_pagar_tecnicos(p_hasta date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_res jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador ve los pagos a técnicos.' using errcode = '42501';
  end if;

  v_res := (
    with servicios as (
      select o.id as orden_id, o.fecha, o.tipo_servicio, o.tecnico_id as persona, 'responsable'::text as rol
        from ordenes_servicio o where o.estado = 'cerrada' and o.tecnico_id is not null
                                  and o.fecha <= p_hasta and o.fecha >= _pagar_desde()
      union all
      select o.id, o.fecha, o.tipo_servicio, o.tecnico2_id, 'ayudante'
        from ordenes_servicio o where o.estado = 'cerrada' and o.tecnico2_id is not null
                                  and o.fecha <= p_hasta and o.fecha >= _pagar_desde()
    ), pendientes as (
      select s.*, _tarifa_pago_tecnico(s.persona, s.tipo_servicio, s.rol, s.fecha) as tarifa
        from servicios s
       where (select rol from perfiles where id = s.persona) is distinct from 'admin'   -- (103) el dueño no se paga a sí mismo
         and not exists (select 1 from pagos_tecnico_lineas l
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
$function$;

insert into _migraciones (archivo, tipo) values ('103_admin_tecnico.sql', 'esquema') on conflict (archivo) do nothing;
