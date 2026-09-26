alter table public.avopuntos_accounts
  add column last_loyverse_sync_attempt_at timestamptz,
  add column last_loyverse_sync_error text;