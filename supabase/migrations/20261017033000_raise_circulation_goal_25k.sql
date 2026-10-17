-- Raise the AP en circulación cumulative redemption target from 20,000 to 25,000 AP.
UPDATE public.avopuntos_rewards
SET description = 'Haz circular 25.000 AvoPuntos.',
    updated_at = now()
WHERE code = 'points_redeemed_20k';

DO $migration$
DECLARE
  v_definition text;
BEGIN
  v_definition := pg_get_functiondef('public.avopuntos_check_permanent_achievements(uuid)'::regprocedure);
  IF position($find$(4, 'points_redeemed_20k'::text, 20000::bigint, 'redeem'::text)$find$ IN v_definition) = 0 THEN
    RAISE EXCEPTION 'No se encontró la meta actual de 20.000 en avopuntos_check_permanent_achievements.';
  END IF;
  v_definition := replace(
    v_definition,
    $old$(4, 'points_redeemed_20k'::text, 20000::bigint, 'redeem'::text)$old$,
    $new$(4, 'points_redeemed_20k'::text, 25000::bigint, 'redeem'::text)$new$
  );
  EXECUTE v_definition;

  v_definition := pg_get_functiondef('public.avopuntos_get_my_rewards_with_progress()'::regprocedure);
  IF position($find$least(coalesce(rp.redeemed_progress, 0), 20000)::bigint$find$ IN v_definition) = 0
     OR position($find$WHEN 'points_redeemed_20k' THEN 20000::bigint$find$ IN v_definition) = 0 THEN
    RAISE EXCEPTION 'No se encontraron las metas actuales del contador AP en circulación.';
  END IF;
  v_definition := replace(
    v_definition,
    $old$least(coalesce(rp.redeemed_progress, 0), 20000)::bigint$old$,
    $new$least(coalesce(rp.redeemed_progress, 0), 25000)::bigint$new$
  );
  v_definition := replace(
    v_definition,
    $old$WHEN 'points_redeemed_20k' THEN 20000::bigint$old$,
    $new$WHEN 'points_redeemed_20k' THEN 25000::bigint$new$
  );
  EXECUTE v_definition;
END;
$migration$;
