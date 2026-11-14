CREATE OR REPLACE FUNCTION private.notify_ah_manual_song_request()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    '/ahtv/admin/index.html#pendingRequestsCard',
    'ah-request-' || left(new.id::text, 24)
  );

  return new;
exception
  when others then
    raise warning 'AHP manual song request notification trigger failed (SQLSTATE %).', SQLSTATE;
    return new;
end;
$function$
;