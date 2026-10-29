-- ---------------------------------------------------------------------------
-- 93 · Escribirle a un cliente con una plantilla (29/10/2026)
--
-- Pedido de Caña: "¿cómo envío un mensaje a un cliente?". Con la ventana de 24 h cerrada (o un
-- cliente que nunca escribió) WhatsApp solo deja mandar una PLANTILLA aprobada por Meta. Hasta hoy
-- eso solo pasaba solo (avisos de cita, campañas); no había forma de mandar una a mano.
--
-- escribir_a_cliente(telefono, plantilla, variables) mete el envío a la MISMA cola de siempre
-- (salida_wa, origen 'manual'), así que sale por enviar-whatsapp con las mismas reglas que todo lo
-- demás: tomar_salida vuelve a revisar que la plantilla siga aprobada, que no falte ninguna
-- variable y que un número con BAJA no reciba marketing. Al salir, marcar_salida lo deja en la
-- conversación de ese número (la crea si no existía).
--
-- · Solo admin. Solo plantillas aprobadas, sin documento (la de la orden necesita su PDF y sale
--   por su propio camino) y que no sean de avisos de cita (esas arman sus variables de la cita).
-- · Las variables se aplanan y recortan (Meta rechaza saltos de línea y espacios seguidos).
-- · El mismo número con la misma plantilla en los últimos 10 minutos no se duplica: devuelve el
--   envío que ya estaba (un doble toque no le manda dos mensajes al cliente).
-- ---------------------------------------------------------------------------

alter table salida_wa drop constraint if exists salida_wa_origen_check;
alter table salida_wa add constraint salida_wa_origen_check
  check (origen = any (array['aviso', 'orden', 'respuesta', 'campana', 'manual']));

create or replace function escribir_a_cliente(p_telefono text, p_plantilla text, p_variables jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_pl wa_plantillas%rowtype;
  v_tel text := right(regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g'), 10);
  v_vars jsonb := '{}'::jsonb;
  v_var text;
  v_val text;
  v_previo uuid;
  v_id uuid := gen_random_uuid();
  v_quien text := coalesce(auth.jwt() ->> 'email', 'crm');
begin
  if not es_admin() then
    raise exception 'Solo el administrador.' using errcode = '42501';
  end if;
  if length(v_tel) <> 10 then
    raise exception 'El teléfono debe tener 10 dígitos.' using errcode = '22023';
  end if;

  v_pl := (select p from wa_plantillas p where p.nombre = p_plantilla);
  if v_pl.nombre is null then
    raise exception 'No existe la plantilla %.', p_plantilla using errcode = '22023';
  end if;
  if v_pl.estado is distinct from 'aprobada' then
    raise exception 'La plantilla % todavía no está aprobada por Meta.', p_plantilla using errcode = '22023';
  end if;
  if coalesce(v_pl.encabezado, 'ninguno') <> 'ninguno' or coalesce(v_pl.uso, '') = 'orden'
     or coalesce(v_pl.uso, '') like 'aviso:%' then
    raise exception 'Esa plantilla sale sola (avisos de cita u orden de servicio); elige otra.' using errcode = '22023';
  end if;

  -- Cada variable de la plantilla, aplanada y recortada; ninguna vacía.
  foreach v_var in array coalesce(v_pl.variables, array[]::text[]) loop
    v_val := left(btrim(regexp_replace(coalesce(p_variables ->> v_var, ''), '\s+', ' ', 'g')), 200);
    if v_val = '' then
      raise exception 'Falta el dato "%".', v_var using errcode = '22023';
    end if;
    v_vars := v_vars || jsonb_build_object(v_var, v_val);
  end loop;

  if v_pl.categoria = 'marketing'
     and exists (select 1 from wa_bajas b where b.telefono_norm = v_tel) then
    raise exception 'Ese número pidió BAJA: no se le manda publicidad.' using errcode = '22023';
  end if;

  -- Doble toque: el mismo envío hace menos de 10 minutos, todavía en camino o ya enviado.
  v_previo := (select s.id from salida_wa s
                where s.telefono_norm = v_tel and s.plantilla = v_pl.nombre and s.origen = 'manual'
                  and s.estado in ('pendiente', 'enviando', 'enviado', 'entregado', 'leido')
                  and s.created_at > now() - interval '10 minutes'
                order by s.created_at desc limit 1);
  if v_previo is not null then
    return jsonb_build_object('ok', true, 'salida_id', v_previo, 'repetido', true,
      'envio_activo', coalesce((select envio_activo from wa_config where id), false));
  end if;

  insert into salida_wa (id, llave, telefono, conversacion_id, tipo, plantilla, variables, texto, origen,
                         categoria, estado, aprobado_por, aprobado_en, creado_por)
  values (v_id, 'manual:' || v_id, v_tel,
          (select c.id from conversaciones c where c.telefono_norm = v_tel limit 1),
          'plantilla', v_pl.nombre, v_vars,
          -- Lo que queda en la conversación: la plantilla con sus datos (el texto lo aprobó Meta).
          concat('Plantilla ', v_pl.nombre, ': ',
                 (select string_agg(concat(k, ' = ', v_vars ->> k), ' · ' order by o)
                    from unnest(v_pl.variables) with ordinality t(k, o))),
          'manual', v_pl.categoria, 'pendiente', v_quien, now(), v_quien);

  return jsonb_build_object('ok', true, 'salida_id', v_id,
    'envio_activo', coalesce((select envio_activo from wa_config where id), false));
end $$;
revoke all on function escribir_a_cliente(text, text, jsonb) from public, anon;
grant execute on function escribir_a_cliente(text, text, jsonb) to authenticated;

insert into _migraciones (archivo, tipo) values ('93_escribir_a_cliente.sql', 'esquema')
on conflict (archivo) do nothing;
