-- ============================================================================
-- 67 · Libro financiero único, bandeja de documentos, CFDI y comisiones del técnico (F1)
--
-- Requiere el 66 (pago a técnicos) ya aplicado. Orden de despliegue: SQL primero, código después.
--
-- Decisiones (Caña, 09/10/2026):
--   · RESICO persona física con IVA mensual: ISR sobre lo COBRADO, IVA por flujo de efectivo. Por eso
--     un movimiento se fecha el día que se pagó o se cobró, no el de la factura.
--   · Lo personal NO vive aquí. Solo existen `retiro_dueno` y `aportacion` (dinero que sale del
--     negocio hacia ti, o que pones tú), para que la caja cuadre sin mezclar gastos personales.
--   · Las facturas se emiten desde el portal del SAT; aquí se sube el XML y se liga a la cotización.
--
-- Qué hace:
--   1. `expediente_movimientos` pasa a ser el libro único: `cotizacion_id` ya es opcional (gastos
--      generales: renta, software, comisiones…) y gana cuenta, CFDI, documento y compra.
--      El expediente de una cotización no cambia: solo suma lo que tiene su `cotizacion_id`.
--   2. `cuentas_financieras` (Banorte negocio, efectivo…), `empresa_fiscal` (tu RFC), `cfdi`,
--      `documentos` (la bandeja y su bitácora) y `reglas_clasificacion` (aprende del proveedor).
--   3. Un CFDI recibido que aún no se paga NO genera movimiento: queda como "por pagar" (F4).
--   4. `registrar_pago_tecnico` (66) ahora también carga al libro lo que no tiene cotización.
--   5. `mis_comisiones()`: lo que ve el técnico de sus propias comisiones, solo después de que el
--      administrador aprueba el pago. Nunca ve lo de otro técnico.
-- ============================================================================

-- ---- tu RFC (una sola fila) ----

create table if not exists empresa_fiscal (
  id               boolean primary key default true check (id),
  rfc              text check (rfc is null or rfc ~ '^[A-ZÑ&]{3,4}[0-9]{6}[A-Z0-9]{3}$'),
  razon_social     text,
  regimen_fiscal   text default '626',
  cp_expedicion    text check (cp_expedicion is null or cp_expedicion ~ '^[0-9]{5}$'),
  updated_at       timestamptz not null default now()
);
insert into empresa_fiscal (id) values (true) on conflict (id) do nothing;

-- ---- de dónde sale o a dónde entra el dinero ----

create table if not exists cuentas_financieras (
  id             uuid primary key default gen_random_uuid(),
  nombre         text not null,
  tipo           text not null default 'banco' check (tipo in ('banco', 'efectivo', 'tarjeta', 'otra')),
  banco          text,
  ultimos4       text check (ultimos4 is null or ultimos4 ~ '^[0-9]{4}$'),
  activa         boolean not null default true,
  created_at     timestamptz not null default now()
);
create unique index if not exists cuentas_financieras_nombre on cuentas_financieras (lower(nombre));
insert into cuentas_financieras (nombre, tipo, banco)
select 'Banorte negocio', 'banco', 'Banorte'
 where not exists (select 1 from cuentas_financieras where lower(nombre) = 'banorte negocio');
insert into cuentas_financieras (nombre, tipo)
select 'Efectivo', 'efectivo'
 where not exists (select 1 from cuentas_financieras where lower(nombre) = 'efectivo');

-- ---- CFDI: lo que dice el XML, leído sin IA ----

create table if not exists cfdi (
  id               uuid primary key default gen_random_uuid(),
  uuid_fiscal      text not null unique check (uuid_fiscal ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
  sentido          text not null check (sentido in ('emitido', 'recibido')),
  tipo_comprobante text not null default 'I' check (tipo_comprobante in ('I', 'E', 'P', 'N', 'T')),
  serie            text,
  folio            text,
  fecha            timestamptz not null,
  rfc_emisor       text not null,
  nombre_emisor    text,
  regimen_emisor   text,
  rfc_receptor     text not null,
  nombre_receptor  text,
  uso_cfdi         text,
  subtotal         numeric(14, 2) not null default 0,
  descuento        numeric(14, 2) not null default 0,
  total            numeric(14, 2) not null default 0,
  iva_trasladado   numeric(14, 2) not null default 0,
  isr_retenido     numeric(14, 2) not null default 0,
  iva_retenido     numeric(14, 2) not null default 0,
  moneda           text not null default 'MXN',
  tipo_cambio      numeric(14, 6),
  metodo_pago      text,            -- PUE | PPD
  forma_pago       text,            -- clave SAT (01 efectivo, 03 transferencia…)
  lugar_expedicion text,
  conceptos        jsonb not null default '[]'::jsonb,
  relacionados     jsonb not null default '[]'::jsonb,   -- UUID relacionados / documentos de un complemento de pago
  archivo_xml      text,            -- ruta en el bucket `finanzas`
  estado_sat       text not null default 'no_verificado' check (estado_sat in ('no_verificado', 'vigente', 'cancelado')),
  cliente_id       uuid references clientes(id),
  cotizacion_id    uuid references cotizaciones(id),
  compra_id        uuid references compras(id),
  documento_id     uuid,
  creado_por       text,
  created_at       timestamptz not null default now()
);
create index if not exists idx_cfdi_fecha on cfdi (sentido, fecha);
create index if not exists idx_cfdi_cotizacion on cfdi (cotizacion_id);

-- ---- documentos: la bandeja y la bitácora ----

create table if not exists documentos (
  id               uuid primary key default gen_random_uuid(),
  tipo             text not null default 'otro'
                   check (tipo in ('cfdi_xml', 'factura_pdf', 'ticket', 'estado_cuenta', 'comprobante_cobro', 'otro')),
  archivo          text not null,                      -- ruta en el bucket `finanzas`
  nombre_original  text,
  mime             text,
  hash_sha256      text not null unique,               -- el mismo archivo no entra dos veces
  estado           text not null default 'pendiente'
                   check (estado in ('pendiente', 'propuesto', 'aprobado', 'rechazado')),
  metodo           text not null default 'manual' check (metodo in ('xml', 'ia', 'manual')),
  extraido         jsonb,                               -- lo que leyó el parser o la IA, tal cual
  propuesta        jsonb,                               -- la clasificación que se le propuso al admin
  validaciones     jsonb not null default '[]'::jsonb,  -- avisos: no cuadra, repetido…
  correccion       jsonb,                               -- lo que el admin cambió de la propuesta
  modelo           text,
  cfdi_id          uuid references cfdi(id),
  movimiento_id    uuid references expediente_movimientos(id) on delete set null,
  motivo_rechazo   text,
  subido_por       text,
  aprobado_por     text,
  aprobado_en      timestamptz,
  created_at       timestamptz not null default now()
);
create index if not exists idx_documentos_estado on documentos (estado, created_at desc);
alter table cfdi drop constraint if exists cfdi_documento_fk;
alter table cfdi add constraint cfdi_documento_fk foreign key (documento_id) references documentos(id) on delete set null;

-- Lo que se aprende de lo que apruebas: este proveedor siempre es esta categoría.
create table if not exists reglas_clasificacion (
  rfc_emisor     text primary key,
  nombre         text,
  categoria      text not null,
  cuenta_id      uuid references cuentas_financieras(id) on delete set null,
  veces          int not null default 1,
  actualizada_en timestamptz not null default now()
);

alter table empresa_fiscal        enable row level security;
alter table cuentas_financieras   enable row level security;
alter table cfdi                  enable row level security;
alter table documentos            enable row level security;
alter table reglas_clasificacion  enable row level security;

drop policy if exists admin_empresa_fiscal on empresa_fiscal;
drop policy if exists admin_cuentas        on cuentas_financieras;
drop policy if exists admin_cfdi_lee       on cfdi;
drop policy if exists admin_cfdi_inserta   on cfdi;
drop policy if exists admin_cfdi_cambia    on cfdi;
drop policy if exists admin_doc_lee        on documentos;
drop policy if exists admin_doc_inserta    on documentos;
drop policy if exists admin_doc_cambia     on documentos;
drop policy if exists admin_reglas         on reglas_clasificacion;
create policy admin_empresa_fiscal on empresa_fiscal       for all    to authenticated using (es_admin()) with check (es_admin());
create policy admin_cuentas        on cuentas_financieras  for all    to authenticated using (es_admin()) with check (es_admin());
create policy admin_reglas         on reglas_clasificacion for all    to authenticated using (es_admin()) with check (es_admin());
-- CFDI y documentos: nadie los borra desde el CRM (son el respaldo de lo que se declaró).
create policy admin_cfdi_lee     on cfdi       for select to authenticated using (es_admin());
create policy admin_cfdi_inserta on cfdi       for insert to authenticated with check (es_admin());
create policy admin_cfdi_cambia  on cfdi       for update to authenticated using (es_admin()) with check (es_admin());
create policy admin_doc_lee      on documentos for select to authenticated using (es_admin());
create policy admin_doc_inserta  on documentos for insert to authenticated with check (es_admin());
create policy admin_doc_cambia   on documentos for update to authenticated using (es_admin()) with check (es_admin());

revoke all on empresa_fiscal, cuentas_financieras, cfdi, documentos, reglas_clasificacion from anon;
grant select, insert, update, delete on empresa_fiscal, cuentas_financieras, reglas_clasificacion to authenticated;
grant select, insert, update on cfdi, documentos to authenticated;

-- ---- el bucket de finanzas también guarda los XML ----

update storage.buckets
   set allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'application/pdf', 'application/xml', 'text/xml']
 where id = 'finanzas';

-- ---------------------------------------------------------------------------
-- expediente_movimientos → libro único
-- ---------------------------------------------------------------------------
alter table expediente_movimientos alter column cotizacion_id drop not null;
alter table expediente_movimientos add column if not exists cuenta_id    uuid references cuentas_financieras(id);
alter table expediente_movimientos add column if not exists cfdi_id      uuid references cfdi(id);
alter table expediente_movimientos add column if not exists documento_id uuid references documentos(id) on delete set null;
alter table expediente_movimientos add column if not exists compra_id    uuid references compras(id);

create index if not exists idx_expediente_fecha  on expediente_movimientos (fecha);
create index if not exists idx_expediente_cuenta on expediente_movimientos (cuenta_id, fecha);
create index if not exists idx_expediente_cfdi   on expediente_movimientos (cfdi_id);

-- Las restricciones viejas de tipo/categoría no tenían nombre fijo: se buscan por su definición
-- (misma técnica que la 21) y se reemplazan por unas con nombre.
do $$
declare
  r record;
begin
  for r in
    select c.conname
      from pg_constraint c
     where c.conrelid = 'public.expediente_movimientos'::regclass
       and c.contype = 'c'
       and (pg_get_constraintdef(c.oid) ilike '%categoria%' or pg_get_constraintdef(c.oid) ilike '%tipo%')
       and c.conname <> 'expediente_iva_no_excede'
  loop
    execute format('alter table expediente_movimientos drop constraint %I', r.conname);
  end loop;
end;
$$;

alter table expediente_movimientos add constraint expediente_tipo_valido
  check (tipo in ('ingreso', 'egreso'));
alter table expediente_movimientos add constraint expediente_categoria_valida
  check (categoria in (
    'cobro', 'aportacion', 'otro_ingreso',
    'tecnico', 'gasolina', 'vehiculo', 'viaticos', 'otro',
    'material', 'herramienta', 'renta', 'servicios', 'software', 'comisiones_bancarias',
    'impuestos', 'publicidad', 'pago_proveedor', 'retiro_dueno'));
alter table expediente_movimientos add constraint expediente_tipo_categoria
  check ((tipo = 'ingreso') = (categoria in ('cobro', 'aportacion', 'otro_ingreso')));
-- Un cobro siempre es de una cotización: la cobranza (63) y la utilidad cuelgan de ahí.
alter table expediente_movimientos add constraint expediente_cobro_con_cotizacion
  check (categoria <> 'cobro' or cotizacion_id is not null);

-- ---------------------------------------------------------------------------
-- registrar_documento: una fila por archivo; el mismo archivo no entra dos veces.
-- ---------------------------------------------------------------------------
create or replace function registrar_documento(
  p_tipo text, p_archivo text, p_nombre text, p_mime text, p_hash text,
  p_metodo text default 'manual', p_extraido jsonb default null, p_validaciones jsonb default '[]'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not es_admin() then
    raise exception 'Solo el administrador sube documentos.' using errcode = '42501';
  end if;
  if coalesce(p_hash, '') !~ '^[0-9a-f]{64}$' then
    raise exception 'El archivo no trae una huella válida.' using errcode = '22023';
  end if;
  v_id := (select id from documentos where hash_sha256 = p_hash);
  if v_id is not null then
    return jsonb_build_object('ok', true, 'duplicado', true, 'documento_id', v_id,
                              'estado', (select estado from documentos where id = v_id));
  end if;
  v_id := gen_random_uuid();
  insert into documentos (id, tipo, archivo, nombre_original, mime, hash_sha256, metodo, extraido, validaciones, subido_por)
  values (v_id, coalesce(p_tipo, 'otro'), p_archivo, p_nombre, p_mime, p_hash,
          coalesce(p_metodo, 'manual'), p_extraido, coalesce(p_validaciones, '[]'::jsonb),
          coalesce(auth.jwt() ->> 'email', 'crm'));
  return jsonb_build_object('ok', true, 'duplicado', false, 'documento_id', v_id, 'estado', 'pendiente');
end;
$$;
revoke execute on function registrar_documento(text, text, text, text, text, text, jsonb, jsonb) from public, anon;
grant execute on function registrar_documento(text, text, text, text, text, text, jsonb, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- registrar_cfdi: guarda lo que dijo el XML. El sentido NO lo decide el navegador: sale de
-- comparar el RFC emisor y receptor con el tuyo (empresa_fiscal).
-- ---------------------------------------------------------------------------
create or replace function registrar_cfdi(p_datos jsonb, p_archivo text default null, p_documento uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rfc text;
  v_uuid text;
  v_emisor text;
  v_receptor text;
  v_sentido text;
  v_id uuid;
  v_existente uuid;
  v_cliente uuid;
  v_compra uuid;
begin
  if not es_admin() then
    raise exception 'Solo el administrador registra CFDI.' using errcode = '42501';
  end if;
  v_rfc := upper(trim(coalesce((select rfc from empresa_fiscal where id), '')));
  if v_rfc = '' then
    raise exception 'Primero captura tu RFC en Finanzas → Mi RFC.' using errcode = '22023';
  end if;

  v_uuid := lower(trim(coalesce(p_datos ->> 'uuid_fiscal', '')));
  v_emisor := upper(trim(coalesce(p_datos ->> 'rfc_emisor', '')));
  v_receptor := upper(trim(coalesce(p_datos ->> 'rfc_receptor', '')));
  if v_uuid = '' or v_emisor = '' or v_receptor = '' then
    raise exception 'El XML no trae UUID o RFC: no parece un CFDI timbrado.' using errcode = '22023';
  end if;

  v_sentido := case when v_emisor = v_rfc then 'emitido'
                    when v_receptor = v_rfc then 'recibido'
                    else null end;
  if v_sentido is null then
    raise exception 'Este CFDI no es de tu RFC (%): ni lo emitiste ni lo recibiste.', v_rfc using errcode = '22023';
  end if;

  v_existente := (select id from cfdi where uuid_fiscal = v_uuid);
  if v_existente is not null then
    if p_documento is not null then
      update documentos set cfdi_id = v_existente, estado = 'propuesto' where id = p_documento and estado = 'pendiente';
    end if;
    return jsonb_build_object('ok', true, 'duplicado', true, 'cfdi_id', v_existente,
                              'sentido', (select sentido from cfdi where id = v_existente));
  end if;

  if v_sentido = 'emitido' then
    v_cliente := (select d.cliente_id from datos_fiscales d
                   where upper(trim(d.rfc)) = v_receptor and coalesce(d.activo, true) limit 1);
  else
    v_compra := (select c.id from compras c where lower(trim(coalesce(c.uuid_fiscal, ''))) = v_uuid limit 1);
  end if;

  v_id := gen_random_uuid();
  insert into cfdi (id, uuid_fiscal, sentido, tipo_comprobante, serie, folio, fecha,
                    rfc_emisor, nombre_emisor, regimen_emisor, rfc_receptor, nombre_receptor, uso_cfdi,
                    subtotal, descuento, total, iva_trasladado, isr_retenido, iva_retenido,
                    moneda, tipo_cambio, metodo_pago, forma_pago, lugar_expedicion,
                    conceptos, relacionados, archivo_xml, cliente_id, compra_id, documento_id, creado_por)
  values (v_id, v_uuid, v_sentido, coalesce(nullif(p_datos ->> 'tipo_comprobante', ''), 'I'),
          nullif(p_datos ->> 'serie', ''), nullif(p_datos ->> 'folio', ''), (p_datos ->> 'fecha')::timestamptz,
          v_emisor, nullif(p_datos ->> 'nombre_emisor', ''), nullif(p_datos ->> 'regimen_emisor', ''),
          v_receptor, nullif(p_datos ->> 'nombre_receptor', ''), nullif(p_datos ->> 'uso_cfdi', ''),
          coalesce((p_datos ->> 'subtotal')::numeric, 0), coalesce((p_datos ->> 'descuento')::numeric, 0),
          coalesce((p_datos ->> 'total')::numeric, 0), coalesce((p_datos ->> 'iva_trasladado')::numeric, 0),
          coalesce((p_datos ->> 'isr_retenido')::numeric, 0), coalesce((p_datos ->> 'iva_retenido')::numeric, 0),
          coalesce(nullif(p_datos ->> 'moneda', ''), 'MXN'), (nullif(p_datos ->> 'tipo_cambio', ''))::numeric,
          nullif(p_datos ->> 'metodo_pago', ''), nullif(p_datos ->> 'forma_pago', ''),
          nullif(p_datos ->> 'lugar_expedicion', ''),
          coalesce(p_datos -> 'conceptos', '[]'::jsonb), coalesce(p_datos -> 'relacionados', '[]'::jsonb),
          p_archivo, v_cliente, v_compra, p_documento, coalesce(auth.jwt() ->> 'email', 'crm'));

  if p_documento is not null then
    update documentos set cfdi_id = v_id, estado = 'propuesto', tipo = 'cfdi_xml', metodo = 'xml'
     where id = p_documento and estado = 'pendiente';
  end if;
  perform _apunta('cfdi', v_id, 'registrar_cfdi', null,
                  jsonb_build_object('uuid', v_uuid, 'sentido', v_sentido, 'total', p_datos ->> 'total'), 'oficina');
  return jsonb_build_object('ok', true, 'duplicado', false, 'cfdi_id', v_id, 'sentido', v_sentido);
end;
$$;
revoke execute on function registrar_cfdi(jsonb, text, uuid) from public, anon;
grant execute on function registrar_cfdi(jsonb, text, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- aprobar_documento: de la bandeja al libro. Nada se vuelve definitivo sin esta llamada.
--   accion 'archivar' → solo se guarda el respaldo (un CFDI emitido, por ejemplo).
--   accion 'gasto'    → egreso en el libro, con pagado=true; con pagado=false el CFDI queda por pagar.
-- ---------------------------------------------------------------------------
create or replace function aprobar_documento(p_documento uuid, p_datos jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_d documentos%rowtype;
  v_cfdi cfdi%rowtype;
  v_accion text;
  v_cat text;
  v_monto numeric;
  v_iva numeric;
  v_fecha date;
  v_pagado boolean;
  v_mov uuid;
  v_cuenta uuid;
  v_cot uuid;
  v_correccion jsonb := '{}'::jsonb;
  v_prop jsonb;
begin
  if not es_admin() then
    raise exception 'Solo el administrador aprueba documentos.' using errcode = '42501';
  end if;
  v_d := (select d from documentos d where d.id = p_documento);
  if v_d.id is null then raise exception 'Ese documento no existe.' using errcode = '22023'; end if;
  if v_d.estado = 'aprobado' then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'movimiento_id', v_d.movimiento_id);
  end if;
  if v_d.estado = 'rechazado' then
    raise exception 'Ese documento fue rechazado; súbelo de nuevo si fue un error.' using errcode = '22023';
  end if;

  v_accion := coalesce(p_datos ->> 'accion', 'gasto');
  if v_accion not in ('gasto', 'archivar') then
    raise exception 'Acción no válida.' using errcode = '22023';
  end if;
  v_cfdi := (select c from cfdi c where c.id = v_d.cfdi_id);
  v_prop := coalesce(v_d.propuesta, '{}'::jsonb);

  if v_accion = 'gasto' then
    v_cat := coalesce(p_datos ->> 'categoria', '');
    if v_cat = '' or v_cat in ('cobro', 'aportacion', 'otro_ingreso') then
      raise exception 'Elige el tipo de gasto.' using errcode = '22023';
    end if;
    v_monto := coalesce((p_datos ->> 'monto')::numeric, v_cfdi.total);
    v_iva := coalesce((p_datos ->> 'iva')::numeric, v_cfdi.iva_trasladado, 0);
    v_fecha := coalesce((p_datos ->> 'fecha')::date, current_date);
    v_pagado := coalesce((p_datos ->> 'pagado')::boolean, true);
    v_cuenta := nullif(p_datos ->> 'cuenta_id', '')::uuid;
    v_cot := nullif(p_datos ->> 'cotizacion_id', '')::uuid;

    if v_pagado then
      if v_monto is null or v_monto <= 0 then
        raise exception 'El monto del gasto debe ser mayor a cero.' using errcode = '22023';
      end if;
      if v_cfdi.id is not null and exists (select 1 from expediente_movimientos where cfdi_id = v_cfdi.id) then
        raise exception 'Ese CFDI ya tiene un pago registrado.' using errcode = '22023';
      end if;
      v_mov := gen_random_uuid();
      insert into expediente_movimientos
        (id, cotizacion_id, tipo, categoria, fecha, concepto, monto, iva, forma, referencia,
         cuenta_id, cfdi_id, documento_id, archivo, archivo_nombre, notas, creado_por)
      values
        (v_mov, v_cot, 'egreso', v_cat, v_fecha,
         coalesce(nullif(trim(p_datos ->> 'concepto'), ''), v_cfdi.nombre_emisor, 'Gasto'),
         v_monto, least(coalesce(v_iva, 0), v_monto), nullif(p_datos ->> 'forma', ''),
         coalesce(nullif(trim(p_datos ->> 'referencia'), ''), v_cfdi.uuid_fiscal),
         v_cuenta, v_cfdi.id, p_documento, v_d.archivo, v_d.nombre_original,
         nullif(trim(p_datos ->> 'notas'), ''), coalesce(auth.jwt() ->> 'email', 'crm'));
    end if;

    -- Lo que el admin cambió de lo propuesto: mide dónde se equivoca la lectura.
    if v_prop ? 'categoria' and v_prop ->> 'categoria' is distinct from v_cat then
      v_correccion := v_correccion || jsonb_build_object('categoria', jsonb_build_array(v_prop ->> 'categoria', v_cat));
    end if;
    if v_prop ? 'monto' and (v_prop ->> 'monto')::numeric is distinct from v_monto then
      v_correccion := v_correccion || jsonb_build_object('monto', jsonb_build_array(v_prop ->> 'monto', v_monto));
    end if;

    -- Aprende: este proveedor, esta categoría.
    if v_cfdi.id is not null and v_cfdi.sentido = 'recibido' then
      insert into reglas_clasificacion (rfc_emisor, nombre, categoria, cuenta_id)
      values (v_cfdi.rfc_emisor, v_cfdi.nombre_emisor, v_cat, v_cuenta)
      on conflict (rfc_emisor) do update
        set categoria = excluded.categoria,
            cuenta_id = coalesce(excluded.cuenta_id, reglas_clasificacion.cuenta_id),
            nombre = coalesce(excluded.nombre, reglas_clasificacion.nombre),
            veces = case when reglas_clasificacion.categoria = excluded.categoria then reglas_clasificacion.veces + 1 else 1 end,
            actualizada_en = now();
    end if;
  end if;

  update documentos
     set estado = 'aprobado', movimiento_id = v_mov, correccion = nullif(v_correccion, '{}'::jsonb),
         aprobado_por = coalesce(auth.jwt() ->> 'email', 'crm'), aprobado_en = now()
   where id = p_documento;
  perform _apunta('documentos', p_documento, 'aprobar_documento', null,
                  jsonb_build_object('accion', v_accion, 'categoria', v_cat, 'monto', v_monto,
                                     'pagado', v_pagado, 'corrigio', v_correccion <> '{}'::jsonb), 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false, 'movimiento_id', v_mov);
end;
$$;
revoke execute on function aprobar_documento(uuid, jsonb) from public, anon;
grant execute on function aprobar_documento(uuid, jsonb) to authenticated;

create or replace function rechazar_documento(p_documento uuid, p_motivo text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_estado text;
begin
  if not es_admin() then
    raise exception 'Solo el administrador rechaza documentos.' using errcode = '42501';
  end if;
  v_estado := (select estado from documentos where id = p_documento);
  if v_estado is null then raise exception 'Ese documento no existe.' using errcode = '22023'; end if;
  if v_estado = 'rechazado' then return jsonb_build_object('ok', true, 'sin_cambio', true); end if;
  if v_estado = 'aprobado' then
    raise exception 'Ese documento ya se aprobó; corrígelo desde el libro.' using errcode = '22023';
  end if;
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Escribe por qué se rechaza.' using errcode = '22023';
  end if;
  update documentos set estado = 'rechazado', motivo_rechazo = trim(p_motivo) where id = p_documento;
  perform _apunta('documentos', p_documento, 'rechazar_documento', null,
                  jsonb_build_object('motivo', trim(p_motivo)), 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false);
end;
$$;
revoke execute on function rechazar_documento(uuid, text) from public, anon;
grant execute on function rechazar_documento(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Ligar una factura emitida a su cotización, y sugerir cuál es.
-- ---------------------------------------------------------------------------
create or replace function sugerir_cotizaciones_para_cfdi(p_cfdi uuid) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_c cfdi%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador liga facturas.' using errcode = '42501';
  end if;
  v_c := (select c from cfdi c where c.id = p_cfdi);
  if v_c.id is null or v_c.sentido <> 'emitido' then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'cotizacion_id', q.id, 'folio', q.folio, 'cliente', cl.nombre, 'total', q.total,
             'estado', q.estado, 'coincide_total', abs(coalesce(q.total, 0) - v_c.total) <= 1,
             'mismo_cliente', q.cliente_id is not distinct from v_c.cliente_id)
           order by (abs(coalesce(q.total, 0) - v_c.total) <= 1) desc, q.created_at desc)
      from (select * from cotizaciones
             where estado in ('aceptada', 'enviada')
               and (cliente_id is not distinct from v_c.cliente_id
                    or abs(coalesce(total, 0) - v_c.total) <= 1)
             order by created_at desc limit 8) q
      join clientes cl on cl.id = q.cliente_id), '[]'::jsonb);
end;
$$;
revoke execute on function sugerir_cotizaciones_para_cfdi(uuid) from public, anon;
grant execute on function sugerir_cotizaciones_para_cfdi(uuid) to authenticated;

create or replace function ligar_cfdi_cotizacion(p_cfdi uuid, p_cotizacion uuid) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_c cfdi%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador liga facturas.' using errcode = '42501';
  end if;
  v_c := (select c from cfdi c where c.id = p_cfdi);
  if v_c.id is null then raise exception 'Ese CFDI no existe.' using errcode = '22023'; end if;
  if v_c.sentido <> 'emitido' then
    raise exception 'Solo las facturas que tú emites se ligan a una cotización.' using errcode = '22023';
  end if;
  if (select id from cotizaciones where id = p_cotizacion) is null then
    raise exception 'Esa cotización no existe.' using errcode = '22023';
  end if;
  update cfdi set cotizacion_id = p_cotizacion where id = p_cfdi;
  perform _apunta('cfdi', p_cfdi, 'ligar_cfdi_cotizacion',
                  jsonb_build_object('cotizacion_id', v_c.cotizacion_id),
                  jsonb_build_object('cotizacion_id', p_cotizacion), 'oficina');
  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function ligar_cfdi_cotizacion(uuid, uuid) from public, anon;
grant execute on function ligar_cfdi_cotizacion(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- registrar_pago_tecnico, completo: ahora también carga al libro lo que no tiene cotización
-- (una póliza, un bono, un anticipo) como UN movimiento 'tecnico', y acepta la cuenta de donde
-- sale el dinero. La versión de 5 argumentos (66) se reemplaza.
-- ---------------------------------------------------------------------------
drop function if exists registrar_pago_tecnico(uuid, text, text, date, text);

create or replace function registrar_pago_tecnico(
  p_pago uuid, p_forma text, p_referencia text default null,
  p_fecha date default null, p_archivo text default null, p_cuenta uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p pagos_tecnico%rowtype;
  v_nombre text;
  r record;
  v_sin_cot numeric;
  v_n_sin_cot int;
  v_cargados int := 0;
  v_ref text;
begin
  if not es_admin() then
    raise exception 'Solo el administrador registra pagos a técnicos.' using errcode = '42501';
  end if;
  v_p := (select p from pagos_tecnico p where p.id = p_pago);
  if v_p.id is null then raise exception 'Ese pago no existe.' using errcode = '22023'; end if;
  if v_p.estado = 'pagado' then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;
  if v_p.estado <> 'aprobado' then
    raise exception 'Primero aprueba el pago (está %).', v_p.estado using errcode = '22023';
  end if;
  if p_forma is null or p_forma not in ('transferencia', 'efectivo', 'otro') then
    raise exception 'Indica la forma de pago: transferencia, efectivo u otro.' using errcode = '22023';
  end if;
  if p_cuenta is not null and (select id from cuentas_financieras where id = p_cuenta) is null then
    raise exception 'Esa cuenta no existe.' using errcode = '22023';
  end if;

  v_nombre := (select nombre from perfiles where id = v_p.tecnico_id);
  v_ref := coalesce(nullif(trim(p_referencia), ''), 'PAGO-' || v_p.folio);

  for r in
    select l.cotizacion_id, sum(l.monto) as monto, count(*) as n
      from pagos_tecnico_lineas l
     where l.pago_id = p_pago and l.activa and l.clase = 'servicio' and l.cotizacion_id is not null
     group by l.cotizacion_id
  loop
    if r.monto > 0 then
      insert into expediente_movimientos
        (cotizacion_id, tipo, categoria, fecha, concepto, monto, forma, referencia, tecnico_id,
         cuenta_id, archivo, notas, creado_por)
      values
        (r.cotizacion_id, 'egreso', 'tecnico', coalesce(p_fecha, current_date),
         format('Pago a %s por %s servicio(s)', coalesce(v_nombre, 'técnico'), r.n),
         r.monto, p_forma, v_ref, v_p.tecnico_id, p_cuenta, p_archivo,
         format('Pago a técnicos PAGO-%s', v_p.folio), coalesce(auth.jwt() ->> 'email', 'crm'));
      v_cargados := v_cargados + 1;
    end if;
  end loop;

  -- Lo que no cuelga de una cotización: servicios sin cotización + bonos y descuentos.
  v_sin_cot := coalesce((select sum(monto) from pagos_tecnico_lineas
                          where pago_id = p_pago and activa and cotizacion_id is null), 0);
  v_n_sin_cot := (select count(*) from pagos_tecnico_lineas
                   where pago_id = p_pago and activa and cotizacion_id is null);
  if v_sin_cot > 0 then
    insert into expediente_movimientos
      (cotizacion_id, tipo, categoria, fecha, concepto, monto, forma, referencia, tecnico_id,
       cuenta_id, archivo, notas, creado_por)
    values
      (null, 'egreso', 'tecnico', coalesce(p_fecha, current_date),
       format('Pago a %s (%s concepto(s) sin cotización)', coalesce(v_nombre, 'técnico'), v_n_sin_cot),
       v_sin_cot, p_forma, v_ref, v_p.tecnico_id, p_cuenta, p_archivo,
       format('Pago a técnicos PAGO-%s', v_p.folio), coalesce(auth.jwt() ->> 'email', 'crm'));
    v_cargados := v_cargados + 1;
  end if;

  update pagos_tecnico
     set estado = 'pagado', forma = p_forma, referencia = nullif(trim(p_referencia), ''),
         fecha_pago = coalesce(p_fecha, current_date), archivo = p_archivo,
         pagado_en = now(), pagado_por = coalesce(auth.jwt() ->> 'email', 'crm')
   where id = p_pago;
  perform _apunta('pagos_tecnico', p_pago, 'registrar_pago_tecnico', null,
                  jsonb_build_object('total', v_p.total, 'forma', p_forma, 'movimientos', v_cargados), 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false, 'expedientes_cargados', v_cargados);
end;
$$;
revoke execute on function registrar_pago_tecnico(uuid, text, text, date, text, uuid) from public, anon;
grant execute on function registrar_pago_tecnico(uuid, text, text, date, text, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- mis_comisiones: lo que ve el TÉCNICO de lo suyo. Una orden cerrada aparece "en revisión" sin
-- monto; el importe se muestra hasta que el administrador aprueba el pago ("aprobada"), y pasa a
-- "pagada" cuando se registra. Solo lee lo del propio usuario (auth.uid()), nunca lo de otro.
-- No muestra precios ni datos de la cotización.
-- ---------------------------------------------------------------------------
create or replace function mis_comisiones(p_dias int default 120) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_yo uuid := auth.uid();
  v_ordenes jsonb;
  v_ajustes jsonb;
  v_por_cobrar numeric;
  v_pagado_mes numeric;
  v_revision int;
  v_dias int := least(greatest(coalesce(p_dias, 120), 1), 400);
begin
  if v_yo is null or coalesce(mi_rol(), '') not in ('tecnico', 'admin') then
    return jsonb_build_object('ordenes', '[]'::jsonb, 'ajustes', '[]'::jsonb,
                              'resumen', jsonb_build_object('por_cobrar', 0, 'pagado_mes', 0, 'en_revision', 0));
  end if;

  v_ordenes := coalesce((
    select jsonb_agg(jsonb_build_object(
             'orden_id', m.orden_id, 'folio', m.folio, 'fecha', m.fecha,
             'tipo_servicio', m.tipo_servicio, 'rol', m.rol,
             'cliente', (select nombre from clientes where id = m.cliente_id),
             'estado', case x.pago_estado when 'pagado' then 'pagada' when 'aprobado' then 'aprobada' else 'en_revision' end,
             'monto', x.monto, 'pago_folio', x.folio, 'fecha_pago', x.fecha_pago)
           order by m.fecha desc, m.folio desc)
      from (
        select o.id as orden_id, o.folio, o.fecha, o.tipo_servicio, o.cliente_id, 'responsable'::text as rol
          from ordenes_servicio o
         where o.tecnico_id = v_yo and o.estado = 'cerrada' and o.fecha >= current_date - v_dias
        union all
        select o.id, o.folio, o.fecha, o.tipo_servicio, o.cliente_id, 'ayudante'
          from ordenes_servicio o
         where o.tecnico2_id = v_yo and o.estado = 'cerrada' and o.fecha >= current_date - v_dias
      ) m
      left join lateral (
        select l.monto, p.estado as pago_estado, p.folio, p.fecha_pago
          from pagos_tecnico_lineas l
          join pagos_tecnico p on p.id = l.pago_id
         where l.orden_id = m.orden_id and l.tecnico_id = v_yo and l.activa and l.clase = 'servicio'
           and p.estado in ('aprobado', 'pagado')
         order by p.created_at desc limit 1
      ) x on true), '[]'::jsonb);

  -- Bonos, descuentos y anticipos ya aprobados: se ven, para que el total cuadre.
  v_ajustes := coalesce((
    select jsonb_agg(jsonb_build_object(
             'concepto', l.concepto, 'monto', l.monto,
             'estado', case p.estado when 'pagado' then 'pagada' else 'aprobada' end,
             'pago_folio', p.folio, 'fecha_pago', p.fecha_pago) order by p.created_at desc)
      from pagos_tecnico_lineas l
      join pagos_tecnico p on p.id = l.pago_id
     where l.tecnico_id = v_yo and l.activa and l.clase = 'ajuste' and p.estado in ('aprobado', 'pagado')
       and p.created_at >= now() - make_interval(days => v_dias)), '[]'::jsonb);

  v_por_cobrar := coalesce((
    select sum(l.monto) from pagos_tecnico_lineas l join pagos_tecnico p on p.id = l.pago_id
     where l.tecnico_id = v_yo and l.activa and p.estado = 'aprobado'), 0);
  v_pagado_mes := coalesce((
    select sum(l.monto) from pagos_tecnico_lineas l join pagos_tecnico p on p.id = l.pago_id
     where l.tecnico_id = v_yo and l.activa and p.estado = 'pagado'
       and date_trunc('month', p.fecha_pago) = date_trunc('month', (now() at time zone 'America/Merida')::date)), 0);
  v_revision := (select count(*) from jsonb_array_elements(v_ordenes) e where e ->> 'estado' = 'en_revision');

  return jsonb_build_object(
    'resumen', jsonb_build_object('por_cobrar', v_por_cobrar, 'pagado_mes', v_pagado_mes, 'en_revision', v_revision),
    'ordenes', v_ordenes, 'ajustes', v_ajustes);
end;
$$;
revoke execute on function mis_comisiones(int) from public, anon;
grant execute on function mis_comisiones(int) to authenticated;

-- Registro (ver 68).
insert into _migraciones (archivo, tipo) values ('67_libro_financiero.sql', 'esquema')
on conflict (archivo) do nothing;
