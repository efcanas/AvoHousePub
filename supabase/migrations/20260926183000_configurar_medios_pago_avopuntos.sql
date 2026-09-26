create table public.avopuntos_payment_methods (
  payment_type_id uuid primary key,
  name text not null,
  loyverse_type text not null,
  eligible_for_avopuntos boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.avopuntos_payment_methods enable row level security;

create policy "AvoPuntos payment methods admin select"
on public.avopuntos_payment_methods
for select
to authenticated
using (
  exists (
    select 1
    from public.admin_users
    where admin_users.user_id = auth.uid()
  )
);

insert into public.avopuntos_payment_methods (
  payment_type_id, name, loyverse_type, eligible_for_avopuntos
) values
  ('a8927096-1704-4b39-bb61-f07606ec8943', 'Efectivo', 'CASH', true),
  ('62050a8c-9630-4da2-aae2-9c989fa17e2e', 'Transferencia', 'NONINTEGRATEDCARD', true),
  ('8bf8a520-05b4-4694-a226-48bf57c3759e', 'TC', 'NONINTEGRATEDCARD', false),
  ('8ad76989-9825-4247-b9b5-b0fd09863b53', 'Crédito', 'OTHER', false);