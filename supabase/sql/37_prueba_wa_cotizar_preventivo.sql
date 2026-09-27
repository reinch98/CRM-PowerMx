-- ---------------------------------------------------------------------------
-- Prueba de 37_wa_cotizar_preventivo.sql. Correr DESPUÉS del 36, y el bloque COMPLETO.
-- Todo en begin/rollback. SQL plano, sin bloques plpgsql (ver CLAUDE.md).
--
-- OJO: la secuencia de folios NO se revierte con el rollback, así que esta prueba consume
-- folios de cotización. Es lo mismo que pasa con las pruebas de la 1b y la 1c.
--
-- Se fabrica todo el escenario: dos clientes (uno a 60 km y otro a 10), un generador diésel
-- de 100 kW para cada uno, la tarifa de preventivo menor, la de traslado, un paquete con una
-- refacción, y una conversación de WhatsApp ligada al contacto del primer cliente.
-- ---------------------------------------------------------------------------

begin;

-- ---- el escenario ----
select set_config('app.cli',  gen_random_uuid()::text, true),
       set_config('app.cli2', gen_random_uuid()::text, true),
       set_config('app.eq',   gen_random_uuid()::text, true),
       set_config('app.eq2',  gen_random_uuid()::text, true),
       set_config('app.prod', gen_random_uuid()::text, true),
       set_config('app.paq',  gen_random_uuid()::text, true),
       set_config('app.con',  gen_random_uuid()::text, true),
       set_config('app.ctc',  gen_random_uuid()::text, true);

-- Cliente lejano (60 km) y cliente cercano (10 km: por debajo del mínimo de 40).
insert into clientes (id, nombre, telefono, distancia_km) values
  (current_setting('app.cli')::uuid,  'PRUEBA-36 lejano',  '9990000036', 60),
  (current_setting('app.cli2')::uuid, 'PRUEBA-36 cercano', '9990000037', 10);

insert into equipos (id, cliente_id, tipo, marca, modelo, capacidad_kw, numero_serie, atributos) values
  (current_setting('app.eq')::uuid,  current_setting('app.cli')::uuid,  'generador', 'Prueba36', 'G100', 100,
   'PRUEBA-36-A', '{"combustible": "diesel"}'::jsonb),
  (current_setting('app.eq2')::uuid, current_setting('app.cli2')::uuid, 'generador', 'Prueba36', 'G100', 100,
   'PRUEBA-36-B', '{"combustible": "diesel"}'::jsonb);

-- Tarifas: el preventivo menor de diésel 30–500 kW a 4,500 y el traslado a 15 por km.
insert into tarifas_servicio (concepto, clase, kw_desde, kw_hasta, precio, activo, sku, nombre)
values ('preventivo_menor', 'diesel', 30, 500, 4500, true, 'PRUEBA36-PMEN',
        'Mantenimiento menor — Diésel 30–500 kW');
insert into tarifas_servicio (concepto, km_desde, precio, activo)
values ('traslado', 40, 15, true);

-- Una refacción con existencia y un paquete que la lleva.
-- `categoria` es obligatoria en `productos` (y no tiene default): sin ella el insert truena.
insert into productos (id, sku, categoria, nombre, unidad, precio, costo, activo)
values (current_setting('app.prod')::uuid, 'PRUEBA36-FIL', 'refaccion', 'Filtro de prueba',
        'pieza', 300, 120, true);
insert into movimientos_inventario (id, tipo, cantidad, producto_id, referencia, created_at)
values (gen_random_uuid(), 'entrada', 10, current_setting('app.prod')::uuid, 'PRUEBA-36', now());

insert into paquetes_mantenimiento (id, tipo, clase, kw_desde, kw_hasta, nombre, activo)
values (current_setting('app.paq')::uuid, 'menor', 'diesel', 30, 500, 'Paquete PRUEBA-36', true);
insert into paquete_lineas (paquete_id, descripcion, cantidad, orden, producto_id)
values (current_setting('app.paq')::uuid, 'Filtro de aceite', 2, 1, current_setting('app.prod')::uuid);

-- El contacto y su conversación de WhatsApp, que es de donde sale el cliente.
insert into contactos (id, cliente_id, nombre, telefono, activo, verificado)
values (current_setting('app.ctc')::uuid, current_setting('app.cli')::uuid,
        'Contacto PRUEBA-36', '9990000036', true, true);
insert into conversaciones (id, telefono, contacto_id)
values (current_setting('app.con')::uuid, '9990000036', current_setting('app.ctc')::uuid);

-- QUIÉN LLAMA. `wa_cotizar_preventivo` exige `_es_bot_o_admin()`, que se resuelve con
-- `mi_rol()`, que a su vez lee `auth.uid()` de `request.jwt.claims`. En el editor SQL no hay
-- claims, así que `mi_rol()` devuelve null y la función rechaza la llamada — es lo que debe
-- hacer. Se simula el **bot**, que es quien la llama en producción.
--
-- NO se hace `set local role authenticated`: solo hacen falta las claims para que `mi_rol()`
-- sepa quién es, y dejando el rol de base intacto la siembra de arriba y el `update` del paso
-- 9 siguen saltándose RLS, que es lo que se quiere en una prueba.
select set_config('app.bot',
         coalesce((select id::text from perfiles where rol = 'bot' and coalesce(activo, true) limit 1),
                  (select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1),
                  ''), true);

select set_config('request.jwt.claims',
         json_build_object('sub', current_setting('app.bot'), 'role', 'authenticated')::text, true);

select set_config('app.p0', concat(
  case when nullif(current_setting('app.bot'), '') is null then 'FALLO: no hay cuenta bot ni admin'
       else 'ok' end,
  ' — escenario listo (2 clientes a 60 y 10 km, tarifas, paquete y conversación), llamando como ',
  coalesce((select rol from perfiles where id = nullif(current_setting('app.bot'), '')::uuid), 'nadie')), true);

-- ---- 1) el camino feliz: cotiza el lejano ----
select set_config('app.r1', wa_cotizar_preventivo(current_setting('app.con')::uuid,
                                                  current_setting('app.eq')::uuid, 'menor')::text, true);

select set_config('app.p1', concat(
  case when (current_setting('app.r1')::jsonb ->> 'ok') = 'true' then 'ok' else 'FALLO' end,
  ' — cotizó: ', current_setting('app.r1')), true);

-- 2) El total NO debe venir en la respuesta: el agente no dice precios.
select set_config('app.p2', concat(
  case when not (current_setting('app.r1')::jsonb ? 'total')
        and not (current_setting('app.r1')::jsonb ? 'subtotal')
        and not (current_setting('app.r1')::jsonb ? 'precio')
       then 'ok' else 'FALLO' end,
  ' — la respuesta que ve el modelo no trae total ni precio'), true);

-- 3) Los números de la cotización guardada. Servicio 4,500 + traslado 60 km x 15 = 900,
--    refacción en 0 → subtotal 5,400, IVA 864, total 6,264.
select set_config('app.p3', concat(
  case when c.subtotal = 5400 and c.iva = 864 and c.total = 6264 then 'ok' else 'FALLO' end,
  ' — subtotal ', c.subtotal, ', IVA ', c.iva, ', total ', c.total,
  ' (se esperaba 5400 / 864 / 6264)'), true)
from cotizaciones c
where c.folio = (current_setting('app.r1')::jsonb ->> 'folio')::int;

-- 4) Nace en borrador, con origen whatsapp, y con las tres partidas en su sitio.
select set_config('app.p4', concat(
  case when c.estado = 'borrador' and c.origen = 'whatsapp'
        and jsonb_array_length(c.partidas) = 3 then 'ok' else 'FALLO' end,
  ' — estado ', c.estado, ', origen ', c.origen,
  ', ', jsonb_array_length(c.partidas), ' partidas (se esperaban 3)'), true)
from cotizaciones c
where c.folio = (current_setting('app.r1')::jsonb ->> 'folio')::int;

-- 5) La refacción va a 0 y marcada `incluida`, pero CON producto_id: es lo único que mira el
--    almacén, así que apartará inventario el día que alguien acepte.
select set_config('app.p5', concat(
  case when p ->> 'precio_unitario' = '0' and (p ->> 'incluida') = 'true'
        and p ->> 'producto_id' = current_setting('app.prod')
       then 'ok' else 'FALLO' end,
  ' — la refacción va en ', p ->> 'precio_unitario', ', incluida=', p ->> 'incluida',
  ', con producto_id=', case when p ? 'producto_id' then 'sí' else 'no' end), true)
from cotizaciones c,
     lateral jsonb_array_elements(c.partidas) p
where c.folio = (current_setting('app.r1')::jsonb ->> 'folio')::int
  and p ->> 'sku' = 'PRUEBA36-FIL';

-- 6) Un borrador no mueve inventario: no debe existir ningún `apartado`.
select set_config('app.p6', concat(
  case when count(*) = 0 then 'ok' else 'FALLO' end,
  ' — movimientos de apartado tras cotizar: ', count(*), ' (debe ser 0: es un borrador)'), true)
from movimientos_inventario
where producto_id = current_setting('app.prod')::uuid and tipo = 'apartado';

-- ---- 7) pedir lo mismo otra vez no apila cotizaciones ----
select set_config('app.r7', wa_cotizar_preventivo(current_setting('app.con')::uuid,
                                                  current_setting('app.eq')::uuid, 'menor')::text, true);
select set_config('app.p7', concat(
  case when (current_setting('app.r7')::jsonb ->> 'repetida') = 'true'
        and (current_setting('app.r7')::jsonb ->> 'folio') = (current_setting('app.r1')::jsonb ->> 'folio')
       then 'ok' else 'FALLO' end,
  ' — la segunda vez devolvió el mismo folio y no creó otra: ', current_setting('app.r7')), true);

-- ---- 8) el equipo de OTRO cliente se rechaza, aunque el id venga bien escrito ----
select set_config('app.r8', wa_cotizar_preventivo(current_setting('app.con')::uuid,
                                                  current_setting('app.eq2')::uuid, 'menor')::text, true);
select set_config('app.p8', concat(
  case when (current_setting('app.r8')::jsonb ->> 'ok') = 'false'
        and (current_setting('app.r8')::jsonb ->> 'falta') like '%no es de este cliente%'
       then 'ok' else 'FALLO' end,
  ' — equipo de otro cliente: ', current_setting('app.r8')), true);

-- ---- 9) sin tarifa no inventa un precio ----
-- Solo se capturó la tarifa de mantenimiento MENOR, así que pedir el mayor tiene que
-- devolver un motivo y ninguna cotización. No hace falta apagar nada.
select set_config('app.r9', wa_cotizar_preventivo(current_setting('app.con')::uuid,
                                                  current_setting('app.eq')::uuid, 'mayor')::text, true);
select set_config('app.p9', concat(
  case when (current_setting('app.r9')::jsonb ->> 'ok') = 'false'
        and not (current_setting('app.r9')::jsonb ? 'folio')
       then 'ok' else 'FALLO' end,
  ' — sin tarifa de mayor: ', current_setting('app.r9')), true);

-- ---- 10) el traslado no aplica por debajo de los 40 km, y eso NO es un dato que falte ----
select set_config('app.r10', _precio_traslado(current_setting('app.cli2')::uuid)::text, true);
select set_config('app.p10', concat(
  case when (current_setting('app.r10')::jsonb ->> 'aplica') = 'false'
        and (current_setting('app.r10')::jsonb ->> 'importe') = '0'
        and not (current_setting('app.r10')::jsonb ? 'falta')
       then 'ok' else 'FALLO' end,
  ' — cliente a 10 km: ', current_setting('app.r10')), true);

-- 11) Y a 60 km cobra los 60, no los 20 que pasan de 40. Es el mismo número que da
--     `tarifas.js` en el navegador (60 x 15 = 900): las dos implementaciones deben coincidir.
select set_config('app.p11', concat(
  case when (_precio_traslado(current_setting('app.cli')::uuid) ->> 'importe')::numeric = 900
       then 'ok' else 'FALLO' end,
  ' — traslado a 60 km: ', _precio_traslado(current_setting('app.cli')::uuid) ->> 'importe',
  ' (se esperaba 900: todos los km, solo ida)'), true);

-- ---- 12) un número sin ligar no cotiza nada ----
insert into conversaciones (id, telefono) values (gen_random_uuid(), '9990000099');
select set_config('app.r12',
  wa_cotizar_preventivo((select id from conversaciones where telefono = '9990000099'),
                        current_setting('app.eq')::uuid, 'menor')::text, true);
select set_config('app.p12', concat(
  case when (current_setting('app.r12')::jsonb ->> 'ok') = 'false'
        and (current_setting('app.r12')::jsonb ->> 'falta') like '%ligado%'
       then 'ok' else 'FALLO' end,
  ' — número sin ligar: ', current_setting('app.r12')), true);

select current_setting('app.p0', true) as resultado
union all select current_setting('app.p1', true)
union all select current_setting('app.p2', true)
union all select current_setting('app.p3', true)
union all select current_setting('app.p4', true)
union all select current_setting('app.p5', true)
union all select current_setting('app.p6', true)
union all select current_setting('app.p7', true)
union all select current_setting('app.p8', true)
union all select current_setting('app.p9', true)
union all select current_setting('app.p10', true)
union all select current_setting('app.p11', true)
union all select current_setting('app.p12', true);

rollback;
