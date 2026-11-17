-- ---------------------------------------------------------------------------
-- 99 · De la solicitud de la calculadora a la cotización (16/11/2026)
--
-- Fase 5 del plan "Calculadora solar → cotización real". La pantalla Solicitudes arma la
-- cotización con el paquete que la calculadora recomendó (precio de HOY, piezas de la
-- receta incluidas para que aparten inventario al aceptar) y, al guardarla, la liga a la
-- solicitud con `ligar_solicitud_a_cotizacion`:
--  - `solicitudes_web.cotizacion_id`: de qué solicitud salió cada cotización (y al revés).
--  - La solicitud queda "atendida", con quién y cuándo, y con el cliente de la cotización
--    (pudo crearse en ese momento). La nota interna gana una línea, no se pisa.
--  - Una solicitud ya ligada a OTRA cotización se rechaza: para cambiarla se desliga a mano.
--    Ligar dos veces la misma devuelve `sin_cambio`.
--  - Borrar la cotización (SQL 60) deja la solicitud sin cotización (on delete set null).
--  - `cotizaciones.origen` (texto libre desde la 37) vale 'sitio' en estas cotizaciones.
--
-- Se puede correr dos veces. Prueba: 99_prueba_solicitud_a_cotizacion.sql.
-- ---------------------------------------------------------------------------

alter table solicitudes_web add column if not exists cotizacion_id uuid
  references cotizaciones(id) on delete set null;

create index if not exists idx_solicitudes_web_cotizacion on solicitudes_web(cotizacion_id)
  where cotizacion_id is not null;

create or replace function ligar_solicitud_a_cotizacion(p_solicitud uuid, p_cotizacion uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_actual uuid;
  v_cliente uuid;
  v_folio text;
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if not exists (select 1 from solicitudes_web where id = p_solicitud) then
    raise exception 'La solicitud no existe.' using errcode = 'P0002';
  end if;
  if not exists (select 1 from cotizaciones where id = p_cotizacion) then
    raise exception 'La cotización no existe.' using errcode = 'P0002';
  end if;

  v_actual := (select cotizacion_id from solicitudes_web where id = p_solicitud);
  v_cliente := (select cliente_id from cotizaciones where id = p_cotizacion);
  v_folio := (select folio::text from cotizaciones where id = p_cotizacion);

  if v_actual = p_cotizacion then
    return jsonb_build_object('ok', true, 'sin_cambio', true, 'folio', v_folio);
  end if;
  if v_actual is not null then
    raise exception 'Esta solicitud ya está ligada a otra cotización.' using errcode = '22023';
  end if;

  update solicitudes_web set
    cotizacion_id = p_cotizacion,
    cliente_id = coalesce(v_cliente, cliente_id),
    estado = 'atendida',
    atendida_por = coalesce(auth.jwt() ->> 'email', 'crm'),
    atendida_en = now(),
    nota_interna = left(concat_ws(E'\n', nullif(nota_interna, ''),
                                  format('Cotización %s creada con el paquete de la calculadora.', v_folio)), 1000)
  where id = p_solicitud;

  update cotizaciones set origen = coalesce(origen, 'sitio') where id = p_cotizacion;

  perform _apunta('solicitudes_web', p_solicitud, 'ligar_cotizacion', null,
                  jsonb_build_object('cotizacion_id', p_cotizacion, 'folio', v_folio), 'oficina');

  return jsonb_build_object('ok', true, 'sin_cambio', false, 'folio', v_folio);
end $$;

revoke all on function ligar_solicitud_a_cotizacion(uuid, uuid) from public, anon;
grant execute on function ligar_solicitud_a_cotizacion(uuid, uuid) to authenticated;

insert into _migraciones (archivo, tipo) values ('99_solicitud_a_cotizacion.sql', 'esquema')
on conflict (archivo) do nothing;
