create or replace function public.avopuntos_cuentas_pendientes_sync(p_limit integer default 25)
returns table (
  profile_id uuid,
  balance bigint,
  last_loyverse_points bigint
)
language sql
security definer
set search_path = public
as $$
  select
    a.profile_id,
    a.balance,
    a.last_loyverse_points
  from public.avopuntos_accounts a
  where a.last_loyverse_points is null
     or a.balance <> a.last_loyverse_points
  order by a.updated_at asc
  limit greatest(1, least(coalesce(p_limit, 25), 100));
$$;

revoke all on function public.avopuntos_cuentas_pendientes_sync(integer) from public;
revoke all on function public.avopuntos_cuentas_pendientes_sync(integer) from anon;
revoke all on function public.avopuntos_cuentas_pendientes_sync(integer) from authenticated;
grant execute on function public.avopuntos_cuentas_pendientes_sync(integer) to service_role;