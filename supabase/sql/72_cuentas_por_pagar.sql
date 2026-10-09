-- ============================================================================
-- 72 · Cuentas por pagar (F4)
--
-- Requiere el 67 y el 71. Una factura RECIBIDA que se aprueba como "Aún no la pago" queda POR PAGAR,
-- con su categoría y su vencimiento. Se paga en uno o varios pagos (PPD): cada pago es un egreso en el
-- libro con su CFDI y el IVA en proporción a lo pagado (el IVA se acredita cuando se paga).
-- El saldo NO se guarda: es el total menos lo pagado (lo mismo que el inventario, se calcula).
--
-- aprobar_documento, inicio_admin y pendientes_admin se redefinen COMPLETAS desde su definición viva
-- del 09/10/2026, con solo los renglones marcados "(72)" de más.
-- ============================================================================

alter table cfdi add column if not exists por_pagar boolean not null default false;
alter table cfdi add column if not exists categoria text;
alter table cfdi add column if not exists vence date;
create index if not exists idx_cfdi_por_pagar on cfdi (vence) where por_pagar;

-- Lo que falta pagar de una factura: total menos los egresos que la citan. Interna.
create or replace function _saldo_cfdi(p_cfdi uuid) returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select round(c.total - coalesce((select sum(m.monto) from expediente_movimientos m
                                    where m.cfdi_id = c.id and m.tipo = 'egreso'), 0), 2)
    from cfdi c where c.id = p_cfdi;
$$;
revoke execute on function _saldo_cfdi(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- cuentas_por_pagar: lo pendiente, lo vencido y cada factura con su saldo.
-- ---------------------------------------------------------------------------
create or replace function cuentas_por_pagar() returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_res jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador ve las cuentas por pagar.' using errcode = '42501';
  end if;
  v_res := (
    with abiertas as (
      select c.*, _saldo_cfdi(c.id) as saldo,
             round(c.total - _saldo_cfdi(c.id), 2) as pagado
        from cfdi c
       where c.por_pagar and c.sentido = 'recibido' and _saldo_cfdi(c.id) > 0.01
    )
    select jsonb_build_object(
      'total', coalesce(sum(saldo), 0),
      'vencido', coalesce(sum(saldo) filter (where vence < current_date), 0),
      'cuentas', coalesce(jsonb_agg(jsonb_build_object(
        'cfdi_id', id, 'proveedor', coalesce(nombre_emisor, rfc_emisor), 'rfc', rfc_emisor,
        'serie', serie, 'folio', folio, 'fecha', (fecha at time zone 'America/Merida')::date,
        'vence', vence, 'dias', vence - current_date, 'total', total, 'pagado', pagado,
        'saldo', saldo, 'iva', iva_trasladado, 'categoria', categoria, 'metodo_pago', metodo_pago,
        'documento_id', documento_id, 'archivo', archivo_xml)
        order by vence nulls last, fecha), '[]'::jsonb))
      from abiertas);
  return v_res;
end;
$$;
revoke execute on function cuentas_por_pagar() from public, anon;
grant execute on function cuentas_por_pagar() to authenticated;

-- ---------------------------------------------------------------------------
-- pagar_cfdi: registra un pago (total o parcial). El IVA del pago es proporcional al monto.
-- ---------------------------------------------------------------------------
create or replace function pagar_cfdi(
  p_cfdi uuid, p_monto numeric, p_fecha date default null, p_cuenta uuid default null,
  p_forma text default null, p_referencia text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_c cfdi%rowtype;
  v_saldo numeric;
  v_iva numeric;
  v_mov uuid;
begin
  if not es_admin() then
    raise exception 'Solo el administrador registra pagos a proveedores.' using errcode = '42501';
  end if;
  v_c := (select c from cfdi c where c.id = p_cfdi);
  if v_c.id is null then raise exception 'Esa factura no existe.' using errcode = '22023'; end if;
  if v_c.sentido <> 'recibido' or not v_c.por_pagar then
    raise exception 'Esa factura no está por pagar.' using errcode = '22023';
  end if;
  if p_monto is null or p_monto <= 0 then
    raise exception 'El pago debe ser mayor a cero.' using errcode = '22023';
  end if;
  if p_cuenta is not null and (select id from cuentas_financieras where id = p_cuenta) is null then
    raise exception 'Esa cuenta no existe.' using errcode = '22023';
  end if;
  v_saldo := _saldo_cfdi(p_cfdi);
  if p_monto > v_saldo + 0.01 then
    raise exception 'El pago (%) es mayor que lo que falta por pagar (%).', p_monto, v_saldo using errcode = '22023';
  end if;
  v_iva := case when v_c.total > 0 then round(v_c.iva_trasladado * p_monto / v_c.total, 2) else 0 end;

  v_mov := gen_random_uuid();
  insert into expediente_movimientos
    (id, cotizacion_id, tipo, categoria, fecha, concepto, monto, iva, forma, referencia,
     cuenta_id, cfdi_id, documento_id, archivo, notas, creado_por)
  values
    (v_mov, null, 'egreso', coalesce(v_c.categoria, 'otro'), coalesce(p_fecha, current_date),
     coalesce(v_c.nombre_emisor, v_c.rfc_emisor), p_monto, least(v_iva, p_monto), nullif(p_forma, ''),
     coalesce(nullif(trim(p_referencia), ''), v_c.uuid_fiscal), p_cuenta, v_c.id, v_c.documento_id,
     v_c.archivo_xml, case when p_monto < v_saldo - 0.01 then 'Pago parcial' end,
     coalesce(auth.jwt() ->> 'email', 'crm'));

  perform _apunta('cfdi', p_cfdi, 'pagar_cfdi', jsonb_build_object('saldo', v_saldo),
                  jsonb_build_object('pago', p_monto, 'iva', v_iva, 'saldo', v_saldo - p_monto), 'oficina');
  return jsonb_build_object('ok', true, 'movimiento_id', v_mov, 'saldo', round(v_saldo - p_monto, 2));
end;
$$;
revoke execute on function pagar_cfdi(uuid, numeric, date, uuid, text, text) from public, anon;
grant execute on function pagar_cfdi(uuid, numeric, date, uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- programar_pago_cfdi: deja una factura recibida por pagar (o cambia su vencimiento o categoría).
-- Sirve también para una que se archivó y resulta que no estaba pagada.
-- ---------------------------------------------------------------------------
create or replace function programar_pago_cfdi(p_cfdi uuid, p_vence date, p_categoria text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_c cfdi%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador programa pagos.' using errcode = '42501';
  end if;
  v_c := (select c from cfdi c where c.id = p_cfdi);
  if v_c.id is null then raise exception 'Esa factura no existe.' using errcode = '22023'; end if;
  if v_c.sentido <> 'recibido' or v_c.tipo_comprobante <> 'I' then
    raise exception 'Solo una factura recibida se puede programar para pago.' using errcode = '22023';
  end if;
  if p_vence is null then raise exception 'Escribe la fecha de vencimiento.' using errcode = '22023'; end if;
  if p_categoria is not null and p_categoria in ('cobro', 'aportacion', 'otro_ingreso') then
    raise exception 'Elige el tipo de gasto.' using errcode = '22023';
  end if;
  update cfdi
     set por_pagar = true, vence = p_vence, categoria = coalesce(p_categoria, categoria, 'otro')
   where id = p_cfdi;
  perform _apunta('cfdi', p_cfdi, 'programar_pago_cfdi',
                  jsonb_build_object('vence', v_c.vence, 'categoria', v_c.categoria),
                  jsonb_build_object('vence', p_vence, 'categoria', p_categoria), 'oficina');
  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function programar_pago_cfdi(uuid, date, text) from public, anon;
grant execute on function programar_pago_cfdi(uuid, date, text) to authenticated;

CREATE OR REPLACE FUNCTION public.aprobar_documento(p_documento uuid, p_datos jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_d documentos%rowtype;
  v_cfdi cfdi%rowtype;
  v_accion text;
  v_cat text;
  v_monto numeric;
  v_iva numeric;
  v_fecha date;
  v_pagado boolean;
  v_mov uuid;
  v_cuenta uuid;
  v_cot uuid;
  v_correccion jsonb := '{}'::jsonb;
  v_prop jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador aprueba documentos.' using errcode = '42501';
  end if;
  v_d := (select d from documentos d where d.id = p_documento);
  if v_d.id is null then raise exception 'Ese documento no existe.' using errcode = '22023'; end if;
  if v_d.estado = 'aprobado' then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'movimiento_id', v_d.movimiento_id);
  end if;
  if v_d.estado = 'rechazado' then
    raise exception 'Ese documento fue rechazado; súbelo de nuevo si fue un error.' using errcode = '22023';
  end if;

  v_accion := coalesce(p_datos ->> 'accion', 'gasto');
  if v_accion not in ('gasto', 'archivar') then
    raise exception 'Acción no válida.' using errcode = '22023';
  end if;
  v_cfdi := (select c from cfdi c where c.id = v_d.cfdi_id);
  v_prop := coalesce(v_d.propuesta, '{}'::jsonb);

  if v_accion = 'gasto' then
    v_cat := coalesce(p_datos ->> 'categoria', '');
    if v_cat = '' or v_cat in ('cobro', 'aportacion', 'otro_ingreso') then
      raise exception 'Elige el tipo de gasto.' using errcode = '22023';
    end if;
    v_monto := coalesce((p_datos ->> 'monto')::numeric, v_cfdi.total);
    v_iva := coalesce((p_datos ->> 'iva')::numeric, v_cfdi.iva_trasladado, 0);
    v_fecha := coalesce((p_datos ->> 'fecha')::date, current_date);
    v_pagado := coalesce((p_datos ->> 'pagado')::boolean, true);
    v_cuenta := nullif(p_datos ->> 'cuenta_id', '')::uuid;
    v_cot := nullif(p_datos ->> 'cotizacion_id', '')::uuid;

    if v_pagado then
      if v_monto is null or v_monto <= 0 then
        raise exception 'El monto del gasto debe ser mayor a cero.' using errcode = '22023';
      end if;
      if v_cfdi.id is not null and exists (select 1 from expediente_movimientos where cfdi_id = v_cfdi.id) then
        raise exception 'Ese CFDI ya tiene un pago registrado.' using errcode = '22023';
      end if;
      v_mov := gen_random_uuid();
      insert into expediente_movimientos
        (id, cotizacion_id, tipo, categoria, fecha, concepto, monto, iva, forma, referencia,
         cuenta_id, cfdi_id, documento_id, archivo, archivo_nombre, notas, creado_por)
      values
        (v_mov, v_cot, 'egreso', v_cat, v_fecha,
         coalesce(nullif(trim(p_datos ->> 'concepto'), ''), v_cfdi.nombre_emisor, 'Gasto'),
         v_monto, least(coalesce(v_iva, 0), v_monto), nullif(p_datos ->> 'forma', ''),
         coalesce(nullif(trim(p_datos ->> 'referencia'), ''), v_cfdi.uuid_fiscal),
         v_cuenta, v_cfdi.id, p_documento, v_d.archivo, v_d.nombre_original,
         nullif(trim(p_datos ->> 'notas'), ''), coalesce(auth.jwt() ->> 'email', 'crm'));
    elsif v_cfdi.id is not null then
      -- (72) "Aún no la pago": la factura queda POR PAGAR con su categoría y su vencimiento
      -- (por omisión, 30 días después de la fecha de la factura, en hora de Mérida).
      update cfdi
         set por_pagar = true, categoria = v_cat,
             vence = coalesce(nullif(p_datos ->> 'vence', '')::date,
                              (v_cfdi.fecha at time zone 'America/Merida')::date + 30)
       where id = v_cfdi.id;
    else
      raise exception 'Solo una factura con XML se puede dejar por pagar.' using errcode = '22023';
    end if;

    if v_prop ? 'categoria' and v_prop ->> 'categoria' is distinct from v_cat then
      v_correccion := v_correccion || jsonb_build_object('categoria', jsonb_build_array(v_prop ->> 'categoria', v_cat));
    end if;
    if v_prop ? 'monto' and (v_prop ->> 'monto')::numeric is distinct from v_monto then
      v_correccion := v_correccion || jsonb_build_object('monto', jsonb_build_array(v_prop ->> 'monto', v_monto));
    end if;

    if v_cfdi.id is not null and v_cfdi.sentido = 'recibido' then
      insert into reglas_clasificacion (rfc_emisor, nombre, categoria, cuenta_id)
      values (v_cfdi.rfc_emisor, v_cfdi.nombre_emisor, v_cat, v_cuenta)
      on conflict (rfc_emisor) do update
        set categoria = excluded.categoria,
            cuenta_id = coalesce(excluded.cuenta_id, reglas_clasificacion.cuenta_id),
            nombre = coalesce(excluded.nombre, reglas_clasificacion.nombre),
            veces = case when reglas_clasificacion.categoria = excluded.categoria then reglas_clasificacion.veces + 1 else 1 end,
            actualizada_en = now();
    end if;
  end if;

  update documentos
     set estado = 'aprobado', movimiento_id = v_mov, correccion = nullif(v_correccion, '{}'::jsonb),
         aprobado_por = coalesce(auth.jwt() ->> 'email', 'crm'), aprobado_en = now()
   where id = p_documento;
  perform _apunta('documentos', p_documento, 'aprobar_documento', null,
                  jsonb_build_object('accion', v_accion, 'categoria', v_cat, 'monto', v_monto,
                                     'pagado', v_pagado, 'corrigio', v_correccion <> '{}'::jsonb), 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false, 'movimiento_id', v_mov);
end;
$function$;

CREATE OR REPLACE FUNCTION public.pendientes_admin()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when not es_admin() then '{}'::jsonb else jsonb_strip_nulls(jsonb_build_object(

    -- La Agenda junta dos cosas porque las dos se atienden ahí: las citas sin fecha esperando
    -- confirmación (las que pide el agente de WhatsApp caen aquí) y los avisos ya redactados
    -- que nadie ha mandado. `avisos` no tiene pestaña propia: vive debajo de "Por programar".
    'agenda', nullif(
      (select count(*) from citas where estado = 'por_programar')
      + (select count(*) from avisos where estado = 'pendiente'), 0),

    -- Órdenes cerradas marcadas "enviar al cliente en cuanto se cierre" que todavía no se
    -- enviaron. La marca se apaga sola al registrar el envío (fase 4).
    'ordenes', nullif((
      select count(*) from ordenes_servicio o
       where o.estado = 'cerrada' and o.enviar_al_cerrar
         and not exists (select 1 from envios_orden e where e.orden_id = o.id)), 0),

    -- Solicitudes del formulario del sitio que nadie ha visto.
    'solicitudes', nullif((select count(*) from solicitudes_web where estado = 'nueva'), 0),

    -- Conversaciones de WhatsApp con mensajes sin leer.
    'whatsapp', nullif((
      select count(*) from conversaciones
       where sin_leer > 0 and coalesce(estado, 'abierta') <> 'cerrada'), 0),

    -- Borradores que propuso el agente y que el admin tiene que revisar antes de enviar.
    'cotizaciones', nullif((
      select count(*) from cotizaciones
       where estado = 'borrador' and origen = 'whatsapp'), 0),

    -- Lo del almacén, junto: lo que espera firma, lo que falta devolver, lo que el técnico
    -- pidió y lo que usó sin que se lo entregaran. Son cuatro pestañas de una misma pantalla,
    -- así que un solo número es lo que corresponde a la pestaña.
    'almacen', nullif((
      (select count(*) from entregas where estado = 'pendiente')
      + (select count(distinct s.orden_id) from orden_surtido s
          where s.cantidad_entregada - s.cantidad_usada
                - s.cantidad_devuelta - s.cantidad_diferencia > 0)
      + (select count(*) from solicitudes_material where estado = 'pendiente')
      + (select count(*) from ordenes_servicio o
          where exists (
            select 1 from jsonb_array_elements(coalesce(o.refacciones, '[]'::jsonb)) x
             where (x ->> 'adicional') = 'true'
               and coalesce(x ->> 'conciliada', 'false') <> 'true'))), 0),

    -- Pedidos a proveedor que todavía no se piden. Los ya `pedida` están en manos del
    -- proveedor: no son trabajo del admin y no se cuentan.
    'requisiciones', nullif((select count(*) from requisiciones where estado = 'pendiente'), 0),

    -- (71) Finanzas: documentos subidos que esperan aprobación o rechazo.
    'finanzas', nullif((select count(*) from documentos where estado in ('pendiente', 'propuesto'))
      -- (72) + facturas de proveedor vencidas con saldo
      + (select count(*) from cfdi c where c.por_pagar and c.sentido = 'recibido'
          and c.vence < current_date and _saldo_cfdi(c.id) > 0.01), 0),

    -- (71) Pago a técnicos: lo que espera una decisión del admin (aprobar un borrador o registrar
    -- que ya pagó). Las órdenes cerradas sin pagar NO se cuentan aquí: entre quincenas siempre hay,
    -- y un globo que siempre marca deja de leerse. Esas van al Inicio como "cuando se pueda".
    'pagos', nullif((select count(*) from pagos_tecnico where estado in ('propuesto', 'aprobado')), 0)

  )) end
$function$;

CREATE OR REPLACE FUNCTION public.inicio_admin()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when not es_admin() then '{}'::jsonb else jsonb_build_object(

    'fecha', current_date,

    -- ---- el día: las citas de hoy, en orden ----
    'hoy', coalesce((
      select jsonb_agg(jsonb_build_object(
               'cita_id', c.id,
               'hora', to_char(c.hora, 'HH24:MI'),
               'cliente', cl.nombre,
               'tipo', c.tipo_servicio,
               'estado', c.estado,
               'tecnico', p.nombre,
               'orden', (select o.folio from ordenes_servicio o where o.cita_id = c.id limit 1))
             order by c.hora nulls last)
        from citas c
        join clientes cl on cl.id = c.cliente_id
        left join perfiles p on p.id = c.tecnico_id
       where c.fecha = current_date
         and coalesce(c.estado, '') not in ('cancelada')), '[]'::jsonb),

    -- ---- lo que está esperando ----
    'urgente', coalesce((
      select jsonb_agg(x order by
               case x ->> 'nivel' when 'alto' then 1 when 'medio' then 2 else 3 end,
               (x ->> 'n')::int desc)
      from (
        -- Material que un técnico debe desde hace 5 días o más. Es el umbral "Atrasada" que
        -- ya usa la pantalla de Almacén; no se inventa uno nuevo.
        select jsonb_build_object(
          'clave', 'devoluciones', 'nivel', 'alto', 'pantalla', 'almacen',
          'n', n, 'texto', concat(n, case when n = 1 then ' devolución' else ' devoluciones' end,
                                  ' atrasada', case when n = 1 then '' else 's' end)) as x
          from (select count(distinct s.orden_id) as n
                  from orden_surtido s
                  join ordenes_servicio o on o.id = s.orden_id
                 where s.cantidad_entregada - s.cantidad_usada
                       - s.cantidad_devuelta - s.cantidad_diferencia > 0
                   and o.updated_at < now() - interval '5 days') z where n > 0

        union all
        -- Avisos redactados que nadie mandó: el cliente no sabe que van.
        select jsonb_build_object(
          'clave', 'avisos', 'nivel', 'alto', 'pantalla', 'agenda',
          'n', n, 'texto', concat(n, ' aviso', case when n = 1 then '' else 's' end,
                                  ' de cita sin mandar'))
          from (select count(*) as n from avisos where estado = 'pendiente') z where n > 0

        union all
        -- Un lead del sitio se enfría: es de lo que más se pudre con el tiempo.
        select jsonb_build_object(
          'clave', 'solicitudes', 'nivel', 'alto', 'pantalla', 'solicitudes',
          'n', n, 'texto', concat(n, ' solicitud', case when n = 1 then '' else 'es' end,
                                  ' del sitio sin ver'))
          from (select count(*) as n from solicitudes_web where estado = 'nueva') z where n > 0

        union all
        select jsonb_build_object(
          'clave', 'whatsapp', 'nivel', 'alto', 'pantalla', 'whatsapp',
          'n', n, 'texto', concat(n, case when n = 1 then ' conversación' else ' conversaciones' end,
                                  ' de WhatsApp sin leer'))
          from (select count(*) as n from conversaciones
                 where sin_leer > 0 and coalesce(estado, 'abierta') <> 'cerrada') z where n > 0

        union all
        select jsonb_build_object(
          'clave', 'entregas', 'nivel', 'medio', 'pantalla', 'almacen',
          'n', n, 'texto', concat(n, ' entrega', case when n = 1 then '' else 's' end,
                                  ' esperando la firma del técnico'))
          from (select count(*) as n from entregas where estado = 'pendiente') z where n > 0

        union all
        select jsonb_build_object(
          'clave', 'por_programar', 'nivel', 'medio', 'pantalla', 'agenda',
          'n', n, 'texto', concat(n, ' cita', case when n = 1 then '' else 's' end,
                                  ' por programar'))
          from (select count(*) as n from citas where estado = 'por_programar') z where n > 0

        union all
        select jsonb_build_object(
          'clave', 'cotiza_whatsapp', 'nivel', 'medio', 'pantalla', 'cotizaciones',
          'n', n, 'texto', concat(n, case when n = 1 then ' cotización' else ' cotizaciones' end,
                                  ' del agente por revisar'))
          from (select count(*) as n from cotizaciones
                 where estado = 'borrador' and origen = 'whatsapp') z where n > 0

        union all
        -- Una cotización que vence sin que nadie la persiga es una venta que se pierde sola.
        select jsonb_build_object(
          'clave', 'por_vencer', 'nivel', 'medio', 'pantalla', 'cotizaciones',
          'n', n, 'texto', concat(n, case when n = 1 then ' cotización' else ' cotizaciones' end,
                                  ' vence', case when n = 1 then '' else 'n' end,
                                  ' en 3 días o menos'))
          from (select count(*) as n from cotizaciones
                 where estado = 'enviada'
                   and fecha + coalesce(vigencia_dias, 15) between current_date
                       and current_date + 3) z where n > 0

        union all
        select jsonb_build_object(
          'clave', 'por_enviar', 'nivel', 'medio', 'pantalla', 'ordenes',
          'n', n, 'texto', concat(n, case when n = 1 then ' orden' else ' órdenes' end,
                                  ' cerrada', case when n = 1 then '' else 's' end,
                                  ' por enviar al cliente'))
          from (select count(*) as n from ordenes_servicio o
                 where o.estado = 'cerrada' and o.enviar_al_cerrar
                   and not exists (select 1 from envios_orden e where e.orden_id = o.id)) z
         where n > 0

        union all
        -- El negocio vive de las pólizas: un mantenimiento vencido es un cliente sin visitar.
        select jsonb_build_object(
          'clave', 'mantenimientos', 'nivel', 'medio', 'pantalla', 'equipos',
          'n', n, 'texto', concat(n, ' equipo', case when n = 1 then '' else 's' end,
                                  ' con el mantenimiento vencido o por vencer'))
          from (select count(*) as n from equipos
                 where coalesce(estado, 'activo') <> 'baja'
                   and proximo_mantenimiento is not null
                   and proximo_mantenimiento <= current_date + 7) z where n > 0

        union all
        select jsonb_build_object(
          'clave', 'pedidos', 'nivel', 'bajo', 'pantalla', 'requisiciones',
          'n', n, 'texto', concat(n, ' pedido', case when n = 1 then '' else 's' end,
                                  ' por poner al proveedor'))
          from (select count(*) as n from requisiciones where estado = 'pendiente') z where n > 0

        union all
        select jsonb_build_object(
          'clave', 'material', 'nivel', 'medio', 'pantalla', 'almacen',
          'n', n, 'texto', concat(n, ' pieza', case when n = 1 then '' else 's' end,
                                  ' que pidió un técnico'))
          from (select count(*) as n from solicitudes_material where estado = 'pendiente') z
         where n > 0

        union all
        -- Una venta aceptada hace más de un mes y sin cobrarse por completo: dinero que ya se ganó.
        select jsonb_build_object(
          'clave', 'cobranza_atrasada', 'nivel', 'alto', 'pantalla', 'cotizaciones',
          'n', n,
          'texto', concat(n, case when n = 1 then ' cotización' else ' cotizaciones' end,
                          ' aceptada', case when n = 1 then '' else 's' end,
                          ' con más de 30 días sin cobrarse por completo',
                          case when falta > 0
                               then concat(' · $', to_char(falta, 'FM999,999,990'), ' por cobrar')
                               else ' · cobrado: falta verificar el comprobante' end))
          from (select count(*) as n,
                       coalesce(sum(greatest(c.total - coalesce(m.cobrado, 0), 0)), 0) as falta
                  from cotizaciones c
                  left join lateral (select sum(x.monto) as cobrado
                                       from expediente_movimientos x
                                      where x.cotizacion_id = c.id and x.tipo = 'ingreso') m on true
                 where c.estado = 'aceptada' and c.cobranza_estado <> 'liquidada'
                   and coalesce(c.total, 0) > 0
                   and c.fecha <= current_date - 30) z where n > 0

        union all
        -- Lo aceptado hace menos de un mes y todavía sin cobrarse por completo.
        select jsonb_build_object(
          'clave', 'cobranza', 'nivel', 'medio', 'pantalla', 'cotizaciones',
          'n', n,
          'texto', concat(n, case when n = 1 then ' cotización' else ' cotizaciones' end,
                          ' aceptada', case when n = 1 then '' else 's' end,
                          ' sin cobrarse por completo',
                          case when falta > 0
                               then concat(' · $', to_char(falta, 'FM999,999,990'), ' por cobrar')
                               else ' · cobrado: falta verificar el comprobante' end))
          from (select count(*) as n,
                       coalesce(sum(greatest(c.total - coalesce(m.cobrado, 0), 0)), 0) as falta
                  from cotizaciones c
                  left join lateral (select sum(x.monto) as cobrado
                                       from expediente_movimientos x
                                      where x.cotizacion_id = c.id and x.tipo = 'ingreso') m on true
                 where c.estado = 'aceptada' and c.cobranza_estado <> 'liquidada'
                   and coalesce(c.total, 0) > 0
                   and c.fecha > current_date - 30) z where n > 0

        union all
        -- Cobrada hace más de 15 días y sin cerrar: la utilidad de esa operación no se conoce todavía.
        select jsonb_build_object(
          'clave', 'expedientes_atrasados', 'nivel', 'alto', 'pantalla', 'cotizaciones',
          'n', n,
          'texto', concat(n, case when n = 1 then ' cotización' else ' cotizaciones' end,
                          case when n = 1 then ' cobrada' else ' cobradas' end,
                          ' hace más de 15 días con el expediente sin cerrar (faltan los gastos y la utilidad)'))
          from (select count(*) as n
                  from cotizaciones c
                 where c.estado = 'aceptada' and c.cobranza_estado = 'liquidada'
                   and c.expediente_cerrado_en is null
                   and coalesce(c.cobranza_liquidada_en, c.updated_at, now()) <= now() - interval '15 days') z where n > 0

        union all
        -- Ya se cobró y falta capturar los gastos y cerrar para saber la utilidad.
        select jsonb_build_object(
          'clave', 'expedientes', 'nivel', 'medio', 'pantalla', 'cotizaciones',
          'n', n,
          'texto', concat(n, case when n = 1 then ' cotización' else ' cotizaciones' end,
                          case when n = 1 then ' cobrada' else ' cobradas' end,
                          ' con el expediente por cerrar (faltan los gastos y la utilidad)'))
          from (select count(*) as n
                  from cotizaciones c
                 where c.estado = 'aceptada' and c.cobranza_estado = 'liquidada'
                   and c.expediente_cerrado_en is null
                   and coalesce(c.cobranza_liquidada_en, c.updated_at, now()) > now() - interval '15 days') z where n > 0

        union all
        -- (71) Un pago aprobado ya lo ve el técnico "por cobrar": hay que pagarle y registrarlo.
        select jsonb_build_object(
          'clave', 'pagos_aprobados', 'nivel', 'alto', 'pantalla', 'pagos',
          'n', n, 'texto', concat(n, case when n = 1 then ' pago a técnico aprobado' else ' pagos a técnicos aprobados' end,
                                  ' sin registrar (el técnico ya lo ve por cobrar)'))
          from (select count(*) as n from pagos_tecnico where estado = 'aprobado') z where n > 0

        union all
        -- (71) Borradores de pago armados que esperan revisión y aprobación.
        select jsonb_build_object(
          'clave', 'pagos_propuestos', 'nivel', 'medio', 'pantalla', 'pagos',
          'n', n, 'texto', concat(n, case when n = 1 then ' pago a técnico por aprobar' else ' pagos a técnicos por aprobar' end))
          from (select count(*) as n from pagos_tecnico where estado = 'propuesto') z where n > 0

        union all
        -- (71) Facturas y tickets subidos que esperan aprobación: nada entra al libro sin ella.
        select jsonb_build_object(
          'clave', 'documentos', 'nivel', 'medio', 'pantalla', 'finanzas',
          'n', n, 'texto', concat(n, case when n = 1 then ' documento' else ' documentos' end, ' de gasto por revisar'))
          from (select count(*) as n from documentos where estado in ('pendiente', 'propuesto')) z where n > 0

        union all
        -- (71) Órdenes cerradas desde el corte (70) que aún no entran a ningún pago.
        select jsonb_build_object(
          'clave', 'tecnicos_por_pagar', 'nivel', 'bajo', 'pantalla', 'pagos',
          'n', n, 'texto', concat(n, case when n = 1 then ' orden cerrada' else ' órdenes cerradas' end,
                                  ' sin pagar a los técnicos'))
          from (select count(*) as n from (
                  select o.id, o.tecnico_id as persona from ordenes_servicio o
                   where o.estado = 'cerrada' and o.tecnico_id is not null and o.fecha >= _pagar_desde()
                  union all
                  select o.id, o.tecnico2_id from ordenes_servicio o
                   where o.estado = 'cerrada' and o.tecnico2_id is not null and o.fecha >= _pagar_desde()
                ) s
                where not exists (select 1 from pagos_tecnico_lineas l
                                   where l.orden_id = s.id and l.tecnico_id = s.persona
                                     and l.activa and l.clase = 'servicio')) z where n > 0

        union all
        -- (71) Sin tarifa del responsable ninguna orden suya se puede pagar.
        select jsonb_build_object(
          'clave', 'tarifa_responsable', 'nivel', 'bajo', 'pantalla', 'pagos', 'n', 1,
          'texto', 'Falta capturar la tarifa del técnico responsable (Pago a técnicos → Tarifas)')
         where not exists (select 1 from tarifas_pago_tecnico where rol = 'responsable')

        union all
        -- (71) Sin tu RFC no se pueden leer los XML del SAT.
        select jsonb_build_object(
          'clave', 'rfc', 'nivel', 'bajo', 'pantalla', 'finanzas', 'n', 1,
          'texto', 'Falta capturar tu RFC para leer facturas (Finanzas → Ajustes)')
         where coalesce((select rfc from empresa_fiscal where id), '') = ''

        union all
        -- (72) Facturas de proveedor vencidas: recargos y un proveedor que deja de dar crédito.
        select jsonb_build_object(
          'clave', 'cxp_vencidas', 'nivel', 'alto', 'pantalla', 'finanzas',
          'n', n, 'texto', concat(n, case when n = 1 then ' factura de proveedor vencida' else ' facturas de proveedor vencidas' end,
                                  ': $', to_char(s, 'FM999,999,990.00'), ' por pagar'))
          from (select count(*) as n, sum(_saldo_cfdi(c.id)) as s from cfdi c
                 where c.por_pagar and c.sentido = 'recibido' and c.vence < current_date
                   and _saldo_cfdi(c.id) > 0.01) z where n > 0

        union all
        -- (72) Lo que vence esta semana.
        select jsonb_build_object(
          'clave', 'cxp_por_vencer', 'nivel', 'medio', 'pantalla', 'finanzas',
          'n', n, 'texto', concat(n, case when n = 1 then ' factura de proveedor vence' else ' facturas de proveedor vencen' end,
                                  ' en los próximos 7 días: $', to_char(s, 'FM999,999,990.00')))
          from (select count(*) as n, sum(_saldo_cfdi(c.id)) as s from cfdi c
                 where c.por_pagar and c.sentido = 'recibido'
                   and c.vence between current_date and current_date + 7
                   and _saldo_cfdi(c.id) > 0.01) z where n > 0
      ) w), '[]'::jsonb))
  end
$function$;

notify pgrst, 'reload schema';

-- Registro (ver 68).
insert into _migraciones (archivo, tipo) values ('72_cuentas_por_pagar.sql', 'esquema')
on conflict (archivo) do nothing;
