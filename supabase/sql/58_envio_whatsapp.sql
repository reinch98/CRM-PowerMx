-- ===========================================================================
-- WHATSAPP · LO QUE NECESITA EL ENVÍO POR LA API (fase 3)
--
-- La Edge Function `enviar-whatsapp` vacía la cola de la 56 con la cuenta `bot`. Le faltaba
-- una sola cosa en la base: poder LEER el PDF de la orden para mandarlo como documento. Las
-- políticas de la 06 solo dejan leer el bucket `ordenes` al admin y al técnico.
--
-- El bot NO recibe el bucket entero: solo la carpeta `enviados/`, que son las copias fechadas
-- que el admin ya decidió mandar al cliente ("Enviar al cliente", fase 4). Fotos, firmas,
-- expedientes internos y placas siguen cerradas para él.
--
-- Al final van comentados los pasos para que pg_cron despierte el envío cada minuto: esos
-- los corre Caña a mano UNA vez, después de desplegar la función (llevan un secreto).
-- Se puede repetir. Prueba: 58_prueba_envio_whatsapp.sql.
-- ===========================================================================

drop policy if exists "ordenes_bot_lee_enviados" on storage.objects;
create policy "ordenes_bot_lee_enviados" on storage.objects for select to authenticated
  using (bucket_id = 'ordenes' and name like 'enviados/%' and public.mi_rol() = 'bot');

-- El bucket se creó solo para imágenes (06). La 53 ya le agregó application/pdf; esto
-- solo lo comprueba en el resultado de abajo.

select 'política del bot sobre enviados/' as que,
       exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                and policyname = 'ordenes_bot_lee_enviados')::text as ok
union all
select 'el bucket ordenes acepta PDF',
       coalesce((select 'application/pdf' = any(allowed_mime_types) from storage.buckets where id = 'ordenes'), false)::text;

-- ---------------------------------------------------------------------------
-- PROGRAMAR EL ENVÍO CADA MINUTO — lo haces tú, una vez, DESPUÉS de desplegar la función:
--
-- a) Database → Extensions: activa pg_cron y pg_net (si no lo hiciste ya con el 54).
-- b) Inventa un texto largo al azar (es la contraseña del reloj) y guárdalo dos veces:
--      · en Edge Functions → Secrets como CRON_SECRET
--      · en la base, cifrado en el Vault:
--          select vault.create_secret('<el mismo texto>', 'enviar_whatsapp_cron');
-- c) Corre (cambia <ref> por el identificador de tu proyecto):
--
--      select cron.schedule('enviar-whatsapp', '* * * * *', $$
--        select net.http_post(
--          url := 'https://<ref>.supabase.co/functions/v1/enviar-whatsapp',
--          headers := jsonb_build_object(
--            'Content-Type', 'application/json',
--            'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets
--                               where name = 'enviar_whatsapp_cron')),
--          body := '{}'::jsonb)
--      $$);
--
-- d) Para ver que corre: select * from cron.job_run_details order by start_time desc limit 5;
--    y en la función → Logs. Para pararlo: select cron.unschedule('enviar-whatsapp');
--
-- Mientras `wa_config.envio_activo` esté apagado, la función contesta "apagado" y no manda
-- nada aunque el reloj la despierte cada minuto: el interruptor de la pantalla manda.
-- ---------------------------------------------------------------------------
