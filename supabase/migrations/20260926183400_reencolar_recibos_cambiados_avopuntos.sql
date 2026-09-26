create or replace function public.avopuntos_requeue_changed_receipt()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if
    old.avopuntos_status <> 'excluded_pre_activation'
    and (
      old.receipt_type is distinct from new.receipt_type
      or old.refund_for is distinct from new.refund_for
      or old.customer_id is distinct from new.customer_id
      or old.profile_id is distinct from new.profile_id
      or old.receipt_date is distinct from new.receipt_date
      or old.cancelled_at is distinct from new.cancelled_at
      or old.total_money is distinct from new.total_money
      or old.total_discount is distinct from new.total_discount
      or old.points_earned is distinct from new.points_earned
      or old.points_deducted is distinct from new.points_deducted
      or old.points_balance is distinct from new.points_balance
      or old.line_items is distinct from new.line_items
      or old.payments is distinct from new.payments
      or old.raw_receipt is distinct from new.raw_receipt
    )
  then
    if new.avopuntos_status in ('processed','manual_review','error','ignored_no_profile') then
      new.avopuntos_status := 'pending';
      new.avopuntos_processed_at := null;
      new.avopuntos_last_error := null;
    end if;
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