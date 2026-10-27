CREATE OR REPLACE FUNCTION public.avopuntos_process_expired_customer_benefit_emails()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  r record;
  v_today date := (now() AT TIME ZONE 'America/Bogota')::date;
  v_customer_name text;
  v_customer_name_html text;
  v_reason_html text;
  v_multiplier_text text;
  v_email_request_id bigint;
  v_processed integer := 0;
  v_criterion_note constant text :=
    'Desde el día siguiente al fin de este beneficio se aplica el primer criterio disponible en este orden: otro beneficio individual vigente, multiplicación Piloto ×2 (si sigue vigente), una promoción general activa y, por último, la tasa base de AvoPuntos. Los criterios no se suman ni multiplican entre sí.';
BEGIN
  -- If an overlapping individual rule was not the effective rule on its own
  -- end date, suppress its expiration email. This avoids duplicate messages
  -- for multiple active rows that expired together without affecting accrual.
  UPDATE public.avopuntos_customer_rules cr
  SET end_email_attempted_at = now(),
      updated_at = now()
  WHERE cr.active = true
    AND cr.end_date IS NOT NULL
    AND cr.end_date < v_today
    AND cr.end_email_attempted_at IS NULL
    AND cr.id <> (
      SELECT winner.id
      FROM public.avopuntos_customer_rules winner
      WHERE winner.profile_id = cr.profile_id
        AND winner.active = true
        AND winner.start_date <= cr.end_date
        AND (winner.end_date IS NULL OR winner.end_date >= cr.end_date)
      ORDER BY winner.start_date DESC, winner.created_at DESC, winner.id DESC
      LIMIT 1
    );

  FOR r IN
    SELECT
      cr.id,
      cr.profile_id,
      cr.multiplier,
      cr.start_date,
      cr.end_date,
      cr.reason,
      p.full_name
    FROM public.avopuntos_customer_rules cr
    JOIN public.profiles p ON p.id = cr.profile_id
    WHERE cr.active = true
      AND cr.end_date IS NOT NULL
      AND cr.end_date < v_today
      AND cr.end_email_attempted_at IS NULL
      AND cr.id = (
        SELECT winner.id
        FROM public.avopuntos_customer_rules winner
        WHERE winner.profile_id = cr.profile_id
          AND winner.active = true
          AND winner.start_date <= cr.end_date
          AND (winner.end_date IS NULL OR winner.end_date >= cr.end_date)
        ORDER BY winner.start_date DESC, winner.created_at DESC, winner.id DESC
        LIMIT 1
      )
    ORDER BY cr.end_date, cr.created_at
    FOR UPDATE OF cr SKIP LOCKED
  LOOP
    v_email_request_id := NULL;
    BEGIN
      v_customer_name := COALESCE(NULLIF(trim(r.full_name), ''), 'Cliente AvoHouse');
      v_customer_name_html := replace(replace(replace(v_customer_name, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
      v_reason_html := replace(replace(replace(COALESCE(r.reason, 'Beneficio individual de AvoPuntos'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
      v_multiplier_text := replace(
        trim(trailing '.' from trim(trailing '0' from to_char(r.multiplier, 'FM999999990.99'))),
        '.', ','
      );

      v_email_request_id := public.avohouse_queue_profile_email(
        'customer-benefit-ended:' || r.id::text,
        r.profile_id,
        'customer_benefit_ended',
        'avopuntos_customer_benefit',
        '551814c9-ab4c-4577-b1d5-c7664ba86036',
        jsonb_build_object(
          'CUSTOMER_NAME', v_customer_name_html,
          'MULTIPLIER', v_multiplier_text,
          'START_DATE', to_char(r.start_date, 'DD/MM/YYYY'),
          'PLANNED_END_DATE', to_char(r.end_date, 'DD/MM/YYYY'),
          'END_NOTICE', 'Este beneficio terminó al concluir el ' || to_char(r.end_date, 'DD/MM/YYYY') || ' (hora Colombia).',
          'REASON', v_reason_html,
          'CRITERION_NOTE', v_criterion_note
        )
      );
    EXCEPTION WHEN OTHERS THEN
      v_email_request_id := NULL;
    END;

    UPDATE public.avopuntos_customer_rules
    SET end_email_attempted_at = now(),
        updated_at = now()
    WHERE id = r.id
      AND end_email_attempted_at IS NULL;

    IF v_email_request_id IS NOT NULL THEN
      v_processed := v_processed + 1;
    END IF;
  END LOOP;

  RETURN v_processed;
END;
$function$;

REVOKE ALL ON FUNCTION public.avopuntos_process_expired_customer_benefit_emails() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.avopuntos_process_expired_customer_benefit_emails() TO postgres;
