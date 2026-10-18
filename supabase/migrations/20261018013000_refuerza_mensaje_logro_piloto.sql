-- Refuerza el agradecimiento del logro Piloto en la ficha y en el correo.
-- No cambia la vigencia ni el cálculo del beneficio AP×2.
UPDATE public.avopuntos_rewards
SET description = '¡Gracias por ser parte del plan piloto! Por acompañarnos en esta primera etapa de AvoHousePub.com, tus compras elegibles acumulan el doble de AvoPuntos (AP×2) hasta el 31 de diciembre de 2026.',
    updated_at = now()
WHERE code = 'pilot_launch_2026';

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
      'BENEFIT_DETAIL','Como agradecimiento por ser parte del plan piloto, tus compras elegibles acumulan el doble de AvoPuntos.',
      'VALID_UNTIL','31 de diciembre de 2026',
      'AWARD_DATE',v_award_date,
      'ACHIEVEMENT_LINK','https://avohousepub.com/cuenta/mi-cuenta.html#specialAchievementsSection'
    )
  );

  RETURN v_request_id;
END;
$function$;
