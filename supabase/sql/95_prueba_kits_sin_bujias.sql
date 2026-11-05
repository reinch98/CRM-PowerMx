-- Prueba del 95 (con rollback: no deja nada). Correr con la CLI:
--   npx supabase db query --linked -f supabase/sql/95_prueba_kits_sin_bujias.sql
begin;

create temporary table resultado (paso int, que text, dio text, ok boolean) on commit drop;

insert into resultado
select 1, 'Ningún kit lleva bujías', count(*)::text, count(*) = 0
  from paquete_lineas l
  join paquetes_mantenimiento p on p.id = l.paquete_id
  join productos pr on pr.id = l.producto_id
 where p.kit and (pr.nombre ~* 'buj[ií]a' or l.descripcion ~* 'buj[ií]a');

insert into resultado
select 2, 'Todo kit tiene piezas y modelos', concat(count(*), ' kits'),
       count(*) > 0
       and bool_and(exists (select 1 from paquete_lineas l where l.paquete_id = p.id))
       and bool_and(exists (select 1 from modelos_generador m where m.paquete_id = p.id))
  from paquetes_mantenimiento p where p.kit;

insert into resultado
select 3, 'Kit de 530 cc: aceite + aire',
       string_agg(concat(l.cantidad::int, 'x', pr.sku), ' + ' order by l.orden),
       string_agg(concat(l.cantidad::int, 'x', pr.sku), ' + ' order by l.orden) = '1x070185ES + 1x0E9371AS'
  from modelos_generador m
  join paquete_lineas l on l.paquete_id = m.paquete_id
  join productos pr on pr.id = l.producto_id
 where m.modelo = 'G0070311';

insert into resultado
select 4, 'Modelo con pieza del catálogo y sin kit', count(*)::text, count(*) = 0
  from modelos_generador m
 where m.paquete_id is null
   and exists (select 1 from productos p where p.activo and p.sku in (m.filtro_aceite, m.filtro_aire));

insert into resultado
select 5, 'La bujía sigue como referencia', bujia, bujia = '0E9368'
  from modelos_generador where modelo = 'G0070311';

select paso, que, dio, case when ok then 'ok' else 'FALLA' end as resultado
  from resultado order by paso;
rollback;
