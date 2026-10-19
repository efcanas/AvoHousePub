create or replace function public.cc_get_customer_marketing_consent(p_user_id uuid)
returns table (
  marketing_authorized boolean,
  accepted_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $function$
  select la.marketing_authorized, la.accepted_at
  from public.legal_acceptances as la
  where la.user_id = p_user_id
    and exists (
      select 1
      from public.admin_users as au
      where au.user_id = (select auth.uid())
    )
  order by la.accepted_at desc nulls last, la.id desc
  limit 1;
$function$;

revoke all on function public.cc_get_customer_marketing_consent(uuid) from public, anon;
grant execute on function public.cc_get_customer_marketing_consent(uuid) to authenticated;
