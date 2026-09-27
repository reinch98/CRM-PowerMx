-- ---------------------------------------------------------------------------
-- 32_comprobar_roles.sql — ¿quedaron los roles como estaban?
--
-- POR QUÉ. Los pasos 5 a 7 de `30_prueba_modo_vistas.sql` le cambian el rol a un perfil real
-- (`update perfiles set rol = 'sin_rol'`, luego `'almacenista'`) para comprobar que el
-- candado `mi_rol()` de las vistas definer sigue puesto. El `rollback` del final lo deshace…
-- **si el rollback corrió**. Si esa ejecución se cerró con un commit, la base solo tiene un
-- técnico y ahora sería almacenista: dejaría de ver sus órdenes, no podría escribir su parte
-- ni cerrar nada, y el síntoma aparecería recién cuando intentara trabajar en campo.
--
-- Es barato comprobarlo y el daño de no hacerlo es grande, así que se comprueba.
--
-- Es un `select`. No cambia nada.
--
-- QUÉ SE ESPERA: al menos un renglón con rol `admin` y al menos uno con rol `tecnico`, y
-- NINGUNO que diga «⚠». Si el técnico aparece como `almacenista` o `sin_rol`, se arregla a
-- mano en la pantalla Usuarios (o con el update que viene comentado al final).
-- ---------------------------------------------------------------------------

select
  p.email,
  p.rol,
  coalesce(p.activo, true) as activo,
  case
    -- El rol `bot` es el conector de WhatsApp: no es una persona y no sale en el menú.
    when p.rol in ('admin', 'tecnico', 'almacenista', 'cliente', 'sin_rol', 'bot') then 'conocido'
    else concat('⚠ rol raro: ', p.rol)
  end as revision
from perfiles p
order by
  case p.rol when 'admin' then 1 when 'tecnico' then 2 when 'almacenista' then 3 else 4 end,
  p.email;

-- Si hiciera falta devolverle el rol al técnico (cambia el correo por el suyo):
--   update perfiles set rol = 'tecnico' where email = 'el-correo-del-tecnico';
-- Es lo mismo que hace la pantalla Usuarios, que es por donde conviene hacerlo.
