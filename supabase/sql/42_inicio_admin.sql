-- ---------------------------------------------------------------------------
-- 42_inicio_admin.sql — lo que está esperando, y el día de hoy.
--
-- Hasta ahora el admin entraba a la Agenda, que muestra el calendario pero **no lo que está
-- esperando**: una devolución de seis días, un aviso de cita sin mandar o una solicitud del
-- sitio sin ver no se notan hasta que alguien abre esa pantalla. Esto convierte el CRM en algo
-- que dice qué atender en vez de esperar a que le pregunten.
--
-- FUNCIÓN APARTE, NO UNA MÁS GRANDE. `pendientes_admin()` (SQL 40) cuenta por pestaña y la
-- llama la barra en **todas** las pantallas; ésta trae el detalle y solo la llama el inicio.
-- Cada una con un trabajo, y el inicio paga solo por sus datos.
--
-- QUÉ ES "URGENTE" AQUÍ: lo que **se pudre con el tiempo**, no todo lo que está abierto. Una
-- lista de once avisos es la misma enfermedad que un contador que siempre marca 40: se deja
-- de leer. Solo salen los que tienen algo (`n > 0`), ordenados por nivel.
--
-- Los textos vienen armados desde aquí, en palabras y con su número, para que la pantalla no
-- tenga que reinventarlos y para que digan lo mismo en el celular y en un correo si algún día
-- se manda uno.
--
-- SQL plano fuera de las funciones, sin `select ... into`. Repetible.
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
          'n', n, 'texto', concat(n, ' devolución', case when n = 1 then '' else 'es' end,
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
          'n', n, 'texto', concat(n, ' conversación', case when n = 1 then '' else 'es' end,
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
          'n', n, 'texto', concat(n, ' cotización', case when n = 1 then '' else 'es' end,
                                  ' del agente por revisar'))
          from (select count(*) as n from cotizaciones
                 where estado = 'borrador' and origen = 'whatsapp') z where n > 0

        union all
        -- Una cotización que vence sin que nadie la persiga es una venta que se pierde sola.
        select jsonb_build_object(
          'clave', 'por_vencer', 'nivel', 'medio', 'pantalla', 'cotizaciones',
          'n', n, 'texto', concat(n, ' cotización', case when n = 1 then '' else 'es' end,
                                  ' vence', case when n = 1 then '' else 'n' end,
                                  ' en 3 días o menos'))
          from (select count(*) as n from cotizaciones
                 where estado = 'enviada'
                   and fecha + coalesce(vigencia_dias, 15) between current_date
                       and current_date + 3) z where n > 0

        union all
        select jsonb_build_object(
          'clave', 'por_enviar', 'nivel', 'medio', 'pantalla', 'ordenes',
          'n', n, 'texto', concat(n, ' orden', case when n = 1 then '' else 'es' end,
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
      ) w), '[]'::jsonb))
  end
$fn$;

revoke all on function inicio_admin() from public;
grant execute on function inicio_admin() to authenticated;

notify pgrst, 'reload schema';

-- Comprobación: como admin devuelve un objeto con `fecha`, `hoy` y `urgente`.
select inicio_admin() as inicio;
