-- ---------------------------------------------------------------------------
-- 65_inicio_expedientes.sql — el Inicio del admin cuenta los expedientes por cerrar.
--
-- Agrega a `inicio_admin()` dos avisos sobre las cotizaciones ACEPTADAS que ya se cobraron
-- (cobranza liquidada, SQL 63) y cuyo expediente sigue abierto (SQL 61): falta capturar los gastos
-- (material, técnicos, vehículo, gasolina…) y cerrarlo, que es cuando se conoce la utilidad.
--   · "cobradas hace más de 15 días con el expediente sin cerrar"  → nivel ALTO ("Atender hoy"):
--     una operación terminada de cobrar de la que nadie sabe todavía cuánto dejó.
--   · "con el expediente por cerrar" (menos de 15 días)            → nivel MEDIO ("Esta semana").
-- Los días se cuentan desde que se liquidó la cobranza. Cada aviso lleva a Cotizaciones.
--
-- Es la misma función completa de la 64 con estos dos renglones más (`create or replace` no
-- permite agregar un renglón sin repetirla entera). No hace falta tocar la pantalla del Inicio.
-- SQL plano, repetible.
-- ---------------------------------------------------------------------------

create or replace function inicio_admin()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $fn$
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
      ) w), '[]'::jsonb))
  end
$fn$;

revoke all on function inicio_admin() from public;
grant execute on function inicio_admin() to authenticated;

notify pgrst, 'reload schema';

-- Registro (ver 68).
insert into _migraciones (archivo, tipo) values ('65_inicio_expedientes.sql', 'esquema')
on conflict (archivo) do nothing;

-- Comprobación: como admin devuelve un objeto con `fecha`, `hoy` y `urgente`.
select inicio_admin() as inicio;
