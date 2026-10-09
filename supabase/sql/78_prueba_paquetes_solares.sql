-- Prueba de 78_paquetes_solares.sql. Correr DESPUÉS del 78, el bloque COMPLETO. begin/rollback.
-- SQL plano (sin bloques plpgsql). Regresión contra el "Borrador paquetes solares PowerMx.xlsx": dentro de la
-- transacción se ponen los costos de los componentes y los parámetros del borrador (tipo de cambio 18.5), y
-- los 18 costos que da la base (6 paquetes × 3 variantes) tienen que ser los del Excel, ±1 peso (el Excel
-- usaba costos con 3 decimales; el catálogo guarda 2).
-- Regla de margen de prueba: paquete_solar, 30 % sobre el costo, sin mínimo, al peso.
begin;

select set_config('request.jwt.claims',
  json_build_object('sub', (select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1),
                    'role', 'authenticated')::text, true);

-- Costos del borrador (hoja Componentes, columna "Costo MXN", redondeados a centavos).
update productos p set costo = v.c, activo = true
  from (values ('PSOJAS1S207', 2121.21), ('INVGROWS4', 4993.34), ('INVGROWS11', 7938.17), ('INVGROWS3', 12803.30),
               ('INVLUXLS101', 8695.00), ('INVLUXS109', 17987.37), ('INVLUXS128', 499.50), ('BATLUXS107', 16465.00),
               ('SMOALM1S520', 3658.01), ('SMOALM1S521', 4739.33), ('SMOALM1S522', 5344.47), ('SMOALM1S523', 6326.63),
               ('SMOPVA1S289', 129.50), ('SINPVA1S341', 2040.55), ('SINPVA1S342', 2040.55), ('SINPVA1S298', 103.42),
               ('PYMSUT1S112', 187.22), ('PYM1033685S102', 577.57), ('SINOMN1S102', 197.40), ('SINOMN1S104', 440.86),
               ('SINOMN1S101', 127.28), ('SINOMN1S107', 111.74), ('SINOMN1S108', 111.74), ('SINOMN1S109', 111.74),
               ('SINPVA1S309', 105.45), ('SINPVA1S306', 106.19), ('SINPVA1S304', 116.00), ('SINPVA1S308', 72.71),
               ('SINPVA1S305', 107.12), ('SINPVA1S307', 72.89)) as v(sku, c)
 where p.sku = v.sku;
-- Parámetros del borrador.
update parametros_costeo pc set valor = v.x
  from (values ('mano_obra_panel', 800), ('mano_obra_fija', 2500), ('tramite_cfe', 1500), ('mano_obra_respaldo', 2500),
               ('imprevistos_pct', 3), ('cable_ca_10awg_m', 20), ('cable_ca_8awg_m', 35), ('cable_ca_6awg_m', 55),
               ('cable_tierra_10awg_m', 20), ('conduit_m', 45), ('varilla_tierra', 450), ('material_tablero', 400),
               ('centro_carga_esenciales', 1500), ('cables_bateria', 800), ('potencia_panel_w', 630),
               ('ahorro_kwp_min', 333), ('ahorro_kwp_max', 500), ('paquete_redondeo', 1000), ('paquete_terminacion', 1))
         as v(clave, x)
 where pc.clave = v.clave;
-- Precios publicados de hoy en el sitio, y ninguna variante publicada todavía desde la receta.
update productos p set precios = jsonb_build_object('estandar', v.e, 'hibrido', v.h), precio = v.e,
                       atributos = coalesce(p.atributos, '{}'::jsonb) - 'receta_publicada'
  from (values ('PKG-STARTER', 40000, 52000), ('PKG-ESSENTIAL', 53999, 68000), ('PKG-COMFORT', 64999, 80000),
               ('PKG-PLUS', 73999, 91000), ('PKG-PREMIUM', 84999, 104000), ('PKG-ELITE', 99000, 120000)) as v(sku, e, h)
 where p.sku = v.sku;
update reglas_margen set activo = false where lower(coalesce(categoria, '')) = 'paquete_solar';
insert into reglas_margen (categoria, marca, margen_pct, margen_minimo_mxn, redondeo, activo, sobre)
values ('paquete_solar', null, 30, 0, 1, true, 'costo');

select set_config('app.starter', (select id::text from productos where sku = 'PKG-STARTER'), true),
       set_config('app.essential', (select id::text from productos where sku = 'PKG-ESSENTIAL'), true),
       set_config('app.elite', (select id::text from productos where sku = 'PKG-ELITE'), true);

-- 1) Recetas sembradas: 6 paquetes, 373 líneas, cada una con su fuente de costo, y el texto del sitio.
select set_config('app.p1', concat(
  case when (select count(distinct paquete_id) from paquete_solar_lineas l join productos p on p.id = l.paquete_id
              where p.sku like 'PKG-%') = 6
        and (select count(*) from paquete_solar_lineas l join productos p on p.id = l.paquete_id where p.sku like 'PKG-%') = 373
        and (select count(*) from productos where categoria = 'paquete_solar' and atributos -> 'receta' -> 'incluye' is not null) >= 6
       then 'ok' else 'FALLO' end, ' — 6 paquetes, 373 líneas y su texto'), true);

-- 2) Los 18 costos son los del Excel (Paquetes!B20:G20, B33:G33, B43:G43).
select set_config('app.r2', paquetes_solares()::text, true);
select set_config('app.p2', concat(
  case when (select count(*) from jsonb_array_elements(current_setting('app.r2')::jsonb) e
               join (values ('PKG-STARTER', 31963.13, 64881.41, 67621.22), ('PKG-ESSENTIAL', 39851.26, 72769.55, 75509.36),
                            ('PKG-COMFORT', 53829.26, 86747.55, 85990.68), ('PKG-PLUS', 62074.48, 111951.72, 111194.85),
                            ('PKG-PREMIUM', 69605.52, 119482.76, 118725.90), ('PKG-ELITE', 83275.56, 133152.80, 148166.95))
                    as x(sku, ic, ha, hb) on x.sku = e ->> 'sku'
              where abs((e #>> '{variantes,interconectado,costo}')::numeric - x.ic) <= 1
                and abs((e #>> '{variantes,hibrido_a,costo}')::numeric - x.ha) <= 1
                and abs((e #>> '{variantes,hibrido_b,costo}')::numeric - x.hb) <= 1) = 6
       then 'ok' else 'FALLO' end, ' — los 18 costos coinciden con el borrador'), true);

-- 3) Precios con IVA, a miles y terminados en 999: Starter 48,999 / 97,999 / 101,999; Elite 125,999 / 200,999 / 223,999.
select set_config('app.r3', costear_paquete(current_setting('app.starter')::uuid)::text, true);
select set_config('app.r3b', costear_paquete(current_setting('app.elite')::uuid)::text, true);
select set_config('app.p3', concat(
  case when (current_setting('app.r3')::jsonb #>> '{variantes,interconectado,precio}')::numeric = 48999
        and (current_setting('app.r3')::jsonb #>> '{variantes,hibrido_a,precio}')::numeric = 97999
        and (current_setting('app.r3')::jsonb #>> '{variantes,hibrido_b,precio}')::numeric = 101999
        and (current_setting('app.r3b')::jsonb #>> '{variantes,interconectado,precio}')::numeric = 125999
        and (current_setting('app.r3b')::jsonb #>> '{variantes,hibrido_a,precio}')::numeric = 200999
        and (current_setting('app.r3b')::jsonb #>> '{variantes,hibrido_b,precio}')::numeric = 223999
        and (current_setting('app.r3')::jsonb ->> 'kwp')::numeric = 2.52
       then 'ok' else 'FALLO' end, ' — precios: ',
  current_setting('app.r3')::jsonb #>> '{variantes,interconectado,precio}', ' / ',
  current_setting('app.r3')::jsonb #>> '{variantes,hibrido_a,precio}', ' / ',
  current_setting('app.r3')::jsonb #>> '{variantes,hibrido_b,precio}', ' · Elite ',
  current_setting('app.r3b')::jsonb #>> '{variantes,interconectado,precio}', ' / ',
  current_setting('app.r3b')::jsonb #>> '{variantes,hibrido_a,precio}', ' / ',
  current_setting('app.r3b')::jsonb #>> '{variantes,hibrido_b,precio}'), true);

-- 4) Nada se publica solo la primera vez: Essential sube 13 % (dentro del ±15 %) y aun así espera.
select set_config('app.r4', recalcular_paquetes()::text, true);
select set_config('app.p4', concat(
  case when (current_setting('app.r4')::jsonb ->> 'aplicados')::int = 0
        and (current_setting('app.r4')::jsonb ->> 'por_aprobar')::int = 18
        and (select (precios ->> 'estandar')::numeric from productos where sku = 'PKG-ESSENTIAL') = 53999
        and (costear_paquete(current_setting('app.essential')::uuid) #>> '{variantes,interconectado,estado}') = 'por_aprobar'
        and (select paquete_calculo is not null from productos where sku = 'PKG-ESSENTIAL')
       then 'ok' else 'FALLO' end, ' — primera vez, todo espera: ', current_setting('app.r4')), true);

-- 5) Publicar el interconectado del Starter: precio, costo y lo que dice el sitio.
select set_config('app.r5', publicar_precio_paquete(current_setting('app.starter')::uuid, 'interconectado')::text, true);
select set_config('app.p5', concat(
  case when (select (precios ->> 'estandar')::numeric = 48999 and precio = 48999 and abs(costo - 31963.13) <= 1
                    and (atributos ->> 'kw')::numeric = 2.52 and (atributos ->> 'paneles')::numeric = 4
                    and atributos ->> 'ahorro_mensual' = '$800–$1,300'
                    and descripcion like 'Paneles JA Solar 630 W%'
                    and atributos -> 'receta_publicada' ? 'estandar'
                    and (precios ->> 'hibrido')::numeric = 52000
               from productos where sku = 'PKG-STARTER')
       then 'ok' else 'FALLO' end, ' — Starter publicado con 2.52 kWp y su lista "incluye"'), true);

-- 6) Ya publicado desde la receta, un cambio chico de costo se aplica solo: panel 2,121 → 2,400 ⇒ 49,999 (+2 %).
update productos set costo = 2400 where sku = 'PSOJAS1S207';
select set_config('app.r6', recalcular_paquetes()::text, true);
select set_config('app.p6', concat(
  case when (current_setting('app.r6')::jsonb ->> 'aplicados')::int = 1
        and (select (precios ->> 'estandar')::numeric from productos where sku = 'PKG-STARTER') = 49999
        and exists (select 1 from auditoria where tabla = 'productos' and registro_id = current_setting('app.starter')::uuid
                     and accion = 'publicar_precio_paquete' and valor_nuevo ->> 'origen' = 'recalculo')
       then 'ok' else 'FALLO' end, ' — dentro del ±15 % se aplicó solo: ', current_setting('app.r6')), true);

-- 7) Publicar el híbrido B deja su propio precio (precios.hibrido_b) sin tocar el estándar.
select set_config('app.r7', publicar_precio_paquete(current_setting('app.starter')::uuid, 'hibrido_b')::text, true);
select set_config('app.p7', concat(
  case when (select (precios ->> 'hibrido_b')::numeric > 0 and (precios ->> 'estandar')::numeric = 49999
                    and atributos -> 'receta_publicada' ? 'hibrido_b'
               from productos where sku = 'PKG-STARTER')
       then 'ok' else 'FALLO' end, ' — híbrido B publicado: ', current_setting('app.r7')), true);

-- 8) Un componente desactivado: los híbridos (usan la antena LUX) no tienen precio; el interconectado sí.
update productos set activo = false where sku = 'INVLUXS128';
select set_config('app.r8', costear_paquete(current_setting('app.starter')::uuid)::text, true);
select set_config('app.p8', concat(
  case when current_setting('app.r8')::jsonb #>> '{variantes,hibrido_a,estado}' = 'falta_costo'
        and current_setting('app.r8')::jsonb #>> '{variantes,hibrido_b,estado}' = 'falta_costo'
        and current_setting('app.r8')::jsonb #>> '{variantes,hibrido_a,precio}' is null
        and (current_setting('app.r8')::jsonb #>> '{variantes,interconectado,precio}')::numeric > 0
        and current_setting('app.r8')::jsonb #>> '{variantes,hibrido_a,faltan,0,motivo}' = 'producto desactivado'
       then 'ok' else 'FALLO' end, ' — sin costo no hay precio, y dice por qué'), true);

-- 9) Quien no es admin no ve las recetas.
select set_config('request.jwt.claims',
  json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
set local role authenticated;
select set_config('app.p9', concat(
  case when (select count(*) from paquete_solar_lineas) = 0 then 'ok' else 'FALLO' end, ' — sin ser admin, nada'), true);
reset role;

select current_setting('app.p1') as resultado
union all select current_setting('app.p2')
union all select current_setting('app.p3')
union all select current_setting('app.p4')
union all select current_setting('app.p5')
union all select current_setting('app.p6')
union all select current_setting('app.p7')
union all select current_setting('app.p8')
union all select current_setting('app.p9');

-- No se prueba aquí porque lanza excepción: publicar una variante sin precio (falta costo o regla), costear un
-- producto que no es paquete, y cualquier llamada sin ser admin (o el conector, para recalcular).

rollback;
