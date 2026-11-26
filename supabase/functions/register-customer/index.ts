import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8"
};

const GENERIC_ACCEPTED = {
  ok: true,
  next: "verify",
  message: "Si los datos permiten completar el registro, te enviaremos un correo de confirmación a la dirección indicada. Revisa también la carpeta de Spam o Correo no deseado."
};

function respond(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: CORS_HEADERS });
}

function text(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function isAdultInBogota(isoDate: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(isoDate)) return false;
  const parsed = new Date(`${isoDate}T00:00:00.000Z`);
  if (Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== isoDate) return false;

  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Bogota",
    year: "numeric",
    month: "2-digit",
    day: "2-digit"
  }).formatToParts(new Date());
  const today = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  const cutoffYear = Number(today.year) - 18;
  const cutoff = `${cutoffYear}-${today.month}-${today.day}`;
  return isoDate <= cutoff;
}

function isIdentityConflictMessage(message: string): boolean {
  return /already registered|user already exists|email.*already|profiles_document_number_key|registration_identity_conflict/i.test(message);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return respond({ ok: false, message: "Método no permitido." }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!supabaseUrl || !serviceRoleKey || !anonKey) {
    console.error("[register-customer] Falta configuración del servidor.");
    return respond({ ok: false, message: "No fue posible procesar el registro en este momento. Inténtalo nuevamente." }, 500);
  }

  let body: Record<string, unknown>;
  try {
    const parsed = await req.json();
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("invalid body");
    body = parsed as Record<string, unknown>;
  } catch {
    return respond({ ok: false, message: "No fue posible procesar la solicitud." }, 400);
  }

  const firstName = text(body.firstName).replace(/\s+/g, " ");
  const lastName = text(body.lastName).replace(/\s+/g, " ");
  const hasSeparatedName = Boolean(firstName && lastName);
  const fullName = hasSeparatedName
    ? `${firstName} ${lastName}`
    : text(body.fullName).replace(/\s+/g, " ");
  const username = text(body.username);
  const documentType = text(body.documentType);
  const documentNumber = text(body.documentNumber);
  const email = text(body.email).toLowerCase();
  const phone = text(body.phone);
  const whatsapp = text(body.whatsapp);
  const whatsappSame = body.whatsappSame === true;
  const birthDate = text(body.birthDate);
  const password = typeof body.password === "string" ? body.password : "";
  const marketingAuthorized = body.marketingAuthorized === true;
  const termsAccepted = body.termsAccepted === true;
  const emailRedirectTo = text(body.emailRedirectTo);

  if (Boolean(firstName) !== Boolean(lastName)) {
    return respond({ ok: false, message: "Indica los nombres y los apellidos." });
  }
  if (firstName.length > 100 || lastName.length > 100) {
    return respond({ ok: false, message: "Los nombres y apellidos no pueden superar 100 caracteres cada uno." });
  }

  const allowedDocumentTypes = new Set([
    "Cédula de ciudadanía",
    "Cédula de extranjería",
    "Pasaporte"
  ]);

  if (
    !fullName || !username || !documentType || !documentNumber || !email ||
    !phone || !birthDate || !password || !termsAccepted ||
    (!whatsappSame && !whatsapp)
  ) {
    return respond({ ok: false, message: "Completa los campos obligatorios y acepta los términos para continuar." });
  }
  if (!allowedDocumentTypes.has(documentType)) {
    return respond({ ok: false, message: "Selecciona un tipo de documento válido." });
  }
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return respond({ ok: false, message: "Ingresa un correo electrónico válido." });
  }
  if (!/^[A-Za-z0-9_]{3,20}$/.test(username)) {
    return respond({ ok: false, message: "El nickname debe tener entre 3 y 20 caracteres y usar solo letras, números o guion bajo." });
  }
  if (password.length < 8 || !/[A-ZÁÉÍÓÚÜÑ]/.test(password) || !/[a-záéíóúüñ]/.test(password) || !/\d/.test(password)) {
    return respond({ ok: false, message: "La contraseña debe tener mínimo 8 caracteres, una mayúscula, una minúscula y un número." });
  }
  if (!isAdultInBogota(birthDate)) {
    return respond({ ok: false, message: "Debes tener al menos 18 años y seleccionar una fecha de nacimiento válida." });
  }

  let redirectUrl: URL;
  try {
    redirectUrl = new URL(emailRedirectTo);
  } catch {
    return respond({ ok: false, message: "No fue posible procesar el registro. Recarga la página e inténtalo nuevamente." });
  }
  const allowedHosts = new Set(["avohousepub.com", "www.avohousepub.com", "efcanas.github.io"]);
  if (
    redirectUrl.protocol !== "https:" ||
    !allowedHosts.has(redirectUrl.hostname.toLowerCase()) ||
    !redirectUrl.pathname.endsWith("/index.html")
  ) {
    return respond({ ok: false, message: "No fue posible procesar el registro. Recarga la página e inténtalo nuevamente." });
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false }
  });

  try {
    const { data: conflict, error: checkError } = await admin.rpc(
      "ahtv_registration_identity_conflict",
      { p_email: email, p_document_number: documentNumber }
    );

    if (checkError) {
      console.error("[register-customer] Falló la comprobación privada de identidad:", checkError.code ?? "sin código");
      return respond({ ok: false, message: "No fue posible procesar el registro en este momento. Inténtalo nuevamente." }, 500);
    }

    // La respuesta pública es idéntica tanto si se encuentra el correo como el documento.
    // En ese caso no se llama a Auth: no se crea un usuario ni se envía correo.
    if (conflict === true) return respond(GENERIC_ACCEPTED);

    const publicClient = createClient(supabaseUrl, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false }
    });

    const { data, error } = await publicClient.auth.signUp({
      email,
      password,
      options: {
        emailRedirectTo: redirectUrl.href,
        data: {
          full_name: fullName,
          first_name: hasSeparatedName ? firstName : null,
          last_name: hasSeparatedName ? lastName : null,
          username,
          document_type: documentType,
          document_number: documentNumber,
          phone,
          whatsapp: whatsappSame ? phone : whatsapp,
          whatsapp_same: whatsappSame,
          birth_date: birthDate,
          terms_accepted: true,
          data_authorized: true,
          marketing_authorized: marketingAuthorized,
          terms_version: "1.0",
          privacy_version: "1.0",
          data_authorization_version: "1.0"
        }
      }
    });

    if (error) {
      if (isIdentityConflictMessage(error.message || "")) return respond(GENERIC_ACCEPTED);
      const message = /nickname.*(uso|disponible|reservado)|reserved/i.test(error.message || "")
        ? "Ese nickname no está disponible. Elige otro."
        : "No fue posible completar el registro. Revisa los datos e inténtalo nuevamente.";
      return respond({ ok: false, message });
    }

    // Supabase puede devolver una respuesta deliberadamente genérica para un correo existente.
    if (data.user && Array.isArray(data.user.identities) && data.user.identities.length === 0) {
      return respond(GENERIC_ACCEPTED);
    }

    // La respuesta no revela si se creó una cuenta ni entrega una sesión distinta según el caso.
    return respond(GENERIC_ACCEPTED);
  } catch (error) {
    console.error("[register-customer] Error inesperado:", error instanceof Error ? error.name : "unknown");
    return respond({ ok: false, message: "No fue posible procesar el registro en este momento. Inténtalo nuevamente." }, 500);
  }
});
