-- ---------------------------------------------------------------------------
-- 53_bucket_ordenes_pdf.sql — el bucket `ordenes` también debe aceptar PDF.
--
-- El 06 lo creó solo para fotos y firmas (image/jpeg, image/png). La fase 4 sube ahí el PDF de
-- la orden (expedientes/, enviados/) y Storage lo rechazaba: «mime type application/pdf is not
-- supported». Esto lo agrega y sube el tope a 10 MB: un PDF con 12 fotos incrustadas pesa
-- más que una foto suelta. Las políticas del bucket no cambian (admin y técnico). Repetible.
-- ---------------------------------------------------------------------------

update storage.buckets
   set allowed_mime_types = array['image/jpeg', 'image/png', 'application/pdf'],
       file_size_limit    = 10485760
 where id = 'ordenes';

select id, allowed_mime_types, file_size_limit from storage.buckets where id = 'ordenes';
