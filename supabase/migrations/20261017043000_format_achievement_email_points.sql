-- Format AP values in emails using Colombian thousands separators.
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
  v_points_awarded_text text;
  v_points_balance_text text;
  v_request_id bigint;
BEGIN
  IF p_event_key IS NULL OR btrim(p_event_key)='' OR p_profile_id IS NULL
     OR p_points_awarded IS NULL OR p_points_awarded<=0
     OR p_reward_code IS NULL OR p_reward_code NOT IN (
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

  v_points_awarded_text := replace(to_char(p_points_awarded,'FM999G999G999G999G999'),',','.');
  v_points_balance_text := replace(to_char(coalesce(p_points_balance,0),'FM999G999G999G999G999'),',','.');

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
      'POINTS_AWARDED',v_points_awarded_text,
      'POINTS_BALANCE',v_points_balance_text,
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
