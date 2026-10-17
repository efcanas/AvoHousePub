-- Conserva los recibos históricos al eliminar una cuenta de cliente.
-- Se desvincula únicamente el perfil; no se eliminan ni modifican los datos del recibo.
ALTER TABLE public.avohouse_sales_receipts
  DROP CONSTRAINT avohouse_sales_receipts_profile_id_fkey;

ALTER TABLE public.avohouse_sales_receipts
  ADD CONSTRAINT avohouse_sales_receipts_profile_id_fkey
  FOREIGN KEY (profile_id)
  REFERENCES public.profiles(id)
  ON DELETE SET NULL;
