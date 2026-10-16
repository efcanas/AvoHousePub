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
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
const PURCHASE_TEMPLATE_ID = "5df899e2-f3ff-43e6-89ba-43e3484b059d";
const FROM_EMAIL = "AvoHouse <noreply@avohousepub.com>";

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

function money(value: unknown): string {
  const n = Number(value);
  if (!Number.isFinite(n)) return "$0";
  return "$" + Math.round(n).toLocaleString("es-CO");
}

function formatDate(value: unknown): string {
  const d = new Date(String(value ?? ""));
  if (Number.isNaN(d.getTime())) return "";
  return new Intl.DateTimeFormat("es-CO", {
    timeZone: "America/Bogota",
    day: "2-digit",
    month: "long",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  }).format(d);
}

function escapeHtml(value: unknown): string {
  return String(value ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  }[c] ?? c));
}

async function supabaseRequest(path: string, init: RequestInit = {}) {
  if (!SUPABASE_URL || !SUPABASE_AUTH) throw new Error("Faltan las credenciales internas de Supabase.");

  const headers = new Headers(init.headers);
  headers.set("apikey", SUPABASE_AUTH.key);
  headers.set("Content-Type", "application/json");
  if (!SUPABASE_AUTH.isNewSecret) {
    headers.set("Authorization", "Bearer " + SUPABASE_AUTH.key);
  }

  const response = await fetch(SUPABASE_URL + path, { ...init, headers });
  const text = await response.text();
  let body: any = null;
  try { body = text ? JSON.parse(text) : null; } catch { body = text; }

  if (!response.ok) {
    throw new Error(`Supabase respondió ${response.status}: ${cleanError(body)}`);
  }
  return body;
}

async function validateInternalSecret(secret: string | null) {
  if (!secret) return false;
  try {
    return (await supabaseRequest(
      "/rest/v1/rpc/avohouse_validate_loyverse_webhook",
      {
        method: "POST",
        body: JSON.stringify({ p_secret: secret }),
      },
    )) === true;
  } catch {
    return false;
  }
}

async function getPurchaseState(receiptNumber: string) {
  const rows = await supabaseRequest(
    "/rest/v1/purchase_email_state?select=receipt_number,status,attempts,message_id,last_error,sent_at&receipt_number=eq." +
      encodeURIComponent(receiptNumber) + "&limit=1",
  );
  return Array.isArray(rows) ? rows[0] ?? null : null;
}

async function upsertState(receiptNumber: string, patch: Record<string, unknown>) {
  await supabaseRequest(
    "/rest/v1/purchase_email_state?on_conflict=receipt_number",
    {
      method: "POST",
      headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
      body: JSON.stringify({
        receipt_number: receiptNumber,
        ...patch,
        updated_at: new Date().toISOString(),
      }),
    },
  );
}

function movementTotals(movements: any[]) {
  let earned = 0;
  let used = 0;
  for (const row of movements) {
    const delta = Number(row?.points_delta ?? 0);
    const type = String(row?.movement_type ?? "");
    if (type === "earn") earned += Math.max(0, delta);
    if (type === "redeem") used += Math.max(0, -delta);
  }
  return { earned, used };
}

async function buildAndSend(receiptNumber: string) {
  if (!RESEND_API_KEY) {
    await upsertState(receiptNumber, {
      status: "error",
      last_error: "Falta configurar RESEND_API_KEY en los secretos de Supabase.",
    });
    return { ok: false, status: "not_configured", receipt_number: receiptNumber };
  }

  const state = await getPurchaseState(receiptNumber);
  if (state?.status === "sent") {
    return { ok: true, status: "already_sent", receipt_number: receiptNumber, message_id: state.message_id };
  }

  const receipts = await supabaseRequest(
    "/rest/v1/loyverse_receipts?select=receipt_number,receipt_type,profile_id,receipt_date,created_at,total_money,total_discount,line_items,payments,points_balance,cancelled_at,raw_receipt&receipt_number=eq." +
      encodeURIComponent(receiptNumber) + "&limit=1",
  );
  const receipt = Array.isArray(receipts) ? receipts[0] : null;

  if (!receipt) throw new Error("No se encontró el ticket.");
  if (String(receipt.receipt_type).toUpperCase() !== "SALE") {
    return { ok: true, status: "ignored_non_sale", receipt_number: receiptNumber };
  }
  if (receipt.cancelled_at) {
    return { ok: true, status: "ignored_cancelled", receipt_number: receiptNumber };
  }
  if (!receipt.profile_id) {
    return { ok: true, status: "ignored_without_profile", receipt_number: receiptNumber };
  }

  const profiles = await supabaseRequest(
    "/rest/v1/profiles?select=full_name,email&id=eq." +
      encodeURIComponent(receipt.profile_id) + "&limit=1",
  );
  const profile = Array.isArray(profiles) ? profiles[0] : null;
  if (!profile?.email) throw new Error("El ticket no tiene un correo de cliente asociado.");

  const movements = await supabaseRequest(
    "/rest/v1/avopuntos_movements?select=movement_type,points_delta,created_at,details&profile_id=eq." +
      encodeURIComponent(receipt.profile_id) + "&receipt_number=eq." +
      encodeURIComponent(receiptNumber) + "&order=created_at.asc&limit=50",
  );
  const { earned, used } = movementTotals(Array.isArray(movements) ? movements : []);

  // El saldo canónico de AvoPuntos vive en avopuntos_accounts.
  // loyverse_receipts.points_balance puede contener el saldo de Loyverse y quedar desfasado.
  const accounts = await supabaseRequest(
    "/rest/v1/avopuntos_accounts?select=balance&profile_id=eq." +
      encodeURIComponent(receipt.profile_id) + "&limit=1",
  );
  const account = Array.isArray(accounts) ? accounts[0] : null;
  const avoPointsBalance = account && Number.isFinite(Number(account.balance))
    ? Number(account.balance)
    : 0;

  const items = Array.isArray(receipt.line_items) ? receipt.line_items : [];
  const validNumber = (value: unknown): number | null => {
    if (value === null || value === undefined || value === "") return null;
    const n = Number(value);
    return Number.isFinite(n) ? n : null;
  };
  const grossItemTotal = (item: any): number => {
    const qty = Number(item?.quantity) || 1;
    const gross = validNumber(item?.gross_total_money);
    if (gross !== null) return gross;
    const price = validNumber(item?.price);
    if (price !== null) return price * qty;
    const net = validNumber(item?.total_money) ?? 0;
    const lineDiscount = validNumber(item?.total_discount) ?? 0;
    return net + lineDiscount;
  };
  const grossLineTotals = items.map((item: any) => grossItemTotal(item));
  const grossSubtotal = grossLineTotals.reduce((sum: number, amount: number) => sum + amount, 0);

  const rawReceipt = receipt.raw_receipt && typeof receipt.raw_receipt === "object"
    ? receipt.raw_receipt
    : {};
  const receiptDiscounts = Array.isArray(rawReceipt.total_discounts)
    ? rawReceipt.total_discounts
    : [];
  const lineDiscounts = items.flatMap((item: any) =>
    Array.isArray(item?.line_discounts) ? item.line_discounts : []
  );
  const discountRecords = receiptDiscounts.length ? receiptDiscounts : lineDiscounts;
  const pointsDiscountRecords = discountRecords.filter((discount: any) =>
    String(discount?.type ?? "").toUpperCase() === "DISCOUNT_BY_POINTS" ||
    String(discount?.name ?? "").toLowerCase().includes("points")
  );
  const recordedPointsDiscount = pointsDiscountRecords.reduce(
    (sum: number, discount: any) => sum + Math.max(0, Number(discount?.money_amount ?? 0) || 0),
    0,
  );
  const totalDiscount = Math.max(0, Number(receipt.total_discount ?? 0) || 0);
  const redeemedMoneyFallback = movements
    .filter((movement: any) => String(movement?.movement_type ?? "") === "redeem")
    .reduce((sum: number, movement: any) => {
      const pointValue = validNumber(movement?.details?.point_value_money) ?? 1;
      return sum + Math.abs(Number(movement?.points_delta ?? 0) || 0) * pointValue;
    }, 0);
  const pointsDiscountTotal = Math.min(
    totalDiscount,
    recordedPointsDiscount > 0 ? recordedPointsDiscount : redeemedMoneyFallback,
  );
  const otherDiscountTotal = Math.max(0, totalDiscount - pointsDiscountTotal);

  const itemsHtml = items.map((item: any, index: number) => {
    const qty = Number(item?.quantity) || 1;
    const name = escapeHtml(item?.item_name || item?.variant_name || "Producto");
    const total = money(grossLineTotals[index] ?? 0);
    return `<tr>
      <td style="padding-top:12px;padding-bottom:12px;border-bottom:1px solid #292929;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:1.5;color:#ffffff;">${qty} × ${name}</td>
      <td align="right" style="padding-top:12px;padding-bottom:12px;border-bottom:1px solid #292929;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:1.5;color:#ffffff;font-weight:700;white-space:nowrap;">${total}</td>
    </tr>`;
  }).join("");

  const itemsText = items.map((item: any, index: number) => {
    const qty = Number(item?.quantity) || 1;
    const name = String(item?.item_name || item?.variant_name || "Producto");
    return `${qty} × ${name} · ${money(grossLineTotals[index] ?? 0)}`;
  }).join("\n");

  const payments = Array.isArray(receipt.payments) ? receipt.payments : [];
  const paymentNames = [...new Set(
    payments.map((p: any) => String(p?.name ?? "").trim()).filter(Boolean),
  )];
  const paymentMethod = paymentNames.length ? paymentNames.join(", ") : "No informado";

  await upsertState(receiptNumber, {
    status: "pending",
    attempts: Number(state?.attempts ?? 0) + 1,
    last_error: null,
  });

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: "Bearer " + RESEND_API_KEY,
      "Content-Type": "application/json",
      "User-Agent": "AvoHouse-Purchase-Receipt/1.0",
      "Idempotency-Key": "avohouse-purchase-receipt/" + receiptNumber,
    },
    body: JSON.stringify({
      from: FROM_EMAIL,
      to: [profile.email],
      template: {
        id: PURCHASE_TEMPLATE_ID,
        variables: {
          CUSTOMER_NAME: String(profile.full_name ?? "Cliente AvoHouse"),
          TICKET: receiptNumber,
          PURCHASE_DATE: formatDate(receipt.receipt_date || receipt.created_at),
          ITEMS_HTML: itemsHtml,
          ITEMS_TEXT: itemsText,
          SUBTOTAL: money(grossSubtotal),
          POINTS_DISCOUNT: pointsDiscountTotal > 0 ? "−" + money(pointsDiscountTotal) : "—",
          OTHER_DISCOUNT: otherDiscountTotal > 0 ? "−" + money(otherDiscountTotal) : "—",
          TOTAL: money(receipt.total_money),
          PAYMENT_METHOD: paymentMethod,
          POINTS_EARNED: earned,
          POINTS_USED: used,
          POINTS_BALANCE: avoPointsBalance,
        },
      },
    }),
  });

  const bodyText = await response.text();
  let body: any = null;
  try { body = bodyText ? JSON.parse(bodyText) : null; } catch { body = bodyText; }

  if (!response.ok) {
    const message = `Resend respondió ${response.status}: ${cleanError(body)}`;
    await upsertState(receiptNumber, { status: "error", last_error: message });
    throw new Error(message);
  }

  const messageId = body?.id ?? null;
  await upsertState(receiptNumber, {
    status: "sent",
    message_id: messageId,
    sent_at: new Date().toISOString(),
    last_error: null,
  });

  return { ok: true, status: "sent", receipt_number: receiptNumber, message_id: messageId, to: profile.email };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const suppliedSecret = req.headers.get("x-avohouse-loyverse-webhook-secret");
  if (!(await validateInternalSecret(suppliedSecret))) return json({ error: "Unauthorized" }, 401);

  let payload: any = {};
  try {
    payload = await req.json();
  } catch {
    return json({ error: "Invalid JSON" }, 400);
  }

  const receiptNumber = String(payload?.receipt_number ?? "").trim();
  if (!receiptNumber) return json({ error: "Missing receipt_number" }, 400);

  try {
    return json(await buildAndSend(receiptNumber));
  } catch (error) {
    const message = cleanError(error);
    console.error("[send-purchase-receipt]", message);
    return json({ ok: false, error: message }, 502);
  }
});
