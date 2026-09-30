-- Prueba de 43_quitar_producto.sql. Correr DESPUÉS del 43, el bloque completo. begin/rollback.
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);

select set_config('app.a', gen_random_uuid()::text, true),
       set_config('app.b', gen_random_uuid()::text, true);

insert into productos (id, sku, nombre, categoria, activo, publicar)
values (current_setting('app.a')::uuid, 'PRUEBA-43-A', 'Sin historia', 'refaccion', true, true),
       (current_setting('app.b')::uuid, 'PRUEBA-43-B', 'Con historia', 'refaccion', true, true);

insert into movimientos_inventario (producto_id, tipo, cantidad)
values (current_setting('app.b')::uuid, 'entrada', 2);

select set_config('app.p1', concat(quitar_producto(current_setting('app.a')::uuid),
  ' (esperado: eliminado) — existe aún: ',
  exists(select 1 from productos where id = current_setting('app.a')::uuid)), true);

select set_config('app.p2', concat(quitar_producto(current_setting('app.b')::uuid),
  ' (esperado: desactivado) — activo=',
  (select activo from productos where id = current_setting('app.b')::uuid),
  ', publicar=', (select publicar from productos where id = current_setting('app.b')::uuid),
  ', movimientos que siguen: ',
  (select count(*) from movimientos_inventario where producto_id = current_setting('app.b')::uuid)), true);

select set_config('app.p3', concat(quitar_producto(current_setting('app.b')::uuid),
  ' (esperado: sin_cambio)'), true);

select set_config('app.p4', concat(
  (select count(*) from auditoria where tabla = 'productos'
     and registro_id in (current_setting('app.a')::uuid, current_setting('app.b')::uuid)),
  ' renglones de auditoría (esperado: 2)'), true);

select current_setting('app.p1') as resultado
union all select current_setting('app.p2')
union all select current_setting('app.p3')
union all select current_setting('app.p4');

rollback;
