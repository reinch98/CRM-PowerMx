// ---------------------------------------------------------------------------
// tipo-cambio — guarda el tipo de cambio del DOF (SQL 91).
//
// La despierta pg_cron dos veces al día (08:30 y 14:30 de Mérida; ver el final de
// 91_tipo_cambio_dof.sql). En cada vuelta:
//   1. baja https://dof.gob.mx/indicadores.php (SIN "www": el certificado de www.dof.gob.mx no
//      coincide y la conexión falla);
//   2. saca el bloque "Tipo de Cambio y Tasas al DD/MM/AAAA — DOLAR" (`_shared/tipoCambio.js`);
//   3. si lo que leyó no tiene sentido (página distinta, dólar fuera de rango, fecha lejana) NO
//      guarda nada y lo dice: un número malo con cara de bueno se cobraría en las cotizaciones;
//   4. entra con la cuenta `bot` (nunca `service_role`) y llama `registrar_tipo_cambio`, que
//      vuelve a validar y guarda por (fecha, moneda): repetir el mismo día no duplica.
//
// Quién la puede llamar: el reloj (encabezado x-cron-secret = CRON_SECRET) o un admin con su
// sesión (el botón "Actualizar" de la franja del encabezado). "Verify JWT" va apagado
// (`[functions.tipo-cambio]` en config.toml) porque el reloj no trae un token de Supabase.
//
// Secretos: CRON_SECRET, BOT_EMAIL y BOT_PASSWORD (los tres ya existen). No necesita ninguno nuevo.
// ---------------------------------------------------------------------------

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { URL_DOF, leerDof, fechaPlausible } from "../_shared/tipoCambio.js";

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
  // Un admin con su propia sesión (botón "Actualizar" del encabezado).
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

// 'AAAA-MM-DD' de hoy en hora de Mérida (en-CA escribe la fecha en ese orden).
const hoyMerida = () => new Date().toLocaleDateString("en-CA", { timeZone: "America/Merida" });

// Lectura pública para el sitio (GET): solo {valor, fecha} del DOF, con CORS para powermx.com.mx
// y caché de una hora. Entra como `bot`; no abre nada a `anon`.
const ORIGENES = (Deno.env.get("SOLICITUD_ORIGENES") ??
  "https://powermx.com.mx,https://www.powermx.com.mx")
  .split(",").map((s) => s.trim()).filter(Boolean);

async function lecturaPublica(req: Request): Promise<Response> {
  const origen = req.headers.get("origin") ?? "";
  const h: Record<string, string> = {
    "Content-Type": "application/json",
    "Vary": "Origin",
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    "Cache-Control": "public, max-age=3600",
  };
  if (ORIGENES.includes(origen)) h["Access-Control-Allow-Origin"] = origen;
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: h });
  try {
    const sb = await comoBot();
    const { data, error } = await sb.rpc("tipo_cambio_publico");
    if (error) {
      bot = null;
      return new Response(JSON.stringify({ error: "sin dato" }), { status: 502, headers: { ...h, "Cache-Control": "no-store" } });
    }
    return new Response(JSON.stringify(data ?? {}), { status: 200, headers: h });
  } catch {
    bot = null;
    return new Response(JSON.stringify({ error: "sin dato" }), { status: 502, headers: { ...h, "Cache-Control": "no-store" } });
  }
}

Deno.serve(async (req) => {
  if (req.method === "GET" || req.method === "OPTIONS") return lecturaPublica(req);
  if (req.method !== "POST") return json({ error: "solo POST" }, 405);
  if (!await autorizado(req)) return json({ error: "no autorizado" }, 401);

  // 1. Bajar la página del DOF (con tope de espera: un DOF colgado no debe colgar al reloj).
  let html: string;
  try {
    const r = await fetch(URL_DOF, {
      headers: { "User-Agent": "Mozilla/5.0 (PowerMx CRM)", "Accept-Language": "es-MX,es;q=0.9" },
      signal: AbortSignal.timeout(20000),
    });
    if (!r.ok) return json({ ok: false, error: `El DOF respondió ${r.status}.` }, 502);
    html = await r.text();
  } catch (e) {
    return json({ ok: false, error: `No se pudo abrir el DOF: ${(e as Error).message}` }, 502);
  }

  // 2 y 3. Leer y comprobar que tenga sentido.
  let dato;
  try {
    dato = leerDof(html);
  } catch (e) {
    return json({ ok: false, error: (e as Error).message }, 502);
  }
  const hoy = hoyMerida();
  if (!fechaPlausible(dato.fecha, hoy)) {
    return json({ ok: false, error: `El DOF trae el dólar del ${dato.fecha}, que no cabe con hoy (${hoy}): no se guardó.` }, 502);
  }

  // 4. Guardarlo (la base vuelve a validar).
  try {
    const sb = await comoBot();
    const { data, error } = await sb.rpc("registrar_tipo_cambio", {
      p_fecha: dato.fecha, p_valor: dato.valor, p_fuente: dato.fuente,
    });
    if (error) {
      bot = null; // si la sesión se cayó, la siguiente vuelta vuelve a entrar
      return json({ ok: false, error: `No se pudo guardar: ${error.message}` }, 500);
    }
    return json(data);
  } catch (e) {
    bot = null;
    return json({ ok: false, error: (e as Error).message }, 500);
  }
});
