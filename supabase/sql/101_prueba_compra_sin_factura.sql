-- ---------------------------------------------------------------------------
-- Prueba de 101_compra_sin_factura.sql. Correr DESPUÉS del 101, el bloque COMPLETO, con la CLI
-- (lleva bloques `do` para comprobar los rechazos; el editor web los mutila):
--   npx supabase db query --linked -f supabase/sql/101_prueba_compra_sin_factura.sql
-- Todo va en begin/rollback; el folio de la compra de prueba sí se consume.
-- ---------------------------------------------------------------------------
begin;

select set_config('app.admin', coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('app.tec', coalesce((select id::text from perfiles where rol = 'tecnico' and coalesce(activo, true) limit 1), ''), true);
select set_config('app.prod', gen_random_uuid()::text, true);
insert into productos (id, sku, nombre, categoria, activo, publicar)
values (current_setting('app.prod')::uuid, 'PIEZA-PRUEBA-101', 'Pieza de prueba (101)', 'refaccion', true, false);

-- Como el admin.
select set_config('request.jwt.claims', json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);
set local role authenticated;

select set_config('app.compra',
  (registrar_compra(jsonb_build_object('proveedor', 'Proveedor de prueba 101', 'fecha', '2026-11-19'),
                    jsonb_build_array(jsonb_build_object('producto_id', current_setting('app.prod'), 'cantidad', 1, 'costo_unitario', 10)))
   ->> 'id'), true);

-- 1) Sin motivo se rechaza.
do $$ begin
  perform cerrar_compra_sin_factura(current_setting('app.compra')::uuid, '  ');
  perform set_config('app.p1', 'FALLO: cerró sin motivo', true);
exception when others then
  perform set_config('app.p1', case when sqlstate = '22023' then 'ok — sin motivo no cierra' else 'FALLO: ' || sqlerrm end, true);
end $$;

-- 2) Con motivo cierra y guarda quién y cuándo.
select cerrar_compra_sin_factura(current_setting('app.compra')::uuid, 'Ticket de mostrador');
select set_config('app.p2', case when (select sin_factura_en is not null and sin_factura_motivo = 'Ticket de mostrador' and sin_factura_por is not null
                                         from compras where id = current_setting('app.compra')::uuid)
                                 then 'ok — cerrada con motivo, quién y cuándo' else 'FALLO: no quedó marcada' end, true);

-- 3) Repetir no cambia nada.
select set_config('app.p3', case when (cerrar_compra_sin_factura(current_setting('app.compra')::uuid, 'otra vez') ->> 'sin_cambio') = 'true'
                                 then 'ok — repetir devuelve sin_cambio' else 'FALLO: repetir cambió algo' end, true);

-- 4) Reabrir limpia los tres campos.
select reabrir_compra_sin_factura(current_setting('app.compra')::uuid);
select set_config('app.p4', case when (select sin_factura_en is null and sin_factura_motivo is null and sin_factura_por is null
                                         from compras where id = current_setting('app.compra')::uuid)
                                 then 'ok — reabrir la deja esperando su factura' else 'FALLO: no se reabrió' end, true);

-- 5) Quedó en auditoría (cerrar y reabrir).
reset role;
select set_config('app.p5', case when (select count(*) from auditoria where registro_id = current_setting('app.compra')::uuid
                                         and accion in ('cerrar_sin_factura', 'reabrir_sin_factura')) = 2
                                 then 'ok — cerrar y reabrir quedaron en auditoría' else 'FALLO: falta auditoría' end, true);

-- 6) Un técnico no puede.
select set_config('request.jwt.claims', json_build_object('sub', current_setting('app.tec'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $$ begin
  perform cerrar_compra_sin_factura(current_setting('app.compra')::uuid, 'intento');
  perform set_config('app.p6', 'FALLO: el técnico cerró una compra', true);
exception when others then
  perform set_config('app.p6', case when sqlstate = '42501' then 'ok — el técnico no puede' else 'FALLO: ' || sqlerrm end, true);
end $$;

select current_setting('app.p1') as p1, current_setting('app.p2') as p2, current_setting('app.p3') as p3,
       current_setting('app.p4') as p4, current_setting('app.p5') as p5, current_setting('app.p6') as p6;
