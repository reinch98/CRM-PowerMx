// ---------------------------------------------------------------------------
// Agente del CRM PowerMx — fase 2: diez herramientas de solo lectura.
//
// Recibe la pregunta desde la pantalla del CRM, conversa con la API de Claude
// y consulta la base CON LA SESIÓN DE QUIEN PREGUNTA. El agente no tiene
// permisos propios: hereda los del usuario. Si un técnico pregunta algo que su
// rol no alcanza, la base simplemente no lo devuelve.
// ---------------------------------------------------------------------------

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const JSON_H = { ...CORS, "Content-Type": "application/json" };

const MODELO = "claude-sonnet-5";
const MAX_VUELTAS = 8; // tope de seguridad: sin esto, un bucle raro se come el saldo

const INSTRUCCIONES = `Eres el asistente interno de PowerMx, una empresa de Mérida, Yucatán
que instala y da mantenimiento a generadores eléctricos y sistemas solares fotovoltaicos.

Ayudas a quien te pregunta a consultar la información del CRM. Reglas:

- Contesta en español, directo y breve. Nada de rodeos.
- SOLO puedes leer. No puedes crear, modificar ni borrar nada todavía.
- NUNCA inventes precios, existencias, números de serie ni fechas. Si no lo
  obtuviste de una herramienta, no lo sabes.
- Si una herramienta devuelve vacío, dilo claro. No rellenes con suposiciones.
- Si algo no te lo devuelve la base, puede ser que el rol de quien pregunta no
  tenga permiso de verlo. Dilo así, sin adivinar el dato.
- Para preguntas generales ("¿qué clientes tengo?", "¿cuántos hay en Progreso?")
  usa listar_clientes.
- Si una herramienta te devuelve varios clientes posibles, pregunta cuál antes
  de seguir. No escojas tú.
- En inventario, lo único que se puede prometer a un cliente es el DISPONIBLE.
  El físico incluye material apartado por cotizaciones y material en resguardo
  que ya es de otros clientes.
- Nunca muestres costos ni márgenes a quien no sea administrador.
- Cuando des una dirección, incluye el enlace de mapa si existe.
- Escribe las fechas como día/mes/año.`;

// ---------------------------------------------------------------------------
// Utilidades
// ---------------------------------------------------------------------------
function responder(cuerpo: unknown, status = 200) {
  return new Response(JSON.stringify(cuerpo), { status, headers: JSON_H });
}

// El servidor corre en UTC; "hoy" tiene que ser el de Mérida o un
// mantenimiento de mañana aparece como de hoy después de las 6 de la tarde.
function hoyMerida(): string {
  return new Date().toLocaleDateString("en-CA", { timeZone: "America/Mexico_City" });
}

function sumarDias(fecha: string, dias: number): string {
  const d = new Date(fecha + "T12:00:00Z");
  d.setUTCDate(d.getUTCDate() + dias);
  return d.toISOString().slice(0, 10);
}

// Quita los caracteres que la base usa como sintaxis dentro de los filtros.
// Sin esto, una coma en la búsqueda rompe la consulta, o la altera.
function limpiar(t: unknown): string {
  return String(t ?? "").replace(/[,()*%\\]/g, " ").replace(/\s+/g, " ").trim().slice(0, 80);
}

// Encuentra clientes por nombre. Si uno coincide exacto, ese gana; si no,
// devuelve todos los parecidos para que el agente pregunte cuál.
async function resolverClientes(sb: any, texto: unknown) {
  const t = limpiar(texto);
  if (!t) return [];
  const { data } = await sb
    .from("clientes")
    .select("id, nombre, nombre_comercial")
    .or(`nombre.ilike.%${t}%,nombre_comercial.ilike.%${t}%`)
    .limit(10);
  const lista = data ?? [];
  const exacto = lista.find(
    (c: any) =>
      c.nombre?.toLowerCase() === t.toLowerCase() ||
      c.nombre_comercial?.toLowerCase() === t.toLowerCase()
  );
  return exacto ? [exacto] : lista;
}

function variosONinguno(cs: any[]) {
  if (cs.length === 0) return { resultado: "no encontré ningún cliente con ese nombre" };
  if (cs.length > 1) {
    return {
      varios_clientes: cs.map((c: any) => c.nombre_comercial ? `${c.nombre} (${c.nombre_comercial})` : c.nombre),
      nota: "Hay varios clientes parecidos. Pregunta cuál.",
    };
  }
  return null;
}

// ---------------------------------------------------------------------------
// Herramientas. Cada una trae su definición (lo que ve Claude) y su ejecución
// (lo que corre contra la base). Para agregar una, se agrega un bloque aquí.
// ---------------------------------------------------------------------------
type Ctx = { rol: string; hoy: string };

const LISTA: {
  name: string;
  description: string;
  input_schema: Record<string, unknown>;
  ejecutar: (sb: any, e: any, ctx: Ctx) => Promise<unknown>;
}[] = [
  {
    name: "listar_clientes",
    description:
      "Lista los clientes registrados, del más reciente al más antiguo, con el total. " +
      "Úsala para preguntas generales como '¿qué clientes tengo?' o '¿cuántos clientes hay en Progreso?'. " +
      "Se puede filtrar por zona o municipio.",
    input_schema: {
      type: "object",
      properties: {
        zona: { type: "string", description: "Opcional. Zona o municipio para filtrar." },
        limite: { type: "integer", description: "Opcional. Cuántos mostrar. Por defecto 25, máximo 50." },
      },
    },
    ejecutar: async (sb, e) => {
      const limite = Math.min(Math.max(Number(e.limite) || 25, 1), 50);
      let q = sb
        .from("clientes")
        .select("nombre, nombre_comercial, tipo_cliente, telefono, zona, municipio", { count: "exact" })
        .order("created_at", { ascending: false })
        .limit(limite);
      const z = limpiar(e.zona);
      if (z) q = q.or(`zona.ilike.%${z}%,municipio.ilike.%${z}%`);
      const { data, error, count } = await q;
      if (error) return { error: error.message };
      return { total: count ?? data.length, mostrados: data.length, clientes: data };
    },
  },

  {
    name: "buscar_cliente",
    description:
      "Busca un cliente por nombre o nombre comercial, aunque sea parcial: 'garcia' encuentra 'Juan García'. " +
      "Devuelve teléfono, correo, dirección, colonia, municipio, zona, referencias y enlace de Google Maps.",
    input_schema: {
      type: "object",
      properties: { texto: { type: "string", description: "Parte del nombre del cliente." } },
      required: ["texto"],
    },
    ejecutar: async (sb, e) => {
      const t = limpiar(e.texto);
      if (!t) return { error: "Falta el nombre a buscar." };
      const { data, error } = await sb
        .from("clientes")
        .select(
          "nombre, nombre_comercial, tipo_cliente, telefono, telefono_alterno, email, " +
          "contacto_nombre, direccion, colonia, municipio, zona, maps_url, referencias"
        )
        .or(`nombre.ilike.%${t}%,nombre_comercial.ilike.%${t}%`)
        .limit(10);
      if (error) return { error: error.message };
      if (!data?.length) return { resultado: "no encontré ningún cliente con ese nombre" };
      return { clientes: data };
    },
  },

  {
    name: "equipos_de_cliente",
    description:
      "Lista los equipos de un cliente (generadores, sistemas solares, baterías) con número de serie, " +
      "marca, modelo, capacidad, fecha de instalación, próximo mantenimiento y si está en póliza.",
    input_schema: {
      type: "object",
      properties: { cliente: { type: "string", description: "Nombre o parte del nombre del cliente." } },
      required: ["cliente"],
    },
    ejecutar: async (sb, e) => {
      const cs = await resolverClientes(sb, e.cliente);
      const aviso = variosONinguno(cs);
      if (aviso) return aviso;
      const { data, error } = await sb
        .from("equipos")
        .select(
          "numero_serie, tipo, marca, modelo, capacidad_kw, fecha_instalacion, ubicacion_equipo, " +
          "horas_uso, proximo_mantenimiento, en_poliza, estado, numero_servicio_cfe, atributos"
        )
        .eq("cliente_id", cs[0].id)
        .order("tipo");
      if (error) return { error: error.message };
      if (!data?.length) return { cliente: cs[0].nombre, resultado: "este cliente no tiene equipos registrados" };
      return { cliente: cs[0].nombre, equipos: data };
    },
  },

  {
    name: "historial_de_equipo",
    description:
      "Las órdenes de servicio de un equipo, de la más reciente a la más vieja: fecha, tipo de servicio, " +
      "técnico, horómetro, trabajos realizados, refacciones usadas y recomendaciones.",
    input_schema: {
      type: "object",
      properties: {
        numero_serie: { type: "string", description: "Número de serie del equipo, completo o parcial." },
        limite: { type: "integer", description: "Opcional. Cuántas órdenes. Por defecto 10." },
      },
      required: ["numero_serie"],
    },
    ejecutar: async (sb, e) => {
      const s = limpiar(e.numero_serie);
      if (!s) return { error: "Falta el número de serie." };
      const { data: eqs, error: e1 } = await sb
        .from("equipos")
        .select("id, numero_serie, tipo, marca, modelo, clientes(nombre)")
        .ilike("numero_serie", `%${s}%`)
        .limit(5);
      if (e1) return { error: e1.message };
      if (!eqs?.length) return { resultado: "no encontré ningún equipo con ese número de serie" };
      const eq = eqs.find((x: any) => x.numero_serie.toLowerCase() === s.toLowerCase()) ??
        (eqs.length === 1 ? eqs[0] : null);
      if (!eq) {
        return { varios_equipos: eqs.map((x: any) => `${x.numero_serie} (${x.clientes?.nombre ?? "sin cliente"})`), nota: "Pregunta cuál." };
      }
      const limite = Math.min(Math.max(Number(e.limite) || 10, 1), 30);
      const { data, error } = await sb
        .from("ordenes_servicio")
        .select(
          "folio, fecha, tipo_servicio, tecnico, horas_equipo, trabajos_realizados, refacciones, " +
          "observaciones, recomendaciones, requiere_seguimiento, fecha_seguimiento, estado"
        )
        .eq("equipo_id", eq.id)
        .order("fecha", { ascending: false })
        .limit(limite);
      if (error) return { error: error.message };
      return {
        equipo: { numero_serie: eq.numero_serie, tipo: eq.tipo, marca: eq.marca, modelo: eq.modelo, cliente: eq.clientes?.nombre },
        ordenes: data?.length ? data : "este equipo no tiene órdenes de servicio registradas",
      };
    },
  },

  {
    name: "buscar_producto",
    description:
      "Busca en el catálogo por SKU, nombre o marca: generadores, paquetes solares, baterías, paneles, " +
      "refacciones y rentas. Devuelve precio de lista. Si quien pregunta es administrador, también el costo y el margen.",
    input_schema: {
      type: "object",
      properties: {
        texto: { type: "string", description: "SKU, nombre o marca, completo o parcial." },
        categoria: {
          type: "string",
          enum: ["generador", "paquete_solar", "bateria", "panel", "refaccion", "renta"],
          description: "Opcional. Para acotar la búsqueda.",
        },
      },
      required: ["texto"],
    },
    ejecutar: async (sb, e, ctx) => {
      const t = limpiar(e.texto);
      if (!t) return { error: "Falta qué buscar." };
      let q = sb
        .from("catalogo")
        .select("id, sku, categoria, nombre, marca, modelo, precio, precios, unidad")
        .or(`sku.ilike.%${t}%,nombre.ilike.%${t}%,marca.ilike.%${t}%`)
        .limit(15);
      if (e.categoria) q = q.eq("categoria", e.categoria);
      const { data, error } = await q;
      if (error) return { error: error.message };
      if (!data?.length) return { resultado: "no encontré productos con eso" };

      // El costo solo viaja si quien pregunta es admin, y aun así la base
      // lo vuelve a filtrar: la tabla productos solo la puede leer el admin.
      let costos: Record<string, number | null> = {};
      if (ctx.rol === "admin") {
        const { data: cs } = await sb.from("productos").select("id, costo").in("id", data.map((p: any) => p.id));
        costos = Object.fromEntries((cs ?? []).map((c: any) => [c.id, c.costo]));
      }

      return {
        productos: data.map((p: any) => {
          const { id, ...resto } = p;
          const salida: any = { ...resto, precio: p.precio ?? "sin precio capturado" };
          if (ctx.rol === "admin") {
            const costo = costos[id];
            salida.costo = costo ?? "sin costo capturado";
            if (p.precio && costo) salida.margen = `${Math.round(((p.precio - costo) / p.precio) * 100)}%`;
          }
          return salida;
        }),
      };
    },
  },

  {
    name: "consultar_existencia",
    description:
      "Existencias de un producto: físico en almacén, apartado por cotizaciones aceptadas, en resguardo " +
      "de clientes y disponible. Solo el disponible se puede prometer.",
    input_schema: {
      type: "object",
      properties: { texto: { type: "string", description: "SKU o nombre del producto, completo o parcial." } },
      required: ["texto"],
    },
    ejecutar: async (sb, e) => {
      const t = limpiar(e.texto);
      if (!t) return { error: "Falta qué producto." };
      const { data, error } = await sb
        .from("disponibles")
        .select("sku, categoria, nombre, unidad, fisico, apartado, resguardo, disponible, minimo")
        .or(`sku.ilike.%${t}%,nombre.ilike.%${t}%`)
        .limit(15);
      if (error) return { error: error.message };
      if (!data?.length) return { resultado: "no encontré ese producto en inventario" };
      return { existencias: data };
    },
  },

  {
    name: "por_reordenar",
    description:
      "Productos cuyo disponible está por debajo del mínimo: lo que hay que pedir. " +
      "Solo aparecen los productos que tienen un mínimo capturado.",
    input_schema: { type: "object", properties: {} },
    ejecutar: async (sb) => {
      const { data, error } = await sb
        .from("por_reordenar")
        .select("sku, categoria, nombre, unidad, disponible, minimo")
        .order("categoria");
      if (error) return { error: error.message };
      if (!data?.length) {
        return { resultado: "nada está bajo el mínimo. Ojo: solo se revisan productos que tienen un mínimo capturado." };
      }
      return { por_pedir: data.map((p: any) => ({ ...p, faltan: p.minimo - p.disponible })) };
    },
  },

  {
    name: "mantenimientos_proximos",
    description:
      "Equipos activos cuyo próximo mantenimiento cae dentro de los siguientes días, incluidos los que ya " +
      "están vencidos. Trae cliente, teléfono y zona para poder agendar.",
    input_schema: {
      type: "object",
      properties: {
        dias: { type: "integer", description: "Cuántos días hacia adelante. Por defecto 30." },
        incluir_vencidos: { type: "boolean", description: "Opcional. Por defecto sí." },
      },
    },
    ejecutar: async (sb, e, ctx) => {
      const dias = Math.min(Math.max(Number(e.dias) || 30, 1), 365);
      const hasta = sumarDias(ctx.hoy, dias);
      let q = sb
        .from("equipos")
        .select("numero_serie, tipo, marca, modelo, proximo_mantenimiento, en_poliza, clientes(nombre, telefono, zona)")
        .eq("estado", "activo")
        .lte("proximo_mantenimiento", hasta)
        .order("proximo_mantenimiento");
      if (e.incluir_vencidos === false) q = q.gte("proximo_mantenimiento", ctx.hoy);
      const { data, error } = await q;
      if (error) return { error: error.message };
      if (!data?.length) return { hoy: ctx.hoy, hasta, resultado: "ningún mantenimiento en ese periodo" };
      return {
        hoy: ctx.hoy,
        hasta,
        equipos: data.map((x: any) => ({ ...x, vencido: x.proximo_mantenimiento < ctx.hoy })),
      };
    },
  },

  {
    name: "resguardo_de_cliente",
    description:
      "Material ya pagado por un cliente de póliza que sigue guardado en el almacén de PowerMx, " +
      "esperando su siguiente visita.",
    input_schema: {
      type: "object",
      properties: { cliente: { type: "string", description: "Nombre o parte del nombre del cliente." } },
      required: ["cliente"],
    },
    ejecutar: async (sb, e) => {
      const t = limpiar(e.cliente);
      if (!t) return { error: "Falta el cliente." };
      const { data, error } = await sb
        .from("resguardo_por_cliente")
        .select("cliente, sku, producto, en_resguardo")
        .ilike("cliente", `%${t}%`);
      if (error) return { error: error.message };
      if (!data?.length) return { resultado: "ese cliente no tiene material en resguardo" };
      return { resguardo: data };
    },
  },

  {
    name: "cotizaciones_de_cliente",
    description:
      "Cotizaciones de un cliente: folio, fecha, tipo, total y estado (borrador, enviada, aceptada, " +
      "rechazada, vencida). Sirve para dar seguimiento.",
    input_schema: {
      type: "object",
      properties: {
        cliente: { type: "string", description: "Nombre o parte del nombre del cliente." },
        estado: {
          type: "string",
          enum: ["borrador", "enviada", "aceptada", "rechazada", "vencida"],
          description: "Opcional. Para filtrar por estado.",
        },
      },
      required: ["cliente"],
    },
    ejecutar: async (sb, e, ctx) => {
      const cs = await resolverClientes(sb, e.cliente);
      const aviso = variosONinguno(cs);
      if (aviso) return aviso;
      let q = sb
        .from("cotizaciones")
        .select("folio, fecha, vigencia_dias, tipo, total, estado, requiere_visita")
        .eq("cliente_id", cs[0].id)
        .order("fecha", { ascending: false })
        .limit(20);
      if (e.estado) q = q.eq("estado", e.estado);
      const { data, error } = await q;
      if (error) return { error: error.message };
      if (!data?.length) {
        return {
          cliente: cs[0].nombre,
          resultado: ctx.rol === "admin"
            ? "este cliente no tiene cotizaciones"
            : "sin resultados; tu rol no tiene acceso a cotizaciones",
        };
      }
      return { cliente: cs[0].nombre, cotizaciones: data };
    },
  },
];

const HERRAMIENTAS = LISTA.map(({ ejecutar: _e, ...definicion }) => definicion);
const EJECUTORES = Object.fromEntries(LISTA.map((h) => [h.name, h.ejecutar]));

// ---------------------------------------------------------------------------
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    const llave = Deno.env.get("ANTHROPIC_API_KEY");
    if (!llave) return responder({ error: "Falta el secreto ANTHROPIC_API_KEY en la función." }, 500);

    const autorizacion = req.headers.get("Authorization");
    if (!autorizacion) return responder({ error: "Falta la sesión." }, 401);

    // La llave anon MÁS el token del usuario: así las políticas por rol aplican
    // igual que cuando el CRM consulta directo. Nunca se usa la llave de
    // servicio aquí; eso le daría al agente permiso sobre todo.
    const sb = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: autorizacion } } }
    );

    // La sesión se valida aquí, ANTES de gastar un solo centavo de la API.
    // El portero de Supabase está apagado para esta función, así que esta es
    // la única puerta.
    const token = autorizacion.replace(/^Bearer\s+/i, "");
    const { data: sesion, error: errorSesion } = await sb.auth.getUser(token);
    if (errorSesion || !sesion?.user) {
      return responder({ error: "Sesión inválida o vencida. Sal y vuelve a entrar al CRM." }, 401);
    }

    // Una cuenta sin rol no gasta crédito.
    const { data: rol } = await sb.rpc("mi_rol");
    if (!rol || rol === "sin_rol") {
      return responder({ error: "Tu cuenta todavía no tiene rol asignado." }, 403);
    }

    const { pregunta, historial = [] } = await req.json();
    if (!pregunta || !String(pregunta).trim()) return responder({ error: "Pregunta vacía." }, 400);

    const ctx: Ctx = { rol, hoy: hoyMerida() };
    const sistema = `${INSTRUCCIONES}\n\nHoy es ${ctx.hoy} (hora de Mérida). Quien pregunta tiene el rol: ${rol}.`;

    const mensajes: any[] = [...historial, { role: "user", content: pregunta }];
    const usadas: string[] = [];
    let respuesta = "";

    for (let vuelta = 0; vuelta < MAX_VUELTAS; vuelta++) {
      const r = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-api-key": llave,
          "anthropic-version": "2023-06-01",
        },
        body: JSON.stringify({
          model: MODELO,
          max_tokens: 1500,
          system: sistema,
          tools: HERRAMIENTAS,
          messages: mensajes,
        }),
      });

      if (!r.ok) {
        return responder({ error: `La API respondió ${r.status}`, detalle: await r.text() }, 502);
      }

      const datos = await r.json();
      mensajes.push({ role: "assistant", content: datos.content });

      if (datos.stop_reason !== "tool_use") {
        respuesta = datos.content
          .filter((b: any) => b.type === "text")
          .map((b: any) => b.text)
          .join("\n");
        break;
      }

      // Claude pidió una o más herramientas: se ejecutan y se le devuelven.
      const resultados = [];
      for (const p of datos.content.filter((b: any) => b.type === "tool_use")) {
        usadas.push(p.name);
        const ejecutar = EJECUTORES[p.name];
        let salida: unknown;
        try {
          salida = ejecutar ? await ejecutar(sb, p.input ?? {}, ctx) : { error: `Herramienta desconocida: ${p.name}` };
        } catch (e) {
          salida = { error: String(e) };
        }
        resultados.push({ type: "tool_result", tool_use_id: p.id, content: JSON.stringify(salida) });
      }
      mensajes.push({ role: "user", content: resultados });
    }

    if (!respuesta) respuesta = "Me enredé buscando la respuesta. Vuelve a preguntarme, más específico.";

    return responder({ respuesta, historial: mensajes, herramientas: usadas });
  } catch (e) {
    return responder({ error: String(e) }, 500);
  }
});
