// ---------------------------------------------------------------------------
// Webhook de WhatsApp — fase 2 del plan: los mensajes que entran caen en la bandeja.
//
// Meta llama esta función cada vez que alguien le escribe al número de PowerMx.
// Aquí NO se contesta nada y NO se agenda nada: solo se guarda el mensaje con
// `registrar_mensaje_entrante` (SQL 22), que crea la conversación si es nueva, abre
// la ventana de 24 horas y la liga sola al contacto cuando el número ya se conoce.
// Responder sigue siendo a mano, desde la pantalla WhatsApp del CRM.
//
// **Nada de `service_role`**, como se acordó: la función entra con una cuenta propia
// de rol `bot` que solo puede llamar esas funciones concretas. Si esa cuenta se
// filtrara, no puede leer clientes ni tocar inventario.
//
// **"Verify JWT" va apagado** (`[functions.whatsapp]` en `supabase/config.toml`):
// Meta no manda tokens de Supabase. Lo que autentica de verdad es la firma
// `X-Hub-Signature-256`, que se comprueba aquí abajo contra el secreto de la app.
//
// Secretos que necesita (Supabase → Edge Functions → Secrets):
//   WHATSAPP_VERIFY_TOKEN   texto que tú inventas; Meta lo repite al dar de alta el webhook
//   WHATSAPP_APP_SECRET     "Clave secreta de la app" en Meta → Configuración → Básica
//   BOT_EMAIL / BOT_PASSWORD  la cuenta con rol `bot` en el CRM
// `SUPABASE_URL` y `SUPABASE_ANON_KEY` las pone Supabase sola.
// ---------------------------------------------------------------------------

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

// Meta reintenta si no contesta rápido; mejor un 200 seco que hacerlo esperar.
const OK = () => new Response("ok", { status: 200 });

// Un mensaje de WhatsApp puede ser de muchos tipos; la tabla solo acepta estos.
const TIPOS: Record<string, string> = {
  text: "texto",
  image: "imagen",
  document: "documento",
  audio: "audio",
  voice: "audio",
  location: "ubicacion",
};

// ---------------------------------------------------------------------------
// Sesión del bot. Iniciarla cuesta una llamada, así que se guarda mientras el
// contenedor siga vivo y solo se repite si el token venció.
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

// ---------------------------------------------------------------------------
// La firma de Meta: HMAC-SHA256 del cuerpo CRUDO con la clave secreta de la app.
// Sin esto, cualquiera que descubra la dirección podría inventar mensajes de
// clientes. Se compara byte por byte y en tiempo constante.
// ---------------------------------------------------------------------------
async function firmaValida(crudo: string, encabezado: string | null): Promise<boolean> {
  const secreto = Deno.env.get("WHATSAPP_APP_SECRET");
  if (!secreto || !encabezado?.startsWith("sha256=")) return false;

  const llave = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secreto),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const firma = await crypto.subtle.sign("HMAC", llave, new TextEncoder().encode(crudo));
  const esperado = [...new Uint8Array(firma)].map((b) => b.toString(16).padStart(2, "0")).join("");
  const recibido = encabezado.slice("sha256=".length);

  if (esperado.length !== recibido.length) return false;
  let diferencia = 0;
  for (let i = 0; i < esperado.length; i++) diferencia |= esperado.charCodeAt(i) ^ recibido.charCodeAt(i);
  return diferencia === 0;
}

// ---------------------------------------------------------------------------
// De lo que manda Meta a lo que guarda la base. El texto de un cliente es dato
// NO CONFIABLE: aquí solo se copia, nunca se interpreta como instrucción.
// ---------------------------------------------------------------------------
function leerMensaje(m: Record<string, any>) {
  const tipo = TIPOS[m.type] ?? "otro";
  let texto: string | null = null;
  let media: string | null = null;

  switch (m.type) {
    case "text":
      texto = m.text?.body ?? null;
      break;
    case "button":
      texto = m.button?.text ?? null;
      break;
    case "interactive":
      // Cuando el cliente toca un botón o elige de una lista.
      texto = m.interactive?.button_reply?.title ?? m.interactive?.list_reply?.title ?? null;
      break;
    case "location": {
      const u = m.location ?? {};
      texto = [u.name, u.address, u.latitude && `${u.latitude}, ${u.longitude}`]
        .filter(Boolean).join(" · ") || null;
      break;
    }
    default: {
      // Imagen, documento, audio, video, sticker: el archivo se queda en Meta y
      // se baja después (todavía no); por ahora se guarda su id y el pie de foto.
      const adjunto = m[m.type];
      if (adjunto && typeof adjunto === "object") {
        media = adjunto.id ?? null;
        texto = adjunto.caption ?? adjunto.filename ?? null;
      }
    }
  }

  return {
    p_telefono: m.from,
    p_wa_message_id: m.id,
    p_texto: texto,
    p_tipo: tipo,
    p_media_id: media,
    p_wa_timestamp: m.timestamp
      ? new Date(Number(m.timestamp) * 1000).toISOString()
      : new Date().toISOString(),
  };
}

// Manda a pensar al agente sin esperar la respuesta. `EdgeRuntime.waitUntil` mantiene viva
// la tarea después de que contestamos 200; si no existiera, se deja pasar en silencio y el
// admin contesta a mano, que es lo que pasa hoy de todos modos.
function despertarAgente(conversacion: string) {
  const sb = cliente;
  const rt = (globalThis as any).EdgeRuntime;
  if (!sb || !rt?.waitUntil) return;
  rt.waitUntil((async () => {
    try {
      // Va con la sesión del bot, que es lo que `agente-whatsapp` exige.
      const { error } = await sb.functions.invoke("agente-whatsapp", { body: { conversacion } });
      if (error) console.error("El agente no pudo contestar:", error.message);
    } catch (e) {
      console.error("No se pudo despertar al agente:", e instanceof Error ? e.message : e);
    }
  })());
}

Deno.serve(async (req) => {
  const url = new URL(req.url);

  // ---- alta del webhook: Meta pregunta una vez y espera su reto de vuelta ----
  if (req.method === "GET") {
    const esperado = Deno.env.get("WHATSAPP_VERIFY_TOKEN");
    const modo = url.searchParams.get("hub.mode");
    const token = url.searchParams.get("hub.verify_token");
    const reto = url.searchParams.get("hub.challenge");
    if (modo === "subscribe" && esperado && token === esperado && reto) {
      return new Response(reto, { status: 200, headers: { "Content-Type": "text/plain" } });
    }
    return new Response("no", { status: 403 });
  }

  if (req.method !== "POST") return new Response("no", { status: 405 });

  // El cuerpo se lee CRUDO: volver a serializar el JSON cambiaría la firma.
  const crudo = await req.text();
  if (!await firmaValida(crudo, req.headers.get("x-hub-signature-256"))) {
    console.error("Firma inválida: el aviso no viene de Meta.");
    return new Response("no", { status: 401 });
  }

  let cuerpo: Record<string, any>;
  try {
    cuerpo = JSON.parse(crudo);
  } catch {
    return OK(); // no es JSON; reintentar no lo va a arreglar
  }

  try {
    const sb = await comoBot();

    for (const entrada of cuerpo.entry ?? []) {
      for (const cambio of entrada.changes ?? []) {
        const valor = cambio.value ?? {};
        // El nombre que reporta WhatsApp lo escribe el propio cliente: se guarda
        // como referencia, pero quien manda es `contactos` (SQL 15).
        const nombre = valor.contacts?.[0]?.profile?.name ?? null;

        for (const m of valor.messages ?? []) {
          const datos = { ...leerMensaje(m), p_nombre_wa: nombre };
          const { data, error } = await sb.rpc("registrar_mensaje_entrante", datos);
          // Un mensaje que falla no debe tumbar a los demás del mismo aviso.
          if (error) { console.error("No se pudo guardar", m.id, error.message); continue; }

          // El agente contesta APARTE: pensar tarda segundos y Meta reintenta el aviso si
          // no le respondemos rápido. Si el agente está apagado, la llamada no hace nada.
          if (data?.conversacion_id && !data?.repetido) despertarAgente(data.conversacion_id);
        }

        // Los acuses de entrega (`statuses`) todavía no se guardan: hacen falta
        // cuando el CRM mande por la API, no mientras se responda a mano.
      }
    }
  } catch (e) {
    // Si el bot no pudo entrar, el token pudo haber vencido: se tira la sesión
    // para que el siguiente aviso vuelva a iniciarla.
    cliente = null;
    console.error("Fallo el webhook:", e instanceof Error ? e.message : e);
  }

  // Siempre 200: si Meta ve un error, reintenta el mismo aviso durante horas.
  // Lo que se perdió queda en el registro de la función, no en un bucle.
  return OK();
});
