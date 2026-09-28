create or replace function public.ahtv_validar_solicitud()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_active_count integer;
  v_existing_user_id uuid;
  v_recent_exists boolean;
  v_username text;
  v_is_admin boolean := false;
begin
  if auth.uid() is not null then
    select exists(select 1 from public.admin_users au where au.user_id=auth.uid()) into v_is_admin;
  end if;
  if v_is_admin then return NEW; end if;

  if auth.uid() is null or NEW.user_id is null or NEW.user_id <> auth.uid() then
    raise exception 'Debes iniciar sesión para solicitar música.' using errcode='P0001';
  end if;

  select p.username into v_username from public.profiles p where p.id=NEW.user_id;
  if v_username is null then
    raise exception 'No fue posible cargar tu nickname.' using errcode='P0001';
  end if;
  NEW.username_snapshot:=v_username;

  if not public.ahtv_solicitudes_habilitadas() then
    raise exception 'Las solicitudes están cerradas en este momento.' using errcode='P0001';
  end if;

  perform pg_advisory_xact_lock(hashtext('ahtv:user:'||NEW.user_id::text));

  select count(*) into v_active_count
  from public.requests r
  where r.user_id=NEW.user_id and r.status in ('pending','accepted','playing','merged');

  if v_active_count>=2 then
    raise exception 'Ya tienes 2 solicitudes activas. Espera a que una se reproduzca antes de pedir otra.' using errcode='P0001';
  end if;

  select r.id into v_existing_user_id
  from public.requests r
  where r.user_id=NEW.user_id and r.song_id=NEW.song_id and r.status in ('pending','accepted','playing','merged')
  order by r.requested_at nulls last,r.id
  limit 1;

  if v_existing_user_id is not null then
    raise exception 'Esta canción ya está en tus solicitudes.' using errcode='P0001';
  end if;

  select exists(
    select 1 from public.requests r
    where r.user_id=NEW.user_id and r.song_id=NEW.song_id and r.status in ('played','rejected')
      and coalesce(r.played_at,r.rejected_at,r.requested_at)>=now()-interval '1 hour'
  ) into v_recent_exists;

  if v_recent_exists then
    raise exception 'Esta canción fue escuchada recientemente. Podrás pedirla de nuevo más adelante.' using errcode='P0001';
  end if;

  return NEW;
end;
$function$;

create or replace function public.ahtv_unificar_solicitud()
returns trigger
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_existing_id uuid;
  v_mode text;
  v_is_admin boolean := false;
begin
  if auth.uid() is not null then
    select exists(select 1 from public.admin_users au where au.user_id=auth.uid()) into v_is_admin;
  end if;
  if v_is_admin then return NEW; end if;

  perform pg_advisory_xact_lock(hashtext('ahtv:song:'||NEW.song_id::text));

  select r.id into v_existing_id
  from public.requests r
  where r.id<>NEW.id and r.song_id=NEW.song_id and r.status in ('pending','accepted','playing')
  order by case when r.status='playing' then 0 else 1 end,
           r.queue_position nulls last,r.accepted_at nulls last,r.requested_at nulls last,r.id
  limit 1;

  if v_existing_id is not null then
    update public.requests set status='merged',merged_into=v_existing_id,queue_position=null,
      accepted_at=null,started_at=null,played_at=null,rejected_at=null where id=NEW.id;
    return NEW;
  end if;

  select request_mode into v_mode from public.ahtv_settings where id=1;
  if coalesce(v_mode,'automatico')='automatico' then
    update public.requests set status='accepted',accepted_at=now(),merged_into=null where id=NEW.id;
  end if;
  return NEW;
end;
$function$;

create or replace function public.ahtv_admin_queue_song(p_song_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_admin uuid;
  v_song public.songs%rowtype;
  v_request public.requests%rowtype;
begin
  v_admin:=auth.uid();
  if v_admin is null or not exists(select 1 from public.admin_users where user_id=v_admin) then
    raise exception 'No autorizado.';
  end if;

  select * into v_song from public.songs where id=p_song_id and active=true;
  if not found then raise exception 'La canción no existe o está inactiva.'; end if;

  insert into public.requests(song_id,client_token,status,user_id,username_snapshot)
  values(v_song.id,'admin:'||gen_random_uuid()::text,'accepted',v_admin,'Administrador')
  returning * into v_request;

  return jsonb_build_object(
    'ok',true,'request_id',v_request.id,'song_id',v_song.id,
    'artist',v_song.artist,'title',v_song.title,'status',v_request.status,
    'queue_position',v_request.queue_position
  );
end;
$function$;

revoke all on function public.ahtv_admin_queue_song(uuid) from public;
grant execute on function public.ahtv_admin_queue_song(uuid) to authenticated;
