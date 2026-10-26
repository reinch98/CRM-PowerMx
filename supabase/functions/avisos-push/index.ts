// ---------------------------------------------------------------------------
// avisos-push — lo que la pantalla necesita para los avisos en el celular (SQL 90).
//
//   { "accion": "clave" }   la llave PÚBLICA VAPID, para que el navegador se suscriba
//   { "accion": "probar" }  manda un aviso de prueba a los dispositivos de quien pregunta
//
// Solo admin, con su propia sesión: lee sus suscripciones por RLS (`push_propias`). La llave
// privada nunca sale de aquí. "Verify JWT" va apagado (`[functions.avisos-push]` en config.toml)
// y la función valida sola con `auth.getUser`, igual que `media-whatsapp`.
// Secretos: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_CONTACTO (los pone
// `node scripts/generar_llaves_avisos.mjs`).
// ---------------------------------------------------------------------------

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { mandarPush } from "../_shared/webpush.js";

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

  const publica = Deno.env.get("VAPID_PUBLIC_KEY");
  const privada = Deno.env.get("VAPID_PRIVATE_KEY");
  if (!publica || !privada) {
    return json({ error: "Faltan las llaves de avisos: corre `node scripts/generar_llaves_avisos.mjs`." }, 500);
  }

  const { accion } = await req.json().catch(() => ({}));
  if (accion === "clave") return json({ ok: true, publica });

  if (accion === "probar") {
    const { data: mias, error } = await sb.from("push_suscripciones").select("endpoint, p256dh, auth").eq("activo", true);
    if (error) return json({ error: error.message }, 500);
    const vapid = { publica, privada, contacto: Deno.env.get("VAPID_CONTACTO") ?? "https://crm.powermx.com.mx" };
    const aviso = { titulo: "WhatsApp · Prueba", cuerpo: "Así te va a llegar el aviso de un mensaje nuevo.", url: "/?ir=whatsapp", etiqueta: "prueba" };
    let enviados = 0;
    const fallas: string[] = [];
    for (const s of mias ?? []) {
      const r = await mandarPush(s, aviso, vapid);
      if (r.ok) enviados++;
      else fallas.push(r.vivo === false ? "ese dispositivo ya no recibe avisos (vuelve a activarlos)" : (r.error || `HTTP ${r.status}`));
      if (r.vivo === false) await sb.from("push_suscripciones").delete().eq("endpoint", s.endpoint);
    }
    return json({ ok: true, enviados, de: (mias ?? []).length, fallas });
  }

  return json({ error: "Acción desconocida." }, 400);
});
