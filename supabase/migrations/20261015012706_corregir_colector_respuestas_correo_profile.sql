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
    -- The public wrapper in this pg_net version mishandles its result.
    -- Use the internal collector only after confirming that its response exists.
    v_response := net._http_collect_response(r.request_id, true);
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
