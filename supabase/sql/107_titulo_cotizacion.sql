-- 107 · Título de la propuesta en la cotización (26/11/2026)
--
-- Pedido de Caña: cuando a un cliente se le mandan varias opciones ("Propuesta 1 · sin aires",
-- "Propuesta 2 · toda la casa"), que el nombre de la propuesta salga en el PDF, arriba de los
-- conceptos. Texto libre y opcional; vacío = el PDF sale como siempre.
--
-- Se puede repetir sin tronar.

alter table cotizaciones add column if not exists titulo text;

alter table cotizaciones drop constraint if exists cotizaciones_titulo_largo;
alter table cotizaciones add constraint cotizaciones_titulo_largo
  check (titulo is null or char_length(titulo) <= 160);

insert into _migraciones (archivo, tipo) values ('107_titulo_cotizacion.sql', 'esquema') on conflict (archivo) do nothing;
