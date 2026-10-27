-- Choose the strongest eligible individual multiplier in the current return and purchase accrual.
DO $rewrite$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
  v_position integer;
BEGIN
  v_definition := pg_get_functiondef('public.avopuntos_get_my_current_return()'::regprocedure);
  v_old := 'ORDER BY r.start_date DESC,r.created_at DESC';
  v_new := 'ORDER BY r.multiplier DESC,r.start_date DESC,r.created_at DESC,r.id DESC';
  IF strpos(v_definition, v_old) = 0 THEN RAISE EXCEPTION 'No se encontró el selector de beneficios individuales en avopuntos_get_my_current_return.'; END IF;
  EXECUTE replace(v_definition, v_old, v_new);

  v_definition := pg_get_functiondef('public.avopuntos_process_receipt(text)'::regprocedure);
  v_old := 'ORDER BY p.start_date DESC,p.created_at DESC';
  v_new := 'ORDER BY p.multiplier DESC,p.start_date DESC,p.created_at DESC,p.id DESC';
  v_position := strpos(v_definition, v_old);
  IF v_position = 0 THEN RAISE EXCEPTION 'No se encontró el selector de beneficios individuales en avopuntos_process_receipt.'; END IF;
  v_definition := substring(v_definition from 1 for v_position - 1)
    || v_new
    || substring(v_definition from v_position + length(v_old));
  EXECUTE v_definition;

  v_definition := pg_get_functiondef('public.avopuntos_admin_set_customer_multiplier(uuid,numeric,date,date,text)'::regprocedure);
  v_old := 'Los beneficios individuales tienen prioridad sobre la multiplicación Piloto y las promociones generales. Si coinciden varios beneficios individuales vigentes, se aplica el de fecha de inicio más reciente; si empatan, el último registrado. Los multiplicadores no se combinan entre sí.';
  v_new := 'Si coinciden varios beneficios individuales vigentes, se aplica el de mayor multiplicador; si empatan, el de fecha de inicio más reciente y, después, el último registrado. Los multiplicadores no se combinan. Al dejar de estar vigente uno, se evalúa el siguiente beneficio individual por multiplicador; después Piloto ×2, promoción general y tasa base.';
  IF strpos(v_definition, v_old) = 0 THEN RAISE EXCEPTION 'No se encontró la nota de criterio en el correo de activación.'; END IF;
  EXECUTE replace(v_definition, v_old, v_new);

  v_definition := pg_get_functiondef('public.avopuntos_process_expired_customer_benefit_emails()'::regprocedure);
  v_old := 'Desde el día siguiente al fin de este beneficio se aplica el primer criterio disponible en este orden: otro beneficio individual vigente, multiplicación Piloto ×2 (si sigue vigente), una promoción general activa y, por último, la tasa base de AvoPuntos. Los criterios no se suman ni multiplican entre sí.';
  v_new := 'Al finalizar este beneficio se aplica el beneficio individual vigente con mayor multiplicador, si existe; de lo contrario se evalúa Piloto ×2, una promoción general activa y, por último, la tasa base. Los multiplicadores no se combinan.';
  IF strpos(v_definition, v_old) = 0 THEN RAISE EXCEPTION 'No se encontró la nota de criterio en el correo de vencimiento.'; END IF;
  v_definition := replace(v_definition, v_old, v_new);
  v_old := 'ORDER BY winner.start_date DESC, winner.created_at DESC, winner.id DESC';
  v_new := 'ORDER BY winner.multiplier DESC, winner.start_date DESC, winner.created_at DESC, winner.id DESC';
  IF strpos(v_definition, v_old) = 0 THEN RAISE EXCEPTION 'No se encontró el selector para correos de vencimiento.'; END IF;
  v_definition := replace(v_definition, v_old, v_new);
  EXECUTE v_definition;
END;
$rewrite$;

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
  v_current_rule jsonb;
  v_latest_rule jsonb;
  v_rules jsonb;
  v_active_rules_count integer := 0;
  v_pilot jsonb;
  v_effective_rule_id uuid;
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

  SELECT r.id,
    jsonb_build_object(
      'id', r.id, 'multiplier', r.multiplier, 'start_date', r.start_date,
      'end_date', r.end_date, 'active', r.active, 'reason', r.reason,
      'created_at', r.created_at, 'currently_effective', true, 'validity_status', 'Vigente'
    )
  INTO v_effective_rule_id, v_current_rule
  FROM public.avopuntos_customer_rules r
  WHERE r.profile_id = p_profile_id
    AND r.active = true
    AND r.start_date <= v_today
    AND (r.end_date IS NULL OR r.end_date >= v_today)
  ORDER BY r.multiplier DESC, r.start_date DESC, r.created_at DESC, r.id DESC
  LIMIT 1;

  SELECT count(*)::integer INTO v_active_rules_count
  FROM public.avopuntos_customer_rules r
  WHERE r.profile_id = p_profile_id
    AND r.active = true
    AND r.start_date <= v_today
    AND (r.end_date IS NULL OR r.end_date >= v_today);

  SELECT jsonb_agg(
    jsonb_build_object(
      'id', r.id, 'multiplier', r.multiplier, 'start_date', r.start_date,
      'end_date', r.end_date, 'active', r.active, 'reason', r.reason,
      'created_at', r.created_at, 'currently_effective', (r.id = v_effective_rule_id),
      'validity_status',
        CASE
          WHEN r.active = false THEN 'Desactivado'
          WHEN r.end_date IS NOT NULL AND r.end_date < v_today THEN 'Vencido'
          WHEN r.start_date > v_today THEN 'Programado'
          ELSE 'Vigente'
        END
    )
    ORDER BY r.multiplier DESC, r.start_date DESC, r.created_at DESC, r.id DESC
  )
  INTO v_rules
  FROM public.avopuntos_customer_rules r
  WHERE r.profile_id = p_profile_id;

  SELECT jsonb_build_object(
    'id', r.id, 'multiplier', r.multiplier, 'start_date', r.start_date,
    'end_date', r.end_date, 'active', r.active, 'reason', r.reason,
    'created_at', r.created_at, 'currently_effective', false,
    'validity_status',
      CASE
        WHEN r.active = false THEN 'Desactivado'
        WHEN r.end_date IS NOT NULL AND r.end_date < v_today THEN 'Vencido'
        WHEN r.start_date > v_today THEN 'Programado'
        ELSE 'No vigente'
      END
  )
  INTO v_latest_rule
  FROM public.avopuntos_customer_rules r
  WHERE r.profile_id = p_profile_id
  ORDER BY r.created_at DESC, r.id DESC
  LIMIT 1;

  v_pilot := jsonb_build_object(
    'eligible', (v_profile_created_date IS NOT NULL AND v_profile_created_date <= DATE '2026-12-31'),
    'active', (
      v_profile_created_date IS NOT NULL
      AND v_profile_created_date <= v_today
      AND v_profile_created_date <= DATE '2026-12-31'
      AND v_today <= DATE '2026-12-31'
    ),
    'start_date', v_profile_created_date,
    'end_date', DATE '2026-12-31',
    'status',
      CASE
        WHEN v_profile_created_date IS NULL OR v_profile_created_date > DATE '2026-12-31' THEN 'No aplica'
        WHEN v_today > DATE '2026-12-31' THEN 'Finalizado'
        WHEN v_profile_created_date > v_today THEN 'Programado'
        ELSE 'Activo'
      END
  );

  RETURN jsonb_build_object(
    'rule', COALESCE(v_current_rule, v_latest_rule),
    'current_rule', v_current_rule,
    'rules', COALESCE(v_rules, '[]'::jsonb),
    'active_rules_count', v_active_rules_count,
    'pilot', v_pilot
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.avopuntos_admin_set_customer_rule_active(p_rule_id uuid, p_active boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_admin uuid := auth.uid();
  v_rule public.avopuntos_customer_rules%rowtype;
  v_today date := (now() AT TIME ZONE 'America/Bogota')::date;
  v_new_active boolean := COALESCE(p_active, false);
  v_customer_name text;
  v_customer_name_html text;
  v_reason_html text;
  v_multiplier_text text;
  v_email_request_id bigint;
  v_email_queued boolean := false;
  v_event_key text;
  v_criterion_note constant text :=
    'Si coinciden varios beneficios individuales vigentes, se aplica el de mayor multiplicador; si empatan, el de fecha de inicio más reciente y, después, el último registrado. Los multiplicadores no se combinan. Al dejar de estar vigente uno, se evalúa el siguiente beneficio individual por multiplicador; después Piloto ×2, promoción general y tasa base.';
BEGIN
  IF v_admin IS NULL OR NOT EXISTS (SELECT 1 FROM public.admin_users WHERE user_id = v_admin) THEN
    RAISE EXCEPTION 'No autorizado.';
  END IF;

  SELECT * INTO v_rule
  FROM public.avopuntos_customer_rules
  WHERE id = p_rule_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No existe el beneficio seleccionado.';
  END IF;

  IF v_new_active AND v_rule.end_date IS NOT NULL AND v_rule.end_date < v_today THEN
    RAISE EXCEPTION 'No se puede activar un beneficio cuyo periodo ya venció. Crea uno nuevo con las fechas correctas.';
  END IF;

  UPDATE public.avopuntos_customer_rules
  SET active = v_new_active,
      end_email_attempted_at = CASE WHEN v_new_active THEN NULL ELSE COALESCE(end_email_attempted_at, now()) END,
      updated_at = now()
  WHERE id = p_rule_id;

  INSERT INTO public.avopuntos_admin_changes(admin_user_id, entity_type, entity_id, action, details)
  VALUES (
    v_admin, 'customer_rule', p_rule_id,
    CASE WHEN v_new_active THEN 'activate' ELSE 'deactivate' END,
    jsonb_build_object(
      'profile_id', v_rule.profile_id, 'previous_active', v_rule.active,
      'new_active', v_new_active, 'multiplier', v_rule.multiplier,
      'start_date', v_rule.start_date, 'end_date', v_rule.end_date, 'reason', v_rule.reason
    )
  );

  IF v_new_active IS DISTINCT FROM v_rule.active THEN
    v_email_request_id := NULL;
    BEGIN
      SELECT COALESCE(NULLIF(trim(p.full_name), ''), 'Cliente AvoHouse')
      INTO v_customer_name
      FROM public.profiles p WHERE p.id = v_rule.profile_id;

      v_customer_name_html := replace(replace(replace(COALESCE(v_customer_name, 'Cliente AvoHouse'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
      v_reason_html := replace(replace(replace(COALESCE(v_rule.reason, 'Beneficio individual de AvoPuntos'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
      v_multiplier_text := replace(trim(trailing '.' from trim(trailing '0' from to_char(v_rule.multiplier, 'FM999999990.99'))), '.', ',');

      IF v_new_active THEN
        v_event_key := 'customer-benefit-activated:' || v_rule.id::text || ':' || gen_random_uuid()::text;
        v_email_request_id := public.avohouse_queue_profile_email(
          v_event_key, v_rule.profile_id, 'customer_benefit_assigned', 'avopuntos_customer_benefit',
          'd6a692dc-0ea4-42cc-93b6-ecf59383139f',
          jsonb_build_object(
            'CUSTOMER_NAME', v_customer_name_html,
            'MULTIPLIER', v_multiplier_text,
            'START_DATE', to_char(v_rule.start_date, 'DD/MM/YYYY'),
            'END_DATE_TEXT', COALESCE(to_char(v_rule.end_date, 'DD/MM/YYYY'), 'sin fecha final'),
            'REASON', v_reason_html,
            'CRITERION_NOTE', v_criterion_note
          )
        );
      ELSIF v_rule.start_date <= v_today AND (v_rule.end_date IS NULL OR v_rule.end_date >= v_today) THEN
        v_event_key := 'customer-benefit-ended:' || v_rule.id::text || ':' || gen_random_uuid()::text;
        v_email_request_id := public.avohouse_queue_profile_email(
          v_event_key, v_rule.profile_id, 'customer_benefit_ended', 'avopuntos_customer_benefit',
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
      END IF;
      v_email_queued := v_email_request_id IS NOT NULL;
    EXCEPTION WHEN OTHERS THEN
      v_email_queued := false;
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'id', p_rule_id, 'active', v_new_active,
    'state_changed', v_new_active IS DISTINCT FROM v_rule.active, 'email_queued', v_email_queued
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.avopuntos_admin_delete_customer_rule(p_rule_id uuid)
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
  v_event_key text;
  v_criterion_note constant text :=
    'Si coinciden varios beneficios individuales vigentes, se aplica el de mayor multiplicador; si empatan, el de fecha de inicio más reciente y, después, el último registrado. Los multiplicadores no se combinan. Al dejar de estar vigente uno, se evalúa el siguiente beneficio individual por multiplicador; después Piloto ×2, promoción general y tasa base.';
BEGIN
  IF v_admin IS NULL OR NOT EXISTS (SELECT 1 FROM public.admin_users WHERE user_id = v_admin) THEN
    RAISE EXCEPTION 'No autorizado.';
  END IF;

  SELECT * INTO v_rule FROM public.avopuntos_customer_rules WHERE id = p_rule_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el beneficio seleccionado.'; END IF;

  IF v_rule.active = true AND (v_rule.end_date IS NULL OR v_rule.end_date >= v_today) THEN
    v_email_request_id := NULL;
    BEGIN
      SELECT COALESCE(NULLIF(trim(p.full_name), ''), 'Cliente AvoHouse')
      INTO v_customer_name FROM public.profiles p WHERE p.id = v_rule.profile_id;

      v_customer_name_html := replace(replace(replace(COALESCE(v_customer_name, 'Cliente AvoHouse'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
      v_reason_html := replace(replace(replace(COALESCE(v_rule.reason, 'Beneficio individual de AvoPuntos'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
      v_multiplier_text := replace(trim(trailing '.' from trim(trailing '0' from to_char(v_rule.multiplier, 'FM999999990.99'))), '.', ',');
      v_event_key := 'customer-benefit-ended:' || v_rule.id::text || ':removed:' || gen_random_uuid()::text;

      v_email_request_id := public.avohouse_queue_profile_email(
        v_event_key, v_rule.profile_id, 'customer_benefit_ended', 'avopuntos_customer_benefit',
        '551814c9-ab4c-4577-b1d5-c7664ba86036',
        jsonb_build_object(
          'CUSTOMER_NAME', v_customer_name_html,
          'MULTIPLIER', v_multiplier_text,
          'START_DATE', to_char(v_rule.start_date, 'DD/MM/YYYY'),
          'PLANNED_END_DATE', COALESCE(to_char(v_rule.end_date, 'DD/MM/YYYY'), 'sin fecha final'),
          'END_NOTICE', CASE
            WHEN v_rule.start_date > v_today THEN 'Este beneficio fue retirado antes de su fecha de inicio.'
            ELSE 'Este beneficio fue retirado manualmente el ' || to_char(v_today, 'DD/MM/YYYY') || ' (hora Colombia).'
          END,
          'REASON', v_reason_html,
          'CRITERION_NOTE', v_criterion_note
        )
      );
      v_email_queued := v_email_request_id IS NOT NULL;
    EXCEPTION WHEN OTHERS THEN
      v_email_queued := false;
    END;
  END IF;

  INSERT INTO public.avopuntos_admin_changes(admin_user_id, entity_type, entity_id, action, details)
  VALUES (
    v_admin, 'customer_rule', p_rule_id, 'delete',
    jsonb_build_object(
      'profile_id', v_rule.profile_id, 'multiplier', v_rule.multiplier,
      'start_date', v_rule.start_date, 'end_date', v_rule.end_date,
      'active', v_rule.active, 'reason', v_rule.reason, 'email_queued', v_email_queued
    )
  );

  DELETE FROM public.avopuntos_customer_rules WHERE id = p_rule_id;
  RETURN jsonb_build_object('ok', true, 'id', p_rule_id, 'email_queued', v_email_queued);
END;
$function$;

REVOKE ALL ON FUNCTION public.avopuntos_admin_delete_customer_rule(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.avopuntos_admin_delete_customer_rule(uuid) TO authenticated;