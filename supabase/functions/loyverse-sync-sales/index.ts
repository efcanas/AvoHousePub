const SUPABASE_URL = Deno.env.get("SUPABASE_URL");

type SupabaseAuth = {
  key: string;
  isNewSecret: boolean;
};

function getSupabaseAuth(): SupabaseAuth | null {
  const rawSecretKeys = Deno.env.get("SUPABASE_SECRET_KEYS");

  if (rawSecretKeys) {
    try {
      const keys = JSON.parse(rawSecretKeys);
      const defaultKey =
        typeof keys?.default === "string" ? keys.default.trim() : "";

      if (defaultKey) {
        return {
          key: defaultKey,
          isNewSecret: defaultKey.startsWith("sb_secret_"),
        };
      }
    } catch {
      // Fall through to the legacy service_role key.
    }
  }

  const legacyKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() ?? "";
  if (legacyKey) {
    return { key: legacyKey, isNewSecret: false };
  }

  return null;
}

const SUPABASE_AUTH = getSupabaseAuth();
const LOYVERSE_BASE_URL = "https://api.loyverse.com/v1.0";
const MAX_PAGES_PER_RUN = 10;
const MAX_RECEIPTS_PER_PAGE = 250;
const OVERLAP_MINUTES = 2;
const INITIAL_SYNC_AT = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Connection": "keep-alive",
    },
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

async function supabaseRequest(
  path: string,
  init: RequestInit = {},
): Promise<any> {
  if (!SUPABASE_URL || !SUPABASE_AUTH) {
    throw new Error("Faltan las credenciales internas de Supabase.");
  }

  const headers = new Headers(init.headers);
  headers.set("apikey", SUPABASE_AUTH.key);
  headers.set("Content-Type", "application/json");

  if (!SUPABASE_AUTH.isNewSecret) {
    headers.set("Authorization", "Bearer " + SUPABASE_AUTH.key);
  }

  const response = await fetch(SUPABASE_URL + path, {
    ...init,
    headers,
  });

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

async function supabaseRpc(
  functionName: string,
  args: Record<string, unknown>,
): Promise<any> {
  return supabaseRequest(
    "/rest/v1/rpc/" + encodeURIComponent(functionName),
    {
      method: "POST",
      body: JSON.stringify(args),
    },
  );
}

async function validateInternalSecret(req: Request): Promise<boolean> {
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

async function getLoyverseToken(): Promise<string> {
  const data = await supabaseRpc("avohouse_get_loyverse_api_token", {});
  const token = typeof data === "string" ? data.trim() : "";
  if (!token) {
    throw new Error(
      "Falta configurar el secreto 'loyverse_api_token' en Supabase Vault.",
    );
  }
  return token;
}

async function loyverseRequest(
  token: string,
  path: string,
): Promise<any> {
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

async function getState() {
  const rows = await supabaseRequest(
    "/rest/v1/loyverse_sync_state?select=sync_key,last_updated_at,pagination_cursor,pagination_window_start,last_run_at,last_success_at,records_last_run,last_error&sync_key=eq.receipts&limit=1",
    { method: "GET" },
  );

  const state = Array.isArray(rows) ? rows[0] : null;
  if (!state) {
    throw new Error("No existe el estado de sincronización de recibos.");
  }

  return state;
}

async function saveState(patch: Record<string, unknown>) {
  await supabaseRequest(
    "/rest/v1/loyverse_sync_state?sync_key=eq.receipts",
    {
      method: "PATCH",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({
        ...patch,
        updated_at: new Date().toISOString(),
      }),
    },
  );
}

function isoMinusMinutes(value: string, minutes: number): string {
  const timestamp = new Date(value).getTime();
  if (!Number.isFinite(timestamp)) {
    return INITIAL_SYNC_AT;
  }
  return new Date(timestamp - minutes * 60 * 1000).toISOString();
}

function parseCursor(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function parseTimestamp(value: unknown): string | null {
  if (typeof value !== "string" || !value.trim()) return null;
  const time = new Date(value);
  return Number.isFinite(time.getTime()) ? time.toISOString() : null;
}

function toReceiptRow(
  receipt: any,
  profileId: string | null,
) {
  const receiptNumber = String(receipt?.receipt_number ?? "").trim();
  const receiptType = String(receipt?.receipt_type ?? "").trim().toUpperCase();
  const updatedAt = parseTimestamp(receipt?.updated_at);
  const receiptDate = parseTimestamp(receipt?.receipt_date);
  const createdAt = parseTimestamp(receipt?.created_at);
  const cancelledAt = parseTimestamp(receipt?.cancelled_at);

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
    receipt_date: receiptDate,
    created_at: createdAt,
    updated_at: updatedAt,
    cancelled_at: cancelledAt,
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

async function resolveProfileIds(customerIds: string[]): Promise<Map<string, string>> {
  const result = new Map<string, string>();

  const uniqueIds = [...new Set(
    customerIds
      .map((id) => String(id ?? "").trim())
      .filter(Boolean),
  )];

  if (uniqueIds.length === 0) return result;

  const encoded = uniqueIds.map((id) => encodeURIComponent(id)).join(",");
  const rows = await supabaseRequest(
    "/rest/v1/loyverse_customers?select=profile_id,loyverse_customer_id&loyverse_customer_id=in.(" +
      encoded +
      ")",
    { method: "GET" },
  );

  for (const row of rows ?? []) {
    if (row?.loyverse_customer_id && row?.profile_id) {
      result.set(
        String(row.loyverse_customer_id),
        String(row.profile_id),
      );
    }
  }

  return result;
}

async function upsertReceipts(receipts: any[]) {
  if (receipts.length === 0) return;

  const customerIds = receipts
    .map((receipt) => receipt?.customer_id)
    .filter((id) => typeof id === "string" && id.trim());

  const profileMap = await resolveProfileIds(customerIds);

  const rows = receipts
    .map((receipt) => {
      const customerId =
        typeof receipt?.customer_id === "string"
          ? receipt.customer_id.trim()
          : "";

      return toReceiptRow(
        receipt,
        customerId ? profileMap.get(customerId) ?? null : null,
      );
    })
    .filter(Boolean);

  if (rows.length === 0) return;

  await supabaseRequest(
    "/rest/v1/loyverse_receipts?on_conflict=receipt_number",
    {
      method: "POST",
      headers: {
        Prefer: "resolution=merge-duplicates,return=minimal",
      },
      body: JSON.stringify(rows),
    },
  );
}

async function fetchReceiptPage(
  token: string,
  createdAtMin: string,
  updatedAtMin: string,
  cursor: string | null,
) {
  const params = new URLSearchParams({
    created_at_min: createdAtMin,
    updated_at_min: updatedAtMin,
    limit: String(MAX_RECEIPTS_PER_PAGE),
  });

  if (cursor) {
    params.set("cursor", cursor);
  }

  return loyverseRequest(token, "/receipts?" + params.toString());
}

async function runSync() {
  const startedAt = new Date().toISOString();
  await saveState({
    last_run_at: startedAt,
    last_error: null,
    records_last_run: 0,
  });

  const token = await getLoyverseToken();
  const state = await getState();

  let updatedAtMin = INITIAL_SYNC_AT;
  let cursor: string | null = null;

  if (state.pagination_cursor && state.pagination_window_start) {
    updatedAtMin = parseTimestamp(state.pagination_window_start) ?? INITIAL_SYNC_AT;
    cursor = parseCursor(state.pagination_cursor);
  } else {
    const saved = parseTimestamp(state.last_updated_at);
    updatedAtMin = saved
      ? isoMinusMinutes(saved, OVERLAP_MINUTES)
      : INITIAL_SYNC_AT;
  }

  const rollingCreatedAtMin = isoMinusMinutes(
    new Date().toISOString(),
    30 * 24 * 60,
  );
  const createdAtMin = cursor ? updatedAtMin : rollingCreatedAtMin;

  let pages = 0;
  let processed = 0;
  let maxUpdatedAt: string | null = null;
  let lastCursor: string | null = cursor;

  while (pages < MAX_PAGES_PER_RUN) {
    const body = await fetchReceiptPage(
      token,
      createdAtMin,
      updatedAtMin,
      lastCursor,
    );
    const receipts = Array.isArray(body?.receipts) ? body.receipts : [];
    const nextCursor = parseCursor(body?.cursor);

    if (receipts.length > 0) {
      await upsertReceipts(receipts);
      processed += receipts.length;

      for (const receipt of receipts) {
        const updated = parseTimestamp(receipt?.updated_at);
        if (
          updated &&
          (!maxUpdatedAt ||
            new Date(updated).getTime() > new Date(maxUpdatedAt).getTime())
        ) {
          maxUpdatedAt = updated;
        }
      }
    }

    pages += 1;

    if (!nextCursor) {
      await saveState({
        last_updated_at: maxUpdatedAt ?? state.last_updated_at ?? INITIAL_SYNC_AT,
        pagination_cursor: null,
        pagination_window_start: null,
        last_success_at: new Date().toISOString(),
        records_last_run: processed,
        last_error: null,
      });

      return {
        mode: "sync",
        ok: true,
        pages,
        processed,
        last_updated_at: maxUpdatedAt ?? state.last_updated_at ?? INITIAL_SYNC_AT,
        finished: true,
      };
    }

    lastCursor = nextCursor;
    await saveState({
      pagination_cursor: nextCursor,
      pagination_window_start: updatedAtMin,
      records_last_run: processed,
      last_error: null,
    });
  }

  await saveState({
    pagination_cursor: lastCursor,
    pagination_window_start: updatedAtMin,
    records_last_run: processed,
    last_success_at: new Date().toISOString(),
    last_error: null,
  });

  return {
    mode: "sync",
    ok: true,
    pages,
    processed,
    finished: false,
    remaining_cursor: Boolean(lastCursor),
  };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  if (!(await validateInternalSecret(req))) {
    return json({ error: "Unauthorized" }, 401);
  }

  try {
    const result = await runSync();
    return json(result);
  } catch (error) {
    const message = cleanError(error);

    try {
      await saveState({
        last_error: message,
        last_run_at: new Date().toISOString(),
      });
    } catch {
      // Preserve the original error in the response.
    }

    console.error("[loyverse-sync-sales]", message);
    return json({ ok: false, error: message }, 502);
  }
});
