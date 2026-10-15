-- Remove all direct table privileges from client-facing roles on private
-- operational/history tables. Access, where required, must go through guarded
-- SECURITY DEFINER functions or trusted server-side service-role operations.
REVOKE ALL PRIVILEGES ON TABLE
  public.avohouse_communications,
  public.avohouse_email_events,
  public.avohouse_inventory_cost_derivations,
  public.avohouse_sales_history_categories,
  public.avohouse_sales_history_months,
  public.avohouse_sales_history_products,
  public.avohouse_sales_receipts,
  public.cancellation_email_state,
  public.purchase_email_state,
  public.refund_cancellation_email_state,
  public.refund_email_state
FROM anon, authenticated;
