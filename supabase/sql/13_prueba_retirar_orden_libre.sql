-- Prueba de la 13 (correr DESPUÉS de la 13, el bloque completo). No deja cambios: termina en rollback.
-- Necesita al menos un técnico con una cita asignada; si no hay, avisa.
begin;

do $$
declare
  v_tec uuid;
  v_cita uuid;
  v_cli uuid;
  v_filas int;
  v_res text := '';
begin
  select c.tecnico_id, c.id, c.cliente_id into v_tec, v_cita, v_cli
  from citas c join perfiles p on p.id = c.tecnico_id and p.rol = 'tecnico'
  limit 1;
  if v_tec is null then
    perform set_config('app.res', 'SIN DATOS: no hay una cita con técnico para probar', true);
    return;
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_tec, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- a) crear una orden libre debe fallar
  begin
    insert into ordenes_servicio (cliente_id, tecnico_id) values (v_cli, v_tec);
    v_res := v_res || 'a) FALLO: el técnico pudo crear una orden; ';
  exception when insufficient_privilege then
    v_res := v_res || 'a) ok: insertar orden rechazado; ';
  end;

  -- b) actualizar su cita no debe tocar ninguna fila
  update citas set estado = 'realizada' where id = v_cita;
  get diagnostics v_filas = row_count;
  v_res := v_res || case when v_filas = 0 then 'b) ok: cita intacta; ' else 'b) FALLO: actualizó ' || v_filas || ' fila(s); ' end;

  -- c) sigue viendo su cita
  select count(*) into v_filas from citas where id = v_cita;
  v_res := v_res || case when v_filas = 1 then 'c) ok: ve su cita' else 'c) FALLO: ya no ve su cita' end;

  perform set_config('app.res', v_res, true);
end $$;

select current_setting('app.res', true) as resultado;

rollback;
