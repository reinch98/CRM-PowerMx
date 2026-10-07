-- ---------------------------------------------------------------------------
-- Prueba de 58_envio_whatsapp.sql. Solo lee el catálogo: no inserta en Storage (Supabase
-- protege sus tablas de cambios directos) ni cambia nada. Se puede correr las veces que sea.
-- ---------------------------------------------------------------------------

select
  case when exists (select 1 from pg_policies
                     where schemaname = 'storage' and tablename = 'objects' and policyname = 'ordenes_bot_lee_enviados'
                       and cmd = 'SELECT'
                       and qual like '%enviados/%' and qual like '%bot%' and qual like '%ordenes%')
       then 'ok' else 'FALLO' end || ' — el bot solo lee ordenes/enviados/ (y solo lectura)' as p1,
  case when not exists (select 1 from pg_policies
                         where schemaname = 'storage' and tablename = 'objects'
                           and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL') and qual like '%bot%')
       then 'ok' else 'FALLO' end || ' — el bot no tiene ninguna política para subir, cambiar ni borrar' as p2,
  case when (select 'application/pdf' = any(allowed_mime_types) from storage.buckets where id = 'ordenes')
       then 'ok' else 'FALLO: corre primero el 53' end || ' — el bucket ordenes acepta PDF' as p3,
  case when exists (select 1 from perfiles where rol = 'bot' and coalesce(activo, true))
       then 'ok' else 'FALLO' end || ' — existe la cuenta bot activa' as p4,
  case when has_function_privilege('authenticated', 'tomar_salida(int)', 'execute')
        and has_function_privilege('authenticated', 'marcar_salida(uuid, boolean, text, text, boolean)', 'execute')
        and has_function_privilege('authenticated', 'registrar_estado_wa(text, text, text)', 'execute')
        and has_function_privilege('authenticated', 'registrar_baja(text, text, text)', 'execute')
       then 'ok' else 'FALLO: corre primero el 56' end || ' — las funciones de la cola están al alcance del bot' as p5;
