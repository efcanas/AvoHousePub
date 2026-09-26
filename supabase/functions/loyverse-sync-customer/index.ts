import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SERVICE_KEY =
  (() => {
    try {
      const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
      return keys?.default ?? null;
    } catch {
      return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? null;
    }
  })() ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

const LOYVERSE_BASE_URL = "https://api.loyverse.com/v1.0";
const MAX_BATCH = 25;

if (!SUPABASE_URL || !SERVICE_KEY) {
  throw new Error("Missing Supabase service credentials");
}

const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function cleanError(value: unknown): string {
  const text = typeof value === "string" ? value : JSON.stringify(value);
  return text.slice(0, 1000);
}

async function validateWebhookSecret(req: Request): Promise<boolean> {
  const supplied = req.headers.get("x-avohouse-loyverse-webhook-secret");
  if (!supplied) return false;

  const { data, error } = await admin.rpc(
    "avohouse_validate_loyverse_webhook",
    { p_secret: supplied },
  );

  return !error && data === true;
}

async function getLoyverseToken(): Promise<string> {
  const { data, error } = await admin.rpc("avohouse_get_loyverse_api_token");
  if (error) {
    throw new Error("No se pudo leer el token de Loyverse: " + error.message);
  }

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
  init: RequestInit = {},
): Promise<any> {
  const headers = new Headers(init.headers);
  headers.set("Authorization", "Bearer " + token);
  headers.set("Content-Type", "application/json");

  const response = await fetch(LOYVERSE_BASE_URL + path, {
    ...init,
    headers,
  });

  const responseText = await response.text();
  let body: any = null;

  if (responseText) {
    try {
      body = JSON.parse(responseText);
    } catch {
      body = responseText;
    }
  }

  if (!response.ok) {
    throw new Error(
      "Loyverse respondió " + response.status + ": " + cleanError(body),
    );
  }

  return body;
}

async function findCustomerByEmail(token: string, email: string) {
  const query = new URLSearchParams({
    email,
    limit: "50",
  });

  const body = await loyverseRequest(
    token,
    "/customers?" + query.toString(),
    { method: "GET" },
  );

  const customers = Array.isArray(body?.customers) ? body.customers : [];
  const exact = customers.filter(
    (customer: any) =>
      String(customer?.email ?? "").trim().toLowerCase() === email,
  );

  if (exact.length > 1) {
    throw new Error(
      "Hay más de un cliente en Loyverse con el mismo correo; la sincronización automática se detuvo para evitar una asociación incorrecta.",
    );
  }

  return exact[0] ?? null;
}

async function saveState(
  profileId: string,
  patch: Record<string, unknown>,
) {
  const { error } = await admin
    .from("loyverse_customers")
    .update({ ...patch, updated_at: new Date().toISOString() })
    .eq("profile_id", profileId);

  if (error) {
    throw new Error("No se pudo actualizar el estado: " + error.message);
  }
}

async function syncCustomer(profileId: string) {
  const { data: profile, error: profileError } = await admin
    .from("profiles")
    .select("id,full_name,username,email,phone")
    .eq("id", profileId)
    .single();

  if (profileError || !profile) {
    throw new Error(
      "No se encontró el perfil AvoHouse: " +
        (profileError?.message ?? "sin datos"),
    );
  }

  const { data: link, error: linkError } = await admin
    .from("loyverse_customers")
    .select(
      "profile_id,loyverse_customer_id,sync_status,attempts,last_attempt_at",
    )
    .eq("profile_id", profileId)
    .single();

  if (linkError || !link) {
    throw new Error(
      "No se encontró el registro de integración: " +
        (linkError?.message ?? "sin datos"),
    );
  }

  if (
    link.sync_status === "processing" &&
    link.last_attempt_at &&
    Date.now() - new Date(link.last_attempt_at).getTime() < 10 * 60 * 1000
  ) {
    return { profileId, skipped: true, reason: "already_processing" };
  }

  const attempts = Number(link.attempts ?? 0) + 1;

  await saveState(profileId, {
    sync_status: "processing",
    attempts,
    last_attempt_at: new Date().toISOString(),
    last_error: null,
  });

  try {
    const token = await getLoyverseToken();
    const email = String(profile.email ?? "").trim().toLowerCase();
    const fullName = String(profile.full_name ?? "").trim();
    const phone = String(profile.phone ?? "").trim();
    const username = String(profile.username ?? "").trim();

    if (!fullName || !email || !phone || !username) {
      throw new Error(
        "El perfil AvoHouse no tiene completos los datos necesarios para crear el cliente en Loyverse.",
      );
    }

    let customerId = link.loyverse_customer_id;
    let existingCustomer: any = null;

    if (customerId) {
      try {
        existingCustomer = await loyverseRequest(
          token,
          "/customers/" + encodeURIComponent(customerId),
          { method: "GET" },
        );
      } catch (error) {
        if (String(error).includes("Loyverse respondió 404")) {
          customerId = null;
        } else {
          throw error;
        }
      }
    }

    if (!customerId) {
      existingCustomer = await findCustomerByEmail(token, email);
      customerId = existingCustomer?.id ?? null;
    }

    let customer: any;

    if (customerId) {
      customer = await loyverseRequest(token, "/customers", {
        method: "POST",
        body: JSON.stringify({
          id: customerId,
          name: fullName,
          email,
          phone_number: phone,
        }),
      });
    } else {
      customer = await loyverseRequest(token, "/customers", {
        method: "POST",
        body: JSON.stringify({
          name: fullName,
          email,
          phone_number: phone,
          customer_code: username,
        }),
      });
    }

    const resultingId = String(
      customer?.id ?? customerId ?? "",
    ).trim();

    if (!resultingId) {
      throw new Error(
        "Loyverse no devolvió el ID del cliente creado/actualizado.",
      );
    }

    await saveState(profileId, {
      loyverse_customer_id: resultingId,
      sync_status: "synced",
      last_synced_at: new Date().toISOString(),
      last_error: null,
      next_attempt_at: null,
    });

    return {
      profileId,
      synced: true,
      loyverseCustomerId: resultingId,
      existed: Boolean(existingCustomer),
    };
  } catch (error) {
    const message = cleanError(
      error instanceof Error ? error.message : error,
    );

    const backoffMinutes = Math.min(
      24 * 60,
      10 * Math.pow(2, Math.min(attempts - 1, 7)),
    );

    await saveState(profileId, {
      sync_status: "error",
      last_error: message,
      next_attempt_at: new Date(
        Date.now() + backoffMinutes * 60 * 1000,
      ).toISOString(),
    });

    throw error;
  }
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  if (!(await validateWebhookSecret(req))) {
    return json({ error: "Unauthorized" }, 401);
  }

  let body: any = {};
  try {
    body = await req.json();
  } catch {
    body = {};
  }

  if (body?.mode === "pending") {
    const now = new Date().toISOString();

    const { data: pending, error } = await admin
      .from("loyverse_customers")
      .select("profile_id")
      .in("sync_status", ["pending", "error"])
      .lte("next_attempt_at", now)
      .order("last_attempt_at", { ascending: true, nullsFirst: true })
      .limit(MAX_BATCH);

    if (error) {
      return json({ error: error.message }, 500);
    }

    const results: any[] = [];

    for (const row of pending ?? []) {
      try {
        results.push(await syncCustomer(row.profile_id));
      } catch (error) {
        results.push({
          profileId: row.profile_id,
          synced: false,
          error: cleanError(
            error instanceof Error ? error.message : error,
          ),
        });
      }
    }

    return json({
      ok: true,
      mode: "pending",
      processed: results.length,
      results,
    });
  }

  const profileId =
    typeof body?.user_id === "string" ? body.user_id : "";

  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
      profileId,
    )
  ) {
    return json({ error: "Invalid user_id" }, 400);
  }

  try {
    const result = await syncCustomer(profileId);
    return json(result);
  } catch (error) {
    return json(
      {
        error: cleanError(
          error instanceof Error ? error.message : error,
        ),
        profileId,
      },
      502,
    );
  }
});
