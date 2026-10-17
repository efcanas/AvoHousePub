-- Expose server-calculated progress for the three cumulative AvoPuntos achievements.
-- Counts use the same receipt-state basis and account-created-at cutoff as automatic rewards.

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
  claimed_at timestamptz,
  verification_code text,
  progress_current bigint,
  progress_target bigint
)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH profile_context AS (
    SELECT p.id, p.created_at
    FROM public.profiles p
    WHERE p.id = auth.uid()
  ),
  receipt_progress AS (
    SELECT
      pc.id AS profile_id,
      greatest(0, coalesce(sum(
        CASE
          WHEN r.receipt_type = 'SALE' AND r.cancelled_at IS NULL
            THEN greatest(coalesce(s.applied_earned_points, 0), 0)
          WHEN r.receipt_type = 'REFUND' AND r.cancelled_at IS NULL
            THEN -greatest(coalesce(s.applied_earned_points, 0), 0)
          ELSE 0
        END
      ), 0))::bigint AS purchase_progress,
      greatest(0, coalesce(sum(
        CASE
          WHEN r.receipt_type = 'SALE' AND r.cancelled_at IS NULL
            THEN greatest(coalesce(s.applied_redeemed_points, 0), 0)
          WHEN r.receipt_type = 'REFUND' AND r.cancelled_at IS NULL
            THEN -greatest(coalesce(s.applied_redeemed_points, 0), 0)
          ELSE 0
        END
      ), 0))::bigint AS redeemed_progress
    FROM profile_context pc
    LEFT JOIN public.avopuntos_receipt_state s
      ON s.profile_id = pc.id
     AND s.status = 'processed'
    LEFT JOIN public.loyverse_receipts r
      ON r.receipt_number = s.receipt_number
     AND r.profile_id = pc.id
     AND r.receipt_type IN ('SALE', 'REFUND')
     AND coalesce(r.receipt_date, r.created_at, r.updated_at) >= pc.created_at
    GROUP BY pc.id
  ),
  latest_claim AS (
    SELECT DISTINCT ON (cr.reward_id)
      cr.reward_id, cr.status, cr.points_granted, cr.claimed_at
    FROM public.avopuntos_customer_rewards cr
    WHERE cr.profile_id = auth.uid()
    ORDER BY cr.reward_id, cr.created_at DESC
  ),
  latest_verification AS (
    SELECT DISTINCT ON (v.channel)
      v.channel, v.status, v.code, v.created_at
    FROM public.avopuntos_contact_verifications v
    WHERE v.profile_id = auth.uid()
      AND v.channel IN ('whatsapp', 'instagram', 'facebook')
    ORDER BY v.channel, v.created_at DESC
  )
  SELECT
    r.id, r.code, r.name, r.description, r.points, r.reward_type,
    r.verification_channel,
    CASE
      WHEN lc.status = 'claimed' THEN 'claimed'
      WHEN lc.status = 'available' THEN 'available'
      WHEN lv.status = 'pending' THEN 'pending'
      ELSE 'available'
    END AS status,
    coalesce(lc.points_granted, 0) AS points_granted,
    lc.claimed_at,
    CASE
      WHEN lv.status = 'pending'
       AND r.verification_channel IN ('whatsapp', 'instagram', 'facebook')
        THEN lv.code
      ELSE NULL
    END AS verification_code,
    CASE r.code
      WHEN 'points_earned_2k' THEN least(coalesce(rp.purchase_progress, 0), 2000)::bigint
      WHEN 'points_earned_10k' THEN least(coalesce(rp.purchase_progress, 0), 10000)::bigint
      WHEN 'points_redeemed_20k' THEN least(coalesce(rp.redeemed_progress, 0), 20000)::bigint
      ELSE NULL
    END AS progress_current,
    CASE r.code
      WHEN 'points_earned_2k' THEN 2000::bigint
      WHEN 'points_earned_10k' THEN 10000::bigint
      WHEN 'points_redeemed_20k' THEN 20000::bigint
      ELSE NULL
    END AS progress_target
  FROM public.avopuntos_rewards r
  CROSS JOIN receipt_progress rp
  LEFT JOIN latest_claim lc ON lc.reward_id = r.id
  LEFT JOIN latest_verification lv ON lv.channel = r.verification_channel
  WHERE r.active = true
  ORDER BY CASE r.reward_type WHEN 'account' THEN 1 WHEN 'verification' THEN 2 ELSE 3 END,
           r.created_at;
$function$;

REVOKE ALL ON FUNCTION public.avopuntos_get_my_rewards_with_progress() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.avopuntos_get_my_rewards_with_progress() TO authenticated;
