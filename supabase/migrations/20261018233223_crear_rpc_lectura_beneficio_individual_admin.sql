CREATE OR REPLACE FUNCTION public.avopuntos_admin_get_customer_rule(p_profile_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_admin uuid := auth.uid();
  v_rule jsonb;
BEGIN
  IF v_admin IS NULL OR NOT public.avopuntos_admin_is_admin() THEN
    RAISE EXCEPTION 'No autorizado.';
  END IF;

  IF p_profile_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = p_profile_id
  ) THEN
    RAISE EXCEPTION 'No existe el cliente seleccionado.';
  END IF;

  SELECT jsonb_build_object(
    'id', r.id,
    'multiplier', r.multiplier,
    'start_date', r.start_date,
    'end_date', r.end_date,
    'active', r.active,
    'reason', r.reason,
    'created_at', r.created_at
  )
  INTO v_rule
  FROM public.avopuntos_customer_rules AS r
  WHERE r.profile_id = p_profile_id
  ORDER BY r.created_at DESC
  LIMIT 1;

  RETURN jsonb_build_object('rule', v_rule);
END;
$function$;

REVOKE ALL ON FUNCTION public.avopuntos_admin_get_customer_rule(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.avopuntos_admin_get_customer_rule(uuid) TO authenticated;
