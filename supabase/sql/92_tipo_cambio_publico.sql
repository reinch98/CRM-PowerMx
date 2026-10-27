-- ============================================================================
-- 92 · El dólar del DOF también en el sitio público.
--
-- El sitio (powermx.com.mx) es estático y no tiene sesión. Lee el valor por la Edge Function
-- `tipo-cambio` (GET), que entra con la cuenta `bot` y llama a esta función. Así NO se abre
-- ninguna tabla ni función a `anon`: la puerta pública es la Edge Function, y solo devuelve
-- el número del DOF y su fecha (dato público), nunca nada más.
--
--   · `tipo_cambio_publico()` — bot o admin; devuelve {valor, fecha} o `{}` si no hay dato.
--
-- Se puede repetir sin problema.
-- ============================================================================

create or replace function tipo_cambio_publico()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case
    when _es_bot_o_admin() then coalesce(
      (select jsonb_build_object('valor', t.valor, 'fecha', t.fecha)
         from tipos_cambio t where t.moneda = 'USD' order by t.fecha desc limit 1),
      '{}'::jsonb)
    else '{}'::jsonb
  end;
$$;

revoke all on function tipo_cambio_publico() from public, anon;
grant execute on function tipo_cambio_publico() to authenticated;

insert into _migraciones (archivo, tipo) values ('92_tipo_cambio_publico.sql', 'esquema')
on conflict (archivo) do nothing;
