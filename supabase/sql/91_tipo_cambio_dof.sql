-- ============================================================================
-- 91 · Tipo de cambio del DOF en el encabezado, actualizado solo cada día
--
-- Pedido de Caña (26/10/2026): "un apartado en el encabezado que muestre el valor real del tipo de
-- cambio diario según el DOF, que se actualice diariamente".
--
--   · La Edge Function `tipo-cambio` lee https://dof.gob.mx/indicadores.php (el bloque "Tipo de Cambio
--     y Tasas al DD/MM/AAAA — DOLAR") y guarda el valor aquí con `registrar_tipo_cambio`.
--     Es el FIX de Banxico (serie SF43718) publicado en el DOF: el mismo número, sin token.
--   · `tipos_cambio` ya existía (sync del proveedor, 44): sigue siendo la única tabla. Cotizaciones
--     convierte los equipos en dólares con su último valor, así que lo que se ve en el encabezado es
--     exactamente lo que se aplica al cotizar.
--   · `tipo_cambio_actual()` lo lee el encabezado (solo admin; un técnico recibe `{}`).
--   · Reloj: dos veces al día (08:30 y 14:30 de Mérida). El DOF publica en la mañana; la segunda vuelta
--     cubre un retraso. Guardar el mismo día dos veces no duplica: la llave es (fecha, moneda).
--
-- Requiere pg_cron y pg_net (ya activos desde el 54/58) y el secreto del Vault `enviar_whatsapp_cron`,
-- que es el mismo CRON_SECRET que usa `enviar-whatsapp`.
-- Se puede repetir sin problema.
-- ============================================================================

create or replace function registrar_tipo_cambio(p_fecha date, p_valor numeric, p_fuente text default 'dof')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hoy       date := (now() at time zone 'America/Merida')::date;
  v_anterior  numeric;
  v_fecha_ant date;
begin
  if not _es_bot_o_admin() then
    raise exception 'Solo el conector o un administrador pueden guardar el tipo de cambio.' using errcode = '42501';
  end if;
  if p_fecha is null or p_valor is null then
    raise exception 'Falta la fecha o el valor del tipo de cambio.' using errcode = '22023';
  end if;
  -- Un dólar fuera de esto es un error de lectura, no un tipo de cambio.
  if p_valor < 5 or p_valor > 100 then
    raise exception 'Un dólar de % no es razonable: no se guardó.', p_valor using errcode = '22023';
  end if;
  -- El DOF publica el valor del día (a veces el de mañana); nunca uno de hace más de 10 días.
  if p_fecha > v_hoy + 2 or p_fecha < v_hoy - 10 then
    raise exception 'La fecha % no cabe con el día de hoy: no se guardó.', p_fecha using errcode = '22023';
  end if;

  v_anterior  := (select t.valor from tipos_cambio t where t.moneda = 'USD' and t.fecha < p_fecha order by t.fecha desc limit 1);
  v_fecha_ant := (select t.fecha from tipos_cambio t where t.moneda = 'USD' and t.fecha < p_fecha order by t.fecha desc limit 1);

  insert into tipos_cambio (fecha, moneda, valor, fuente)
  values (p_fecha, 'USD', p_valor, coalesce(nullif(trim(p_fuente), ''), 'dof'))
  on conflict (fecha, moneda) do update set valor = excluded.valor, fuente = excluded.fuente;

  return jsonb_build_object(
    'ok', true, 'fecha', p_fecha, 'valor', p_valor,
    'anterior', v_anterior, 'fecha_anterior', v_fecha_ant,
    'cambio_pct', case when v_anterior > 0 then round((p_valor - v_anterior) / v_anterior * 100, 2) end
  );
end;
$$;

revoke all on function registrar_tipo_cambio(date, numeric, text) from public, anon;
grant execute on function registrar_tipo_cambio(date, numeric, text) to authenticated;

create or replace function tipo_cambio_actual()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case
    when es_admin() then coalesce(
      (select jsonb_build_object('valor', t.valor, 'fecha', t.fecha, 'fuente', t.fuente)
         from tipos_cambio t where t.moneda = 'USD' order by t.fecha desc limit 1),
      '{}'::jsonb)
    else '{}'::jsonb
  end;
$$;

revoke all on function tipo_cambio_actual() from public, anon;
grant execute on function tipo_cambio_actual() to authenticated;

-- El reloj: 14:30 y 20:30 UTC = 08:30 y 14:30 de Mérida (sin horario de verano).
select cron.schedule('tipo-cambio-dof', '30 14,20 * * *', $$
  select net.http_post(
    url := 'https://jrnxrgusjosihgrqspja.supabase.co/functions/v1/tipo-cambio',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'enviar_whatsapp_cron')),
    body := '{}'::jsonb)
$$);

insert into _migraciones (archivo, tipo) values ('91_tipo_cambio_dof.sql', 'esquema')
on conflict (archivo) do nothing;
