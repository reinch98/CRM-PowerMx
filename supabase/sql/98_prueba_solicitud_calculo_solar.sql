-- ---------------------------------------------------------------------------
-- Prueba de 98_solicitud_calculo_solar.sql. Correr DESPUÉS del 98, y el bloque COMPLETO.
-- Todo va en begin/rollback: no deja nada.
-- SQL plano, sin plpgsql ni `select into` (ver "Pruebas en el editor SQL" en CLAUDE.md).
-- Se corre igual con la CLI: npx supabase db query --linked -f supabase/sql/98_prueba_solicitud_calculo_solar.sql
-- ---------------------------------------------------------------------------

begin;

select set_config('app.bot',
         coalesce((select id::text from perfiles where rol = 'bot' and coalesce(activo, true) limit 1), ''), true),
       set_config('app.admin',
         coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true),
       set_config('app.tecnico',
         coalesce((select id::text from perfiles where rol = 'tecnico' and coalesce(activo, true) limit 1), ''), true);

select set_config('app.p0',
         case when nullif(current_setting('app.bot'), '') is null then 'FALLO: no hay perfil con rol bot'
              when nullif(current_setting('app.admin'), '') is null then 'FALLO: no hay admin activo'
              when nullif(current_setting('app.tecnico'), '') is null then 'FALLO: no hay técnico activo'
              else 'ok — hay bot, admin y técnico con quienes probar' end, true);

-- Un cálculo como el que manda la calculadora con el recibo de referencia.
select set_config('app.calc', '{
  "version": 1, "fuente": "recibo", "tipo": "residencial", "tarifa": "1D", "hilos": 2,
  "servicio_ult4": "1480", "kwh_mes": 468.8, "gasto_mes": 992.66, "tarifa_efectiva": 2.699,
  "dap_mes": 59.31, "dias": 367, "crecimiento": 0.241, "fuente_gasto": "historial",
  "incremento_cfe": 0.06, "a_la_medida": false,
  "paquete": {"sku": "PKG-ESSENTIAL", "nombre": "Essential", "variante": "interconectado",
              "paneles": 6, "kw": 3.78, "precio": 53999, "cobertura": 1, "ahorro_mes": 900.71,
              "recibo_despues_mes": 91.81, "retorno_anios": 4.6},
  "avisos": ["dos_hilos", "crecimiento"],
  "historial": [{"fin": "2026-11-09", "dias": 63, "kwh": 1102, "importe": 2974.76},
                {"fin": "2026-09-07", "dias": 60, "kwh": 1074, "importe": 1570}]
}', true);

-- Un cálculo con basura: campos de más, tipos equivocados, número de servicio completo,
-- avisos con HTML y 20 periodos de historial.
select set_config('app.basura', (
  '{"kwh_mes": 500, "costo": 40000, "tarifa": "<b>1D</b>", "servicio_ult4": "773981101480",
    "paquete": {"sku": "PKG-ESSENTIAL", "precio": "53999", "nombre": "<script>x</script>"},
    "avisos": ["dos_hilos", "<img>", "x y"],
    "historial": ' || (select jsonb_agg(jsonb_build_object('kwh', g, 'fin', '2026-01-01')) from generate_series(1, 20) g)::text || '}'
), true);

-- ---- como el BOT (la cuenta que usa la Edge Function) ----
select set_config('request.jwt.claims',
         json_build_object('sub', current_setting('app.bot'), 'role', 'authenticated',
                           'email', 'bot@prueba')::text, true);
set local role authenticated;

-- 1) Con el cálculo completo: entra, lo guarda y la marca como Solar.
select set_config('app.r1', registrar_solicitud_web(
         p_nombre => 'Prueba 98 completo', p_telefono => '999 000 9801',
         p_notas => 'Desde la calculadora solar', p_origen_url => 'https://powermx.com.mx/cotizar.html',
         p_calculo => current_setting('app.calc')::jsonb)::text, true);

-- 2) Con basura: entra y se queda solo con lo que pasa la lista blanca.
select set_config('app.r2', registrar_solicitud_web(
         p_nombre => 'Prueba 98 basura', p_telefono => '999 000 9802',
         p_calculo => current_setting('app.basura')::jsonb)::text, true);

-- 3) Cálculo sin kWh y 4) cálculo que no es un objeto: la solicitud entra igual, sin cálculo.
select set_config('app.r3', registrar_solicitud_web(
         p_nombre => 'Prueba 98 sin kwh', p_telefono => '999 000 9803', p_tipos => 'Generador',
         p_calculo => '{"gasto_mes": 1000, "paquete": {"sku": "PKG-STARTER"}}'::jsonb)::text, true);
select set_config('app.r4', registrar_solicitud_web(
         p_nombre => 'Prueba 98 arreglo', p_telefono => '999 000 9804',
         p_calculo => '[1, 2, 3]'::jsonb)::text, true);

-- 5) Reintento: primero sin cálculo (función vieja), luego con él: se completa, no duplica.
select set_config('app.r5a', registrar_solicitud_web(
         p_nombre => 'Prueba 98 reintento', p_telefono => '999 000 9805', p_tipos => 'Solar',
         p_notas => 'misma nota')::text, true);
select set_config('app.r5b', registrar_solicitud_web(
         p_nombre => 'Prueba 98 reintento', p_telefono => '999 000 9805', p_tipos => 'Solar',
         p_notas => 'misma nota', p_calculo => current_setting('app.calc')::jsonb)::text, true);

-- 6) La llamada vieja, con 13 argumentos por posición, sigue sirviendo.
select set_config('app.r6', registrar_solicitud_web(
         'Prueba 98 vieja', '999 000 9806', null, 'Mérida', 'Generador', 'Residencial',
         null, null, null, null, null, 'nota vieja', null)::text, true);

-- ---- como el TÉCNICO: no ve solicitudes ----
reset role;
select set_config('request.jwt.claims',
         json_build_object('sub', current_setting('app.tecnico'), 'role', 'authenticated')::text, true);
set local role authenticated;
select set_config('app.n_tec', (select count(*) from solicitudes_web where telefono_norm like '99900098%')::text, true);

-- ---- como el ADMIN: revisa lo guardado ----
reset role;
select set_config('request.jwt.claims',
         json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);
set local role authenticated;

select set_config('app.p1', concat(
  case when (current_setting('app.r1')::jsonb ->> 'calculo') = 'true'
         and s.tipos = 'Solar'
         and (s.calculo ->> 'kwh_mes')::numeric = 468.8
         and s.calculo #>> '{paquete,sku}' = 'PKG-ESSENTIAL'
         and (s.calculo #>> '{paquete,precio}')::numeric = 53999
         and s.calculo ->> 'servicio_ult4' = '1480'
         and jsonb_array_length(s.calculo -> 'historial') = 2
         and s.calculo -> 'avisos' = '["dos_hilos", "crecimiento"]'::jsonb
       then 'ok' else 'FALLO' end,
  ' — cálculo completo guardado, tipos = ', s.tipos, ': ', s.calculo::text), true)
from solicitudes_web s where s.id = (current_setting('app.r1')::jsonb ->> 'id')::uuid;

select set_config('app.p2', concat(
  case when s.calculo is not null
         and not (s.calculo ? 'costo')
         and not (s.calculo ? 'tarifa')
         and not (s.calculo ? 'servicio_ult4')
         and not (s.calculo -> 'paquete' ? 'precio')
         and not (s.calculo -> 'paquete' ? 'nombre')
         and s.calculo #>> '{paquete,sku}' = 'PKG-ESSENTIAL'
         and s.calculo -> 'avisos' = '["dos_hilos"]'::jsonb
         and jsonb_array_length(s.calculo -> 'historial') = 12
       then 'ok' else 'FALLO' end,
  ' — la basura se descartó y quedó lo válido: ', s.calculo::text), true)
from solicitudes_web s where s.id = (current_setting('app.r2')::jsonb ->> 'id')::uuid;

select set_config('app.p3', concat(
  case when count(*) = 2 and count(s.calculo) = 0
         and bool_and(s.tipos is distinct from 'Solar' or s.telefono_norm = '9990009804')
       then 'ok' else 'FALLO' end,
  ' — sin kWh o sin objeto: entran sin cálculo (', count(*), ' solicitudes, ', count(s.calculo), ' con cálculo)'), true)
from solicitudes_web s
where s.id in ((current_setting('app.r3')::jsonb ->> 'id')::uuid, (current_setting('app.r4')::jsonb ->> 'id')::uuid);

select set_config('app.p4', concat(
  case when (current_setting('app.r5b')::jsonb ->> 'repetido') = 'true'
         and (current_setting('app.r5b')::jsonb ->> 'id') = (current_setting('app.r5a')::jsonb ->> 'id')
         and (select count(*) from solicitudes_web where telefono_norm = '9990009805') = 1
         and (select calculo #>> '{paquete,sku}' from solicitudes_web where telefono_norm = '9990009805') = 'PKG-ESSENTIAL'
       then 'ok' else 'FALLO' end,
  ' — el reintento no duplicó y completó el cálculo: ', current_setting('app.r5b')), true);

select set_config('app.p5', concat(
  case when (current_setting('app.r6')::jsonb ->> 'ok') = 'true'
         and (select calculo from solicitudes_web where telefono_norm = '9990009806') is null
       then 'ok' else 'FALLO' end,
  ' — la llamada vieja de 13 argumentos sigue sirviendo: ', current_setting('app.r6')), true);

select set_config('app.p6', concat(
  case when current_setting('app.n_tec') = '0' then 'ok' else 'FALLO' end,
  ' — el técnico ve ', current_setting('app.n_tec'), ' solicitudes'), true);

reset role;
select set_config('app.p7', concat(
  case when (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'registrar_solicitud_web') = 1
       then 'ok' else 'FALLO' end,
  ' — queda una sola registrar_solicitud_web (la firma vieja se borró)'), true);

select current_setting('app.p0') as p0, current_setting('app.p1') as p1, current_setting('app.p2') as p2,
       current_setting('app.p3') as p3, current_setting('app.p4') as p4, current_setting('app.p5') as p5,
       current_setting('app.p6') as p6, current_setting('app.p7') as p7;

rollback;
