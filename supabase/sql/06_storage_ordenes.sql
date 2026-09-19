-- ===========================================================================
-- STORAGE DE ÓRDENES: bucket `ordenes` y políticas por rol
--
-- Lo que había: un bucket llamado `Ordenes` (con mayúscula) y dos políticas
-- que apuntaban a `ordenes` (minúscula). Storage distingue mayúsculas, así que
-- el CRM no encontraba el bucket y toda orden con fotos o firma fallaba, y las
-- políticas no protegían nada del bucket real. Además dejaban subir y listar a
-- cualquier cuenta con sesión, incluidos clientes y cuentas sin rol.
--
-- Esto crea el bucket correcto (privado, con tope de tamaño y solo imágenes) y
-- deja las políticas para admin y técnico. Se puede volver a ejecutar.
--
-- El bucket viejo `Ordenes` no se toca aquí. Cuando esté vacío se borra a mano
-- desde Storage. Antes, comprobar:
--   select count(*) from storage.objects where bucket_id = 'Ordenes';
-- ===========================================================================

-- 5 MB por archivo: las fotos se encogen a ~200 KB antes de subir y la firma
-- pesa ~10 KB, así que el tope solo frena abusos.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('ordenes', 'ordenes', false, 5242880, array['image/jpeg', 'image/png'])
on conflict (id) do update
  set file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "lee_autenticado"    on storage.objects;
drop policy if exists "sube_autenticado"   on storage.objects;
drop policy if exists "ordenes_lee"        on storage.objects;
drop policy if exists "ordenes_sube"       on storage.objects;
drop policy if exists "ordenes_actualiza"  on storage.objects;

-- Ver: admin y técnico. El portal del cliente necesitará su propia política
-- (solo las fotos de sus órdenes) cuando exista.
create policy "ordenes_lee" on storage.objects for select to authenticated
  using (bucket_id = 'ordenes' and public.mi_rol() in ('admin', 'tecnico'));

create policy "ordenes_sube" on storage.objects for insert to authenticated
  with check (bucket_id = 'ordenes' and public.mi_rol() in ('admin', 'tecnico'));

-- El CRM sube con upsert para que un reintento tras un corte no falle; eso
-- necesita permiso de actualizar. Nadie borra desde el CRM: sin política de
-- delete, solo se borra desde el panel de Supabase.
create policy "ordenes_actualiza" on storage.objects for update to authenticated
  using (bucket_id = 'ordenes' and public.mi_rol() in ('admin', 'tecnico'))
  with check (bucket_id = 'ordenes' and public.mi_rol() in ('admin', 'tecnico'));

-- Verificación: deben salir el bucket `ordenes` (privado) y tres políticas.
select id, name, public, file_size_limit from storage.buckets order by id;
select policyname, cmd, roles from pg_policies
where schemaname = 'storage' and tablename = 'objects' order by policyname;
