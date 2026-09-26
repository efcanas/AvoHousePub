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

  const legacyKey =
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() ?? "";

  if (legacyKey) {
    return {
      key: legacyKey,
      isNewSecret: false,
    };
  }

  return null;
}

const SUPABASE_AUTH = getSupabaseAuth();
const LOYVERSE_BASE_URL = "https://api.loyverse.com/v1.0";
const MAX_BATCH = 25;

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

async function supabaseRequest(
  path: string,
  init: RequestInit = {},
): Promise<any> {
  if (!SUPABASE_URL || !SUPABASE_AUTH) {
    throw new Error(
      "Faltan las credenciales internas de Supabase para la Edge Function.",
    );
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
      "Supabase respondió " + response.status + ": " + cleanError(body),
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

async function validateWebhookSecret(req: Request): Promise<boolean> {
  const supplied = req.headers.get("x-avohouse-loyverse-webhook-secret");
  if (!supplied) return false;

  try {
    const data = await supabaseRpc(
      "avohouse_validate_loyverse_webhook",
      { p_secret: supplied },
    );
    return data === true;
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
  await supabaseRequest(
    "/rest/v1/loyverse_customers?profile_id=eq." +
      encodeURIComponent(profileId),
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

async function syncCustomer(profileId: string) {
  const profiles = await supabaseRequest(
    "/rest/v1/profiles?select=id,full_name,username,email,phone&id=eq." +
      encodeURIComponent(profileId),
    { method: "GET" },
  );

  const profile = Array.isArray(profiles) ? profiles[0] : null;

  if (!profile) {
    throw new Error("No se encontró el perfil AvoHouse.");
  }

  const links = await supabaseRequest(
    "/rest/v1/loyverse_customers?select=profile_id,loyverse_customer_id,sync_status,attempts,last_attempt_at&profile_id=eq." +
      encodeURIComponent(profileId),
    { method: "GET" },
  );

  const link = Array.isArray(links) ? links[0] : null;

  if (!link) {
    throw new Error("No se encontró el registro de integración.");
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

    const avopuntosAccounts = await supabaseRequest(
      "/rest/v1/avopuntos_accounts?select=balance&profile_id=eq." +
        encodeURIComponent(profileId) +
        "&limit=1",
      { method: "GET" },
    );
    const avopuntosAccount = Array.isArray(avopuntosAccounts)
      ? avopuntosAccounts[0]
      : null;
    const avopuntosBalance = Number(avopuntosAccount?.balance ?? 0);

    if (
      !Number.isInteger(avopuntosBalance) ||
      avopuntosBalance < 0
    ) {
      throw new Error(
        "El saldo de AvoPuntos asociado al perfil no es válido.",
      );
    }

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
      const current = existingCustomer ?? await loyverseRequest(
        token,
        "/customers/" + encodeURIComponent(customerId),
        { method: "GET" },
      );

      const currentPoints = Number(current?.total_points ?? 0);
      if (!Number.isInteger(currentPoints) || currentPoints < 0) {
        throw new Error("El saldo actual de puntos de Loyverse no es válido.");
      }

      const expectedName = String(current?.name ?? fullName).trim() || fullName;
      const expectedEmail = email;
      const expectedPhone = phone;
      const expectedCustomerCode = username;

      const identityMatches =
        String(current?.name ?? "").trim() === expectedName &&
        String(current?.email ?? "").trim().toLowerCase() === expectedEmail &&
        String(current?.phone_number ?? "").trim() === expectedPhone &&
        String(current?.customer_code ?? "").trim() === expectedCustomerCode;

      if (currentPoints === avopuntosBalance && identityMatches) {
        return {
          profileId,
          synced: true,
          alreadyCurrent: true,
          loyverseCustomerId: customerId,
          balance: avopuntosBalance,
        };
      }

      customer = await loyverseRequest(token, "/customers", {
        method: "POST",
        body: JSON.stringify({
          id: customerId,
          name: expectedName,
          email: expectedEmail,
          phone_number: expectedPhone,
          address: current?.address ?? null,
          city: current?.city ?? null,
          region: current?.region ?? null,
          postal_code: current?.postal_code ?? null,
          country_code: current?.country_code ?? null,
          customer_code: expectedCustomerCode,
          note: current?.note ?? null,
          total_points: avopuntosBalance,
        }),
      });

      const verified = await loyverseRequest(
        token,
        "/customers/" + encodeURIComponent(customerId),
        { method: "GET" },
      );

      if (
        Number(verified?.total_points) !== avopuntosBalance ||
        String(verified?.name ?? "").trim() !== expectedName ||
        String(verified?.email ?? "").trim().toLowerCase() !== expectedEmail ||
        String(verified?.phone_number ?? "").trim() !== expectedPhone ||
        String(verified?.customer_code ?? "").trim() !== expectedCustomerCode
      ) {
        throw new Error(
          "La verificación posterior a la actualización del cliente en Loyverse detectó un cambio inesperado en los datos del cliente.",
        );
      }
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

    const syncedAt = new Date().toISOString();

    await saveState(profileId, {
      loyverse_customer_id: resultingId,
      sync_status: "synced",
      last_synced_at: syncedAt,
      last_error: null,
      next_attempt_at: null,
    });

    await supabaseRequest(
      "/rest/v1/avopuntos_accounts?profile_id=eq." +
        encodeURIComponent(profileId),
      {
        method: "PATCH",
        headers: { Prefer: "return=minimal" },
        body: JSON.stringify({
          last_loyverse_points: avopuntosBalance,
          last_loyverse_sync_at: syncedAt,
          last_loyverse_sync_attempt_at: syncedAt,
          last_loyverse_sync_error: null,
          updated_at: syncedAt,
        }),
      },
    );

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
    try {
      const now = new Date().toISOString();

      const pending = await supabaseRequest(
        "/rest/v1/loyverse_customers?select=profile_id&sync_status=in.(pending,error)&next_attempt_at=lte." +
          encodeURIComponent(now) +
          "&order=last_attempt_at.asc.nullsfirst&limit=" +
          MAX_BATCH,
        { method: "GET" },
      );

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
    } catch (error) {
      console.error(
        "[loyverse-sync-customer]",
        cleanError(error instanceof Error ? error.message : error),
      );
      return json(
        { error: cleanError(error instanceof Error ? error.message : error) },
        500,
      );
    }
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
