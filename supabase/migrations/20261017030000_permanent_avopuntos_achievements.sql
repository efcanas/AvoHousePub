-- Permanent AvoPuntos achievement rewards and automatic receipt-based evaluation.

ALTER TABLE public.avopuntos_rewards
  DROP CONSTRAINT IF EXISTS avopuntos_rewards_reward_type_check;
ALTER TABLE public.avopuntos_rewards
  ADD CONSTRAINT avopuntos_rewards_reward_type_check
  CHECK (reward_type = ANY (ARRAY['account','verification','campaign','contest','manual','achievement']::text[]));

INSERT INTO public.avopuntos_rewards
  (code,name,description,points,reward_type,verification_channel,active)
VALUES
  ('points_earned_2k','2K AvoPuntos','Alcanza los 2.000 AvoPuntos.',1000,'achievement',NULL,true),
  ('points_earned_10k','10K AvoPuntos','Alcanza los 10.000 AvoPuntos.',2000,'achievement',NULL,true),
  ('first_redemption','Primer movimiento','Realiza tu primer canje de AvoPuntos.',500,'achievement',NULL,true),
  ('points_redeemed_20k','AP en circulación','Haz circular 20.000 AvoPuntos.',1000,'achievement',NULL,true)
ON CONFLICT (code) DO UPDATE
SET name=EXCLUDED.name, description=EXCLUDED.description, points=EXCLUDED.points,
    reward_type=EXCLUDED.reward_type, verification_channel=NULL,
    active=true, updated_at=now();

CREATE OR REPLACE FUNCTION public.avopuntos_check_permanent_achievements(p_profile_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_created_at timestamptz;
  v_purchase_points bigint := 0;
  v_redeemed_points bigint := 0;
  v_goal record;
  v_reward public.avopuntos_rewards%rowtype;
  v_claim_id uuid;
  v_balance bigint;
  v_rows integer;
  v_progress bigint;
  v_granted jsonb := '[]'::jsonb;
BEGIN
  IF p_profile_id IS NULL THEN
    RETURN jsonb_build_object('ok',false,'reason','missing_profile');
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('avopuntos-permanent-achievements:'||p_profile_id::text,0));
  SELECT created_at INTO v_created_at FROM public.profiles WHERE id=p_profile_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'reason','profile_not_found');
  END IF;

  SELECT greatest(0,coalesce(sum(CASE
    WHEN r.receipt_type='SALE' AND r.cancelled_at IS NULL THEN greatest(coalesce(s.applied_earned_points,0),0)
    WHEN r.receipt_type='REFUND' AND r.cancelled_at IS NULL THEN -greatest(coalesce(s.applied_earned_points,0),0)
    ELSE 0 END),0))::bigint
  INTO v_purchase_points
  FROM public.avopuntos_receipt_state s
  JOIN public.loyverse_receipts r ON r.receipt_number=s.receipt_number
  WHERE s.profile_id=p_profile_id AND r.profile_id=p_profile_id AND s.status='processed'
    AND r.receipt_type IN ('SALE','REFUND')
    AND coalesce(r.receipt_date,r.created_at,r.updated_at)>=v_created_at;

  SELECT greatest(0,coalesce(sum(CASE
    WHEN r.receipt_type='SALE' AND r.cancelled_at IS NULL THEN greatest(coalesce(s.applied_redeemed_points,0),0)
    WHEN r.receipt_type='REFUND' AND r.cancelled_at IS NULL THEN -greatest(coalesce(s.applied_redeemed_points,0),0)
    ELSE 0 END),0))::bigint
  INTO v_redeemed_points
  FROM public.avopuntos_receipt_state s
  JOIN public.loyverse_receipts r ON r.receipt_number=s.receipt_number
  WHERE s.profile_id=p_profile_id AND r.profile_id=p_profile_id AND s.status='processed'
    AND r.receipt_type IN ('SALE','REFUND')
    AND coalesce(r.receipt_date,r.created_at,r.updated_at)>=v_created_at;

  FOR v_goal IN
    SELECT * FROM (VALUES
      (1,'points_earned_2k'::text,2000::bigint,'purchase'::text),
      (2,'points_earned_10k'::text,10000::bigint,'purchase'::text),
      (3,'first_redemption'::text,1::bigint,'redeem'::text),
      (4,'points_redeemed_20k'::text,20000::bigint,'redeem'::text)
    ) AS goals(sort_order,code,target_points,progress_type)
    ORDER BY sort_order
  LOOP
    v_progress := CASE WHEN v_goal.progress_type='purchase' THEN v_purchase_points ELSE v_redeemed_points END;
    IF v_progress < v_goal.target_points THEN CONTINUE; END IF;

    SELECT * INTO v_reward FROM public.avopuntos_rewards
    WHERE code=v_goal.code AND active=true LIMIT 1;
    IF NOT FOUND OR v_reward.points<=0 THEN CONTINUE; END IF;

    v_claim_id := NULL;
    INSERT INTO public.avopuntos_customer_rewards
      (profile_id,reward_id,status,points_granted,source_key,evidence,claimed_at,granted_by)
    VALUES
      (p_profile_id,v_reward.id,'claimed',v_reward.points,
       'reward:'||v_goal.code||':'||p_profile_id::text,
       jsonb_build_object('achievement_code',v_goal.code,'progress_type',v_goal.progress_type,
         'progress_at_unlock',v_progress,'target_points',v_goal.target_points),
       now(),NULL)
    ON CONFLICT (profile_id,reward_id) DO NOTHING
    RETURNING id INTO v_claim_id;
    IF v_claim_id IS NULL THEN CONTINUE; END IF;

    INSERT INTO public.avopuntos_movements
      (profile_id,movement_type,points_delta,source_key,details)
    VALUES
      (p_profile_id,'earn',v_reward.points,
       'achievement:'||v_goal.code||':'||p_profile_id::text,
       jsonb_build_object('title',v_reward.name,'bonus_type',v_goal.code,'reward_code',v_goal.code,
         'description',v_reward.description,'points_granted',v_reward.points,
         'progress_at_unlock',v_progress,'target_points',v_goal.target_points))
    ON CONFLICT (source_key) DO NOTHING;
    GET DIAGNOSTICS v_rows=ROW_COUNT;
    IF v_rows<>1 THEN
      RAISE EXCEPTION 'No fue posible registrar de forma única el abono del logro % para %.',v_goal.code,p_profile_id;
    END IF;

    INSERT INTO public.avopuntos_accounts(profile_id,balance)
    VALUES(p_profile_id,0) ON CONFLICT(profile_id) DO NOTHING;
    UPDATE public.avopuntos_accounts SET balance=balance+v_reward.points,updated_at=now()
    WHERE profile_id=p_profile_id RETURNING balance INTO v_balance;
    IF NOT FOUND THEN RAISE EXCEPTION 'No existe la cuenta AvoPuntos asociada al perfil %.',p_profile_id; END IF;
    v_granted := v_granted || jsonb_build_array(v_goal.code);
  END LOOP;

  RETURN jsonb_build_object('ok',true,'profile_id',p_profile_id,
    'purchase_points',v_purchase_points,'redeemed_points',v_redeemed_points,'granted',v_granted);
END;
$function$;

CREATE OR REPLACE FUNCTION public.avopuntos_trigger_permanent_achievements()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.status='processed' AND NEW.profile_id IS NOT NULL THEN
    PERFORM public.avopuntos_check_permanent_achievements(NEW.profile_id);
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.avopuntos_check_permanent_achievements(uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.avopuntos_trigger_permanent_achievements() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS trg_avopuntos_permanent_achievements ON public.avopuntos_receipt_state;
CREATE TRIGGER trg_avopuntos_permanent_achievements
AFTER INSERT OR UPDATE ON public.avopuntos_receipt_state
FOR EACH ROW EXECUTE FUNCTION public.avopuntos_trigger_permanent_achievements();

DO $backfill$
DECLARE v_profile record;
BEGIN
  FOR v_profile IN SELECT id FROM public.profiles ORDER BY created_at
  LOOP
    PERFORM public.avopuntos_check_permanent_achievements(v_profile.id);
  END LOOP;
END;
$backfill$;
