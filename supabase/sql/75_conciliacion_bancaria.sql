-- ============================================================================
-- 75 · Conciliación bancaria (Banorte negocio, o cualquier cuenta de cuentas_financieras)
--
-- Requiere el 67 (libro único y cuentas). Flujo:
--   1. Se sube el estado de cuenta (PDF); la IA (leer-comprobante, modo estado_cuenta) PROPONE los
--      movimientos y la pantalla los muestra. registrar_estado_cuenta los guarda: el encabezado y una fila
--      por movimiento. Subir dos estados que se traslapan no duplica (huella por cuenta).
--   2. proponer_conciliacion empata cada movimiento del banco con el libro (expediente_movimientos):
--      mismo sentido (abono ↔ ingreso, cargo ↔ egreso), mismo monto, ±7 días, de esa cuenta o sin cuenta,
--      y que no esté ya conciliado. "Seguro" = un solo candidato y ese candidato no le sirve a otro
--      movimiento del banco: eso se concilia con un toque (conciliar_seguros).
--   3. Lo que no empata se registra desde el banco (comisión, gasto no capturado: registrar_desde_banco)
--      o se ignora con motivo (traspaso entre cuentas propias).
--   4. resumen_conciliacion dice también lo que está en el libro de esa cuenta y no apareció en el banco.
-- Nada se concilia solo: todo pasa por una llamada del admin.
-- ============================================================================

create table if not exists estados_cuenta (
  id             uuid primary key default gen_random_uuid(),
  cuenta_id      uuid not null references cuentas_financieras(id),
  periodo_desde  date,
  periodo_hasta  date,
  saldo_inicial  numeric(14, 2),
  saldo_final    numeric(14, 2),
  abonos         numeric(14, 2) not null default 0,
  cargos         numeric(14, 2) not null default 0,
  cuadra         boolean,                 -- saldo inicial + abonos − cargos = saldo final (±1)
  diferencia     numeric(14, 2),
  archivo        text,                    -- ruta en el bucket `finanzas`
  notas          text,
  creado_por     text,
  created_at     timestamptz not null default now()
);
create index if not exists idx_estados_cuenta on estados_cuenta (cuenta_id, periodo_hasta desc);

create table if not exists movimientos_banco (
  id             uuid primary key default gen_random_uuid(),
  estado_id      uuid not null references estados_cuenta(id) on delete cascade,
  cuenta_id      uuid not null references cuentas_financieras(id),
  fecha          date not null,
  descripcion    text,
  referencia     text,
  cargo          numeric(14, 2) not null default 0 check (cargo >= 0),
  abono          numeric(14, 2) not null default 0 check (abono >= 0),
  saldo          numeric(14, 2),
  huella         text not null,
  estado         text not null default 'pendiente' check (estado in ('pendiente', 'conciliado', 'ignorado')),
  movimiento_id  uuid references expediente_movimientos(id) on delete set null,
  nota           text,
  conciliado_por text,
  conciliado_en  timestamptz,
  created_at     timestamptz not null default now(),
  constraint mov_banco_un_lado check ((cargo > 0) <> (abono > 0)),
  constraint mov_banco_conciliado check ((estado = 'conciliado') = (movimiento_id is not null))
);
create unique index if not exists mov_banco_huella on movimientos_banco (cuenta_id, huella);
-- Un movimiento del libro se concilia con UN solo renglón del banco.
create unique index if not exists mov_banco_una_vez on movimientos_banco (movimiento_id) where movimiento_id is not null;
create index if not exists idx_mov_banco_estado on movimientos_banco (estado_id, estado, fecha);

alter table estados_cuenta    enable row level security;
alter table movimientos_banco enable row level security;
drop policy if exists admin_estados_cuenta on estados_cuenta;
drop policy if exists admin_movimientos_banco on movimientos_banco;
create policy admin_estados_cuenta    on estados_cuenta    for all to authenticated using (es_admin()) with check (es_admin());
create policy admin_movimientos_banco on movimientos_banco for all to authenticated using (es_admin()) with check (es_admin());
revoke all on estados_cuenta, movimientos_banco from anon;
grant select, insert, update, delete on estados_cuenta, movimientos_banco to authenticated;

-- ---------------------------------------------------------------------------
-- registrar_estado_cuenta: encabezado + movimientos (sin duplicar los ya subidos).
-- p_datos = { periodo_desde, periodo_hasta, saldo_inicial, saldo_final, notas,
--             movimientos: [{ fecha, descripcion, referencia, cargo, abono, saldo }] }
-- ---------------------------------------------------------------------------
create or replace function registrar_estado_cuenta(p_cuenta uuid, p_datos jsonb, p_archivo text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid := gen_random_uuid();
  v_abonos numeric;
  v_cargos numeric;
  v_ini numeric := nullif(p_datos ->> 'saldo_inicial', '')::numeric;
  v_fin numeric := nullif(p_datos ->> 'saldo_final', '')::numeric;
  v_dif numeric;
  v_total int;
  v_nuevos int;
begin
  if not es_admin() then
    raise exception 'Solo el administrador sube estados de cuenta.' using errcode = '42501';
  end if;
  if (select id from cuentas_financieras where id = p_cuenta) is null then
    raise exception 'Esa cuenta no existe.' using errcode = '22023';
  end if;
  if jsonb_typeof(p_datos -> 'movimientos') is distinct from 'array' or jsonb_array_length(p_datos -> 'movimientos') = 0 then
    raise exception 'El estado de cuenta no trae movimientos.' using errcode = '22023';
  end if;

  v_abonos := coalesce((select sum(coalesce(nullif(e ->> 'abono', '')::numeric, 0)) from jsonb_array_elements(p_datos -> 'movimientos') e), 0);
  v_cargos := coalesce((select sum(coalesce(nullif(e ->> 'cargo', '')::numeric, 0)) from jsonb_array_elements(p_datos -> 'movimientos') e), 0);
  v_dif := case when v_ini is not null and v_fin is not null then round(v_ini + v_abonos - v_cargos - v_fin, 2) end;
  v_total := jsonb_array_length(p_datos -> 'movimientos');

  insert into estados_cuenta (id, cuenta_id, periodo_desde, periodo_hasta, saldo_inicial, saldo_final,
                              abonos, cargos, cuadra, diferencia, archivo, notas, creado_por)
  values (v_id, p_cuenta, nullif(p_datos ->> 'periodo_desde', '')::date, nullif(p_datos ->> 'periodo_hasta', '')::date,
          v_ini, v_fin, v_abonos, v_cargos, case when v_dif is null then null else abs(v_dif) <= 1 end, v_dif,
          p_archivo, nullif(trim(p_datos ->> 'notas'), ''), coalesce(auth.jwt() ->> 'email', 'crm'));

  -- La huella identifica un renglón del banco: fecha, montos, texto, referencia y el número de vez que
  -- se repite igual en el mismo estado (dos comisiones idénticas el mismo día son dos renglones).
  insert into movimientos_banco (estado_id, cuenta_id, fecha, descripcion, referencia, cargo, abono, saldo, huella)
  select v_id, p_cuenta, fecha, descripcion, referencia, cargo, abono, saldo,
         md5(concat_ws('|', fecha, cargo, abono, lower(coalesce(descripcion, '')), coalesce(referencia, ''), vez))
    from (
      select *, row_number() over (partition by fecha, cargo, abono, lower(coalesce(descripcion, '')), coalesce(referencia, '')
                                   order by o) as vez
        from (
          select o,
                 (e ->> 'fecha')::date as fecha,
                 round(coalesce(nullif(e ->> 'cargo', '')::numeric, 0), 2) as cargo,
                 round(coalesce(nullif(e ->> 'abono', '')::numeric, 0), 2) as abono,
                 nullif(trim(e ->> 'descripcion'), '') as descripcion,
                 nullif(trim(e ->> 'referencia'), '') as referencia,
                 nullif(e ->> 'saldo', '')::numeric as saldo
            from jsonb_array_elements(p_datos -> 'movimientos') with ordinality as t(e, o)
           where nullif(e ->> 'fecha', '') is not null
        ) crudos
       where (cargo > 0) <> (abono > 0)
    ) validos
  on conflict (cuenta_id, huella) do nothing;
  get diagnostics v_nuevos = row_count;

  perform _apunta('estados_cuenta', v_id, 'registrar_estado_cuenta', null,
                  jsonb_build_object('movimientos', v_total, 'nuevos', v_nuevos, 'cuadra', abs(coalesce(v_dif, 0)) <= 1), 'oficina');
  return jsonb_build_object('ok', true, 'estado_id', v_id, 'movimientos', v_total, 'nuevos', v_nuevos,
                            'repetidos', v_total - v_nuevos, 'cuadra', case when v_dif is null then null else abs(v_dif) <= 1 end,
                            'diferencia', v_dif);
end;
$$;
revoke execute on function registrar_estado_cuenta(uuid, jsonb, text) from public, anon;
grant execute on function registrar_estado_cuenta(uuid, jsonb, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Candidatos del libro para un renglón del banco (interna).
-- ---------------------------------------------------------------------------
create or replace function _candidatos_banco(p_mov uuid) returns table (movimiento_id uuid, dias int)
language sql
stable
security definer
set search_path = public
as $$
  select m.id, abs(m.fecha - b.fecha)
    from movimientos_banco b
    join expediente_movimientos m
      on m.tipo = case when b.abono > 0 then 'ingreso' else 'egreso' end
     and abs(m.monto - greatest(b.abono, b.cargo)) <= 0.01
     and m.fecha between b.fecha - 7 and b.fecha + 7
     and (m.cuenta_id = b.cuenta_id or m.cuenta_id is null)
   where b.id = p_mov
     and not exists (select 1 from movimientos_banco x where x.movimiento_id = m.id)
   order by abs(m.fecha - b.fecha), (m.cuenta_id is null), m.created_at;
$$;
revoke execute on function _candidatos_banco(uuid) from public, anon, authenticated;

create or replace function proponer_conciliacion(p_estado uuid) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not es_admin() then
    raise exception 'Solo el administrador concilia.' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'mov_banco_id', b.id, 'fecha', b.fecha, 'descripcion', b.descripcion, 'referencia', b.referencia,
             'monto', greatest(b.abono, b.cargo), 'sentido', case when b.abono > 0 then 'entrada' else 'salida' end,
             'candidatos', c.lista,
             -- Seguro: un solo candidato, y ese candidato no aparece en ningún otro renglón pendiente.
             'seguro', jsonb_array_length(c.lista) = 1
                       and (select count(*) from movimientos_banco b2
                             where b2.estado = 'pendiente' and b2.id <> b.id and b2.cuenta_id = b.cuenta_id
                               and exists (select 1 from _candidatos_banco(b2.id) k
                                            where k.movimiento_id = (c.lista -> 0 ->> 'movimiento_id')::uuid)) = 0)
           order by b.fecha, b.created_at)
      from movimientos_banco b
      cross join lateral (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'movimiento_id', m.id, 'fecha', m.fecha, 'dias', k.dias, 'concepto', m.concepto,
                 'categoria', m.categoria, 'cotizacion', q.folio, 'referencia', m.referencia) order by k.dias), '[]'::jsonb) as lista
          from (select * from _candidatos_banco(b.id) limit 5) k
          join expediente_movimientos m on m.id = k.movimiento_id
          left join cotizaciones q on q.id = m.cotizacion_id
      ) c
     where b.estado_id = p_estado and b.estado = 'pendiente'), '[]'::jsonb);
end;
$$;
revoke execute on function proponer_conciliacion(uuid) from public, anon;
grant execute on function proponer_conciliacion(uuid) to authenticated;

create or replace function conciliar_movimiento(p_mov_banco uuid, p_movimiento uuid) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b movimientos_banco%rowtype;
  v_m expediente_movimientos%rowtype;
  v_tipo text;
  v_sentido text;
  v_monto numeric;
begin
  if not es_admin() then
    raise exception 'Solo el administrador concilia.' using errcode = '42501';
  end if;
  v_b := (select b from movimientos_banco b where b.id = p_mov_banco);
  v_m := (select m from expediente_movimientos m where m.id = p_movimiento);
  if v_b.id is null or v_m.id is null then raise exception 'No encontré el movimiento.' using errcode = '22023'; end if;
  if v_b.estado = 'conciliado' and v_b.movimiento_id = p_movimiento then
    return jsonb_build_object('ok', true, 'sin_cambio', true);
  end if;
  if v_b.estado <> 'pendiente' then
    raise exception 'Ese renglón del banco ya está %.', v_b.estado using errcode = '22023';
  end if;
  -- En plpgsql la condición de un IF se corta en el primer THEN: un CASE dentro del IF rompe el
  -- bloque. Por eso el sentido se calcula antes.
  v_tipo := case when v_b.abono > 0 then 'ingreso' else 'egreso' end;
  v_sentido := case when v_b.abono > 0 then 'entrada' else 'salida' end;
  v_monto := greatest(v_b.abono, v_b.cargo);
  if v_m.tipo <> v_tipo then
    raise exception 'No cuadra el sentido: el banco dice % y el libro dice %.', v_sentido, v_m.tipo using errcode = '22023';
  end if;
  if abs(v_m.monto - v_monto) > 0.01 then
    raise exception 'No cuadra el monto: el banco dice % y el libro dice %.', v_monto, v_m.monto using errcode = '22023';
  end if;
  if exists (select 1 from movimientos_banco where movimiento_id = p_movimiento) then
    raise exception 'Ese movimiento del libro ya está conciliado con otro renglón del banco.' using errcode = '22023';
  end if;

  update movimientos_banco
     set estado = 'conciliado', movimiento_id = p_movimiento,
         conciliado_por = coalesce(auth.jwt() ->> 'email', 'crm'), conciliado_en = now()
   where id = p_mov_banco;
  -- El movimiento del libro queda en la cuenta donde de verdad pasó el dinero.
  update expediente_movimientos set cuenta_id = v_b.cuenta_id where id = p_movimiento and cuenta_id is null;
  perform _apunta('movimientos_banco', p_mov_banco, 'conciliar', null,
                  jsonb_build_object('movimiento_id', p_movimiento), 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false);
end;
$$;
revoke execute on function conciliar_movimiento(uuid, uuid) from public, anon;
grant execute on function conciliar_movimiento(uuid, uuid) to authenticated;

-- Concilia de un golpe todos los "seguros" del estado.
create or replace function conciliar_seguros(p_estado uuid) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_n int := 0;
begin
  if not es_admin() then
    raise exception 'Solo el administrador concilia.' using errcode = '42501';
  end if;
  for r in
    select (e ->> 'mov_banco_id')::uuid as banco, (e -> 'candidatos' -> 0 ->> 'movimiento_id')::uuid as libro
      from jsonb_array_elements(proponer_conciliacion(p_estado)) e
     where (e ->> 'seguro')::boolean
  loop
    if not exists (select 1 from movimientos_banco where movimiento_id = r.libro)
       and (select estado from movimientos_banco where id = r.banco) = 'pendiente' then
      perform conciliar_movimiento(r.banco, r.libro);
      v_n := v_n + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'conciliados', v_n);
end;
$$;
revoke execute on function conciliar_seguros(uuid) from public, anon;
grant execute on function conciliar_seguros(uuid) to authenticated;

create or replace function desconciliar_movimiento(p_mov_banco uuid) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b movimientos_banco%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador concilia.' using errcode = '42501';
  end if;
  v_b := (select b from movimientos_banco b where b.id = p_mov_banco);
  if v_b.id is null then raise exception 'No encontré el renglón.' using errcode = '22023'; end if;
  if v_b.estado = 'pendiente' then return jsonb_build_object('ok', true, 'sin_cambio', true); end if;
  update movimientos_banco
     set estado = 'pendiente', movimiento_id = null, nota = null, conciliado_por = null, conciliado_en = null
   where id = p_mov_banco;
  perform _apunta('movimientos_banco', p_mov_banco, 'desconciliar',
                  jsonb_build_object('estado', v_b.estado, 'movimiento_id', v_b.movimiento_id), null, 'oficina');
  return jsonb_build_object('ok', true, 'sin_cambio', false);
end;
$$;
revoke execute on function desconciliar_movimiento(uuid) from public, anon;
grant execute on function desconciliar_movimiento(uuid) to authenticated;

create or replace function ignorar_movimiento_banco(p_mov_banco uuid, p_nota text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not es_admin() then
    raise exception 'Solo el administrador concilia.' using errcode = '42501';
  end if;
  if coalesce(trim(p_nota), '') = '' then
    raise exception 'Escribe por qué se ignora (por ejemplo: traspaso entre mis cuentas).' using errcode = '22023';
  end if;
  update movimientos_banco
     set estado = 'ignorado', nota = trim(p_nota), conciliado_por = coalesce(auth.jwt() ->> 'email', 'crm'), conciliado_en = now()
   where id = p_mov_banco and estado = 'pendiente';
  if not found then raise exception 'Ese renglón ya no está pendiente.' using errcode = '22023'; end if;
  perform _apunta('movimientos_banco', p_mov_banco, 'ignorar', null, jsonb_build_object('nota', trim(p_nota)), 'oficina');
  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function ignorar_movimiento_banco(uuid, text) from public, anon;
grant execute on function ignorar_movimiento_banco(uuid, text) to authenticated;

-- Registra en el libro un renglón del banco que no estaba capturado (una comisión, un gasto, un retiro)
-- y lo concilia en la misma transacción. Sin CFDI: su IVA no se acredita.
create or replace function registrar_desde_banco(p_mov_banco uuid, p_categoria text, p_concepto text default null,
                                                 p_cotizacion uuid default null) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b movimientos_banco%rowtype;
  v_tipo text;
  v_id uuid := gen_random_uuid();
begin
  if not es_admin() then
    raise exception 'Solo el administrador concilia.' using errcode = '42501';
  end if;
  v_b := (select b from movimientos_banco b where b.id = p_mov_banco);
  if v_b.id is null then raise exception 'No encontré el renglón.' using errcode = '22023'; end if;
  if v_b.estado <> 'pendiente' then raise exception 'Ese renglón ya no está pendiente.' using errcode = '22023'; end if;
  v_tipo := case when v_b.abono > 0 then 'ingreso' else 'egreso' end;
  if (v_tipo = 'ingreso') <> (p_categoria in ('cobro', 'aportacion', 'otro_ingreso')) then
    raise exception 'Esa categoría no corresponde a %.', case when v_tipo = 'ingreso' then 'una entrada' else 'una salida' end
      using errcode = '22023';
  end if;
  if p_categoria = 'cobro' and p_cotizacion is null then
    raise exception 'Un cobro va ligado a su cotización; regístralo en su Expediente.' using errcode = '22023';
  end if;

  insert into expediente_movimientos (id, cotizacion_id, tipo, categoria, fecha, concepto, monto, iva, forma,
                                      referencia, cuenta_id, notas, creado_por)
  values (v_id, p_cotizacion, v_tipo, p_categoria, v_b.fecha,
          coalesce(nullif(trim(p_concepto), ''), v_b.descripcion, 'Movimiento del banco'),
          greatest(v_b.abono, v_b.cargo), 0, 'transferencia', v_b.referencia, v_b.cuenta_id,
          'Registrado desde el estado de cuenta', coalesce(auth.jwt() ->> 'email', 'crm'));
  perform conciliar_movimiento(p_mov_banco, v_id);
  return jsonb_build_object('ok', true, 'movimiento_id', v_id);
end;
$$;
revoke execute on function registrar_desde_banco(uuid, text, text, uuid) from public, anon;
grant execute on function registrar_desde_banco(uuid, text, text, uuid) to authenticated;

-- Cómo va un estado: cuántos conciliados, pendientes e ignorados, y lo del libro que no salió en el banco.
create or replace function resumen_conciliacion(p_estado uuid) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_e estados_cuenta%rowtype;
begin
  if not es_admin() then
    raise exception 'Solo el administrador concilia.' using errcode = '42501';
  end if;
  v_e := (select e from estados_cuenta e where e.id = p_estado);
  if v_e.id is null then raise exception 'Ese estado de cuenta no existe.' using errcode = '22023'; end if;
  return jsonb_build_object(
    'estado', to_jsonb(v_e),
    'conteo', (select jsonb_build_object(
                 'total', count(*),
                 'conciliados', count(*) filter (where estado = 'conciliado'),
                 'pendientes', count(*) filter (where estado = 'pendiente'),
                 'ignorados', count(*) filter (where estado = 'ignorado'))
                 from movimientos_banco where estado_id = p_estado),
    -- En el libro de ESTA cuenta y dentro del periodo, pero sin renglón del banco.
    'solo_en_libro', coalesce((
      select jsonb_agg(jsonb_build_object('movimiento_id', m.id, 'fecha', m.fecha, 'tipo', m.tipo, 'categoria', m.categoria,
                                          'concepto', m.concepto, 'monto', m.monto) order by m.fecha)
        from expediente_movimientos m
       where m.cuenta_id = v_e.cuenta_id
         and m.fecha between coalesce(v_e.periodo_desde, '-infinity'::date) and coalesce(v_e.periodo_hasta, 'infinity'::date)
         and not exists (select 1 from movimientos_banco b where b.movimiento_id = m.id)), '[]'::jsonb));
end;
$$;
revoke execute on function resumen_conciliacion(uuid) from public, anon;
grant execute on function resumen_conciliacion(uuid) to authenticated;

-- Registro (ver 68).
insert into _migraciones (archivo, tipo) values ('75_conciliacion_bancaria.sql', 'esquema')
on conflict (archivo) do nothing;
