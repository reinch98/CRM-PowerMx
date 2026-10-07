// ---------------------------------------------------------------------------
// enviar-whatsapp — vacía la cola de salida (SQL 56) contra la API de WhatsApp de Meta.
//
// La despierta pg_cron cada minuto (pasos al final de 58_envio_whatsapp.sql). En cada vuelta:
//   1. entra con la cuenta `bot` (nunca `service_role`);
//   2. `tomar_salida(20)` le da lo aprobado y listo — la BASE ya revisó ventana de 24 h,
//      bajas, plantilla aprobada y variables; aquí no se decide nada de eso;
//   3. lo manda a Meta uno por uno;
//   4. `marcar_salida` guarda el resultado: enviado (con el wamid), error temporal (vuelve a
//      la cola con espera) o permanente (lo revisa una persona en Por enviar → Con problema).
// Si la función se cae entre el paso 3 y el 4, la fila se queda "enviando" y la base la pasa
// a "sin confirmar" a los 10 min: NO se reintenta sola, porque podría llegar dos veces.
//
// Con `wa_config.envio_activo` apagado, `tomar_salida` contesta "apagado" y no sale nada.
//
// Quién la puede llamar: el reloj (encabezado x-cron-secret = CRON_SECRET) o un admin con su
// sesión (para "mandar ahora"). "Verify JWT" va apagado (`[functions.enviar-whatsapp]` en
// config.toml) porque el reloj no trae un token de Supabase.
//
// Secretos (Supabase → Edge Functions → Secrets):
//   WHATSAPP_TOKEN      token PERMANENTE del usuario del sistema de Meta
//   WHATSAPP_PHONE_ID   identificador del número (no el número)
//   CRON_SECRET         el mismo texto guardado en el Vault como enviar_whatsapp_cron
//   BOT_EMAIL / BOT_PASSWORD  la cuenta `bot` (ya existen, las usa el webhook)
//   WHATSAPP_API_VERSION  opcional; por omisión v23.0
// ---------------------------------------------------------------------------

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cuerpoMensaje, leerRespuesta } from "../_shared/whatsapp.js";

const json = (cuerpo: unknown, status = 200) =>
  new Response(JSON.stringify(cuerpo), { status, headers: { "Content-Type": "application/json" } });

let bot: SupabaseClient | null = null;
async function comoBot(): Promise<SupabaseClient> {
  if (bot) return bot;
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } });
  const { error } = await sb.auth.signInWithPassword({
    email: Deno.env.get("BOT_EMAIL") ?? "", password: Deno.env.get("BOT_PASSWORD") ?? "",
  });
  if (error) throw new Error(`La cuenta del bot no pudo entrar: ${error.message}`);
  bot = sb;
  return sb;
}

// Comparación en tiempo constante (el secreto del reloj no se debe poder adivinar por tiempos).
function iguales(a: string, b: string) {
  if (!a || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

async function autorizado(req: Request): Promise<boolean> {
  const secreto = Deno.env.get("CRON_SECRET") ?? "";
  if (secreto && iguales(req.headers.get("x-cron-secret") ?? "", secreto)) return true;
  // Un admin con su propia sesión ("mandar ahora" desde el CRM).
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return false;
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: u } = await sb.auth.getUser(token);
  if (!u?.user) return false;
  const { data: p } = await sb.from("perfiles").select("rol, activo").eq("id", u.user.id).maybeSingle();
  return p?.rol === "admin" && p?.activo !== false;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "solo POST" }, 405);
  if (!await autorizado(req)) return json({ error: "no autorizado" }, 401);

  const tokenMeta = Deno.env.get("WHATSAPP_TOKEN");
  const telefono = Deno.env.get("WHATSAPP_PHONE_ID");
  const version = Deno.env.get("WHATSAPP_API_VERSION") ?? "v23.0";
  if (!tokenMeta || !telefono) return json({ error: "Faltan WHATSAPP_TOKEN y WHATSAPP_PHONE_ID en los secretos." }, 500);

  let sb: SupabaseClient;
  try {
    sb = await comoBot();
  } catch (e) {
    bot = null;
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }

  const { data: lote, error } = await sb.rpc("tomar_salida", { p_n: 20 });
  if (error) {
    bot = null;   // quizá venció la sesión: la siguiente vuelta entra de nuevo
    return json({ error: error.message }, 500);
  }
  if (lote?.apagado) return json({ ok: true, apagado: true });

  const resumen = { enviados: 0, temporales: 0, fallidos: 0 };
  for (const m of lote?.mensajes ?? []) {
    let r: { ok: boolean; wamid?: string; temporal?: boolean; error?: string };
    try {
      // El PDF de la orden: enlace firmado por 1 hora, solo de ordenes/enviados/ (SQL 58).
      let enlace: string | null = null;
      if (m.documento_ruta) {
        const { data: f, error: ef } = await sb.storage.from("ordenes").createSignedUrl(m.documento_ruta, 3600);
        if (ef || !f?.signedUrl) throw Object.assign(new Error(`No se pudo leer el PDF: ${ef?.message ?? "sin enlace"}`), { permanente: true });
        enlace = f.signedUrl;
      }
      const resp = await fetch(`https://graph.facebook.com/${version}/${telefono}/messages`, {
        method: "POST",
        headers: { Authorization: `Bearer ${tokenMeta}`, "Content-Type": "application/json" },
        body: JSON.stringify(cuerpoMensaje(m, enlace)),
      });
      const cuerpo = await resp.json().catch(() => ({}));
      r = leerRespuesta(resp.status, cuerpo);
    } catch (e) {
      // Sin red hacia Meta: temporal. Un PDF que no existe o un mensaje mal armado: permanente.
      const permanente = (e as { permanente?: boolean })?.permanente || (e instanceof Error && /documento/.test(e.message));
      r = { ok: false, temporal: !permanente, error: e instanceof Error ? e.message : String(e) };
    }

    const { error: em } = await sb.rpc("marcar_salida", {
      p_id: m.id, p_ok: r.ok, p_wa_message_id: r.wamid ?? null,
      p_error: r.error ?? null, p_temporal: !!r.temporal,
    });
    if (em) console.error("No se pudo marcar", m.id, em.message);   // quedará "sin confirmar"
    if (r.ok) resumen.enviados++;
    else if (r.temporal) resumen.temporales++;
    else { resumen.fallidos++; console.error("Envío fallido", m.id, r.error); }
  }

  return json({ ok: true, ...resumen });
});
