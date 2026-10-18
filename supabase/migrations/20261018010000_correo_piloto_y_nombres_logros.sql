-- Ajusta solo nombres/descripción de logros y activa el correo transaccional de Piloto.
-- No modifica los puntos ni las reglas que conceden Aniversario o HB.

UPDATE public.avopuntos_rewards
SET name = CASE code
      WHEN 'account_anniversary' THEN 'Aniversario'
      WHEN 'birthday_celebration' THEN 'HB'
      WHEN 'pilot_launch_2026' THEN 'Piloto'
      ELSE name
    END,
    description = CASE
      WHEN code = 'pilot_launch_2026' THEN 'Hasta el 31 de diciembre de 2026, obtienes AP×2 en tus compras elegibles.'
      ELSE description
    END,
    updated_at = now()
WHERE code IN ('account_anniversary','birthday_celebration','pilot_launch_2026');

CREATE OR REPLACE FUNCTION public.avohouse_queue_pilot_achievement_email(p_profile_id uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_profile public.profiles%rowtype;
  v_customer_name text;
  v_achievement_name text := 'Piloto';
  v_description text;
  v_award_date text;
  v_request_id bigint;
BEGIN
  IF p_profile_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_profile
  FROM public.profiles
  WHERE id = p_profile_id;

  IF NOT FOUND
     OR nullif(trim(coalesce(v_profile.email,'')), '') IS NULL
     OR v_profile.created_at IS NULL
     OR (v_profile.created_at AT TIME ZONE 'America/Bogota')::date > DATE '2026-12-31' THEN
    RETURN NULL;
  END IF;

  SELECT r.description INTO v_description
  FROM public.avopuntos_rewards r
  WHERE r.code = 'pilot_launch_2026' AND r.active = true
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_customer_name := coalesce(nullif(btrim(v_profile.full_name),''),'Cliente AvoHouse');
  v_customer_name := replace(replace(replace(replace(replace(v_customer_name,'&','&amp;'),'<','&lt;'),'>','&gt;'),'"','&quot;'),'''','&#39;');
  v_achievement_name := replace(replace(replace(replace(replace(v_achievement_name,'&','&amp;'),'<','&lt;'),'>','&gt;'),'"','&quot;'),'''','&#39;');
  v_description := coalesce(v_description,'');
  v_description := replace(replace(replace(replace(replace(v_description,'&','&amp;'),'<','&lt;'),'>','&gt;'),'"','&quot;'),'''','&#39;');
  v_award_date := 'Cuenta creada: ' ||
    to_char(v_profile.created_at AT TIME ZONE 'America/Bogota','DD/MM/YYYY HH24:MI') ||
    ' (hora de Colombia)';

  v_request_id := public.avohouse_queue_profile_email(
    'achievement-pilot-launch-2026:' || p_profile_id::text,
    p_profile_id,
    'achievement_awarded',
    'pilot_launch_2026',
    'a84c5bf3-0664-4d1c-a6a1-9ae2c586365a',
    jsonb_build_object(
      'CUSTOMER_NAME',v_customer_name,
      'ACHIEVEMENT_NAME',v_achievement_name,
      'ACHIEVEMENT_DESCRIPTION',v_description,
      'ACHIEVEMENT_IMAGE_URL','https://avohousepub.com/assets/logros-ah/piloto.svg?v=piloto-emblem-v1',
      'BENEFIT_VALUE','AP×2',
      'BENEFIT_DETAIL','Tus compras elegibles acumulan el doble de AvoPuntos.',
      'VALID_UNTIL','31 de diciembre de 2026',
      'AWARD_DATE',v_award_date,
      'ACHIEVEMENT_LINK','https://avohousepub.com/cuenta/mi-cuenta.html#specialAchievementsSection'
    )
  );

  RETURN v_request_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.avohouse_queue_pilot_achievement_email(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.avohouse_queue_pilot_achievement_email(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.avohouse_trigger_pilot_achievement_email()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.created_at IS NOT NULL
     AND (NEW.created_at AT TIME ZONE 'America/Bogota')::date <= DATE '2026-12-31' THEN
    PERFORM public.avohouse_queue_pilot_achievement_email(NEW.id);
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.avohouse_trigger_pilot_achievement_email() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_profiles_pilot_achievement_email ON public.profiles;
CREATE TRIGGER trg_profiles_pilot_achievement_email
AFTER INSERT ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.avohouse_trigger_pilot_achievement_email();

-- Backfill: notifica una sola vez a los perfiles ya elegibles cuando se habilita el logro.
DO $block$
DECLARE
  v_profile record;
BEGIN
  FOR v_profile IN
    SELECT p.id
    FROM public.profiles p
    WHERE p.created_at IS NOT NULL
      AND (p.created_at AT TIME ZONE 'America/Bogota')::date <= DATE '2026-12-31'
      AND nullif(trim(coalesce(p.email,'')), '') IS NOT NULL
  LOOP
    PERFORM public.avohouse_queue_pilot_achievement_email(v_profile.id);
  END LOOP;
END;
$block$;

-- La RPC muestra exactamente los nombres nuevos; los ciclos y puntos anuales no cambian.
CREATE OR REPLACE FUNCTION public.avopuntos_get_my_rewards_with_progress()
RETURNS TABLE(
  id uuid,
  code text,
  name text,
  description text,
  points bigint,
  reward_type text,
  verification_channel text,
  status text,
  points_granted bigint,
  claimed_at timestamp with time zone,
  verification_code text,
  progress_current bigint,
  progress_target bigint
)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH profile_context AS (
    SELECT p.id,p.created_at
    FROM public.profiles p
    WHERE p.id=auth.uid()
  ),
  receipt_progress AS (
    SELECT
      pc.id AS profile_id,
      pc.created_at AS profile_created_at,
      greatest(0,coalesce(sum(CASE
        WHEN r.receipt_type='SALE' AND r.cancelled_at IS NULL THEN greatest(coalesce(s.applied_earned_points,0),0)
        WHEN r.receipt_type='REFUND' AND r.cancelled_at IS NULL THEN -greatest(coalesce(s.applied_earned_points,0),0)
        ELSE 0 END),0))::bigint AS purchase_progress,
      greatest(0,coalesce(sum(CASE
        WHEN r.receipt_type='SALE' AND r.cancelled_at IS NULL THEN greatest(coalesce(s.applied_redeemed_points,0),0)
        WHEN r.receipt_type='REFUND' AND r.cancelled_at IS NULL THEN -greatest(coalesce(s.applied_redeemed_points,0),0)
        ELSE 0 END),0))::bigint AS redeemed_progress
    FROM profile_context pc
    LEFT JOIN public.avopuntos_receipt_state s
      ON s.profile_id=pc.id AND s.status='processed'
    LEFT JOIN public.loyverse_receipts r
      ON r.receipt_number=s.receipt_number
      AND r.profile_id=pc.id
      AND r.receipt_type IN ('SALE','REFUND')
      AND coalesce(r.receipt_date,r.created_at,r.updated_at)>=pc.created_at
    GROUP BY pc.id,pc.created_at
  ),
  latest_claim AS (
    SELECT DISTINCT ON (cr.reward_id)
      cr.reward_id,cr.status,cr.points_granted,cr.claimed_at
    FROM public.avopuntos_customer_rewards cr
    WHERE cr.profile_id=auth.uid()
    ORDER BY cr.reward_id,cr.created_at DESC
  ),
  latest_verification AS (
    SELECT DISTINCT ON (v.channel)
      v.channel,v.status,v.code,v.created_at
    FROM public.avopuntos_contact_verifications v
    WHERE v.profile_id=auth.uid()
      AND v.channel IN ('whatsapp','instagram','facebook')
    ORDER BY v.channel,v.created_at DESC
  ),
  annual_cycle_counts AS (
    SELECT c.reward_code,count(*)::bigint AS cycle_count
    FROM public.avopuntos_annual_reward_cycles c
    WHERE c.profile_id=auth.uid() AND c.status <> 'revoked'
    GROUP BY c.reward_code
  ),
  latest_annual_cycle AS (
    SELECT DISTINCT ON (c.reward_code)
      c.reward_code,c.points_granted,c.granted_at
    FROM public.avopuntos_annual_reward_cycles c
    WHERE c.profile_id=auth.uid() AND c.status <> 'revoked'
    ORDER BY c.reward_code,c.cycle_year DESC,c.granted_at DESC
  )
  SELECT
    r.id,
    r.code,
    r.name,
    r.description,
    r.points,
    r.reward_type,
    r.verification_channel,
    CASE
      WHEN r.code='pilot_launch_2026' THEN
        CASE
          WHEN (rp.profile_created_at AT TIME ZONE 'America/Bogota')::date <= DATE '2026-12-31' THEN 'claimed'
          ELSE 'revoked'
        END
      WHEN r.code IN ('account_anniversary','birthday_celebration')
        THEN CASE WHEN coalesce(acc.cycle_count,0)>0 THEN 'claimed' ELSE 'available' END
      WHEN lc.status='claimed' THEN 'claimed'
      WHEN lc.status='available' THEN 'available'
      WHEN lv.status='pending' THEN 'pending'
      ELSE 'available'
    END AS status,
    CASE WHEN r.code IN ('account_anniversary','birthday_celebration')
      THEN coalesce(lac.points_granted,0)
      ELSE coalesce(lc.points_granted,0)
    END AS points_granted,
    CASE
      WHEN r.code='pilot_launch_2026' THEN
        CASE
          WHEN (rp.profile_created_at AT TIME ZONE 'America/Bogota')::date <= DATE '2026-12-31' THEN rp.profile_created_at
          ELSE NULL
        END
      WHEN r.code IN ('account_anniversary','birthday_celebration') THEN lac.granted_at
      ELSE lc.claimed_at
    END AS claimed_at,
    CASE
      WHEN lv.status='pending' AND r.verification_channel IN ('whatsapp','instagram','facebook')
        THEN lv.code
      ELSE NULL
    END AS verification_code,
    CASE r.code
      WHEN 'points_earned_2k' THEN least(coalesce(rp.purchase_progress,0),2000)::bigint
      WHEN 'points_earned_10k' THEN least(coalesce(rp.purchase_progress,0),10000)::bigint
      WHEN 'points_redeemed_20k' THEN least(coalesce(rp.redeemed_progress,0),25000)::bigint
      ELSE NULL
    END AS progress_current,
    CASE r.code
      WHEN 'points_earned_2k' THEN 2000::bigint
      WHEN 'points_earned_10k' THEN 10000::bigint
      WHEN 'points_redeemed_20k' THEN 25000::bigint
      ELSE NULL
    END AS progress_target
  FROM public.avopuntos_rewards r
  CROSS JOIN receipt_progress rp
  LEFT JOIN latest_claim lc ON lc.reward_id=r.id
  LEFT JOIN latest_verification lv ON lv.channel=r.verification_channel
  LEFT JOIN annual_cycle_counts acc ON acc.reward_code=r.code
  LEFT JOIN latest_annual_cycle lac ON lac.reward_code=r.code
  WHERE r.active=true
  ORDER BY CASE r.reward_type WHEN 'account' THEN 1 WHEN 'verification' THEN 2 ELSE 3 END,r.created_at;
$function$;

-- Conserva intactos los abonos y reglas de vigencia; solo usa el nuevo nombre en movimientos/correos.
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
            v_title := v_reward.name;
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
            v_title := v_reward.name;
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
