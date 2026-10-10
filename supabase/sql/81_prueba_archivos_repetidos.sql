-- Prueba de 81_archivos_repetidos.sql. Correr DESPUÉS del 81, el bloque COMPLETO, con la CLI:
--   npx supabase db query --linked -f supabase/sql/81_prueba_archivos_repetidos.sql
-- begin/rollback, con bloques `do` para los rechazos (el editor web los mutila; la CLI no).
-- Huellas inventadas (aaaa…, bbbb…) y rutas "prueba81/": no tocan archivos reales.
begin;

select set_config('app.admin',
  coalesce((select id::text from perfiles where rol = 'admin' and coalesce(activo, true) limit 1), ''), true);
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated')::text, true);
select set_config('app.h1', repeat('a', 64), true), set_config('app.h2', repeat('b', 64), true),
       set_config('app.h3', repeat('c', 64), true), set_config('app.h4', repeat('d', 64), true),
       set_config('app.h5', repeat('e', 64), true), set_config('app.m1', gen_random_uuid()::text, true),
       set_config('app.cuenta', (select id::text from cuentas_financieras order by created_at limit 1), true);

-- 1) Un gasto con su ticket: se registra y luego aparece como "ya registrado", con el dónde.
select anotar_archivo('finanzas', 'prueba81/a.jpg', current_setting('app.h1'), 'ticket.jpg');
insert into expediente_movimientos (id, tipo, categoria, fecha, concepto, monto, archivo)
values (current_setting('app.m1')::uuid, 'egreso', 'otro', '2001-03-01', 'PRUEBA81', 250, 'prueba81/a.jpg');
select set_config('app.r1', archivo_repetido(current_setting('app.h1'))::text, true);
select set_config('app.p1', concat(
  case when (current_setting('app.r1')::jsonb ->> 'repetido')::boolean
        and current_setting('app.r1')::jsonb ->> 'donde' like '%un gasto del 01/03/2001 por $250.00%'
       then 'ok' else 'FALLO' end, ' — ', current_setting('app.r1')::jsonb ->> 'donde'), true);

-- 2) El mismo archivo con otro nombre, como otro gasto: rechazado al guardar.
select anotar_archivo('finanzas', 'prueba81/otra-vez.jpg', current_setting('app.h1'), 'copia.jpg');
select set_config('app.p2', '', true);
do $$
declare v_msg text;
begin
  begin
    insert into expediente_movimientos (tipo, categoria, fecha, concepto, monto, archivo)
    values ('egreso', 'otro', '2001-03-02', 'PRUEBA81 copia', 250, 'prueba81/otra-vez.jpg');
  exception when sqlstate '22023' then v_msg := sqlerrm; end;
  perform set_config('app.p2', concat(case when v_msg like 'Ese archivo ya está registrado%' then 'ok' else 'FALLO' end,
    ' — el segundo gasto con el mismo archivo se rechaza: ', coalesce(v_msg, '(no se rechazó)')), true);
end $$;

-- 3) Y tampoco entra a la bandeja de Finanzas.
select set_config('app.p3', '', true);
do $$
declare v_ok boolean := false;
begin
  begin
    perform registrar_documento('ticket', 'documentos/' || current_setting('app.h1') || '.jpg', 'copia.jpg', 'image/jpeg',
                                current_setting('app.h1'), 'manual', null, '[]'::jsonb);
  exception when sqlstate '22023' then v_ok := true; end;
  perform set_config('app.p3', concat(case when v_ok then 'ok' else 'FALLO' end,
    ' — la bandeja rechaza un archivo ya registrado en el libro'), true);
end $$;

-- 4) Un documento RECHAZADO en la bandeja no bloquea; uno vivo sí.
insert into documentos (tipo, archivo, nombre_original, hash_sha256, estado)
values ('ticket', 'documentos/p81-rechazado.jpg', 'rechazado.jpg', current_setting('app.h2'), 'rechazado');
select anotar_archivo('finanzas', 'prueba81/b.jpg', current_setting('app.h2'), 'b.jpg');
insert into expediente_movimientos (tipo, categoria, fecha, concepto, monto, archivo)
values ('egreso', 'otro', '2001-03-03', 'PRUEBA81 b', 90, 'prueba81/b.jpg');
select registrar_documento('ticket', 'documentos/p81-vivo.jpg', 'vivo.jpg', 'image/jpeg',
                           current_setting('app.h3'), 'manual', null, '[]'::jsonb);
select anotar_archivo('finanzas', 'prueba81/c.jpg', current_setting('app.h3'), 'c.jpg');
select set_config('app.p4', '', true);
do $$
declare v_bloqueo boolean := false;
begin
  begin
    insert into expediente_movimientos (tipo, categoria, fecha, concepto, monto, archivo)
    values ('egreso', 'otro', '2001-03-04', 'PRUEBA81 c', 90, 'prueba81/c.jpg');
  exception when sqlstate '22023' then v_bloqueo := true; end;
  perform set_config('app.p4', concat(
    case when v_bloqueo and exists (select 1 from expediente_movimientos where concepto = 'PRUEBA81 b')
         then 'ok' else 'FALLO' end, ' — rechazado en la bandeja no bloquea; vivo en la bandeja sí'), true);
end $$;

-- 5) Desde la bandeja (p_origen = documentos) no se mira la propia bandeja; desde otro lado, sí.
select set_config('app.p5', concat(
  case when not (archivo_repetido(current_setting('app.h3'), 'dinero', 'documentos') ->> 'repetido')::boolean
        and (archivo_repetido(current_setting('app.h3')) ->> 'repetido')::boolean
        and archivo_repetido(current_setting('app.h3')) ->> 'donde' like 'en la bandeja de Finanzas (por revisar%'
       then 'ok' else 'FALLO' end, ' — la bandeja deja su propio duplicado a registrar_documento'), true);

-- 6) Subido para leer y no guardado: no cuenta. Cambiar el archivo de un gasto por una copia de sí
--    mismo tampoco (se excluye el propio registro).
select anotar_archivo('finanzas', 'prueba81/solo-leido.pdf', current_setting('app.h4'), 'leido.pdf');
select anotar_archivo('finanzas', 'prueba81/a-renombrado.jpg', current_setting('app.h1'), 'a.jpg');
update expediente_movimientos set archivo = 'prueba81/a-renombrado.jpg' where id = current_setting('app.m1')::uuid;
select set_config('app.p6', concat(
  case when not (archivo_repetido(current_setting('app.h4')) ->> 'repetido')::boolean
        and (select archivo from expediente_movimientos where id = current_setting('app.m1')::uuid) = 'prueba81/a-renombrado.jpg'
       then 'ok' else 'FALLO' end, ' — leer sin guardar no cuenta; el propio gasto puede cambiar su archivo'), true);

-- 7) Compras va aparte: la misma factura puede estar en Finanzas y en UNA compra, no en dos.
select anotar_archivo('compras', 'prueba81/f.pdf', current_setting('app.h1'), 'factura.pdf');
insert into compras (proveedor, factura, fecha, archivo_pdf) values ('PRUEBA81 Proveedor', 'P81-1', '2001-03-05', 'prueba81/f.pdf');
select anotar_archivo('compras', 'prueba81/g.pdf', current_setting('app.h1'), 'factura-copia.pdf');
select set_config('app.p7', '', true);
do $$
declare v_bloqueo boolean := false;
begin
  begin
    insert into compras (proveedor, factura, fecha, archivo_pdf) values ('PRUEBA81 Proveedor', 'P81-2', '2001-03-06', 'prueba81/g.pdf');
  exception when sqlstate '22023' then v_bloqueo := true; end;
  perform set_config('app.p7', concat(
    case when v_bloqueo and exists (select 1 from compras where factura = 'P81-1')
          and archivo_repetido(current_setting('app.h1'), 'compras') ->> 'donde' like 'en la compra % de PRUEBA81 Proveedor, factura P81-1%'
         then 'ok' else 'FALLO' end, ' — compras: la primera entra, la segunda con el mismo PDF se rechaza'), true);
end $$;

-- 8) El mismo estado de cuenta no se guarda dos veces.
select anotar_archivo('finanzas', 'estados/' || current_setting('app.h5') || '.pdf', current_setting('app.h5'), 'estado.pdf');
insert into estados_cuenta (cuenta_id, periodo_desde, periodo_hasta, archivo)
values (current_setting('app.cuenta')::uuid, '2001-03-01', '2001-03-31', 'estados/' || current_setting('app.h5') || '.pdf');
select set_config('app.p8', '', true);
do $$
declare v_bloqueo boolean := false;
begin
  begin
    insert into estados_cuenta (cuenta_id, periodo_desde, periodo_hasta, archivo)
    values (current_setting('app.cuenta')::uuid, '2001-03-01', '2001-03-31', 'estados/' || current_setting('app.h5') || '.pdf');
  exception when sqlstate '22023' then v_bloqueo := true; end;
  perform set_config('app.p8', concat(
    case when v_bloqueo and archivo_repetido(current_setting('app.h5')) ->> 'donde' like 'en el estado de cuenta de % del 01/03/2001 al 31/03/2001'
         then 'ok' else 'FALLO' end, ' — un estado de cuenta repetido se detecta antes de leerlo y se rechaza'), true);
end $$;

-- 9) Quien no es admin no consulta ni anota.
select set_config('request.jwt.claims',
  json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
select set_config('app.p9', '', true);
do $$
declare v_ok int := 0;
begin
  begin perform archivo_repetido(current_setting('app.h1')); exception when sqlstate '42501' then v_ok := v_ok + 1; end;
  begin perform anotar_archivo('finanzas', 'x', current_setting('app.h1')); exception when sqlstate '42501' then v_ok := v_ok + 1; end;
  perform set_config('app.p9', concat(case when v_ok = 2 then 'ok' else 'FALLO' end, ' — sin rol de admin: 2 de 2 rechazadas'), true);
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
order by 1;

rollback;
