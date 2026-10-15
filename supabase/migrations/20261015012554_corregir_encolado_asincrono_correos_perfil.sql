-- Evita agotar statement_timeout esperando la respuesta de Resend dentro de la misma
-- transacción de una verificación o actualización del perfil.
CREATE OR REPLACE FUNCTION public.avohouse_queue_profile_email(
  p_event_key text,
  p_profile_id uuid,
  p_event_type text,
  p_channel text,
  p_template_id text,
  p_variables jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'vault', 'net'
AS $function$
DECLARE
  v_profile public.profiles%rowtype;
  v_api_key text;
  v_request_id bigint;
BEGIN
  IF nullif(trim(coalesce(p_event_key,'')), '') IS NULL
     OR p_profile_id IS NULL
     OR nullif(trim(coalesce(p_template_id,'')), '') IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_profile
  FROM public.profiles
  WHERE id = p_profile_id;

  IF NOT FOUND OR nullif(trim(coalesce(v_profile.email,'')), '') IS NULL THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.avohouse_email_events (
    event_key, profile_id, event_type, channel, status,
    recipient_email, template_id, variables
  )
  VALUES (
    p_event_key,
    p_profile_id,
    coalesce(nullif(trim(p_event_type), ''), 'transactional'),
    nullif(trim(p_channel), ''),
    'queued',
    v_profile.email,
    p_template_id,
    coalesce(p_variables, '{}'::jsonb)
  )
  ON CONFLICT (event_key) DO NOTHING;

  IF NOT FOUND THEN
    RETURN (
      SELECT e.request_id
      FROM public.avohouse_email_events e
      WHERE e.event_key = p_event_key
      LIMIT 1
    );
  END IF;

  SELECT decrypted_secret INTO v_api_key
  FROM vault.decrypted_secrets
  WHERE name = 'RESEND_API_KEY'
  LIMIT 1;

  IF nullif(trim(coalesce(v_api_key,'')), '') IS NULL THEN
    UPDATE public.avohouse_email_events
    SET status = 'error',
        error_message = 'Falta configurar RESEND_API_KEY.',
        updated_at = now()
    WHERE event_key = p_event_key;
    RETURN NULL;
  END IF;

  BEGIN
    SELECT net.http_post(
      url := 'https://api.resend.com/emails',
      body := jsonb_build_object(
        'from', 'AvoHouse <noreply@avohousepub.com>',
        'to', jsonb_build_array(v_profile.email),
        'template', jsonb_build_object(
          'id', p_template_id,
          'variables', coalesce(p_variables, '{}'::jsonb)
        )
      ),
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || v_api_key,
        'Content-Type', 'application/json',
        'Idempotency-Key', p_event_key
      ),
      timeout_milliseconds := 10000
    )
    INTO v_request_id;

    IF v_request_id IS NULL THEN
      RAISE EXCEPTION 'pg_net no devolvió un identificador de solicitud.';
    END IF;

    UPDATE public.avohouse_email_events
    SET status = 'queued',
        request_id = v_request_id,
        error_message = NULL,
        updated_at = now()
    WHERE event_key = p_event_key;

    RETURN v_request_id;
  EXCEPTION
    WHEN OTHERS THEN
      UPDATE public.avohouse_email_events
      SET status = 'error',
          request_id = v_request_id,
          error_message = left(sqlerrm, 1000),
          updated_at = now()
      WHERE event_key = p_event_key;
      RETURN NULL;
  END;
END;
$function$;

-- Procesa las respuestas de pg_net cuando la transacción que encoló el correo ya cerró.
CREATE OR REPLACE FUNCTION public.avohouse_process_profile_email_events()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'net'
AS $function$
DECLARE
  r record;
  v_response net.http_response_result;
  v_status_code integer;
  v_body_text text;
  v_body jsonb;
  v_resend_email_id text;
  v_processed integer := 0;
BEGIN
  FOR r IN
    SELECT e.event_key, e.request_id
    FROM public.avohouse_email_events e
    JOIN net._http_response h ON h.id = e.request_id
    WHERE e.status = 'queued'
      AND e.request_id IS NOT NULL
    ORDER BY e.created_at
    LIMIT 100
    FOR UPDATE OF e SKIP LOCKED
  LOOP
    v_response := net.http_collect_response(r.request_id, true);
    v_status_code := (v_response.response).status_code;
    v_body_text := (v_response.response).body;

    BEGIN
      v_body := nullif(v_body_text, '')::jsonb;
    EXCEPTION WHEN OTHERS THEN
      v_body := NULL;
    END;

    v_resend_email_id := nullif(trim(coalesce(v_body->>'id','')), '');

    IF v_status_code BETWEEN 200 AND 299 AND v_resend_email_id IS NOT NULL THEN
      UPDATE public.avohouse_email_events
      SET status = 'sent',
          resend_email_id = v_resend_email_id,
          error_message = NULL,
          updated_at = now()
      WHERE event_key = r.event_key;
    ELSE
      UPDATE public.avohouse_email_events
      SET status = 'error',
          error_message = left(
            coalesce(
              v_response.message,
              nullif(v_body_text, ''),
              CASE
                WHEN v_status_code IS NULL THEN 'No se pudo obtener una respuesta válida de Resend.'
                ELSE 'Resend respondió con HTTP ' || v_status_code::text || '.'
              END
            ),
            1000
          ),
          updated_at = now()
      WHERE event_key = r.event_key;
    END IF;

    v_processed := v_processed + 1;
  END LOOP;

  RETURN v_processed;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.avohouse_process_profile_email_events() FROM PUBLIC, anon, authenticated;

DO $schedule$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'avohouse_profile_email_status_sync'
  ) THEN
    PERFORM cron.schedule(
      'avohouse_profile_email_status_sync',
      '* * * * *',
      'SELECT public.avohouse_process_profile_email_events();'
    );
  END IF;
END;
$schedule$;
