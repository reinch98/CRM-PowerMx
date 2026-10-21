// ---------------------------------------------------------------------------
// media-whatsapp — trae de Meta las fotos, documentos y audios que el webhook no guardó
// (SQL 87): los que llegaron antes de este cambio, o uno que falló al llegar.
//
// Solo el admin, con su propia sesión: las funciones de la base (`media_pendientes`,
// `guardar_media_wa`) y el bucket `whatsapp` ya lo dejan pasar, así que no hace falta la
// cuenta del bot. Cuerpo:
//   { "mensaje": "<uuid>" }   ese mensaje, aunque ya haya fallado antes
//   {}                        hasta 20 pendientes de los últimos 30 días
// Meta borra los archivos a los 30 días: lo anterior ya no se puede traer.
//
// "Verify JWT" va apagado (`[functions.media-whatsapp]` en config.toml) y la función valida
// sola con `auth.getUser`, igual que `leer-placa`.
// Secretos: WHATSAPP_TOKEN (el mismo de `enviar-whatsapp`), WHATSAPP_API_VERSION opcional.
// ---------------------------------------------------------------------------

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { bajarMedia } from "../_shared/mediaWa.js";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (cuerpo: unknown, status = 200) =>
  new Response(JSON.stringify(cuerpo), { status, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "solo POST" }, 405);

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "Inicia sesión." }, 401);
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: u } = await sb.auth.getUser(token);
  if (!u?.user) return json({ error: "La sesión venció: vuelve a entrar." }, 401);
  const { data: p } = await sb.from("perfiles").select("rol, activo").eq("id", u.user.id).maybeSingle();
  if (p?.rol !== "admin" || p?.activo === false) return json({ error: "Solo el administrador." }, 403);

  const cuerpo = await req.json().catch(() => ({}));
  const mensaje = typeof cuerpo?.mensaje === "string" ? cuerpo.mensaje : null;

  const { data: lista, error } = await sb.rpc("media_pendientes", { p_n: 20, p_mensaje: mensaje });
  if (error) return json({ error: error.message }, 500);

  const ajustes = {
    sb,
    token: Deno.env.get("WHATSAPP_TOKEN"),
    version: Deno.env.get("WHATSAPP_API_VERSION") ?? "v23.0",
  };
  const resumen = { guardados: 0, fallidos: 0, errores: [] as string[] };
  // Uno por uno: son pocos y así no se le pega a Meta con ráfagas.
  for (const m of lista ?? []) {
    const r = await bajarMedia(ajustes, m);
    if (r.ok) resumen.guardados++;
    else { resumen.fallidos++; if (r.error) resumen.errores.push(r.error); }
  }
  return json({ ok: true, revisados: (lista ?? []).length, ...resumen, errores: [...new Set(resumen.errores)] });
});
