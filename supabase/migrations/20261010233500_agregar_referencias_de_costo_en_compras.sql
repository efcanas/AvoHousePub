-- Permite registrar referencias de costo histórico que no representan una
-- cantidad ni un valor adicional comprado en la factura.
ALTER TABLE public.avohouse_inventory_purchase_lines
  ADD COLUMN IF NOT EXISTS cost_only boolean NOT NULL DEFAULT false;

ALTER TABLE public.avohouse_inventory_purchase_lines
  DROP CONSTRAINT IF EXISTS avohouse_inventory_purchase_lines_presentation_quantity_check;
ALTER TABLE public.avohouse_inventory_purchase_lines
  ADD CONSTRAINT avohouse_inventory_purchase_lines_presentation_quantity_check
  CHECK (presentation_quantity >= 0 AND (presentation_quantity > 0 OR cost_only));

ALTER TABLE public.avohouse_inventory_purchase_lines
  DROP CONSTRAINT IF EXISTS avohouse_inventory_purchase_lines_units_received_check;
ALTER TABLE public.avohouse_inventory_purchase_lines
  ADD CONSTRAINT avohouse_inventory_purchase_lines_units_received_check
  CHECK (units_received >= 0 AND (units_received > 0 OR cost_only));
