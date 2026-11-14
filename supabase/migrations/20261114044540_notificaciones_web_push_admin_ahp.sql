create schema if not exists private;

create table if not exists public.ah_admin_push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null unique check (endpoint ~ '^https://'),
  p256dh text not null,
  auth text not null,
  device_label text,
  user_agent text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

create index if not exists ah_admin_push_subscriptions_user_idx
  on public.ah_admin_push_subscriptions(user_id);

alter table public.ah_admin_push_subscriptions enable row level security;
revoke all on public.ah_admin_push_subscriptions from public, anon, authenticated;
grant all on public.ah_admin_push_subscriptions to service_role;

create or replace function public.get_ah_push_config()
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_object_agg(v.name, v.decrypted_secret),
    '{}'::jsonb
  )
  from vault.decrypted_secrets v
  where v.name in (
    'ah_push_vapid_public_key',
    'ah_push_vapid_private_key',
    'ah_push_vapid_subject',
    'ah_push_webhook_secret'
  );
$$;

revoke all on function public.get_ah_push_config() from public, anon, authenticated;
grant execute on function public.get_ah_push_config() to service_role;

create or replace function private.dispatch_ah_admin_push(
  p_event_type text,
  p_title text,
  p_body text,
  p_url text,
  p_tag text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project_url text;
  v_webhook_secret text;
begin
  select v.decrypted_secret into v_project_url
  from vault.decrypted_secrets v
  where v.name = 'ah_push_project_url'
  limit 1;

  select v.decrypted_secret into v_webhook_secret
  from vault.decrypted_secrets v
  where v.name = 'ah_push_webhook_secret'
  limit 1;

  if nullif(v_project_url, '') is null or nullif(v_webhook_secret, '') is null then
    raise warning 'AHP push notification secrets are not configured.';
    return;
  end if;

  perform net.http_post(
    url := pg_catalog.rtrim(v_project_url, '/') || '/functions/v1/admin-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-ah-push-secret', v_webhook_secret
    ),
    body := jsonb_build_object(
      'action', 'dispatch',
      'event_type', p_event_type,
      'title', p_title,
      'body', p_body,
      'url', p_url,
      'tag', p_tag
    ),
    timeout_milliseconds := 5000
  );
exception
  when others then
    raise warning 'AHP push dispatch could not be queued (SQLSTATE %).', SQLSTATE;
end;
$$;

create or replace function private.notify_ah_new_registration()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.dispatch_ah_admin_push(
    'new_registration',
    'Nuevo registro en AHP',
    'Se creó la cuenta @' || coalesce(nullif(btrim(new.username), ''), 'usuario'),
    '/cuenta/admin/index.html',
    'ah-registration-' || left(new.id::text, 24)
  );
  return new;
exception
  when others then
    raise warning 'AHP registration notification trigger failed (SQLSTATE %).', SQLSTATE;
    return new;
end;
$$;

create or replace function private.notify_ah_new_song_suggestion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.dispatch_ah_admin_push(
    'new_song_suggestion',
    'Nueva sugerencia musical',
    coalesce(new.artist, 'Artista desconocido') || ' — ' || coalesce(new.title, 'Canción sin título'),
    '/ahtv/admin/index.html#songSuggestionsCard',
    'ah-suggestion-' || left(new.id::text, 24)
  );
  return new;
exception
  when others then
    raise warning 'AHP song suggestion notification trigger failed (SQLSTATE %).', SQLSTATE;
    return new;
end;
$$;

create or replace function private.notify_ah_manual_song_request()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text;
  v_request_mode text;
  v_requests_enabled boolean;
  v_artist text;
  v_title text;
  v_username text;
  v_is_admin boolean := false;
begin
  select
    r.status,
    coalesce(s.request_mode, 'automatico'),
    coalesce(s.requests_enabled, false),
    song.artist,
    song.title,
    r.username_snapshot,
    exists (
      select 1
      from public.admin_users au
      where au.user_id = r.user_id
    )
  into
    v_status,
    v_request_mode,
    v_requests_enabled,
    v_artist,
    v_title,
    v_username,
    v_is_admin
  from public.requests r
  join public.ahtv_settings s on s.id = 1
  left join public.songs song on song.id = r.song_id
  where r.id = new.id;

  if not found
     or v_status <> 'pending'
     or v_request_mode <> 'manual'
     or not v_requests_enabled
     or v_is_admin then
    return new;
  end if;

  perform private.dispatch_ah_admin_push(
    'manual_song_request',
    'Solicitud musical pendiente',
    coalesce(v_artist, 'Artista desconocido') || ' — ' ||
      coalesce(v_title, 'Canción sin título') ||
      case
        when nullif(btrim(v_username), '') is not null
          then ' · @' || btrim(v_username)
        else ''
      end ||
      '. Revisa si aprobarla o rechazarla.',
    '/ahtv/admin/index.html',
    'ah-request-' || left(new.id::text, 24)
  );

  return new;
exception
  when others then
    raise warning 'AHP manual song request notification trigger failed (SQLSTATE %).', SQLSTATE;
    return new;
end;
$$;

drop trigger if exists zz_ah_notify_new_registration on public.profiles;
create trigger zz_ah_notify_new_registration
after insert on public.profiles
for each row execute function private.notify_ah_new_registration();

drop trigger if exists zz_ah_notify_new_song_suggestion on public.ahtv_song_suggestions;
create trigger zz_ah_notify_new_song_suggestion
after insert on public.ahtv_song_suggestions
for each row execute function private.notify_ah_new_song_suggestion();

drop trigger if exists zz_ah_notify_manual_song_request on public.requests;
create trigger zz_ah_notify_manual_song_request
after insert on public.requests
for each row execute function private.notify_ah_manual_song_request();
