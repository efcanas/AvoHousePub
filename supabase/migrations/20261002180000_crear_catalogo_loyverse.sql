create table if not exists public.loyverse_categories (
  id uuid primary key,
  name text not null,
  color text,
  created_at timestamptz,
  deleted_at timestamptz,
  raw_category jsonb not null default '{}'::jsonb,
  synced_at timestamptz not null default now()
);

create table if not exists public.loyverse_items (
  id uuid primary key,
  handle text,
  item_name text not null,
  description text,
  reference_id text,
  category_id uuid,
  track_stock boolean not null default false,
  sold_by_weight boolean not null default false,
  is_composite boolean not null default false,
  use_production boolean not null default false,
  primary_supplier_id uuid,
  tax_ids jsonb not null default '[]'::jsonb,
  modifiers_ids jsonb not null default '[]'::jsonb,
  form text,
  color text,
  image_url text,
  option1_name text,
  option2_name text,
  option3_name text,
  components jsonb not null default '[]'::jsonb,
  created_at timestamptz,
  updated_at timestamptz,
  deleted_at timestamptz,
  raw_item jsonb not null default '{}'::jsonb,
  synced_at timestamptz not null default now(),
  constraint loyverse_items_category_fk
    foreign key (category_id) references public.loyverse_categories(id)
);

create index if not exists loyverse_items_category_idx
  on public.loyverse_items(category_id);
create index if not exists loyverse_items_updated_idx
  on public.loyverse_items(updated_at desc);

create table if not exists public.loyverse_item_variants (
  variant_id uuid primary key,
  item_id uuid not null references public.loyverse_items(id) on delete cascade,
  sku text,
  reference_variant_id text,
  option1_value text,
  option2_value text,
  option3_value text,
  barcode text,
  cost numeric,
  purchase_cost numeric,
  default_pricing_type text,
  default_price numeric,
  stores jsonb not null default '[]'::jsonb,
  created_at timestamptz,
  updated_at timestamptz,
  deleted_at timestamptz,
  raw_variant jsonb not null default '{}'::jsonb,
  synced_at timestamptz not null default now()
);

create index if not exists loyverse_item_variants_item_idx
  on public.loyverse_item_variants(item_id);
create index if not exists loyverse_item_variants_sku_idx
  on public.loyverse_item_variants(sku);

create table if not exists public.loyverse_inventory_levels (
  variant_id uuid not null references public.loyverse_item_variants(variant_id) on delete cascade,
  store_id uuid not null,
  in_stock numeric not null,
  updated_at timestamptz,
  raw_inventory jsonb not null default '{}'::jsonb,
  synced_at timestamptz not null default now(),
  primary key (variant_id, store_id)
);

create index if not exists loyverse_inventory_store_idx
  on public.loyverse_inventory_levels(store_id);
create index if not exists loyverse_inventory_updated_idx
  on public.loyverse_inventory_levels(updated_at desc);

create table if not exists public.loyverse_catalog_sync_state (
  sync_key text primary key,
  last_started_at timestamptz,
  last_success_at timestamptz,
  last_items_count integer not null default 0,
  last_variants_count integer not null default 0,
  last_categories_count integer not null default 0,
  last_inventory_count integer not null default 0,
  last_error text,
  updated_at timestamptz not null default now()
);

insert into public.loyverse_catalog_sync_state(sync_key)
values ('catalog')
on conflict (sync_key) do nothing;

alter table public.loyverse_categories enable row level security;
alter table public.loyverse_items enable row level security;
alter table public.loyverse_item_variants enable row level security;
alter table public.loyverse_inventory_levels enable row level security;
alter table public.loyverse_catalog_sync_state enable row level security;

drop policy if exists "Admins can read Loyverse categories" on public.loyverse_categories;
create policy "Admins can read Loyverse categories"
  on public.loyverse_categories
  for select
  to authenticated
  using (exists (select 1 from public.admin_users au where au.user_id = auth.uid()));

drop policy if exists "Admins can read Loyverse items" on public.loyverse_items;
create policy "Admins can read Loyverse items"
  on public.loyverse_items
  for select
  to authenticated
  using (exists (select 1 from public.admin_users au where au.user_id = auth.uid()));

drop policy if exists "Admins can read Loyverse item variants" on public.loyverse_item_variants;
create policy "Admins can read Loyverse item variants"
  on public.loyverse_item_variants
  for select
  to authenticated
  using (exists (select 1 from public.admin_users au where au.user_id = auth.uid()));

drop policy if exists "Admins can read Loyverse inventory levels" on public.loyverse_inventory_levels;
create policy "Admins can read Loyverse inventory levels"
  on public.loyverse_inventory_levels
  for select
  to authenticated
  using (exists (select 1 from public.admin_users au where au.user_id = auth.uid()));

drop policy if exists "Admins can read Loyverse catalog sync state" on public.loyverse_catalog_sync_state;
create policy "Admins can read Loyverse catalog sync state"
  on public.loyverse_catalog_sync_state
  for select
  to authenticated
  using (exists (select 1 from public.admin_users au where au.user_id = auth.uid()));

grant select on public.loyverse_categories to authenticated;
grant select on public.loyverse_items to authenticated;
grant select on public.loyverse_item_variants to authenticated;
grant select on public.loyverse_inventory_levels to authenticated;
grant select on public.loyverse_catalog_sync_state to authenticated;

grant all on public.loyverse_categories to service_role;
grant all on public.loyverse_items to service_role;
grant all on public.loyverse_item_variants to service_role;
grant all on public.loyverse_inventory_levels to service_role;
grant all on public.loyverse_catalog_sync_state to service_role;
