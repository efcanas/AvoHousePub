-- Marca líneas de facturas importadas manualmente cuyo movimiento de stock aún
-- debe enviarse a Loyverse. La marca evita contabilizar el mismo movimiento dos veces.
ALTER TABLE public.avohouse_inventory_purchase_lines
  ADD COLUMN IF NOT EXISTS inventory_sync_pending boolean NOT NULL DEFAULT false;
