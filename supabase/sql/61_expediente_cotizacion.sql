-- ---------------------------------------------------------------------------
-- 61_expediente_cotizacion.sql — el expediente de ingresos y egresos de cada cotización.
--
--   INGRESO  = la cotización (su base sin IVA). Los COBROS se registran uno por uno y cada uno se
--              comprueba con su operación bancaria (foto o PDF).
--   EGRESOS  = (a) el MATERIAL, que dicta la cotización: sus partidas con producto × el costo real
--              de cada pieza; no se captura aparte porque las facturas entran al almacén general
--              (Compras) y lo que no se usa se queda ahí; (b) lo demás se captura en el expediente:
--              gasolina, uso del vehículo, pago de técnicos, viáticos y otros, cada uno con su
--              ticket o PDF si lo hay.
--   UTILIDAD = base sin IVA − material − otros egresos sin IVA. Los tickets sin factura cuentan
--              completos (su IVA no se recupera); un gasto con factura registra su IVA aparte.
--
-- Al CERRAR se congela una foto de las cifras (el costo del catálogo puede cambiar después sin
-- mover la utilidad de un trabajo ya cerrado). Cerrado, no se tocan sus movimientos ni las
-- partidas de la cotización; para cambiar algo se REABRE con un motivo, que queda en auditoría.
--
-- Solo admin: aquí vive el dinero. Repetible.
-- ---------------------------------------------------------------------------

alter table cotizaciones add column if not exists expediente_cerrado_en  timestamptz;
alter table cotizaciones add column if not exists expediente_cerrado_por text;
alter table cotizaciones add column if not exists expediente_cierre      jsonb;

create table if not exists expediente_movimientos (
  id uuid primary key default gen_random_uuid(),
  cotizacion_id uuid not null references cotizaciones(id) on delete cascade,
  tipo text not null check (tipo in ('ingreso', 'egreso')),
  categoria text not null check (categoria in ('cobro', 'gasolina', 'vehiculo', 'tecnico', 'viaticos', 'otro')),
  fecha date not null default current_date,
  concepto text,
  monto numeric(14, 2) not null check (monto > 0),      -- lo que se pagó o se cobró, con IVA
  iva numeric(14, 2) not null default 0 check (iva >= 0), -- IVA acreditable de un egreso con factura
  forma text,                                           -- cobro: transferencia | deposito | cheque | efectivo
  referencia text,                                      -- clave de rastreo, folio de ficha…
  tecnico_id uuid references perfiles(id),              -- pago de técnico: a quién
  archivo text,                                         -- ruta en el bucket `finanzas`
  archivo_nombre text,
  notas text,
  creado_por text,
  created_at timestamptz not null default now(),
  constraint expediente_tipo_categoria check ((tipo = 'ingreso') = (categoria = 'cobro')),
  constraint expediente_iva_no_excede check (iva <= monto)
);
create index if not exists idx_expediente_cot on expediente_movimientos(cotizacion_id, fecha);

alter table expediente_movimientos enable row level security;
drop policy if exists admin_expediente on expediente_movimientos;
create policy admin_expediente on expediente_movimientos for all to authenticated
  using (es_admin()) with check (es_admin());
revoke all on expediente_movimientos from anon;
grant select, insert, update, delete on expediente_movimientos to authenticated;

-- Con el expediente cerrado nadie agrega, cambia ni borra movimientos.
create or replace function _expediente_cerrado_bloquea() returns trigger
language plpgsql as $$
declare
  v_cot uuid;
begin
  v_cot := coalesce(new.cotizacion_id, old.cotizacion_id);
  if (select expediente_cerrado_en from cotizaciones where id = v_cot) is not null then
    raise exception 'El expediente está cerrado. Reábrelo para cambiar sus movimientos.' using errcode = '22023';
  end if;
  return coalesce(new, old);
end;
$$;
drop trigger if exists expediente_cerrado_bloquea on expediente_movimientos;
create trigger expediente_cerrado_bloquea before insert or update or delete on expediente_movimientos
  for each row execute function _expediente_cerrado_bloquea();

-- Y la cotización ya cerrada no cambia sus partidas ni sus importes: la foto del cierre dejaría
-- de corresponder a lo que se vendió.
create or replace function _cotizacion_cerrada_bloquea() returns trigger
language plpgsql as $$
begin
  if old.expediente_cerrado_en is not null and new.expediente_cerrado_en is not null
     and (new.partidas, new.subtotal, new.descuento, new.iva, new.total)
         is distinct from (old.partidas, old.subtotal, old.descuento, old.iva, old.total) then
    raise exception 'Su expediente está cerrado: reábrelo antes de cambiar las partidas o los importes.' using errcode = '22023';
  end if;
  return new;
end;
$$;
drop trigger if exists cotizacion_cerrada_bloquea on cotizaciones;
create trigger cotizacion_cerrada_bloquea before update on cotizaciones
  for each row execute function _cotizacion_cerrada_bloquea();

-- ---- el bucket de los comprobantes: privado y solo admin (aquí hay dinero) ----
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('finanzas', 'finanzas', false, 10485760,
        array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do update
  set file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "finanzas_lee"       on storage.objects;
drop policy if exists "finanzas_sube"      on storage.objects;
drop policy if exists "finanzas_actualiza" on storage.objects;
create policy "finanzas_lee" on storage.objects for select to authenticated
  using (bucket_id = 'finanzas' and public.es_admin());
create policy "finanzas_sube" on storage.objects for insert to authenticated
  with check (bucket_id = 'finanzas' and public.es_admin());
create policy "finanzas_actualiza" on storage.objects for update to authenticated
  using (bucket_id = 'finanzas' and public.es_admin())
  with check (bucket_id = 'finanzas' and public.es_admin());

-- ---------------------------------------------------------------------------
-- expediente_resumen(cotización): todas las cifras en un jsonb. Una sola fórmula, aquí: la
-- pantalla solo la muestra. Con el expediente cerrado, el material sale de la foto del cierre.
-- ---------------------------------------------------------------------------
create or replace function expediente_resumen(p_cotizacion uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_c cotizaciones%rowtype;
  v_base numeric;
  v_cobrado numeric;
  v_comprobado numeric;
  v_sin_comprobar int;
  v_material jsonb;
  v_material_total numeric;
  v_sin_costo int;
  v_otros numeric;
  v_por_cat jsonb;
  v_utilidad numeric;
  v_avisos text[] := '{}';
  v_hay_tecnico boolean;
begin
  if not es_admin() then
    raise exception 'Solo el administrador ve el expediente.' using errcode = '42501';
  end if;
  v_c := (select c from cotizaciones c where c.id = p_cotizacion);
  if v_c.id is null then
    raise exception 'Esa cotización ya no existe.' using errcode = '22023';
  end if;

  v_base := coalesce(v_c.total, 0) - coalesce(v_c.iva, 0);          -- subtotal − descuento

  v_cobrado := coalesce((select sum(monto) from expediente_movimientos
                          where cotizacion_id = p_cotizacion and tipo = 'ingreso'), 0);
  v_comprobado := coalesce((select sum(monto) from expediente_movimientos
                             where cotizacion_id = p_cotizacion and tipo = 'ingreso' and archivo is not null), 0);
  v_sin_comprobar := (select count(*) from expediente_movimientos
                       where cotizacion_id = p_cotizacion and tipo = 'ingreso' and archivo is null);

  if v_c.expediente_cerrado_en is not null and v_c.expediente_cierre ? 'material' then
    v_material := v_c.expediente_cierre -> 'material' -> 'lineas';
  else
    v_material := coalesce((
      select jsonb_agg(jsonb_build_object(
               'producto_id', q.pid, 'sku', p.sku, 'nombre', p.nombre, 'cantidad', q.cant,
               'costo_unitario', coalesce(p.costo, 0), 'importe', round(q.cant * coalesce(p.costo, 0), 2),
               'sin_costo', coalesce(p.costo, 0) = 0) order by p.sku)
        from (select (e ->> 'producto_id')::uuid as pid, sum((e ->> 'cantidad')::numeric) as cant
                from jsonb_array_elements(v_c.partidas) e
               where nullif(e ->> 'producto_id', '') is not null
               group by 1) q
        join productos p on p.id = q.pid), '[]'::jsonb);
  end if;
  v_material_total := coalesce((select sum((l ->> 'importe')::numeric) from jsonb_array_elements(v_material) l), 0);
  v_sin_costo := (select count(*) from jsonb_array_elements(v_material) l where (l ->> 'sin_costo')::boolean);

  v_por_cat := coalesce((
    select jsonb_object_agg(categoria, jsonb_build_object('n', n, 'monto', monto, 'sin_iva', sin_iva))
      from (select categoria, count(*) as n, sum(monto) as monto, sum(monto - iva) as sin_iva
              from expediente_movimientos
             where cotizacion_id = p_cotizacion and tipo = 'egreso'
             group by categoria) x), '{}'::jsonb);
  v_otros := coalesce((select sum(monto - iva) from expediente_movimientos
                        where cotizacion_id = p_cotizacion and tipo = 'egreso'), 0);
  v_hay_tecnico := exists (select 1 from expediente_movimientos
                            where cotizacion_id = p_cotizacion and categoria = 'tecnico');

  v_utilidad := v_base - v_material_total - v_otros;

  -- Avisos (no impiden cerrar; se muestran para cerrar con conocimiento).
  if v_c.estado <> 'aceptada' then
    v_avisos := v_avisos || format('La cotización está en estado %s, no Aceptada.', v_c.estado);
  end if;
  if v_c.total - v_cobrado > 0.009 then
    v_avisos := v_avisos || format('Falta cobrar $%s.', to_char(v_c.total - v_cobrado, 'FM999,999,990.00'));
  end if;
  if v_sin_comprobar > 0 then
    v_avisos := v_avisos || format('%s cobro(s) sin comprobante bancario.', v_sin_comprobar);
  end if;
  if v_sin_costo > 0 then
    v_avisos := v_avisos || format('%s pieza(s) de la cotización sin costo capturado: la utilidad sale inflada.', v_sin_costo);
  end if;
  if not v_hay_tecnico then
    v_avisos := array_append(v_avisos, 'No hay pago de técnicos capturado.'::text);
  end if;

  return jsonb_build_object(
    'folio', v_c.folio, 'estado', v_c.estado,
    'cerrado', v_c.expediente_cerrado_en is not null, 'cerrado_en', v_c.expediente_cerrado_en,
    'ingreso', jsonb_build_object(
      'base', v_base, 'iva', coalesce(v_c.iva, 0), 'total', coalesce(v_c.total, 0),
      'cobrado', v_cobrado, 'comprobado', v_comprobado,
      'por_cobrar', greatest(coalesce(v_c.total, 0) - v_cobrado, 0)),
    'material', jsonb_build_object('lineas', v_material, 'total', v_material_total, 'sin_costo', v_sin_costo),
    'egresos', jsonb_build_object('por_categoria', v_por_cat, 'total_sin_iva', v_otros),
    'utilidad', v_utilidad,
    'margen_pct', case when v_base > 0 then round(v_utilidad / v_base * 100, 1) else null end,
    'avisos', to_jsonb(v_avisos));
end;
$$;

-- ---------------------------------------------------------------------------
-- cerrar_expediente: congela las cifras. Con avisos pendientes no cierra salvo que se pida
-- (p_forzar): cerrar con algo sin comprobar es una decisión, no un descuido.
-- ---------------------------------------------------------------------------
create or replace function cerrar_expediente(p_cotizacion uuid, p_forzar boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_c cotizaciones%rowtype;
  v_r jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador cierra expedientes.' using errcode = '42501';
  end if;
  v_c := (select c from cotizaciones c where c.id = p_cotizacion);
  if v_c.id is null then
    raise exception 'Esa cotización ya no existe.' using errcode = '22023';
  end if;
  if v_c.expediente_cerrado_en is not null then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;

  v_r := expediente_resumen(p_cotizacion);
  if jsonb_array_length(v_r -> 'avisos') > 0 and not p_forzar then
    return jsonb_build_object('ok', false, 'avisos', v_r -> 'avisos', 'resumen', v_r);
  end if;

  update cotizaciones
     set expediente_cerrado_en = now(),
         expediente_cerrado_por = coalesce(auth.jwt() ->> 'email', 'crm'),
         expediente_cierre = v_r
   where id = p_cotizacion;
  perform _apunta('cotizaciones', p_cotizacion, 'cerrar_expediente', null,
                  jsonb_build_object('utilidad', v_r -> 'utilidad', 'margen_pct', v_r -> 'margen_pct',
                                     'avisos', v_r -> 'avisos'), 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false, 'resumen', v_r);
end;
$$;

create or replace function reabrir_expediente(p_cotizacion uuid, p_motivo text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_c cotizaciones%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador reabre expedientes.' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_motivo, ''))) < 3 then
    raise exception 'Escribe por qué se reabre el expediente.' using errcode = '22023';
  end if;
  v_c := (select c from cotizaciones c where c.id = p_cotizacion);
  if v_c.id is null then
    raise exception 'Esa cotización ya no existe.' using errcode = '22023';
  end if;
  if v_c.expediente_cerrado_en is null then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;
  perform _apunta('cotizaciones', p_cotizacion, 'reabrir_expediente',
                  jsonb_build_object('cerrado_en', v_c.expediente_cerrado_en,
                                     'utilidad', v_c.expediente_cierre -> 'utilidad'),
                  jsonb_build_object('motivo', trim(p_motivo)), 'oficina');
  update cotizaciones
     set expediente_cerrado_en = null, expediente_cerrado_por = null, expediente_cierre = null
   where id = p_cotizacion;
  return jsonb_build_object('ok', true, 'sin_cambio', false);
end;
$$;

revoke all on function expediente_resumen(uuid) from public;
revoke all on function expediente_resumen(uuid) from anon;
revoke all on function cerrar_expediente(uuid, boolean) from public;
revoke all on function cerrar_expediente(uuid, boolean) from anon;
revoke all on function reabrir_expediente(uuid, text) from public;
revoke all on function reabrir_expediente(uuid, text) from anon;
grant execute on function expediente_resumen(uuid) to authenticated;
grant execute on function cerrar_expediente(uuid, boolean) to authenticated;
grant execute on function reabrir_expediente(uuid, text) to authenticated;

notify pgrst, 'reload schema';
