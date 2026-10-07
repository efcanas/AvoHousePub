create table if not exists public.avohouse_inventory_cost_derivations (
  id uuid primary key default gen_random_uuid(),
  source_variant_id uuid not null references public.loyverse_item_variants(variant_id) on delete cascade,
  target_variant_id uuid not null references public.loyverse_item_variants(variant_id) on delete cascade,
  source_content_ml numeric(14,3) not null check (source_content_ml > 0),
  fallback_unit_cost numeric(14,6),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint avohouse_inventory_cost_derivations_source_target_uniq unique (source_variant_id,target_variant_id),
  constraint avohouse_inventory_cost_derivations_not_self check (source_variant_id <> target_variant_id)
);

alter table public.avohouse_inventory_cost_derivations enable row level security;

insert into public.avohouse_inventory_cost_derivations(
  source_variant_id,target_variant_id,source_content_ml,fallback_unit_cost,active
)
values(
  'c2dbd7d7-9006-4ca9-be47-ddea15f4277d',
  'cc9a0443-b252-4c06-a21d-189326792135',
  250,
  28,
  true
)
on conflict (source_variant_id,target_variant_id) do update
set source_content_ml=excluded.source_content_ml,
    fallback_unit_cost=excluded.fallback_unit_cost,
    active=true,
    updated_at=now();