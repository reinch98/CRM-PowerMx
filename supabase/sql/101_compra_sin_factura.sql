-- ---------------------------------------------------------------------------
-- 101 — Cerrar una compra (ticket) sin factura (pedido de Caña, 19/11/2026).
--
-- En "Pedido → factura" (FlujoCompras) una compra sin su XML se queda para siempre en "Falta la
-- factura". Pero hay tickets que nunca van a tener factura (AutoZone pagado en mostrador, una
-- compra chica): hace falta poder decir "esta se cierra así", con un motivo escrito, sin
-- inventarle una factura.
--
-- No mueve inventario ni dinero: solo marca la compra. Si después sí llega el XML y se liga
-- (`cfdi.compra_id`), la factura manda y la compra queda "Completo" de todos modos.
-- Se puede deshacer (`reabrir_compra_sin_factura`). Todo queda en `auditoria`.
-- Se puede repetir sin tronar.
-- ---------------------------------------------------------------------------

alter table compras add column if not exists sin_factura_motivo text;
alter table compras add column if not exists sin_factura_por text;
alter table compras add column if not exists sin_factura_en timestamptz;

comment on column compras.sin_factura_en is
  'Cuándo se cerró sin factura (null = sigue esperando su XML). Ver cerrar_compra_sin_factura (SQL 101).';

create or replace function cerrar_compra_sin_factura(p_compra uuid, p_motivo text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_c compras%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador cierra compras sin factura.' using errcode = '42501';
  end if;
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Escribe por qué se cierra sin factura (por ejemplo: ticket de mostrador, no se pidió factura).'
      using errcode = '22023';
  end if;

  v_c := (select c from compras c where c.id = p_compra);
  if v_c.id is null then
    raise exception 'Esa compra no existe.' using errcode = 'P0002';
  end if;
  if v_c.estado = 'cancelada' then
    raise exception 'La compra % está cancelada.', v_c.folio using errcode = '22023';
  end if;
  if exists (select 1 from cfdi f where f.compra_id = p_compra) then
    raise exception 'La compra % ya tiene su factura ligada: no hace falta cerrarla sin factura.', v_c.folio
      using errcode = '22023';
  end if;
  if v_c.sin_factura_en is not null then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'folio', v_c.folio);
  end if;

  update compras
     set sin_factura_motivo = trim(p_motivo),
         sin_factura_por = coalesce(auth.jwt() ->> 'email', 'crm'),
         sin_factura_en = now(),
         updated_at = now()
   where id = p_compra;

  perform _apunta('compras', p_compra, 'cerrar_sin_factura', null,
                  jsonb_build_object('folio', v_c.folio, 'motivo', trim(p_motivo)), 'oficina');

  return jsonb_build_object('ok', true, 'folio', v_c.folio);
end $fn$;

create or replace function reabrir_compra_sin_factura(p_compra uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_c compras%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador reabre compras.' using errcode = '42501';
  end if;
  v_c := (select c from compras c where c.id = p_compra);
  if v_c.id is null then
    raise exception 'Esa compra no existe.' using errcode = 'P0002';
  end if;
  if v_c.sin_factura_en is null then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'folio', v_c.folio);
  end if;

  update compras
     set sin_factura_motivo = null, sin_factura_por = null, sin_factura_en = null, updated_at = now()
   where id = p_compra;

  perform _apunta('compras', p_compra, 'reabrir_sin_factura',
                  jsonb_build_object('motivo', v_c.sin_factura_motivo, 'por', v_c.sin_factura_por,
                                     'en', v_c.sin_factura_en), null, 'oficina');

  return jsonb_build_object('ok', true, 'folio', v_c.folio);
end $fn$;

revoke all on function cerrar_compra_sin_factura(uuid, text) from public;
revoke all on function reabrir_compra_sin_factura(uuid) from public;
grant execute on function cerrar_compra_sin_factura(uuid, text) to authenticated;
grant execute on function reabrir_compra_sin_factura(uuid) to authenticated;

insert into _migraciones (archivo, tipo) values ('101_compra_sin_factura.sql', 'esquema')
on conflict (archivo) do nothing;
