-- ===========================================================================
-- LA REVISIÓN DE LA ORDEN (el formato de mantenimiento, en el celular)
--
-- PowerMx tiene dos trabajos distintos y no se capturan igual: **generador** y **solar**
-- (FV + BESS). El formato solar en papel (PMX-FR-MTTO-01 Rev. 2.0) trae ~55 puntos; aquí
-- va resumido a 32 en nueve secciones, con la caja de hallazgo solo cuando algo sale mal.
--
-- **Una fila por orden**, no una por punto: el técnico llena esto SIN SEÑAL y lo sube de un
-- golpe cuando vuelve la cobertura, igual que `orden_partes`. Por eso las respuestas van en
-- un `jsonb` y se escribe con `upsert`, no con veinte inserts que podrían subir a medias.
--
-- El catálogo de puntos (etiquetas, orden, qué dato numérico lleva cada uno) vive en
-- `src/lib/revision.js`, no aquí: es presentación, cambia con el formato en papel y lo
-- comparten la pantalla y el PDF. La base guarda las RESPUESTAS.
--
-- Forma de `datos`:
--   { llegada:    { clima, irradiancia, temp_ambiente },
--     puntos:     { "2.2": { v: "B"|"R"|"M"|"NA", obs, num, fotos: [rutas] }, ... },
--     mediciones: { strings: [...], ac: {...}, bess: {...} },
--     placas:     { inversor, modulos, bateria, bms },   -- rutas en el bucket
--     reporte_termico: bool,
--     dictamen:   "aprobado"|"condicionado"|"no_aprobado",
--     motivo_dictamen: text }
--
-- Se puede repetir sin problema. Prueba: 24_prueba_revision_orden.sql.
-- ===========================================================================

create table if not exists orden_revision (
  orden_id uuid primary key references ordenes_servicio(id) on delete cascade,
  tipo text not null default 'generador' check (tipo in ('generador', 'solar')),
  datos jsonb not null default '{}'::jsonb,
  actualizado_por uuid references perfiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_orden_revision_tipo on orden_revision(tipo);

-- ---------------------------------------------------------------------------
-- Quién la escribe: los dos técnicos de la orden mientras está ABIERTA, y el admin.
-- Cerrada, todos la leen y nadie la edita — igual que las partes (12).
-- ---------------------------------------------------------------------------
alter table orden_revision enable row level security;
revoke all on orden_revision from anon;

drop policy if exists "admin_orden_revision" on orden_revision;
create policy "admin_orden_revision" on orden_revision for all to authenticated
  using (es_admin()) with check (es_admin());

drop policy if exists "tecnico_lee_revision" on orden_revision;
create policy "tecnico_lee_revision" on orden_revision for select to authenticated
  using (soy_de_la_orden(orden_id));

drop policy if exists "tecnico_crea_revision" on orden_revision;
create policy "tecnico_crea_revision" on orden_revision for insert to authenticated
  with check (soy_de_la_orden(orden_id) and orden_abierta(orden_id));

drop policy if exists "tecnico_actualiza_revision" on orden_revision;
create policy "tecnico_actualiza_revision" on orden_revision for update to authenticated
  using (soy_de_la_orden(orden_id) and orden_abierta(orden_id))
  with check (soy_de_la_orden(orden_id) and orden_abierta(orden_id));

-- ---------------------------------------------------------------------------
-- Marca de tiempo y autor: no se le piden al navegador, que puede traer el reloj
-- descuadrado o mentir sobre quién escribe.
-- ---------------------------------------------------------------------------
create or replace function _sella_revision() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  new.actualizado_por := coalesce(auth.uid(), new.actualizado_por);
  return new;
end $$;

drop trigger if exists sella_revision on orden_revision;
create trigger sella_revision before insert or update on orden_revision
  for each row execute function _sella_revision();

-- ---------------------------------------------------------------------------
-- La regla del propio formato: «si cualquier punto de la Sección 3 se marca NO sin
-- control compensatorio documentado, el servicio se suspende».
--
-- Va como TRIGGER sobre `ordenes_servicio` y no dentro de `cerrar_orden` por lo mismo que
-- el horómetro (23): no hay que volver a copiar entera esa función, y así también frena
-- un cierre hecho desde la oficina.
--
-- La salida NO es un callejón: basta escribir el control compensatorio en la observación
-- de ese punto. Un técnico no se queda atrapado en el sitio, pero tampoco cierra en
-- silencio una orden que el formato manda suspender.
--
-- Lo que NO se exige aquí es la foto de los puntos en "M": esa se pide en la pantalla.
-- Bloquear el cierre por una cámara que falla dejaría al técnico sin poder terminar.
-- ---------------------------------------------------------------------------
create or replace function _seguridad_antes_de_cerrar() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_sin_control text;
begin
  if new.estado <> 'cerrada' or old.estado = 'cerrada' then
    return new;
  end if;

  select string_agg(clave, ', ' order by clave) into v_sin_control
  from (
    select p.key as clave
      from orden_revision r,
           jsonb_each(coalesce(r.datos -> 'puntos', '{}'::jsonb)) p
     where r.orden_id = new.id
       and p.key like '1.%'                                  -- sección 1: seguridad
       and (p.value ->> 'v') = 'M'                            -- "M" aquí es el "NO" del papel
       and coalesce(trim(p.value ->> 'obs'), '') = ''         -- sin control compensatorio
  ) x;

  if v_sin_control is not null then
    raise exception 'Seguridad sin resolver en % . Escribe el control compensatorio o suspende el servicio.',
      v_sin_control using errcode = '22023';
  end if;
  return new;
end $$;

drop trigger if exists seguridad_antes_de_cerrar on ordenes_servicio;
create trigger seguridad_antes_de_cerrar before update on ordenes_servicio
  for each row execute function _seguridad_antes_de_cerrar();

notify pgrst, 'reload schema';
