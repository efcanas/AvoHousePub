alter table public.avopuntos_receipt_state
  add column if not exists input_hash text;

create or replace function public.avopuntos_receipt_input_hash(
  p_receipt public.loyverse_receipts
)
returns text
language sql
immutable
set search_path = public
as $$
  select md5(
    concat_ws(
      '¦',
      p_receipt.receipt_type,
      coalesce(p_receipt.refund_for, ''),
      coalesce(p_receipt.customer_id, ''),
      coalesce(p_receipt.profile_id::text, ''),
      coalesce(p_receipt.receipt_date::text, ''),
      coalesce(p_receipt.cancelled_at::text, ''),
      coalesce(p_receipt.total_money::text, ''),
      coalesce(p_receipt.total_tax::text, ''),
      coalesce(p_receipt.total_discount::text, ''),
      p_receipt.line_items::text,
      p_receipt.payments::text,
      coalesce((p_receipt.raw_receipt->'total_discounts')::text, '')
    )
  );
$$;

create or replace function public.avopuntos_requeue_changed_receipt()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_hash text;
  v_saved_hash text;
begin
  v_hash := public.avopuntos_receipt_input_hash(new);

  select input_hash
    into v_saved_hash
  from public.avopuntos_receipt_state
  where receipt_number = new.receipt_number;

  if v_saved_hash is not null
     and v_hash <> v_saved_hash
     and new.avopuntos_status in ('processed','manual_review','error','ignored_no_profile')
  then
    new.avopuntos_status := 'pending';
    new.avopuntos_processed_at := null;
    new.avopuntos_last_error := null;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_loyverse_receipts_requeue_avopuntos
  on public.loyverse_receipts;

create trigger trg_loyverse_receipts_requeue_avopuntos
before update on public.loyverse_receipts
for each row
execute function public.avopuntos_requeue_changed_receipt();

create or replace function public.avopuntos_process_receipt(p_receipt_number text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
begin
  select *
  into r
  from public.loyverse_receipts
  where receipt_number = p_receipt_number
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'status', 'not_found');
  end if;

  v_input_hash := public.avopuntos_receipt_input_hash(r);

  select *
  into st
  from public.avopuntos_receipt_state
  where receipt_number = p_receipt_number
  for update;

  if r.profile_id is null then
    update public.loyverse_receipts
    set avopuntos_status = 'ignored_no_profile',
        avopuntos_processed_at = v_now,
        avopuntos_last_error = null
    where receipt_number = p_receipt_number;

    insert into public.avopuntos_receipt_state (
      receipt_number, profile_id, input_hash, applied_earned_points,
      applied_redeemed_points, last_receipt_updated_at, version, status,
      last_error, processed_at, updated_at
    )
    values (
      r.receipt_number, null, v_input_hash, 0, 0, r.updated_at, 1,
      'ignored', null, v_now, v_now
    )
    on conflict (receipt_number) do update
    set profile_id = null,
        input_hash = excluded.input_hash,
        applied_earned_points = 0,
        applied_redeemed_points = 0,
        last_receipt_updated_at = excluded.last_receipt_updated_at,
        version = excluded.version,
        status = 'ignored',
        last_error = null,
        processed_at = excluded.processed_at,
        updated_at = excluded.updated_at;

    return jsonb_build_object(
      'ok', true,
      'status', 'ignored_no_profile',
      'receipt_number', p_receipt_number
    );
  end if;

  select *
  into cfg
  from public.avopuntos_config
  where config_id = true and active = true;

  if not found then
    raise exception 'No existe una configuración activa de AvoPuntos.';
  end if;

  if st.receipt_number is not null
     and st.input_hash = v_input_hash
     and st.status in ('processed','manual_review','ignored')
     and r.avopuntos_status <> 'error'
  then
    return jsonb_build_object(
      'ok', true,
      'status', st.status,
      'receipt_number', p_receipt_number,
      'profile_id', r.profile_id,
      'balance', (
        select balance
        from public.avopuntos_accounts
        where profile_id = r.profile_id
      )
    );
  end if;

  if st.receipt_number is not null
     and st.profile_id is not null
     and st.profile_id <> r.profile_id
  then
    update public.loyverse_receipts
    set avopuntos_status = 'manual_review',
        avopuntos_processed_at = v_now,
        avopuntos_last_error = 'El recibo cambió de cliente asociado después de haber sido procesado.'
    where receipt_number = p_receipt_number;

    update public.avopuntos_receipt_state
    set status = 'manual_review',
        last_error = 'El recibo cambió de cliente asociado después de haber sido procesado.',
        updated_at = v_now
    where receipt_number = p_receipt_number;

    return jsonb_build_object(
      'ok', false,
      'status', 'manual_review',
      'receipt_number', p_receipt_number
    );
  end if;

  if st.receipt_number is null then
    v_old_earned := 0;
    v_old_redeemed := 0;
    v_version := 1;
  else
    v_old_earned := st.applied_earned_points;
    v_old_redeemed := st.applied_redeemed_points;
    v_version := st.version + 1;
  end if;

  if r.receipt_type = 'REFUND' then
    insert into public.avopuntos_receipt_state (
      receipt_number, profile_id, input_hash, applied_earned_points,
      applied_redeemed_points, last_receipt_updated_at, version, status,
      last_error, processed_at, updated_at
    )
    values (
      r.receipt_number, r.profile_id, v_input_hash, v_old_earned,
      v_old_redeemed, r.updated_at, v_version, 'manual_review',
      'Reembolso pendiente de una regla específica de reverso AvoPuntos.',
      v_now, v_now
    )
    on conflict (receipt_number) do update
    set profile_id = excluded.profile_id,
        input_hash = excluded.input_hash,
        applied_earned_points = excluded.applied_earned_points,
        applied_redeemed_points = excluded.applied_redeemed_points,
        last_receipt_updated_at = excluded.last_receipt_updated_at,
        version = excluded.version,
        status = excluded.status,
        last_error = excluded.last_error,
        processed_at = excluded.processed_at,
        updated_at = excluded.updated_at;

    update public.loyverse_receipts
    set avopuntos_status = 'manual_review',
        avopuntos_processed_at = v_now,
        avopuntos_last_error = 'Reembolso pendiente de regla de reverso AvoPuntos.'
    where receipt_number = p_receipt_number;

    return jsonb_build_object(
      'ok', true,
      'status', 'manual_review',
      'receipt_number', r.receipt_number
    );
  end if;

  if r.cancelled_at is null then
    for v_payment in
      select value from jsonb_array_elements(coalesce(r.payments, '[]'::jsonb))
    loop
      v_payment_type_id := null;
      if nullif(v_payment->>'payment_type_id','') is not null then
        v_payment_type_id := (v_payment->>'payment_type_id')::uuid;
      end if;

      v_payment_amount :=
        coalesce(nullif(v_payment->>'money_amount','')::numeric, 0);

      if v_payment_type_id is not null
         and v_payment_amount > 0
         and exists (
           select 1
           from public.avopuntos_payment_methods pm
           where pm.payment_type_id = v_payment_type_id
             and pm.active = true
             and pm.eligible_for_avopuntos = true
         )
      then
        v_eligible_amount := v_eligible_amount + v_payment_amount;
      end if;
    end loop;

    for v_discount in
      select value from jsonb_array_elements(
        coalesce(r.raw_receipt->'total_discounts', '[]'::jsonb)
      )
    loop
      v_discount_type := upper(coalesce(v_discount->>'type',''));
      v_discount_amount :=
        coalesce(nullif(v_discount->>'money_amount','')::numeric, 0);

      if v_discount_type = 'DISCOUNT_BY_POINTS'
         and v_discount_amount > 0
      then
        v_redeemed_points := v_redeemed_points + round(v_discount_amount)::bigint;
      end if;
    end loop;

    v_earned_points := round(
      v_eligible_amount * cfg.points_per_thousand / 1000.0
    )::bigint;
  end if;

  v_earned_delta := v_earned_points - v_old_earned;
  v_redeemed_delta := v_redeemed_points - v_old_redeemed;
  v_net_delta := v_earned_delta - v_redeemed_delta;

  select *
  into acc
  from public.avopuntos_accounts
  where profile_id = r.profile_id
  for update;

  if not found then
    insert into public.avopuntos_accounts(profile_id)
    values (r.profile_id)
    returning * into acc;
  end if;

  v_new_balance := acc.balance + v_net_delta;

  if v_new_balance < 0 then
    update public.loyverse_receipts
    set avopuntos_status = 'manual_review',
        avopuntos_processed_at = v_now,
        avopuntos_last_error = 'El movimiento produciría un saldo negativo de AvoPuntos.'
    where receipt_number = p_receipt_number;

    insert into public.avopuntos_receipt_state (
      receipt_number, profile_id, input_hash, applied_earned_points,
      applied_redeemed_points, last_receipt_updated_at, version, status,
      last_error, processed_at, updated_at
    )
    values (
      r.receipt_number, r.profile_id, v_input_hash, v_old_earned,
      v_old_redeemed, r.updated_at, v_version, 'error',
      'El movimiento produciría un saldo negativo de AvoPuntos.',
      v_now, v_now
    )
    on conflict (receipt_number) do update
    set profile_id = excluded.profile_id,
        input_hash = excluded.input_hash,
        applied_earned_points = excluded.applied_earned_points,
        applied_redeemed_points = excluded.applied_redeemed_points,
        last_receipt_updated_at = excluded.last_receipt_updated_at,
        version = excluded.version,
        status = 'error',
        last_error = excluded.last_error,
        processed_at = excluded.processed_at,
        updated_at = excluded.updated_at;

    return jsonb_build_object(
      'ok', false,
      'status', 'error',
      'receipt_number', r.receipt_number
    );
  end if;

  if v_earned_delta <> 0 then
    insert into public.avopuntos_movements (
      profile_id, movement_type, points_delta, eligible_amount,
      receipt_number, source_key, details
    )
    values (
      r.profile_id,
      case when v_earned_delta > 0 then 'earn' else 'earn_reversal' end,
      v_earned_delta,
      case when v_earned_delta > 0 then v_eligible_amount else null end,
      r.receipt_number,
      'receipt:' || r.receipt_number || ':earn:v' || v_version,
      jsonb_build_object(
        'receipt_updated_at', r.updated_at,
        'payment_rule', 'Efectivo + Transferencia',
        'points_per_thousand', cfg.points_per_thousand
      )
    );
  end if;

  if v_redeemed_delta <> 0 then
    insert into public.avopuntos_movements (
      profile_id, movement_type, points_delta, receipt_number,
      source_key, details
    )
    values (
      r.profile_id,
      case when v_redeemed_delta > 0 then 'redeem' else 'redeem_reversal' end,
      -v_redeemed_delta,
      r.receipt_number,
      'receipt:' || r.receipt_number || ':redeem:v' || v_version,
      jsonb_build_object(
        'receipt_updated_at', r.updated_at,
        'discount_rule', 'DISCOUNT_BY_POINTS',
        'point_value_money', cfg.point_value_money
      )
    );
  end if;

  update public.avopuntos_accounts
  set balance = v_new_balance,
      updated_at = v_now
  where profile_id = r.profile_id;

  insert into public.avopuntos_receipt_state (
    receipt_number, profile_id, input_hash, applied_earned_points,
    applied_redeemed_points, last_receipt_updated_at, version, status,
    last_error, processed_at, updated_at
  )
  values (
    r.receipt_number, r.profile_id, v_input_hash, v_earned_points,
    v_redeemed_points, r.updated_at, v_version, 'processed',
    null, v_now, v_now
  )
  on conflict (receipt_number) do update
  set profile_id = excluded.profile_id,
      input_hash = excluded.input_hash,
      applied_earned_points = excluded.applied_earned_points,
      applied_redeemed_points = excluded.applied_redeemed_points,
      last_receipt_updated_at = excluded.last_receipt_updated_at,
      version = excluded.version,
      status = 'processed',
      last_error = null,
      processed_at = excluded.processed_at,
      updated_at = excluded.updated_at;

  update public.loyverse_receipts
  set avopuntos_status = 'processed',
      avopuntos_processed_at = v_now,
      avopuntos_last_error = null
  where receipt_number = p_receipt_number;

  return jsonb_build_object(
    'ok', true,
    'status', 'processed',
    'receipt_number', r.receipt_number,
    'profile_id', r.profile_id,
    'eligible_amount', v_eligible_amount,
    'earned_points', v_earned_points,
    'redeemed_points', v_redeemed_points,
    'net_delta', v_net_delta,
    'balance', v_new_balance
  );
end;
$$;

revoke all on function public.avopuntos_receipt_input_hash(public.loyverse_receipts) from public;
revoke all on function public.avopuntos_receipt_input_hash(public.loyverse_receipts) from anon;
revoke all on function public.avopuntos_receipt_input_hash(public.loyverse_receipts) from authenticated;
revoke all on function public.avopuntos_requeue_changed_receipt() from public;
revoke all on function public.avopuntos_requeue_changed_receipt() from anon;
revoke all on function public.avopuntos_requeue_changed_receipt() from authenticated;
grant execute on function public.avopuntos_receipt_input_hash(public.loyverse_receipts) to service_role;
grant execute on function public.avopuntos_requeue_changed_receipt() to service_role;
revoke all on function public.avopuntos_process_receipt(text) from public;
revoke all on function public.avopuntos_process_receipt(text) from anon;
revoke all on function public.avopuntos_process_receipt(text) from authenticated;
grant execute on function public.avopuntos_process_receipt(text) to service_role;