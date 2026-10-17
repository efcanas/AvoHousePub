-- Notify clients by email when an AP achievement is granted.
CREATE OR REPLACE FUNCTION public.avohouse_queue_achievement_award_email(p_event_key text, p_profile_id uuid, p_reward_code text, p_achievement_name text, p_description text, p_points_awarded bigint, p_points_balance bigint, p_awarded_at timestamp with time zone, p_expires_at timestamp with time zone)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_customer_name text;
  v_achievement_name text;
  v_description text;
  v_image_url text;
  v_achievement_link text;
  v_award_date text;
  v_expiry_note text;
  v_request_id bigint;
BEGIN
  IF p_event_key IS NULL OR btrim(p_event_key)='' OR p_profile_id IS NULL
     OR p_points_awarded IS NULL OR p_points_awarded<=0
     OR p_reward_code NOT IN (
       'points_earned_2k','points_earned_10k','first_redemption',
       'points_redeemed_20k','account_anniversary','birthday_celebration'
     ) THEN
    RETURN NULL;
  END IF;

  SELECT coalesce(nullif(btrim(p.full_name),''),'Cliente AvoHouse')
    INTO v_customer_name
  FROM public.profiles p
  WHERE p.id=p_profile_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT coalesce(nullif(btrim(p_description),''),r.description,'')
    INTO v_description
  FROM public.avopuntos_rewards r
  WHERE r.code=p_reward_code
  LIMIT 1;
  v_description := coalesce(v_description,'');

  v_achievement_name := coalesce(nullif(btrim(p_achievement_name),''),p_reward_code);

  v_image_url := CASE p_reward_code
    WHEN 'points_earned_2k' THEN 'https://avohousepub.com/assets/logros-ah/2k-avopuntos.svg'
    WHEN 'points_earned_10k' THEN 'https://avohousepub.com/assets/logros-ah/10k-avopuntos.svg'
    WHEN 'first_redemption' THEN 'https://avohousepub.com/assets/logros-ah/primer-movimiento.svg'
    WHEN 'points_redeemed_20k' THEN 'https://avohousepub.com/assets/logros-ah/ap-en-circulacion.svg'
    WHEN 'account_anniversary' THEN 'https://avohousepub.com/assets/logros-ah/aniversario-avohouse.svg'
    WHEN 'birthday_celebration' THEN 'https://avohousepub.com/assets/logros-ah/celebracion-avohouse.svg'
    ELSE 'https://avohousepub.com/assets/logros-ah/bienvenido.svg'
  END;

  v_achievement_link := CASE
    WHEN p_reward_code IN ('account_anniversary','birthday_celebration')
      THEN 'https://avohousepub.com/cuenta/mi-cuenta.html#specialAchievementsSection'
    ELSE 'https://avohousepub.com/cuenta/mi-cuenta.html#rewardsSection'
  END;

  v_award_date := to_char(
    coalesce(p_awarded_at,now()) AT TIME ZONE 'America/Bogota',
    'DD/MM/YYYY HH24:MI'
  ) || ' (hora de Colombia)';

  IF p_expires_at IS NOT NULL THEN
    v_expiry_note := 'Recuerda: el bono de cumpleaños vence el ' ||
      to_char(p_expires_at AT TIME ZONE 'America/Bogota','DD/MM/YYYY HH24:MI') ||
      ' (hora de Colombia). Al vencer, solo se revierten los puntos de este bono que queden sin usar.';
  ELSE
    v_expiry_note := 'Tus AvoPuntos se rigen por las condiciones generales de vigencia del programa AvoPuntos.';
  END IF;

  -- These variables are inserted as raw template placeholders by Resend;
  -- escape all text values here. URLs come from a fixed allowlist above.
  v_customer_name := replace(replace(replace(replace(replace(v_customer_name,'&','&amp;'),'<','&lt;'),'>','&gt;'),'"','&quot;'),'''','&#39;');
  v_achievement_name := replace(replace(replace(replace(replace(v_achievement_name,'&','&amp;'),'<','&lt;'),'>','&gt;'),'"','&quot;'),'''','&#39;');
  v_description := replace(replace(replace(replace(replace(v_description,'&','&amp;'),'<','&lt;'),'>','&gt;'),'"','&quot;'),'''','&#39;');
  v_expiry_note := replace(replace(replace(replace(replace(v_expiry_note,'&','&amp;'),'<','&lt;'),'>','&gt;'),'"','&quot;'),'''','&#39;');

  v_request_id := public.avohouse_queue_profile_email(
    'achievement-points:' || p_event_key,
    p_profile_id,
    'achievement_awarded',
    p_reward_code,
    '12eba35e-2f31-45b6-b785-fa7ad5c519bb',
    jsonb_build_object(
      'CUSTOMER_NAME',v_customer_name,
      'ACHIEVEMENT_NAME',v_achievement_name,
      'ACHIEVEMENT_DESCRIPTION',v_description,
      'ACHIEVEMENT_IMAGE_URL',v_image_url,
      'POINTS_AWARDED',p_points_awarded,
      'POINTS_BALANCE',coalesce(p_points_balance,0),
      'AWARD_DATE',v_award_date,
      'EXPIRY_NOTE',v_expiry_note,
      'ACHIEVEMENT_LINK',v_achievement_link
    )
  );

  RETURN v_request_id;
END;
$function$
;
REVOKE ALL ON FUNCTION public.avohouse_queue_achievement_award_email(text,uuid,text,text,text,bigint,bigint,timestamptz,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.avohouse_queue_achievement_award_email(text,uuid,text,text,text,bigint,bigint,timestamptz,timestamptz) TO service_role;

CREATE OR REPLACE FUNCTION public.avopuntos_check_permanent_achievements(p_profile_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_created_at timestamptz;
  v_purchase_points bigint := 0;
  v_redeemed_points bigint := 0;
  v_goal record;
  v_reward public.avopuntos_rewards%rowtype;
  v_claim_id uuid;
  v_source_key text;
  v_progress bigint;
  v_balance bigint;
  v_rows integer;
  v_granted jsonb := '[]'::jsonb;
BEGIN
  IF p_profile_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_profile');
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('avopuntos-permanent-achievements:' || p_profile_id::text, 0)
  );

  SELECT p.created_at INTO v_created_at
  FROM public.profiles p
  WHERE p.id = p_profile_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'profile_not_found');
  END IF;

  -- Net AP earned from valid sales, minus AP reversed by valid refunds.
  -- Receipt-backed points exclude welcome, social and other achievement bonuses.
  SELECT greatest(0, coalesce(sum(
    CASE
      WHEN r.receipt_type = 'SALE' AND r.cancelled_at IS NULL
        THEN greatest(coalesce(s.applied_earned_points, 0), 0)
      WHEN r.receipt_type = 'REFUND' AND r.cancelled_at IS NULL
        THEN -greatest(coalesce(s.applied_earned_points, 0), 0)
      ELSE 0
    END
  ), 0))::bigint
  INTO v_purchase_points
  FROM public.avopuntos_receipt_state s
  JOIN public.loyverse_receipts r ON r.receipt_number = s.receipt_number
  WHERE s.profile_id = p_profile_id
    AND r.profile_id = p_profile_id
    AND s.status = 'processed'
    AND r.receipt_type IN ('SALE', 'REFUND')
    AND coalesce(r.receipt_date, r.created_at, r.updated_at) >= v_created_at;

  -- Net AP used in valid sales, minus points restored by valid refunds.
  SELECT greatest(0, coalesce(sum(
    CASE
      WHEN r.receipt_type = 'SALE' AND r.cancelled_at IS NULL
        THEN greatest(coalesce(s.applied_redeemed_points, 0), 0)
      WHEN r.receipt_type = 'REFUND' AND r.cancelled_at IS NULL
        THEN -greatest(coalesce(s.applied_redeemed_points, 0), 0)
      ELSE 0
    END
  ), 0))::bigint
  INTO v_redeemed_points
  FROM public.avopuntos_receipt_state s
  JOIN public.loyverse_receipts r ON r.receipt_number = s.receipt_number
  WHERE s.profile_id = p_profile_id
    AND r.profile_id = p_profile_id
    AND s.status = 'processed'
    AND r.receipt_type IN ('SALE', 'REFUND')
    AND coalesce(r.receipt_date, r.created_at, r.updated_at) >= v_created_at;

  -- Process in milestone order. Re-running cannot double-credit a reward.
  FOR v_goal IN
    SELECT *
    FROM (VALUES
      (1, 'points_earned_2k'::text, 2000::bigint, 'purchase'::text),
      (2, 'points_earned_10k'::text, 10000::bigint, 'purchase'::text),
      (3, 'first_redemption'::text, 1::bigint, 'redeem'::text),
      (4, 'points_redeemed_20k'::text, 25000::bigint, 'redeem'::text)
    ) AS goals(sort_order, code, target_points, progress_type)
    ORDER BY sort_order
  LOOP
    IF v_goal.progress_type = 'purchase' THEN
      v_progress := v_purchase_points;
    ELSE
      v_progress := v_redeemed_points;
    END IF;

    IF v_progress < v_goal.target_points THEN
      CONTINUE;
    END IF;

    SELECT * INTO v_reward
    FROM public.avopuntos_rewards r
    WHERE r.code = v_goal.code AND r.active = true
    LIMIT 1;

    IF NOT FOUND OR v_reward.points <= 0 THEN
      CONTINUE;
    END IF;

    v_claim_id := NULL;
    v_source_key := 'reward:' || v_goal.code || ':' || p_profile_id::text;

    INSERT INTO public.avopuntos_customer_rewards
      (profile_id, reward_id, status, points_granted, source_key, evidence, claimed_at, granted_by)
    VALUES
      (
        p_profile_id, v_reward.id, 'claimed', v_reward.points, v_source_key,
        jsonb_build_object(
          'achievement_code', v_goal.code,
          'progress_type', v_goal.progress_type,
          'progress_at_unlock', v_progress,
          'target_points', v_goal.target_points
        ),
        now(), NULL
      )
    ON CONFLICT (profile_id, reward_id) DO NOTHING
    RETURNING id INTO v_claim_id;

    IF v_claim_id IS NULL THEN
      CONTINUE;
    END IF;

    INSERT INTO public.avopuntos_movements
      (profile_id, movement_type, points_delta, source_key, details)
    VALUES
      (
        p_profile_id, 'earn', v_reward.points,
        'achievement:' || v_goal.code || ':' || p_profile_id::text,
        jsonb_build_object(
          'title', v_reward.name,
          'bonus_type', v_goal.code,
          'reward_code', v_goal.code,
          'description', v_reward.description,
          'points_granted', v_reward.points,
          'progress_at_unlock', v_progress,
          'target_points', v_goal.target_points
        )
      )
    ON CONFLICT (source_key) DO NOTHING;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 1 THEN
      RAISE EXCEPTION 'No fue posible registrar de forma única el abono del logro % para %.', v_goal.code, p_profile_id;
    END IF;

    INSERT INTO public.avopuntos_accounts (profile_id, balance)
    VALUES (p_profile_id, 0)
    ON CONFLICT (profile_id) DO NOTHING;

    UPDATE public.avopuntos_accounts
    SET balance = balance + v_reward.points, updated_at = now()
    WHERE profile_id = p_profile_id
    RETURNING balance INTO v_balance;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'No existe la cuenta AvoPuntos asociada al perfil %.', p_profile_id;
    END IF;

    PERFORM public.avohouse_queue_achievement_award_email(
      'achievement:' || v_goal.code || ':' || p_profile_id::text,
      p_profile_id,
      v_goal.code,
      v_reward.name,
      v_reward.description,
      v_reward.points,
      v_balance,
      now(),
      NULL
    );

    v_granted := v_granted || jsonb_build_array(v_goal.code);
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'profile_id', p_profile_id,
    'purchase_points', v_purchase_points,
    'redeemed_points', v_redeemed_points,
    'granted', v_granted
  );
END;
$function$
;
REVOKE ALL ON FUNCTION public.avopuntos_check_permanent_achievements(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.avopuntos_check_permanent_achievements(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.avopuntos_process_annual_reward_cycles()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  p record;
  v_cycle public.avopuntos_annual_reward_cycles%rowtype;
  v_reward public.avopuntos_rewards%rowtype;
  v_expiry record;
  v_cycle_id uuid;
  v_today date := (now() AT TIME ZONE 'America/Bogota')::date;
  v_year integer := extract(year FROM (now() AT TIME ZONE 'America/Bogota'))::integer;
  v_created_local date;
  v_month integer;
  v_day integer;
  v_month_start date;
  v_days_in_month integer;
  v_event_date date;
  v_birthday_date date;
  v_now timestamptz := now();
  v_balance bigint;
  v_expire_points bigint;
  v_title text;
  v_source_key text;
  v_occurrences bigint;
  v_rows integer;
  v_granted_count integer := 0;
  v_expired_count integer := 0;
BEGIN
  FOR v_expiry IN
    SELECT c.id,c.profile_id
    FROM public.avopuntos_annual_reward_cycles c
    WHERE c.reward_code='birthday_celebration' AND c.status='granted'
      AND c.expires_at<=v_now AND c.points_remaining>0
    ORDER BY c.expires_at,c.profile_id
  LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended('avopuntos-annual-rewards:'||v_expiry.profile_id::text,0));
    INSERT INTO public.avopuntos_accounts(profile_id,balance)
      VALUES(v_expiry.profile_id,0) ON CONFLICT(profile_id) DO NOTHING;
    SELECT a.balance INTO v_balance
      FROM public.avopuntos_accounts a WHERE a.profile_id=v_expiry.profile_id FOR UPDATE;
    SELECT * INTO v_cycle FROM public.avopuntos_annual_reward_cycles c WHERE c.id=v_expiry.id FOR UPDATE;

    IF NOT FOUND OR v_cycle.status<>'granted' OR v_cycle.expires_at>v_now OR v_cycle.points_remaining<=0 THEN
      CONTINUE;
    END IF;

    v_expire_points := least(v_cycle.points_remaining,greatest(coalesce(v_balance,0),0));
    IF v_expire_points>0 THEN
      v_source_key := 'annual_reward_expiration:'||v_cycle.id::text;
      INSERT INTO public.avopuntos_movements(profile_id,movement_type,points_delta,source_key,details)
      VALUES(
        v_cycle.profile_id,'expiration',-v_expire_points,v_source_key,
        jsonb_build_object(
          'title','Vencimiento 🎂 Celebración AvoHouse',
          'bonus_type','birthday_celebration_expiration',
          'reward_code','birthday_celebration',
          'cycle_year',v_cycle.cycle_year,
          'points_reverted',v_expire_points,
          'expiration_date',v_cycle.expires_at
        )
      ) ON CONFLICT(source_key) DO NOTHING;
      GET DIAGNOSTICS v_rows=ROW_COUNT;
      IF v_rows=1 THEN
        UPDATE public.avopuntos_accounts
          SET balance=balance-v_expire_points,updated_at=v_now
          WHERE profile_id=v_cycle.profile_id;
      ELSE
        v_expire_points := 0;
      END IF;
    END IF;

    UPDATE public.avopuntos_annual_reward_cycles
      SET points_remaining=0,points_expired=v_expire_points,
          points_shortfall=greatest(v_cycle.points_remaining-v_expire_points,0),
          status='expired',expired_at=v_now,updated_at=v_now
      WHERE id=v_cycle.id;
    v_expired_count := v_expired_count+1;
  END LOOP;

  FOR p IN
    SELECT id,created_at,birth_date FROM public.profiles ORDER BY created_at,id
  LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended('avopuntos-annual-rewards:'||p.id::text,0));
    INSERT INTO public.avopuntos_accounts(profile_id,balance)
      VALUES(p.id,0) ON CONFLICT(profile_id) DO NOTHING;
    PERFORM 1 FROM public.avopuntos_accounts a WHERE a.profile_id=p.id FOR UPDATE;

    v_created_local := (p.created_at AT TIME ZONE 'America/Bogota')::date;
    IF extract(year FROM v_created_local)::integer<v_year THEN
      v_month := extract(month FROM v_created_local)::integer;
      v_day := extract(day FROM v_created_local)::integer;
      v_month_start := make_date(v_year,v_month,1);
      v_days_in_month := extract(day FROM (v_month_start+interval '1 month'-interval '1 day'))::integer;
      v_event_date := make_date(v_year,v_month,least(v_day,v_days_in_month));

      IF v_today>=v_event_date THEN
        SELECT * INTO v_reward FROM public.avopuntos_rewards
          WHERE code='account_anniversary' AND active=true LIMIT 1;
        IF FOUND AND v_reward.points>0 THEN
          v_cycle_id := NULL;
          INSERT INTO public.avopuntos_annual_reward_cycles
            (profile_id,reward_code,cycle_year,points_granted,granted_at,expires_at,points_remaining)
          VALUES(p.id,'account_anniversary',v_year,v_reward.points,v_now,NULL,NULL)
          ON CONFLICT(profile_id,reward_code,cycle_year) DO NOTHING
          RETURNING id INTO v_cycle_id;

          IF v_cycle_id IS NOT NULL THEN
            SELECT count(*) INTO v_occurrences FROM public.avopuntos_annual_reward_cycles
              WHERE profile_id=p.id AND reward_code='account_anniversary';
            v_title := v_reward.name||repeat(' 🎂',v_occurrences::integer);
            v_source_key := 'annual_reward:account_anniversary:'||p.id::text||':'||v_year::text;
            INSERT INTO public.avopuntos_movements(profile_id,movement_type,points_delta,source_key,details)
            VALUES(
              p.id,'earn',v_reward.points,v_source_key,
              jsonb_build_object(
                'title',v_title,'bonus_type','account_anniversary',
                'reward_code','account_anniversary','description',v_reward.description,
                'points_granted',v_reward.points,'cycle_year',v_year
              )
            ) ON CONFLICT(source_key) DO NOTHING;
            GET DIAGNOSTICS v_rows=ROW_COUNT;
            IF v_rows<>1 THEN RAISE EXCEPTION 'No fue posible registrar el aniversario anual para el perfil %.',p.id; END IF;
            UPDATE public.avopuntos_accounts
              SET balance=balance+v_reward.points,updated_at=v_now
              WHERE profile_id=p.id
              RETURNING balance INTO v_balance;

            PERFORM public.avohouse_queue_achievement_award_email(
              v_source_key,
              p.id,
              'account_anniversary',
              v_title,
              v_reward.description,
              v_reward.points,
              v_balance,
              v_now,
              NULL
            );

            v_granted_count := v_granted_count+1;
          END IF;
        END IF;
      END IF;
    END IF;

    IF p.birth_date IS NOT NULL THEN
      v_month := extract(month FROM p.birth_date)::integer;
      v_day := extract(day FROM p.birth_date)::integer;
      v_month_start := make_date(v_year,v_month,1);
      v_days_in_month := extract(day FROM (v_month_start+interval '1 month'-interval '1 day'))::integer;
      v_birthday_date := make_date(v_year,v_month,least(v_day,v_days_in_month));

      -- Only credit on the birthday date itself, and only if the profile existed before that birthday.
      IF v_today = v_birthday_date AND v_created_local < v_birthday_date THEN
        SELECT * INTO v_reward FROM public.avopuntos_rewards
          WHERE code='birthday_celebration' AND active=true LIMIT 1;
        IF FOUND AND v_reward.points>0 THEN
          v_cycle_id := NULL;
          INSERT INTO public.avopuntos_annual_reward_cycles
            (profile_id,reward_code,cycle_year,points_granted,granted_at,expires_at,points_remaining)
          VALUES(p.id,'birthday_celebration',v_year,v_reward.points,v_now,v_now+interval '15 days',v_reward.points)
          ON CONFLICT(profile_id,reward_code,cycle_year) DO NOTHING
          RETURNING id INTO v_cycle_id;

          IF v_cycle_id IS NOT NULL THEN
            SELECT count(*) INTO v_occurrences FROM public.avopuntos_annual_reward_cycles
              WHERE profile_id=p.id AND reward_code='birthday_celebration';
            v_title := v_reward.name||repeat(' 🎂',v_occurrences::integer);
            v_source_key := 'annual_reward:birthday_celebration:'||p.id::text||':'||v_year::text;
            INSERT INTO public.avopuntos_movements(profile_id,movement_type,points_delta,source_key,details)
            VALUES(
              p.id,'earn',v_reward.points,v_source_key,
              jsonb_build_object(
                'title',v_title,'bonus_type','birthday_celebration',
                'reward_code','birthday_celebration','description',v_reward.description,
                'points_granted',v_reward.points,'cycle_year',v_year,
                'expires_at',v_now+interval '15 days'
              )
            ) ON CONFLICT(source_key) DO NOTHING;
            GET DIAGNOSTICS v_rows=ROW_COUNT;
            IF v_rows<>1 THEN RAISE EXCEPTION 'No fue posible registrar la celebración anual para el perfil %.',p.id; END IF;
            UPDATE public.avopuntos_accounts
              SET balance=balance+v_reward.points,updated_at=v_now
              WHERE profile_id=p.id
              RETURNING balance INTO v_balance;

            PERFORM public.avohouse_queue_achievement_award_email(
              v_source_key,
              p.id,
              'birthday_celebration',
              v_title,
              v_reward.description,
              v_reward.points,
              v_balance,
              v_now,
              v_now+interval '15 days'
            );

            v_granted_count := v_granted_count+1;
          END IF;
        END IF;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok',true,'granted',v_granted_count,'expired',v_expired_count,'checked_at',v_now);
END;
$function$
;
REVOKE ALL ON FUNCTION public.avopuntos_process_annual_reward_cycles() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.avopuntos_process_annual_reward_cycles() TO service_role;
