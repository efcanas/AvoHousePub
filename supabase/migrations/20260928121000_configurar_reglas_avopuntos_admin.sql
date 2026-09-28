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
\nCREATE OR REPLACE FUNCTION public.avopuntos_process_receipt(p_receipt_number text)\n RETURNS jsonb\n LANGUAGE plpgsql\n SECURITY DEFINER\n SET search_path TO 'public'\nAS $function$\ndeclare\n  r public.loyverse_receipts%rowtype;\n  st public.avopuntos_receipt_state%rowtype;\n  cfg public.avopuntos_config%rowtype;\n  acc public.avopuntos_accounts%rowtype;\n  v_input_hash text;\n  v_eligible_amount numeric(14,2) := 0;\n  v_redeemed_points bigint := 0;\n  v_earned_points bigint := 0;\n  v_old_earned bigint := 0;\n  v_old_redeemed bigint := 0;\n  v_earned_delta bigint := 0;\n  v_redeemed_delta bigint := 0;\n  v_net_delta bigint := 0;\n  v_new_balance bigint := 0;\n  v_version integer := 1;\n  v_now timestamptz := now();\n  v_payment jsonb;\n  v_discount jsonb;\n  v_payment_type_id uuid;\n  v_payment_amount numeric;\n  v_discount_type text;\n  v_discount_amount numeric;\n  orig public.loyverse_receipts%rowtype;\n  orig_st public.avopuntos_receipt_state%rowtype;\n  v_refund_ratio numeric := 0;\n  v_original_earned bigint := 0;\n  v_original_redeemed bigint := 0;\n  v_target_earned_reversal bigint := 0;\n  v_target_redeemed_restore bigint := 0;\n  v_old_refund_earned bigint := 0;\n  v_old_refund_redeemed bigint := 0;\n  v_redeemed_restore_delta bigint := 0;\n  v_source text;\n  v_business_date date;\n  v_multiplier numeric := 1;\n  v_rule_type text := 'base';\n  v_rule_name text := null;\n  v_rule_id uuid := null;\n  v_effective_points_per_thousand numeric;\nbegin\n  select * into r\n  from public.loyverse_receipts\n  where receipt_number=p_receipt_number\n  for update;\n\n  if not found then\n    return jsonb_build_object('ok',false,'status','not_found');\n  end if;\n\n  v_input_hash := public.avopuntos_receipt_input_hash(r);\n\n  select * into st\n  from public.avopuntos_receipt_state\n  where receipt_number=p_receipt_number\n  for update;\n\n  if r.profile_id is null then\n    update public.loyverse_receipts\n    set avopuntos_status='ignored_no_profile',\n        avopuntos_processed_at=v_now,\n        avopuntos_last_error=null\n    where receipt_number=p_receipt_number;\n\n    insert into public.avopuntos_receipt_state(\n      receipt_number,profile_id,input_hash,applied_earned_points,\n      applied_redeemed_points,last_receipt_updated_at,version,status,\n      last_error,processed_at,updated_at\n    ) values (\n      r.receipt_number,null,v_input_hash,0,0,r.updated_at,1,\n      'ignored',null,v_now,v_now\n    )\n    on conflict(receipt_number) do update\n    set profile_id=null,input_hash=excluded.input_hash,\n        applied_earned_points=0,applied_redeemed_points=0,\n        last_receipt_updated_at=excluded.last_receipt_updated_at,\n        version=excluded.version,status='ignored',last_error=null,\n        processed_at=excluded.processed_at,updated_at=excluded.updated_at;\n\n    return jsonb_build_object('ok',true,'status','ignored_no_profile','receipt_number',p_receipt_number);\n  end if;\n\n  select * into cfg\n  from public.avopuntos_config\n  where config_id=true and active=true;\n\n  if not found then\n    raise exception 'No existe una configuración activa de AvoPuntos.';\n  end if;\n\n  if st.receipt_number is not null\n     and st.input_hash=v_input_hash\n     and st.status in ('processed','manual_review','ignored')\n     and r.avopuntos_status<>'error'\n     and r.receipt_type<>'REFUND'\n  then\n    return jsonb_build_object(\n      'ok',true,'status',st.status,'receipt_number',p_receipt_number,\n      'profile_id',r.profile_id,\n      'balance',(select balance from public.avopuntos_accounts where profile_id=r.profile_id)\n    );\n  end if;\n\n  if st.receipt_number is not null\n     and st.profile_id is not null\n     and st.profile_id<>r.profile_id\n  then\n    update public.loyverse_receipts\n    set avopuntos_status='manual_review',\n        avopuntos_processed_at=v_now,\n        avopuntos_last_error='El recibo cambió de cliente asociado después de haber sido procesado.'\n    where receipt_number=p_receipt_number;\n\n    update public.avopuntos_receipt_state\n    set status='manual_review',\n        last_error='El recibo cambió de cliente asociado después de haber sido procesado.',\n        updated_at=v_now\n    where receipt_number=p_receipt_number;\n\n    return jsonb_build_object('ok',false,'status','manual_review','receipt_number',p_receipt_number);\n  end if;\n\n  if st.receipt_number is null then\n    v_old_earned:=0;\n    v_old_redeemed:=0;\n    v_version:=1;\n  else\n    v_old_earned:=st.applied_earned_points;\n    v_old_redeemed:=st.applied_redeemed_points;\n    v_version:=st.version+1;\n  end if;\n\n  if r.receipt_type='REFUND' then\n    v_old_refund_earned:=greatest(coalesce(st.applied_earned_points,0),0);\n    v_old_refund_redeemed:=greatest(coalesce(st.applied_redeemed_points,0),0);\n\n    if r.cancelled_at is not null then\n      v_target_earned_reversal:=0;\n      v_target_redeemed_restore:=0;\n    else\n      if r.refund_for is null then\n        update public.loyverse_receipts\n        set avopuntos_status='manual_review',\n            avopuntos_processed_at=v_now,\n            avopuntos_last_error='Reembolso sin ticket de origen.'\n        where receipt_number=p_receipt_number;\n        return jsonb_build_object('ok',false,'status','manual_review','receipt_number',r.receipt_number);\n      end if;\n\n      select * into orig\n      from public.loyverse_receipts\n      where receipt_number=r.refund_for\n      for update;\n\n      if not found then\n        update public.loyverse_receipts\n        set avopuntos_status='manual_review',\n            avopuntos_processed_at=v_now,\n            avopuntos_last_error='No se encontró el ticket de origen del reembolso.'\n        where receipt_number=p_receipt_number;\n        return jsonb_build_object('ok',false,'status','manual_review','receipt_number',r.receipt_number);\n      end if;\n\n      select * into orig_st\n      from public.avopuntos_receipt_state\n      where receipt_number=orig.receipt_number;\n\n      if orig_st.receipt_number is null or orig_st.status<>'processed' then\n        update public.loyverse_receipts\n        set avopuntos_status='manual_review',\n            avopuntos_processed_at=v_now,\n            avopuntos_last_error='El ticket de origen no tiene AvoPuntos procesados.'\n        where receipt_number=p_receipt_number;\n        return jsonb_build_object('ok',false,'status','manual_review','receipt_number',r.receipt_number);\n      end if;\n\n      v_original_earned:=greatest(coalesce(orig_st.applied_earned_points,0),0);\n      v_original_redeemed:=greatest(coalesce(orig_st.applied_redeemed_points,0),0);\n\n      if coalesce(orig.total_money,0)<=0 then\n        v_refund_ratio:=1;\n      else\n        v_refund_ratio:=least(\n          greatest(abs(coalesce(r.total_money,0))/orig.total_money,0),\n          1\n        );\n      end if;\n\n      v_target_earned_reversal:=round(v_original_earned*v_refund_ratio)::bigint;\n      v_target_redeemed_restore:=round(v_original_redeemed*v_refund_ratio)::bigint;\n    end if;\n\n    v_earned_delta:=v_target_earned_reversal-v_old_refund_earned;\n    v_redeemed_restore_delta:=v_target_redeemed_restore-v_old_refund_redeemed;\n    v_net_delta:=v_redeemed_restore_delta-v_earned_delta;\n\n    select * into acc\n    from public.avopuntos_accounts\n    where profile_id=r.profile_id\n    for update;\n\n    if not found then\n      insert into public.avopuntos_accounts(profile_id)\n      values(r.profile_id)\n      returning * into acc;\n    end if;\n\n    v_new_balance:=acc.balance+v_net_delta;\n\n    if v_new_balance<0 then\n      update public.loyverse_receipts\n      set avopuntos_status='manual_review',\n          avopuntos_processed_at=v_now,\n          avopuntos_last_error='El reembolso produciría un saldo negativo de AvoPuntos.'\n      where receipt_number=p_receipt_number;\n      return jsonb_build_object('ok',false,'status','error','receipt_number',r.receipt_number);\n    end if;\n\n    if v_earned_delta<>0 then\n      if v_earned_delta>0 then\n        v_source:='receipt:'||r.receipt_number||':refund-earn:v'||v_version;\n        insert into public.avopuntos_movements(\n          profile_id,movement_type,points_delta,receipt_number,related_receipt_number,source_key,details\n        ) values (\n          r.profile_id,'earn_reversal',-v_earned_delta,r.receipt_number,r.refund_for,v_source,\n          jsonb_build_object('refund_for',r.refund_for,'refund_ratio',v_refund_ratio,\n            'original_earned_points',v_original_earned,'refunded_amount',r.total_money,\n            'refund_cancellation',false)\n        );\n      else\n        v_source:='receipt:'||r.receipt_number||':refund-cancel-earn:v'||v_version;\n        insert into public.avopuntos_movements(\n          profile_id,movement_type,points_delta,receipt_number,related_receipt_number,source_key,details\n        ) values (\n          r.profile_id,'earn',-v_earned_delta,r.receipt_number,r.refund_for,v_source,\n          jsonb_build_object('refund_for',r.refund_for,'refund_cancellation',true,\n            'restored_points',-v_earned_delta)\n        );\n      end if;\n    end if;\n\n    if v_redeemed_restore_delta<>0 then\n      if v_redeemed_restore_delta>0 then\n        v_source:='receipt:'||r.receipt_number||':refund-redeem:v'||v_version;\n        insert into public.avopuntos_movements(\n          profile_id,movement_type,points_delta,receipt_number,related_receipt_number,source_key,details\n        ) values (\n          r.profile_id,'redeem_reversal',v_redeemed_restore_delta,r.receipt_number,r.refund_for,v_source,\n          jsonb_build_object('refund_for',r.refund_for,'refund_ratio',v_refund_ratio,\n            'original_redeemed_points',v_original_redeemed,'refunded_amount',r.total_money,\n            'refund_cancellation',false)\n        );\n      else\n        v_source:='receipt:'||r.receipt_number||':refund-cancel-redeem:v'||v_version;\n        insert into public.avopuntos_movements(\n          profile_id,movement_type,points_delta,receipt_number,related_receipt_number,source_key,details\n        ) values (\n          r.profile_id,'redeem',v_redeemed_restore_delta,r.receipt_number,r.refund_for,v_source,\n          jsonb_build_object('refund_for',r.refund_for,'refund_cancellation',true,\n            'removed_restored_points',-v_redeemed_restore_delta)\n        );\n      end if;\n    end if;\n\n    update public.avopuntos_accounts\n    set balance=v_new_balance,updated_at=v_now\n    where profile_id=r.profile_id;\n\n    insert into public.avopuntos_receipt_state(\n      receipt_number,profile_id,input_hash,applied_earned_points,applied_redeemed_points,\n      last_receipt_updated_at,version,status,last_error,processed_at,updated_at\n    ) values (\n      r.receipt_number,r.profile_id,v_input_hash,v_target_earned_reversal,v_target_redeemed_restore,\n      r.updated_at,greatest(coalesce(st.version,0),0)+1,'processed',null,v_now,v_now\n    )\n    on conflict(receipt_number) do update\n    set profile_id=excluded.profile_id,input_hash=excluded.input_hash,\n        applied_earned_points=excluded.applied_earned_points,\n        applied_redeemed_points=excluded.applied_redeemed_points,\n        last_receipt_updated_at=excluded.last_receipt_updated_at,\n        version=excluded.version,status='processed',last_error=null,\n        processed_at=excluded.processed_at,updated_at=excluded.updated_at;\n\n    update public.loyverse_receipts\n    set avopuntos_status='processed',avopuntos_processed_at=v_now,avopuntos_last_error=null,\n        points_earned=0,points_deducted=0,points_balance=v_new_balance\n    where receipt_number=p_receipt_number;\n\n    return jsonb_build_object(\n      'ok',true,'status','processed','receipt_number',r.receipt_number,\n      'profile_id',r.profile_id,'refund_for',r.refund_for,\n      'refund_ratio',v_refund_ratio,'earned_reversed',v_target_earned_reversal,\n      'redeemed_restored',v_target_redeemed_restore,'net_delta',v_net_delta,\n      'balance',v_new_balance,'refund_cancelled',(r.cancelled_at is not null)\n    );\n  end if;\n\n  if r.cancelled_at is null then\n    for v_payment in\n      select value from jsonb_array_elements(coalesce(r.payments,'[]'::jsonb))\n    loop\n      v_payment_type_id:=null;\n      if nullif(v_payment->>'payment_type_id','') is not null then\n        v_payment_type_id:=(v_payment->>'payment_type_id')::uuid;\n      end if;\n\n      v_payment_amount:=coalesce(nullif(v_payment->>'money_amount','')::numeric,0);\n\n      if v_payment_type_id is not null\n         and v_payment_amount>0\n         and exists(\n           select 1 from public.avopuntos_payment_methods pm\n           where pm.payment_type_id=v_payment_type_id\n             and pm.active=true and pm.eligible_for_avopuntos=true\n         )\n      then\n        v_eligible_amount:=v_eligible_amount+v_payment_amount;\n      end if;\n    end loop;\n\n    for v_discount in\n      select value from jsonb_array_elements(\n        coalesce(r.raw_receipt->'total_discounts','[]'::jsonb)\n      )\n    loop\n      v_discount_type:=upper(coalesce(v_discount->>'type',''));\n      v_discount_amount:=coalesce(nullif(v_discount->>'money_amount','')::numeric,0);\n\n      if v_discount_type='DISCOUNT_BY_POINTS' and v_discount_amount>0 then\n        v_redeemed_points:=v_redeemed_points+round(v_discount_amount)::bigint;\n      end if;\n    end loop;\n\n    v_business_date:=(r.receipt_date at time zone 'America/Bogota')::date;\n\n    select p.multiplier,p.name,p.id\n      into v_multiplier,v_rule_name,v_rule_id\n    from public.avopuntos_customer_rules p\n    where p.profile_id=r.profile_id\n      and p.active=true\n      and p.start_date<=v_business_date\n      and (p.end_date is null or p.end_date>=v_business_date)\n    order by p.start_date desc,p.created_at desc\n    limit 1;\n\n    if v_rule_id is not null then\n      v_rule_type:='customer';\n    else\n      v_multiplier:=1;\n      v_rule_name:=null;\n      v_rule_id:=null;\n\n      select p.multiplier,p.name,p.id\n        into v_multiplier,v_rule_name,v_rule_id\n      from public.avopuntos_promotions p\n      where p.active=true\n        and p.start_date<=v_business_date\n        and (p.end_date is null or p.end_date>=v_business_date)\n      order by p.start_date desc,p.created_at desc\n      limit 1;\n\n      if v_rule_id is not null then\n        v_rule_type:='promotion';\n      else\n        v_rule_type:='base';\n      end if;\n    end if;\n\n    v_effective_points_per_thousand:=cfg.points_per_thousand*v_multiplier;\n\n    v_earned_points:=round(\n      v_eligible_amount*v_effective_points_per_thousand/1000.0\n    )::bigint;\n  end if;\n\n  v_earned_delta:=v_earned_points-v_old_earned;\n  v_redeemed_delta:=v_redeemed_points-v_old_redeemed;\n  v_net_delta:=v_earned_delta-v_redeemed_delta;\n\n  select * into acc\n  from public.avopuntos_accounts\n  where profile_id=r.profile_id\n  for update;\n\n  if not found then\n    insert into public.avopuntos_accounts(profile_id)\n    values(r.profile_id)\n    returning * into acc;\n  end if;\n\n  v_new_balance:=acc.balance+v_net_delta;\n\n  if v_new_balance<0 then\n    update public.loyverse_receipts\n    set avopuntos_status='manual_review',\n        avopuntos_processed_at=v_now,\n        avopuntos_last_error='El movimiento produciría un saldo negativo de AvoPuntos.'\n    where receipt_number=p_receipt_number;\n\n    insert into public.avopuntos_receipt_state(\n      receipt_number,profile_id,input_hash,applied_earned_points,\n      applied_redeemed_points,last_receipt_updated_at,version,status,\n      last_error,processed_at,updated_at\n    ) values (\n      r.receipt_number,r.profile_id,v_input_hash,v_old_earned,\n      v_old_redeemed,r.updated_at,v_version,'error',\n      'El movimiento produciría un saldo negativo de AvoPuntos.',\n      v_now,v_now\n    )\n    on conflict(receipt_number) do update\n    set profile_id=excluded.profile_id,input_hash=excluded.input_hash,\n        applied_earned_points=excluded.applied_earned_points,\n        applied_redeemed_points=excluded.applied_redeemed_points,\n        last_receipt_updated_at=excluded.last_receipt_updated_at,\n        version=excluded.version,status='error',last_error=excluded.last_error,\n        processed_at=excluded.processed_at,updated_at=excluded.updated_at;\n\n    return jsonb_build_object('ok',false,'status','error','receipt_number',p_receipt_number);\n  end if;\n\n  if v_earned_delta<>0 then\n    insert into public.avopuntos_movements(\n      profile_id,movement_type,points_delta,eligible_amount,\n      receipt_number,source_key,details\n    ) values (\n      r.profile_id,\n      case when v_earned_delta>0 then 'earn' else 'earn_reversal' end,\n      v_earned_delta,\n      case when v_earned_delta>0 then v_eligible_amount else null end,\n      r.receipt_number,\n      'receipt:'||r.receipt_number||':earn:v'||v_version,\n      jsonb_build_object(\n        'receipt_updated_at',r.updated_at,\n        'payment_rule','Efectivo + Transferencia',\n        'points_per_thousand',cfg.points_per_thousand,\n        'multiplier',v_multiplier,\n        'effective_points_per_thousand',v_effective_points_per_thousand,\n        'rule_type',v_rule_type,\n        'rule_name',v_rule_name,\n        'rule_id',v_rule_id,\n        'business_date',v_business_date\n      )\n    );\n  end if;\n\n  if v_redeemed_delta<>0 then\n    insert into public.avopuntos_movements(\n      profile_id,movement_type,points_delta,receipt_number,\n      source_key,details\n    ) values (\n      r.profile_id,\n      case when v_redeemed_delta>0 then 'redeem' else 'redeem_reversal' end,\n      -v_redeemed_delta,\n      r.receipt_number,\n      'receipt:'||r.receipt_number||':redeem:v'||v_version,\n      jsonb_build_object(\n        'receipt_updated_at',r.updated_at,\n        'discount_rule','DISCOUNT_BY_POINTS',\n        'point_value_money',cfg.point_value_money\n      )\n    );\n  end if;\n\n  update public.avopuntos_accounts\n  set balance=v_new_balance,updated_at=v_now\n  where profile_id=r.profile_id;\n\n  insert into public.avopuntos_receipt_state(\n    receipt_number,profile_id,input_hash,applied_earned_points,applied_redeemed_points,\n    last_receipt_updated_at,version,status,last_error,processed_at,updated_at\n  ) values (\n    r.receipt_number,r.profile_id,v_input_hash,v_earned_points,v_redeemed_points,\n    r.updated_at,v_version,'processed',null,v_now,v_now\n  )\n  on conflict(receipt_number) do update\n  set profile_id=excluded.profile_id,input_hash=excluded.input_hash,\n      applied_earned_points=excluded.applied_earned_points,\n      applied_redeemed_points=excluded.applied_redeemed_points,\n      last_receipt_updated_at=excluded.last_receipt_updated_at,\n      version=excluded.version,status='processed',last_error=null,\n      processed_at=excluded.processed_at,updated_at=excluded.updated_at;\n\n  update public.loyverse_receipts\n  set avopuntos_status='processed',avopuntos_processed_at=v_now,avopuntos_last_error=null\n  where receipt_number=p_receipt_number;\n\n  return jsonb_build_object(\n    'ok',true,'status','processed','receipt_number',r.receipt_number,\n    'profile_id',r.profile_id,'eligible_amount',v_eligible_amount,\n    'earned_points',v_earned_points,'redeemed_points',v_redeemed_points,\n    'net_delta',v_net_delta,'balance',v_new_balance,\n    'rule_type',v_rule_type,'rule_name',v_rule_name,\n    'multiplier',v_multiplier,\n    'effective_points_per_thousand',v_effective_points_per_thousand\n  );\nend;\n$function$\n