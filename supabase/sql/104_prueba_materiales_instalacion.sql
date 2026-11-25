-- Prueba del 104 (materiales de instalación). SQL plano, todo con rollback.
-- Correr con: npx supabase db query --linked -f supabase/sql/104_prueba_materiales_instalacion.sql
begin;

select set_config('app.admin', (select id::text from perfiles where rol = 'admin' and activo limit 1), true);

-- 1. La siembra existe: 41 renglones, y cada grupo tiene exactamente una opción predeterminada.
select set_config('app.p1', case when
  (select count(*) from materiales_instalacion) >= 41
  and not exists (select 1 from materiales_instalacion where grupo is not null
                  group by grupo having count(*) filter (where predeterminado) <> 1)
  then 'ok' else 'FALLA' end, true);

-- 2. Correr la siembra otra vez no pisa un precio corregido (on conflict do nothing).
update materiales_instalacion set precio = 199 where clave = 'gas_durman';
insert into materiales_instalacion (clave, bloque, nombre, precio) values ('gas_durman', 'gas', 'x', 80)
on conflict (clave) do nothing;
select set_config('app.p2', case when (select precio from materiales_instalacion where clave = 'gas_durman') = 199
  then 'ok' else 'FALLA' end, true);

-- 3. Una cuenta que no es admin (usuario inexistente) no ve nada.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
select set_config('app.p3', case when (select count(*) from materiales_instalacion) = 0 then 'ok' else 'FALLA' end, true);

-- 4. Tampoco puede cambiar precios (RLS: el update no toca filas).
update materiales_instalacion set precio = 1;
reset role;
select set_config('app.p4', case when not exists (select 1 from materiales_instalacion where precio = 1)
  then 'ok' else 'FALLA' end, true);

-- 5. El admin ve todo y su cambio queda sellado con fecha.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('app.admin'), 'role', 'authenticated', 'email', 'prueba@crm')::text, true);
update materiales_instalacion set precio = 85 where clave = 'gas_durman';
select set_config('app.p5', case when (select count(*) from materiales_instalacion) >= 41
  and (select actualizado_por from materiales_instalacion where clave = 'gas_durman') = 'prueba@crm'
  then 'ok' else 'FALLA' end, true);
reset role;

-- 6. `anon` no tiene ningún privilegio sobre la tabla.
select set_config('app.p6', case when not has_table_privilege('anon', 'materiales_instalacion', 'select')
  and not has_table_privilege('anon', 'materiales_instalacion', 'truncate')
  then 'ok' else 'FALLA' end, true);

select current_setting('app.p1') p1, current_setting('app.p2') p2, current_setting('app.p3') p3,
       current_setting('app.p4') p4, current_setting('app.p5') p5, current_setting('app.p6') p6;
rollback;
