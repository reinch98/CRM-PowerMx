-- ---------------------------------------------------------------------------
-- 31_comparar_modo_vistas.sql — ¿miente el volcado o cambió la base?
--
-- EL PROBLEMA. `00_volcar_esquema.sql`, corrido el 26/09/2026 a las 17:55, reportó
-- `catalogo` y `resguardo_por_cliente` en `security_invoker = on`. Minutos después,
-- `30_prueba_modo_vistas.sql` dijo `off` y el técnico viendo 95 filas — lo mismo que se midió
-- el 19/09 y lo que `05_vistas_por_rol.sql` configura. Las dos cosas no pueden ser ciertas.
--
-- Solo hay dos explicaciones:
--   1. el modo sí estaba volteado y algo lo corrigió en el rato entre las dos corridas
--      (correr `30_modo_vistas.sql`, que es idempotente, lo haría);
--   2. la consulta del volcado lee mal `reloptions`, y entonces la sección de vistas de
--      `00_esquema_base.sql` no sirve — lo cual importa, porque ese archivo es el registro
--      del que habría que reconstruir la base si se pierde el proyecto.
--
-- Esto las distingue sin depender de que nadie recuerde qué corrió: pone lado a lado la
-- expresión EXACTA del volcado y una lectura directa del catálogo, sobre la misma fila y en
-- el mismo instante. Si las dos columnas coinciden, la consulta del volcado está bien y lo
-- que cambió fue la base (explicación 1). Si discrepan, el bug es mío (explicación 2).
--
-- Es un `select`. No cambia nada y se puede repetir.
-- ---------------------------------------------------------------------------

select
  c.relname                                        as vista,

  -- Tal cual lo arma el volcado, que es lo que se quiere auditar.
  case when c.reloptions is not null
       then format('with (%s)', array_to_string(c.reloptions, ', '))
       else '(sin reloptions)' end                 as lo_que_dice_el_volcado,

  -- Lectura directa, por otro camino: desarma el arreglo y busca la opción por nombre.
  coalesce((select split_part(o, '=', 2)
            from unnest(c.reloptions) o
            where split_part(o, '=', 1) = 'security_invoker'),
           'no está puesta → definer por omisión')  as security_invoker_directo,

  -- El arreglo crudo, sin interpretar: si las dos columnas de arriba se contradijeran, aquí
  -- se ve por qué. (`pg_options_to_table` no sirve aquí: devuelve varias filas y rompería la
  -- comparación de una vista por renglón.)
  coalesce(c.reloptions::text, '(null)')            as reloptions_crudo,

  -- En una vista definer, la RLS que se aplica es la del DUEÑO: por eso también se anota.
  c.relowner::regrole::text                         as dueno_de_la_vista

from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relkind = 'v'
  and c.relname in ('existencias', 'catalogo', 'resguardo_por_cliente',
                    'disponibles', 'por_reordenar')
order by c.relname;
