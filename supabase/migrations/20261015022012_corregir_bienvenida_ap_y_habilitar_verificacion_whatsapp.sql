UPDATE public.avopuntos_rewards
SET points = 1000, active = true
WHERE code = 'account_created';

CREATE OR REPLACE FUNCTION public.avopuntos_grant_account_creation_reward()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_reward public.avopuntos_rewards%rowtype;
  v_source_key text;
  v_rows integer := 0;
BEGIN
  SELECT *
    INTO v_reward
  FROM public.avopuntos_rewards
  WHERE code = 'account_created'
    AND active = true
  ORDER BY created_at
  LIMIT 1;

  IF NOT FOUND OR coalesce(v_reward.points, 0) <= 0 THEN
    RETURN new;
  END IF;

  v_source_key := 'reward:account_created:' || new.id::text;

  -- Asegura que exista la cuenta antes de registrar y acreditar la bonificación.
  INSERT INTO public.avopuntos_accounts (profile_id, balance)
  VALUES (new.id, 0)
  ON CONFLICT (profile_id) DO NOTHING;

  -- Conserva la recompensa en el catálogo personal sin dejarla marcada con cero puntos.
  INSERT INTO public.avopuntos_customer_rewards AS current_reward
    (profile_id, reward_id, status, points_granted, source_key, evidence, claimed_at)
  VALUES
    (
      new.id,
      v_reward.id,
      'claimed',
      v_reward.points,
      v_source_key,
      jsonb_build_object(
        'reward_code', v_reward.code,
        'description', 'Bonificación de bienvenida por crear una cuenta AvoHouse'
      ),
      now()
    )
  ON CONFLICT (profile_id, reward_id) DO UPDATE
  SET status = 'claimed',
      points_granted = greatest(coalesce(current_reward.points_granted, 0), excluded.points_granted),
      source_key = excluded.source_key,
      evidence = coalesce(current_reward.evidence, '{}'::jsonb) || excluded.evidence,
      claimed_at = coalesce(current_reward.claimed_at, excluded.claimed_at);

  -- La clave única impide acreditar los puntos dos veces si el proceso se repite.
  INSERT INTO public.avopuntos_movements
    (profile_id, movement_type, points_delta, source_key, details, created_at)
  VALUES
    (
      new.id,
      'earn',
      v_reward.points,
      v_source_key,
      jsonb_build_object(
        'title', 'Bonificación de bienvenida',
        'bonus_type', 'account_created',
        'reward_code', v_reward.code,
        'description', '1.000 AP de bienvenida por creación de cuenta',
        'points_granted', v_reward.points
      ),
      now()
    )
  ON CONFLICT (source_key) DO NOTHING;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  IF v_rows > 0 THEN
    UPDATE public.avopuntos_accounts
    SET balance = balance + v_reward.points,
        updated_at = now()
    WHERE profile_id = new.id;
  END IF;

  RETURN new;
END;
$function$;

-- Regulariza las cuentas existentes que quedaron con la recompensa reclamada en 0 AP.
DO $migration$
DECLARE
  v_reward public.avopuntos_rewards%rowtype;
  r record;
  v_rows integer;
BEGIN
  SELECT *
    INTO v_reward
  FROM public.avopuntos_rewards
  WHERE code = 'account_created'
    AND active = true
  ORDER BY created_at
  LIMIT 1;

  IF NOT FOUND OR coalesce(v_reward.points, 0) <= 0 THEN
    RAISE EXCEPTION 'No se encontró la recompensa activa de creación de cuenta con puntos configurados.';
  END IF;

  FOR r IN
    SELECT p.id
    FROM public.profiles p
    ORDER BY p.created_at
  LOOP
    INSERT INTO public.avopuntos_accounts (profile_id, balance)
    VALUES (r.id, 0)
    ON CONFLICT (profile_id) DO NOTHING;

    INSERT INTO public.avopuntos_customer_rewards AS current_reward
      (profile_id, reward_id, status, points_granted, source_key, evidence, claimed_at)
    VALUES
      (
        r.id,
        v_reward.id,
        'claimed',
        v_reward.points,
        'reward:account_created:' || r.id::text,
        jsonb_build_object(
          'reward_code', v_reward.code,
          'description', 'Bonificación de bienvenida por crear una cuenta AvoHouse'
        ),
        now()
      )
    ON CONFLICT (profile_id, reward_id) DO UPDATE
    SET status = 'claimed',
        points_granted = greatest(coalesce(current_reward.points_granted, 0), excluded.points_granted),
        source_key = excluded.source_key,
        evidence = coalesce(current_reward.evidence, '{}'::jsonb) || excluded.evidence,
        claimed_at = coalesce(current_reward.claimed_at, excluded.claimed_at);

    INSERT INTO public.avopuntos_movements
      (profile_id, movement_type, points_delta, source_key, details, created_at)
    VALUES
      (
        r.id,
        'earn',
        v_reward.points,
        'reward:account_created:' || r.id::text,
        jsonb_build_object(
          'title', 'Bonificación de bienvenida',
          'bonus_type', 'account_created',
          'reward_code', v_reward.code,
          'description', '1.000 AP de bienvenida por creación de cuenta',
          'points_granted', v_reward.points
        ),
        now()
      )
    ON CONFLICT (source_key) DO NOTHING;

    GET DIAGNOSTICS v_rows = ROW_COUNT;

    IF v_rows > 0 THEN
      UPDATE public.avopuntos_accounts
      SET balance = balance + v_reward.points,
          updated_at = now()
      WHERE profile_id = r.id;
    END IF;

    -- La sincronización programada volverá a publicar el saldo actualizado en Loyverse.
    UPDATE public.loyverse_customers
    SET sync_status = 'pending',
        next_attempt_at = now(),
        last_error = NULL,
        updated_at = now()
    WHERE profile_id = r.id;
  END LOOP;
END;
$migration$;