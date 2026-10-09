-- ============================================================================
-- 71 · Avisos de Finanzas y de pago a técnicos en el Inicio y en los globos del menú
--
-- Requiere el 66, 67 y 70. Las dos funciones se redefinen COMPLETAS (create or replace no permite
-- agregar un renglón) a partir de su definición viva del 09/10/2026, con solo los renglones
-- marcados "(71)" de más.
--
-- Globos: 'finanzas' = documentos por revisar; 'pagos' = pagos por aprobar o por registrar.
-- Inicio: pagos aprobados sin registrar (alto: el técnico ya los ve por cobrar), pagos por aprobar y
-- documentos por revisar (medio), y como "cuando se pueda": órdenes cerradas sin pagar desde el
-- corte, la tarifa del responsable sin capturar y el RFC sin capturar.
-- No hizo falta tocar Inicio.jsx ni App.jsx: dibujan cualquier aviso y cualquier clave que mande la base.
-- ============================================================================

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
    'finanzas', nullif((select count(*) from documentos where estado in ('pendiente', 'propuesto')), 0),

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
      ) w), '[]'::jsonb))
  end
$function$;

notify pgrst, 'reload schema';

-- Registro (ver 68).
insert into _migraciones (archivo, tipo) values ('71_avisos_finanzas.sql', 'esquema')
on conflict (archivo) do nothing;
