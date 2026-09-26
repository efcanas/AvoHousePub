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
const MAX_RECEIPTS = 25;

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

async function requestCustomerSync(webhookSecret: string, profileId: string) {
  const response = await fetch(
    SUPABASE_URL + "/functions/v1/loyverse-sync-customer",
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-avohouse-loyverse-webhook-secret": webhookSecret,
      },
      body: JSON.stringify({ user_id: profileId }),
    },
  );

  const responseText = await response.text();
  let body: any = null;
  try {
    body = responseText ? JSON.parse(responseText) : null;
  } catch {
    body = responseText;
  }

  if (!response.ok) {
    throw new Error(
      `Sincronización de cliente falló (${response.status}): ${cleanError(body)}`,
    );
  }

  return body;
}

async function processPendingReceipts(webhookSecret: string) {
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

  const profileIds = [
    ...new Set(
      results
        .filter((result) => result?.ok && result?.profile_id)
        .map((result) => String(result.profile_id)),
    ),
  ];

  const sync_results: any[] = [];
  for (const profileId of profileIds) {
    try {
      sync_results.push(await requestCustomerSync(webhookSecret, profileId));
    } catch (error) {
      sync_results.push({
        ok: false,
        status: "sync_error",
        profile_id: profileId,
        error: cleanError(error),
      });
    }
  }

  return { results, sync_results };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  if (!(await validateSecret(req))) {
    return json({ error: "Unauthorized" }, 401);
  }

  try {
    const processed = await processPendingReceipts(
      req.headers.get("x-avohouse-loyverse-webhook-secret")!,
    );

    return json({
      ok: true,
      receipts_processed: processed.results.length,
      receipts: processed.results,
      customer_sync: processed.sync_results,
    });
  } catch (error) {
    const message = cleanError(error);
    console.error("[avopuntos-process-receipts]", message);
    return json({ ok: false, error: message }, 502);
  }
});
