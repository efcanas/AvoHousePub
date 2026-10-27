CREATE OR REPLACE FUNCTION public.avopuntos_admin_adjust_points(
  p_profile_id uuid,
  p_points_delta bigint,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_admin uuid;
  v_account public.avopuntos_accounts%rowtype;
  v_old_balance bigint;
  v_new_balance bigint;
  v_reason text := nullif(trim(coalesce(p_reason,'')),'');
  v_source text;
  v_customer_name text;
  v_signed_points text;
  v_previous_balance_text text;
  v_new_balance_text text;
  v_adjustment_date text;
  v_movement_label text;
  v_email_request_id bigint;
BEGIN
  v_admin := auth.uid();

  IF v_admin IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM public.admin_users au WHERE au.user_id = v_admin
     )
  THEN
    RAISE EXCEPTION 'No autorizado.';
  END IF;

  IF p_profile_id IS NULL THEN
    RAISE EXCEPTION 'El cliente es obligatorio.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.profiles p WHERE p.id = p_profile_id
  ) THEN
    RAISE EXCEPTION 'No existe el cliente seleccionado.';
  END IF;

  IF coalesce(p_points_delta,0) = 0 THEN
    RAISE EXCEPTION 'El ajuste debe ser diferente de cero.';
  END IF;

  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'Debes indicar el motivo del ajuste.';
  END IF;

  IF char_length(v_reason) > 500 THEN
    RAISE EXCEPTION 'El motivo no puede superar 500 caracteres.';
  END IF;

  SELECT * INTO v_account
  FROM public.avopuntos_accounts
  WHERE profile_id = p_profile_id
  FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO public.avopuntos_accounts(profile_id, balance)
    VALUES (p_profile_id, 0)
    RETURNING * INTO v_account;
  END IF;

  v_old_balance := v_account.balance;
  v_new_balance := v_old_balance + p_points_delta;

  IF v_new_balance < 0 THEN
    RAISE EXCEPTION 'El ajuste dejaría el saldo en un valor negativo.';
  END IF;

  v_source := 'admin-adjust:' || gen_random_uuid()::text;

  INSERT INTO public.avopuntos_movements (
    profile_id, movement_type, points_delta, eligible_amount,
    receipt_number, related_receipt_number, source_key, details
  )
  VALUES (
    p_profile_id, 'adjustment', p_points_delta, NULL,
    NULL, NULL, v_source,
    jsonb_build_object(
      'title','Ajuste manual de AvoPuntos',
      'reason',v_reason,
      'admin_user_id',v_admin,
      'previous_balance',v_old_balance,
      'new_balance',v_new_balance,
      'adjustment_points',abs(p_points_delta)
    )
  );

  UPDATE public.avopuntos_accounts
  SET balance=v_new_balance, updated_at=now()
  WHERE profile_id=p_profile_id;

  SELECT coalesce(nullif(trim(p.full_name),''),'Cliente AvoHouse')
  INTO v_customer_name
  FROM public.profiles p
  WHERE p.id=p_profile_id;

  -- Escape variable values because Resend inserts triple-brace placeholders as raw HTML.
  v_customer_name := replace(replace(replace(replace(replace(v_customer_name,'&','&amp;'),'<','&lt;'),'>','&gt;'),'"','&quot;'),'''','&#39;');
  v_reason := replace(replace(replace(replace(replace(v_reason,'&','&amp;'),'<','&lt;'),'>','&gt;'),'"','&quot;'),'''','&#39;');

  v_signed_points :=
    (CASE WHEN p_points_delta > 0 THEN '+' ELSE '−' END) ||
    replace(to_char(abs(p_points_delta::numeric),'FM999,999,999,999,999,999,990'),',','.');
  v_previous_balance_text :=
    replace(to_char(v_old_balance,'FM999,999,999,999,999,999,990'),',','.');
  v_new_balance_text :=
    replace(to_char(v_new_balance,'FM999,999,999,999,999,999,990'),',','.');
  v_adjustment_date :=
    to_char(now() AT TIME ZONE 'America/Bogota','DD/MM/YYYY HH24:MI') ||
    ' (hora de Colombia)';
  v_movement_label := CASE
    WHEN p_points_delta > 0 THEN 'Acreditación manual de AvoPuntos'
    ELSE 'Retiro manual de AvoPuntos'
  END;

  -- Email is transactional, not advertising. Failure to enqueue it must not undo the points adjustment.
  BEGIN
    v_email_request_id := public.avohouse_queue_profile_email(
      'manual-points-adjustment:' || v_source,
      p_profile_id,
      'points_adjustment',
      'avopuntos_adjustment',
      '26e1b295-58fe-4b6e-8519-a7c498ff9061',
      jsonb_build_object(
        'CUSTOMER_NAME',v_customer_name,
        'MOVEMENT_LABEL',v_movement_label,
        'SIGNED_POINTS',v_signed_points,
        'ADJUSTMENT_DATE',v_adjustment_date,
        'ADJUSTMENT_REASON',v_reason,
        'PREVIOUS_BALANCE',v_previous_balance_text,
        'CURRENT_BALANCE',v_new_balance_text
      )
    );
  EXCEPTION WHEN OTHERS THEN
    v_email_request_id := NULL;
  END;

  RETURN jsonb_build_object(
    'ok',true,
    'profile_id',p_profile_id,
    'points_delta',p_points_delta,
    'previous_balance',v_old_balance,
    'balance',v_new_balance,
    'reason',v_reason,
    'email_queued',v_email_request_id IS NOT NULL
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.avopuntos_admin_adjust_points(uuid,bigint,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.avopuntos_admin_adjust_points(uuid,bigint,text) TO authenticated;
