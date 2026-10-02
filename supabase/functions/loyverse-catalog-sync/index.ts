// Read-only mirror of the Loyverse catalog into Supabase.
// It never writes to Loyverse; all Loyverse requests are GETs.

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
const PAGE_SIZE = 250;
const MAX_PAGES = 100;

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function cleanError(value: unknown): string {
  const message =
    value instanceof Error ? value.message :
    typeof value === "string" ? value :
    JSON.stringify(value);
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

async function validateSecret(supplied: string | null) {
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
    throw new Error(`Loyverse respondió ${response.status}: ${cleanError(body)}`);
  }
  return body;
}

function parseTimestamp(value: unknown): string | null {
  if (typeof value !== "string" || !value.trim()) return null;
  const d = new Date(value);
  return Number.isFinite(d.getTime()) ? d.toISOString() : null;
}

function uuidOrNull(value: unknown): string | null {
  const s = typeof value === "string" ? value.trim() : "";
  return s || null;
}

async function upsert(path: string, rows: Record<string, unknown>[]) {
  if (!rows.length) return;
  await supabaseRequest(path, {
    method: "POST",
    headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
    body: JSON.stringify(rows),
  });
}

async function syncCategories(token: string) {
  const body = await loyverseGet(token, "/categories");
  const categories = Array.isArray(body?.categories) ? body.categories : [];
  const rows = categories.map((c: any) => ({
    id: c?.id,
    name: String(c?.name ?? "").trim() || "Sin nombre",
    color: c?.color ?? null,
    created_at: parseTimestamp(c?.created_at),
    deleted_at: parseTimestamp(c?.deleted_at),
    raw_category: c,
    synced_at: new Date().toISOString(),
  })).filter((r: any) => uuidOrNull(r.id));
  await upsert("/rest/v1/loyverse_categories?on_conflict=id", rows);
  return rows.length;
}

async function syncItemsAndVariants(token: string) {
  let cursor: string | null = null;
  let pages = 0;
  let itemsCount = 0;
  let variantsCount = 0;
  let finished = false;

  while (pages < MAX_PAGES) {
    const params = new URLSearchParams({
      limit: String(PAGE_SIZE),
      show_deleted: "true",
    });
    if (cursor) params.set("cursor", cursor);

    const body = await loyverseGet(token, "/items?" + params.toString());
    const items = Array.isArray(body?.items) ? body.items : [];

    const itemRows = items.map((item: any) => ({
      id: item?.id,
      handle: item?.handle ?? null,
      item_name: String(item?.item_name ?? "").trim() || "Sin nombre",
      description: item?.description ?? null,
      reference_id: item?.reference_id ?? null,
      category_id: uuidOrNull(item?.category_id),
      track_stock: Boolean(item?.track_stock),
      sold_by_weight: Boolean(item?.sold_by_weight),
      is_composite: Boolean(item?.is_composite),
      use_production: Boolean(item?.use_production),
      primary_supplier_id: uuidOrNull(item?.primary_supplier_id),
      tax_ids: Array.isArray(item?.tax_ids) ? item.tax_ids : [],
      modifiers_ids: Array.isArray(item?.modifiers_ids) ? item.modifiers_ids : [],
      form: item?.form ?? null,
      color: item?.color ?? null,
      image_url: item?.image_url ?? null,
      option1_name: item?.option1_name ?? null,
      option2_name: item?.option2_name ?? null,
      option3_name: item?.option3_name ?? null,
      components: Array.isArray(item?.components) ? item.components : [],
      created_at: parseTimestamp(item?.created_at),
      updated_at: parseTimestamp(item?.updated_at),
      deleted_at: parseTimestamp(item?.deleted_at),
      raw_item: item,
      synced_at: new Date().toISOString(),
    })).filter((r: any) => uuidOrNull(r.id));

    await upsert("/rest/v1/loyverse_items?on_conflict=id", itemRows);
    itemsCount += itemRows.length;

    const variantRows: Record<string, unknown>[] = [];
    for (const item of items) {
      const itemId = uuidOrNull(item?.id);
      if (!itemId || !Array.isArray(item?.variants)) continue;
      for (const v of item.variants) {
        const variantId = uuidOrNull(v?.variant_id);
        if (!variantId) continue;
        variantRows.push({
          variant_id: variantId,
          item_id: itemId,
          sku: v?.sku ?? null,
          reference_variant_id: v?.reference_variant_id ?? null,
          option1_value: v?.option1_value ?? null,
          option2_value: v?.option2_value ?? null,
          option3_value: v?.option3_value ?? null,
          barcode: v?.barcode ?? null,
          cost: v?.cost ?? null,
          purchase_cost: v?.purchase_cost ?? null,
          default_pricing_type: v?.default_pricing_type ?? null,
          default_price: v?.default_price ?? null,
          stores: Array.isArray(v?.stores) ? v.stores : [],
          created_at: parseTimestamp(v?.created_at),
          updated_at: parseTimestamp(v?.updated_at),
          deleted_at: parseTimestamp(v?.deleted_at),
          raw_variant: v,
          synced_at: new Date().toISOString(),
        });
      }
    }
    await upsert("/rest/v1/loyverse_item_variants?on_conflict=variant_id", variantRows);
    variantsCount += variantRows.length;

    pages += 1;
    const next = typeof body?.cursor === "string" ? body.cursor.trim() : "";
    if (!next) { finished = true; break; }
    cursor = next;
  }
  return { pages, itemsCount, variantsCount, finished };
}

async function syncInventory(token: string) {
  let cursor: string | null = null;
  let pages = 0;
  let inventoryCount = 0;
  let finished = false;

  while (pages < MAX_PAGES) {
    const params = new URLSearchParams({ limit: String(PAGE_SIZE) });
    if (cursor) params.set("cursor", cursor);

    const body = await loyverseGet(token, "/inventory?" + params.toString());
    const levels = Array.isArray(body?.inventory_levels) ? body.inventory_levels : [];

    const rows = levels.map((level: any) => ({
      variant_id: uuidOrNull(level?.variant_id),
      store_id: uuidOrNull(level?.store_id),
      in_stock: Number(level?.in_stock ?? 0),
      updated_at: parseTimestamp(level?.updated_at),
      raw_inventory: level,
      synced_at: new Date().toISOString(),
    })).filter((r: any) =>
      r.variant_id && r.store_id && Number.isFinite(r.in_stock)
    );

    await upsert(
      "/rest/v1/loyverse_inventory_levels?on_conflict=variant_id,store_id",
      rows,
    );
    inventoryCount += rows.length;

    pages += 1;
    const next = typeof body?.cursor === "string" ? body.cursor.trim() : "";
    if (!next) { finished = true; break; }
    cursor = next;
  }
  return { pages, inventoryCount, finished };
}

async function markStart() {
  await supabaseRequest(
    "/rest/v1/loyverse_catalog_sync_state?sync_key=eq.catalog",
    {
      method: "PATCH",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({
        last_started_at: new Date().toISOString(),
        last_error: null,
        updated_at: new Date().toISOString(),
      }),
    },
  );
}

async function markSuccess(data: {
  items: number;
  variants: number;
  categories: number;
  inventory: number;
}) {
  await supabaseRequest(
    "/rest/v1/loyverse_catalog_sync_state?sync_key=eq.catalog",
    {
      method: "PATCH",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({
        last_success_at: new Date().toISOString(),
        last_items_count: data.items,
        last_variants_count: data.variants,
        last_categories_count: data.categories,
        last_inventory_count: data.inventory,
        last_error: null,
        updated_at: new Date().toISOString(),
      }),
    },
  );
}

async function markError(error: string) {
  await supabaseRequest(
    "/rest/v1/loyverse_catalog_sync_state?sync_key=eq.catalog",
    {
      method: "PATCH",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({
        last_error: error.slice(0, 1500),
        updated_at: new Date().toISOString(),
      }),
    },
  );
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const supplied = req.headers.get("x-avohouse-loyverse-webhook-secret");
  if (!(await validateSecret(supplied))) {
    return json({ error: "Unauthorized" }, 401);
  }

  try {
    await markStart();
    const token = await getLoyverseToken();

    const categories = await syncCategories(token);
    const itemSync = await syncItemsAndVariants(token);
    const inventorySync = await syncInventory(token);

    if (!itemSync.finished || !inventorySync.finished) {
      throw new Error(
        "La sincronización llegó al límite de páginas antes de completar todo el catálogo. Ejecutar nuevamente para continuar.",
      );
    }

    await markSuccess({
      items: itemSync.itemsCount,
      variants: itemSync.variantsCount,
      categories,
      inventory: inventorySync.inventoryCount,
    });

    return json({
      ok: true,
      read_only_against_loyverse: true,
      categories,
      items: itemSync.itemsCount,
      variants: itemSync.variantsCount,
      inventory_levels: inventorySync.inventoryCount,
      item_pages: itemSync.pages,
      inventory_pages: inventorySync.pages,
      completed_at: new Date().toISOString(),
    });
  } catch (error) {
    const message = cleanError(error);
    try { await markError(message); } catch {}
    console.error("[loyverse-catalog-sync]", message);
    return json({ ok: false, error: message }, 502);
  }
});
