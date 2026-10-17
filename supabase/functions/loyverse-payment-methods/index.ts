const SUPABASE_URL = Deno.env.get("SUPABASE_URL");

type SupabaseAuth = { key: string; isNewSecret: boolean };

function getSupabaseAuth(): SupabaseAuth | null {
  const raw = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (raw) {
    try {
      const keys = JSON.parse(raw);
      const key = typeof keys?.default === "string" ? keys.default.trim() : "";
      if (key) return { key, isNewSecret: key.startsWith("sb_secret_") };
    } catch {}
  }
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() ?? "";
  return legacy ? { key: legacy, isNewSecret: false } : null;
}

const SUPABASE_AUTH = getSupabaseAuth();
const LOYVERSE_BASE_URL = "https://api.loyverse.com/v1.0";
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function cleanError(value: unknown): string {
  const message =
    value instanceof Error ? value.message :
    typeof value === "string" ? value :
    JSON.stringify(value);
  return message.slice(0, 1200);
}

async function supabaseRequest(path: string, init: RequestInit = {}, userToken?: string) {
  if (!SUPABASE_URL || !SUPABASE_AUTH) {
    throw new Error("Faltan las credenciales internas de Supabase.");
  }
  const headers = new Headers(init.headers);
  headers.set("apikey", SUPABASE_AUTH.key);
  headers.set("Content-Type", "application/json");
  if (userToken) {
    headers.set("Authorization", "Bearer " + userToken);
  } else if (!SUPABASE_AUTH.isNewSecret) {
    headers.set("Authorization", "Bearer " + SUPABASE_AUTH.key);
  }

  const response = await fetch(SUPABASE_URL + path, { ...init, headers });
  const text = await response.text();
  let body: any = null;
  if (text) {
    try { body = JSON.parse(text); } catch { body = text; }
  }
  if (!response.ok) {
    throw new Error("Supabase respondió " + response.status + ": " + cleanError(body));
  }
  return body;
}

async function supabaseRpc(name: string, args: Record<string, unknown>) {
  return supabaseRequest("/rest/v1/rpc/" + encodeURIComponent(name), {
    method: "POST",
    body: JSON.stringify(args),
  });
}

async function assertAdmin(req: Request) {
  const authorization = req.headers.get("authorization") ?? "";
  const userToken = authorization.replace(/^Bearer\\s+/i, "").trim();
  if (!userToken) throw new Error("Inicia sesión como administrador.");

  const user = await supabaseRequest("/auth/v1/user", { method: "GET" }, userToken);
  const userId = typeof user?.id === "string" ? user.id : "";
  if (!userId) throw new Error("La sesión no es válida.");

  const rows = await supabaseRequest(
    "/rest/v1/admin_users?select=user_id&user_id=eq." + encodeURIComponent(userId) + "&limit=1",
    { method: "GET" },
  );
  if (!Array.isArray(rows) || !rows.length) {
    throw new Error("No tienes permisos de administración.");
  }
}

async function getLoyverseToken() {
  const token = await supabaseRpc("avohouse_get_loyverse_api_token", {});
  const value = typeof token === "string" ? token.trim() : "";
  if (!value) throw new Error("Falta configurar loyverse_api_token.");
  return value;
}

async function loyverseGet(token: string, path: string) {
  const response = await fetch(LOYVERSE_BASE_URL + path, {
    method: "GET",
    headers: {
      Authorization: "Bearer " + token,
      "Content-Type": "application/json",
    },
  });
  const text = await response.text();
  let body: any = null;
  if (text) {
    try { body = JSON.parse(text); } catch { body = text; }
  }
  if (!response.ok) {
    throw new Error("Loyverse respondió " + response.status + ": " + cleanError(body));
  }
  return body;
}

async function listPaymentTypes(token: string) {
  const byId = new Map<string, any>();
  let cursor = "";
  const pageSize = 250;
  const maxPages = 100;

  for (let page = 0; page < maxPages; page++) {
    const params = new URLSearchParams({ limit: String(pageSize) });
    if (cursor) params.set("cursor", cursor);
    const body = await loyverseGet(token, "/payment_types?" + params.toString());
    const paymentTypes = Array.isArray(body?.payment_types) ? body.payment_types : [];

    for (const method of paymentTypes) {
      const id = String(method?.id ?? "").trim();
      const name = String(method?.name ?? "").trim();
      if (!id || !name || method?.deleted_at) continue;
      byId.set(id, {
        id,
        name,
        type: String(method?.type ?? "OTHER").trim().toUpperCase() || "OTHER",
        stores: Array.isArray(method?.stores) ? method.stores : [],
      });
    }

    cursor = typeof body?.cursor === "string" ? body.cursor.trim() : "";
    if (!cursor) {
      return [...byId.values()].sort((a, b) => a.name.localeCompare(b.name, "es"));
    }
  }

  throw new Error("La consulta de métodos de pago alcanzó el límite de páginas.");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ ok: false, error: "Método no permitido." }, 405);

  try {
    await assertAdmin(req);
    const token = await getLoyverseToken();
    const paymentTypes = await listPaymentTypes(token);
    return json({ ok: true, payment_types: paymentTypes, count: paymentTypes.length });
  } catch (error) {
    const message = cleanError(error);
    console.error("[loyverse-payment-methods]", message);
    return json({ ok: false, error: message }, 502);
  }
});
