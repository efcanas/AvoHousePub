grant select, insert, update, delete on table public.avopuntos_payment_methods to authenticated;

drop policy if exists "AvoPuntos payment methods admin select" on public.avopuntos_payment_methods;
drop policy if exists "AvoPuntos payment methods admin insert" on public.avopuntos_payment_methods;
drop policy if exists "AvoPuntos payment methods admin update" on public.avopuntos_payment_methods;
drop policy if exists "AvoPuntos payment methods admin delete" on public.avopuntos_payment_methods;

create policy "AvoPuntos payment methods admin select"
on public.avopuntos_payment_methods
for select
to authenticated
using (
  exists (
    select 1 from public.admin_users
    where admin_users.user_id = (select auth.uid())
  )
);

create policy "AvoPuntos payment methods admin insert"
on public.avopuntos_payment_methods
for insert
to authenticated
with check (
  exists (
    select 1 from public.admin_users
    where admin_users.user_id = (select auth.uid())
  )
);

create policy "AvoPuntos payment methods admin update"
on public.avopuntos_payment_methods
for update
to authenticated
using (
  exists (
    select 1 from public.admin_users
    where admin_users.user_id = (select auth.uid())
  )
)
with check (
  exists (
    select 1 from public.admin_users
    where admin_users.user_id = (select auth.uid())
  )
);

create policy "AvoPuntos payment methods admin delete"
on public.avopuntos_payment_methods
for delete
to authenticated
using (
  exists (
    select 1 from public.admin_users
    where admin_users.user_id = (select auth.uid())
  )
);
