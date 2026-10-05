alter table public.avohouse_inventory_purchase_lines
  add column if not exists presentation_content_ml numeric(14,3);

alter table public.avohouse_inventory_purchase_lines
  drop constraint if exists avohouse_inventory_purchase_lines_content_ml_chk;

alter table public.avohouse_inventory_purchase_lines
  add constraint avohouse_inventory_purchase_lines_content_ml_chk
  check (presentation_content_ml is null or presentation_content_ml > 0);