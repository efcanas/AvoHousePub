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
  return message.slice(0, 1500);
}

function getBearer(req: Request): string | null {
  const value = req.headers.get("authorization") ?? "";
  return value.replace(/^Bearer\s+/i, "").trim() || null;
}

function getJwtSubject(token: string): string | null {
  try {
    const parts = token.split(".");
    if (parts.length < 2) return null;
    const normalized = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = normalized + "=".repeat((4 - normalized.length % 4) % 4);
    const payload = JSON.parse(atob(padded));
    return typeof payload?.sub === "string" ? payload.sub : null;
  } catch {
    return null;
  }
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

async function assertAdmin(req: Request) {
  const token = getBearer(req);
  const userId = token ? getJwtSubject(token) : null;
  if (!userId) throw new Error("Sesión administrativa inválida.");

  const rows = await supabaseRequest(
    "/rest/v1/admin_users?select=user_id&user_id=eq." + encodeURIComponent(userId) + "&limit=1",
    { method: "GET" },
  );
  if (!Array.isArray(rows) || !rows.length) {
    throw new Error("No tienes permisos de administración.");
  }
  return userId;
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

async function loyversePost(token: string, path: string, payload: unknown) {
  const response = await fetch(LOYVERSE_BASE_URL + path, {
    method: "POST",
    headers: {
      Authorization: "Bearer " + token,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(payload),
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

function finiteNumber(value: unknown, field: string): number {
  const n = Number(value);
  if (!Number.isFinite(n)) throw new Error(`El campo ${field} no contiene un número válido.`);
  return n;
}

function requiredString(value: unknown, field: string, max = 200): string {
  const s = typeof value === "string" ? value.trim() : "";
  if (!s) throw new Error(`El campo ${field} es obligatorio.`);
  if (s.length > max) throw new Error(`El campo ${field} supera el límite permitido.`);
  return s;
}

async function getLiveEditData(token: string, itemId: string, variantId: string) {
  const [item, variant, inventory, stores, purchaseRows] = await Promise.all([
    loyverseGet(token, "/items/" + encodeURIComponent(itemId)),
    loyverseGet(token, "/variants/" + encodeURIComponent(variantId)),
    loyverseGet(token, "/inventory?variant_ids=" + encodeURIComponent(variantId) + "&limit=250"),
    loyverseGet(token, "/stores?limit=250"),
    supabaseRequest(
      "/rest/v1/loyverse_item_variants?select=variant_id,purchase_pack_size,purchase_presentation_cost,purchase_presentation_content_ml&variant_id=eq." +
        encodeURIComponent(variantId) + "&limit=1",
      { method: "GET" },
    ),
  ]);
  const purchase = Array.isArray(purchaseRows) && purchaseRows[0] ? purchaseRows[0] : {};
  return {
    item,
    variant,
    inventory_levels: Array.isArray(inventory?.inventory_levels) ? inventory.inventory_levels : [],
    stores: Array.isArray(stores?.stores) ? stores.stores : [],
    purchase_settings: {
      pack_size: purchase?.purchase_pack_size ?? null,
      presentation_cost: purchase?.purchase_presentation_cost ?? null,
      content_ml: purchase?.purchase_presentation_content_ml ?? null,
    },
  };
}

function findStoreOverride(variant: any, storeId: string) {
  const stores = Array.isArray(variant?.stores) ? variant.stores : [];
  return stores.find((s: any) => String(s?.store_id || "") === storeId) ?? null;
}

async function mirrorEditedItem(item: any) {
  const row = {
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
  };
  if (uuidOrNull(row.id)) await upsert("/rest/v1/loyverse_items?on_conflict=id", [row]);
}

async function mirrorEditedVariant(variant: any) {
  const row = {
    variant_id: uuidOrNull(variant?.variant_id),
    item_id: uuidOrNull(variant?.item_id),
    sku: variant?.sku ?? null,
    reference_variant_id: variant?.reference_variant_id ?? null,
    option1_value: variant?.option1_value ?? null,
    option2_value: variant?.option2_value ?? null,
    option3_value: variant?.option3_value ?? null,
    barcode: variant?.barcode ?? null,
    cost: variant?.cost ?? null,
    purchase_cost: variant?.purchase_cost ?? null,
    default_pricing_type: variant?.default_pricing_type ?? null,
    default_price: variant?.default_price ?? null,
    stores: Array.isArray(variant?.stores) ? variant.stores : [],
    created_at: parseTimestamp(variant?.created_at),
    updated_at: parseTimestamp(variant?.updated_at),
    deleted_at: parseTimestamp(variant?.deleted_at),
    raw_variant: variant,
    synced_at: new Date().toISOString(),
  };
  if (uuidOrNull(row.variant_id) && uuidOrNull(row.item_id)) {
    await upsert("/rest/v1/loyverse_item_variants?on_conflict=variant_id", [row]);
  }
}

async function mirrorEditedInventory(levels: any[]) {
  const rows = (Array.isArray(levels) ? levels : []).map((level: any) => ({
    variant_id: uuidOrNull(level?.variant_id),
    store_id: uuidOrNull(level?.store_id),
    in_stock: Number(level?.in_stock ?? 0),
    updated_at: parseTimestamp(level?.updated_at),
    raw_inventory: level,
    synced_at: new Date().toISOString(),
  })).filter((r: any) => r.variant_id && r.store_id && Number.isFinite(r.in_stock));
  await upsert("/rest/v1/loyverse_inventory_levels?on_conflict=variant_id,store_id", rows);
}

async function createCatalogItem(token: string, payload: any) {
  const itemName = requiredString(payload?.item_name, "nombre", 64);
  const categoryId = requiredString(payload?.category_id, "categoría", 64);
  const productType = String(payload?.product_type || "regular").trim().toLowerCase();
  if (!["regular", "composite"].includes(productType)) throw new Error("Tipo de producto no válido.");

  const [storeBody, categoryBody] = await Promise.all([
    loyverseGet(token, "/stores?limit=250"),
    loyverseGet(token, "/categories?limit=250"),
  ]);
  const stores = (Array.isArray(storeBody?.stores) ? storeBody.stores : []).filter((store: any) => store?.id && !store?.deleted_at);
  if (stores.length !== 1) throw new Error(stores.length === 0 ? "No se encontró una tienda activa en Loyverse." : "AvoHouse espera una sola tienda activa en Loyverse para crear productos.");
  const storeId = String(stores[0].id);
  const category = (Array.isArray(categoryBody?.categories) ? categoryBody.categories : []).find((entry: any) => String(entry?.id || "") === categoryId);
  if (!category) throw new Error("La categoría seleccionada no existe en Loyverse.");
  const isInsumosCategory = String(category?.name || "").trim().toLowerCase() === "insumos";
  const isMezcladitasCategory = String(category?.name || "").trim().toLowerCase() === "mezcladitas";
  if (isMezcladitasCategory && productType !== "composite") {
    throw new Error("Los productos de la categoría Mezcladitas deben ser de tipo Producto compuesto.");
  }
  const isComposite = productType === "composite";
  const trackStock = isComposite || isInsumosCategory ? false : Boolean(payload?.track_stock);
  const availableForSale = isInsumosCategory ? false : payload?.available_for_sale !== false;

  let unitCost: number | null = null;
  let packSize: number | null = null;
  let presentationCost: number | null = null;
  let presentationContentMl: number | null = null;

  if (!isComposite) {
    const purchaseCost = finiteNumber(payload?.purchase_cost, "costo de compra");
    if (purchaseCost < 0 || purchaseCost > 1000000000) throw new Error("El costo de compra debe ser un número válido no negativo.");
    if (isInsumosCategory) {
      const contentMl = finiteNumber(payload?.purchase_content_ml, "contenido de la presentación");
      if (contentMl <= 0 || contentMl > 1000000000) throw new Error("El contenido de la presentación debe ser mayor que 0 ml.");
      packSize = 1;
      presentationCost = purchaseCost;
      presentationContentMl = contentMl;
      unitCost = purchaseCost / contentMl;
    } else {
      const pack = finiteNumber(payload?.pack_size, "unidades por presentación");
      if (!Number.isInteger(pack) || pack <= 0 || pack > 100000) throw new Error("Las unidades por presentación deben ser un entero mayor que 0.");
      packSize = pack;
      presentationCost = purchaseCost;
      unitCost = purchaseCost / pack;
    }
  }

  let price = 0;
  if (!isInsumosCategory) {
    price = finiteNumber(payload?.price, "precio");
    if (price < 0 || price > 1000000000) throw new Error("El precio debe ser un número válido no negativo.");
  }

  const lowStockRaw = payload?.low_stock, optimalStockRaw = payload?.optimal_stock;
  let lowStock: number | null = null, optimalStock: number | null = null;
  if (trackStock && lowStockRaw !== undefined && String(lowStockRaw).trim() !== "") {
    lowStock = finiteNumber(lowStockRaw, "stock bajo");
    if (lowStock < 0) throw new Error("El stock bajo no puede ser negativo.");
  }
  if (trackStock && optimalStockRaw !== undefined && String(optimalStockRaw).trim() !== "") {
    optimalStock = finiteNumber(optimalStockRaw, "stock óptimo");
    if (optimalStock < 0) throw new Error("El stock óptimo no puede ser negativo.");
  }

  let initialStock = 0;
  if (trackStock) {
    const stockRaw = payload?.initial_stock === undefined || String(payload.initial_stock).trim() === "" ? 0 : finiteNumber(payload.initial_stock, "existencias iniciales");
    if (stockRaw < 0 || stockRaw > 9999999.999) throw new Error("Las existencias iniciales deben estar entre 0 y 9.999.999,999.");
    initialStock = stockRaw;
  }

  const normalizeComponents = (value: any) => (Array.isArray(value) ? value : [])
    .map((component: any) => ({variant_id:String(component?.variant_id||"").trim(),quantity:Number(component?.quantity)}))
    .filter((component: any) => component.variant_id);
  const components = normalizeComponents(payload?.components);
  if (isComposite) {
    if (!components.length) throw new Error("El producto compuesto debe tener al menos un componente.");
    if (components.length > 100) throw new Error("Un producto no puede superar 100 componentes.");
    const ids = new Set<string>();
    for (const component of components) {
      if (!Number.isFinite(component.quantity) || component.quantity <= 0 || component.quantity > 1000000) throw new Error("Cada componente debe tener una cantidad mayor que 0.");
      if (ids.has(component.variant_id)) throw new Error("No se puede repetir un mismo componente.");
      ids.add(component.variant_id);
      await loyverseGet(token, "/variants/" + encodeURIComponent(component.variant_id));
    }
  }

  const variantPayload: Record<string, unknown> = {
    cost: isComposite ? 0 : unitCost,
    purchase_cost: isComposite ? 0 : unitCost,
    default_pricing_type: "FIXED",
    default_price: price,
    stores: [{
      store_id: storeId, pricing_type: "FIXED", price,
      available_for_sale: availableForSale,
      low_stock: trackStock ? lowStock : null,
      optimal_stock: trackStock ? optimalStock : null,
    }],
  };
  const itemPayload: Record<string, unknown> = {
    item_name: itemName, category_id: categoryId, track_stock: trackStock,
    sold_by_weight: false, is_composite: isComposite, use_production: false,
  };
  if (isComposite) itemPayload.components = components;

  const created = await loyversePost(token, "/items", {...itemPayload, variants:[variantPayload]});
  const itemId = String(created?.id || "").trim();
  if (!itemId) throw new Error("Loyverse creó el artículo pero no devolvió su identificador.");
  let liveItem = created;
  let variant = Array.isArray(created?.variants) ? created.variants[0] : null;
  if (!variant?.variant_id) {
    liveItem = await loyverseGet(token, "/items/" + encodeURIComponent(itemId));
    variant = Array.isArray(liveItem?.variants) ? liveItem.variants[0] : null;
  }
  const variantId = String(variant?.variant_id || "").trim();
  if (!variantId) throw new Error("Loyverse creó el artículo pero no devolvió una variante utilizable.");

  let inventoryLevels:any[] = [];
  if (trackStock) {
    const inventoryResponse = await loyversePost(token, "/inventory", {inventory_levels:[{variant_id:variantId,store_id:storeId,stock_after:initialStock}]});
    inventoryLevels = Array.isArray(inventoryResponse?.inventory_levels) ? inventoryResponse.inventory_levels : [];
    if (!inventoryLevels.length) inventoryLevels=[{variant_id:variantId,store_id:storeId,in_stock:initialStock}];
  }
  await mirrorEditedItem(liveItem);
  await mirrorEditedVariant(variant);
  if (!isComposite && packSize !== null && presentationCost !== null) {
    await supabaseRequest("/rest/v1/loyverse_item_variants?variant_id=eq."+encodeURIComponent(variantId),{
      method:"PATCH",headers:{Prefer:"return=minimal"},
      body:JSON.stringify({purchase_pack_size:packSize,purchase_presentation_cost:presentationCost,purchase_presentation_content_ml:presentationContentMl}),
    });
  }
  if (inventoryLevels.length) await mirrorEditedInventory(inventoryLevels);
  return {ok:true,item_id:itemId,variant_id:variantId,item_name:String(liveItem?.item_name||itemName),product_type:productType,unit_cost:unitCost,purchase_pack_size:packSize,purchase_presentation_cost:presentationCost,purchase_presentation_content_ml:presentationContentMl,initial_stock:trackStock?initialStock:null,available_for_sale:availableForSale,created_at:liveItem?.created_at??null};
}

async function updateCatalogItem(token: string, payload: any) {
  const itemId=requiredString(payload?.item_id,"item_id"),variantId=requiredString(payload?.variant_id,"variant_id");
  const live=await getLiveEditData(token,itemId,variantId),currentItem=live.item,currentVariant=live.variant;
  if(String(currentItem?.id||"")!==itemId)throw new Error("El artículo solicitado no coincide con el artículo de Loyverse.");
  if(String(currentVariant?.variant_id||"")!==variantId)throw new Error("La variante solicitada no coincide con la variante de Loyverse.");
  if(String(currentVariant?.item_id||"")!==itemId)throw new Error("La variante no pertenece al artículo seleccionado.");
  const storeOverrides=Array.isArray(currentVariant?.stores)?currentVariant.stores.filter((s:any)=>s?.store_id):[],storeOverride=storeOverrides[0]??null,storeId=String(storeOverride?.store_id||"");
  if(!storeOverride||!storeId)throw new Error("Loyverse no devolvió una tienda asociada a esta variante.");

  const itemChanges=payload?.item??{},variantChanges=payload?.variant??{},storeChanges=payload?.store??{},inventoryChanges=payload?.inventory??{},purchaseChanges=payload?.purchase??{};
  let itemChanged=false,variantChanged=false,inventoryChanged=false,purchaseSettingsChanged=false;
  const itemName=requiredString(itemChanges?.item_name??currentItem?.item_name,"nombre",64);
  const categoryId=itemChanges?.category_id?String(itemChanges.category_id).trim():null;
  const nextCategoryId=categoryId||String(currentItem?.category_id||"");
  const catBody=await loyverseGet(token,"/categories?limit=250");
  const nextCategory=(Array.isArray(catBody?.categories)?catBody.categories:[]).find((c:any)=>String(c?.id||"")===nextCategoryId);
  const isInsumosCategory=String(nextCategory?.name||"").trim().toLowerCase()==="insumos";
  const currentTrackStock=Boolean(currentItem?.track_stock);
  const requestedTrackStock=itemChanges?.track_stock===undefined?currentTrackStock:Boolean(itemChanges.track_stock);
  const nextTrackStock=Boolean(currentItem?.is_composite)||isInsumosCategory?false:requestedTrackStock;

  let nextComponents=Array.isArray(currentItem?.components)?currentItem.components:[];
  if(Boolean(currentItem?.is_composite)&&itemChanges?.components!==undefined){
    const incoming=(Array.isArray(itemChanges.components)?itemChanges.components:[]).map((component:any)=>({variant_id:String(component?.variant_id||"").trim(),quantity:Number(component?.quantity)})).filter((component:any)=>component.variant_id);
    if(!incoming.length)throw new Error("El producto compuesto debe tener al menos un componente.");
    const ids=new Set<string>();
    for(const component of incoming){
      if(!Number.isFinite(component.quantity)||component.quantity<=0||component.quantity>1000000)throw new Error("Cada componente debe tener una cantidad mayor que 0.");
      if(component.variant_id===variantId)throw new Error("Un producto compuesto no puede incluirse a sí mismo.");
      if(ids.has(component.variant_id))throw new Error("No se puede repetir un mismo componente.");
      ids.add(component.variant_id);
    }
    nextComponents=incoming;
  }

  if(itemName!==String(currentItem?.item_name??"").trim()||String(categoryId??"")!==String(currentItem?.category_id??"")||nextTrackStock!==currentTrackStock||(Boolean(currentItem?.is_composite)&&itemChanges?.components!==undefined&&JSON.stringify(nextComponents)!==JSON.stringify(currentItem?.components??[]))){
    itemChanged=true;
    const itemPayload:Record<string,unknown>={id:itemId,item_name:itemName,category_id:categoryId,track_stock:nextTrackStock};
    if(Boolean(currentItem?.is_composite)&&itemChanges?.components!==undefined)itemPayload.components=nextComponents;
    await loyversePost(token,"/items",itemPayload);
  }

  const nextVariant:any={...currentVariant,variant_id:variantId,item_id:itemId};
  const currentPurchaseSettings=live.purchase_settings??{};
  const hasPackInput=purchaseChanges?.pack_size!==undefined;
  const hasPresentationCostInput=purchaseChanges?.presentation_cost!==undefined;
  const hasContentInput=purchaseChanges?.presentation_content_ml!==undefined;
  let nextPackSize=currentPurchaseSettings?.pack_size==null?null:Number(currentPurchaseSettings.pack_size);
  let nextPresentationCost=currentPurchaseSettings?.presentation_cost==null?null:Number(currentPurchaseSettings.presentation_cost);
  let nextContentMl=currentPurchaseSettings?.content_ml==null?null:Number(currentPurchaseSettings.content_ml);

  if(!isInsumosCategory&&hasContentInput)nextContentMl=null;
  if(isInsumosCategory){
    if(!hasPresentationCostInput && (nextPresentationCost===null||!Number.isFinite(nextPresentationCost))) throw new Error("El producto de la categoría Insumos requiere un costo de compra por presentación.");
    if(!hasContentInput && (nextContentMl===null||!Number.isFinite(nextContentMl)||nextContentMl<=0)) throw new Error("El producto de la categoría Insumos requiere el contenido de la presentación en ml.");
    const contentRaw=hasContentInput?String(purchaseChanges?.presentation_content_ml??"").trim():String(nextContentMl??"").trim();
    const presentationRaw=hasPresentationCostInput?String(purchaseChanges?.presentation_cost??"").trim():String(nextPresentationCost??"").trim();
    const content=Number(contentRaw),presentation=Number(presentationRaw);
    if(contentRaw===""||!Number.isFinite(content)||content<=0||content>1000000000)throw new Error("El contenido de la presentación debe ser mayor que 0 ml.");
    if(presentationRaw===""||!Number.isFinite(presentation)||presentation<0||presentation>1000000000)throw new Error("El costo de compra debe ser un número válido no negativo.");
    nextPackSize=1;nextContentMl=content;nextPresentationCost=presentation;
    const costPerMl=presentation/content;
    nextVariant.cost=costPerMl;nextVariant.purchase_cost=costPerMl;
    storeChanges.available_for_sale=false;
  }else if(hasPackInput||hasPresentationCostInput){
    const packRaw=String(purchaseChanges?.pack_size??"").trim(),presentationRaw=String(purchaseChanges?.presentation_cost??"").trim();
    if((packRaw!==""||presentationRaw!=="")&&(packRaw===""||presentationRaw===""))throw new Error("Para calcular el costo unitario debes indicar las unidades por presentación y el costo de compra.");
    if(packRaw===""&&presentationRaw===""){nextPackSize=null;nextPresentationCost=null;}
    else{
      const pack=Number(packRaw),presentationCost=Number(presentationRaw);
      if(!Number.isInteger(pack)||pack<=0||pack>100000)throw new Error("Las unidades por presentación deben ser un entero mayor que 0.");
      if(!Number.isFinite(presentationCost)||presentationCost<0||presentationCost>1000000000)throw new Error("El costo de compra debe ser un número válido no negativo.");
      nextPackSize=pack;nextPresentationCost=presentationCost;nextVariant.cost=presentationCost/pack;nextVariant.purchase_cost=presentationCost/pack;
    }
  }

  if(variantChanges?.sku!==undefined){const sku=String(variantChanges.sku).trim();if(!sku&&String(currentVariant?.sku??"").trim())throw new Error("El SKU no puede quedar vacío al editar una variante existente.");if(sku.length>40)throw new Error("El SKU no puede superar 40 caracteres.");nextVariant.sku=sku||currentVariant?.sku||undefined;}
  if(variantChanges?.barcode!==undefined){const barcode=String(variantChanges.barcode).trim();if(barcode.length>128)throw new Error("El código de barras no puede superar 128 caracteres.");nextVariant.barcode=barcode||currentVariant?.barcode||undefined;}
  for(const field of ["cost","purchase_cost","default_price"]){if(variantChanges?.[field]!==undefined&&variantChanges[field]!==""){const n=finiteNumber(variantChanges[field],field);if(n<0)throw new Error(`El campo ${field} no puede ser negativo.`);nextVariant[field]=n;}}
  if(variantChanges?.default_pricing_type!==undefined){const pricingType=String(variantChanges.default_pricing_type);if(!["FIXED","VARIABLE"].includes(pricingType))throw new Error("Tipo de precio no válido.");nextVariant.default_pricing_type=pricingType;}

  const nextStore:any={...storeOverride,store_id:storeId};
  if(storeChanges?.price!==undefined&&storeChanges.price!==""){const price=finiteNumber(storeChanges.price,"precio");if(price<0)throw new Error("El precio no puede ser negativo.");nextStore.price=price;}
  if(storeChanges?.available_for_sale!==undefined)nextStore.available_for_sale=Boolean(storeChanges.available_for_sale);
  if(storeChanges?.low_stock!==undefined&&storeChanges.low_stock!==""){const low=finiteNumber(storeChanges.low_stock,"stock bajo");if(low<0)throw new Error("El stock bajo no puede ser negativo.");nextStore.low_stock=low;}
  if(storeChanges?.optimal_stock!==undefined&&storeChanges.optimal_stock!==""){const optimal=finiteNumber(storeChanges.optimal_stock,"stock óptimo");if(optimal<0)throw new Error("El stock óptimo no puede ser negativo.");nextStore.optimal_stock=optimal;}
  if(variantChanges?.default_price!==undefined&&variantChanges.default_price!=="")nextStore.price=Number(nextVariant.default_price);
  if(isInsumosCategory)nextStore.available_for_sale=false;

  nextVariant.stores=(Array.isArray(currentVariant?.stores)?currentVariant.stores:[]).map((store:any)=>String(store?.store_id||"")===storeId?nextStore:store);

  const changedVariantFields=String(nextVariant?.sku??"")!==String(currentVariant?.sku??"")||String(nextVariant?.barcode??"")!==String(currentVariant?.barcode??"")||Number(nextVariant?.cost??0)!==Number(currentVariant?.cost??0)||Number(nextVariant?.purchase_cost??0)!==Number(currentVariant?.purchase_cost??0)||String(nextVariant?.default_pricing_type??"")!==String(currentVariant?.default_pricing_type??"")||Number(nextVariant?.default_price??0)!==Number(currentVariant?.default_price??0)||JSON.stringify(nextVariant.stores)!==JSON.stringify(currentVariant.stores);

  if(changedVariantFields){variantChanged=true;const variantPayload:Record<string,unknown>={variant_id:variantId,item_id:itemId,reference_variant_id:currentVariant?.reference_variant_id??null,option1_value:currentVariant?.option1_value??null,option2_value:currentVariant?.option2_value??null,option3_value:currentVariant?.option3_value??null,sku:nextVariant?.sku??undefined,barcode:nextVariant?.barcode??undefined,cost:nextVariant?.cost??0,purchase_cost:nextVariant?.purchase_cost??0,default_pricing_type:nextVariant?.default_pricing_type??"VARIABLE",default_price:nextVariant?.default_price??null,stores:nextVariant.stores};
    if(variantPayload.sku===undefined)delete variantPayload.sku;if(variantPayload.barcode===undefined)delete variantPayload.barcode;
    await loyversePost(token,"/variants",variantPayload);
  }

  const currentPackComparable=currentPurchaseSettings?.pack_size==null?null:Number(currentPurchaseSettings.pack_size);
  const currentPresentationComparable=currentPurchaseSettings?.presentation_cost==null?null:Number(currentPurchaseSettings.presentation_cost);
  const currentContentComparable=currentPurchaseSettings?.content_ml==null?null:Number(currentPurchaseSettings.content_ml);
  purchaseSettingsChanged=nextPackSize!==currentPackComparable||nextPresentationCost!==currentPresentationComparable||nextContentMl!==currentContentComparable;

  if(inventoryChanges?.stock_after!==undefined&&inventoryChanges.stock_after!==""&&nextTrackStock&&!isInsumosCategory){
    const stockAfter=finiteNumber(inventoryChanges.stock_after,"existencias");if(stockAfter<0)throw new Error("Las existencias no pueden ser negativas desde esta pantalla.");
    const currentLevel=(Array.isArray(live.inventory_levels)?live.inventory_levels:[]).find((level:any)=>String(level?.store_id||"")===storeId),currentStock=currentLevel?Number(currentLevel.in_stock??0):0;
    if(stockAfter!==currentStock){inventoryChanged=true;await loyversePost(token,"/inventory",{inventory_levels:[{variant_id:variantId,store_id:storeId,stock_after:stockAfter}]});}
  }

  const verified=await getLiveEditData(token,itemId,variantId),verifiedStore=findStoreOverride(verified.variant,storeId),verifiedLevel=(Array.isArray(verified.inventory_levels)?verified.inventory_levels:[]).find((level:any)=>String(level?.store_id||"")===storeId);
  if(itemChanged&&(String(verified.item?.item_name??"").trim()!==itemName||String(verified.item?.category_id??"")!==String(categoryId??"")||Boolean(verified.item?.track_stock)!==nextTrackStock||(Boolean(currentItem?.is_composite)&&itemChanges?.components!==undefined&&JSON.stringify(verified.item?.components??[])!==JSON.stringify(nextComponents))))throw new Error("La verificación posterior a la actualización del artículo o composición no coincidió con lo solicitado.");

  if(variantChanged){
    const expectedSku=nextVariant?.sku,expectedBarcode=nextVariant?.barcode;
    if((expectedSku!==undefined&&String(verified.variant?.sku??"")!==String(expectedSku))||(expectedBarcode!==undefined&&String(verified.variant?.barcode??"")!==String(expectedBarcode))||Number(verified.variant?.cost??0)!==Number(nextVariant?.cost??0)||Number(verified.variant?.purchase_cost??0)!==Number(nextVariant?.purchase_cost??0)||Number(verified.variant?.default_price??0)!==Number(nextVariant?.default_price??0)||String(verified.variant?.default_pricing_type??"")!==String(nextVariant?.default_pricing_type??""))throw new Error("La verificación posterior a la actualización de la variante no coincidió con lo solicitado.");
    const verifiedStoreAgain=findStoreOverride(verified.variant,storeId);
    for(const key of ["price","available_for_sale","low_stock","optimal_stock"])if(nextStore?.[key]!==undefined&&JSON.stringify(verifiedStoreAgain?.[key])!==JSON.stringify(nextStore?.[key]))throw new Error("La verificación posterior de la configuración de tienda no coincidió con lo solicitado.");
  }
  if(inventoryChanged){const verifiedStock=Number(verifiedLevel?.in_stock),expectedStock=Number(inventoryChanges.stock_after);if(!Number.isFinite(verifiedStock)||verifiedStock!==expectedStock)throw new Error("La verificación posterior al cambio de existencias no coincidió con lo solicitado.");}

  if(purchaseSettingsChanged){
    const saved=await supabaseRequest("/rest/v1/loyverse_item_variants?variant_id=eq."+encodeURIComponent(variantId),{
      method:"PATCH",headers:{Prefer:"return=representation"},
      body:JSON.stringify({purchase_pack_size:nextPackSize,purchase_presentation_cost:nextPresentationCost,purchase_presentation_content_ml:nextContentMl,synced_at:new Date().toISOString()})
    });
    const savedRow=Array.isArray(saved)?saved[0]:null;
    const savedPack=savedRow?.purchase_pack_size==null?null:Number(savedRow.purchase_pack_size),savedPresentation=savedRow?.purchase_presentation_cost==null?null:Number(savedRow.purchase_presentation_cost),savedContent=savedRow?.purchase_presentation_content_ml==null?null:Number(savedRow.purchase_presentation_content_ml);
    if(savedPack!==nextPackSize||savedPresentation!==nextPresentationCost||savedContent!==nextContentMl)throw new Error("La verificación posterior de la presentación, contenido y costo de compra no coincidió con lo solicitado.");
  }
  await mirrorEditedItem(verified.item);await mirrorEditedVariant(verified.variant);await mirrorEditedInventory(verified.inventory_levels);
  return{ok:true,item:verified.item,variant:verified.variant,inventory_levels:verified.inventory_levels,stores:verified.stores,store_id:storeId,changed:{item:itemChanged,variant:variantChanged,inventory:inventoryChanged,purchase_settings:purchaseSettingsChanged},edited_at:new Date().toISOString()};
}

async function setPurchasePackSize(payload: any) {
  const variantId = requiredString(payload?.variant_id, "variant_id");
  const value = finiteNumber(payload?.pack_size, "presentación");
  if (!Number.isFinite(value) || value <= 0 || value > 100000) {
    throw new Error("La presentación debe ser un número mayor que 0.");
  }

  const rows = await supabaseRequest(
    "/rest/v1/loyverse_item_variants?select=variant_id&variant_id=eq." + encodeURIComponent(variantId) + "&limit=1",
    { method: "GET" },
  );
  if (!Array.isArray(rows) || !rows.length) {
    throw new Error("La variante no existe en el catálogo de AvoHouse.");
  }

  await supabaseRequest(
    "/rest/v1/loyverse_item_variants?variant_id=eq." + encodeURIComponent(variantId),
    {
      method: "PATCH",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({ purchase_pack_size: value, synced_at: new Date().toISOString() }),
    },
  );

  return { ok: true, variant_id: variantId, pack_size: value, saved_at: new Date().toISOString() };
}

async function createPurchaseRecord(userId: string, purchaseDate: string, notes: string | null, lines: any[], totalUnits: number, totalValue: number, purchaseType: "inventory" | "insumo" = "inventory") {
  const created = await supabaseRequest("/rest/v1/avohouse_inventory_purchases", {
    method: "POST",
    headers: { Prefer: "return=representation" },
    body: JSON.stringify({ purchase_date: purchaseDate, purchase_type: purchaseType, created_by: userId, status: "processing", line_count: lines.length, total_units: totalUnits, total_value: totalValue, notes }),
  });
  if (!Array.isArray(created) || !created[0]?.id) throw new Error("No se pudo crear el registro de la compra.");
  return created[0];
}

async function patchPurchase(purchaseId: string, data: Record<string, unknown>) {
  await supabaseRequest("/rest/v1/avohouse_inventory_purchases?id=eq." + encodeURIComponent(purchaseId), {
    method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify(data),
  });
}

async function registerPurchase(token: string, userId: string, payload: any) {
  const rawLines = Array.isArray(payload?.lines) ? payload.lines : [];
  if (!rawLines.length) throw new Error("La compra debe tener al menos un producto.");
  if (rawLines.length > 50) throw new Error("La compra no puede superar 50 productos.");
  const purchaseDate = typeof payload?.purchase_date === "string" && /^\d{4}-\d{2}-\d{2}$/.test(payload.purchase_date) ? payload.purchase_date : new Date().toISOString().slice(0, 10);
  const notesRaw = typeof payload?.notes === "string" ? payload.notes.trim() : "";
  const notes = notesRaw ? notesRaw.slice(0, 1000) : null;

  const normalized = rawLines.map((line: any, index: number) => {
    const variantId = requiredString(line?.variant_id, "producto");
    const quantity = Number(line?.quantity);
    const packRaw = line?.pack_size;
    const packSize = packRaw === null || packRaw === undefined || packRaw === "" ? null : Number(packRaw);
    const contentRaw = line?.presentation_content_ml;
    const presentationContentMl = contentRaw === null || contentRaw === undefined || contentRaw === "" ? null : Number(contentRaw);
    const purchaseTotalValue = Number(line?.purchase_total_value);
    if (!Number.isInteger(quantity) || quantity <= 0 || quantity > 100000) throw new Error("La cantidad de la línea " + (index + 1) + " debe ser un entero mayor que 0.");
    if (packSize !== null && (!Number.isInteger(packSize) || packSize <= 0 || packSize > 100000)) throw new Error("La Presentación de la línea " + (index + 1) + " debe ser un entero mayor que 0.");
    if (presentationContentMl !== null && (!Number.isFinite(presentationContentMl) || presentationContentMl <= 0 || presentationContentMl > 100000000)) throw new Error("El contenido de la presentación de la línea " + (index + 1) + " debe ser mayor que 0 ml.");
    if (!Number.isFinite(purchaseTotalValue) || purchaseTotalValue <= 0 || purchaseTotalValue > 1000000000) throw new Error("El Valor total de la línea " + (index + 1) + " debe ser mayor que 0.");
    return { variant_id: variantId, quantity, pack_size: packSize, presentation_content_ml: presentationContentMl, purchase_total_value: purchaseTotalValue };
  });

  const seen = new Set<string>();
  for (const line of normalized) {
    if (seen.has(line.variant_id)) throw new Error("No repitas un mismo producto dentro de la compra.");
    seen.add(line.variant_id);
  }

  const { preparedNew, storeAndStock, deltas, insumoUpdates } = await preparePurchaseLinesForDelta(token, normalized, []);
  const totalUnits = preparedNew.reduce((sum, line) => sum + Number(line.units_received), 0);
  const totalValue = preparedNew.reduce((sum, line) => sum + Number(line.line_total), 0);
  const purchase = await createPurchaseRecord(userId, purchaseDate, notes, preparedNew, totalUnits, totalValue, "inventory");

  try {
    const lineRows = preparedNew.map((line, index) => ({
      purchase_id: purchase.id,
      line_number: index + 1,
      variant_id: line.variant_id,
      item_id: line.item_id,
      product_name: line.product_name,
      sku: line.sku,
      pack_size: line.pack_size,
      presentation_quantity: line.presentation_quantity,
      presentation_content_ml: line.presentation_content_ml,
      purchase_unit: line.purchase_unit,
      purchase_total_value: line.purchase_total_value,
      unit_cost: line.unit_cost,
      line_total: line.line_total,
      units_received: line.units_received,
      previous_purchase_cost: line.previous_purchase_cost,
      stock_before: line.isInsumo ? null : Number(line.stock_before ?? 0),
      stock_after: line.isInsumo ? null : Number(line.stock_after ?? 0),
    }));
    await supabaseRequest("/rest/v1/avohouse_inventory_purchase_lines", {
      method: "POST",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify(lineRows),
    });

    const inventoryChanges = await applyPurchaseInventoryDelta(token, deltas, storeAndStock);
    for (const [variantId, update] of insumoUpdates.entries()) {
      await setInsumoPurchaseCost(token, variantId, Number(update.purchaseCost));
    }

    await patchPurchase(purchase.id, {
      status: "completed",
      completed_at: new Date().toISOString(),
      error_message: null,
    });

    return {
      ok: true,
      purchase_id: purchase.id,
      purchase_number: purchase.purchase_number,
      purchase_date: purchaseDate,
      purchase_type: "inventory",
      line_count: preparedNew.length,
      total_units: totalUnits,
      total_value: totalValue,
      inventory_adjusted: inventoryChanges.size,
      lines: preparedNew,
      completed_at: new Date().toISOString(),
    };
  } catch (error) {
    try { await patchPurchase(purchase.id, { status: "failed", error_message: cleanError(error) }); } catch {}
    throw error;
  }
}


async function getPurchaseForAdmin(purchaseId: string) {
  const rows = await supabaseRequest(
    "/rest/v1/avohouse_inventory_purchases?select=id,purchase_number,purchase_date,purchase_type,status,line_count,total_units,total_value,notes,created_at,completed_at&id=eq." + encodeURIComponent(purchaseId) + "&limit=1",
    { method: "GET" },
  );
  if (!Array.isArray(rows) || !rows[0]) throw new Error("No se encontró la compra.");
  return rows[0];
}

async function getPurchaseLinesForAdmin(purchaseId: string) {
  const rows = await supabaseRequest(
    "/rest/v1/avohouse_inventory_purchase_lines?select=purchase_id,line_number,variant_id,item_id,product_name,sku,pack_size,presentation_quantity,purchase_unit,purchase_total_value,unit_cost,line_total,units_received,stock_before,stock_after,previous_purchase_cost&purchase_id=eq." + encodeURIComponent(purchaseId) + "&order=line_number",
    { method: "GET" },
  );
  return Array.isArray(rows) ? rows : [];
}

async function normalizePurchaseLines(rawLines: any[]) {
  if (!Array.isArray(rawLines) || !rawLines.length) throw new Error("La compra debe tener al menos un producto.");
  if (rawLines.length > 50) throw new Error("La compra no puede superar 50 productos.");

  const normalized = rawLines.map((line: any, index: number) => {
    const variantId = requiredString(line?.variant_id, "producto");
    const quantity = Number(line?.quantity);
    const packRaw = line?.pack_size;
    const packSize = packRaw === null || packRaw === undefined || packRaw === "" ? null : Number(packRaw);
    const contentRaw = line?.presentation_content_ml;
    const presentationContentMl = contentRaw === null || contentRaw === undefined || contentRaw === "" ? null : Number(contentRaw);
    const purchaseTotalValue = Number(line?.purchase_total_value);
    if (!Number.isInteger(quantity) || quantity <= 0 || quantity > 100000) throw new Error("La cantidad de la línea " + (index + 1) + " debe ser un entero mayor que 0.");
    if (packSize !== null && (!Number.isInteger(packSize) || packSize <= 0 || packSize > 100000)) throw new Error("La Presentación de la línea " + (index + 1) + " debe ser un entero mayor que 0.");
    if (presentationContentMl !== null && (!Number.isFinite(presentationContentMl) || presentationContentMl <= 0 || presentationContentMl > 100000000)) throw new Error("El contenido de la presentación de la línea " + (index + 1) + " debe ser mayor que 0 ml.");
    if (!Number.isFinite(purchaseTotalValue) || purchaseTotalValue <= 0 || purchaseTotalValue > 1000000000) throw new Error("El Valor total de la línea " + (index + 1) + " debe ser mayor que 0.");
    return { variant_id: variantId, quantity, pack_size: packSize, presentation_content_ml: presentationContentMl, purchase_total_value: purchaseTotalValue };
  });

  const seen = new Set<string>();
  for (const line of normalized) {
    if (seen.has(line.variant_id)) throw new Error("No repitas un mismo producto dentro de la compra.");
    seen.add(line.variant_id);
  }
  return normalized;
}

async function preparePurchaseLinesForDelta(token: string, normalized: any[], oldLines: any[]) {
  const variantIds = [...new Set([
    ...normalized.map((l: any) => String(l.variant_id)),
    ...oldLines.map((l: any) => String(l.variant_id)),
  ])];

  const catalogVariants = await supabaseRequest(
    "/rest/v1/loyverse_item_variants?select=variant_id,item_id,sku,purchase_cost,purchase_presentation_content_ml&variant_id=in.(" + encodeURIComponent(variantIds.join(",")) + ")",
    { method: "GET" },
  );
  if (!Array.isArray(catalogVariants) || catalogVariants.length !== variantIds.length) {
    throw new Error("Uno o más productos ya no están disponibles en el catálogo sincronizado.");
  }

  const variantMap = new Map(catalogVariants.map((v: any) => [String(v.variant_id), v]));
  const itemIds = [...new Set(catalogVariants.map((v: any) => String(v.item_id)).filter(Boolean))];
  const catalogItems = await supabaseRequest(
    "/rest/v1/loyverse_items?select=id,item_name,category_id,track_stock&id=in.(" + encodeURIComponent(itemIds.join(",")) + ")",
    { method: "GET" },
  );
  const itemMap = new Map((Array.isArray(catalogItems) ? catalogItems : []).map((i: any) => [String(i.id), i]));

  const categories = await supabaseRequest(
    "/rest/v1/loyverse_categories?select=id,name&id=in.(" + encodeURIComponent([...new Set([...itemMap.values()].map((i: any) => String(i.category_id || "")).filter(Boolean))].join(",")) + ")",
    { method: "GET" },
  );
  const categoryMap = new Map((Array.isArray(categories) ? categories : []).map((c: any) => [String(c.id), String(c.name || "")]));

  const deltas = new Map<string, number>();
  for (const old of oldLines) {
    const id = String(old.variant_id);
    const isOldInsumo = Number(old?.presentation_content_ml) > 0 || String(old?.purchase_unit || "").toUpperCase() === "PRESENTACIÓN";
    if (isOldInsumo) continue;
    const units = Number(old.units_received || 0);
    if (!Number.isFinite(units) || units < 0) throw new Error("La compra existente contiene una cantidad de inventario inválida.");
    deltas.set(id, (deltas.get(id) || 0) - units);
  }

  const preparedNew: any[] = [];
  const storeAndStock = new Map<string, any>();
  const insumoUpdates = new Map<string, any>();

  for (const line of normalized) {
    const v = variantMap.get(String(line.variant_id));
    const item = v ? itemMap.get(String(v.item_id)) : null;
    const categoryName = String(categoryMap.get(String(item?.category_id || "")) || "").trim().toLowerCase();
    const isInsumo = categoryName === "insumos";

    if (isInsumo) {
      const configuredContent = Number(v?.purchase_presentation_content_ml);
      if (!Number.isFinite(configuredContent) || configuredContent <= 0) {
        throw new Error(String(item?.item_name || "El insumo") + " no tiene configurado el contenido de la presentación.");
      }
      if (line.presentation_content_ml !== null && Math.abs(Number(line.presentation_content_ml) - configuredContent) > 0.000001) {
        throw new Error("El contenido de la presentación no coincide con el configurado para " + String(item?.item_name || "el insumo") + ".");
      }
      const content = configuredContent;
      const unitsReceived = line.quantity;
      const unitCost = line.purchase_total_value / (line.quantity * content);
      const currentCost = Number(v?.purchase_cost ?? 0);
      if (!Number.isFinite(unitCost) || unitCost <= 0) throw new Error("No se pudo calcular el costo por ml de " + String(item?.item_name || "el insumo") + ".");
      if (!Number.isFinite(currentCost) || currentCost < 0) throw new Error("El costo actual de " + String(item?.item_name || "el insumo") + " no es válido.");
      preparedNew.push({
        variant_id: String(line.variant_id),
        item_id: String(v.item_id),
        product_name: String(item?.item_name || "Sin nombre"),
        sku: v?.sku ?? null,
        pack_size: 1,
        presentation_quantity: line.quantity,
        presentation_content_ml: content,
        purchase_unit: "PRESENTACIÓN",
        purchase_total_value: line.purchase_total_value,
        unit_cost: unitCost,
        line_total: line.purchase_total_value,
        units_received: unitsReceived,
        stock_before: null,
        stock_after: null,
        previous_purchase_cost: currentCost,
        isInsumo: true,
      });
      insumoUpdates.set(String(line.variant_id), { purchaseCost: unitCost });
      continue;
    }

    if (!item?.track_stock) {
      throw new Error(String(item?.item_name || "Este producto") + " no tiene seguimiento de inventario activo en Loyverse.");
    }
    if (line.pack_size === null) throw new Error("La Presentación de " + String(item?.item_name || "este producto") + " debe ser un entero mayor que 0.");

    const [liveVariant, inventoryBody] = await Promise.all([
      loyverseGet(token, "/variants/" + encodeURIComponent(line.variant_id)),
      loyverseGet(token, "/inventory?variant_ids=" + encodeURIComponent(line.variant_id) + "&limit=250"),
    ]);
    const stores = Array.isArray(liveVariant?.stores) ? liveVariant.stores : [];
    const store = stores[0] || null;
    const storeId = String(store?.store_id || "");
    if (!storeId) throw new Error(String(item?.item_name || "El producto") + " no tiene una tienda configurada en Loyverse.");
    const levels = Array.isArray(inventoryBody?.inventory_levels) ? inventoryBody.inventory_levels : [];
    const level = levels.find((x: any) => String(x?.store_id || "") === storeId) || levels[0] || null;
    const stockBefore = level ? Number(level.in_stock ?? 0) : 0;
    if (!Number.isFinite(stockBefore)) throw new Error("No se pudo determinar el stock actual de " + String(item?.item_name || "este producto") + ".");
    const unitsReceived = line.quantity * line.pack_size;
    const unitCost = line.purchase_total_value / unitsReceived;
    const stockAfter = stockBefore + unitsReceived;
    deltas.set(String(line.variant_id), (deltas.get(String(line.variant_id)) || 0) + unitsReceived);
    preparedNew.push({
      variant_id: String(line.variant_id),
      item_id: String(v.item_id),
      product_name: String(item?.item_name || "Sin nombre"),
      sku: v?.sku ?? null,
      pack_size: line.pack_size,
      presentation_quantity: line.quantity,
      presentation_content_ml: null,
      purchase_unit: "UNIDAD",
      purchase_total_value: line.purchase_total_value,
      unit_cost: unitCost,
      line_total: line.purchase_total_value,
      units_received: unitsReceived,
      stock_before: stockBefore,
      stock_after: stockAfter,
      previous_purchase_cost: null,
      isInsumo: false,
    });
    storeAndStock.set(String(line.variant_id), { storeId, stockBefore, item });
  }

  return { deltas, preparedNew, storeAndStock, insumoUpdates };
}

async function applyPurchaseInventoryDelta(token: string, deltas: Map<string, number>, storeAndStock: Map<string, any>) {
  const changed = [...deltas.entries()].filter(([, delta]) => Number(delta) !== 0);
  if (!changed.length) return new Map<string, any>();

  const updates = changed.map(([variantId, delta]) => {
    const state = storeAndStock.get(variantId);
    if (!state) throw new Error("No se pudo preparar el stock de una variante.");
    return {
      variant_id: variantId,
      store_id: state.storeId,
      stock_before: Number(state.stockBefore),
      delta: Number(delta),
      stock_after: Number(state.stockBefore) + Number(delta),
    };
  });

  await loyversePost(token, "/inventory", {
    inventory_levels: updates.map((x) => ({
      variant_id: x.variant_id,
      store_id: x.store_id,
      stock_after: x.stock_after,
    })),
  });

  for (const x of updates) {
    const verifyBody = await loyverseGet(token, "/inventory?variant_ids=" + encodeURIComponent(x.variant_id) + "&limit=250");
    const levels = Array.isArray(verifyBody?.inventory_levels) ? verifyBody.inventory_levels : [];
    const verified = levels.find((v: any) => String(v?.store_id || "") === x.store_id) || levels[0] || null;
    const verifiedStock = Number(verified?.in_stock);
    if (!Number.isFinite(verifiedStock) || verifiedStock !== Number(x.stock_after)) {
      throw new Error("La verificación del stock actualizado no coincidió.");
    }
  }

  return new Map(updates.map((x) => [x.variant_id, x]));
}

async function getPreviousInsumoPurchaseCost(variantId:string,purchaseId:string,oldLine:any){
  const recorded=Number(oldLine?.previous_purchase_cost);
  if(Number.isFinite(recorded)&&recorded>=0)return recorded;
  const prior=await supabaseRequest(
    "/rest/v1/avohouse_inventory_purchase_lines?select=purchase_id,unit_cost&variant_id=eq."+encodeURIComponent(variantId)+"&purchase_id=neq."+encodeURIComponent(purchaseId)+"&order=purchase_id.desc&limit=1",
    {method:"GET"}
  );
  if(Array.isArray(prior)&&prior[0]&&Number.isFinite(Number(prior[0].unit_cost))&&Number(prior[0].unit_cost)>=0)return Number(prior[0].unit_cost);
  return null;
}

async function restoreRemovedInsumoCosts(token:string,purchaseId:string,oldLines:any[],newVariantIds:Set<string>){
  for(const old of oldLines){
    const variantId=String(old.variant_id||"");
    const isInsumo=Number(old?.presentation_content_ml)>0;
    if(!variantId||!isInsumo||newVariantIds.has(variantId))continue;
    const previous=await getPreviousInsumoPurchaseCost(variantId,purchaseId,old);
    if(previous===null)throw new Error("No se pudo determinar el costo anterior del insumo "+String(old.product_name||variantId)+" para revertir esta modificación.");
    await setInsumoPurchaseCost(token,variantId,previous);
  }
}

async function updatePurchase(token:string,userId:string,payload:any){
  const purchaseId=requiredString(payload?.purchase_id,"purchase_id");
  const purchase=await getPurchaseForAdmin(purchaseId);
  if(purchase.status!=="completed")throw new Error("Solo se pueden modificar compras completadas.");
  const oldLines=await getPurchaseLinesForAdmin(purchaseId);
  const normalized=await normalizePurchaseLines(payload?.lines);
  const {preparedNew,storeAndStock,deltas,insumoUpdates}=await preparePurchaseLinesForDelta(token,normalized,oldLines);
  const totalUnits=preparedNew.reduce((sum,line)=>sum+Number(line.units_received),0);
  const totalValue=preparedNew.reduce((sum,line)=>sum+Number(line.line_total),0);
  const newVariantIds=new Set(preparedNew.map(line=>String(line.variant_id)));
  const inventoryChanges=await applyPurchaseInventoryDelta(token,deltas,storeAndStock);
  try{
    await restoreRemovedInsumoCosts(token,purchaseId,oldLines,newVariantIds);
    for(const [variantId,update] of insumoUpdates.entries())await setInsumoPurchaseCost(token,variantId,Number(update.purchaseCost));
    await supabaseRequest("/rest/v1/avohouse_inventory_purchase_lines?purchase_id=eq."+encodeURIComponent(purchaseId),{method:"DELETE"});
    const lineRows=preparedNew.map((line,index)=>{
      const delta=Number(deltas.get(line.variant_id)||0),state=storeAndStock.get(line.variant_id);
      const stockBefore=Number(state?.stockBefore??line.stock_before??0);
      return{
        purchase_id:purchaseId,line_number:index+1,variant_id:line.variant_id,item_id:line.item_id,product_name:line.product_name,sku:line.sku,
        pack_size:line.pack_size,presentation_quantity:line.presentation_quantity,presentation_content_ml:line.presentation_content_ml,
        purchase_unit:line.purchase_unit,purchase_total_value:line.purchase_total_value,unit_cost:line.unit_cost,line_total:line.line_total,
        units_received:line.units_received,stock_before:line.isInsumo?null:stockBefore,stock_after:line.isInsumo?null:stockBefore+delta,
        previous_purchase_cost:line.previous_purchase_cost
      };
    });
    await supabaseRequest("/rest/v1/avohouse_inventory_purchase_lines",{method:"POST",headers:{Prefer:"return=minimal"},body:JSON.stringify(lineRows)});
    const purchaseDate=typeof payload?.purchase_date==="string"&&/^\d{4}-\d{2}-\d{2}$/.test(payload.purchase_date)?payload.purchase_date:purchase.purchase_date;
    const notesRaw=typeof payload?.notes==="string"?payload.notes.trim():"";
    await patchPurchase(purchaseId,{purchase_date:purchaseDate,status:"completed",line_count:preparedNew.length,total_units:totalUnits,total_value:totalValue,notes:notesRaw?notesRaw.slice(0,1000):null,updated_at:new Date().toISOString(),updated_by:userId,completed_at:purchase.completed_at||new Date().toISOString(),error_message:null});
    return{ok:true,purchase_id:purchaseId,purchase_number:purchase.purchase_number,purchase_date:purchaseDate,line_count:preparedNew.length,total_units:totalUnits,total_value:totalValue,updated_at:new Date().toISOString()};
  }catch(error){throw error;}
}

async function deletePurchase(token:string,userId:string,payload:any){
  const purchaseId=requiredString(payload?.purchase_id,"purchase_id");
  const purchase=await getPurchaseForAdmin(purchaseId);
  if(purchase.status!=="completed")throw new Error("La compra ya no está activa.");
  const oldLines=await getPurchaseLinesForAdmin(purchaseId);
  if(!oldLines.length)throw new Error("La compra no tiene líneas para revertir.");
  const {deltas,storeAndStock}=await preparePurchaseLinesForDelta(token,[],oldLines);
  const inventoryChanges=await applyPurchaseInventoryDelta(token,deltas,storeAndStock);
  try{
    await restoreRemovedInsumoCosts(token,purchaseId,oldLines,new Set<string>());
    await patchPurchase(purchaseId,{status:"cancelled",deleted_at:new Date().toISOString(),deleted_by:userId,updated_at:new Date().toISOString(),updated_by:userId,error_message:null});
    return{ok:true,purchase_id:purchaseId,purchase_number:purchase.purchase_number,status:"cancelled",inventory_adjusted:inventoryChanges.size,deleted_at:new Date().toISOString()};
  }catch(error){throw error;}
}


async function getInsumoProduct(token: string, variantId: string) {
  const rows = await supabaseRequest(
    "/rest/v1/loyverse_item_variants?select=variant_id,item_id,sku,purchase_cost,purchase_presentation_content_ml,stores,option1_value,option2_value,option3_value&variant_id=eq." + encodeURIComponent(variantId) + "&limit=1",
    { method: "GET" },
  );
  if (!Array.isArray(rows) || !rows[0]) throw new Error("El insumo seleccionado ya no está disponible.");
  const v = rows[0];
  const items = await supabaseRequest(
    "/rest/v1/loyverse_items?select=id,item_name,category_id,track_stock&id=eq." + encodeURIComponent(String(v.item_id)) + "&limit=1",
    { method: "GET" },
  );
  const item = Array.isArray(items) ? items[0] : null;
  if (!item || String(item.category_id) === "") throw new Error("No se pudo identificar la categoría del insumo.");
  const cats = await supabaseRequest(
    "/rest/v1/loyverse_categories?select=id,name&id=eq." + encodeURIComponent(String(item.category_id)) + "&limit=1",
    { method: "GET" },
  );
  const categoryName = Array.isArray(cats) && cats[0] ? String(cats[0].name || "") : "";
  if (categoryName !== "Insumos") throw new Error("El producto seleccionado no pertenece a la categoría Insumos.");
  if (Boolean(item.track_stock)) throw new Error(String(item.item_name || "Este insumo") + " tiene inventario activo en Loyverse y no puede registrarse con este flujo.");
  return { variant: v, item, categoryName };
}

async function setInsumoPurchaseCost(token: string, variantId: string, purchaseCost: number) {
  const live = await loyverseGet(token, "/variants/" + encodeURIComponent(variantId));
  const current = Number(live?.purchase_cost ?? 0);
  if (!Number.isFinite(purchaseCost) || purchaseCost < 0) throw new Error("El costo de compra no puede ser negativo.");

  await loyversePost(token, "/variants/" + encodeURIComponent(variantId), {
    purchase_cost: purchaseCost,
  });

  const verified = await loyverseGet(token, "/variants/" + encodeURIComponent(variantId));
  const verifiedCost = Number(verified?.purchase_cost);
  if (!Number.isFinite(verifiedCost) || Math.abs(verifiedCost - purchaseCost) > 0.000001) {
    throw new Error("Loyverse no confirmó el nuevo Costo de compra.");
  }
  return { previous: current, current: verifiedCost };
}

async function registerInsumoPurchase(token: string, userId: string, payload: any) {
  const rawLines = Array.isArray(payload?.lines) ? payload.lines : [];
  if (!rawLines.length) throw new Error("La compra de insumos debe tener al menos un producto.");
  if (rawLines.length > 50) throw new Error("La compra no puede superar 50 productos.");
  const purchaseDate = typeof payload?.purchase_date === "string" && /^\d{4}-\d{2}-\d{2}$/.test(payload.purchase_date) ? payload.purchase_date : new Date().toISOString().slice(0,10);
  const notesRaw = typeof payload?.notes === "string" ? payload.notes.trim() : "";
  const notes = notesRaw ? notesRaw.slice(0,1000) : null;
  const normalized = rawLines.map((line:any,index:number)=>{
    const variantId=requiredString(line?.variant_id,"producto");
    const quantity=Number(line?.quantity), purchaseTotalValue=Number(line?.purchase_total_value), presentationContentMl=Number(line?.presentation_content_ml);
    if(!Number.isInteger(quantity)||quantity<=0||quantity>100000) throw new Error("La cantidad de la línea "+(index+1)+" debe ser un entero mayor que 0.");
    if(!Number.isFinite(purchaseTotalValue)||purchaseTotalValue<=0||purchaseTotalValue>1000000000) throw new Error("El Valor total de la línea "+(index+1)+" debe ser mayor que 0.");
    if(!Number.isFinite(presentationContentMl)||presentationContentMl<=0) throw new Error("El contenido de la presentación de la línea "+(index+1)+" debe ser mayor que 0 ml.");
    return {variant_id:variantId,quantity,purchase_total_value:purchaseTotalValue,presentation_content_ml:presentationContentMl};
  });
  const seen=new Set<string>(); for(const line of normalized){if(seen.has(line.variant_id))throw new Error("No repitas un mismo insumo dentro de la compra.");seen.add(line.variant_id);}
  const prepared:any[]=[];
  for(const line of normalized){
    const info=await getInsumoProduct(token,line.variant_id);
    const configuredContent=Number(info.variant?.purchase_presentation_content_ml);
    if(!Number.isFinite(configuredContent)||configuredContent<=0) throw new Error("El insumo "+String(info.item.item_name||"seleccionado")+" no tiene configurado el contenido de su presentación.");
    if(Math.abs(configuredContent-line.presentation_content_ml)>0.000001) throw new Error("El contenido de la presentación no coincide con el configurado para "+String(info.item.item_name||"el insumo")+".");
    const live=await loyverseGet(token,"/variants/"+encodeURIComponent(line.variant_id));
    const currentCost=Number(live?.purchase_cost??0);
    const presentationCost=line.purchase_total_value/line.quantity;
    const costPerMl=presentationCost/configuredContent;
    await setInsumoPurchaseCost(token,line.variant_id,costPerMl);
    prepared.push({variant_id:line.variant_id,item_id:String(info.variant.item_id),product_name:String(info.item.item_name||"Sin nombre"),sku:info.variant.sku??null,pack_size:1,presentation_quantity:line.quantity,presentation_content_ml:configuredContent,purchase_unit:"PRESENTACIÓN",purchase_total_value:line.purchase_total_value,unit_cost:costPerMl,line_total:line.purchase_total_value,units_received:line.quantity,stock_before:null,stock_after:null,previous_purchase_cost:currentCost,purchase_cost_after:costPerMl});
  }
  const totalUnits=prepared.reduce((sum,line)=>sum+Number(line.units_received),0);
  const totalValue=prepared.reduce((sum,line)=>sum+Number(line.line_total),0);
  const purchase=await createPurchaseRecord(userId,purchaseDate,notes,prepared,totalUnits,totalValue,"insumo");
  try{
    const lineRows=prepared.map((line,index)=>({purchase_id:purchase.id,line_number:index+1,variant_id:line.variant_id,item_id:line.item_id,product_name:line.product_name,sku:line.sku,pack_size:line.pack_size,presentation_quantity:line.presentation_quantity,presentation_content_ml:line.presentation_content_ml,purchase_unit:line.purchase_unit,purchase_total_value:line.purchase_total_value,unit_cost:line.unit_cost,line_total:line.line_total,units_received:line.units_received,previous_purchase_cost:line.previous_purchase_cost,stock_before:null,stock_after:null}));
    await supabaseRequest("/rest/v1/avohouse_inventory_purchase_lines",{method:"POST",headers:{Prefer:"return=minimal"},body:JSON.stringify(lineRows)});
    await patchPurchase(purchase.id,{status:"completed",completed_at:new Date().toISOString(),error_message:null});
    return {ok:true,purchase_id:purchase.id,purchase_number:purchase.purchase_number,purchase_date:purchaseDate,purchase_type:"insumo",line_count:prepared.length,total_units:totalUnits,total_value:totalValue,lines:prepared.map(line=>({product_name:line.product_name,presentation_quantity:line.presentation_quantity,presentation_content_ml:line.presentation_content_ml,purchase_total_value:line.purchase_total_value,unit_cost:line.unit_cost})),completed_at:new Date().toISOString()};
  }catch(error){try{await patchPurchase(purchase.id,{status:"failed",error_message:cleanError(error)});}catch{}throw error;}
}


async function updateInsumoPurchase(token: string, userId: string, payload: any, purchase: any, oldLines: any[]) {
  const rawLines=Array.isArray(payload?.lines)?payload.lines:[];
  if(!rawLines.length) throw new Error("La compra de insumos debe tener al menos un producto.");
  if(rawLines.length>50) throw new Error("La compra no puede superar 50 productos.");
  const normalized=rawLines.map((line:any,index:number)=>{
    const variantId=requiredString(line?.variant_id,"producto"),quantity=Number(line?.quantity),purchaseTotalValue=Number(line?.purchase_total_value),presentationContentMl=Number(line?.presentation_content_ml);
    if(!Number.isInteger(quantity)||quantity<=0)throw new Error("La cantidad de la línea "+(index+1)+" debe ser un entero mayor que 0.");
    if(!Number.isFinite(purchaseTotalValue)||purchaseTotalValue<=0)throw new Error("El Valor total de la línea "+(index+1)+" debe ser mayor que 0.");
    if(!Number.isFinite(presentationContentMl)||presentationContentMl<=0)throw new Error("El contenido de la presentación de la línea "+(index+1)+" debe ser mayor que 0 ml.");
    return{variant_id:variantId,quantity,purchase_total_value:purchaseTotalValue,presentation_content_ml:presentationContentMl};
  });
  const oldByVariant=new Map(oldLines.map((l:any)=>[String(l.variant_id),l]));
  const seen=new Set<string>(),newPrepared:any[]=[];
  for(const line of normalized){
    if(seen.has(line.variant_id))throw new Error("No repitas un mismo insumo dentro de la compra.");seen.add(line.variant_id);
    const info=await getInsumoProduct(token,line.variant_id);
    const configuredContent=Number(info.variant?.purchase_presentation_content_ml);
    if(!Number.isFinite(configuredContent)||configuredContent<=0)throw new Error("El insumo "+String(info.item.item_name||"seleccionado")+" no tiene configurado el contenido de su presentación.");
    if(Math.abs(configuredContent-line.presentation_content_ml)>0.000001)throw new Error("El contenido de la presentación no coincide con el configurado para "+String(info.item.item_name||"el insumo")+".");
    const currentLive=await loyverseGet(token,"/variants/"+encodeURIComponent(line.variant_id));
    const previousCost=Number(currentLive?.purchase_cost??0);
    const presentationCost=line.purchase_total_value/line.quantity;
    const costPerMl=presentationCost/configuredContent;
    await setInsumoPurchaseCost(token,line.variant_id,costPerMl);
    newPrepared.push({variant_id:line.variant_id,item_id:String(info.variant.item_id),product_name:String(info.item.item_name||"Sin nombre"),sku:info.variant.sku??null,pack_size:1,presentation_quantity:line.quantity,presentation_content_ml:configuredContent,purchase_unit:"PRESENTACIÓN",purchase_total_value:line.purchase_total_value,unit_cost:costPerMl,line_total:line.purchase_total_value,units_received:line.quantity,stock_before:null,stock_after:null,previous_purchase_cost:previousCost,was_existing_line:Boolean(oldByVariant.get(line.variant_id))});
  }
  for(const old of oldLines){
    const oldVariantId=String(old.variant_id); if(normalized.some((l:any)=>l.variant_id===oldVariantId))continue;
    const prior=await supabaseRequest("/rest/v1/avohouse_inventory_purchase_lines?select=purchase_id,unit_cost,purchase_id&variant_id=eq."+encodeURIComponent(oldVariantId)+"&purchase_id=neq."+encodeURIComponent(purchase.id)+"&order=purchase_id.desc&limit=1",{method:"GET"});
    if(Array.isArray(prior)&&prior[0]&&Number(prior[0].unit_cost)>0)await setInsumoPurchaseCost(token,oldVariantId,Number(prior[0].unit_cost));
  }
  const totalUnits=newPrepared.reduce((s,l)=>s+Number(l.units_received),0),totalValue=newPrepared.reduce((s,l)=>s+Number(l.line_total),0);
  await supabaseRequest("/rest/v1/avohouse_inventory_purchase_lines?purchase_id=eq."+encodeURIComponent(purchase.id),{method:"DELETE"});
  const lineRows=newPrepared.map((line,index)=>({purchase_id:purchase.id,line_number:index+1,variant_id:line.variant_id,item_id:line.item_id,product_name:line.product_name,sku:line.sku,pack_size:line.pack_size,presentation_quantity:line.presentation_quantity,presentation_content_ml:line.presentation_content_ml,purchase_unit:line.purchase_unit,purchase_total_value:line.purchase_total_value,unit_cost:line.unit_cost,line_total:line.line_total,units_received:line.units_received,stock_before:null,stock_after:null}));
  await supabaseRequest("/rest/v1/avohouse_inventory_purchase_lines",{method:"POST",headers:{Prefer:"return=minimal"},body:JSON.stringify(lineRows)});
  const purchaseDate=typeof payload?.purchase_date==="string"&&/^\d{4}-\d{2}-\d{2}$/.test(payload.purchase_date)?payload.purchase_date:purchase.purchase_date;
  const notesRaw=typeof payload?.notes==="string"?payload.notes.trim():"";
  await patchPurchase(purchase.id,{purchase_date:purchaseDate,status:"completed",line_count:newPrepared.length,total_units:totalUnits,total_value:totalValue,notes:notesRaw?notesRaw.slice(0,1000):null,updated_at:new Date().toISOString(),updated_by:userId,error_message:null});
  return{ok:true,purchase_id:purchase.id,purchase_number:purchase.purchase_number,purchase_type:"insumo",purchase_date:purchaseDate,line_count:newPrepared.length,total_units:totalUnits,total_value:totalValue,updated_at:new Date().toISOString()};
}

async function deleteInsumoPurchase(token: string, userId: string, purchase: any, oldLines: any[]) {
  if (purchase.status !== "completed") throw new Error("La compra ya no está activa.");
  if (!oldLines.length) throw new Error("La compra no tiene líneas para revertir.");
  // Deleting an insumo purchase should restore the purchase cost that existed before this purchase,
  // when that value is available. Otherwise, leave the current cost untouched and preserve the history.
  // For a safe first implementation, the immediately preceding recorded purchase for each variant is used.
  const affected = new Set(oldLines.map((l: any) => String(l.variant_id)));
  for (const variantId of affected) {
    const prior = await supabaseRequest(
      "/rest/v1/avohouse_inventory_purchase_lines?select=purchase_id,unit_cost,purchase_id&variant_id=eq." + encodeURIComponent(variantId) + "&purchase_id=neq." + encodeURIComponent(purchase.id) + "&order=purchase_id.desc&limit=1",
      { method: "GET" },
    );
    if (Array.isArray(prior) && prior[0] && Number(prior[0].unit_cost) > 0) {
      await setInsumoPurchaseCost(token, variantId, Number(prior[0].unit_cost));
    }
  }
  await patchPurchase(purchase.id, {
    status: "cancelled",
    deleted_at: new Date().toISOString(),
    deleted_by: userId,
    updated_at: new Date().toISOString(),
    updated_by: userId,
    error_message: null,
  });
  return { ok: true, purchase_id: purchase.id, purchase_number: purchase.purchase_number, purchase_type: "insumo", status: "cancelled", inventory_adjusted: 0, deleted_at: new Date().toISOString() };
}

async function upsert(path: string, rows: Record<string, unknown>[]) {
  if (!rows.length) return;
  await supabaseRequest(path, {
    method: "POST",
    headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
    body: JSON.stringify(rows),
  });
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

async function syncCategories(token: string) {
  const body = await loyverseGet(token, "/categories");
  const rows = (Array.isArray(body?.categories) ? body.categories : [])
    .map((c: any) => ({
      id: c?.id,
      name: String(c?.name ?? "").trim() || "Sin nombre",
      color: c?.color ?? null,
      created_at: parseTimestamp(c?.created_at),
      deleted_at: parseTimestamp(c?.deleted_at),
      raw_category: c,
      synced_at: new Date().toISOString(),
    }))
    .filter((r: any) => uuidOrNull(r.id));
  await upsert("/rest/v1/loyverse_categories?on_conflict=id", rows);
  return rows.length;
}

async function syncItemsAndVariants(token: string) {
  let cursor: string | null = null;
  let pages = 0;
  let items = 0;
  let variants = 0;
  let finished = false;

  while (pages < MAX_PAGES) {
    const params = new URLSearchParams({
      limit: String(PAGE_SIZE),
      show_deleted: "true",
    });
    if (cursor) params.set("cursor", cursor);

    const body = await loyverseGet(token, "/items?" + params.toString());
    const list = Array.isArray(body?.items) ? body.items : [];

    const itemRows = list.map((item: any) => ({
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
    items += itemRows.length;

    const variantRows: Record<string, unknown>[] = [];
    for (const item of list) {
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
    variants += variantRows.length;

    pages += 1;
    const next = typeof body?.cursor === "string" ? body.cursor.trim() : "";
    if (!next) {
      finished = true;
      break;
    }
    cursor = next;
  }

  return { pages, items, variants, finished };
}

async function syncInventory(token: string) {
  let cursor: string | null = null;
  let pages = 0;
  let count = 0;
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
    count += rows.length;

    pages += 1;
    const next = typeof body?.cursor === "string" ? body.cursor.trim() : "";
    if (!next) {
      finished = true;
      break;
    }
    cursor = next;
  }

  return { pages, count, finished };
}

async function logStart() {
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

async function logSuccess(data: { items:number; variants:number; categories:number; inventory:number }) {
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

async function logError(message: string) {
  await supabaseRequest(
    "/rest/v1/loyverse_catalog_sync_state?sync_key=eq.catalog",
    {
      method: "PATCH",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({
        last_error: message.slice(0, 1500),
        updated_at: new Date().toISOString(),
      }),
    },
  );
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    await assertAdmin(req);
    const body = await req.json().catch(() => ({}));
    const action = String(body?.action || "sync").trim().toLowerCase();
    const token = await getLoyverseToken();

    if (action === "create_item") {
      return json(await createCatalogItem(token, body));
    }

    if (action === "get_edit") {
      const itemId = requiredString(body?.item_id, "item_id");
      const variantId = requiredString(body?.variant_id, "variant_id");
      const data = await getLiveEditData(token, itemId, variantId);
      return json({ ok: true, ...data });
    }

    if (action === "update_item") {
      return json(await updateCatalogItem(token, body));
    }

    if (action === "set_pack_size") {
      return json(await setPurchasePackSize(body));
    }

    if (action === "register_purchase") {
      const userId = await assertAdmin(req);
      return json(await registerPurchase(token, userId, body));
    }

    if (action === "register_insumo_purchase") {
      const userId = await assertAdmin(req);
      return json(await registerInsumoPurchase(token, userId, body));
    }

    if (action === "update_purchase") {
      const userId = await assertAdmin(req);
      const purchase = await getPurchaseForAdmin(requiredString(body?.purchase_id, "purchase_id"));
      if (purchase.purchase_type === "insumo") {
        const oldLines = await getPurchaseLinesForAdmin(purchase.id);
        return json(await updateInsumoPurchase(token, userId, body, purchase, oldLines));
      }
      return json(await updatePurchase(token, userId, body));
    }

    if (action === "delete_purchase") {
      const userId = await assertAdmin(req);
      const purchase = await getPurchaseForAdmin(requiredString(body?.purchase_id, "purchase_id"));
      if (purchase.purchase_type === "insumo") {
        const oldLines = await getPurchaseLinesForAdmin(purchase.id);
        return json(await deleteInsumoPurchase(token, userId, purchase, oldLines));
      }
      return json(await deletePurchase(token, userId, body));
    }

    if (action !== "sync") return json({ ok: false, error: "Acción no reconocida." }, 400);

    await logStart();
    const categories = await syncCategories(token);
    const itemSync = await syncItemsAndVariants(token);
    const inventorySync = await syncInventory(token);

    if (!itemSync.finished || !inventorySync.finished) {
      throw new Error("La sincronización alcanzó el límite de páginas antes de completarse.");
    }

    await logSuccess({
      categories,
      items: itemSync.items,
      variants: itemSync.variants,
      inventory: inventorySync.count,
    });

    return json({
      ok: true,
      categories,
      items: itemSync.items,
      variants: itemSync.variants,
      inventory_levels: inventorySync.count,
      completed_at: new Date().toISOString(),
    });
  } catch (error) {
    const message = cleanError(error);
    try { await logError(message); } catch {}
    return json({ ok: false, error: message }, 403);
  }
});
