create table if not exists public.avopuntos_promotions (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  multiplier numeric(10,2) not null,
  start_date date not null,
  end_date date,
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint avopuntos_promotions_name_chk check (char_length(trim(name)) between 1 and 120),
  constraint avopuntos_promotions_multiplier_chk check (multiplier > 0 and multiplier <= 100),
  constraint avopuntos_promotions_dates_chk check (end_date is null or end_date >= start_date)
);

create index if not exists avopuntos_promotions_active_dates_idx
on public.avopuntos_promotions(active,start_date,end_date);

create table if not exists public.avopuntos_customer_rules (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  multiplier numeric(10,2) not null,
  start_date date not null,
  end_date date,
  active boolean not null default true,
  reason text not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint avopuntos_customer_rules_multiplier_chk check (multiplier > 0 and multiplier <= 100),
  constraint avopuntos_customer_rules_reason_chk check (char_length(trim(reason)) between 1 and 500),
  constraint avopuntos_customer_rules_dates_chk check (end_date is null or end_date >= start_date)
);

create index if not exists avopuntos_customer_rules_profile_dates_idx
on public.avopuntos_customer_rules(profile_id,active,start_date desc,created_at desc);

create table if not exists public.avopuntos_admin_changes (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid references auth.users(id) on delete set null,
  entity_type text not null,
  entity_id uuid,
  action text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists avopuntos_admin_changes_created_idx
on public.avopuntos_admin_changes(created_at desc);

create or replace function public.avopuntos_admin_is_admin()
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select exists(select 1 from public.admin_users where user_id=auth.uid());
$$;

revoke all on function public.avopuntos_admin_is_admin() from public;
grant execute on function public.avopuntos_admin_is_admin() to authenticated;

alter table public.avopuntos_promotions enable row level security;
alter table public.avopuntos_customer_rules enable row level security;
alter table public.avopuntos_admin_changes enable row level security;

drop policy if exists "Admins can view AvoPuntos promotions" on public.avopuntos_promotions;
create policy "Admins can view AvoPuntos promotions"
on public.avopuntos_promotions for select to authenticated
using (public.avopuntos_admin_is_admin());

drop policy if exists "Admins can view customer AvoPuntos rules" on public.avopuntos_customer_rules;
create policy "Admins can view customer AvoPuntos rules"
on public.avopuntos_customer_rules for select to authenticated
using (public.avopuntos_admin_is_admin());

drop policy if exists "Admins can view AvoPuntos admin changes" on public.avopuntos_admin_changes;
create policy "Admins can view AvoPuntos admin changes"
on public.avopuntos_admin_changes for select to authenticated
using (public.avopuntos_admin_is_admin());

create or replace function public.avopuntos_admin_get_settings()
returns jsonb language plpgsql security definer set search_path=public
as $$
declare
  v_admin uuid:=auth.uid();
  v_config public.avopuntos_config%rowtype;
  v_promotions jsonb;
begin
  if v_admin is null or not exists(select 1 from public.admin_users where user_id=v_admin) then raise exception 'No autorizado.'; end if;
  select * into v_config from public.avopuntos_config where config_id=true limit 1;
  if not found then raise exception 'No existe la configuración de AvoPuntos.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',p.id,'name',p.name,'multiplier',p.multiplier,'start_date',p.start_date,
    'end_date',p.end_date,'active',p.active,'created_at',p.created_at,'updated_at',p.updated_at
  ) order by p.active desc,p.start_date desc,p.created_at desc),'[]'::jsonb)
  into v_promotions from public.avopuntos_promotions p;
  return jsonb_build_object(
    'points_per_thousand',v_config.points_per_thousand,
    'point_value_money',v_config.point_value_money,
    'rounding_mode',v_config.rounding_mode,
    'promotions',v_promotions
  );
end;
$$;

revoke all on function public.avopuntos_admin_get_settings() from public;
grant execute on function public.avopuntos_admin_get_settings() to authenticated;

create or replace function public.avopuntos_admin_update_base_rate(p_points_per_thousand integer)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare
  v_admin uuid:=auth.uid();
  v_config public.avopuntos_config%rowtype;
  v_old integer;
begin
  if v_admin is null or not exists(select 1 from public.admin_users where user_id=v_admin) then raise exception 'No autorizado.'; end if;
  if p_points_per_thousand is null or p_points_per_thousand<0 or p_points_per_thousand>100000 then
    raise exception 'La tasa base debe ser un número entero entre 0 y 100000 AP por cada $1.000.';
  end if;
  select * into v_config from public.avopuntos_config where config_id=true for update;
  if not found then raise exception 'No existe la configuración de AvoPuntos.'; end if;
  v_old:=v_config.points_per_thousand;
  if v_old=p_points_per_thousand then
    return jsonb_build_object('ok',true,'changed',false,'points_per_thousand',v_old);
  end if;
  insert into public.avopuntos_admin_changes(admin_user_id,entity_type,action,details)
  values(v_admin,'config','update_base_rate',jsonb_build_object(
    'previous_points_per_thousand',v_old,'new_points_per_thousand',p_points_per_thousand));
  update public.avopuntos_config
  set points_per_thousand=p_points_per_thousand,updated_at=now()
  where config_id=true;
  return jsonb_build_object('ok',true,'changed',true,
    'previous_points_per_thousand',v_old,'points_per_thousand',p_points_per_thousand);
end;
$$;

revoke all on function public.avopuntos_admin_update_base_rate(integer) from public;
grant execute on function public.avopuntos_admin_update_base_rate(integer) to authenticated;

create or replace function public.avopuntos_admin_create_promotion(
  p_name text,p_multiplier numeric,p_start_date date,p_end_date date
)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare
  v_admin uuid:=auth.uid();
  v_id uuid;
  v_name text:=nullif(trim(coalesce(p_name,'')),'');
begin
  if v_admin is null or not exists(select 1 from public.admin_users where user_id=v_admin) then raise exception 'No autorizado.'; end if;
  if v_name is null or char_length(v_name)>120 then raise exception 'El nombre de la promoción debe tener entre 1 y 120 caracteres.'; end if;
  if p_multiplier is null or p_multiplier<=0 or p_multiplier>100 then raise exception 'El multiplicador debe estar entre 0,01× y 100×.'; end if;
  if p_start_date is null then raise exception 'La fecha de inicio es obligatoria.'; end if;
  if p_end_date is not null and p_end_date<p_start_date then raise exception 'La fecha final no puede ser anterior a la fecha inicial.'; end if;
  insert into public.avopuntos_promotions(name,multiplier,start_date,end_date,active,created_by)
  values(v_name,p_multiplier,p_start_date,p_end_date,true,v_admin)
  returning id into v_id;
  insert into public.avopuntos_admin_changes(admin_user_id,entity_type,entity_id,action,details)
  values(v_admin,'promotion',v_id,'create',jsonb_build_object(
    'name',v_name,'multiplier',p_multiplier,'start_date',p_start_date,'end_date',p_end_date));
  return jsonb_build_object('ok',true,'id',v_id);
end;
$$;

revoke all on function public.avopuntos_admin_create_promotion(text,numeric,date,date) from public;
grant execute on function public.avopuntos_admin_create_promotion(text,numeric,date,date) to authenticated;

create or replace function public.avopuntos_admin_set_promotion_active(p_promotion_id uuid,p_active boolean)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare
  v_admin uuid:=auth.uid();
  v_p public.avopuntos_promotions%rowtype;
begin
  if v_admin is null or not exists(select 1 from public.admin_users where user_id=v_admin) then raise exception 'No autorizado.'; end if;
  select * into v_p from public.avopuntos_promotions where id=p_promotion_id for update;
  if not found then raise exception 'No existe la promoción seleccionada.'; end if;
  update public.avopuntos_promotions set active=coalesce(p_active,false),updated_at=now() where id=p_promotion_id;
  insert into public.avopuntos_admin_changes(admin_user_id,entity_type,entity_id,action,details)
  values(v_admin,'promotion',p_promotion_id,case when p_active then 'activate' else 'deactivate' end,
    jsonb_build_object('previous_active',v_p.active,'new_active',coalesce(p_active,false)));
  return jsonb_build_object('ok',true,'id',p_promotion_id,'active',coalesce(p_active,false));
end;
$$;

revoke all on function public.avopuntos_admin_set_promotion_active(uuid,boolean) from public;
grant execute on function public.avopuntos_admin_set_promotion_active(uuid,boolean) to authenticated;

create or replace function public.avopuntos_admin_set_customer_multiplier(
  p_profile_id uuid,p_multiplier numeric,p_start_date date,p_end_date date,p_reason text
)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare
  v_admin uuid:=auth.uid();
  v_reason text:=nullif(trim(coalesce(p_reason,'')),'');
  v_id uuid;
  v_deactivated integer:=0;
begin
  if v_admin is null or not exists(select 1 from public.admin_users where user_id=v_admin) then raise exception 'No autorizado.'; end if;
  if p_profile_id is null or not exists(select 1 from public.profiles where id=p_profile_id) then raise exception 'No existe el cliente seleccionado.'; end if;
  if p_multiplier is null or p_multiplier<=0 or p_multiplier>100 then raise exception 'El multiplicador debe estar entre 0,01× y 100×.'; end if;
  if p_start_date is null then raise exception 'La fecha de inicio es obligatoria.'; end if;
  if p_end_date is not null and p_end_date<p_start_date then raise exception 'La fecha final no puede ser anterior a la fecha inicial.'; end if;
  if v_reason is null or char_length(v_reason)>500 then raise exception 'Debes indicar un motivo de hasta 500 caracteres.'; end if;

  update public.avopuntos_customer_rules
  set active=false,updated_at=now()
  where profile_id=p_profile_id and active=true;
  get diagnostics v_deactivated=row_count;

  insert into public.avopuntos_customer_rules(
    profile_id,multiplier,start_date,end_date,active,reason,created_by
  ) values(p_profile_id,p_multiplier,p_start_date,p_end_date,true,v_reason,v_admin)
  returning id into v_id;

  insert into public.avopuntos_admin_changes(
    admin_user_id,entity_type,entity_id,action,details
  ) values(v_admin,'customer_rule',v_id,'create',jsonb_build_object(
    'profile_id',p_profile_id,'multiplier',p_multiplier,'start_date',p_start_date,
    'end_date',p_end_date,'reason',v_reason,
    'previous_active_rules_deactivated',v_deactivated
  ));

  return jsonb_build_object('ok',true,'id',v_id,'previous_active_rules_deactivated',v_deactivated);
end;
$$;

revoke all on function public.avopuntos_admin_set_customer_multiplier(uuid,numeric,date,date,text) from public;
grant execute on function public.avopuntos_admin_set_customer_multiplier(uuid,numeric,date,date,text) to authenticated;

create or replace function public.avopuntos_admin_set_customer_rule_active(p_rule_id uuid,p_active boolean)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare
  v_admin uuid:=auth.uid();
  v_rule public.avopuntos_customer_rules%rowtype;
begin
  if v_admin is null or not exists(select 1 from public.admin_users where user_id=v_admin) then raise exception 'No autorizado.'; end if;
  select * into v_rule from public.avopuntos_customer_rules where id=p_rule_id for update;
  if not found then raise exception 'No existe el beneficio seleccionado.'; end if;
  update public.avopuntos_customer_rules set active=coalesce(p_active,false),updated_at=now() where id=p_rule_id;
  insert into public.avopuntos_admin_changes(admin_user_id,entity_type,entity_id,action,details)
  values(v_admin,'customer_rule',p_rule_id,case when p_active then 'activate' else 'deactivate' end,
    jsonb_build_object('profile_id',v_rule.profile_id,'previous_active',v_rule.active,'new_active',coalesce(p_active,false)));
  return jsonb_build_object('ok',true,'id',p_rule_id,'active',coalesce(p_active,false));
end;
$$;

revoke all on function public.avopuntos_admin_set_customer_rule_active(uuid,boolean) from public;
grant execute on function public.avopuntos_admin_set_customer_rule_active(uuid,boolean) to authenticated;

-- The active receipt processor is replaced by the deployed function in the database with
-- base-rate, promotion and customer-rule selection. Historical receipts are not recalculated.
