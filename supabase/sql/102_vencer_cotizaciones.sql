-- ===========================================================================
-- 102 · Las cotizaciones vencen solas (semáforo de vigencia, 19/11/2026)
--
-- Pedido de Caña: "una normativa de color, en la que vayamos descartando y
-- guardando las que van expirando". Había 15 cotizaciones en borrador o enviada,
-- varias con semanas, mezcladas con las vivas.
--
-- Una cotización en BORRADOR o ENVIADA vence `vigencia_dias` (15 si no hay)
-- después de su fecha; el día de vencer todavía vale. Un reloj diario la pasa a
-- `vencida`. NO se borra nada: queda archivada (la lista la oculta por omisión)
-- y se reactiva pasándola a Borrador. Las aceptadas no vencen.
--
-- Vencer hace lo mismo que `cambiar_estado_cotizacion(..., 'vencida')` desde
-- borrador/enviada: cancela la cita y la orden que NO tengan trabajo capturado
-- (si lo tienen, las deja y lo cuenta). No se reusa esa función porque exige
-- sesión de admin y el reloj no tiene sesión; el bloque de cancelar es COPIA del
-- de esa función (versión de la 14). Si se cambia allá, cambiarlo aquí.
-- Una cotización que nunca se aceptó no tiene apartados ni pedidos: no hay
-- inventario que mover.
-- ===========================================================================

create or replace function public.vencer_cotizaciones(p_hoy date default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_hoy date := coalesce(p_hoy, (now() at time zone 'America/Mexico_City')::date);
  r record;
  v_canc int;
  v_trab int;
  n int := 0;
  n_citas int := 0;
  n_trabajo int := 0;
  v_folios int[] := '{}';
begin
  -- Sin sesión (el reloj) pasa; con sesión, solo admin.
  if auth.uid() is not null and not es_admin() then
    raise exception 'Solo el administrador puede vencer cotizaciones.' using errcode = '42501';
  end if;

  for r in
    select c.id, c.folio, c.estado
      from cotizaciones c
     where c.estado in ('borrador', 'enviada')
       and c.fecha is not null
       and c.fecha + coalesce(nullif(c.vigencia_dias, 0), 15) < v_hoy
     order by c.folio
       for update skip locked
  loop
    with candidatas as (
      select ci.id as cita_id,
             (exists (select 1 from ordenes_servicio o
                       where o.cita_id = ci.id
                         and (coalesce(o.trabajos_realizados, '') <> ''
                              or exists (select 1 from orden_partes op where op.orden_id = o.id)
                              or exists (select 1 from entregas en
                                          where en.orden_id = o.id
                                            and en.estado in ('firmada', 'sin_firma'))))
             ) as con_trabajo
      from citas ci
      where ci.cotizacion_id = r.id and ci.estado in ('por_programar', 'programada')
    ),
    sin_trabajo as (
      select cita_id from candidatas where not con_trabajo
    ),
    ordenes_canceladas as (
      update ordenes_servicio set estado = 'cancelada'
       where cita_id in (select cita_id from sin_trabajo) and estado = 'abierta'
      returning id
    ),
    citas_canceladas as (
      update citas set estado = 'cancelada'
       where id in (select cita_id from sin_trabajo)
      returning id
    )
    select (select count(*) from citas_canceladas),
           (select count(*) from candidatas where con_trabajo)
      into v_canc, v_trab;

    update cotizaciones set estado = 'vencida' where id = r.id;

    perform _apunta('cotizaciones', r.id, 'vencida_sola',
      jsonb_build_object('estado', r.estado),
      jsonb_build_object('estado', 'vencida', 'hoy', v_hoy,
                         'citas_canceladas', v_canc, 'citas_con_trabajo', v_trab),
      'agente');

    n := n + 1;
    n_citas := n_citas + v_canc;
    n_trabajo := n_trabajo + v_trab;
    v_folios := v_folios || r.folio;
  end loop;

  return jsonb_build_object('ok', true, 'hoy', v_hoy, 'vencidas', n, 'folios', to_jsonb(v_folios),
                            'citas_canceladas', n_citas, 'citas_con_trabajo', n_trabajo);
end;
$fn$;

-- La llama el reloj (dueño postgres). Un admin también puede llamarla desde la API.
revoke all on function public.vencer_cotizaciones(date) from public, anon;
grant execute on function public.vencer_cotizaciones(date) to authenticated;

-- Reloj diario: 13:10 UTC = 07:10 de Mérida (después del de pólizas).
-- `cron.schedule` con el mismo nombre lo reemplaza.
select cron.schedule('vencer-cotizaciones', '10 13 * * *', 'select public.vencer_cotizaciones()');

notify pgrst, 'reload schema';

insert into _migraciones (archivo, tipo) values ('102_vencer_cotizaciones.sql', 'esquema')
on conflict (archivo) do nothing;
