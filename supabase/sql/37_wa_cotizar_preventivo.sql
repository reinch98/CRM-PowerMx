-- ---------------------------------------------------------------------------
-- 37_wa_cotizar_preventivo.sql — la segunda (y última) herramienta de escritura del agente
-- de WhatsApp: dejar una cotización de mantenimiento preventivo en BORRADOR.
--
-- Cierra el "Falta: el cotizador de preventivos" del paso (3) del plan de WhatsApp. Se puede
-- hacer ahora porque el precio fijo por clase y capacidad ya vive en SQL desde la 28
-- (`paquete_preventivo`) y la 29 lo partió en piezas sin precio: cuando se diseñó esto, la
-- fórmula solo existía en el navegador (`tarifas.js`) y por eso quedó pendiente.
--
-- LA REGLA QUE MANDA, igual que en toda la 27: **el cliente sale del NÚMERO, nunca del
-- texto.** Se parte de `p_conversacion`, se saca su contacto y de ahí el `cliente_id`
-- (`_cliente_de_conversacion`). Un mensaje que diga "cotiza el generador de la empresa X" no
-- puede mover eso, y un equipo de otro cliente se rechaza aunque el id venga bien escrito.
--
-- EL PRECIO LO CALCULA LA BASE. El modelo no lo compone, no lo redondea y no lo transmite:
-- por decisión de Caña (27/09/2026) **el agente no le dice el precio al cliente**, solo avisa
-- que la cotización se está preparando. Por eso la función devuelve el folio y el tipo de
-- servicio, y **el total no sale** en la respuesta que ve el modelo. El admin la revisa en
-- Cotizaciones y la manda él.
--
-- QUÉ LLEVA LA COTIZACIÓN (las mismas reglas que la pantalla de admin, para que el precio no
-- dependa de por dónde entró la solicitud):
--   · el servicio, con su precio fijo tabulado por clase y tramo de kW;
--   · las refacciones del paquete a **precio 0** y marcadas `incluida` — van dentro del
--     servicio, pero con `producto_id`, que es lo único que mira el almacén: así apartan
--     inventario igual cuando alguien acepte la cotización (SQL 28);
--   · el **traslado** desde los 40 km, cobrando todos los km y solo ida (decisión de Caña del
--     20/09/2026 para el diagnóstico, extendida al preventivo el 27/09/2026).
--
-- SALE EN BORRADOR Y NO MUEVE NADA. Un borrador no aparta inventario ni genera requisiciones:
-- eso solo ocurre al aceptar, y aceptar sigue siendo del admin
-- (`cambiar_estado_cotizacion` exige `es_admin()`).
--
-- SI FALTA UN DATO, NO INVENTA UN PRECIO: devuelve `{"ok": false, "falta": "…"}` con el
-- motivo en palabras y el agente pasa la conversación a una persona. Falta = sin combustible
-- capturado, sin capacidad, sin tarifa para esa clase y tramo, sin paquete de refacciones, o
-- sin `distancia_km` del cliente.
--
-- SQL plano fuera de las funciones (ver "Pruebas en el editor SQL" en CLAUDE.md).
-- Repetible: `add column if not exists` y `create or replace`.
-- ---------------------------------------------------------------------------

-- De dónde viene una cotización. Hasta hoy todas eran de la oficina; ahora hay que poder
-- distinguir las que propuso el agente, porque son las que el admin tiene que revisar.
alter table cotizaciones add column if not exists origen text;

comment on column cotizaciones.origen is
  'De dónde salió: null = la oficina, ''whatsapp'' = la propuso el agente y falta revisarla.';

-- ---------------------------------------------------------------------------
-- El traslado, en la base. La misma regla que `tarifas.js` en el navegador: aplica a partir de
-- `km_desde` (40 por omisión) y, una vez rebasado, se cobran TODOS los km, solo ida.
--
-- Existen dos implementaciones de esta regla —esta y la de `tarifas.js`— y no se puede evitar:
-- el navegador no puede llamar a una función que el bot necesita con otros permisos, y el bot
-- no puede leer `tarifas_servicio`. **Tienen que dar el mismo número**, y eso se comprueba:
-- 60 km a 15/km = 900 en las pruebas de los dos lados.
-- ---------------------------------------------------------------------------
create or replace function _precio_traslado(p_cliente uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_km     numeric;
  v_t      tarifas_servicio%rowtype;
  v_desde  numeric;
begin
  -- Asignación y no `select ... into`: el editor de Supabase confunde ese `into` con la
  -- sintaxis vieja de `create table as` y llega a mutilar el bloque (ver CLAUDE.md).
  v_km := (select distancia_km from clientes where id = p_cliente);
  if v_km is null then
    return jsonb_build_object('falta', 'El cliente no tiene capturada la distancia en km.');
  end if;

  -- La fila entera de una vez: pedir precio y km_desde por separado podría tomarlos de dos
  -- tarifas distintas si hubiera varias activas.
  v_t := (select t from tarifas_servicio t
           where t.activo and t.concepto = 'traslado'
           order by t.updated_at desc
           limit 1);

  if v_t.precio is null then
    return jsonb_build_object('falta', 'No hay tarifa de traslado capturada en Tarifas.');
  end if;
  v_desde := coalesce(v_t.km_desde, 40);

  -- Por debajo del mínimo no se cobra, y eso NO es un dato que falte: es un cliente cerca.
  if v_km < v_desde then
    return jsonb_build_object('km', v_km, 'aplica', false, 'importe', 0);
  end if;

  return jsonb_build_object('km', v_km, 'aplica', true,
                            'precio_km', v_t.precio,
                            'importe', round(v_km * v_t.precio, 2));
end $fn$;

revoke all on function _precio_traslado(uuid) from public;

-- ---------------------------------------------------------------------------
-- La herramienta. Devuelve jsonb; nunca lanza excepción por un dato que falte, porque el
-- agente tiene que poder explicarle al cliente qué pasó en vez de quedarse callado.
-- ---------------------------------------------------------------------------
create or replace function wa_cotizar_preventivo(
  p_conversacion uuid,
  p_equipo       uuid,
  p_tipo         text default 'menor'
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_cliente   uuid;
  e           equipos%rowtype;
  v_clase     text;
  v_cap       numeric;
  v_tarifa    tarifas_servicio%rowtype;
  v_paquete   uuid;
  v_traslado  jsonb;
  v_partidas  jsonb := '[]'::jsonb;
  v_subtotal  numeric := 0;
  v_iva       numeric;
  v_ya        cotizaciones%rowtype;
  v_id        uuid;
  v_folio     int;
  v_desc      text;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el conector de WhatsApp o el administrador.' using errcode = '42501';
  end if;
  if p_tipo not in ('menor', 'mayor') then
    return jsonb_build_object('ok', false, 'falta', 'El mantenimiento es menor o mayor.');
  end if;

  -- El cliente sale del número. Si no está ligado, no se cotiza nada.
  v_cliente := _cliente_de_conversacion(p_conversacion);
  if v_cliente is null then
    return jsonb_build_object('ok', false,
      'falta', 'Ese número todavía no está ligado a un cliente: una persona tiene que enlazarlo.');
  end if;

  -- El equipo tiene que ser de ESE cliente, aunque el id venga bien escrito.
  e := (select x from equipos x where x.id = p_equipo and x.cliente_id = v_cliente);
  if e.id is null then
    return jsonb_build_object('ok', false, 'falta', 'Ese equipo no es de este cliente.');
  end if;

  v_clase := _clase_de_equipo(e);
  v_cap   := _capacidad_de_equipo(e);

  -- La tarifa fija por clase y tramo de kW. Gana la más específica: primero la que sí tiene
  -- clase, y dentro de ésas la que empieza más arriba. Es la misma búsqueda que hace
  -- `paquete_preventivo` (SQL 28): si se cambia una, hay que cambiar la otra.
  v_tarifa := (select t from tarifas_servicio t
                where t.activo
                  and t.concepto = 'preventivo_' || p_tipo
                  and (t.clase is null or t.clase = v_clase)
                  and (t.kw_desde is null or (v_cap is not null and v_cap >= t.kw_desde))
                  and (t.kw_hasta is null or (v_cap is not null and v_cap <= t.kw_hasta))
                order by (t.clase is not null) desc, t.kw_desde desc nulls last
                limit 1);

  v_paquete  := _paquete_de_equipo(e.id, p_tipo);
  v_traslado := _precio_traslado(v_cliente);

  -- Todo lo que puede faltar, con el motivo en palabras. Sin esto habría que inventar un
  -- precio, que es justo lo que el diseño prohíbe.
  if v_clase is null then
    return jsonb_build_object('ok', false,
      'falta', 'No se sabe de qué clase es el equipo: falta capturar el combustible.');
  elsif v_cap is null then
    return jsonb_build_object('ok', false, 'falta', 'El equipo no tiene capacidad capturada.');
  elsif v_tarifa.precio is null then
    return jsonb_build_object('ok', false,
      'falta', concat('No hay tarifa de mantenimiento ', p_tipo, ' para esa clase y capacidad.'));
  elsif v_paquete is null then
    return jsonb_build_object('ok', false,
      'falta', 'Ese equipo todavía no tiene paquete de refacciones capturado.');
  elsif v_traslado ? 'falta' then
    return jsonb_build_object('ok', false, 'falta', v_traslado ->> 'falta');
  end if;

  -- Una línea del paquete sin ningún código disponible se caería en silencio del arreglo, y el
  -- almacén no tendría qué preparar. Mejor no cotizar y que lo vea una persona.
  if exists (
    select 1 from paquete_lineas l
     where l.paquete_id = v_paquete
       and not exists (select 1 from _codigos_de_linea(l.id))
  ) then
    return jsonb_build_object('ok', false,
      'falta', 'Al paquete de ese equipo le falta el código de alguna refacción.');
  end if;

  -- ¿Ya hay un borrador del agente para lo mismo? No se apilan cotizaciones: pedir dos veces
  -- devuelve la que ya estaba, igual que `wa_solicitar_cita` no apila citas. Se busca por la
  -- marca `servicio` de la partida y no por el sku, que en `tarifas_servicio` puede ser nulo.
  v_ya := (select c from cotizaciones c
            where c.cliente_id = v_cliente and c.equipo_id = e.id
              and c.estado = 'borrador' and c.origen = 'whatsapp'
              and c.tipo = 'preventivo'
              and c.partidas @> jsonb_build_array(
                    jsonb_build_object('servicio', 'preventivo_' || p_tipo))
            order by c.created_at desc
            limit 1);
  if v_ya.id is not null then
    return jsonb_build_object('ok', true, 'repetida', true, 'folio', v_ya.folio, 'tipo', p_tipo);
  end if;

  -- 1) El servicio. Partida LIBRE (sin producto_id): no mueve inventario.
  v_partidas := v_partidas || jsonb_build_array(jsonb_build_object(
    'producto_id', null, 'sku', v_tarifa.sku,
    -- `servicio` marca de qué se trata la partida, como hace `tarifas.js` con 'diagnostico' y
    -- 'traslado'. Sirve para no apilar borradores del mismo tipo.
    'servicio', 'preventivo_' || p_tipo,
    'descripcion', coalesce(v_tarifa.nombre, concat('Mantenimiento ', p_tipo)),
    'unidad', 'servicio', 'cantidad', 1,
    'precio_unitario', v_tarifa.precio, 'importe', v_tarifa.precio));
  v_subtotal := v_subtotal + v_tarifa.precio;

  -- 2) Las refacciones del paquete: precio 0 y marcadas `incluida`, pero CON producto_id para
  --    que aparten inventario el día que alguien acepte. De cada línea se toma el código con
  --    más existencia, que puede ser el genérico en vez del original (SQL 29).
  v_partidas := v_partidas || coalesce((
    select jsonb_agg(jsonb_build_object(
             'producto_id', c.producto_id, 'sku', c.sku, 'descripcion', c.nombre,
             'unidad', coalesce(c.unidad, 'pieza'), 'cantidad', l.cantidad,
             'precio_unitario', 0, 'importe', 0, 'incluida', true)
           order by l.orden)
      from paquete_lineas l
      cross join lateral (
        select * from _codigos_de_linea(l.id) x order by x.disponible desc limit 1
      ) c
     where l.paquete_id = v_paquete), '[]'::jsonb);

  -- 3) El traslado, si aplica.
  if (v_traslado ->> 'aplica')::boolean then
    v_partidas := v_partidas || jsonb_build_array(jsonb_build_object(
      'producto_id', null, 'sku', '',
      'descripcion', concat('Servicio de traslado (', v_traslado ->> 'km', ' km, solo ida)'),
      'unidad', 'km', 'cantidad', (v_traslado ->> 'km')::numeric,
      'precio_unitario', (v_traslado ->> 'precio_km')::numeric,
      'importe', (v_traslado ->> 'importe')::numeric));
    v_subtotal := v_subtotal + (v_traslado ->> 'importe')::numeric;
  end if;

  v_iva := round(v_subtotal * 0.16, 2);

  insert into cotizaciones (cliente_id, equipo_id, tipo, partidas, subtotal, descuento,
                            iva, total, requiere_visita, estado, origen, creada_por,
                            notas_internas)
  values (v_cliente, e.id, 'preventivo', v_partidas, v_subtotal, 0,
          v_iva, v_subtotal + v_iva, true, 'borrador', 'whatsapp', 'agente-whatsapp',
          concat('Propuesta del agente de WhatsApp (mantenimiento ', p_tipo,
                 '). Revisar antes de enviar.'))
  -- Este `into` sí se queda: va con `returning` y sin `from`, así que no se puede confundir
  -- con un `create table as`. Lo que el editor malinterpreta es `select ... into X from ...`.
  returning id, folio into v_id, v_folio;   --  no lo confunde: no lleva 

  perform _apunta('cotizaciones', v_id, 'cotizacion_whatsapp', null,
                  jsonb_build_object('tipo', p_tipo, 'equipo_id', e.id), 'whatsapp');

  v_desc := trim(concat_ws(' ', e.marca, e.modelo,
                           case when e.capacidad_kw is not null
                                then concat(e.capacidad_kw, ' kW') end));

  -- El total NO se devuelve: el agente no le dice el precio al cliente.
  return jsonb_build_object('ok', true, 'folio', v_folio, 'tipo', p_tipo,
                            'equipo', nullif(v_desc, ''),
                            'aviso', 'Quedó en borrador. Una persona la revisa y la envía.');
end $fn$;

revoke all on function wa_cotizar_preventivo(uuid, uuid, text) from public;
grant execute on function wa_cotizar_preventivo(uuid, uuid, text) to authenticated;

notify pgrst, 'reload schema';
