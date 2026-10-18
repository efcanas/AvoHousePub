-- Expone al cliente autenticado únicamente su retorno actual y la regla efectiva de hoy.
-- Respeta la misma prioridad que avopuntos_process_receipt: regla individual, promoción global, tasa base.
CREATE OR REPLACE FUNCTION public.avopuntos_get_my_current_return()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_profile_id uuid := auth.uid();
  v_points_per_thousand integer;
  v_point_value_money numeric;
  v_multiplier numeric := 1;
  v_bonus_type text := NULL;
  v_bonus_name text := NULL;
  v_start_date date := NULL;
  v_end_date date := NULL;
  v_today date := (now() AT TIME ZONE 'America/Bogota')::date;
BEGIN
  IF v_profile_id IS NULL THEN
    RAISE EXCEPTION 'Se requiere una sesión autenticada.';
  END IF;

  SELECT c.points_per_thousand,c.point_value_money
    INTO v_points_per_thousand,v_point_value_money
  FROM public.avopuntos_config c
  WHERE c.config_id=true AND c.active=true
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No existe una configuración activa de AvoPuntos.';
  END IF;

  -- Misma prioridad que el motor de recibos: primero regla individual vigente.
  SELECT r.multiplier,r.reason,r.start_date,r.end_date
    INTO v_multiplier,v_bonus_name,v_start_date,v_end_date
  FROM public.avopuntos_customer_rules r
  WHERE r.profile_id=v_profile_id
    AND r.active=true
    AND r.start_date<=v_today
    AND (r.end_date IS NULL OR r.end_date>=v_today)
  ORDER BY r.start_date DESC,r.created_at DESC
  LIMIT 1;

  IF FOUND THEN
    v_bonus_type:='customer';
  ELSE
    v_multiplier:=1;
    v_bonus_name:=NULL;
    v_start_date:=NULL;
    v_end_date:=NULL;

    SELECT p.multiplier,p.name,p.start_date,p.end_date
      INTO v_multiplier,v_bonus_name,v_start_date,v_end_date
    FROM public.avopuntos_promotions p
    WHERE p.active=true
      AND p.start_date<=v_today
      AND (p.end_date IS NULL OR p.end_date>=v_today)
    ORDER BY p.start_date DESC,p.created_at DESC
    LIMIT 1;

    IF FOUND THEN
      v_bonus_type:='promotion';
    ELSE
      v_multiplier:=1;
      v_bonus_type:=NULL;
      v_bonus_name:=NULL;
      v_start_date:=NULL;
      v_end_date:=NULL;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'base_points_per_thousand',v_points_per_thousand,
    'point_value_money',v_point_value_money,
    'base_return_percent',round((v_points_per_thousand::numeric*v_point_value_money/1000)*100,2),
    'effective_points_per_thousand',round(v_points_per_thousand::numeric*v_multiplier,2),
    'effective_return_percent',round((v_points_per_thousand::numeric*v_multiplier*v_point_value_money/1000)*100,2),
    'multiplier',v_multiplier,
    'bonus_type',CASE WHEN v_multiplier<>1 THEN v_bonus_type ELSE NULL END,
    'bonus_name',CASE WHEN v_multiplier<>1 THEN v_bonus_name ELSE NULL END,
    'bonus_start_date',CASE WHEN v_multiplier<>1 THEN v_start_date ELSE NULL END,
    'bonus_end_date',CASE WHEN v_multiplier<>1 THEN v_end_date ELSE NULL END,
    'current_date_colombia',v_today
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.avopuntos_get_my_current_return() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.avopuntos_get_my_current_return() TO authenticated;
