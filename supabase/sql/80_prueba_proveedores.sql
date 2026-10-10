-- Prueba de 80_proveedores.sql. Correr DESPUÉS del 80, el bloque COMPLETO, con la CLI:
--   npx supabase db query --linked -f supabase/sql/80_prueba_proveedores.sql
-- begin/rollback. Lleva bloques `do` para comprobar los rechazos: el editor web los mutila (ver
-- CLAUDE.md), la CLI no. Nombres "PRUEBA80" para no mezclarse con datos reales.
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);
select set_config('app.xl', (select id::text from proveedores where clave = 'xlstore'), true),
       set_config('app.prod', (select id::text from productos order by sku limit 1), true);

-- 1) Los dos de la sincronización existen y todos los vínculos de catálogo ya tienen proveedor.
select set_config('app.p1', concat(
  case when (select nombre from proveedores where clave = 'xlstore') = 'Exel Solar'
        and exists (select 1 from proveedores where clave = 'solarama')
        and (select count(*) from producto_proveedores where proveedor_id is null) = 0
        and (select count(*) from producto_proveedores pp join proveedores p on p.id = pp.proveedor_id
              where p.clave = pp.proveedor) = (select count(*) from producto_proveedores where proveedor in ('xlstore', 'solarama'))
       then 'ok' else 'FALLO' end, ' — xlstore y solarama sembrados; los vínculos de catálogo ligados'), true);

-- 2) Como viene impreso en la factura de Exel Solar, se reconoce como XLStore y aprende el alias.
-- (La llamada va en su propia sentencia: la misma sentencia no ve lo que la función escribió.)
select set_config('app.x2', coalesce(_proveedor_id('EXEL SOLAR S.A.P.I. DE C.V.', null, false)::text, ''), true);
select set_config('app.p2', concat(
  case when _clave_proveedor('EXEL SOLAR S.A.P.I. DE C.V.') = 'exelsolar'
        and current_setting('app.x2') = current_setting('app.xl')
        and (select 'EXEL SOLAR S.A.P.I. DE C.V.' = any (alias) from proveedores where clave = 'xlstore')
        and _rfc_valido('xaxx010101000') is null and _rfc_valido(' cum-010101-ab1 ') = 'CUM010101AB1'
       then 'ok' else 'FALLO' end, ' — "EXEL SOLAR S.A.P.I. DE C.V." = Exel Solar; RFC genérico = vacío'), true);

-- 3) Dos compras escritas distinto caen en el MISMO proveedor, creado solo.
insert into compras (proveedor, factura, fecha, subtotal, iva, total)
values ('Cummins PRUEBA80 México S.A. de C.V.', 'P80-1', '2001-02-01', 1000, 160, 1160),
       ('CUMMINS PRUEBA80', 'P80-2', '2001-02-02', 500, 80, 580);
select set_config('app.cum', (select proveedor_id::text from compras where factura = 'P80-1'), true);
select set_config('app.p3', concat(
  case when current_setting('app.cum') <> ''
        and (select count(distinct proveedor_id) from compras where factura in ('P80-1', 'P80-2')) = 1
       then 'ok' else 'FALLO' end, ' — "Cummins PRUEBA80 México S.A. de C.V." y "CUMMINS PRUEBA80" son uno'), true);

-- 4) Una factura recibida de ese nombre con RFC: mismo proveedor, y la ficha aprende el RFC.
insert into cfdi (uuid_fiscal, sentido, fecha, rfc_emisor, nombre_emisor, rfc_receptor, subtotal, total, por_pagar, vence)
values ('80808080-0000-4000-8000-000000000001', 'recibido', '2001-02-03', 'CPR010101AB1', 'CUMMINS PRUEBA80 SA DE CV',
        'XAXX010101000', 1000, 1160, true, '2001-03-03');
select set_config('app.p4', concat(
  case when (select proveedor_id::text from cfdi where uuid_fiscal = '80808080-0000-4000-8000-000000000001') = current_setting('app.cum')
        and (select rfc from proveedores where id = current_setting('app.cum')::uuid) = 'CPR010101AB1'
       then 'ok' else 'FALLO' end, ' — la factura con RFC cae en el mismo proveedor y le deja su RFC'), true);

-- 5) Uno parecido dado de alta a mano aparece como posible duplicado.
select set_config('app.sales', (guardar_proveedor(null, jsonb_build_object(
  'nombre', 'Cummins PRUEBA80 Sales', 'telefono', '9990000080', 'alias', jsonb_build_array('CPS 80'))) ->> 'id'), true);
insert into requisiciones (producto_id, cantidad, estado, proveedor_id)
values (current_setting('app.prod')::uuid, 2, 'pedida', current_setting('app.sales')::uuid);
select set_config('app.p5', concat(
  case when exists (select 1 from jsonb_array_elements(proveedores_parecidos()) x
                     where (x -> 'a' ->> 'id') in (current_setting('app.cum'), current_setting('app.sales'))
                       and (x -> 'b' ->> 'id') in (current_setting('app.cum'), current_setting('app.sales')))
       then 'ok' else 'FALLO' end, ' — "Cummins PRUEBA80" y "Cummins PRUEBA80 Sales" salen como parecidos'), true);

-- 6) Rechazos: RFC repetido, RFC mal escrito, nombre que ya existe, RFC genérico.
select set_config('app.p6', '', true);
do $$
declare v_ok int := 0;
begin
  begin perform guardar_proveedor(null, jsonb_build_object('nombre', 'Otra PRUEBA80', 'rfc', 'CPR010101AB1'));
  exception when sqlstate '22023' then v_ok := v_ok + 1; end;
  begin perform guardar_proveedor(null, jsonb_build_object('nombre', 'Otra PRUEBA80', 'rfc', 'ABC123'));
  exception when sqlstate '22023' then v_ok := v_ok + 1; end;
  begin perform guardar_proveedor(null, jsonb_build_object('nombre', 'cummins prueba80, s.a. de c.v.'));
  exception when sqlstate '22023' then v_ok := v_ok + 1; end;
  begin perform guardar_proveedor(null, jsonb_build_object('nombre', 'Otra PRUEBA80', 'rfc', 'XEXX010101000'));
  exception when sqlstate '22023' then v_ok := v_ok + 1; end;
  perform set_config('app.p6', concat(case when v_ok = 4 then 'ok' else 'FALLO' end,
    ' — rechaza RFC repetido, RFC mal escrito, nombre repetido y RFC genérico (', v_ok, ' de 4)'), true);
end $$;

-- 7) Unir: el pedido pasa al que queda, el nombre del que se va queda como alias, y queda rastro.
select set_config('app.u7', unir_proveedores(current_setting('app.cum')::uuid, current_setting('app.sales')::uuid)::text, true);
select set_config('app.p7', concat(
  case when not exists (select 1 from proveedores where id = current_setting('app.sales')::uuid)
        and (select count(*) from requisiciones where proveedor_id = current_setting('app.cum')::uuid) = 1
        and (select 'Cummins PRUEBA80 Sales' = any (alias) from proveedores where id = current_setting('app.cum')::uuid)
        and (select 'CPS 80' = any (alias) from proveedores where id = current_setting('app.cum')::uuid)
        and (select telefono from proveedores where id = current_setting('app.cum')::uuid) = '9990000080'
        and exists (select 1 from auditoria where tabla = 'proveedores' and accion = 'unir'
                     and registro_id = current_setting('app.cum')::uuid)
        and _proveedor_id('Cummins PRUEBA80 Sales', null, false)::text = current_setting('app.cum')
       then 'ok' else 'FALLO' end, ' — unir mueve el pedido, guarda alias y teléfono, y deja rastro'), true);

-- 8) "No son el mismo" se recuerda: la pareja ya no se propone.
select set_config('app.power', (guardar_proveedor(null, jsonb_build_object('nombre', 'Cummins PRUEBA80 Power')) ->> 'id'), true);
select set_config('app.d8a', (select count(*)::text from jsonb_array_elements(proveedores_parecidos()) x
                              where (x -> 'a' ->> 'id') = current_setting('app.power') or (x -> 'b' ->> 'id') = current_setting('app.power')), true);
select marcar_proveedores_distintos(current_setting('app.cum')::uuid, current_setting('app.power')::uuid);
select set_config('app.p8', concat(
  case when current_setting('app.d8a')::int >= 1
        and not exists (select 1 from jsonb_array_elements(proveedores_parecidos()) x
                         where (x -> 'a' ->> 'id') in (current_setting('app.cum'), current_setting('app.power'))
                           and (x -> 'b' ->> 'id') in (current_setting('app.cum'), current_setting('app.power')))
       then 'ok' else 'FALLO' end, ' — marcar "son distintos" deja de proponer la pareja'), true);

-- 9) La carpeta junta compras, facturas, pedidos y saldo por pagar.
select set_config('app.carpeta', carpeta_proveedor(current_setting('app.cum')::uuid)::text, true);
select set_config('app.p9', concat(
  case when jsonb_array_length(current_setting('app.carpeta')::jsonb -> 'compras') = 2
        and jsonb_array_length(current_setting('app.carpeta')::jsonb -> 'facturas') = 1
        and jsonb_array_length(current_setting('app.carpeta')::jsonb -> 'pedidos') = 1
        and (current_setting('app.carpeta')::jsonb -> 'resumen' ->> 'por_pagar')::numeric = 1160
        and (current_setting('app.carpeta')::jsonb -> 'resumen' ->> 'vencido')::numeric = 1160
        and exists (select 1 from jsonb_array_elements(proveedores_resumen()) x where x ->> 'id' = current_setting('app.cum'))
       then 'ok' else 'FALLO' end, ' — carpeta: 2 compras, 1 factura, 1 pedido, 1,160 por pagar (vencido)'), true);

-- 10) Expediente cerrado: llenar proveedor_id pasa; cambiar el monto sigue bloqueado.
select set_config('app.cli', gen_random_uuid()::text, true), set_config('app.cot', gen_random_uuid()::text, true),
       set_config('app.mov', gen_random_uuid()::text, true);
insert into clientes (id, nombre, telefono) values (current_setting('app.cli')::uuid, 'PRUEBA80', '9990000080');
insert into cotizaciones (id, cliente_id, tipo, estado, partidas, subtotal, descuento, iva, total)
values (current_setting('app.cot')::uuid, current_setting('app.cli')::uuid, 'venta', 'aceptada', '[]'::jsonb, 100, 0, 16, 116);
insert into expediente_movimientos (id, cotizacion_id, tipo, categoria, fecha, concepto, monto)
values (current_setting('app.mov')::uuid, current_setting('app.cot')::uuid, 'egreso', 'otro', '2001-02-05', 'PRUEBA80', 50);
update cotizaciones set expediente_cerrado_en = now() where id = current_setting('app.cot')::uuid;
update expediente_movimientos set proveedor_id = current_setting('app.cum')::uuid where id = current_setting('app.mov')::uuid;
select set_config('app.p10', '', true);
do $$
declare v_bloqueo boolean := false;
begin
  begin
    update expediente_movimientos set monto = 60 where id = current_setting('app.mov')::uuid;
  exception when sqlstate '22023' then v_bloqueo := true; end;
  perform set_config('app.p10', concat(
    case when v_bloqueo and (select proveedor_id::text from expediente_movimientos where id = current_setting('app.mov')::uuid)
                          = current_setting('app.cum')
         then 'ok' else 'FALLO' end, ' — cerrado: proveedor_id sí se llena, el monto sigue bloqueado'), true);
end $$;

-- 11) Quien no es admin no ve ni edita proveedores.
select set_config('request.jwt.claims',
  json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
select set_config('app.p11', '', true);
do $$
declare v_ok int := 0;
begin
  begin perform proveedores_resumen(); exception when sqlstate '42501' then v_ok := v_ok + 1; end;
  begin perform carpeta_proveedor(current_setting('app.cum')::uuid); exception when sqlstate '42501' then v_ok := v_ok + 1; end;
  begin perform guardar_proveedor(null, '{"nombre":"Intruso PRUEBA80"}'::jsonb); exception when sqlstate '42501' then v_ok := v_ok + 1; end;
  begin perform unir_proveedores(current_setting('app.cum')::uuid, current_setting('app.power')::uuid);
  exception when sqlstate '42501' then v_ok := v_ok + 1; end;
  perform set_config('app.p11', concat(case when v_ok = 4 then 'ok' else 'FALLO' end,
    ' — sin rol de admin: 4 de 4 rechazadas (', v_ok, ')'), true);
end $$;

select 1 as paso, current_setting('app.p1') as resultado
union all select 2, current_setting('app.p2')
union all select 3, current_setting('app.p3')
union all select 4, current_setting('app.p4')
union all select 5, current_setting('app.p5')
union all select 6, current_setting('app.p6')
union all select 7, current_setting('app.p7')
union all select 8, current_setting('app.p8')
union all select 9, current_setting('app.p9')
union all select 10, current_setting('app.p10')
union all select 11, current_setting('app.p11')
order by 1;

rollback;
