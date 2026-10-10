-- ===========================================================================
-- 81 · El mismo archivo no se registra dos veces (10/10/2026)
--
-- Pedido de Caña: "que el sistema no acepte imágenes o documentos repetidos". Un ticket subido
-- dos veces es un gasto contado dos veces; un comprobante de pago reusado hace pasar por cobrado
-- lo que no se cobró; un estado de cuenta leído de nuevo gasta saldo de la IA para nada.
--
-- Cómo se reconoce "el mismo archivo": por su huella SHA-256, calculada en el navegador sobre los
-- bytes ORIGINALES (antes de encoger una foto). Dos fotos distintas del mismo ticket NO son el
-- mismo archivo: ese caso lo siguen cubriendo las reglas de contenido (UUID del CFDI único, clave
-- de rastreo repetida en un cobro, huella de cada renglón del banco).
--
-- · `archivos_subidos`: cada archivo que el CRM sube a `finanzas` o `compras` deja aquí su ruta y
--   su huella (`anotar_archivo`). La bandeja de Finanzas no hace falta anotarla: `documentos` ya
--   guarda su huella desde la 67.
-- · Un archivo está "en uso" si un registro VIVO lo usa: un documento de la bandeja que no se
--   rechazó, un movimiento del libro (cobro o gasto del Expediente), un estado de cuenta o una
--   compra no cancelada. Subir un archivo para leerlo y luego no guardar no cuenta.
-- · Dos grupos que no se cruzan, porque hoy son libros distintos:
--     dinero  = bandeja de Finanzas + movimientos del libro + estados de cuenta;
--     compras = archivos de las compras (factura de material → inventario).
--   La misma factura sí puede estar en Compras (inventario) y en Finanzas (el gasto): es la
--   "doble puerta" que la parte D va a unir. Hasta entonces bloquearla rompería uno de los dos.
-- · `archivo_repetido(huella)` lo revisa ANTES de subir (y antes de gastar una lectura de IA) y
--   dice dónde está, en palabras. Los disparadores lo vuelven a revisar al guardar: el candado
--   vive en la base, no solo en la pantalla.
--
-- Fuera a propósito: fotos de los técnicos, firmas y placas (se toman en campo, sin señal; el
-- mismo archivo dos veces ahí no cuenta dinero dos veces).
-- Solo admin. Repetible.
-- ===========================================================================

create table if not exists archivos_subidos (
  bucket      text not null check (bucket in ('finanzas', 'compras')),
  ruta        text not null,
  hash        text not null check (hash ~ '^[0-9a-f]{64}$'),
  nombre      text,
  subido_por  text,
  created_at  timestamptz not null default now(),
  primary key (bucket, ruta)
);
create index if not exists idx_archivos_subidos_hash on archivos_subidos (hash);

alter table archivos_subidos enable row level security;
drop policy if exists admin_archivos_subidos on archivos_subidos;
create policy admin_archivos_subidos on archivos_subidos
  for all to authenticated using (es_admin()) with check (es_admin());
revoke all on archivos_subidos from anon;

-- Dónde está en uso un archivo, en palabras; null si no está en uso. `p_tabla`/`p_id` excluyen al
-- propio registro (al editarlo). Desde la bandeja (`p_tabla = 'documentos'`) no se mira la propia
-- bandeja: ahí el duplicado ya lo resuelve registrar_documento, que devuelve el documento que había.
create or replace function _archivo_en_uso(p_hash text, p_grupo text, p_tabla text default null, p_id uuid default null)
returns text
language plpgsql stable security definer set search_path = public as $fn$
declare
  v text;
begin
  if p_hash is null then
    return null;
  end if;

  if p_grupo = 'compras' then
    return (
      select format('en la compra %s de %s%s (registrada el %s)', c.folio, c.proveedor,
                    case when c.factura is not null then ', factura ' || c.factura else '' end,
                    to_char(c.fecha, 'DD/MM/YYYY'))
        from compras c
        join archivos_subidos a on a.bucket = 'compras' and a.ruta in (c.archivo_pdf, c.archivo_xml)
       where a.hash = p_hash and c.estado <> 'cancelada'
         and not coalesce(p_tabla = 'compras' and c.id = p_id, false)
       order by c.created_at
       limit 1);
  end if;

  -- grupo 'dinero'
  if p_tabla is distinct from 'documentos' then
    v := (select format('en la bandeja de Finanzas (%s, "%s", subido el %s)',
                        case when d.estado = 'aprobado' then 'ya aprobado' else 'por revisar' end,
                        coalesce(d.nombre_original, 'sin nombre'),
                        to_char(d.created_at at time zone 'America/Merida', 'DD/MM/YYYY'))
            from documentos d
           where d.hash_sha256 = p_hash and d.estado <> 'rechazado'
           order by d.created_at
           limit 1);
    if v is not null then
      return v;
    end if;
  end if;

  v := (select format('%s: %s del %s por %s',
                      case when m.cotizacion_id is not null
                           then 'en el expediente de la cotización ' || coalesce((select q.folio::text from cotizaciones q where q.id = m.cotizacion_id), '')
                           else 'en el libro de Finanzas' end,
                      case when m.tipo = 'ingreso' then 'un cobro' else 'un gasto' end,
                      to_char(m.fecha, 'DD/MM/YYYY'),
                      to_char(m.monto, 'FM$999,999,990.00'))
          from expediente_movimientos m
          join archivos_subidos a on a.bucket = 'finanzas' and a.ruta = m.archivo
         where a.hash = p_hash
           and not coalesce(p_tabla = 'expediente_movimientos' and m.id = p_id, false)
         order by m.created_at
         limit 1);
  if v is not null then
    return v;
  end if;

  return (
    select format('en el estado de cuenta de %s%s', coalesce(cf.nombre, 'la cuenta'),
                  case when e.periodo_desde is not null
                       then format(' del %s al %s', to_char(e.periodo_desde, 'DD/MM/YYYY'), to_char(e.periodo_hasta, 'DD/MM/YYYY'))
                       else '' end)
      from estados_cuenta e
      join archivos_subidos a on a.bucket = 'finanzas' and a.ruta = e.archivo
      left join cuentas_financieras cf on cf.id = e.cuenta_id
     where a.hash = p_hash
       and not coalesce(p_tabla = 'estados_cuenta' and e.id = p_id, false)
     order by e.created_at
     limit 1);
end $fn$;
revoke execute on function _archivo_en_uso(text, text, text, uuid) from public, anon, authenticated;

-- Para la pantalla: ¿ya está registrado? Se pregunta ANTES de subir y de leer con la IA.
create or replace function archivo_repetido(p_hash text, p_grupo text default 'dinero', p_origen text default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare
  v text;
begin
  if not es_admin() then
    raise exception 'Solo el administrador sube comprobantes.' using errcode = '42501';
  end if;
  if p_grupo not in ('dinero', 'compras') then
    raise exception 'Grupo de archivos desconocido.' using errcode = '22023';
  end if;
  v := _archivo_en_uso(lower(p_hash), p_grupo, p_origen, null);
  return jsonb_build_object('repetido', v is not null, 'donde', v);
end $fn$;

-- Lo llama la pantalla justo después de subir. Volver a subir a la misma ruta actualiza la huella.
create or replace function anotar_archivo(p_bucket text, p_ruta text, p_hash text, p_nombre text default null)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
begin
  if not es_admin() then
    raise exception 'Solo el administrador sube comprobantes.' using errcode = '42501';
  end if;
  if p_bucket not in ('finanzas', 'compras') or coalesce(trim(p_ruta), '') = ''
     or coalesce(lower(p_hash), '') !~ '^[0-9a-f]{64}$' then
    raise exception 'Datos del archivo incompletos.' using errcode = '22023';
  end if;
  insert into archivos_subidos (bucket, ruta, hash, nombre, subido_por)
  values (p_bucket, p_ruta, lower(p_hash), nullif(trim(p_nombre), ''), coalesce(auth.jwt() ->> 'email', 'crm'))
  on conflict (bucket, ruta) do update
     set hash = excluded.hash, nombre = excluded.nombre, subido_por = excluded.subido_por, created_at = now();
  return jsonb_build_object('ok', true);
end $fn$;

revoke execute on function archivo_repetido(text, text, text), anotar_archivo(text, text, text, text) from public, anon;
grant execute on function archivo_repetido(text, text, text), anotar_archivo(text, text, text, text) to authenticated;

-- ---- los candados al guardar ----

create or replace function _rechazar_si_repetido(p_hash text, p_grupo text, p_tabla text, p_id uuid) returns void
language plpgsql stable security definer set search_path = public as $fn$
declare
  v text := _archivo_en_uso(p_hash, p_grupo, p_tabla, p_id);
begin
  if v is not null then
    raise exception 'Ese archivo ya está registrado %. No se registró otra vez.', v using errcode = '22023';
  end if;
end $fn$;
revoke execute on function _rechazar_si_repetido(text, text, text, uuid) from public, anon, authenticated;

-- Movimientos del libro y estados de cuenta: su archivo vive en `finanzas`.
create or replace function _archivo_no_repetido_finanzas() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  if new.archivo is not null and (tg_op = 'INSERT' or new.archivo is distinct from old.archivo) then
    perform _rechazar_si_repetido(
      (select a.hash from archivos_subidos a where a.bucket = 'finanzas' and a.ruta = new.archivo),
      'dinero', tg_table_name, new.id);
  end if;
  return new;
end $fn$;

drop trigger if exists archivo_no_repetido on expediente_movimientos;
create trigger archivo_no_repetido before insert or update of archivo on expediente_movimientos
  for each row execute function _archivo_no_repetido_finanzas();
drop trigger if exists archivo_no_repetido on estados_cuenta;
create trigger archivo_no_repetido before insert or update of archivo on estados_cuenta
  for each row execute function _archivo_no_repetido_finanzas();

-- La bandeja: su huella contra los movimientos y los estados de cuenta.
create or replace function _archivo_no_repetido_documento() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  if new.estado <> 'rechazado' then
    perform _rechazar_si_repetido(lower(new.hash_sha256), 'dinero', 'documentos', new.id);
  end if;
  return new;
end $fn$;
drop trigger if exists archivo_no_repetido on documentos;
create trigger archivo_no_repetido before insert on documentos
  for each row execute function _archivo_no_repetido_documento();

-- Compras: el PDF o el XML de una factura, contra las demás compras.
create or replace function _archivo_no_repetido_compra() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  if new.archivo_pdf is not null and (tg_op = 'INSERT' or new.archivo_pdf is distinct from old.archivo_pdf) then
    perform _rechazar_si_repetido(
      (select a.hash from archivos_subidos a where a.bucket = 'compras' and a.ruta = new.archivo_pdf),
      'compras', 'compras', new.id);
  end if;
  if new.archivo_xml is not null and (tg_op = 'INSERT' or new.archivo_xml is distinct from old.archivo_xml) then
    perform _rechazar_si_repetido(
      (select a.hash from archivos_subidos a where a.bucket = 'compras' and a.ruta = new.archivo_xml),
      'compras', 'compras', new.id);
  end if;
  return new;
end $fn$;
drop trigger if exists archivo_no_repetido on compras;
create trigger archivo_no_repetido before insert or update of archivo_pdf, archivo_xml on compras
  for each row execute function _archivo_no_repetido_compra();

insert into _migraciones (archivo, tipo) values ('81_archivos_repetidos.sql', 'esquema')
on conflict (archivo) do nothing;
