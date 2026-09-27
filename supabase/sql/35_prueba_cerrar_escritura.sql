-- ---------------------------------------------------------------------------
-- Prueba de 35_cerrar_escritura.sql. Correr DESPUÉS del 35, y el bloque COMPLETO.
-- Todo va en begin/rollback: no deja nada.
--
-- SQL plano, sin plpgsql (ver "Pruebas en el editor SQL" en CLAUDE.md).
--
-- POR QUÉ SE PRUEBA `update` Y NO `insert`. Un `insert` que RLS rechaza **lanza excepción**
-- («new row violates row-level security policy»), y atrapar una excepción exige plpgsql, que
-- el editor de Supabase mutila. Un `update` que RLS rechaza, en cambio, no falla: simplemente
-- no toca ninguna fila, y eso se puede contar con un CTE `returning`. Es la misma puerta: si
-- el técnico no puede modificar un renglón sembrado, tampoco puede insertar uno.
-- La configuración del `insert` se revisa aparte, en la consulta final.
-- ---------------------------------------------------------------------------

begin;

-- Un renglón sembrado desde el editor (que se salta RLS) para tener qué intentar modificar.
select set_config('app.valor', concat('PRUEBA-35-', gen_random_uuid()::text), true);

insert into catalogos (tipo, valor) values ('prueba_35', current_setting('app.valor'));

-- Y un renglón de auditoría sembrado igual. Sin él, "el técnico ve 0" no probaría nada: podría
-- ser que la tabla estuviera vacía. Con él, 0 para el técnico y 1 para el admin sí es la prueba.
insert into auditoria (tabla, accion, origen) values ('prueba_35', 'prueba', 'prueba_35');

-- Y el técnico con el que se va a intentar.
select set_config('app.tecnico',
         coalesce((select id::text from perfiles where rol = 'tecnico' and coalesce(activo, true) limit 1), ''), true);

select set_config('app.p0',
         case when nullif(current_setting('app.tecnico'), '') is null
              then 'FALLO: no hay ningún técnico activo con el que probar'
              else 'ok — renglón de catalogos sembrado y técnico elegido' end, true);

-- ---- como TÉCNICO ----
select set_config('request.jwt.claims',
         json_build_object('sub', current_setting('app.tecnico'), 'role', 'authenticated')::text, true);

set local role authenticated;

-- 1) Leer catalogos sí se puede: es una tabla de catálogos y se dejó abierta a propósito.
select set_config('app.p1', concat(
         case when (select count(*) from catalogos where tipo = 'prueba_35') = 1 then 'ok' else 'FALLO' end,
         ' — el técnico ve ', (select count(*) from catalogos where tipo = 'prueba_35'),
         ' renglón(es) de prueba en catalogos (leer está permitido)'), true);

-- 2) Modificarlo NO. Antes de la 35 esto cambiaba la fila (la política decía `using (true)`).
with intento as (
  update catalogos set valor = 'MODIFICADO POR EL TECNICO'
  where tipo = 'prueba_35' returning 1
)
select set_config('app.p2', concat(
         case when (select count(*) from intento) = 0 then 'ok' else 'FALLO' end,
         ' — el técnico modificó ', (select count(*) from intento),
         ' renglón(es) de catalogos (debe ser 0)'), true);

-- 3) Borrarlo tampoco (nunca hubo política de delete; se comprueba para que quede escrito).
with intento as (
  delete from catalogos where tipo = 'prueba_35' returning 1
)
select set_config('app.p3', concat(
         case when (select count(*) from intento) = 0 then 'ok' else 'FALLO' end,
         ' — el técnico borró ', (select count(*) from intento),
         ' renglón(es) de catalogos (debe ser 0)'), true);

-- 4) La auditoría no la lee: es solo del admin. Hay un renglón sembrado, así que el 0 pesa.
select set_config('app.p4', concat(
         case when (select count(*) from auditoria where origen = 'prueba_35') = 0 then 'ok' else 'FALLO' end,
         ' — el técnico ve ', (select count(*) from auditoria where origen = 'prueba_35'),
         ' del renglón sembrado en auditoria (debe ser 0)'), true);

-- 5) Ni lo modifica (nunca hubo política de update; sin poder verlo ya no podría).
with intento as (
  update auditoria set accion = 'ALTERADO' where origen = 'prueba_35' returning 1
)
select set_config('app.p5', concat(
         case when (select count(*) from intento) = 0 then 'ok' else 'FALLO' end,
         ' — el técnico alteró ', (select count(*) from intento),
         ' renglones de auditoria (debe ser 0: un rastro que se puede editar no es rastro)'), true);

reset role;

-- ---- como ADMIN: que no se haya cerrado de más ----
select set_config('request.jwt.claims',
         json_build_object('sub', (select id::text from perfiles where rol = 'admin' limit 1),
                           'role', 'authenticated')::text, true);

set local role authenticated;

with intento as (
  update catalogos set valor = current_setting('app.valor')
  where tipo = 'prueba_35' returning 1
)
select set_config('app.p6', concat(
         case when (select count(*) from intento) = 1 then 'ok' else 'FALLO' end,
         ' — el admin modificó ', (select count(*) from intento),
         ' renglón(es) de catalogos (debe poder: es quien mantiene el catálogo)'), true);

select set_config('app.p7', concat(
         case when (select count(*) from auditoria where origen = 'prueba_35') = 1 then 'ok' else 'FALLO' end,
         ' — el admin ve ', (select count(*) from auditoria where origen = 'prueba_35'),
         ' del renglón sembrado en auditoria (debe ver 1: no se cerró de más)'), true);

reset role;

-- ---- lo que no se puede probar con un intento, se revisa en la configuración ----
-- Ninguna política de escritura debe quedar con la condición en `true`: un `insert` rechazado
-- lanza excepción y atraparla exigiría plpgsql, así que aquí se comprueba la regla.
select set_config('app.p8', concat(
         case when (select count(*) from pg_policies
                    where schemaname = 'public' and tablename in ('catalogos', 'auditoria')
                      and cmd in ('INSERT', 'UPDATE', 'ALL')
                      and coalesce(with_check, qual, 'true') = 'true') = 0
              then 'ok' else 'FALLO' end,
         ' — políticas de escritura con la condición en `true`: ',
         (select count(*) from pg_policies
          where schemaname = 'public' and tablename in ('catalogos', 'auditoria')
            and cmd in ('INSERT', 'UPDATE', 'ALL')
            and coalesce(with_check, qual, 'true') = 'true'),
         ' (debe ser 0)'), true);

-- Y que a `anon` no le quede nada en el esquema público.
select set_config('app.p9', concat(
         case when (select count(*) from information_schema.role_table_grants
                    where table_schema = 'public' and grantee::text = 'anon') = 0
              then 'ok' else 'FALLO' end,
         ' — privilegios de anon en el esquema público: ',
         (select count(*) from information_schema.role_table_grants
          where table_schema = 'public' and grantee::text = 'anon'),
         ' (debe ser 0)'), true);

select current_setting('app.p0', true) as resultado
union all select current_setting('app.p1', true)
union all select current_setting('app.p2', true)
union all select current_setting('app.p3', true)
union all select current_setting('app.p4', true)
union all select current_setting('app.p5', true)
union all select current_setting('app.p6', true)
union all select current_setting('app.p7', true)
union all select current_setting('app.p8', true)
union all select current_setting('app.p9', true);

rollback;
