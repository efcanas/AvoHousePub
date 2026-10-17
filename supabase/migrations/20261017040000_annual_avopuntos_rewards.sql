-- Recurring annual AvoPuntos rewards, birthday-expiry lots and cake-count achievement names.

INSERT INTO public.avopuntos_rewards
  (code, name, description, points, reward_type, verification_channel, active)
VALUES
  ('account_anniversary','Aniversario AvoHouse','Cada año, en el aniversario de creación de tu cuenta, recibes +5.000 AvoPuntos.',5000,'achievement',NULL,true),
  ('birthday_celebration','Celebración AvoHouse','Recibes +10.000 AvoPuntos por tu cumpleaños. Tienes 15 días desde la acreditación para usarlos; los puntos que queden se revierten automáticamente.',10000,'achievement',NULL,true)
ON CONFLICT (code) DO UPDATE
SET name=EXCLUDED.name, description=EXCLUDED.description, points=EXCLUDED.points,
    reward_type=EXCLUDED.reward_type, verification_channel=NULL, active=true, updated_at=now();

CREATE TABLE IF NOT EXISTS public.avopuntos_annual_reward_cycles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  reward_code text NOT NULL CHECK (reward_code IN ('account_anniversary','birthday_celebration')),
  cycle_year integer NOT NULL CHECK (cycle_year >= 2020),
  points_granted bigint NOT NULL CHECK (points_granted > 0),
  granted_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz,
  points_remaining bigint,
  points_expired bigint NOT NULL DEFAULT 0 CHECK (points_expired >= 0),
  points_shortfall bigint NOT NULL DEFAULT 0 CHECK (points_shortfall >= 0),
  status text NOT NULL DEFAULT 'granted' CHECK (status IN ('granted','expired')),
  expired_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT avopuntos_annual_reward_cycles_profile_code_year_key UNIQUE (profile_id,reward_code,cycle_year),
  CONSTRAINT avopuntos_annual_reward_cycles_type_fields_check CHECK (
    (reward_code='account_anniversary' AND expires_at IS NULL AND points_remaining IS NULL)
    OR
    (reward_code='birthday_celebration' AND expires_at IS NOT NULL
      AND points_remaining IS NOT NULL AND points_remaining>=0 AND points_remaining<=points_granted)
  )
);

CREATE INDEX IF NOT EXISTS idx_avopuntos_annual_reward_cycles_due
  ON public.avopuntos_annual_reward_cycles (expires_at,profile_id)
  WHERE reward_code='birthday_celebration' AND status='granted';
CREATE INDEX IF NOT EXISTS idx_avopuntos_annual_reward_cycles_profile_code
  ON public.avopuntos_annual_reward_cycles (profile_id,reward_code,cycle_year DESC);

CREATE TABLE IF NOT EXISTS public.avopuntos_annual_reward_lot_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  movement_id uuid NOT NULL REFERENCES public.avopuntos_movements(id) ON DELETE CASCADE,
  profile_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  receipt_number text NOT NULL,
  cycle_id uuid NOT NULL REFERENCES public.avopuntos_annual_reward_cycles(id) ON DELETE CASCADE,
  points_consumed bigint NOT NULL CHECK (points_consumed > 0),
  points_restored bigint NOT NULL DEFAULT 0 CHECK (points_restored>=0 AND points_restored<=points_consumed),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT avopuntos_annual_reward_lot_allocations_movement_cycle_key UNIQUE (movement_id,cycle_id)
);
CREATE INDEX IF NOT EXISTS idx_avopuntos_annual_reward_allocations_receipt
  ON public.avopuntos_annual_reward_lot_allocations (profile_id,receipt_number);

CREATE TABLE IF NOT EXISTS public.avopuntos_annual_reward_lot_restorations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  movement_id uuid NOT NULL REFERENCES public.avopuntos_movements(id) ON DELETE CASCADE,
  allocation_id uuid NOT NULL REFERENCES public.avopuntos_annual_reward_lot_allocations(id) ON DELETE CASCADE,
  points_restored bigint NOT NULL CHECK (points_restored>0),
  points_reversed bigint NOT NULL DEFAULT 0 CHECK (points_reversed>=0 AND points_reversed<=points_restored),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT avopuntos_annual_reward_lot_restorations_movement_allocation_key UNIQUE (movement_id,allocation_id)
);

ALTER TABLE public.avopuntos_annual_reward_cycles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.avopuntos_annual_reward_lot_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.avopuntos_annual_reward_lot_restorations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.avopuntos_annual_reward_cycles FROM PUBLIC,anon,authenticated;
REVOKE ALL ON TABLE public.avopuntos_annual_reward_lot_allocations FROM PUBLIC,anon,authenticated;
REVOKE ALL ON TABLE public.avopuntos_annual_reward_lot_restorations FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.avopuntos_track_birthday_point_lots()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_amount bigint := 0;
  v_left bigint := 0;
  v_take bigint := 0;
  v_origin_receipt text;
  v_original_points bigint := 0;
  v_prior_refunded bigint := 0;
  v_remaining_base bigint := 0;
  v_unrestored bigint := 0;
  v_restore_total bigint := 0;
  v_item record;
BEGIN
  IF NEW.profile_id IS NULL OR NEW.points_delta=0 THEN RETURN NEW; END IF;

  IF NEW.movement_type='redeem' AND NEW.points_delta<0 THEN
    v_amount := abs(NEW.points_delta);

    IF lower(coalesce(NEW.details->>'refund_cancellation','false'))='true' THEN
      IF NEW.receipt_number IS NULL THEN RETURN NEW; END IF;
      FOR v_item IN
        SELECT rs.id AS restoration_id, rs.points_restored-rs.points_reversed AS still_restored,
               a.id AS allocation_id, c.id AS cycle_id
        FROM public.avopuntos_annual_reward_lot_restorations rs
        JOIN public.avopuntos_movements original_movement ON original_movement.id=rs.movement_id
        JOIN public.avopuntos_annual_reward_lot_allocations a ON a.id=rs.allocation_id
        JOIN public.avopuntos_annual_reward_cycles c ON c.id=a.cycle_id
        WHERE original_movement.receipt_number=NEW.receipt_number
          AND original_movement.movement_type='redeem_reversal'
          AND original_movement.details ? 'refund_for'
          AND rs.points_restored>rs.points_reversed
        ORDER BY c.expires_at ASC, rs.created_at DESC
        FOR UPDATE OF rs,a,c
      LOOP
        EXIT WHEN v_amount<=0;
        v_take := least(v_amount,v_item.still_restored);
        UPDATE public.avopuntos_annual_reward_lot_restorations
          SET points_reversed=points_reversed+v_take,updated_at=now()
          WHERE id=v_item.restoration_id;
        UPDATE public.avopuntos_annual_reward_lot_allocations
          SET points_restored=greatest(0,points_restored-v_take)
          WHERE id=v_item.allocation_id;
        UPDATE public.avopuntos_annual_reward_cycles
          SET points_remaining=greatest(0,points_remaining-v_take),updated_at=now()
          WHERE id=v_item.cycle_id AND reward_code='birthday_celebration'
            AND status='granted' AND expires_at>now();
        v_amount := v_amount-v_take;
      END LOOP;
      RETURN NEW;
    END IF;

    IF NEW.receipt_number IS NULL THEN RETURN NEW; END IF;
    FOR v_item IN
      SELECT c.id AS cycle_id,c.points_remaining
      FROM public.avopuntos_annual_reward_cycles c
      WHERE c.profile_id=NEW.profile_id AND c.reward_code='birthday_celebration'
        AND c.status='granted' AND c.expires_at>now() AND c.points_remaining>0
      ORDER BY c.expires_at ASC,c.granted_at ASC
      FOR UPDATE OF c
    LOOP
      EXIT WHEN v_amount<=0;
      v_take := least(v_amount,v_item.points_remaining);
      IF v_take>0 THEN
        INSERT INTO public.avopuntos_annual_reward_lot_allocations
          (movement_id,profile_id,receipt_number,cycle_id,points_consumed)
        VALUES (NEW.id,NEW.profile_id,NEW.receipt_number,v_item.cycle_id,v_take);
        UPDATE public.avopuntos_annual_reward_cycles
          SET points_remaining=points_remaining-v_take,updated_at=now()
          WHERE id=v_item.cycle_id;
        v_amount := v_amount-v_take;
      END IF;
    END LOOP;
    RETURN NEW;
  END IF;

  IF NEW.movement_type='redeem_reversal' AND NEW.points_delta>0 THEN
    v_origin_receipt := coalesce(NEW.related_receipt_number,NEW.receipt_number);
    IF v_origin_receipt IS NULL THEN RETURN NEW; END IF;

    SELECT greatest(coalesce(s.applied_redeemed_points,0),0)
      INTO v_original_points
    FROM public.avopuntos_receipt_state s
    WHERE s.receipt_number=v_origin_receipt;

    IF coalesce(NEW.related_receipt_number,'')<>'' THEN
      SELECT coalesce(sum(greatest(coalesce(refund_state.applied_redeemed_points,0),0)),0)
        INTO v_prior_refunded
      FROM public.avopuntos_receipt_state refund_state
      JOIN public.loyverse_receipts refund_receipt
        ON refund_receipt.receipt_number=refund_state.receipt_number
      WHERE refund_receipt.receipt_type='REFUND'
        AND refund_receipt.refund_for=v_origin_receipt
        AND refund_state.status='processed';
      v_remaining_base := greatest(v_original_points-v_prior_refunded,0);
    ELSE
      v_remaining_base := v_original_points;
    END IF;

    SELECT coalesce(sum(a.points_consumed-a.points_restored),0)
      INTO v_unrestored
    FROM public.avopuntos_annual_reward_lot_allocations a
    WHERE a.profile_id=NEW.profile_id AND a.receipt_number=v_origin_receipt;

    IF v_unrestored<=0 OR v_remaining_base<=0 THEN RETURN NEW; END IF;

    v_restore_total := least(v_unrestored,round(NEW.points_delta::numeric*v_unrestored/v_remaining_base)::bigint);
    v_left := v_restore_total;

    FOR v_item IN
      SELECT a.id AS allocation_id,a.points_consumed-a.points_restored AS available_to_restore,
             c.id AS cycle_id
      FROM public.avopuntos_annual_reward_lot_allocations a
      JOIN public.avopuntos_annual_reward_cycles c ON c.id=a.cycle_id
      WHERE a.profile_id=NEW.profile_id AND a.receipt_number=v_origin_receipt
        AND a.points_consumed>a.points_restored
      ORDER BY c.expires_at DESC,a.created_at DESC
      FOR UPDATE OF a,c
    LOOP
      EXIT WHEN v_left<=0;
      v_take := least(v_left,v_item.available_to_restore);
      IF v_take>0 THEN
        UPDATE public.avopuntos_annual_reward_lot_allocations
          SET points_restored=points_restored+v_take WHERE id=v_item.allocation_id;
        INSERT INTO public.avopuntos_annual_reward_lot_restorations
          (movement_id,allocation_id,points_restored)
        VALUES (NEW.id,v_item.allocation_id,v_take);
        UPDATE public.avopuntos_annual_reward_cycles
          SET points_remaining=least(points_granted,points_remaining+v_take),updated_at=now()
          WHERE id=v_item.cycle_id AND reward_code='birthday_celebration'
            AND status='granted' AND expires_at>now();
        v_left := v_left-v_take;
      END IF;
    END LOOP;
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.avopuntos_track_birthday_point_lots() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS trg_avopuntos_track_birthday_point_lots ON public.avopuntos_movements;
CREATE TRIGGER trg_avopuntos_track_birthday_point_lots
AFTER INSERT ON public.avopuntos_movements
FOR EACH ROW EXECUTE FUNCTION public.avopuntos_track_birthday_point_lots();

CREATE OR REPLACE FUNCTION public.avopuntos_process_annual_reward_cycles()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
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
            UPDATE public.avopuntos_accounts SET balance=balance+v_reward.points,updated_at=v_now WHERE profile_id=p.id;
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

      IF v_today>=v_birthday_date AND v_today<=v_birthday_date+15 THEN
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
            UPDATE public.avopuntos_accounts SET balance=balance+v_reward.points,updated_at=v_now WHERE profile_id=p.id;
            v_granted_count := v_granted_count+1;
          END IF;
        END IF;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok',true,'granted',v_granted_count,'expired',v_expired_count,'checked_at',v_now);
END;
$function$;

REVOKE ALL ON FUNCTION public.avopuntos_process_annual_reward_cycles() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.avopuntos_process_annual_reward_cycles() TO service_role;

DO $schedule$
DECLARE v_job_id bigint;
BEGIN
  FOR v_job_id IN SELECT jobid FROM cron.job WHERE jobname='avohouse_annual_avopuntos_rewards'
  LOOP
    PERFORM cron.unschedule(v_job_id);
  END LOOP;
  PERFORM cron.schedule(
    'avohouse_annual_avopuntos_rewards',
    '5 * * * *',
    'SELECT public.avopuntos_process_annual_reward_cycles();'
  );
END;
$schedule$;

CREATE OR REPLACE FUNCTION public.avopuntos_get_my_rewards_with_progress()
RETURNS TABLE(
  id uuid, code text, name text, description text, points bigint, reward_type text,
  verification_channel text, status text, points_granted bigint, claimed_at timestamptz,
  verification_code text, progress_current bigint, progress_target bigint
)
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $function$
  WITH profile_context AS (
    SELECT p.id,p.created_at FROM public.profiles p WHERE p.id=auth.uid()
  ),
  receipt_progress AS (
    SELECT
      pc.id AS profile_id,
      greatest(0,coalesce(sum(CASE
        WHEN r.receipt_type='SALE' AND r.cancelled_at IS NULL THEN greatest(coalesce(s.applied_earned_points,0),0)
        WHEN r.receipt_type='REFUND' AND r.cancelled_at IS NULL THEN -greatest(coalesce(s.applied_earned_points,0),0)
        ELSE 0 END),0))::bigint AS purchase_progress,
      greatest(0,coalesce(sum(CASE
        WHEN r.receipt_type='SALE' AND r.cancelled_at IS NULL THEN greatest(coalesce(s.applied_redeemed_points,0),0)
        WHEN r.receipt_type='REFUND' AND r.cancelled_at IS NULL THEN -greatest(coalesce(s.applied_redeemed_points,0),0)
        ELSE 0 END),0))::bigint AS redeemed_progress
    FROM profile_context pc
    LEFT JOIN public.avopuntos_receipt_state s ON s.profile_id=pc.id AND s.status='processed'
    LEFT JOIN public.loyverse_receipts r
      ON r.receipt_number=s.receipt_number AND r.profile_id=pc.id
      AND r.receipt_type IN ('SALE','REFUND')
      AND coalesce(r.receipt_date,r.created_at,r.updated_at)>=pc.created_at
    GROUP BY pc.id
  ),
  latest_claim AS (
    SELECT DISTINCT ON (cr.reward_id) cr.reward_id,cr.status,cr.points_granted,cr.claimed_at
    FROM public.avopuntos_customer_rewards cr WHERE cr.profile_id=auth.uid()
    ORDER BY cr.reward_id,cr.created_at DESC
  ),
  latest_verification AS (
    SELECT DISTINCT ON (v.channel) v.channel,v.status,v.code,v.created_at
    FROM public.avopuntos_contact_verifications v
    WHERE v.profile_id=auth.uid() AND v.channel IN ('whatsapp','instagram','facebook')
    ORDER BY v.channel,v.created_at DESC
  ),
  annual_cycle_counts AS (
    SELECT c.reward_code,count(*)::bigint AS cycle_count
    FROM public.avopuntos_annual_reward_cycles c
    WHERE c.profile_id=auth.uid()
    GROUP BY c.reward_code
  ),
  latest_annual_cycle AS (
    SELECT DISTINCT ON (c.reward_code) c.reward_code,c.points_granted,c.granted_at
    FROM public.avopuntos_annual_reward_cycles c
    WHERE c.profile_id=auth.uid()
    ORDER BY c.reward_code,c.cycle_year DESC,c.granted_at DESC
  )
  SELECT
    r.id,
    r.code,
    CASE WHEN r.code IN ('account_anniversary','birthday_celebration')
      THEN r.name||repeat(' 🎂',coalesce(acc.cycle_count,0)::integer) ELSE r.name END AS name,
    r.description,
    r.points,
    r.reward_type,
    r.verification_channel,
    CASE
      WHEN r.code IN ('account_anniversary','birthday_celebration')
        THEN CASE WHEN coalesce(acc.cycle_count,0)>0 THEN 'claimed' ELSE 'available' END
      WHEN lc.status='claimed' THEN 'claimed'
      WHEN lc.status='available' THEN 'available'
      WHEN lv.status='pending' THEN 'pending'
      ELSE 'available'
    END AS status,
    CASE WHEN r.code IN ('account_anniversary','birthday_celebration')
      THEN coalesce(lac.points_granted,0) ELSE coalesce(lc.points_granted,0) END AS points_granted,
    CASE WHEN r.code IN ('account_anniversary','birthday_celebration')
      THEN lac.granted_at ELSE lc.claimed_at END AS claimed_at,
    CASE WHEN lv.status='pending' AND r.verification_channel IN ('whatsapp','instagram','facebook')
      THEN lv.code ELSE NULL END AS verification_code,
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

REVOKE ALL ON FUNCTION public.avopuntos_get_my_rewards_with_progress() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.avopuntos_get_my_rewards_with_progress() TO authenticated;
