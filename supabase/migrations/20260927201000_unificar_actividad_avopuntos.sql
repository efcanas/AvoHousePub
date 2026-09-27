alter table public.avopuntos_movements
  drop constraint if exists avopuntos_movements_movement_type_check;

alter table public.avopuntos_movements
  add constraint avopuntos_movements_movement_type_check
  check (
    movement_type = any (
      array[
        'opening_balance',
        'earn',
        'redeem',
        'earn_reversal',
        'redeem_reversal',
        'expiration',
        'adjustment',
        'purchase',
        'purchase_cancelled',
        'refund',
        'refund_cancelled'
      ]
    )
  );

alter table public.avopuntos_movements
  drop constraint if exists avopuntos_movements_points_delta_check;

alter table public.avopuntos_movements
  add constraint avopuntos_movements_points_delta_check
  check (
    points_delta <> 0
    or movement_type in ('purchase','purchase_cancelled','refund','refund_cancelled')
  );

drop trigger if exists trg_record_customer_activity_event on public.loyverse_receipts;

create or replace function public.avopuntos_record_zero_activity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.loyverse_receipts%rowtype;
  v_type text;
  v_title text;
  v_source text;
  v_payment_names text[];
  v_payment jsonb;
  v_payment_name text;
  v_balance bigint := 0;
  v_event_at timestamptz;
begin
  if new.profile_id is null
     or new.status <> 'processed'
     or coalesce(new.applied_earned_points,0) <> 0
     or coalesce(new.applied_redeemed_points,0) <> 0
  then
    return new;
  end if;

  select * into r
  from public.loyverse_receipts
  where receipt_number = new.receipt_number;

  if not found then
    return new;
  end if;

  if r.receipt_type = 'SALE' and r.cancelled_at is null then
    v_type := 'purchase';
    v_title := 'Compra registrada';
    v_event_at := coalesce(r.receipt_date,r.created_at,r.updated_at,now());
  elsif r.receipt_type = 'SALE' and r.cancelled_at is not null then
    v_type := 'purchase_cancelled';
    v_title := 'Compra cancelada';
    v_event_at := coalesce(r.cancelled_at,r.updated_at,now());
  elsif r.receipt_type = 'REFUND' and r.cancelled_at is null then
    v_type := 'refund';
    v_title := 'Reembolso registrado';
    v_event_at := coalesce(r.receipt_date,r.created_at,r.updated_at,now());
  elsif r.receipt_type = 'REFUND' and r.cancelled_at is not null then
    v_type := 'refund_cancelled';
    v_title := 'Reembolso cancelado';
    v_event_at := coalesce(r.cancelled_at,r.updated_at,now());
  else
    return new;
  end if;

  v_source := 'receipt:' || r.receipt_number || ':event:' || v_type;

  if jsonb_typeof(coalesce(r.payments, '[]'::jsonb)) = 'array' then
    for v_payment in
      select value from jsonb_array_elements(coalesce(r.payments, '[]'::jsonb))
    loop
      v_payment_name := nullif(trim(v_payment->>'name'), '');
      if v_payment_name is not null then
        v_payment_names := array_append(v_payment_names, v_payment_name);
      end if;
    end loop;
  end if;

  select balance into v_balance
  from public.avopuntos_accounts
  where profile_id = r.profile_id;

  insert into public.avopuntos_movements (
    profile_id,movement_type,points_delta,eligible_amount,
    receipt_number,related_receipt_number,source_key,details,created_at
  )
  values (
    r.profile_id,v_type,0,null,
    r.receipt_number,r.refund_for,v_source,
    jsonb_build_object(
      'event_only',true,
      'title',v_title,
      'total_money',coalesce(r.total_money,0),
      'payment_names',coalesce(v_payment_names,array[]::text[]),
      'refund_for',r.refund_for,
      'cancelled_at',r.cancelled_at,
      'points_balance',coalesce(v_balance,0),
      'receipt_type',r.receipt_type
    ),
    v_event_at
  )
  on conflict (source_key) do update
  set details=excluded.details;

  return new;
end;
$$;

revoke all on function public.avopuntos_record_zero_activity() from public,anon,authenticated;
grant execute on function public.avopuntos_record_zero_activity() to service_role;

drop trigger if exists trg_avopuntos_record_zero_activity
  on public.avopuntos_receipt_state;

create trigger trg_avopuntos_record_zero_activity
after insert or update on public.avopuntos_receipt_state
for each row
execute function public.avopuntos_record_zero_activity();

insert into public.avopuntos_movements (
  profile_id,movement_type,points_delta,eligible_amount,
  receipt_number,related_receipt_number,source_key,details,created_at
)
select
  r.profile_id,'purchase',0,null,
  r.receipt_number,null,
  'receipt:' || r.receipt_number || ':event:purchase',
  jsonb_build_object(
    'event_only',true,
    'title','Compra registrada',
    'total_money',coalesce(r.total_money,0),
    'payment_names',array['TC'],
    'refund_for',null,
    'cancelled_at',r.cancelled_at,
    'points_balance',coalesce(a.balance,0),
    'receipt_type',r.receipt_type,
    'backfilled',true
  ),
  coalesce(r.receipt_date,r.created_at,r.updated_at,now())
from public.loyverse_receipts r
left join public.avopuntos_accounts a on a.profile_id=r.profile_id
where r.receipt_number='5-1592'
  and r.profile_id is not null
  and r.receipt_type='SALE'
  and r.cancelled_at is null
on conflict (source_key) do update
set details=excluded.details;

update public.avopuntos_movements
set created_at = coalesce(
  (select r.receipt_date
   from public.loyverse_receipts r
   where r.receipt_number=public.avopuntos_movements.receipt_number),
  created_at
)
where source_key='receipt:5-1592:event:purchase';