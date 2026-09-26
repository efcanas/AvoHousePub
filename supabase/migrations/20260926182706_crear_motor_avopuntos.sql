create table public.avopuntos_config (
  config_id boolean primary key default true check (config_id),
  points_per_thousand integer not null default 4 check (points_per_thousand > 0),
  point_value_money numeric(12,2) not null default 1 check (point_value_money > 0),
  rounding_mode text not null default 'nearest' check (rounding_mode = 'nearest'),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.avopuntos_config (config_id, points_per_thousand, point_value_money, rounding_mode)
values (true, 4, 1, 'nearest')
on conflict (config_id) do update
set points_per_thousand = excluded.points_per_thousand,
    point_value_money = excluded.point_value_money,
    rounding_mode = excluded.rounding_mode,
    active = true,
    updated_at = now();

create table public.avopuntos_accounts (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  balance bigint not null default 0 check (balance >= 0),
  status text not null default 'active' check (status in ('active','blocked')),
  last_loyverse_points bigint,
  last_loyverse_sync_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.avopuntos_movements (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  movement_type text not null check (
    movement_type in (
      'opening_balance',
      'earn',
      'redeem',
      'earn_reversal',
      'redeem_reversal',
      'expiration',
      'adjustment'
    )
  ),
  points_delta bigint not null check (points_delta <> 0),
  eligible_amount numeric(14,2),
  receipt_number text,
  related_receipt_number text,
  source_key text not null unique,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index idx_avopuntos_movements_profile_created
  on public.avopuntos_movements(profile_id, created_at desc);

create index idx_avopuntos_movements_receipt
  on public.avopuntos_movements(receipt_number);

create table public.avopuntos_receipt_state (
  receipt_number text primary key references public.loyverse_receipts(receipt_number) on delete cascade,
  profile_id uuid references public.profiles(id) on delete set null,
  applied_earned_points bigint not null default 0,
  applied_redeemed_points bigint not null default 0,
  last_receipt_updated_at timestamptz,
  version integer not null default 0,
  status text not null default 'pending' check (
    status in ('pending','processed','manual_review','error','ignored')
  ),
  last_error text,
  processed_at timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.loyverse_receipts
  add column avopuntos_status text not null default 'pending'
    check (avopuntos_status in (
      'pending',
      'processed',
      'manual_review',
      'error',
      'ignored_no_profile',
      'excluded_pre_activation'
    ));

alter table public.loyverse_receipts
  add column avopuntos_processed_at timestamptz;

alter table public.loyverse_receipts
  add column avopuntos_last_error text;

update public.loyverse_receipts
set avopuntos_status = 'excluded_pre_activation',
    avopuntos_processed_at = now(),
    avopuntos_last_error = null
where avopuntos_status = 'pending';

alter table public.avopuntos_config enable row level security;
alter table public.avopuntos_accounts enable row level security;
alter table public.avopuntos_movements enable row level security;
alter table public.avopuntos_receipt_state enable row level security;

create policy avopuntos_config_authenticated_select
  on public.avopuntos_config
  for select
  to authenticated
  using (active = true);

create policy avopuntos_accounts_self_select
  on public.avopuntos_accounts
  for select
  to authenticated
  using (profile_id = auth.uid());

create policy avopuntos_accounts_admin_select
  on public.avopuntos_accounts
  for select
  to authenticated
  using (
    exists (
      select 1 from public.admin_users
      where admin_users.user_id = auth.uid()
    )
  );

create policy avopuntos_movements_self_select
  on public.avopuntos_movements
  for select
  to authenticated
  using (profile_id = auth.uid());

create policy avopuntos_movements_admin_select
  on public.avopuntos_movements
  for select
  to authenticated
  using (
    exists (
      select 1 from public.admin_users
      where admin_users.user_id = auth.uid()
    )
  );

create policy avopuntos_receipt_state_admin_select
  on public.avopuntos_receipt_state
  for select
  to authenticated
  using (
    exists (
      select 1 from public.admin_users
      where admin_users.user_id = auth.uid()
    )
  );

grant select on public.avopuntos_config to authenticated;
grant select on public.avopuntos_accounts to authenticated;
grant select on public.avopuntos_movements to authenticated;
grant select on public.avopuntos_receipt_state to authenticated;

grant select, insert, update on public.avopuntos_config to service_role;
grant select, insert, update on public.avopuntos_accounts to service_role;
grant select, insert, update on public.avopuntos_movements to service_role;
grant select, insert, update on public.avopuntos_receipt_state to service_role;
grant select, insert, update on public.loyverse_receipts to service_role;

create or replace function public.avopuntos_ensure_account()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.avopuntos_accounts (profile_id)
  values (new.id)
  on conflict (profile_id) do nothing;
  return new;
end;
$$;

drop trigger if exists trg_profiles_create_avopuntos_account on public.profiles;

create trigger trg_profiles_create_avopuntos_account
after insert on public.profiles
for each row
execute function public.avopuntos_ensure_account();

insert into public.avopuntos_accounts (profile_id)
select p.id
from public.profiles p
left join public.avopuntos_accounts a on a.profile_id = p.id
where a.profile_id is null
on conflict (profile_id) do nothing;

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
  v_eligible_amount numeric(14,2) := 0;
  v_redeemed_points bigint := 0;
  v_earned_points bigint := 0;
  v_old_earned bigint := 0;
  v_old_redeemed bigint := 0;
  v_earned_delta bigint := 0;
  v_redeemed_delta bigint := 0;
  v_net_delta bigint := 0;
  v_new_balance bigint := 0;
  v_version integer := 0;
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

  if r.profile_id is null then
    update public.loyverse_receipts
    set avopuntos_status = 'ignored_no_profile',
        avopuntos_processed_at = v_now,
        avopuntos_last_error = null
    where receipt_number = p_receipt_number;

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

  select *
  into st
  from public.avopuntos_receipt_state
  where receipt_number = p_receipt_number
  for update;

  if st.receipt_number is not null
     and st.last_receipt_updated_at = r.updated_at
     and st.status in ('processed','manual_review','ignored')
     and r.avopuntos_status <> 'error'
  then
    return jsonb_build_object(
      'ok', true,
      'status', st.status,
      'receipt_number', p_receipt_number,
      'profile_id', r.profile_id,
      'balance', (select balance from public.avopuntos_accounts where profile_id = r.profile_id)
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
    st.receipt_number := r.receipt_number;
    st.profile_id := r.profile_id;
    st.applied_earned_points := 0;
    st.applied_redeemed_points := 0;
    st.version := 0;
  end if;

  v_old_earned := st.applied_earned_points;
  v_old_redeemed := st.applied_redeemed_points;
  v_version := st.version + 1;

  if r.receipt_type = 'REFUND' then
    insert into public.avopuntos_receipt_state (
      receipt_number,
      profile_id,
      applied_earned_points,
      applied_redeemed_points,
      last_receipt_updated_at,
      version,
      status,
      last_error,
      processed_at,
      updated_at
    )
    values (
      r.receipt_number,
      r.profile_id,
      v_old_earned,
      v_old_redeemed,
      r.updated_at,
      v_version,
      'manual_review',
      'Los reembolsos requieren una regla específica de AvoPuntos antes de aplicar reversos automáticos.',
      v_now,
      v_now
    )
    on conflict (receipt_number) do update
    set profile_id = excluded.profile_id,
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
      'receipt_number', p_receipt_number,
      'profile_id', r.profile_id
    );
  end if;

  if r.cancelled_at is null then
    for v_payment in
      select value
      from jsonb_array_elements(coalesce(r.payments, '[]'::jsonb))
    loop
      v_payment_type_id := nullif(v_payment->>'payment_type_id','')::uuid;
      v_payment_amount := coalesce(nullif(v_payment->>'money_amount','')::numeric, 0);

      if v_payment_type_id is not null and v_payment_amount > 0
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
      select value
      from jsonb_array_elements(coalesce(r.raw_receipt->'total_discounts', '[]'::jsonb))
    loop
      v_discount_type := upper(coalesce(v_discount->>'type',''));
      v_discount_amount := coalesce(nullif(v_discount->>'money_amount','')::numeric, 0);

      if v_discount_type = 'DISCOUNT_BY_POINTS' and v_discount_amount > 0 then
        v_redeemed_points := v_redeemed_points + round(v_discount_amount)::bigint;
      end if;
    end loop;

    v_earned_points := round(
      v_eligible_amount * cfg.points_per_thousand / 1000.0
    )::bigint;
  else
    v_eligible_amount := 0;
    v_redeemed_points := 0;
    v_earned_points := 0;
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
    insert into public.avopuntos_accounts (profile_id)
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
      receipt_number,
      profile_id,
      applied_earned_points,
      applied_redeemed_points,
      last_receipt_updated_at,
      version,
      status,
      last_error,
      processed_at,
      updated_at
    )
    values (
      r.receipt_number,
      r.profile_id,
      v_old_earned,
      v_old_redeemed,
      r.updated_at,
      v_version,
      'error',
      'El movimiento produciría un saldo negativo de AvoPuntos.',
      v_now,
      v_now
    )
    on conflict (receipt_number) do update
    set status = excluded.status,
        last_error = excluded.last_error,
        last_receipt_updated_at = excluded.last_receipt_updated_at,
        version = excluded.version,
        processed_at = excluded.processed_at,
        updated_at = excluded.updated_at;

    return jsonb_build_object(
      'ok', false,
      'status', 'error',
      'receipt_number', p_receipt_number,
      'profile_id', r.profile_id
    );
  end if;

  if v_earned_delta <> 0 then
    insert into public.avopuntos_movements (
      profile_id,
      movement_type,
      points_delta,
      eligible_amount,
      receipt_number,
      source_key,
      details
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
      profile_id,
      movement_type,
      points_delta,
      eligible_amount,
      receipt_number,
      source_key,
      details
    )
    values (
      r.profile_id,
      case when v_redeemed_delta > 0 then 'redeem' else 'redeem_reversal' end,
      -v_redeemed_delta,
      null,
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
    receipt_number,
    profile_id,
    applied_earned_points,
    applied_redeemed_points,
    last_receipt_updated_at,
    version,
    status,
    last_error,
    processed_at,
    updated_at
  )
  values (
    r.receipt_number,
    r.profile_id,
    v_earned_points,
    v_redeemed_points,
    r.updated_at,
    v_version,
    'processed',
    null,
    v_now,
    v_now
  )
  on conflict (receipt_number) do update
  set profile_id = excluded.profile_id,
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

revoke all on function public.avopuntos_process_receipt(text) from public;
revoke all on function public.avopuntos_process_receipt(text) from anon;
revoke all on function public.avopuntos_process_receipt(text) from authenticated;
grant execute on function public.avopuntos_process_receipt(text) to service_role;