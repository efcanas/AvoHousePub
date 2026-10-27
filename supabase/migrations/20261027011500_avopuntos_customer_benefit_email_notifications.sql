ALTER TABLE public.avopuntos_customer_rules
  ADD COLUMN IF NOT EXISTS end_email_attempted_at timestamptz;

-- Do not send retroactive expiration notices for benefits that had already ended
-- before this notification workflow was deployed.
UPDATE public.avopuntos_customer_rules
SET end_email_attempted_at = COALESCE(end_email_attempted_at, now())
WHERE end_date IS NOT NULL
  AND end_date < (now() AT TIME ZONE 'America/Bogota')::date;

CREATE OR REPLACE FUNCTION public.avopuntos_admin_get_customer_rule(p_profile_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_admin uuid := auth.uid();
  v_today date := (now() AT TIME ZONE 'America/Bogota')::date;
  v_profile_created_date date;
  v_rule jsonb;
  v_latest_rule jsonb;
  v_current_rule jsonb;
  v_active_rules_count integer := 0;
  v_pilot jsonb;
BEGIN
  IF v_admin IS NULL OR NOT public.avopuntos_admin_is_admin() THEN
    RAISE EXCEPTION 'No autorizado.';
  END IF;

  IF p_profile_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = p_profile_id
  ) THEN
    RAISE EXCEPTION 'No existe el cliente seleccionado.';
  END IF;

  SELECT (p.created_at AT TIME ZONE 'America/Bogota')::date
  INTO v_profile_created_date
  FROM public.profiles p
  WHERE p.id = p_profile_id;

  -- Match the benefit-selection rule used by purchase processing:
  -- latest start date first, then most recently created.
  SELECT jsonb_build_object(
    'id', r.id,
    'multiplier', r.multiplier,
    'start_date', r.start_date,
    'end_date', r.end_date,
    'active', r.active,
    'reason', r.reason,
    'created_at', r.created_at,
    'currently_effective', true,
    'validity_status', 'Vigente'
  )
  INTO v_current_rule
  FROM public.avopuntos_customer_rules r
  WHERE r.profile_id = p_profile_id
    AND r.active = true
    AND r.start_date <= v_today
    AND (r.end_date IS NULL OR r.end_date >= v_today)
  ORDER BY r.start_date DESC, r.created_at DESC, r.id DESC
  LIMIT 1;

  SELECT count(*)::integer
  INTO v_active_rules_count
  FROM public.avopuntos_customer_rules r
  WHERE r.profile_id = p_profile_id
    AND r.active = true
    AND r.start_date <= v_today
    AND (r.end_date IS NULL OR r.end_date >= v_today);

  -- Keep a recent record visible when there is no rule currently in force,
  -- but never present that historical/scheduled record as the applied rule.
  SELECT jsonb_build_object(
    'id', r.id,
    'multiplier', r.multiplier,
    'start_date', r.start_date,
    'end_date', r.end_date,
    'active', r.active,
    'reason', r.reason,
    'created_at', r.created_at,
    'currently_effective', false,
    'validity_status',
      CASE
        WHEN r.active = false THEN 'Desactivado'
        WHEN r.start_date > v_today THEN 'Programado'
        WHEN r.end_date IS NOT NULL AND r.end_date < v_today THEN 'Vencido'
        ELSE 'No vigente'
      END
  )
  INTO v_latest_rule
  FROM public.avopuntos_customer_rules r
  WHERE r.profile_id = p_profile_id
  ORDER BY r.created_at DESC, r.id DESC
  LIMIT 1;

  v_rule := COALESCE(v_current_rule, v_latest_rule);

  v_pilot := jsonb_build_object(
    'eligible',
      (v_profile_created_date IS NOT NULL AND v_profile_created_date <= DATE '2026-12-31'),
    'active',
      (v_profile_created_date IS NOT NULL
       AND v_profile_created_date <= v_today
       AND v_profile_created_date <= DATE '2026-12-31'
       AND v_today <= DATE '2026-12-31'),
    'start_date', v_profile_created_date,
    'end_date', DATE '2026-12-31',
    'status',
      CASE
        WHEN v_profile_created_date IS NULL
          OR v_profile_created_date > DATE '2026-12-31' THEN 'No aplica'
        WHEN v_today > DATE '2026-12-31' THEN 'Finalizado'
        WHEN v_profile_created_date > v_today THEN 'Programado'
        ELSE 'Activo'
      END
  );

  RETURN jsonb_build_object(
    'rule', v_rule,
    'current_rule', v_current_rule,
    'active_rules_count', v_active_rules_count,
    'pilot', v_pilot
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.avopuntos_admin_set_customer_multiplier(
  p_profile_id uuid,
  p_multiplier numeric,
  p_start_date date,
  p_end_date date,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_admin uuid := auth.uid();
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_id uuid;
  v_customer_name text;
  v_customer_name_html text;
  v_reason_html text;
  v_multiplier_text text;
  v_email_request_id bigint;
  v_criterion_note constant text :=
    'Los beneficios individuales tienen prioridad sobre la multiplicación Piloto y las promociones generales. Si coinciden varios beneficios individuales vigentes, se aplica el de fecha de inicio más reciente; si empatan, el último registrado. Los multiplicadores no se combinan entre sí.';
BEGIN
  IF v_admin IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.admin_users WHERE user_id = v_admin
  ) THEN
    RAISE EXCEPTION 'No autorizado.';
  END IF;

  IF p_profile_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = p_profile_id
  ) THEN
    RAISE EXCEPTION 'No existe el cliente seleccionado.';
  END IF;

  IF p_multiplier IS NULL OR p_multiplier <= 0 OR p_multiplier > 100 THEN
    RAISE EXCEPTION 'El multiplicador debe estar entre 0,01× y 100×.';
  END IF;

  IF p_start_date IS NULL THEN
    RAISE EXCEPTION 'La fecha de inicio es obligatoria.';
  END IF;

  IF p_end_date IS NOT NULL AND p_end_date < p_start_date THEN
    RAISE EXCEPTION 'La fecha final no puede ser anterior a la fecha inicial.';
  END IF;

  IF v_reason IS NULL OR char_length(v_reason) > 500 THEN
    RAISE EXCEPTION 'Debes indicar un motivo de hasta 500 caracteres.';
  END IF;

  INSERT INTO public.avopuntos_customer_rules(
    profile_id, multiplier, start_date, end_date, active, reason, created_by
  )
  VALUES (
    p_profile_id, p_multiplier, p_start_date, p_end_date, true, v_reason, v_admin
  )
  RETURNING id INTO v_id;

  INSERT INTO public.avopuntos_admin_changes(
    admin_user_id, entity_type, entity_id, action, details
  )
  VALUES (
    v_admin, 'customer_rule', v_id, 'create',
    jsonb_build_object(
      'profile_id', p_profile_id,
      'multiplier', p_multiplier,
      'start_date', p_start_date,
      'end_date', p_end_date,
      'reason', v_reason
    )
  );

  -- Queue a transactional notification without rolling back the benefit if
  -- the mail system is temporarily unavailable.
  v_email_request_id := NULL;
  BEGIN
    SELECT COALESCE(NULLIF(trim(p.full_name), ''), 'Cliente AvoHouse')
    INTO v_customer_name
    FROM public.profiles p
    WHERE p.id = p_profile_id;

    v_customer_name_html := replace(replace(replace(
      COALESCE(v_customer_name, 'Cliente AvoHouse'), '&', '&amp;'
    ), '<', '&lt;'), '>', '&gt;');

    v_reason_html := replace(replace(replace(v_reason, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');

    v_multiplier_text := replace(
      trim(trailing '.' from trim(trailing '0' from to_char(p_multiplier, 'FM999999990.99'))),
      '.', ','
    );

    v_email_request_id := public.avohouse_queue_profile_email(
      'customer-benefit-assigned:' || v_id::text,
      p_profile_id,
      'customer_benefit_assigned',
      'avopuntos_customer_benefit',
      'd6a692dc-0ea4-42cc-93b6-ecf59383139f',
      jsonb_build_object(
        'CUSTOMER_NAME', v_customer_name_html,
        'MULTIPLIER', v_multiplier_text,
        'START_DATE', to_char(p_start_date, 'DD/MM/YYYY'),
        'END_DATE_TEXT', COALESCE(to_char(p_end_date, 'DD/MM/YYYY'), 'sin fecha final'),
        'REASON', v_reason_html,
        'CRITERION_NOTE', v_criterion_note
      )
    );
  EXCEPTION WHEN OTHERS THEN
    v_email_request_id := NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'id', v_id,
    'email_queued', v_email_request_id IS NOT NULL
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.avopuntos_admin_set_customer_rule_active(
  p_rule_id uuid,
  p_active boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_admin uuid := auth.uid();
  v_rule public.avopuntos_customer_rules%rowtype;
  v_today date := (now() AT TIME ZONE 'America/Bogota')::date;
  v_customer_name text;
  v_customer_name_html text;
  v_reason_html text;
  v_multiplier_text text;
  v_email_request_id bigint;
  v_email_queued boolean := false;
  v_criterion_note constant text :=
    'Desde el fin de este beneficio se aplica el primer criterio disponible en este orden: otro beneficio individual vigente, multiplicación Piloto ×2 (si sigue vigente), una promoción general activa y, por último, la tasa base de AvoPuntos. Los criterios no se suman ni multiplican entre sí.';
BEGIN
  IF v_admin IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.admin_users WHERE user_id = v_admin
  ) THEN
    RAISE EXCEPTION 'No autorizado.';
  END IF;

  SELECT * INTO v_rule
  FROM public.avopuntos_customer_rules
  WHERE id = p_rule_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No existe el beneficio seleccionado.';
  END IF;

  UPDATE public.avopuntos_customer_rules
  SET active = COALESCE(p_active, false),
      end_email_attempted_at = CASE
        WHEN COALESCE(p_active, false) THEN NULL
        ELSE COALESCE(end_email_attempted_at, now())
      END,
      updated_at = now()
  WHERE id = p_rule_id;

  INSERT INTO public.avopuntos_admin_changes(
    admin_user_id, entity_type, entity_id, action, details
  )
  VALUES (
    v_admin, 'customer_rule', p_rule_id,
    CASE WHEN COALESCE(p_active, false) THEN 'activate' ELSE 'deactivate' END,
    jsonb_build_object(
      'profile_id', v_rule.profile_id,
      'previous_active', v_rule.active,
      'new_active', COALESCE(p_active, false)
    )
  );

  -- A manual deactivation is also an end-of-benefit event. Send only once when
  -- the rule really transitions from active to inactive.
  IF COALESCE(p_active, false) = false AND v_rule.active = true THEN
    v_email_request_id := NULL;
    BEGIN
      SELECT COALESCE(NULLIF(trim(p.full_name), ''), 'Cliente AvoHouse')
      INTO v_customer_name
      FROM public.profiles p
      WHERE p.id = v_rule.profile_id;

      v_customer_name_html := replace(replace(replace(
        COALESCE(v_customer_name, 'Cliente AvoHouse'), '&', '&amp;'
      ), '<', '&lt;'), '>', '&gt;');

      v_reason_html := replace(replace(replace(
        COALESCE(v_rule.reason, 'Beneficio individual de AvoPuntos'), '&', '&amp;'
      ), '<', '&lt;'), '>', '&gt;');

      v_multiplier_text := replace(
        trim(trailing '.' from trim(trailing '0' from to_char(v_rule.multiplier, 'FM999999990.99'))),
        '.', ','
      );

      v_email_request_id := public.avohouse_queue_profile_email(
        'customer-benefit-ended:' || v_rule.id::text,
        v_rule.profile_id,
        'customer_benefit_ended',
        'avopuntos_customer_benefit',
        '551814c9-ab4c-4577-b1d5-c7664ba86036',
        jsonb_build_object(
          'CUSTOMER_NAME', v_customer_name_html,
          'MULTIPLIER', v_multiplier_text,
          'START_DATE', to_char(v_rule.start_date, 'DD/MM/YYYY'),
          'PLANNED_END_DATE', COALESCE(to_char(v_rule.end_date, 'DD/MM/YYYY'), 'sin fecha final'),
          'END_NOTICE', 'Este beneficio fue desactivado de forma anticipada el ' || to_char(v_today, 'DD/MM/YYYY') || ' (hora Colombia).',
          'REASON', v_reason_html,
          'CRITERION_NOTE', v_criterion_note
        )
      );

      v_email_queued := v_email_request_id IS NOT NULL;
    EXCEPTION WHEN OTHERS THEN
      v_email_queued := false;
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'id', p_rule_id,
    'active', COALESCE(p_active, false),
    'email_queued', v_email_queued
  );
END;
$function$;

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

    -- Record the attempt regardless of the mail outcome, so cron will not
    -- enqueue the same end notification repeatedly if email configuration fails.
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

DO $cron$
DECLARE
  v_job_id bigint;
BEGIN
  SELECT jobid INTO v_job_id
  FROM cron.job
  WHERE jobname = 'avohouse_customer_benefit_expiration_email'
  LIMIT 1;

  IF v_job_id IS NOT NULL THEN
    PERFORM cron.unschedule(v_job_id);
  END IF;

  PERFORM cron.schedule(
    'avohouse_customer_benefit_expiration_email',
    '10 12 * * *',
    'SELECT public.avopuntos_process_expired_customer_benefit_emails();'
  );
END;
$cron$;
