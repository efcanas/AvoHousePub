-- Permite a usuarios de admin_users consultar perfiles en el Centro de Control del Cliente.
drop policy if exists "profiles_admin_select" on public.profiles;

create policy "profiles_admin_select"
on public.profiles
for select
to authenticated
using (
  exists (
    select 1
    from public.admin_users
    where admin_users.user_id = auth.uid()
  )
);
