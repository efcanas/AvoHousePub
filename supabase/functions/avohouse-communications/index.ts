
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const PUBLIC_KEY =
  Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ??
  "sb_publishable_Clp6KIiLE-gKHGu3Lp8E2A_DxYhFBdT";

function getSecretKey(): string {
  const raw = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (raw) {
    try {
      const parsed = JSON.parse(raw);
      const key = typeof parsed?.default === "string" ? parsed.default.trim() : "";
      if (key) return key;
    } catch {}
  }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() ?? "";
}

const SERVICE_KEY = getSecretKey();
let RESEND_API_KEY = Deno.env.get("RESEND_API_KEY")?.trim() ?? "";
const FROM_EMAIL = "AvoHouse <noreply@avohousepub.com>";

// Only aliases explicitly approved for public marketing campaigns belong here.
// No current transactional or account-notification template is campaign-enabled.
const MASS_CAMPAIGN_TEMPLATE_ALIASES = new Set<string>([]);

const ALLOWED_ORIGINS = new Set([
  "https://avohousepub.com",
  "https://www.avohousepub.com",
  "https://efcanas.github.io",
]);

function headers(origin: string | null): HeadersInit {
  const allow = origin && ALLOWED_ORIGINS.has(origin) ? origin : "*";
  return {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

function json(data: unknown, status = 200, origin: string | null = null) {
  return new Response(JSON.stringify(data), { status, headers: headers(origin) });
}

function cleanError(value: unknown): string {
  const message =
    value instanceof Error
      ? value.message
      : typeof value === "string"
        ? value
        : JSON.stringify(value);
  return message.slice(0, 2000);
}

async function requireAdmin(req: Request) {
  if (!SUPABASE_URL || !SERVICE_KEY) throw new Error("Faltan las credenciales internas de Supabase.");

  const authHeader = req.headers.get("authorization") ?? "";
  const match = authHeader.match(/^Bearer\s+(.+)$/i);
  if (!match) {
    return { error: "No autorizado.", status: 401 };
  }

  const jwt = match[1].trim();
  const userClient = createClient(SUPABASE_URL, PUBLIC_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: "Bearer " + jwt } },
  });

  const { data: userData, error: userError } = await userClient.auth.getUser(jwt);
  if (userError || !userData?.user) {
    return { error: "Sesión no válida.", status: 401 };
  }

  const { data: isAdmin, error: adminError } = await userClient.rpc("avopuntos_admin_is_admin");
  if (adminError || isAdmin !== true) {
    return { error: "No autorizado.", status: 403 };
  }

  const serviceClient = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  return {
    userClient,
    serviceClient,
    user: userData.user,
    jwt,
  };
}

async function loadResendApiKey(serviceClient: any) {
  const { data, error } = await serviceClient.rpc("avohouse_get_resend_api_key");
  if (error) throw new Error("No se pudo cargar RESEND_API_KEY desde Supabase Vault: " + error.message);
  const key = String(data ?? "").trim();
  if (!key) throw new Error("RESEND_API_KEY no está configurada en Supabase Vault.");
  RESEND_API_KEY = key;
}

async function resendRequest(path: string, init: RequestInit = {}) {
  if (!RESEND_API_KEY) throw new Error("Falta configurar RESEND_API_KEY en Supabase.");

  const requestHeaders = new Headers(init.headers);
  requestHeaders.set("Authorization", "Bearer " + RESEND_API_KEY);
  requestHeaders.set("Content-Type", "application/json");

  const response = await fetch("https://api.resend.com" + path, {
    ...init,
    headers: requestHeaders,
  });

  const bodyText = await response.text();
  let body: any = null;
  try {
    body = bodyText ? JSON.parse(bodyText) : null;
  } catch {
    body = bodyText;
  }

  if (!response.ok) {
    throw new Error("Resend respondió " + response.status + ": " + cleanError(body));
  }
  return body;
}

function normalizeTemplateVariables(value: unknown): Record<string, string | number> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const result: Record<string, string | number> = {};
  for (const [key, raw] of Object.entries(value as Record<string, unknown>)) {
    if (typeof raw === "number" && Number.isFinite(raw)) result[key] = raw;
    else if (typeof raw === "string") result[key] = raw;
  }
  return result;
}

function fallbackVariables(template: any, custom: Record<string, string | number>) {
  const result: Record<string, string | number> = { ...custom };
  const vars = Array.isArray(template?.variables) ? template.variables : [];
  for (const item of vars) {
    const key = String(item?.key ?? "").trim();
    if (!key || result[key] !== undefined) continue;
    if (item?.fallbackValue !== undefined && item?.fallbackValue !== null) {
      result[key] = item.fallbackValue;
    } else if (key === "CUSTOMER_NAME") {
      result[key] = "Cliente AvoHouse";
    } else {
      result[key] = "";
    }
  }
  return result;
}

function massEligible(template: any): { ok: boolean; reason?: string } {
  const alias = String(template?.alias ?? "").trim();
  if (!MASS_CAMPAIGN_TEMPLATE_ALIASES.has(alias)) {
    return {
      ok: false,
      reason: "Esta plantilla no está habilitada explícitamente para campañas publicitarias.",
    };
  }

  const vars = Array.isArray(template?.variables) ? template.variables : [];
  const unsupported = vars
    .map((v: any) => String(v?.key ?? "").trim())
    .filter(Boolean)
    .filter((key: string) => key !== "CUSTOMER_NAME");
  if (unsupported.length) {
    return {
      ok: false,
      reason:
        "La plantilla requiere variables específicas de una transacción y no puede enviarse automáticamente a toda la base. Variables: " +
        unsupported.join(", ") +
        ".",
    };
  }
  return { ok: true };
}

async function listMarketingRecipients(userClient: any) {
  const { data, error } = await userClient.rpc("avohouse_admin_list_marketing_recipients");
  if (error) throw new Error("No se pudieron obtener los destinatarios autorizados: " + error.message);
  return Array.isArray(data) ? data : [];
}

async function handleAction(ctx: any, body: any) {
  const action = String(body?.action ?? "").trim();

  if (action === "list") {
    const listing = await resendRequest("/templates?limit=100");
    const rows = Array.isArray(listing?.data) ? listing.data : [];
    const enriched = await Promise.all(
      rows.map(async (row: any) => {
        try {
          const detail = await resendRequest("/templates/" + encodeURIComponent(String(row?.id ?? "")));
          return {
            ...row,
            variables: Array.isArray(detail?.variables) ? detail.variables : [],
            subject: detail?.subject ?? row?.subject ?? "",
            from: detail?.from ?? row?.from ?? "",
          };
        } catch {
          return row;
        }
      }),
    );
    return { templates: { ...listing, data: enriched } };
  }

  if (action === "get") {
    const id = String(body?.id ?? "").trim();
    if (!id) throw new Error("Falta el ID de la plantilla.");
    return { template: await resendRequest("/templates/" + encodeURIComponent(id)) };
  }

  if (action === "create") {
    const payload: Record<string, unknown> = {
      name: String(body?.name ?? "").trim(),
      alias: String(body?.alias ?? "").trim(),
      subject: String(body?.subject ?? "").trim(),
      from: String(body?.from ?? FROM_EMAIL).trim() || FROM_EMAIL,
      html: String(body?.html ?? ""),
      text: String(body?.text ?? ""),
    };
    const variables = Array.isArray(body?.variables) ? body.variables : [];
    if (variables.length) payload.variables = variables;

    if (!payload.name || !payload.subject || !payload.html) {
      throw new Error("Nombre, asunto y HTML son obligatorios para crear una plantilla.");
    }

    return { template: await resendRequest("/templates", {
      method: "POST",
      body: JSON.stringify(payload),
    }) };
  }

  if (action === "update") {
    const id = String(body?.id ?? "").trim();
    if (!id) throw new Error("Falta el ID de la plantilla.");

    const payload: Record<string, unknown> = {};
    for (const key of ["name", "alias", "subject", "from", "reply_to", "html", "text", "variables"]) {
      if (body?.[key] !== undefined) payload[key] = body[key];
    }
    if (payload.from === "") payload.from = FROM_EMAIL;

    return { template: await resendRequest("/templates/" + encodeURIComponent(id), {
      method: "PATCH",
      body: JSON.stringify(payload),
    }) };
  }

  if (action === "publish") {
    const id = String(body?.id ?? "").trim();
    if (!id) throw new Error("Falta el ID de la plantilla.");
    return { template: await resendRequest("/templates/" + encodeURIComponent(id) + "/publish", {
      method: "POST",
      body: JSON.stringify({}),
    }) };
  }

  if (action === "send_test") {
    const id = String(body?.id ?? "").trim();
    if (!id) throw new Error("Falta el ID de la plantilla.");

    const template = await resendRequest("/templates/" + encodeURIComponent(id));
    const to = String(body?.to ?? ctx.user.email ?? "").trim().toLowerCase();
    if (!to) throw new Error("No hay un correo destinatario para la prueba.");

    const variables = fallbackVariables(
      template,
      normalizeTemplateVariables(body?.variables),
    );

    const result = await resendRequest("/emails", {
      method: "POST",
      headers: {
        "Idempotency-Key": "avohouse-communications-test-" + crypto.randomUUID(),
      },
      body: JSON.stringify({
        from: template?.from || FROM_EMAIL,
        to: [to],
        template: { id, variables },
      }),
    });

    return { sent: true, to, result };
  }

  if (action === "send_all") {
    if (body?.confirm !== true) {
      throw new Error("Confirma explícitamente el envío masivo.");
    }

    const id = String(body?.id ?? "").trim();
    if (!id) throw new Error("Falta el ID de la plantilla.");

    const template = await resendRequest("/templates/" + encodeURIComponent(id));
    if (String(template?.status ?? "").toLowerCase() !== "published") {
      throw new Error("La plantilla debe estar publicada antes del envío masivo.");
    }

    const eligibility = massEligible(template);
    if (!eligibility.ok) throw new Error(eligibility.reason);

    const recipients = await listMarketingRecipients(ctx.userClient);
    if (!recipients.length) {
      return { sent: 0, failed: 0, recipients: 0, message: "No hay clientes confirmados con autorización publicitaria vigente." };
    }

    const communicationInsert = await ctx.serviceClient
      .from("avohouse_communications")
      .insert({
        created_by: ctx.user.id,
        template_id: id,
        template_name: String(template?.name ?? ""),
        subject: String(template?.subject ?? ""),
        recipient_scope: "marketing_authorized",
        recipient_count: recipients.length,
        sent_count: 0,
        failed_count: 0,
        status: "sending",
        details: {
          channel: "email",
          source: "Comunicaciones",
        },
      })
      .select("id")
      .single();

    if (communicationInsert.error) {
      throw new Error("No se pudo registrar la comunicación: " + communicationInsert.error.message);
    }

    const communicationId = communicationInsert.data.id;
    let sent = 0;
    let failed = 0;
    const batchSize = 100;

    for (let start = 0; start < recipients.length; start += batchSize) {
      const slice = recipients.slice(start, start + batchSize);
      const emails = slice.map((recipient: any) => ({
        from: template?.from || FROM_EMAIL,
        to: [recipient.email],
        template: {
          id,
          variables: {
            CUSTOMER_NAME:
              String(recipient.full_name ?? "").trim() ||
              String(recipient.username ?? "").trim() ||
              "Cliente AvoHouse",
          },
        },
        tags: [
          { name: "communication_id", value: String(communicationId) },
          { name: "communication_type", value: "mass" },
        ],
      }));

      try {
        const batchResult = await resendRequest("/emails/batch", {
          method: "POST",
          headers: {
            "Idempotency-Key":
              "avohouse-communications-" +
              String(communicationId) +
              "-batch-" +
              String(Math.floor(start / batchSize)),
          },
          body: JSON.stringify(emails),
        });

        const count = Array.isArray(batchResult?.data)
          ? batchResult.data.length
          : slice.length;
        sent += count;
        failed += Math.max(0, slice.length - count);
      } catch (error) {
        failed += slice.length;
        console.error("[avohouse-communications] batch error", cleanError(error));
      }

      await ctx.serviceClient
        .from("avohouse_communications")
        .update({ sent_count: sent, failed_count: failed })
        .eq("id", communicationId);
    }

    const status = failed === 0 ? "sent" : sent > 0 ? "partial_error" : "error";
    await ctx.serviceClient
      .from("avohouse_communications")
      .update({
        sent_count: sent,
        failed_count: failed,
        status,
        details: {
          channel: "email",
          source: "Comunicaciones",
          completed_at: new Date().toISOString(),
        },
      })
      .eq("id", communicationId);

    return {
      communication_id: communicationId,
      sent,
      failed,
      recipients: recipients.length,
      status,
    };
  }


  if (action === "email_detail") {
    const archiveId = String(body?.archive_id ?? "").trim();
    if (!archiveId) throw new Error("Falta el ID del registro de correo.");

    const { data: archive, error: archiveError } = await ctx.serviceClient
      .from("avohouse_email_archive")
      .select("id,profile_id,event_type,recipient_email,subject,from_email,template_id,resend_email_id,message_id,sent_at,status,html_content,text_content,variables,related_receipt_number,metadata")
      .eq("id", archiveId)
      .single();

    if (archiveError || !archive) {
      throw new Error("No se encontró el correo archivado.");
    }

    if (archive.html_content || archive.text_content || !archive.resend_email_id) {
      return { email: archive, source: archive.html_content ? "archive" : "metadata" };
    }

    const detail = await resendRequest(
      "/emails/" + encodeURIComponent(String(archive.resend_email_id)),
    );

    const html = typeof detail?.html === "string" ? detail.html : null;
    const textContent = typeof detail?.text === "string" ? detail.text : null;
    const subject = typeof detail?.subject === "string" ? detail.subject : archive.subject;
    const fromEmail = typeof detail?.from === "string" ? detail.from : archive.from_email;
    const messageId = typeof detail?.message_id === "string" ? detail.message_id : archive.message_id;
    const sentAt = detail?.created_at ?? archive.sent_at;

    const patch = {
      subject,
      from_email: fromEmail,
      message_id: messageId,
      sent_at: sentAt,
      html_content: html,
      text_content: textContent,
      archived_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    };

    const { error: updateError } = await ctx.serviceClient
      .from("avohouse_email_archive")
      .update(patch)
      .eq("id", archiveId);

    if (updateError) {
      throw new Error("No se pudo guardar la copia del correo: " + updateError.message);
    }

    return {
      email: {
        ...archive,
        ...patch,
      },
      source: "resend",
    };
  }

  if (action === "count_recipients") {
    const recipients = await listMarketingRecipients(ctx.userClient);
    return { count: recipients.length };
  }

  if (action === "history") {
    const { data, error } = await ctx.userClient.rpc("avohouse_admin_get_communications");
    if (error) throw new Error("No se pudo cargar el historial: " + error.message);
    return { history: Array.isArray(data) ? data : [] };
  }

  throw new Error("Acción no reconocida.");
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: headers(origin) });
  }

  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405, origin);
  }

  try {
    const ctx = await requireAdmin(req);
    if ("error" in ctx) return json({ error: ctx.error }, ctx.status, origin);

    await loadResendApiKey(ctx.serviceClient);

    let body: any = {};
    try {
      body = await req.json();
    } catch {
      return json({ error: "JSON inválido." }, 400, origin);
    }

    return json(await handleAction(ctx, body), 200, origin);
  } catch (error) {
    console.error("[avohouse-communications]", cleanError(error));
    return json({ error: cleanError(error) }, 500, origin);
  }
});
