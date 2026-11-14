import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import webPush from "npm:web-push@4.0.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ?? "";

const ORIGINS = new Set([
  "https://avohousepub.com",
  "https://www.avohousepub.com",
  "https://efcanas.github.io"
]);

const DEFAULT_ADMIN_URL = "/ahtv/admin/index.html";

function headersFor(req: Request) {
  const origin = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ORIGINS.has(origin) ? origin : "https://avohousepub.com",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-ah-push-secret",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store"
  };
}

function respond(req: Request, data: unknown, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: headersFor(req) });
}

function cleanString(value: unknown, max = 500): string {
  return typeof value === "string" ? value.trim().slice(0, max) : "";
}

function decodeVapidKey(value: string): Uint8Array {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - normalized.length % 4) % 4);
  const binary = atob(padded);
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}

const service = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false }
});

const publicClient = createClient(SUPABASE_URL, ANON_KEY, {
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false }
});

async function loadConfig() {
  const { data, error } = await service.rpc("get_ah_push_config");
  if (error || !data) throw new Error("No fue posible cargar la configuración privada de notificaciones.");
  return data as Record<string, string>;
}

async function authorizeAdmin(req: Request) {
  const authorization = req.headers.get("authorization") ?? "";
  const token = authorization.replace(/^Bearer\s+/i, "").trim();
  if (!token) return null;

  const { data: authData, error: authError } = await publicClient.auth.getUser(token);
  const user = authData?.user;
  if (authError || !user) return null;

  const { data: admin, error: adminError } = await service
    .from("admin_users")
    .select("user_id")
    .eq("user_id", user.id)
    .maybeSingle();

  if (adminError || !admin) return null;
  return user;
}

function parseSubscription(value: unknown) {
  if (!value || typeof value !== "object") return null;
  const item = value as Record<string, unknown>;
  const keys = item.keys && typeof item.keys === "object"
    ? item.keys as Record<string, unknown>
    : {};
  const endpoint = cleanString(item.endpoint, 2048);
  const p256dh = cleanString(keys.p256dh, 256);
  const auth = cleanString(keys.auth, 128);

  try {
    if (new URL(endpoint).protocol !== "https:") return null;
  } catch {
    return null;
  }
  if (!p256dh || !auth) return null;
  return { endpoint, p256dh, auth };
}

async function sendOne(subscription: Record<string, unknown>, config: Record<string, string>, payload: Record<string, unknown>) {
  const stored = {
    endpoint: String(subscription.endpoint),
    keys: {
      p256dh: String(subscription.p256dh),
      auth: String(subscription.auth)
    }
  };

  webPush.setVapidDetails(
    config.ah_push_vapid_subject,
    config.ah_push_vapid_public_key,
    config.ah_push_vapid_private_key
  );

  return await webPush.sendNotification(
    stored,
    JSON.stringify(payload),
    { TTL: 86400, urgency: "high" }
  );
}

async function sendToAll(payload: Record<string, unknown>, config: Record<string, string>) {
  const { data: subscriptions, error } = await service
    .from("ah_admin_push_subscriptions")
    .select("id,endpoint,p256dh,auth");

  if (error) throw new Error("No fue posible consultar los dispositivos autorizados.");

  const items = subscriptions ?? [];
  const results = await Promise.allSettled(items.map((item) => sendOne(item, config, payload)));
  const expiredIds: string[] = [];
  let sent = 0;
  let failed = 0;

  results.forEach((result, index) => {
    if (result.status === "fulfilled") {
      sent += 1;
      return;
    }
    failed += 1;
    const statusCode = Number((result.reason as { statusCode?: number })?.statusCode);
    if (statusCode === 404 || statusCode === 410) expiredIds.push(String(items[index].id));
    console.error("[admin-push] Falló la entrega a un dispositivo:", statusCode || "sin código");
  });

  if (expiredIds.length) {
    await service.from("ah_admin_push_subscriptions").delete().in("id", expiredIds);
  }

  return { devices: items.length, sent, failed, removedExpired: expiredIds.length };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: headersFor(req) });
  if (req.method !== "POST") return respond(req, { ok: false, message: "Método no permitido." }, 405);

  if (!SUPABASE_URL || !SERVICE_ROLE_KEY || !ANON_KEY) {
    console.error("[admin-push] Falta configuración del entorno Supabase.");
    return respond(req, { ok: false, message: "Servicio de notificaciones no disponible." }, 500);
  }

  let body: Record<string, unknown>;
  try {
    const parsed = await req.json();
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("invalid body");
    body = parsed as Record<string, unknown>;
  } catch {
    return respond(req, { ok: false, message: "Solicitud no válida." }, 400);
  }

  const action = cleanString(body.action, 40);

  if (action === "dispatch") {
    let config: Record<string, string>;
    try {
      config = await loadConfig();
    } catch (error) {
      console.error("[admin-push] No se pudo cargar configuración privada.");
      return respond(req, { ok: false }, 500);
    }

    const suppliedSecret = req.headers.get("x-ah-push-secret") ?? "";
    if (!config.ah_push_webhook_secret || suppliedSecret !== config.ah_push_webhook_secret) {
      return respond(req, { ok: false }, 401);
    }

    const allowedTypes = new Set(["new_registration", "new_song_suggestion", "manual_song_request"]);
    const eventType = cleanString(body.event_type, 48);
    if (!allowedTypes.has(eventType)) return respond(req, { ok: false }, 400);

    const title = cleanString(body.title, 100);
    const message = cleanString(body.body, 260);
    let target = cleanString(body.url, 300);
    if (!target.startsWith("/") || target.startsWith("//")) target = DEFAULT_ADMIN_URL;

    if (!title || !message) return respond(req, { ok: false }, 400);

    const payload = {
      title,
      body: message,
      icon: "/LogoPrincipal.png",
      badge: "/LogoPrincipal.png",
      url: target,
      tag: cleanString(body.tag, 80) || "ah-admin-event",
      eventType,
      requireInteraction: true,
      renotify: false
    };

    try {
      const result = await sendToAll(payload, config);
      return respond(req, { ok: true, ...result });
    } catch (error) {
      console.error("[admin-push] No fue posible despachar el evento.");
      return respond(req, { ok: false, message: "No fue posible enviar la notificación." }, 500);
    }
  }

  const user = await authorizeAdmin(req);
  if (!user) return respond(req, { ok: false, message: "Acceso exclusivo para administradores." }, 401);

  if (action === "get_public_key") {
    try {
      const config = await loadConfig();
      if (!config.ah_push_vapid_public_key) throw new Error("missing public key");
      return respond(req, { ok: true, publicKey: config.ah_push_vapid_public_key });
    } catch {
      return respond(req, { ok: false, message: "No se pudo cargar la clave pública." }, 500);
    }
  }

  if (action === "status") {
    const endpoint = cleanString(body.endpoint, 2048);
    let query = service
      .from("ah_admin_push_subscriptions")
      .select("id,device_label,created_at,last_seen_at", { count: "exact" })
      .eq("user_id", user.id);

    if (endpoint) query = query.eq("endpoint", endpoint);
    const { data, count, error } = await query;
    if (error) return respond(req, { ok: false, message: "No se pudo consultar el estado de notificaciones." }, 500);
    return respond(req, {
      ok: true,
      enabled: Boolean(endpoint && data?.length),
      devices: count ?? data?.length ?? 0,
      device: data?.[0] ?? null
    });
  }

  if (action === "subscribe") {
    const subscription = parseSubscription(body.subscription);
    if (!subscription) return respond(req, { ok: false, message: "La suscripción del navegador no es válida." }, 400);

    const deviceLabel = cleanString(body.deviceLabel, 80) || "Dispositivo";
    const userAgent = cleanString(req.headers.get("user-agent"), 512);

    const { error } = await service
      .from("ah_admin_push_subscriptions")
      .upsert({
        user_id: user.id,
        endpoint: subscription.endpoint,
        p256dh: subscription.p256dh,
        auth: subscription.auth,
        device_label: deviceLabel,
        user_agent: userAgent,
        updated_at: new Date().toISOString(),
        last_seen_at: new Date().toISOString()
      }, { onConflict: "endpoint" });

    if (error) {
      console.error("[admin-push] No se pudo guardar una suscripción.");
      return respond(req, { ok: false, message: "No fue posible activar las notificaciones en este dispositivo." }, 500);
    }
    return respond(req, { ok: true, message: "Notificaciones activadas en este dispositivo." });
  }

  if (action === "unsubscribe") {
    const endpoint = cleanString(body.endpoint, 2048);
    if (!endpoint) return respond(req, { ok: false }, 400);

    const { error } = await service
      .from("ah_admin_push_subscriptions")
      .delete()
      .eq("user_id", user.id)
      .eq("endpoint", endpoint);

    if (error) return respond(req, { ok: false, message: "No fue posible desactivar las notificaciones." }, 500);
    return respond(req, { ok: true, message: "Notificaciones desactivadas en este dispositivo." });
  }

  if (action === "test") {
    const endpoint = cleanString(body.endpoint, 2048);
    if (!endpoint) return respond(req, { ok: false }, 400);

    const { data: subscription, error } = await service
      .from("ah_admin_push_subscriptions")
      .select("id,endpoint,p256dh,auth")
      .eq("user_id", user.id)
      .eq("endpoint", endpoint)
      .maybeSingle();

    if (error || !subscription) return respond(req, { ok: false, message: "Este dispositivo no tiene una suscripción activa." }, 404);

    try {
      const config = await loadConfig();
      await sendOne(subscription, config, {
        title: "Notificación de AHP",
        body: "Este dispositivo está listo para recibir avisos administrativos.",
        icon: "/LogoPrincipal.png",
        badge: "/LogoPrincipal.png",
        url: DEFAULT_ADMIN_URL,
        tag: "ah-push-test",
        requireInteraction: true
      });
      return respond(req, { ok: true, message: "Notificación de prueba enviada." });
    } catch (error) {
      console.error("[admin-push] Falló la notificación de prueba.");
      return respond(req, { ok: false, message: "No se pudo enviar la notificación de prueba." }, 502);
    }
  }

  return respond(req, { ok: false, message: "Acción no reconocida." }, 400);
});
