create or replace function public.avopuntos_admin_adjust_points(
  p_profile_id uuid,
  p_points_delta bigint,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid;
  v_account public.avopuntos_accounts%rowtype;
  v_old_balance bigint;
  v_new_balance bigint;
  v_reason text := nullif(trim(coalesce(p_reason,'')),'');
  v_source text;
begin
  v_admin := auth.uid();

  if v_admin is null
     or not exists (
       select 1 from public.admin_users au where au.user_id = v_admin
     )
  then
    raise exception 'No autorizado.';
  end if;

  if p_profile_id is null then
    raise exception 'El cliente es obligatorio.';
  end if;

  if not exists (
    select 1 from public.profiles p where p.id = p_profile_id
  ) then
    raise exception 'No existe el cliente seleccionado.';
  end if;

  if coalesce(p_points_delta,0) = 0 then
    raise exception 'El ajuste debe ser diferente de cero.';
  end if;

  if v_reason is null then
    raise exception 'Debes indicar el motivo del ajuste.';
  end if;

  if char_length(v_reason) > 500 then
    raise exception 'El motivo no puede superar 500 caracteres.';
  end if;

  select * into v_account
  from public.avopuntos_accounts
  where profile_id = p_profile_id
  for update;

  if not found then
    insert into public.avopuntos_accounts(profile_id, balance)
    values (p_profile_id, 0)
    returning * into v_account;
  end if;

  v_old_balance := v_account.balance;
  v_new_balance := v_old_balance + p_points_delta;

  if v_new_balance < 0 then
    raise exception 'El ajuste dejaría el saldo en un valor negativo.';
  end if;

  v_source := 'admin-adjust:' || gen_random_uuid()::text;

  insert into public.avopuntos_movements (
    profile_id, movement_type, points_delta, eligible_amount,
    receipt_number, related_receipt_number, source_key, details
  )
  values (
    p_profile_id, 'adjustment', p_points_delta, null,
    null, null, v_source,
    jsonb_build_object(
      'title','Ajuste manual de AvoPuntos',
      'reason',v_reason,
      'admin_user_id',v_admin,
      'previous_balance',v_old_balance,
      'new_balance',v_new_balance,
      'adjustment_points',abs(p_points_delta)
    )
  );

  update public.avopuntos_accounts
  set balance=v_new_balance, updated_at=now()
  where profile_id=p_profile_id;

  return jsonb_build_object(
    'ok',true,
    'profile_id',p_profile_id,
    'points_delta',p_points_delta,
    'previous_balance',v_old_balance,
    'balance',v_new_balance,
    'reason',v_reason
  );
end;
$$;

revoke all on function public.avopuntos_admin_adjust_points(uuid,bigint,text) from public;
grant execute on function public.avopuntos_admin_adjust_points(uuid,bigint,text) to authenticated;
