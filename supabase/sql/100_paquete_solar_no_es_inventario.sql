-- ---------------------------------------------------------------------------
-- 100 · Un paquete solar nunca aparta inventario (16/11/2026)
--
-- El problema: un paquete solar (PKG-STARTER, PKG-ESSENTIAL…) es un producto del catálogo
-- (`productos.categoria = 'paquete_solar'`) pero NO existe en el estante: es una receta
-- (`paquete_solar_lineas`). Si entraba a una cotización con su `producto_id` (desde el
-- buscador de Cotizaciones), al aceptarla `cambiar_estado_cotizacion` lo apartaba, creaba
-- una requisición para pedírselo al proveedor y el almacén lo ponía en el surtido.
--
-- La regla vive donde nace el dato, no en cada función que lee las partidas:
--  - Disparador `paquete_solar_no_es_inventario` (BEFORE INSERT / UPDATE OF partidas en
--    `cotizaciones`): a toda partida cuyo `producto_id` sea un paquete solar le quita el
--    `producto_id` y le deja `paquete_sku`. Así la partida es LIBRE para todos los que
--    leen partidas (aceptar, liberar, requisiciones, surtido, costo del Expediente), sin
--    redefinir ninguno. Las piezas reales del paquete entran aparte, a $0, incluidas y con
--    su `producto_id` (src/lib/calculoSolar.js, fase 5 de la calculadora): esas sí apartan.
--  - NO toca una cotización que ya estaba ACEPTADA: si apartó el paquete antes de este
--    script, al salir de "aceptada" tiene que poder liberarlo con las mismas partidas.
--  - Corrección única: las cotizaciones en borrador o enviada con un paquete como producto
--    se limpian ya; las requisiciones PENDIENTES de un paquete se cancelan con nota. Las
--    aceptadas, sus apartados y lo ya pedido al proveedor se dejan y se REPORTAN al final,
--    para revisarlas a mano.
--
-- Se puede correr dos veces. Prueba: 100_prueba_paquete_solar_no_es_inventario.sql.
-- ---------------------------------------------------------------------------

-- Las partidas sin el producto_id de los paquetes solares (internas; misma regla en la
-- corrección y en el disparador).
create or replace function _partidas_sin_paquete_inventario(p jsonb) returns jsonb
language sql stable set search_path = public as $$
  select case when jsonb_typeof(p) <> 'array' then p else coalesce((
    select jsonb_agg(
             case when pr.id is not null
                  then (e.v - 'producto_id') || jsonb_build_object('producto_id', null, 'paquete_sku', pr.sku)
                  else e.v end
             order by e.i)
    from jsonb_array_elements(p) with ordinality as e(v, i)
    left join productos pr
      on pr.categoria = 'paquete_solar'
     and jsonb_typeof(e.v) = 'object'
     and nullif(e.v ->> 'producto_id', '') is not null
     and pr.id::text = e.v ->> 'producto_id'
  ), '[]'::jsonb) end
$$;

create or replace function _paquete_solar_no_es_inventario() returns trigger
language plpgsql set search_path = public as $$
begin
  -- Una cotización ya aceptada se deja como está: sus apartados dependen de sus partidas.
  if tg_op = 'UPDATE' and old.estado = 'aceptada' then
    return new;
  end if;
  new.partidas := _partidas_sin_paquete_inventario(new.partidas);
  return new;
end $$;

revoke all on function _partidas_sin_paquete_inventario(jsonb) from public, anon;
revoke all on function _paquete_solar_no_es_inventario() from public, anon;

drop trigger if exists paquete_solar_no_es_inventario on cotizaciones;
create trigger paquete_solar_no_es_inventario
  before insert or update of partidas on cotizaciones
  for each row execute function _paquete_solar_no_es_inventario();

-- ---- Corrección única de lo que ya existe ----

-- Borradores y enviadas con un paquete como producto: se limpian (el disparador lo hace).
update cotizaciones c
   set partidas = c.partidas
 where c.estado in ('borrador', 'enviada')
   and exists (select 1 from jsonb_array_elements(coalesce(c.partidas, '[]'::jsonb)) e
                 join productos pr on pr.id::text = e ->> 'producto_id'
                where pr.categoria = 'paquete_solar');

-- Requisiciones pendientes de un paquete: no hay qué pedirle al proveedor.
update requisiciones r
   set estado = 'cancelada',
       notas = concat_ws(E'\n', nullif(r.notas, ''),
                         'Cancelada (SQL 100): un paquete solar no se pide al proveedor; se piden sus piezas.'),
       updated_at = now()
  from productos pr
 where pr.id = r.producto_id and pr.categoria = 'paquete_solar' and r.estado = 'pendiente';

insert into _migraciones (archivo, tipo) values ('100_paquete_solar_no_es_inventario.sql', 'esquema')
on conflict (archivo) do nothing;

-- Lo que queda para revisar a mano (no se toca solo).
select
  (select count(*) from cotizaciones c
    where c.estado = 'aceptada'
      and exists (select 1 from jsonb_array_elements(coalesce(c.partidas, '[]'::jsonb)) e
                    join productos pr on pr.id::text = e ->> 'producto_id'
                   where pr.categoria = 'paquete_solar')) as aceptadas_con_paquete_como_producto,
  (select coalesce(sum(case when m.tipo = 'apartado' then m.cantidad
                            when m.tipo = 'libera_apartado' then -m.cantidad else 0 end), 0)
     from movimientos_inventario m join productos pr on pr.id = m.producto_id
    where pr.categoria = 'paquete_solar') as paquetes_apartados_hoy,
  (select count(*) from requisiciones r join productos pr on pr.id = r.producto_id
    where pr.categoria = 'paquete_solar' and r.estado = 'pedida') as paquetes_ya_pedidos_al_proveedor;
