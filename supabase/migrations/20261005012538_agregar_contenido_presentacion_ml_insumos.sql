alter table public.loyverse_item_variants
  add column if not exists purchase_presentation_content_ml numeric(14,3);

alter table public.loyverse_item_variants
  drop constraint if exists loyverse_item_variants_purchase_presentation_content_ml_check;

alter table public.loyverse_item_variants
  add constraint loyverse_item_variants_purchase_presentation_content_ml_check
  check (
    purchase_presentation_content_ml is null
    or purchase_presentation_content_ml > 0
  );
