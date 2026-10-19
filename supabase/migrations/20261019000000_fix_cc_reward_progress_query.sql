CREATE OR REPLACE FUNCTION public.avopuntos_admin_get_customer_rewards_with_progress(p_profile_id uuid)
 RETURNS TABLE(id uuid, code text, name text, description text, points bigint, reward_type text, verification_channel text, status text, points_granted bigint, claimed_at timestamp with time zone, verification_code text, progress_current bigint, progress_target bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.uid() IS NULL OR NOT public.avopuntos_admin_is_admin() THEN
    RAISE EXCEPTION 'No tienes permisos para consultar recompensas.';
  END IF;
  IF p_profile_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = p_profile_id) THEN
    RAISE EXCEPTION 'No existe el cliente seleccionado.';
  END IF;

  RETURN QUERY
  WITH profile_context AS (
    SELECT p.id, p.created_at FROM public.profiles p WHERE p.id = p_profile_id
  ),
  receipt_progress AS (
    SELECT
      pc.id AS profile_id, pc.created_at AS profile_created_at,
      greatest(0, coalesce(sum(CASE
        WHEN receipt.receipt_type = 'SALE' AND receipt.cancelled_at IS NULL THEN greatest(coalesce(s.applied_earned_points, 0), 0)
        WHEN receipt.receipt_type = 'REFUND' AND receipt.cancelled_at IS NULL THEN -greatest(coalesce(s.applied_earned_points, 0), 0)
        ELSE 0 END), 0))::bigint AS purchase_progress,
      greatest(0, coalesce(sum(CASE
        WHEN receipt.receipt_type = 'SALE' AND receipt.cancelled_at IS NULL THEN greatest(coalesce(s.applied_redeemed_points, 0), 0)
        WHEN receipt.receipt_type = 'REFUND' AND receipt.cancelled_at IS NULL THEN -greatest(coalesce(s.applied_redeemed_points, 0), 0)
        ELSE 0 END), 0))::bigint AS redeemed_progress
    FROM profile_context pc
    LEFT JOIN public.avopuntos_receipt_state s ON s.profile_id = pc.id AND s.status = 'processed'
    LEFT JOIN public.loyverse_receipts receipt
      ON receipt.receipt_number = s.receipt_number
      AND receipt.profile_id = pc.id
      AND receipt.receipt_type IN ('SALE', 'REFUND')
      AND coalesce(receipt.receipt_date, receipt.created_at, receipt.updated_at) >= pc.created_at
    GROUP BY pc.id, pc.created_at
  ),
  latest_claim AS (
    SELECT DISTINCT ON (cr.reward_id) cr.reward_id, cr.status, cr.points_granted, cr.claimed_at
    FROM public.avopuntos_customer_rewards cr
    WHERE cr.profile_id = p_profile_id
    ORDER BY cr.reward_id, cr.created_at DESC
  ),
  latest_verification AS (
    SELECT DISTINCT ON (v.channel) v.channel, v.status, v.code, v.created_at
    FROM public.avopuntos_contact_verifications v
    WHERE v.profile_id = p_profile_id AND v.channel IN ('whatsapp', 'instagram', 'facebook')
    ORDER BY v.channel, v.created_at DESC
  ),
  annual_cycle_counts AS (
    SELECT c.reward_code, count(*)::bigint AS cycle_count
    FROM public.avopuntos_annual_reward_cycles c
    WHERE c.profile_id = p_profile_id AND c.status <> 'revoked'
    GROUP BY c.reward_code
  ),
  latest_annual_cycle AS (
    SELECT DISTINCT ON (c.reward_code) c.reward_code, c.points_granted, c.granted_at
    FROM public.avopuntos_annual_reward_cycles c
    WHERE c.profile_id = p_profile_id AND c.status <> 'revoked'
    ORDER BY c.reward_code, c.cycle_year DESC, c.granted_at DESC
  )
  SELECT
    reward.id, reward.code, reward.name, reward.description, reward.points::bigint,
    reward.reward_type, reward.verification_channel,
    CASE
      WHEN reward.code = 'pilot_launch_2026' THEN
        CASE WHEN (rp.profile_created_at AT TIME ZONE 'America/Bogota')::date <= DATE '2026-12-31' THEN 'claimed' ELSE 'revoked' END
      WHEN reward.code IN ('account_anniversary', 'birthday_celebration')
        THEN CASE WHEN coalesce(acc.cycle_count, 0) > 0 THEN 'claimed' ELSE 'available' END
      WHEN lc.status = 'claimed' THEN 'claimed'
      WHEN lc.status = 'available' THEN 'available'
      WHEN lv.status = 'pending' THEN 'pending'
      ELSE 'available'
    END AS status,
    CASE WHEN reward.code IN ('account_anniversary', 'birthday_celebration')
      THEN coalesce(lac.points_granted, 0) ELSE coalesce(lc.points_granted, 0) END AS points_granted,
    CASE
      WHEN reward.code = 'pilot_launch_2026' THEN
        CASE WHEN (rp.profile_created_at AT TIME ZONE 'America/Bogota')::date <= DATE '2026-12-31' THEN rp.profile_created_at ELSE NULL END
      WHEN reward.code IN ('account_anniversary', 'birthday_celebration') THEN lac.granted_at
      ELSE lc.claimed_at
    END AS claimed_at,
    CASE
      WHEN lv.status = 'pending' AND reward.verification_channel IN ('whatsapp', 'instagram', 'facebook') THEN lv.code
      ELSE NULL
    END AS verification_code,
    CASE reward.code
      WHEN 'points_earned_2k' THEN least(coalesce(rp.purchase_progress, 0), 2000)::bigint
      WHEN 'points_earned_10k' THEN least(coalesce(rp.purchase_progress, 0), 10000)::bigint
      WHEN 'points_redeemed_20k' THEN least(coalesce(rp.redeemed_progress, 0), 25000)::bigint
      ELSE NULL
    END AS progress_current,
    CASE reward.code
      WHEN 'points_earned_2k' THEN 2000::bigint
      WHEN 'points_earned_10k' THEN 10000::bigint
      WHEN 'points_redeemed_20k' THEN 25000::bigint
      ELSE NULL
    END AS progress_target
  FROM public.avopuntos_rewards reward
  CROSS JOIN receipt_progress rp
  LEFT JOIN latest_claim lc ON lc.reward_id = reward.id
  LEFT JOIN latest_verification lv ON lv.channel = reward.verification_channel
  LEFT JOIN annual_cycle_counts acc ON acc.reward_code = reward.code
  LEFT JOIN latest_annual_cycle lac ON lac.reward_code = reward.code
  WHERE reward.active = true
  ORDER BY CASE reward.reward_type WHEN 'account' THEN 1 WHEN 'verification' THEN 2 ELSE 3 END, reward.created_at;
END;
$function$


REVOKE ALL ON FUNCTION public.avopuntos_admin_get_customer_rewards_with_progress(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.avopuntos_admin_get_customer_rewards_with_progress(uuid) TO authenticated;
