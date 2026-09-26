create extension if not exists pg_net;
create extension if not exists pg_cron;

create table if not exists public.loyverse_customers (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  loyverse_customer_id text unique,
  sync_status text not null default 'pending'
    check (sync_status in ('pending','processing','synced','error')),
  attempts integer not null default 0 check (attempts >= 0),
  last_attempt_at timestamptz,
  next_attempt_at timestamptz not null default now(),
  last_synced_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.loyverse_customers enable row level security;

grant select on public.loyverse_customers to authenticated;

drop policy if exists "Admins can read Loyverse sync state" on public.loyverse_customers;
create policy "Admins can read Loyverse sync state"
on public.loyverse_customers
for select
to authenticated
using (
  exists (
    select 1
    from public.admin_users
    where public.admin_users.user_id = auth.uid()
  )
);

do $$
begin
  if not exists (
    select 1
    from vault.secrets
    where name = 'avohouse_loyverse_webhook_secret'
  ) then
    perform vault.create_secret(
      encode(gen_random_bytes(32), 'hex'),
      'avohouse_loyverse_webhook_secret',
      'Secret interno para autenticar el webhook de sincronización AvoHouse -> Loyverse.'
    );
  end if;
end
$$;

create or replace function public.avohouse_validate_loyverse_webhook(p_secret text)
returns boolean
language sql
security definer
set search_path = public, vault
as $$
  select coalesce(
    (
      select decrypted_secret = p_secret
      from vault.decrypted_secrets
      where name = 'avohouse_loyverse_webhook_secret'
      limit 1
    ),
    false
  );
$$;

revoke all on function public.avohouse_validate_loyverse_webhook(text) from public, anon, authenticated;
grant execute on function public.avohouse_validate_loyverse_webhook(text) to service_role;

create or replace function public.avohouse_get_loyverse_api_token()
returns text
language sql
security definer
set search_path = public, vault
as $$
  select decrypted_secret
  from vault.decrypted_secrets
  where name = 'loyverse_api_token'
  limit 1;
$$;

revoke all on function public.avohouse_get_loyverse_api_token() from public, anon, authenticated;
grant execute on function public.avohouse_get_loyverse_api_token() to service_role;

insert into public.loyverse_customers (profile_id, sync_status)
select p.id, 'pending'
from public.profiles p
where not exists (
  select 1
  from public.admin_users a
  where a.user_id = p.id
)
on conflict (profile_id) do nothing;

create or replace function public.enqueue_loyverse_customer_sync()
returns trigger
language plpgsql
security definer
set search_path = public, vault
as $$
declare
  webhook_secret text;
begin
  insert into public.loyverse_customers (profile_id, sync_status, next_attempt_at)
  values (new.id, 'pending', now())
  on conflict (profile_id) do nothing;

  select decrypted_secret
    into webhook_secret
  from vault.decrypted_secrets
  where name = 'avohouse_loyverse_webhook_secret'
  limit 1;

  if webhook_secret is null then
    update public.loyverse_customers
    set
      sync_status = 'error',
      last_error = 'No está configurado el secreto interno de sincronización.',
      next_attempt_at = now() + interval '1 hour',
      updated_at = now()
    where profile_id = new.id;
    return new;
  end if;

  begin
    perform net.http_post(
      url := 'https://tjarildqqxtjmafpiyuz.supabase.co/functions/v1/loyverse-sync-customer',
      body := jsonb_build_object('user_id', new.id),
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-avohouse-loyverse-webhook-secret', webhook_secret
      ),
      timeout_milliseconds := 5000
    );
  exception
    when others then
      update public.loyverse_customers
      set
        sync_status = 'error',
        last_error = left(sqlerrm, 1000),
        next_attempt_at = now() + interval '10 minutes',
        updated_at = now()
      where profile_id = new.id;
  end;

  return new;
end;
$$;

drop trigger if exists trg_enqueue_loyverse_customer_sync on public.profiles;
create trigger trg_enqueue_loyverse_customer_sync
after insert on public.profiles
for each row
execute function public.enqueue_loyverse_customer_sync();

do $$
begin
  if not exists (
    select 1
    from cron.job
    where jobname = 'avohouse_loyverse_sync_retry'
  ) then
    perform cron.schedule(
      'avohouse_loyverse_sync_retry',
      '*/10 * * * *',
      $cron$
        select net.http_post(
          url := 'https://tjarildqqxtjmafpiyuz.supabase.co/functions/v1/loyverse-sync-customer',
          body := '{"mode":"pending"}'::jsonb,
          headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'x-avohouse-loyverse-webhook-secret',
            (select decrypted_secret
             from vault.decrypted_secrets
             where name = 'avohouse_loyverse_webhook_secret'
             limit 1)
          ),
          timeout_milliseconds := 5000
        );
      $cron$
    );
  end if;
end
$$;
