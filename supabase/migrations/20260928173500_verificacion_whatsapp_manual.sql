-- Verificación manual de WhatsApp para AvoPuntos
create table if not exists public.avopuntos_contact_verifications (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  channel text not null check (channel = 'whatsapp'),
  contact_value text not null check (contact_value ~ '^\+57[0-9]{10}$'),
  code text not null check (code ~ '^[0-9]{6}$'),
  status text not null default 'pending' check (status in ('pending','verified','cancelled')),
  bonus_points bigint not null default 1000 check (bonus_points >= 0),
  bonus_granted boolean not null default false,
  verified_by uuid references auth.users(id) on delete set null,
  requested_at timestamptz not null default now(),
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists avopuntos_contact_verifications_contact_idx
  on public.avopuntos_contact_verifications(channel, contact_value, status);

create index if not exists avopuntos_contact_verifications_profile_channel_idx
  on public.avopuntos_contact_verifications(profile_id, channel, created_at desc);

create unique index if not exists avopuntos_contact_verifications_pending_profile_channel_idx
  on public.avopuntos_contact_verifications(profile_id, channel)
  where status = 'pending';

alter table public.avopuntos_contact_verifications enable row level security;

drop policy if exists "Clientes y admins pueden consultar verificaciones" on public.avopuntos_contact_verifications;
create policy "Clientes y admins pueden consultar verificaciones"
  on public.avopuntos_contact_verifications
  for select
  to authenticated
  using (
    auth.uid() = profile_id
    or public.avopuntos_admin_is_admin()
  );

create or replace function public.avopuntos_normalize_whatsapp(p_value text)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  v_digits text;
begin
  v_digits := regexp_replace(coalesce(p_value, ''), '[^0-9]', '', 'g');

  if length(v_digits) = 10 then
    return '+57' || v_digits;
  end if;

  if length(v_digits) = 12 and left(v_digits, 2) = '57' then
    return '+' || v_digits;
  end if;

  return null;
end;
$$;

create or replace function public.avopuntos_request_whatsapp_verification()
returns table (
  verification_id uuid,
  contact_value text,
  code text,
  status text,
  bonus_points bigint,
  bonus_eligible boolean,
  requested_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_whatsapp text;
  v_contact text;
  v_existing public.avopuntos_contact_verifications%rowtype;
  v_bonus_eligible boolean;
begin
  if v_user_id is null then
    raise exception 'Debes iniciar sesión para verificar WhatsApp.';
  end if;

  select p.whatsapp
    into v_whatsapp
  from public.profiles p
  where p.id = v_user_id;

  if not found or nullif(trim(v_whatsapp), '') is null then
    raise exception 'No hay un número de WhatsApp registrado en tu cuenta.';
  end if;

  v_contact := public.avopuntos_normalize_whatsapp(v_whatsapp);

  if v_contact is null then
    raise exception 'El número de WhatsApp registrado no tiene un formato válido.';
  end if;

  select *
    into v_existing
  from public.avopuntos_contact_verifications v
  where v.profile_id = v_user_id
    and v.channel = 'whatsapp'
    and v.status in ('pending','verified')
  order by v.created_at desc
  limit 1;

  if found then
    select not exists (
      select 1
      from public.avopuntos_contact_verifications other_v
      where other_v.channel = 'whatsapp'
        and other_v.contact_value = v_existing.contact_value
        and other_v.status = 'verified'
        and other_v.profile_id <> v_user_id
    )
    into v_bonus_eligible;

    return query
    select
      v_existing.id,
      v_existing.contact_value,
      v_existing.code,
      v_existing.status,
      v_existing.bonus_points,
      case
        when v_existing.status = 'verified' then v_existing.bonus_granted = false
          and v_bonus_eligible
        else v_bonus_eligible
      end,
      v_existing.requested_at;
    return;
  end if;

  v_bonus_eligible := not exists (
    select 1
    from public.avopuntos_contact_verifications other_v
    where other_v.channel = 'whatsapp'
      and other_v.contact_value = v_contact
      and other_v.status = 'verified'
      and other_v.profile_id <> v_user_id
  );

  insert into public.avopuntos_contact_verifications (
    profile_id, channel, contact_value, code, status, bonus_points, bonus_granted
  )
  values (
    v_user_id,
    'whatsapp',
    v_contact,
    lpad((floor(random() * 1000000))::bigint::text, 6, '0'),
    'pending',
    1000,
    false
  )
  returning * into v_existing;

  return query
  select
    v_existing.id,
    v_existing.contact_value,
    v_existing.code,
    v_existing.status,
    v_existing.bonus_points,
    v_bonus_eligible,
    v_existing.requested_at;
end;
$$;

create or replace function public.avopuntos_admin_verify_whatsapp(p_verification_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_verification public.avopuntos_contact_verifications%rowtype;
  v_current_whatsapp text;
  v_current_contact text;
  v_bonus integer := 0;
  v_bonus_granted boolean := false;
  v_balance bigint := 0;
  v_source_key text;
begin
  if v_admin_id is null or not public.avopuntos_admin_is_admin() then
    raise exception 'No tienes permisos para validar verificaciones.';
  end if;

  select *
    into v_verification
  from public.avopuntos_contact_verifications v
  where v.id = p_verification_id
  for update;

  if not found then
    raise exception 'No se encontró la solicitud de verificación.';
  end if;

  if v_verification.channel <> 'whatsapp' then
    raise exception 'El canal de esta solicitud no es WhatsApp.';
  end if;

  if v_verification.status <> 'pending' then
    select a.balance into v_balance
    from public.avopuntos_accounts a
    where a.profile_id = v_verification.profile_id;

    return jsonb_build_object(
      'verification_id', v_verification.id,
      'status', v_verification.status,
      'bonus_points', case when v_verification.bonus_granted then v_verification.bonus_points else 0 end,
      'bonus_granted', v_verification.bonus_granted,
      'balance', coalesce(v_balance, 0),
      'contact_value', v_verification.contact_value
    );
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(v_verification.channel || ':' || v_verification.contact_value, 0)
  );

  select p.whatsapp
    into v_current_whatsapp
  from public.profiles p
  where p.id = v_verification.profile_id;

  v_current_contact := public.avopuntos_normalize_whatsapp(v_current_whatsapp);

  if v_current_contact is null or v_current_contact <> v_verification.contact_value then
    raise exception 'El número de WhatsApp registrado cambió. Genera una nueva solicitud de verificación.';
  end if;

  if exists (
    select 1
    from public.avopuntos_contact_verifications other_v
    where other_v.channel = 'whatsapp'
      and other_v.contact_value = v_verification.contact_value
      and other_v.status = 'verified'
      and other_v.profile_id <> v_verification.profile_id
  ) then
    v_bonus := 0;
    v_bonus_granted := false;
  elsif exists (
    select 1
    from public.avopuntos_contact_verifications own_v
    where own_v.channel = 'whatsapp'
      and own_v.profile_id = v_verification.profile_id
      and own_v.status = 'verified'
      and own_v.bonus_granted = true
  ) then
    v_bonus := 0;
    v_bonus_granted := false;
  else
    v_bonus := greatest(0, v_verification.bonus_points::integer);
    v_bonus_granted := v_bonus > 0;
  end if;

  if v_bonus_granted then
    v_source_key := 'whatsapp_verification_bonus:' || v_verification.id::text;

    insert into public.avopuntos_movements (
      profile_id,
      movement_type,
      points_delta,
      source_key,
      details
    )
    values (
      v_verification.profile_id,
      'earn',
      v_bonus,
      v_source_key,
      jsonb_build_object(
        'bonus_type', 'whatsapp_verification',
        'verification_id', v_verification.id,
        'channel', 'whatsapp',
        'contact_value', v_verification.contact_value,
        'admin_user_id', v_admin_id,
        'description', 'Bonificación única por verificación manual de WhatsApp'
      )
    );

    update public.avopuntos_accounts
      set balance = balance + v_bonus,
          updated_at = now()
    where profile_id = v_verification.profile_id
    returning balance into v_balance;

    if not found then
      raise exception 'No existe la cuenta AvoPuntos asociada al cliente.';
    end if;
  else
    select a.balance into v_balance
    from public.avopuntos_accounts a
    where a.profile_id = v_verification.profile_id;
  end if;

  update public.avopuntos_contact_verifications
    set status = 'verified',
        bonus_granted = v_bonus_granted,
        verified_by = v_admin_id,
        verified_at = now(),
        updated_at = now()
  where id = v_verification.id;

  insert into public.avopuntos_admin_changes (
    admin_user_id,
    entity_type,
    entity_id,
    action,
    details
  )
  values (
    v_admin_id,
    'whatsapp_verification',
    v_verification.id,
    'verify',
    jsonb_build_object(
      'profile_id', v_verification.profile_id,
      'channel', 'whatsapp',
      'contact_value', v_verification.contact_value,
      'bonus_points', v_bonus,
      'bonus_granted', v_bonus_granted
    )
  );

  return jsonb_build_object(
    'verification_id', v_verification.id,
    'profile_id', v_verification.profile_id,
    'status', 'verified',
    'bonus_points', v_bonus,
    'bonus_granted', v_bonus_granted,
    'balance', coalesce(v_balance, 0),
    'contact_value', v_verification.contact_value
  );
end;
$$;

grant execute on function public.avopuntos_request_whatsapp_verification() to authenticated;
grant execute on function public.avopuntos_admin_verify_whatsapp(uuid) to authenticated;
