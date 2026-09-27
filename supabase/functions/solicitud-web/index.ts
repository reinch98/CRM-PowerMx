// ---------------------------------------------------------------------------
// Solicitudes de cotización del sitio público → CRM.
//
// El formulario de `cotizar.html` (sitio PowerMx) manda aquí lo que el cliente llenó, y
// queda en la tabla `solicitudes_web` (SQL 36). Aquí NO se crea ningún cliente, cotización
// ni cita: el admin las ve en la pantalla "Solicitudes" y decide.
//
// Es un endpoint PÚBLICO: cualquiera que conozca la dirección puede llamarlo. Por eso:
//  - **Nada de `service_role`.** Entra con la cuenta de rol `bot` (la misma del webhook de
//    WhatsApp), que solo puede llamar a `registrar_solicitud_web`. Si esa cuenta se filtrara,
//    no puede leer clientes ni tocar inventario.
//  - **Lo que protege es la base**, no esta función: `registrar_solicitud_web` valida, recorta
//    y pone topes (60 por hora en todo el sitio, 5 por día por número) y no duplica reintentos.
//  - Un campo trampa (`sitio_web`, oculto en el formulario) y un tiempo mínimo de llenado
//    descartan a los bots más simples SIN avisarles: responden 200 como si hubiera funcionado.
//  - El cuerpo se limita a 10 KB. Todo lo que llega es texto de un desconocido: se copia, jamás
//    se interpreta como instrucción.
//  - CORS solo para los orígenes del sitio. Ojo: eso protege al navegador, no a la función;
//    un script puede ignorarlo. Es comodidad, no seguridad.
//
// "Verify JWT" va apagado (`[functions.solicitud-web]` en `supabase/config.toml`): el sitio
// no tiene sesión de Supabase.
//
// Secretos (Supabase → Edge Functions → Secrets):
//   BOT_EMAIL / BOT_PASSWORD   la cuenta con rol `bot` (los mismos que usa `whatsapp`)
//   SOLICITUD_ORIGENES         opcional: orígenes permitidos separados por coma.
//                              Por omisión: https://powermx.com.mx y https://www.powermx.com.mx
// ---------------------------------------------------------------------------

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const MAX_CUERPO = 10_000; // bytes
const MIN_LLENADO_MS = 2_500; // nadie llena un formulario de cotización en menos

const ORIGENES = (Deno.env.get("SOLICITUD_ORIGENES") ??
  "https://powermx.com.mx,https://www.powermx.com.mx")
  .split(",").map((s) => s.trim()).filter(Boolean);

function cabeceras(req: Request): Record<string, string> {
  const origen = req.headers.get("origin") ?? "";
  const h: Record<string, string> = {
    "Content-Type": "application/json",
    "Vary": "Origin",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
  };
  if (ORIGENES.includes(origen)) h["Access-Control-Allow-Origin"] = origen;
  return h;
}

function responder(req: Request, estado: number, cuerpo: Record<string, unknown>) {
  return new Response(JSON.stringify(cuerpo), { status: estado, headers: cabeceras(req) });
}

// ---------------------------------------------------------------------------
// Sesión del bot: iniciarla cuesta una llamada, así que se guarda mientras el contenedor
// viva y se tira si algo falla, para que la siguiente petición vuelva a entrar.
// ---------------------------------------------------------------------------
let cliente: SupabaseClient | null = null;

async function comoBot(): Promise<SupabaseClient> {
  if (cliente) return cliente;
  const correo = Deno.env.get("BOT_EMAIL");
  const clave = Deno.env.get("BOT_PASSWORD");
  if (!correo || !clave) throw new Error("Faltan BOT_EMAIL y BOT_PASSWORD en los secretos.");

  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
  const { error } = await sb.auth.signInWithPassword({ email: correo, password: clave });
  if (error) throw new Error(`La cuenta del bot no pudo entrar: ${error.message}`);
  cliente = sb;
  return sb;
}

const texto = (v: unknown, max: number): string | null =>
  typeof v === "string" && v.trim() ? v.trim().slice(0, max) : null;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cabeceras(req) });
  if (req.method !== "POST") return responder(req, 405, { ok: false, error: "Método no permitido." });

  const crudo = await req.text();
  if (new TextEncoder().encode(crudo).length > MAX_CUERPO) {
    return responder(req, 413, { ok: false, error: "La solicitud es demasiado grande." });
  }

  let d: Record<string, unknown>;
  try {
    d = JSON.parse(crudo);
  } catch {
    return responder(req, 400, { ok: false, error: "No se entendió la solicitud." });
  }

  // Bots simples: rellenan el campo trampa o mandan el formulario al instante. Se contesta
  // que todo salió bien para que no cambien de táctica, y no se guarda nada.
  const abiertoMs = Number(d.abierto_ms);
  if (texto(d.sitio_web, 50) || (Number.isFinite(abiertoMs) && abiertoMs < MIN_LLENADO_MS)) {
    console.warn("Solicitud descartada por el campo trampa o por llenarse demasiado rápido.");
    return responder(req, 200, { ok: true });
  }

  try {
    const sb = await comoBot();
    const { data, error } = await sb.rpc("registrar_solicitud_web", {
      p_nombre: texto(d.nombre, 120),
      p_telefono: texto(d.whatsapp, 30),
      p_email: texto(d.email, 160),
      p_ubicacion: texto(d.ubicacion, 200),
      p_tipos: texto(d.tipos, 200),
      p_uso: texto(d.uso, 60),
      p_equipo_actual: texto(d.equipo_actual, 100),
      p_consumo: texto(d.consumo, 100),
      p_presupuesto: texto(d.presupuesto, 100),
      p_plazo: texto(d.plazo, 100),
      p_fuente: texto(d.fuente, 100),
      p_notas: texto(d.notas, 2000),
      p_origen_url: texto(d.fuente_url, 300),
    });

    if (error) {
      // 22023 = dato inválido: el mensaje está escrito para el cliente.
      if (error.code === "22023") return responder(req, 400, { ok: false, error: error.message });
      // 54000 = tope: que escriba por WhatsApp, que es lo que el sitio ya le ofrece.
      if (error.code === "54000") return responder(req, 429, { ok: false, error: error.message });
      // Cualquier otra cosa (sesión vencida del bot, permisos): se tira la sesión y se avisa.
      cliente = null;
      console.error("No se pudo guardar la solicitud:", error.code, error.message);
      return responder(req, 500, { ok: false, error: "No pudimos registrar tu solicitud." });
    }

    return responder(req, 200, { ok: true, repetido: !!data?.repetido });
  } catch (e) {
    cliente = null;
    console.error("Fallo solicitud-web:", e instanceof Error ? e.message : e);
    return responder(req, 500, { ok: false, error: "No pudimos registrar tu solicitud." });
  }
});
