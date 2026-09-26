const SUPABASE_URL = Deno.env.get("SUPABASE_URL");

type SupabaseAuth = {
  key: string;
  isNewSecret: boolean;
};

function getSupabaseAuth(): SupabaseAuth | null {
  const raw = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (raw) {
    try {
      const keys = JSON.parse(raw);
      const key = typeof keys?.default === "string" ? keys.default.trim() : "";
      if (key) return { key, isNewSecret: key.startsWith("sb_secret_") };
    } catch {
      // Fall through to the legacy key.
    }
  }

  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() ?? "";
  return legacy ? { key: legacy, isNewSecret: false } : null;
}

const SUPABASE_AUTH = getSupabaseAuth();
const LOYVERSE_BASE_URL = "https://api.loyverse.com/v1.0";
const MAX_RECEIPTS = 25;
const MAX_ACCOUNTS = 25;

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", "Connection": "keep-alive" },
  });
}

function cleanError(value: unknown): string {
  const message =
    value instanceof Error
      ? value.message
      : typeof value === "string"
        ? value
        : JSON.stringify(value);
  return message.slice(0, 1500);
}

async function supabaseRequest(path: string, init: RequestInit = {}) {
  if (!SUPABASE_URL || !SUPABASE_AUTH) {
    throw new Error("Faltan las credenciales internas de Supabase.");
  }

  const headers = new Headers(init.headers);
  headers.set("apikey", SUPABASE_AUTH.key);
  headers.set("Content-Type", "application/json");
  if (!SUPABASE_AUTH.isNewSecret) {
    headers.set("Authorization", "Bearer " + SUPABASE_AUTH.key);
  }

  const response = await fetch(SUPABASE_URL + path, { ...init, headers });
  const text = await response.text();

  let body: any = null;
  if (text) {
    try {
      body = JSON.parse(text);
    } catch {
      body = text;
    }
  }

  if (!response.ok) {
    throw new Error(
      `Supabase respondió ${response.status}: ${cleanError(body)}`,
    );
  }

  return body;
}

async function supabaseRpc(name: string, args: Record<string, unknown>) {
  return supabaseRequest("/rest/v1/rpc/" + encodeURIComponent(name), {
    method: "POST",
    body: JSON.stringify(args),
  });
}

async function validateSecret(req: Request) {
  const supplied = req.headers.get("x-avohouse-loyverse-webhook-secret");
  if (!supplied) return false;

  try {
    return (
      (await supabaseRpc("avohouse_validate_loyverse_webhook", {
        p_secret: supplied,
      })) === true
    );
  } catch {
    return false;
  }
}

async function getLoyverseToken() {
  const token = await supabaseRpc("avohouse_get_loyverse_api_token", {});
  const value = typeof token === "string" ? token.trim() : "";
  if (!value) {
    throw new Error("Falta configurar loyverse_api_token en Supabase Vault.");
  }
  return value;
}

async function loyverseRequest(token: string, path: string, init: RequestInit = {}) {
  const headers = new Headers(init.headers);
  headers.set("Authorization", "Bearer " + token);
  headers.set("Content-Type", "application/json");

  const response = await fetch(LOYVERSE_BASE_URL + path, { ...init, headers });
  const text = await response.text();

  let body: any = null;
  if (text) {
    try {
      body = JSON.parse(text);
    } catch {
      body = text;
    }
  }

  if (!response.ok) {
    throw new Error(
      `Loyverse respondió ${response.status}: ${cleanError(body)}`,
    );
  }

  return body;
}

async function processPendingReceipts() {
  const rows = await supabaseRequest(
    "/rest/v1/loyverse_receipts?select=receipt_number,profile_id,avopuntos_status,updated_at&profile_id=not.is.null&avopuntos_status=eq.pending&order=updated_at.asc&limit=" +
      MAX_RECEIPTS,
    { method: "GET" },
  );

  const results: any[] = [];

  for (const row of rows ?? []) {
    try {
      const result = await supabaseRpc("avopuntos_process_receipt", {
        p_receipt_number: row.receipt_number,
      });
      results.push(result);
    } catch (error) {
      const message = cleanError(error);

      await supabaseRequest(
        "/rest/v1/loyverse_receipts?receipt_number=eq." +
          encodeURIComponent(row.receipt_number),
        {
          method: "PATCH",
          headers: { Prefer: "return=minimal" },
          body: JSON.stringify({
            avopuntos_status: "error",
            avopuntos_processed_at: new Date().toISOString(),
            avopuntos_last_error: message,
          }),
        },
      );

      results.push({
        ok: false,
        status: "error",
        receipt_number: row.receipt_number,
        profile_id: row.profile_id,
        error: message,
      });
    }
  }

  return results;
}

async function syncAccountToLoyverse(token: string, profileId: string) {
  const profiles = await supabaseRequest(
    "/rest/v1/profiles?select=id,full_name,username,email,phone&id=eq." +
      encodeURIComponent(profileId) +
      "&limit=1",
    { method: "GET" },
  );
  const profile = Array.isArray(profiles) ? profiles[0] : null;
  if (!profile) throw new Error("No se encontró el perfil AvoHouse.");

  const accounts = await supabaseRequest(
    "/rest/v1/avopuntos_accounts?select=profile_id,balance,last_loyverse_points&profile_id=eq." +
      encodeURIComponent(profileId) +
      "&limit=1",
    { method: "GET" },
  );
  const account = Array.isArray(accounts) ? accounts[0] : null;
  if (!account) throw new Error("No se encontró la cuenta de AvoPuntos.");

  const links = await supabaseRequest(
    "/rest/v1/loyverse_customers?select=profile_id,loyverse_customer_id&profile_id=eq." +
      encodeURIComponent(profileId) +
      "&limit=1",
    { method: "GET" },
  );
  const link = Array.isArray(links) ? links[0] : null;

  if (!link?.loyverse_customer_id) {
    return {
      ok: true,
      status: "waiting_customer_link",
      profile_id: profileId,
    };
  }

  const customerId = String(link.loyverse_customer_id);
  const current = await loyverseRequest(
    token,
    "/customers/" + encodeURIComponent(customerId),
    { method: "GET" },
  );

  const balance = Number(account.balance ?? 0);
  if (!Number.isInteger(balance) || balance < 0) {
    throw new Error("El saldo AvoPuntos no es un entero válido.");
  }

  const payload = {
    id: customerId,
    name: String(profile.full_name ?? "").trim(),
    email: String(profile.email ?? "").trim(),
    phone_number: String(profile.phone ?? "").trim(),
    address: current?.address ?? null,
    city: current?.city ?? null,
    region: current?.region ?? null,
    postal_code: current?.postal_code ?? null,
    country_code: current?.country_code ?? null,
    customer_code: String(profile.username ?? "").trim(),
    note: current?.note ?? null,
    total_points: balance,
  };

  if (!payload.name || !payload.email || !payload.phone_number || !payload.customer_code) {
    throw new Error("Faltan datos obligatorios para sincronizar el cliente.");
  }

  await loyverseRequest(token, "/customers", {
    method: "POST",
    body: JSON.stringify(payload),
  });

  const verified = await loyverseRequest(
    token,
    "/customers/" + encodeURIComponent(customerId),
    { method: "GET" },
  );

  const checks = [
    ["name", payload.name, verified?.name],
    ["email", payload.email, verified?.email],
    ["phone_number", payload.phone_number, verified?.phone_number],
    ["customer_code", payload.customer_code, verified?.customer_code],
    ["total_points", balance, Number(verified?.total_points)],
  ];

  for (const [field, expected, actual] of checks) {
    if (String(expected) !== String(actual)) {
      throw new Error(
        `Verificación fallida del campo ${field} después de actualizar el cliente en Loyverse.`,
      );
    }
  }

  await supabaseRequest(
    "/rest/v1/avopuntos_accounts?profile_id=eq." +
      encodeURIComponent(profileId),
    {
      method: "PATCH",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({
        last_loyverse_points: balance,
        last_loyverse_sync_at: new Date().toISOString(),
        last_loyverse_sync_attempt_at: new Date().toISOString(),
        last_loyverse_sync_error: null,
        updated_at: new Date().toISOString(),
      }),
    },
  );

  return {
    ok: true,
    status: "synced",
    profile_id: profileId,
    balance,
    loyverse_customer_id: customerId,
  };
}

async function syncPendingAccounts(token: string) {
  const accounts = await supabaseRequest(
    "/rest/v1/avopuntos_accounts?select=profile_id,balance,last_loyverse_points&or=(last_loyverse_points.is.null,balance.neq.last_loyverse_points)&order=updated_at.asc&limit=" +
      MAX_ACCOUNTS,
    { method: "GET" },
  );

  const results: any[] = [];

  for (const account of accounts ?? []) {
    const profileId = String(account.profile_id);

    await supabaseRequest(
      "/rest/v1/avopuntos_accounts?profile_id=eq." +
        encodeURIComponent(profileId),
      {
        method: "PATCH",
        headers: { Prefer: "return=minimal" },
        body: JSON.stringify({
          last_loyverse_sync_attempt_at: new Date().toISOString(),
          last_loyverse_sync_error: null,
          updated_at: new Date().toISOString(),
        }),
      },
    );

    try {
      results.push(await syncAccountToLoyverse(token, profileId));
    } catch (error) {
      const message = cleanError(error);

      await supabaseRequest(
        "/rest/v1/avopuntos_accounts?profile_id=eq." +
          encodeURIComponent(profileId),
        {
          method: "PATCH",
          headers: { Prefer: "return=minimal" },
          body: JSON.stringify({
            last_loyverse_sync_error: message,
            updated_at: new Date().toISOString(),
          }),
        },
      );

      results.push({
        ok: false,
        status: "sync_error",
        profile_id: profileId,
        error: message,
      });
    }
  }

  return results;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  if (!(await validateSecret(req))) {
    return json({ error: "Unauthorized" }, 401);
  }

  try {
    const token = await getLoyverseToken();
    const receipts = await processPendingReceipts();
    const accounts = await syncPendingAccounts(token);

    return json({
      ok: true,
      receipts_processed: receipts.length,
      receipts,
      accounts_processed: accounts.length,
      accounts,
    });
  } catch (error) {
    const message = cleanError(error);
    console.error("[avopuntos-process-receipts]", message);
    return json({ ok: false, error: message }, 502);
  }
});
