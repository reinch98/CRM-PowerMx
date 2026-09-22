-- ===========================================================================
-- FASE 4 · PDF DE LA ORDEN Y SU ENVÍO
--
-- El PDF se genera en el NAVEGADOR del admin (con jsPDF), no en una función: no hay CLI de
-- Supabase instalada y este documento no necesita datos que el admin no tenga ya. Se sube al
-- bucket `ordenes` que ya existe (sus políticas de storage ya cubren admin).
--
--   · Copia del CLIENTE: solo el trabajo realizado (las piezas se ven en la cotización).
--   · Copia INTERNA, al expediente: agrega el material usado. Sin costos: `orden_surtido`
--     nunca los tuvo.
--   · Ambas se guardan (y se reemplazan al regenerar) en
--     `expedientes/<cliente_id>/OS-<folio>-<tipo>.pdf`; `ordenes_pdf` lleva un registro,
--     uno por tipo y orden (upsert).
--   · "Enviar al cliente" es manual (sin la API de WhatsApp todavía: ver CLAUDE.md). Cada
--     envío guarda una copia fechada en `enviados/<AAAA>-S<ss>/OS-<folio>-<marca de
--     tiempo>.pdf` (semana en hora de Mérida) y una fila en `envios_orden` con los
--     destinatarios, para cuando exista el envío automático.
--
--   · El admin puede marcar una orden con "enviar al cerrar" (`ordenes_servicio.enviar_al_cerrar`),
--     desde que la ve, sin esperar a que se cierre. Es un recordatorio, no un envío automático
--     de verdad (el PDF se arma en el navegador del admin, nadie lo hace por su cuenta): al
--     cerrarse, la pantalla lo resalta y abre el panel de envío solo; al registrar el envío la
--     marca se apaga sola.
--
-- Solo admin: sin funciones, acceso directo con RLS (como Contactos; `ordenes_servicio` ya
-- tiene su política "admin_ordenes" para todo). Se puede repetir sin problema.
-- Prueba: 20_prueba_pdf_orden.sql.
-- ===========================================================================

alter table ordenes_servicio add column if not exists enviar_al_cerrar boolean not null default false;

create table if not exists ordenes_pdf (
  id uuid primary key default gen_random_uuid(),
  orden_id uuid not null references ordenes_servicio(id) on delete cascade,
  tipo text not null check (tipo in ('cliente', 'interno')),
  ruta text not null,
  generado_por text,
  generado_en timestamptz not null default now(),
  unique (orden_id, tipo)      -- se reemplaza (upsert) al regenerar; no se duplica
);

create table if not exists envios_orden (
  id uuid primary key default gen_random_uuid(),
  folio bigint generated always as identity unique,
  orden_id uuid not null references ordenes_servicio(id),
  ruta text not null,                                  -- la copia fechada que se mandó
  semana text not null,                                -- 'AAAA-Wss', para ver por carpeta
  destinatarios jsonb not null default '[]'::jsonb,    -- [{contacto_id, nombre, telefono}]
  enviado_por text,
  enviado_en timestamptz not null default now()
);

create index if not exists idx_ordenes_pdf_orden on ordenes_pdf(orden_id);
create index if not exists idx_envios_orden_orden on envios_orden(orden_id);

alter table ordenes_pdf enable row level security;
alter table envios_orden enable row level security;
revoke all on ordenes_pdf, envios_orden from anon;

drop policy if exists "admin_ordenes_pdf" on ordenes_pdf;
create policy "admin_ordenes_pdf" on ordenes_pdf for all to authenticated
  using (es_admin()) with check (es_admin());

drop policy if exists "admin_envios_orden" on envios_orden;
create policy "admin_envios_orden" on envios_orden for all to authenticated
  using (es_admin()) with check (es_admin());

notify pgrst, 'reload schema';

-- Verificación: RLS puesto en las dos tablas y la columna nueva en ordenes_servicio.
select 'rls ordenes_pdf' as que, relrowsecurity::text as ok from pg_class where relname = 'ordenes_pdf'
union all
select 'rls envios_orden', relrowsecurity::text from pg_class where relname = 'envios_orden'
union all
select 'ordenes_servicio.enviar_al_cerrar',
       exists (select 1 from information_schema.columns
                where table_name = 'ordenes_servicio' and column_name = 'enviar_al_cerrar')::text;
