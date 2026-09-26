create table if not exists public.loyverse_sync_state (
  sync_key text primary key,
  last_updated_at timestamptz not null,
  pagination_cursor text,
  pagination_window_start timestamptz,
  last_run_at timestamptz,
  last_success_at timestamptz,
  records_last_run integer not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.loyverse_receipts (
  receipt_number text primary key,
  receipt_type text not null check (receipt_type in ('SALE','REFUND')),
  refund_for text,
  customer_id text,
  profile_id uuid references public.profiles(id) on delete set null,
  order_name text,
  source text,
  store_id text,
  employee_id text,
  pos_device_id text,
  receipt_date timestamptz,
  created_at timestamptz,
  updated_at timestamptz not null,
  cancelled_at timestamptz,
  total_money numeric,
  total_tax numeric,
  total_discount numeric,
  points_earned numeric,
  points_deducted numeric,
  points_balance numeric,
  line_items jsonb not null default '[]'::jsonb,
  payments jsonb not null default '[]'::jsonb,
  raw_receipt jsonb not null,
  synced_at timestamptz not null default now()
);

create index if not exists idx_loyverse_receipts_profile_id
  on public.loyverse_receipts(profile_id);

create index if not exists idx_loyverse_receipts_customer_id
  on public.loyverse_receipts(customer_id);

create index if not exists idx_loyverse_receipts_updated_at
  on public.loyverse_receipts(updated_at desc);

create index if not exists idx_loyverse_receipts_receipt_date
  on public.loyverse_receipts(receipt_date desc);

alter table public.loyverse_sync_state enable row level security;
alter table public.loyverse_receipts enable row level security;

drop policy if exists loyverse_sync_state_admin_select on public.loyverse_sync_state;
create policy loyverse_sync_state_admin_select
  on public.loyverse_sync_state
  for select
  to authenticated
  using (
    exists (
      select 1 from public.admin_users
      where admin_users.user_id = auth.uid()
    )
  );

drop policy if exists loyverse_sync_state_service_role on public.loyverse_sync_state;
create policy loyverse_sync_state_service_role
  on public.loyverse_sync_state
  for all
  to service_role
  using (true)
  with check (true);

drop policy if exists loyverse_receipts_admin_select on public.loyverse_receipts;
create policy loyverse_receipts_admin_select
  on public.loyverse_receipts
  for select
  to authenticated
  using (
    exists (
      select 1 from public.admin_users
      where admin_users.user_id = auth.uid()
    )
  );

drop policy if exists loyverse_receipts_service_role on public.loyverse_receipts;
create policy loyverse_receipts_service_role
  on public.loyverse_receipts
  for all
  to service_role
  using (true)
  with check (true);

grant select on public.loyverse_sync_state to authenticated;
grant select on public.loyverse_receipts to authenticated;
grant select, insert, update on public.loyverse_sync_state to service_role;
grant select, insert, update on public.loyverse_receipts to service_role;

insert into public.loyverse_sync_state (sync_key, last_updated_at)
values ('receipts', '2026-08-27T00:00:00Z')
on conflict (sync_key) do nothing;

do $$
declare
  v_jobid bigint;
begin
  select jobid into v_jobid
  from cron.job
  where jobname = 'avohouse_loyverse_receipts_sync'
  limit 1;
  if v_jobid is not null then
    perform cron.unschedule(v_jobid);
  end if;
end
$$;

select cron.schedule(
  'avohouse_loyverse_receipts_sync',
  '*/5 * * * *',
  $cron$
    select net.http_post(
      url := 'https://tjarildqqxtjmafpiyuz.supabase.co/functions/v1/loyverse-sync-sales',
      body := '{"mode":"sync"}'::jsonb,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-avohouse-loyverse-webhook-secret',
        (
          select decrypted_secret
          from vault.decrypted_secrets
          where name = 'avohouse_loyverse_webhook_secret'
          limit 1
        )
      ),
      timeout_milliseconds := 5000
    );
  $cron$
);

update public.loyverse_sync_state
set
  last_updated_at = '2026-08-27T00:00:00Z',
  pagination_cursor = null,
  pagination_window_start = null,
  last_run_at = null,
  last_success_at = null,
  records_last_run = 0,
  last_error = null,
  updated_at = now()
where sync_key = 'receipts';
