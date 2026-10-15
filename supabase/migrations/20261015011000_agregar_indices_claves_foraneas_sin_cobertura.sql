-- Add supporting B-tree indexes for foreign-key columns reported by the
-- Supabase performance advisor. All listed foreign keys are single-column.
-- IF NOT EXISTS makes replay safer if an equivalent named index is already present.
CREATE INDEX IF NOT EXISTS idx_ahtv_now_playing_request_id_fk
  ON public.ahtv_now_playing (request_id);
CREATE INDEX IF NOT EXISTS idx_ahtv_now_playing_song_id_fk
  ON public.ahtv_now_playing (song_id);
CREATE INDEX IF NOT EXISTS idx_avohouse_communications_created_by_fk
  ON public.avohouse_communications (created_by);
CREATE INDEX IF NOT EXISTS idx_avohouse_inventory_cost_derivations_target_variant_id_fk
  ON public.avohouse_inventory_cost_derivations (target_variant_id);
CREATE INDEX IF NOT EXISTS idx_avohouse_inventory_purchase_lines_item_id_fk
  ON public.avohouse_inventory_purchase_lines (item_id);
CREATE INDEX IF NOT EXISTS idx_avohouse_inventory_purchase_lines_variant_id_fk
  ON public.avohouse_inventory_purchase_lines (variant_id);
CREATE INDEX IF NOT EXISTS idx_avohouse_inventory_purchases_created_by_fk
  ON public.avohouse_inventory_purchases (created_by);
CREATE INDEX IF NOT EXISTS idx_avohouse_inventory_purchases_deleted_by_fk
  ON public.avohouse_inventory_purchases (deleted_by);
CREATE INDEX IF NOT EXISTS idx_avohouse_inventory_purchases_updated_by_fk
  ON public.avohouse_inventory_purchases (updated_by);
CREATE INDEX IF NOT EXISTS idx_avohouse_sales_receipts_profile_id_fk
  ON public.avohouse_sales_receipts (profile_id);
CREATE INDEX IF NOT EXISTS idx_avopuntos_admin_changes_admin_user_id_fk
  ON public.avopuntos_admin_changes (admin_user_id);
CREATE INDEX IF NOT EXISTS idx_avopuntos_contact_verifications_verified_by_fk
  ON public.avopuntos_contact_verifications (verified_by);
CREATE INDEX IF NOT EXISTS idx_avopuntos_customer_rewards_granted_by_fk
  ON public.avopuntos_customer_rewards (granted_by);
CREATE INDEX IF NOT EXISTS idx_avopuntos_customer_rewards_reward_id_fk
  ON public.avopuntos_customer_rewards (reward_id);
CREATE INDEX IF NOT EXISTS idx_avopuntos_customer_rules_created_by_fk
  ON public.avopuntos_customer_rules (created_by);
CREATE INDEX IF NOT EXISTS idx_avopuntos_promotions_created_by_fk
  ON public.avopuntos_promotions (created_by);
CREATE INDEX IF NOT EXISTS idx_avopuntos_receipt_state_profile_id_fk
  ON public.avopuntos_receipt_state (profile_id);
CREATE INDEX IF NOT EXISTS idx_legal_acceptances_user_id_fk
  ON public.legal_acceptances (user_id);
CREATE INDEX IF NOT EXISTS idx_playback_history_song_id_fk
  ON public.playback_history (song_id);
