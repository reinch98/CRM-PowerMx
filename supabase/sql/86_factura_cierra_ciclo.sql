-- ===========================================================================
-- 86 · La factura cierra el ciclo (parte D del ciclo de compras, 19/10/2026)
--
-- Decisión de Caña: la factura de un proveedor se liga a su comprobante de pago y a su cotización de
-- proveedor, si corresponde a alguna, y todo queda separado por proveedor. Además, la misma factura
-- podía entrar por DOS puertas sin saber una de la otra: Compras (mete el material al almacén) y
-- Finanzas (el XML: por pagar o pagada). Aquí se juntan.
--
-- · Factura ↔ compra: `cfdi.compra_id` ya existía (67) pero solo se llenaba al registrar el XML y
--   solo por UUID. Ahora se liga sola en los DOS sentidos (entre primero la compra o el XML): por
--   UUID, o por mismo proveedor + mismo folio + mismo total (±1 peso, misma moneda), y SOLO si hay
--   una pareja (con dos posibles no se adivina: se ofrece en pantalla). Una compra tiene a lo más una
--   factura. Cancelar la compra la suelta.
-- · Factura ↔ cotización de proveedor: `cfdi.cotizacion_proveedor_id` y `compras.cotizacion_proveedor_id`.
--   Una compra que recibe pedidos nacidos de una cotización (84) hereda esa cotización, y su factura
--   también. Si no se pudo deducir, se liga a mano.
-- · Factura ↔ pagos: un pago es un egreso que cita la factura (`cfdi_id`). Los anticipos (85) se
--   aplican al aprobar la factura en la bandeja: `aprobar_documento` acepta `anticipos` y, con la
--   factura "por pagar", se los aplica en la misma transacción (todo o nada).
-- · Un PDF de la bandeja que es el MISMO archivo que una compra liga su gasto a esa compra.
-- · `factura_contexto` da todo en una llamada; `ligar_factura` / `desligar_factura` corrigen a mano.
--
-- SQL plano fuera de las funciones, sin `select ... into` (ver CLAUDE.md). Repetible.
-- ===========================================================================

alter table cfdi
  add column if not exists cotizacion_proveedor_id uuid references cotizaciones_proveedor (id) on delete set null;
alter table compras
  add column if not exists cotizacion_proveedor_id uuid references cotizaciones_proveedor (id) on delete set null;

-- Una compra, una factura.
create unique index if not exists cfdi_una_compra on cfdi (compra_id) where compra_id is not null;
create index if not exists idx_cfdi_proveedor on cfdi (proveedor_id, fecha desc);
create index if not exists idx_cfdi_cotprov on cfdi (cotizacion_proveedor_id);
create index if not exists idx_compras_proveedor on compras (proveedor_id, fecha desc);

-- El folio de una factura como se compara: solo letras y números, en mayúsculas, y sin los ceros a la
-- izquierda de cada número ("A-0001474048", "a 1474048" y serie "A" + folio "1474048" dan "A1474048").
create or replace function _folio_clave(p text) returns text
language sql immutable as $fn$
  select nullif(regexp_replace(upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')),
                               '(^|[^0-9])0+([0-9])', '\1\2', 'g'), '')
$fn$;

-- ¿Qué compra es de esta factura? Por UUID, o una sola por proveedor + folio + total. Nula si hay dudas.
create or replace function _compra_para_cfdi(p_cfdi uuid, p_uuid text, p_proveedor uuid, p_serie text,
                                             p_folio text, p_total numeric, p_moneda text)
returns uuid
language plpgsql stable security definer set search_path = public as $fn$
declare
  v uuid;
begin
  v := (select co.id from compras co
         where co.estado <> 'cancelada' and lower(trim(coalesce(co.uuid_fiscal, ''))) = lower(trim(coalesce(p_uuid, '')))
           and coalesce(p_uuid, '') <> ''
           and not exists (select 1 from cfdi f where f.compra_id = co.id and f.id is distinct from p_cfdi)
         limit 1);
  if v is not null or p_proveedor is null or _folio_clave(p_folio) is null then
    return v;
  end if;
  if (select count(*) from compras co
       where co.estado <> 'cancelada' and co.proveedor_id = p_proveedor
         and _folio_clave(co.factura) in (_folio_clave(p_folio), _folio_clave(concat(p_serie, p_folio)))
         and coalesce(co.moneda, 'MXN') = coalesce(p_moneda, 'MXN') and abs(co.total - p_total) <= 1
         and not exists (select 1 from cfdi f where f.compra_id = co.id and f.id is distinct from p_cfdi)) <> 1 then
    return null;
  end if;
  return (select co.id from compras co
           where co.estado <> 'cancelada' and co.proveedor_id = p_proveedor
             and _folio_clave(co.factura) in (_folio_clave(p_folio), _folio_clave(concat(p_serie, p_folio)))
             and coalesce(co.moneda, 'MXN') = coalesce(p_moneda, 'MXN') and abs(co.total - p_total) <= 1
             and not exists (select 1 from cfdi f where f.compra_id = co.id and f.id is distinct from p_cfdi));
end $fn$;
revoke execute on function _compra_para_cfdi(uuid, text, uuid, text, text, numeric, text) from public, anon, authenticated;

-- ¿Qué factura (XML) es de esta compra? La misma regla, del otro lado.
create or replace function _cfdi_para_compra(p_compra uuid) returns uuid
language plpgsql stable security definer set search_path = public as $fn$
declare
  v_co compras;
  v uuid;
begin
  v_co := (select c from compras c where c.id = p_compra);
  if v_co.id is null or v_co.estado = 'cancelada' then
    return null;
  end if;
  v := (select f.id from cfdi f
         where f.sentido = 'recibido' and f.compra_id is null
           and coalesce(v_co.uuid_fiscal, '') <> '' and f.uuid_fiscal = lower(trim(v_co.uuid_fiscal))
         limit 1);
  if v is not null or v_co.proveedor_id is null or _folio_clave(v_co.factura) is null then
    return v;
  end if;
  if (select count(*) from cfdi f
       where f.sentido = 'recibido' and f.tipo_comprobante = 'I' and f.compra_id is null
         and f.estado_sat <> 'cancelado' and f.proveedor_id = v_co.proveedor_id
         and _folio_clave(v_co.factura) in (_folio_clave(f.folio), _folio_clave(concat(f.serie, f.folio)))
         and f.moneda = coalesce(v_co.moneda, 'MXN') and abs(f.total - v_co.total) <= 1) <> 1 then
    return null;
  end if;
  return (select f.id from cfdi f
           where f.sentido = 'recibido' and f.tipo_comprobante = 'I' and f.compra_id is null
             and f.estado_sat <> 'cancelado' and f.proveedor_id = v_co.proveedor_id
             and _folio_clave(v_co.factura) in (_folio_clave(f.folio), _folio_clave(concat(f.serie, f.folio)))
             and f.moneda = coalesce(v_co.moneda, 'MXN') and abs(f.total - v_co.total) <= 1);
end $fn$;
revoke execute on function _cfdi_para_compra(uuid) from public, anon, authenticated;

-- Al entrar un XML recibido: busca su compra. Corre DESPUÉS de `fijar_proveedor` (orden alfabético
-- de los disparadores `before`), así que ya trae su proveedor.
create or replace function _ligar_compra_de_cfdi() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  if new.sentido = 'recibido' and new.tipo_comprobante = 'I' then
    if new.compra_id is null then
      new.compra_id := _compra_para_cfdi(new.id, new.uuid_fiscal, new.proveedor_id, new.serie, new.folio,
                                          new.total, new.moneda);
    end if;
    if new.cotizacion_proveedor_id is null and new.compra_id is not null then
      new.cotizacion_proveedor_id := (select cotizacion_proveedor_id from compras where id = new.compra_id);
    end if;
  end if;
  return new;
end $fn$;
drop trigger if exists ligar_compra on cfdi;
create trigger ligar_compra before insert on cfdi
  for each row execute function _ligar_compra_de_cfdi();

-- Al registrar o corregir una compra: busca su XML. La compra nace con total 0 y lo recibe al final
-- de `registrar_compra`, por eso también se mira el cambio de total. Cancelarla suelta su factura.
create or replace function _ligar_cfdi_de_compra() returns trigger
language plpgsql security definer set search_path = public as $fn$
declare
  v uuid;
begin
  if new.estado = 'cancelada' then
    update cfdi set compra_id = null where compra_id = new.id;
    return null;
  end if;
  if exists (select 1 from cfdi where compra_id = new.id) then
    return null;
  end if;
  v := _cfdi_para_compra(new.id);
  if v is not null then
    update cfdi set compra_id = new.id,
                    cotizacion_proveedor_id = coalesce(cotizacion_proveedor_id, new.cotizacion_proveedor_id)
     where id = v;
  end if;
  return null;
end $fn$;
drop trigger if exists ligar_cfdi on compras;
create trigger ligar_cfdi after insert or update of factura, uuid_fiscal, proveedor_id, estado, total on compras
  for each row execute function _ligar_cfdi_de_compra();

-- Una línea de compra que recibe un pedido nacido de una cotización de proveedor: la compra (y su
-- factura, si ya está ligada) heredan esa cotización.
create or replace function _cotizacion_de_compra() returns trigger
language plpgsql security definer set search_path = public as $fn$
declare
  v uuid;
begin
  if new.requisicion_id is null then
    return null;
  end if;
  v := (select cotizacion_proveedor_id from requisiciones where id = new.requisicion_id);
  if v is not null then
    update compras set cotizacion_proveedor_id = v where id = new.compra_id and cotizacion_proveedor_id is null;
    update cfdi set cotizacion_proveedor_id = v where compra_id = new.compra_id and cotizacion_proveedor_id is null;
  end if;
  return null;
end $fn$;
drop trigger if exists cotizacion_de_compra on compra_lineas;
create trigger cotizacion_de_compra after insert on compra_lineas
  for each row execute function _cotizacion_de_compra();

-- Lo que ya existía: compras que heredan su cotización y facturas que encuentran su compra (una por una,
-- para que dos facturas no tomen la misma compra).
update compras co
   set cotizacion_proveedor_id = (select min(r.cotizacion_proveedor_id::text)::uuid
                                    from compra_lineas l join requisiciones r on r.id = l.requisicion_id
                                   where l.compra_id = co.id and r.cotizacion_proveedor_id is not null)
 where co.cotizacion_proveedor_id is null
   and exists (select 1 from compra_lineas l join requisiciones r on r.id = l.requisicion_id
                where l.compra_id = co.id and r.cotizacion_proveedor_id is not null);

do $$
declare
  f record;
  v uuid;
begin
  for f in select * from cfdi where sentido = 'recibido' and tipo_comprobante = 'I' and compra_id is null order by fecha loop
    v := _compra_para_cfdi(f.id, f.uuid_fiscal, f.proveedor_id, f.serie, f.folio, f.total, f.moneda);
    if v is not null then
      update cfdi set compra_id = v,
                      cotizacion_proveedor_id = coalesce(cotizacion_proveedor_id, (select cotizacion_proveedor_id from compras where id = v))
       where id = f.id;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- factura_contexto: todo lo de una factura recibida en una llamada.
-- ---------------------------------------------------------------------------
create or replace function factura_contexto(p_cfdi uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare
  v_c     cfdi;
  v_saldo numeric;
  v_cot   uuid;
  v_fecha date;
begin
  if not es_admin() then
    raise exception 'Solo el administrador ve las facturas.' using errcode = '42501';
  end if;
  v_c := (select c from cfdi c where c.id = p_cfdi);
  if v_c.id is null then
    raise exception 'Esa factura no existe.' using errcode = '22023';
  end if;
  v_saldo := _saldo_cfdi(p_cfdi);
  v_fecha := (v_c.fecha at time zone 'America/Merida')::date;
  v_cot := coalesce(v_c.cotizacion_proveedor_id, (select cotizacion_proveedor_id from compras where id = v_c.compra_id));

  return jsonb_build_object(
    'factura', jsonb_build_object(
      'id', v_c.id, 'serie', v_c.serie, 'folio', v_c.folio, 'fecha', v_fecha, 'total', v_c.total,
      'moneda', v_c.moneda, 'saldo', v_saldo, 'por_pagar', v_c.por_pagar, 'sentido', v_c.sentido,
      'proveedor_id', v_c.proveedor_id, 'proveedor', (select nombre from proveedores where id = v_c.proveedor_id)),
    'compra', (select jsonb_build_object(
                 'id', co.id, 'folio', co.folio, 'factura', co.factura, 'fecha', co.fecha, 'total', co.total,
                 'proveedor', co.proveedor,
                 'entro', exists (select 1 from compra_lineas l where l.compra_id = co.id and l.movimiento_id is not null))
                 from compras co where co.id = v_c.compra_id),
    'compras_posibles', case when v_c.compra_id is not null or v_c.proveedor_id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', co.id, 'folio', co.folio, 'factura', co.factura, 'fecha', co.fecha, 'total', co.total,
               'proveedor', co.proveedor, 'cuadra', abs(co.total - v_c.total) <= 1,
               'mismo_folio', coalesce(_folio_clave(co.factura) in (_folio_clave(v_c.folio), _folio_clave(concat(v_c.serie, v_c.folio))), false))
             order by abs(co.total - v_c.total), co.fecha desc)
        from (select * from compras co
               where co.proveedor_id = v_c.proveedor_id and co.estado <> 'cancelada'
                 and not exists (select 1 from cfdi f where f.compra_id = co.id)
                 and co.fecha between v_fecha - 120 and v_fecha + 60
               order by abs(co.total - v_c.total), co.fecha desc limit 5) co), '[]'::jsonb) end,
    'cotizacion', (select jsonb_build_object(
                     'id', q.id, 'folio', q.folio, 'numero', q.numero, 'estado', q.estado, 'fecha', q.fecha,
                     'moneda', q.moneda, 'total', q.total,
                     'total_mxn', round(q.total * case when q.moneda = 'USD' then coalesce(q.tipo_cambio, 0) else 1 end, 2),
                     'directa', v_c.cotizacion_proveedor_id is not null)
                     from cotizaciones_proveedor q where q.id = v_cot),
    'cotizaciones_posibles', case when v_cot is not null or v_c.proveedor_id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', q.id, 'folio', q.folio, 'numero', q.numero, 'estado', q.estado, 'fecha', q.fecha,
               'moneda', q.moneda, 'total', q.total, 'total_mxn', q.total_mxn,
               'cuadra', abs(q.total_mxn - v_c.total) <= greatest(1, v_c.total * 0.02))
             order by abs(q.total_mxn - v_c.total) <= greatest(1, v_c.total * 0.02) desc, (q.estado = 'aceptada') desc, q.fecha desc)
        from (select q.*, round(q.total * case when q.moneda = 'USD' then coalesce(q.tipo_cambio, 0) else 1 end, 2) as total_mxn
                from cotizaciones_proveedor q
               where q.proveedor_id = v_c.proveedor_id and q.estado in ('vigente', 'aceptada')
                 and q.fecha >= v_fecha - 180
               order by q.fecha desc limit 5) q), '[]'::jsonb) end,
    'anticipos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'movimiento_id', m.id, 'fecha', m.fecha, 'monto', m.monto, 'referencia', m.referencia,
               'cotizacion_proveedor', (select 'COTP-' || q.folio from cotizaciones_proveedor q where q.id = m.cotizacion_proveedor_id),
               'de_su_cotizacion', v_cot is not null and m.cotizacion_proveedor_id = v_cot,
               'cabe', m.monto <= v_saldo + 0.01)
             order by (v_cot is not null and m.cotizacion_proveedor_id = v_cot) desc, abs(m.monto - v_saldo), m.fecha)
        from expediente_movimientos m
       where v_c.proveedor_id is not null and m.proveedor_id = v_c.proveedor_id
         and m.tipo = 'egreso' and m.categoria = 'pago_proveedor' and m.cfdi_id is null), '[]'::jsonb),
    'pagos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', m.id, 'fecha', m.fecha, 'monto', m.monto, 'iva', m.iva, 'forma', m.forma,
               'referencia', m.referencia, 'anticipo', coalesce(m.notas, '') ilike '%Anticipo aplicado%')
             order by m.fecha, m.created_at)
        from expediente_movimientos m where m.cfdi_id = p_cfdi and m.tipo = 'egreso'), '[]'::jsonb)
  );
end $fn$;
revoke execute on function factura_contexto(uuid) from public, anon;
grant execute on function factura_contexto(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- ligar_factura / desligar_factura: corregir a mano lo que no se pudo deducir.
-- ---------------------------------------------------------------------------
create or replace function ligar_factura(p_cfdi uuid, p_compra uuid default null, p_cotizacion uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_c  cfdi;
  v_co compras;
  v_q  cotizaciones_proveedor;
begin
  if not es_admin() then
    raise exception 'Solo el administrador liga facturas.' using errcode = '42501';
  end if;
  v_c := (select c from cfdi c where c.id = p_cfdi);
  if v_c.id is null or v_c.sentido <> 'recibido' then
    raise exception 'Esa factura no es de un proveedor.' using errcode = '22023';
  end if;
  if p_compra is null and p_cotizacion is null then
    raise exception 'Elige la compra o la cotización.' using errcode = '22023';
  end if;

  if p_compra is not null then
    v_co := (select c from compras c where c.id = p_compra);
    if v_co.id is null or v_co.estado = 'cancelada' then
      raise exception 'Esa compra no existe o está cancelada.' using errcode = '22023';
    end if;
    if v_co.proveedor_id is distinct from v_c.proveedor_id then
      raise exception 'La compra es de otro proveedor.' using errcode = '22023';
    end if;
    if exists (select 1 from cfdi f where f.compra_id = p_compra and f.id <> p_cfdi) then
      raise exception 'Esa compra ya tiene su factura.' using errcode = '22023';
    end if;
    update cfdi set compra_id = p_compra,
                    cotizacion_proveedor_id = coalesce(cotizacion_proveedor_id, v_co.cotizacion_proveedor_id)
     where id = p_cfdi;
    -- La compra aprende el UUID de su factura si no lo tenía.
    update compras set uuid_fiscal = v_c.uuid_fiscal, updated_at = now()
     where id = p_compra and coalesce(uuid_fiscal, '') = '';
    perform _apunta('cfdi', p_cfdi, 'ligar_compra', jsonb_build_object('compra_id', v_c.compra_id),
                    jsonb_build_object('compra_id', p_compra, 'compra', v_co.folio), 'oficina');
  end if;

  if p_cotizacion is not null then
    v_q := (select q from cotizaciones_proveedor q where q.id = p_cotizacion);
    if v_q.id is null or v_q.estado in ('cancelada', 'rechazada') then
      raise exception 'Esa cotización no existe o ya no está viva.' using errcode = '22023';
    end if;
    if v_q.proveedor_id is distinct from v_c.proveedor_id then
      raise exception 'La cotización es de otro proveedor.' using errcode = '22023';
    end if;
    update cfdi set cotizacion_proveedor_id = p_cotizacion where id = p_cfdi;
    update compras set cotizacion_proveedor_id = p_cotizacion
     where id = (select compra_id from cfdi where id = p_cfdi) and cotizacion_proveedor_id is null;
    perform _apunta('cfdi', p_cfdi, 'ligar_cotizacion', jsonb_build_object('cotizacion_proveedor_id', v_c.cotizacion_proveedor_id),
                    jsonb_build_object('cotizacion_proveedor_id', p_cotizacion, 'cotizacion', 'COTP-' || v_q.folio), 'oficina');
  end if;
  return jsonb_build_object('ok', true);
end $fn$;
revoke execute on function ligar_factura(uuid, uuid, uuid) from public, anon;
grant execute on function ligar_factura(uuid, uuid, uuid) to authenticated;

create or replace function desligar_factura(p_cfdi uuid, p_que text)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_c cfdi;
begin
  if not es_admin() then
    raise exception 'Solo el administrador liga facturas.' using errcode = '42501';
  end if;
  v_c := (select c from cfdi c where c.id = p_cfdi);
  if v_c.id is null then
    raise exception 'Esa factura no existe.' using errcode = '22023';
  end if;
  if p_que = 'compra' then
    if v_c.compra_id is null then
      return jsonb_build_object('ok', true, 'sin_cambio', true);
    end if;
    update cfdi set compra_id = null where id = p_cfdi;
  elsif p_que = 'cotizacion' then
    if v_c.cotizacion_proveedor_id is null then
      return jsonb_build_object('ok', true, 'sin_cambio', true);
    end if;
    update cfdi set cotizacion_proveedor_id = null where id = p_cfdi;
  else
    raise exception 'Di qué se suelta: la compra o la cotización.' using errcode = '22023';
  end if;
  perform _apunta('cfdi', p_cfdi, 'desligar_' || p_que,
                  jsonb_build_object('compra_id', v_c.compra_id, 'cotizacion_proveedor_id', v_c.cotizacion_proveedor_id),
                  null, 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false);
end $fn$;
revoke execute on function desligar_factura(uuid, text) from public, anon;
grant execute on function desligar_factura(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- aprobar_documento (redefinida desde la viva, que era la del 72) con dos cosas más:
--   (86) `anticipos`: con la factura "por pagar", le aplica esos anticipos en la misma transacción.
--   (86) el gasto queda ligado a la compra de su factura, o a la compra que tiene el MISMO archivo.
-- ---------------------------------------------------------------------------
create or replace function aprobar_documento(p_documento uuid, p_datos jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
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
  v_ant jsonb;      -- (86)
  v_m text;         -- (86)
  v_compra uuid;    -- (86)
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
  -- (86) anticipos a aplicar
  v_ant := case when jsonb_typeof(p_datos -> 'anticipos') = 'array' then p_datos -> 'anticipos' else '[]'::jsonb end;

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

    -- (86) un anticipo ya es el pago: la factura queda por pagar y el anticipo la abona.
    if jsonb_array_length(v_ant) > 0 and (v_pagado or v_cfdi.id is null) then
      raise exception 'Para aplicarle un anticipo, la factura (con XML) queda "por pagar": el anticipo ya es el pago.' using errcode = '22023';
    end if;

    if v_pagado then
      if v_monto is null or v_monto <= 0 then
        raise exception 'El monto del gasto debe ser mayor a cero.' using errcode = '22023';
      end if;
      if v_cfdi.id is not null and exists (select 1 from expediente_movimientos where cfdi_id = v_cfdi.id) then
        raise exception 'Ese CFDI ya tiene un pago registrado.' using errcode = '22023';
      end if;
      -- (86) la compra de esa factura, o la compra que tiene el mismo archivo.
      v_compra := coalesce(v_cfdi.compra_id,
                           (select co.id from compras co
                              join archivos_subidos a on a.bucket = 'compras' and a.ruta in (co.archivo_pdf, co.archivo_xml)
                             where a.hash = v_d.hash_sha256 and co.estado <> 'cancelada'
                             order by co.created_at limit 1));
      v_mov := gen_random_uuid();
      insert into expediente_movimientos
        (id, cotizacion_id, tipo, categoria, fecha, concepto, monto, iva, forma, referencia,
         cuenta_id, cfdi_id, documento_id, compra_id, archivo, archivo_nombre, notas, creado_por)
      values
        (v_mov, v_cot, 'egreso', v_cat, v_fecha,
         coalesce(nullif(trim(p_datos ->> 'concepto'), ''), v_cfdi.nombre_emisor, 'Gasto'),
         v_monto, least(coalesce(v_iva, 0), v_monto), nullif(p_datos ->> 'forma', ''),
         coalesce(nullif(trim(p_datos ->> 'referencia'), ''), v_cfdi.uuid_fiscal),
         v_cuenta, v_cfdi.id, p_documento, v_compra, v_d.archivo, v_d.nombre_original,
         nullif(trim(p_datos ->> 'notas'), ''), coalesce(auth.jwt() ->> 'email', 'crm'));
    elsif v_cfdi.id is not null then
      -- (72) "Aún no la pago": la factura queda POR PAGAR con su categoría y su vencimiento
      -- (por omisión, 30 días después de la fecha de la factura, en hora de Mérida).
      update cfdi
         set por_pagar = true, categoria = v_cat,
             vence = coalesce(nullif(p_datos ->> 'vence', '')::date,
                              (v_cfdi.fecha at time zone 'America/Merida')::date + 30)
       where id = v_cfdi.id;
      -- (86) y le aplica los anticipos elegidos (mismo proveedor, no más que el saldo: lo revisa aplicar_anticipo).
      for v_m in select jsonb_array_elements_text(v_ant) loop
        perform aplicar_anticipo(v_m::uuid, v_cfdi.id);
      end loop;
    else
      raise exception 'Solo una factura con XML se puede dejar por pagar.' using errcode = '22023';
    end if;

    if v_prop ? 'categoria' and v_prop ->> 'categoria' is distinct from v_cat then
      v_correccion := v_correccion || jsonb_build_object('categoria', jsonb_build_array(v_prop ->> 'categoria', v_cat));
    end if;
    if v_prop ? 'monto' and (v_prop ->> 'monto')::numeric is distinct from v_monto then
      v_correccion := v_correccion || jsonb_build_object('monto', jsonb_build_array(v_prop ->> 'monto', v_monto));
    end if;

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
                                     'pagado', v_pagado, 'corrigio', v_correccion <> '{}'::jsonb,
                                     'anticipos', jsonb_array_length(v_ant), 'compra_id', v_compra), 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false, 'movimiento_id', v_mov,
                            'anticipos', jsonb_array_length(v_ant),
                            'saldo', case when v_cfdi.id is not null then _saldo_cfdi(v_cfdi.id) end);
end;
$fn$;
revoke execute on function aprobar_documento(uuid, jsonb) from public, anon;
grant execute on function aprobar_documento(uuid, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- cotizaciones_proveedor_lista (84) con sus facturas y lo anticipado.
-- ---------------------------------------------------------------------------
create or replace function cotizaciones_proveedor_lista(p_proveedor uuid default null, p_dias int default 365)
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
begin
  if not es_admin() then
    raise exception 'Solo el administrador ve las cotizaciones de proveedor.' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', c.id, 'folio', c.folio, 'proveedor_id', c.proveedor_id, 'proveedor', p.nombre,
             'numero', c.numero, 'fecha', c.fecha, 'vigencia', c.vigencia, 'estado', c.estado,
             'vencida', c.estado = 'vigente' and c.vigencia is not null and c.vigencia < _hoy_merida(),
             'moneda', c.moneda, 'tipo_cambio', c.tipo_cambio, 'subtotal', c.subtotal, 'iva', c.iva,
             'total', c.total, 'motivo', c.motivo, 'notas', c.notas, 'archivo', c.archivo,
             'archivo_bucket', c.archivo_bucket, 'aceptada_en', c.aceptada_en,
             'pedidos', (select count(*) from requisiciones r where r.cotizacion_proveedor_id = c.id),
             'pedidos_recibidos', (select count(*) from requisiciones r
                                    where r.cotizacion_proveedor_id = c.id and r.estado = 'recibida'),
             -- (86) sus facturas (directas o por su compra) y lo anticipado sin factura
             'facturas', coalesce((
               select jsonb_agg(jsonb_build_object('cfdi_id', f.id, 'serie', f.serie, 'folio', f.folio,
                                                   'total', f.total, 'saldo', _saldo_cfdi(f.id), 'por_pagar', f.por_pagar)
                                order by f.fecha)
                 from cfdi f
                where f.cotizacion_proveedor_id = c.id
                   or f.compra_id in (select co.id from compras co where co.cotizacion_proveedor_id = c.id)), '[]'::jsonb),
             'anticipado', coalesce((select sum(m.monto) from expediente_movimientos m
                                      where m.cotizacion_proveedor_id = c.id and m.tipo = 'egreso'
                                        and m.categoria = 'pago_proveedor' and m.cfdi_id is null), 0),
             'lineas', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'producto_id', l.producto_id, 'sku', pr.sku, 'nombre', pr.nombre, 'codigo', l.codigo,
                        'descripcion', l.descripcion, 'cantidad', l.cantidad,
                        'precio_unitario', l.precio_unitario, 'importe', l.importe) order by l.orden)
                 from cotizacion_proveedor_lineas l join productos pr on pr.id = l.producto_id
                where l.cotizacion_id = c.id), '[]'::jsonb))
           order by (c.estado = 'vigente') desc, c.fecha desc, c.folio desc)
      from cotizaciones_proveedor c
      join proveedores p on p.id = c.proveedor_id
     where (p_proveedor is null or c.proveedor_id = p_proveedor)
       and (c.estado = 'vigente' or c.fecha >= _hoy_merida() - greatest(coalesce(p_dias, 365), 1))
  ), '[]'::jsonb);
end $fn$;
revoke execute on function cotizaciones_proveedor_lista(uuid, int) from public, anon;
grant execute on function cotizaciones_proveedor_lista(uuid, int) to authenticated;

-- ---------------------------------------------------------------------------
-- carpeta_proveedor (80) con la compra y la cotización de cada factura, y la factura de cada compra.
-- ---------------------------------------------------------------------------
create or replace function carpeta_proveedor(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare
  v_p proveedores;
begin
  if not es_admin() then
    raise exception 'Solo el administrador ve los proveedores.' using errcode = '42501';
  end if;
  v_p := (select p from proveedores p where p.id = p_id);
  if v_p.id is null then
    raise exception 'Ese proveedor no existe.' using errcode = '22023';
  end if;
  return jsonb_build_object(
    'proveedor', _ficha_proveedor(v_p),
    'resumen', _resumen_proveedor(p_id),
    'facturas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', f.id, 'serie', f.serie, 'folio', f.folio, 'uuid_fiscal', f.uuid_fiscal, 'fecha', f.fecha::date,
               'total', f.total, 'moneda', f.moneda, 'saldo', _saldo_cfdi(f.id), 'por_pagar', f.por_pagar,
               'vence', f.vence, 'estado_sat', f.estado_sat, 'metodo_pago', f.metodo_pago,
               -- (86)
               'compra', (select co.folio from compras co where co.id = f.compra_id),
               'cotizacion', (select 'COTP-' || q.folio from cotizaciones_proveedor q
                               where q.id = coalesce(f.cotizacion_proveedor_id,
                                                     (select co.cotizacion_proveedor_id from compras co where co.id = f.compra_id))),
               'pagos', (select count(*) from expediente_movimientos m where m.cfdi_id = f.id and m.tipo = 'egreso'))
             order by f.fecha desc)
        from (select * from cfdi where proveedor_id = p_id order by fecha desc limit 60) f), '[]'::jsonb),
    'pagos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', m.id, 'fecha', m.fecha, 'monto', m.monto, 'iva', m.iva, 'categoria', m.categoria,
               'concepto', m.concepto, 'forma', m.forma, 'referencia', m.referencia, 'cfdi_id', m.cfdi_id,
               'factura', (select nullif(concat_ws(' ', f.serie, f.folio), '') from cfdi f where f.id = m.cfdi_id),
               'archivo', m.archivo)
             order by m.fecha desc, m.created_at desc)
        from (select * from expediente_movimientos
               where proveedor_id = p_id and tipo = 'egreso'
               order by fecha desc, created_at desc limit 60) m), '[]'::jsonb),
    'compras', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'folio', c.folio, 'factura', c.factura, 'fecha', c.fecha, 'total', c.total,
               'estado', c.estado, 'proveedor_texto', c.proveedor,
               -- (86)
               'factura_xml', (select nullif(concat_ws(' ', f.serie, f.folio), '') from cfdi f where f.compra_id = c.id),
               'con_xml', exists (select 1 from cfdi f where f.compra_id = c.id),
               'cotizacion', (select 'COTP-' || q.folio from cotizaciones_proveedor q where q.id = c.cotizacion_proveedor_id))
             order by c.fecha desc, c.folio desc)
        from (select * from compras where proveedor_id = p_id order by fecha desc, folio desc limit 40) c), '[]'::jsonb),
    'pedidos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', r.id, 'folio', r.folio, 'estado', r.estado, 'cantidad', r.cantidad,
               'sku', pr.sku, 'producto', pr.nombre, 'referencia', r.referencia,
               'fecha_pedido', r.fecha_pedido, 'fecha_recibida', r.fecha_recibida)
             order by (r.estado in ('pendiente', 'pedida')) desc, r.created_at desc)
        from (select * from requisiciones
               where proveedor_id = p_id
                 and (estado in ('pendiente', 'pedida') or created_at >= now() - interval '120 days')
               order by created_at desc limit 60) r
        join productos pr on pr.id = r.producto_id), '[]'::jsonb),
    'productos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pr.id, 'sku', pr.sku, 'nombre', pr.nombre, 'codigo', pp.proveedor_sku,
               'opcion', pp.opcion, 'costo', pp.costo_mxn)
             order by pp.opcion nulls last, pr.sku)
        from (select * from producto_proveedores where proveedor_id = p_id
               order by opcion nulls last, proveedor_sku limit 40) pp
        join productos pr on pr.id = pp.producto_id), '[]'::jsonb)
  );
end $fn$;
revoke execute on function carpeta_proveedor(uuid) from public, anon;
grant execute on function carpeta_proveedor(uuid) to authenticated;

notify pgrst, 'reload schema';

insert into _migraciones (archivo, tipo) values ('86_factura_cierra_ciclo.sql', 'esquema')
on conflict (archivo) do nothing;
