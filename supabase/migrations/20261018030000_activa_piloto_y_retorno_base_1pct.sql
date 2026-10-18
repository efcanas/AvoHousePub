-- Ajusta retorno base al 1% e integra Piloto al cálculo efectivo de AvoPuntos.
-- No modifica saldos, movimientos ni tickets históricos ya procesados.
UPDATE public.avopuntos_config
SET points_per_thousand=10,
    updated_at=now()
WHERE config_id=true;

CREATE OR REPLACE FUNCTION public.avopuntos_process_receipt(p_receipt_number text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r public.loyverse_receipts%rowtype;
  st public.avopuntos_receipt_state%rowtype;
  cfg public.avopuntos_config%rowtype;
  acc public.avopuntos_accounts%rowtype;
  v_input_hash text;
  v_eligible_amount numeric(14,2) := 0;
  v_redeemed_points bigint := 0;
  v_earned_points bigint := 0;
  v_old_earned bigint := 0;
  v_old_redeemed bigint := 0;
  v_earned_delta bigint := 0;
  v_redeemed_delta bigint := 0;
  v_net_delta bigint := 0;
  v_new_balance bigint := 0;
  v_version integer := 1;
  v_now timestamptz := now();
  v_payment jsonb;
  v_discount jsonb;
  v_payment_type_id uuid;
  v_payment_amount numeric;
  v_discount_type text;
  v_discount_amount numeric;
  orig public.loyverse_receipts%rowtype;
  orig_st public.avopuntos_receipt_state%rowtype;
  v_refund_ratio numeric := 0;
  v_original_earned bigint := 0;
  v_original_redeemed bigint := 0;
  v_target_earned_reversal bigint := 0;
  v_target_redeemed_restore bigint := 0;
  v_old_refund_earned bigint := 0;
  v_old_refund_redeemed bigint := 0;
  v_redeemed_restore_delta bigint := 0;
  v_source text;
  v_business_date date;
  v_profile_created_at timestamptz;
  v_multiplier numeric := 1;
  v_rule_type text := 'base';
  v_rule_name text := null;
  v_rule_id uuid := null;
  v_effective_points_per_thousand numeric;
begin
  select * into r
  from public.loyverse_receipts
  where receipt_number=p_receipt_number
  for update;

  if not found then
    return jsonb_build_object('ok',false,'status','not_found');
  end if;

  v_input_hash := public.avopuntos_receipt_input_hash(r);

  select * into st
  from public.avopuntos_receipt_state
  where receipt_number=p_receipt_number
  for update;

  if r.profile_id is null then
    update public.loyverse_receipts
    set avopuntos_status='ignored_no_profile',
        avopuntos_processed_at=v_now,
        avopuntos_last_error=null
    where receipt_number=p_receipt_number;

    insert into public.avopuntos_receipt_state(
      receipt_number,profile_id,input_hash,applied_earned_points,
      applied_redeemed_points,last_receipt_updated_at,version,status,
      last_error,processed_at,updated_at
    ) values (
      r.receipt_number,null,v_input_hash,0,0,r.updated_at,1,
      'ignored',null,v_now,v_now
    )
    on conflict(receipt_number) do update
    set profile_id=null,input_hash=excluded.input_hash,
        applied_earned_points=0,applied_redeemed_points=0,
        last_receipt_updated_at=excluded.last_receipt_updated_at,
        version=excluded.version,status='ignored',last_error=null,
        processed_at=excluded.processed_at,updated_at=excluded.updated_at;

    return jsonb_build_object('ok',true,'status','ignored_no_profile','receipt_number',p_receipt_number);
  end if;

  select * into cfg
  from public.avopuntos_config
  where config_id=true and active=true;

  if not found then
    raise exception 'No existe una configuración activa de AvoPuntos.';
  end if;

  if st.receipt_number is not null
     and st.input_hash=v_input_hash
     and st.status in ('processed','manual_review','ignored')
     and r.avopuntos_status<>'error'
     and r.receipt_type<>'REFUND'
  then
    return jsonb_build_object(
      'ok',true,'status',st.status,'receipt_number',p_receipt_number,
      'profile_id',r.profile_id,
      'balance',(select balance from public.avopuntos_accounts where profile_id=r.profile_id)
    );
  end if;

  if st.receipt_number is not null
     and st.profile_id is not null
     and st.profile_id<>r.profile_id
  then
    update public.loyverse_receipts
    set avopuntos_status='manual_review',
        avopuntos_processed_at=v_now,
        avopuntos_last_error='El recibo cambió de cliente asociado después de haber sido procesado.'
    where receipt_number=p_receipt_number;

    update public.avopuntos_receipt_state
    set status='manual_review',
        last_error='El recibo cambió de cliente asociado después de haber sido procesado.',
        updated_at=v_now
    where receipt_number=p_receipt_number;

    return jsonb_build_object('ok',false,'status','manual_review','receipt_number',p_receipt_number);
  end if;

  if st.receipt_number is null then
    v_old_earned:=0;
    v_old_redeemed:=0;
    v_version:=1;
  else
    v_old_earned:=st.applied_earned_points;
    v_old_redeemed:=st.applied_redeemed_points;
    v_version:=st.version+1;
  end if;

  if r.receipt_type='REFUND' then
    v_old_refund_earned:=greatest(coalesce(st.applied_earned_points,0),0);
    v_old_refund_redeemed:=greatest(coalesce(st.applied_redeemed_points,0),0);

    if r.cancelled_at is not null then
      v_target_earned_reversal:=0;
      v_target_redeemed_restore:=0;
    else
      if r.refund_for is null then
        update public.loyverse_receipts
        set avopuntos_status='manual_review',
            avopuntos_processed_at=v_now,
            avopuntos_last_error='Reembolso sin ticket de origen.'
        where receipt_number=p_receipt_number;
        return jsonb_build_object('ok',false,'status','manual_review','receipt_number',r.receipt_number);
      end if;

      select * into orig
      from public.loyverse_receipts
      where receipt_number=r.refund_for
      for update;

      if not found then
        update public.loyverse_receipts
        set avopuntos_status='manual_review',
            avopuntos_processed_at=v_now,
            avopuntos_last_error='No se encontró el ticket de origen del reembolso.'
        where receipt_number=p_receipt_number;
        return jsonb_build_object('ok',false,'status','manual_review','receipt_number',r.receipt_number);
      end if;

      select * into orig_st
      from public.avopuntos_receipt_state
      where receipt_number=orig.receipt_number;

      if orig_st.receipt_number is null or orig_st.status<>'processed' then
        update public.loyverse_receipts
        set avopuntos_status='manual_review',
            avopuntos_processed_at=v_now,
            avopuntos_last_error='El ticket de origen no tiene AvoPuntos procesados.'
        where receipt_number=p_receipt_number;
        return jsonb_build_object('ok',false,'status','manual_review','receipt_number',r.receipt_number);
      end if;

      v_original_earned:=greatest(coalesce(orig_st.applied_earned_points,0),0);
      v_original_redeemed:=greatest(coalesce(orig_st.applied_redeemed_points,0),0);

      if coalesce(orig.total_money,0)<=0 then
        v_refund_ratio:=1;
      else
        v_refund_ratio:=least(
          greatest(abs(coalesce(r.total_money,0))/orig.total_money,0),
          1
        );
      end if;

      v_target_earned_reversal:=round(v_original_earned*v_refund_ratio)::bigint;
      v_target_redeemed_restore:=round(v_original_redeemed*v_refund_ratio)::bigint;
    end if;

    v_earned_delta:=v_target_earned_reversal-v_old_refund_earned;
    v_redeemed_restore_delta:=v_target_redeemed_restore-v_old_refund_redeemed;
    v_net_delta:=v_redeemed_restore_delta-v_earned_delta;

    select * into acc
    from public.avopuntos_accounts
    where profile_id=r.profile_id
    for update;

    if not found then
      insert into public.avopuntos_accounts(profile_id)
      values(r.profile_id)
      returning * into acc;
    end if;

    v_new_balance:=acc.balance+v_net_delta;

    if v_new_balance<0 then
      update public.loyverse_receipts
      set avopuntos_status='manual_review',
          avopuntos_processed_at=v_now,
          avopuntos_last_error='El reembolso produciría un saldo negativo de AvoPuntos.'
      where receipt_number=p_receipt_number;
      return jsonb_build_object('ok',false,'status','error','receipt_number',r.receipt_number);
    end if;

    if v_earned_delta<>0 then
      if v_earned_delta>0 then
        v_source:='receipt:'||r.receipt_number||':refund-earn:v'||v_version;
        insert into public.avopuntos_movements(
          profile_id,movement_type,points_delta,receipt_number,related_receipt_number,source_key,details
        ) values (
          r.profile_id,'earn_reversal',-v_earned_delta,r.receipt_number,r.refund_for,v_source,
          jsonb_build_object('refund_for',r.refund_for,'refund_ratio',v_refund_ratio,
            'original_earned_points',v_original_earned,'refunded_amount',r.total_money,
            'refund_cancellation',false)
        );
      else
        v_source:='receipt:'||r.receipt_number||':refund-cancel-earn:v'||v_version;
        insert into public.avopuntos_movements(
          profile_id,movement_type,points_delta,receipt_number,related_receipt_number,source_key,details
        ) values (
          r.profile_id,'earn',-v_earned_delta,r.receipt_number,r.refund_for,v_source,
          jsonb_build_object('refund_for',r.refund_for,'refund_cancellation',true,
            'restored_points',-v_earned_delta)
        );
      end if;
    end if;

    if v_redeemed_restore_delta<>0 then
      if v_redeemed_restore_delta>0 then
        v_source:='receipt:'||r.receipt_number||':refund-redeem:v'||v_version;
        insert into public.avopuntos_movements(
          profile_id,movement_type,points_delta,receipt_number,related_receipt_number,source_key,details
        ) values (
          r.profile_id,'redeem_reversal',v_redeemed_restore_delta,r.receipt_number,r.refund_for,v_source,
          jsonb_build_object('refund_for',r.refund_for,'refund_ratio',v_refund_ratio,
            'original_redeemed_points',v_original_redeemed,'refunded_amount',r.total_money,
            'refund_cancellation',false)
        );
      else
        v_source:='receipt:'||r.receipt_number||':refund-cancel-redeem:v'||v_version;
        insert into public.avopuntos_movements(
          profile_id,movement_type,points_delta,receipt_number,related_receipt_number,source_key,details
        ) values (
          r.profile_id,'redeem',v_redeemed_restore_delta,r.receipt_number,r.refund_for,v_source,
          jsonb_build_object('refund_for',r.refund_for,'refund_cancellation',true,
            'removed_restored_points',-v_redeemed_restore_delta)
        );
      end if;
    end if;

    update public.avopuntos_accounts
    set balance=v_new_balance,updated_at=v_now
    where profile_id=r.profile_id;

    insert into public.avopuntos_receipt_state(
      receipt_number,profile_id,input_hash,applied_earned_points,applied_redeemed_points,
      last_receipt_updated_at,version,status,last_error,processed_at,updated_at
    ) values (
      r.receipt_number,r.profile_id,v_input_hash,v_target_earned_reversal,v_target_redeemed_restore,
      r.updated_at,greatest(coalesce(st.version,0),0)+1,'processed',null,v_now,v_now
    )
    on conflict(receipt_number) do update
    set profile_id=excluded.profile_id,input_hash=excluded.input_hash,
        applied_earned_points=excluded.applied_earned_points,
        applied_redeemed_points=excluded.applied_redeemed_points,
        last_receipt_updated_at=excluded.last_receipt_updated_at,
        version=excluded.version,status='processed',last_error=null,
        processed_at=excluded.processed_at,updated_at=excluded.updated_at;

    update public.loyverse_receipts
    set avopuntos_status='processed',avopuntos_processed_at=v_now,avopuntos_last_error=null,
        points_earned=0,points_deducted=0,points_balance=v_new_balance
    where receipt_number=p_receipt_number;

    return jsonb_build_object(
      'ok',true,'status','processed','receipt_number',r.receipt_number,
      'profile_id',r.profile_id,'refund_for',r.refund_for,
      'refund_ratio',v_refund_ratio,'earned_reversed',v_target_earned_reversal,
      'redeemed_restored',v_target_redeemed_restore,'net_delta',v_net_delta,
      'balance',v_new_balance,'refund_cancelled',(r.cancelled_at is not null)
    );
  end if;

  if r.cancelled_at is null then
    for v_payment in
      select value from jsonb_array_elements(coalesce(r.payments,'[]'::jsonb))
    loop
      v_payment_type_id:=null;
      if nullif(v_payment->>'payment_type_id','') is not null then
        v_payment_type_id:=(v_payment->>'payment_type_id')::uuid;
      end if;

      v_payment_amount:=coalesce(nullif(v_payment->>'money_amount','')::numeric,0);

      if v_payment_type_id is not null
         and v_payment_amount>0
         and exists(
           select 1 from public.avopuntos_payment_methods pm
           where pm.payment_type_id=v_payment_type_id
             and pm.active=true and pm.eligible_for_avopuntos=true
         )
      then
        v_eligible_amount:=v_eligible_amount+v_payment_amount;
      end if;
    end loop;

    for v_discount in
      select value from jsonb_array_elements(
        coalesce(r.raw_receipt->'total_discounts','[]'::jsonb)
      )
    loop
      v_discount_type:=upper(coalesce(v_discount->>'type',''));
      v_discount_amount:=coalesce(nullif(v_discount->>'money_amount','')::numeric,0);

      if v_discount_type='DISCOUNT_BY_POINTS' and v_discount_amount>0 then
        v_redeemed_points:=v_redeemed_points+round(v_discount_amount)::bigint;
      end if;
    end loop;

    v_business_date:=(r.receipt_date at time zone 'America/Bogota')::date;

    SELECT p.created_at
      INTO v_profile_created_at
    FROM public.profiles p
    WHERE p.id=r.profile_id;

    -- Las reglas individuales explícitas conservan la prioridad existente.
    SELECT p.multiplier,p.reason,p.id
      INTO v_multiplier,v_rule_name,v_rule_id
    FROM public.avopuntos_customer_rules p
    WHERE p.profile_id=r.profile_id
      AND p.active=true
      AND p.start_date<=v_business_date
      AND (p.end_date IS NULL OR p.end_date>=v_business_date)
    ORDER BY p.start_date DESC,p.created_at DESC
    LIMIT 1;

    IF v_rule_id IS NOT NULL THEN
      v_rule_type:='customer';
    ELSE
      v_multiplier:=1;
      v_rule_name:=NULL;
      v_rule_id:=NULL;

      -- Piloto: la cuenta debe haberse creado antes del cierre y la compra
      -- debe ocurrir desde su registro hasta el 31/12/2026 inclusive (hora Colombia).
      IF v_profile_created_at IS NOT NULL
         AND (v_profile_created_at AT TIME ZONE 'America/Bogota')::date <= DATE '2026-12-31'
         AND v_business_date >= (v_profile_created_at AT TIME ZONE 'America/Bogota')::date
         AND v_business_date <= DATE '2026-12-31' THEN
        v_multiplier:=2;
        v_rule_type:='pilot';
        v_rule_name:='Piloto';
      ELSE
        SELECT p.multiplier,p.name,p.id
          INTO v_multiplier,v_rule_name,v_rule_id
        FROM public.avopuntos_promotions p
        WHERE p.active=true
          AND p.start_date<=v_business_date
          AND (p.end_date IS NULL OR p.end_date>=v_business_date)
        ORDER BY p.start_date DESC,p.created_at DESC
        LIMIT 1;

        IF v_rule_id IS NOT NULL THEN
          v_rule_type:='promotion';
        ELSE
          v_multiplier:=1;
          v_rule_type:='base';
          v_rule_name:=NULL;
          v_rule_id:=NULL;
        END IF;
      END IF;
    END IF;

    v_effective_points_per_thousand:=cfg.points_per_thousand*v_multiplier;

    v_earned_points:=round(
      v_eligible_amount*v_effective_points_per_thousand/1000.0
    )::bigint;
  end if;

  v_earned_delta:=v_earned_points-v_old_earned;
  v_redeemed_delta:=v_redeemed_points-v_old_redeemed;
  v_net_delta:=v_earned_delta-v_redeemed_delta;

  select * into acc
  from public.avopuntos_accounts
  where profile_id=r.profile_id
  for update;

  if not found then
    insert into public.avopuntos_accounts(profile_id)
    values(r.profile_id)
    returning * into acc;
  end if;

  v_new_balance:=acc.balance+v_net_delta;

  if v_new_balance<0 then
    update public.loyverse_receipts
    set avopuntos_status='manual_review',
        avopuntos_processed_at=v_now,
        avopuntos_last_error='El movimiento produciría un saldo negativo de AvoPuntos.'
    where receipt_number=p_receipt_number;

    insert into public.avopuntos_receipt_state(
      receipt_number,profile_id,input_hash,applied_earned_points,
      applied_redeemed_points,last_receipt_updated_at,version,status,
      last_error,processed_at,updated_at
    ) values (
      r.receipt_number,r.profile_id,v_input_hash,v_old_earned,
      v_old_redeemed,r.updated_at,v_version,'error',
      'El movimiento produciría un saldo negativo de AvoPuntos.',
      v_now,v_now
    )
    on conflict(receipt_number) do update
    set profile_id=excluded.profile_id,input_hash=excluded.input_hash,
        applied_earned_points=excluded.applied_earned_points,
        applied_redeemed_points=excluded.applied_redeemed_points,
        last_receipt_updated_at=excluded.last_receipt_updated_at,
        version=excluded.version,status='error',last_error=excluded.last_error,
        processed_at=excluded.processed_at,updated_at=excluded.updated_at;

    return jsonb_build_object('ok',false,'status','error','receipt_number',p_receipt_number);
  end if;

  if v_earned_delta<>0 then
    insert into public.avopuntos_movements(
      profile_id,movement_type,points_delta,eligible_amount,
      receipt_number,source_key,details
    ) values (
      r.profile_id,
      case when v_earned_delta>0 then 'earn' else 'earn_reversal' end,
      v_earned_delta,
      case when v_earned_delta>0 then v_eligible_amount else null end,
      r.receipt_number,
      'receipt:'||r.receipt_number||':earn:v'||v_version,
      jsonb_build_object(
        'receipt_updated_at',r.updated_at,
        'payment_rule','Efectivo + Transferencia',
        'points_per_thousand',cfg.points_per_thousand,
        'multiplier',v_multiplier,
        'effective_points_per_thousand',v_effective_points_per_thousand,
        'rule_type',v_rule_type,
        'rule_name',v_rule_name,
        'rule_id',v_rule_id,
        'business_date',v_business_date
      )
    );
  end if;

  if v_redeemed_delta<>0 then
    insert into public.avopuntos_movements(
      profile_id,movement_type,points_delta,receipt_number,
      source_key,details
    ) values (
      r.profile_id,
      case when v_redeemed_delta>0 then 'redeem' else 'redeem_reversal' end,
      -v_redeemed_delta,
      r.receipt_number,
      'receipt:'||r.receipt_number||':redeem:v'||v_version,
      jsonb_build_object(
        'receipt_updated_at',r.updated_at,
        'discount_rule','DISCOUNT_BY_POINTS',
        'point_value_money',cfg.point_value_money
      )
    );
  end if;

  update public.avopuntos_accounts
  set balance=v_new_balance,updated_at=v_now
  where profile_id=r.profile_id;

  insert into public.avopuntos_receipt_state(
    receipt_number,profile_id,input_hash,applied_earned_points,applied_redeemed_points,
    last_receipt_updated_at,version,status,last_error,processed_at,updated_at
  ) values (
    r.receipt_number,r.profile_id,v_input_hash,v_earned_points,v_redeemed_points,
    r.updated_at,v_version,'processed',null,v_now,v_now
  )
  on conflict(receipt_number) do update
  set profile_id=excluded.profile_id,input_hash=excluded.input_hash,
      applied_earned_points=excluded.applied_earned_points,
      applied_redeemed_points=excluded.applied_redeemed_points,
      last_receipt_updated_at=excluded.last_receipt_updated_at,
      version=excluded.version,status='processed',last_error=null,
      processed_at=excluded.processed_at,updated_at=excluded.updated_at;

  update public.loyverse_receipts
  set avopuntos_status='processed',avopuntos_processed_at=v_now,avopuntos_last_error=null
  where receipt_number=p_receipt_number;

  return jsonb_build_object(
    'ok',true,'status','processed','receipt_number',r.receipt_number,
    'profile_id',r.profile_id,'eligible_amount',v_eligible_amount,
    'earned_points',v_earned_points,'redeemed_points',v_redeemed_points,
    'net_delta',v_net_delta,'balance',v_new_balance,
    'rule_type',v_rule_type,'rule_name',v_rule_name,
    'multiplier',v_multiplier,
    'effective_points_per_thousand',v_effective_points_per_thousand
  );
end;
$function$;

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
  v_profile_created_at timestamptz := NULL;
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

  -- Prioridad: regla individual explícita, beneficio de Piloto y luego promoción general.
  SELECT p.created_at
    INTO v_profile_created_at
  FROM public.profiles p
  WHERE p.id=v_profile_id;

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

    IF v_profile_created_at IS NOT NULL
       AND (v_profile_created_at AT TIME ZONE 'America/Bogota')::date <= DATE '2026-12-31'
       AND v_today <= DATE '2026-12-31' THEN
      v_multiplier:=2;
      v_bonus_type:='pilot';
      v_bonus_name:='Piloto';
      v_start_date:=(v_profile_created_at AT TIME ZONE 'America/Bogota')::date;
      v_end_date:=DATE '2026-12-31';
    ELSE
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
