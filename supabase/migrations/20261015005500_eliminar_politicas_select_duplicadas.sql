-- Remove two exactly duplicated permissive SELECT policies.
-- The retained policies have identical roles, command, and USING predicates.
DROP POLICY "Admins can view own admin record" ON public.admin_users;
DROP POLICY admins_select_variant_pack_sizes ON public.loyverse_item_variants;
