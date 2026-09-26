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
const MAX_RECEIPTS = 25;

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
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
    try { body = JSON.parse(text); } catch { body = text; }
  }
  if (!response.ok) {
    throw new Error(`Supabase respondió ${response.status}: ${cleanError(body)}`);
  }
  return body;
}

async function supabaseRpc(name: string, args: Record<string, unknown>) {
  return supabaseRequest("/rest/v1/rpc/" + encodeURIComponent(name), {
    method: "POST",
    body: JSON.stringify(args),
  });
}

async function validateWebhookSecret(supplied: string | null) {
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
  if (!value) throw new Error("Falta configurar loyverse_api_token.");
  return value;
}

async function loyverseRequest(token: string, path: string) {
  const response = await fetch(LOYVERSE_BASE_URL + path, {
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
    throw new Error(`Loyverse respondió ${response.status}: ${cleanError(body)}`);
  }
  return body;
}

function parseTimestamp(value: unknown): string | null {
  if (typeof value !== "string" || !value.trim()) return null;
  const d = new Date(value);
  return Number.isFinite(d.getTime()) ? d.toISOString() : null;
}

function toReceiptRow(receipt: any, profileId: string | null) {
  const receiptNumber = String(receipt?.receipt_number ?? "").trim();
  const receiptType = String(receipt?.receipt_type ?? "").trim().toUpperCase();
  const updatedAt = parseTimestamp(receipt?.updated_at);
  if (!receiptNumber || !updatedAt || !["SALE", "REFUND"].includes(receiptType)) {
    return null;
  }

  return {
    receipt_number: receiptNumber,
    receipt_type: receiptType,
    refund_for: receipt?.refund_for ?? null,
    customer_id: receipt?.customer_id ?? null,
    profile_id: profileId,
    order_name: receipt?.order ?? null,
    source: receipt?.source ?? null,
    store_id: receipt?.store_id ?? null,
    employee_id: receipt?.employee_id ?? null,
    pos_device_id: receipt?.pos_device_id ?? null,
    receipt_date: parseTimestamp(receipt?.receipt_date),
    created_at: parseTimestamp(receipt?.created_at),
    updated_at: updatedAt,
    cancelled_at: parseTimestamp(receipt?.cancelled_at),
    total_money: receipt?.total_money ?? null,
    total_tax: receipt?.total_tax ?? null,
    total_discount: receipt?.total_discount ?? null,
    points_earned: receipt?.points_earned ?? null,
    points_deducted: receipt?.points_deducted ?? null,
    points_balance: receipt?.points_balance ?? null,
    line_items: Array.isArray(receipt?.line_items) ? receipt.line_items : [],
    payments: Array.isArray(receipt?.payments) ? receipt.payments : [],
    raw_receipt: receipt,
    synced_at: new Date().toISOString(),
  };
}

async function processWebhookReceipts(receiptNumbers: string[], webhookSecret: string) {
  const unique = [...new Set(receiptNumbers)].slice(0, MAX_RECEIPTS);
  if (!unique.length) return { received: 0, processed: 0, avopuntos: [] as any[] };

  const token = await getLoyverseToken();
  const query = new URLSearchParams({ receipt_numbers: unique.join(","), limit: String(unique.length) });
  const body = await loyverseRequest(token, "/receipts?" + query.toString());
  const receipts = Array.isArray(body?.receipts) ? body.receipts : [];

  const customerIds = receipts
    .map((r: any) => typeof r?.customer_id === "string" ? r.customer_id.trim() : "")
    .filter(Boolean);

  const profileMap = new Map<string, string>();
  if (customerIds.length) {
    const ids = [...new Set(customerIds)].map(encodeURIComponent).join(",");
    const links = await supabaseRequest(
      "/rest/v1/loyverse_customers?select=profile_id,loyverse_customer_id&loyverse_customer_id=in.(" + ids + ")",
      { method: "GET" },
    );
    for (const link of links ?? []) {
      if (link?.loyverse_customer_id && link?.profile_id) {
        profileMap.set(String(link.loyverse_customer_id), String(link.profile_id));
      }
    }
  }

  const rows = receipts
    .map((r: any) => toReceiptRow(
      r,
      typeof r?.customer_id === "string"
        ? profileMap.get(r.customer_id.trim()) ?? null
        : null,
    ))
    .filter(Boolean);

  if (rows.length) {
    await supabaseRequest("/rest/v1/loyverse_receipts?on_conflict=receipt_number", {
      method: "POST",
      headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
      body: JSON.stringify(rows),
    });
  }

  const avopuntos: any[] = [];
  for (const row of rows) {
    if (!row.profile_id) continue;
    try {
      avopuntos.push(
        await supabaseRpc("avopuntos_process_receipt", {
          p_receipt_number: row.receipt_number,
        }),
      );
    } catch (error) {
      avopuntos.push({
        ok: false,
        status: "error",
        receipt_number: row.receipt_number,
        error: cleanError(error),
      });
    }
  }

  const profileIds = [...new Set(rows.map((r: any) => r.profile_id).filter(Boolean))];
  const syncResults: any[] = [];

  for (const profileId of profileIds) {
    try {
      const response = await fetch(
        SUPABASE_URL + "/functions/v1/loyverse-sync-customer",
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "x-avohouse-loyverse-webhook-secret": supplied,
          },
          body: JSON.stringify({ user_id: profileId }),
        },
      );

      const responseText = await response.text();
      let body: any = null;
      try { body = responseText ? JSON.parse(responseText) : null; } catch { body = responseText; }

      if (!response.ok) {
        throw new Error(
          `Sincronización de saldo Loyverse falló (${response.status}): ${cleanError(body)}`,
        );
      }

      syncResults.push({ profile_id: profileId, synced: true });
    } catch (error) {
      syncResults.push({
        profile_id: profileId,
        synced: false,
        error: cleanError(error),
      });
    }
  }

  return {
    received: unique.length,
    found: receipts.length,
    stored: rows.length,
    avopuntos,
    sync_requested: syncResults,
  };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const supplied = new URL(req.url).searchParams.get("secret");
  if (!(await validateWebhookSecret(supplied))) {
    return json({ error: "Unauthorized" }, 401);
  }

  let payload: any = {};
  try {
    payload = await req.json();
  } catch {
    return json({ error: "Invalid JSON" }, 400);
  }

  if (payload?.type !== "receipts.update") {
    return json({ ok: true, ignored: true });
  }

  try {
    const receiptNumbers = Array.isArray(payload?.receipts)
      ? payload.receipts
          .map((r: any) => String(r?.receipt_number ?? "").trim())
          .filter(Boolean)
      : [];

    const result = await processWebhookReceipts(receiptNumbers, supplied);
    return json({ ok: true, ...result });
  } catch (error) {
    const message = cleanError(error);
    console.error("[loyverse-webhook-receipts]", message);
    return json({ ok: false, error: message }, 502);
  }
});
