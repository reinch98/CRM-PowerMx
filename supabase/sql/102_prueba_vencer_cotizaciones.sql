-- Prueba de 102_vencer_cotizaciones.sql. Todo se deshace con rollback.
-- Correr con la CLI: npx supabase db query --linked -f supabase/sql/102_prueba_vencer_cotizaciones.sql
-- (consume folios de cotización y de orden: las secuencias no se revierten).
--
-- Hoy fijo = 2026-11-19. Cinco cotizaciones de prueba:
--   A borrador del 20/10, 15 días  → vence (y su cita sin trabajo se cancela)
--   B enviada del 14/11            → sigue viva
--   C aceptada del 20/09           → no vence nunca
--   D borrador del 03/11, 15 días  → venció ayer → vence (su cita CON trabajo se queda)
--   E borrador del 04/11, 15 días  → vence hoy, todavía vale → sigue viva
begin;

create temp table t (paso int, ok boolean, detalle text) on commit drop;

do $$
declare
  v_cli uuid := (select id from clientes order by created_at limit 1);
  a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); c uuid := gen_random_uuid();
  d uuid := gen_random_uuid(); e uuid := gen_random_uuid();
  cita_a uuid := gen_random_uuid(); cita_d uuid := gen_random_uuid();
  res jsonb; res2 jsonb;
begin
  insert into cotizaciones (id, cliente_id, tipo, fecha, vigencia_dias, estado, partidas) values
    (a, v_cli, 'mantenimiento', '2026-10-20', 15, 'borrador', '[]'),
    (b, v_cli, 'mantenimiento', '2026-11-14', 15, 'enviada',  '[]'),
    (c, v_cli, 'refacciones',   '2026-09-20', 15, 'aceptada', '[]'),
    (d, v_cli, 'diagnostico',   '2026-11-03', 15, 'borrador', '[]'),
    (e, v_cli, 'mantenimiento', '2026-11-04', 15, 'borrador', '[]');

  insert into citas (id, cliente_id, tipo_servicio, estado, origen, cotizacion_id) values
    (cita_a, v_cli, 'preventivo', 'por_programar', 'cotizacion', a),
    (cita_d, v_cli, 'diagnostico', 'por_programar', 'cotizacion', d);
  insert into ordenes_servicio (cliente_id, cita_id, estado) values (v_cli, cita_a, 'abierta');
  insert into ordenes_servicio (cliente_id, cita_id, estado, trabajos_realizados)
    values (v_cli, cita_d, 'abierta', 'Ya se revisó el tablero');

  res := vencer_cotizaciones('2026-11-19');

  insert into t values
    (1, (select estado from cotizaciones where id = a) = 'vencida', 'A vencida'),
    (2, (select estado from cotizaciones where id = b) = 'enviada', 'B sigue enviada'),
    (3, (select estado from cotizaciones where id = c) = 'aceptada', 'C aceptada no vence'),
    (4, (select estado from cotizaciones where id = d) = 'vencida', 'D vencida (venció ayer)'),
    (5, (select estado from cotizaciones where id = e) = 'borrador', 'E vence hoy: todavía vale'),
    (6, (select estado from citas where id = cita_a) = 'cancelada'
        and (select estado from ordenes_servicio where cita_id = cita_a) = 'cancelada',
        'Cita y orden de A sin trabajo: canceladas'),
    (7, (select estado from citas where id = cita_d) = 'por_programar'
        and (select estado from ordenes_servicio where cita_id = cita_d) = 'abierta',
        'Cita de D con trabajo: se queda'),
    (8, (select count(*) from auditoria where registro_id in (a, d) and accion = 'vencida_sola') = 2,
        'Queda rastro en auditoría'),
    (9, (res -> 'folios') @> to_jsonb((select array_agg(folio) from cotizaciones where id in (a, d))),
        concat('Devuelve los folios: ', res::text));

  res2 := vencer_cotizaciones('2026-11-19');
  insert into t values (10, (res2 ->> 'vencidas')::int = 0, concat('Repetir no vence nada más: ', res2::text));

  -- Un técnico no puede llamarla.
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select id from perfiles where rol = 'tecnico' limit 1), 'role', 'authenticated')::text, true);
  begin
    perform vencer_cotizaciones('2026-11-19');
    insert into t values (11, false, 'El técnico pudo vencer');
  exception when insufficient_privilege then
    insert into t values (11, true, 'El técnico es rechazado');
  end;
end $$;

select concat_ws(' · ', paso, case when ok then 'ok' else 'FALLA' end, detalle) as resultado
  from t order by paso;

rollback;
