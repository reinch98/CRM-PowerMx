-- ---------------------------------------------------------------------------
-- 40_pendientes_admin.sql — los contadores de la barra de navegación.
--
-- Era el paso 2 de la propuesta de interfaz y ya estaba anotado como pendiente en el proyecto
-- ("indicador de pendientes en el menú"). Sin esto, agrupar las catorce pantallas en cinco
-- áreas solo **acomoda**; con esto la barra empieza a **avisar**: hoy una devolución de seis
-- días o una solicitud del sitio sin ver no se notan hasta que alguien abre esa pantalla.
--
-- UNA SOLA LLAMADA, NO OCHO. Devuelve un jsonb con el conteo por pantalla, con las mismas
-- claves que el mapa `PANTALLAS` de `App.jsx`. La barra se dibuja en todas las pantallas, así
-- que ocho consultas por carga serían ocho viajes; esto es uno.
--
-- SOLO ADMIN, A PROPÓSITO. Es el único rol con áreas (el técnico ve dos pantallas y el
-- almacenista una). Y hay una razón de campo además de la de diseño: `App.jsx` documenta que
-- cualquier `supabase.from(...)` con el token vencido y sin señal se queda esperando la
-- renovación —medido: 5.5 s—, así que **no se le agrega una consulta al arranque del técnico**
-- por un adorno. Si esta llamada falla, la barra se dibuja sin globos y ya.
--
-- QUÉ SE CUENTA: solo lo que alguien tiene que ATENDER, no el tamaño de las tablas. Un
-- contador que siempre marca 40 deja de leerse a la semana.
--
-- SQL plano fuera de la función. Repetible.
-- ---------------------------------------------------------------------------

create or replace function pendientes_admin()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $fn$
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
    'requisiciones', nullif((select count(*) from requisiciones where estado = 'pendiente'), 0)

  )) end
$fn$;

revoke all on function pendientes_admin() from public;
grant execute on function pendientes_admin() to authenticated;

notify pgrst, 'reload schema';

-- Comprobación rápida: corriendo como admin debe devolver un objeto (vacío si no hay nada
-- que atender, que también es la respuesta correcta).
select pendientes_admin() as pendientes;
