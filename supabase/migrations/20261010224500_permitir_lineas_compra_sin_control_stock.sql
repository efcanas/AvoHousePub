-- Los productos sin control de inventario (incluidos artículos retirados de venta
-- e insumos) pueden registrar costos de compra sin inventar existencias físicas.
ALTER TABLE public.avohouse_inventory_purchase_lines
  ALTER COLUMN stock_before DROP NOT NULL,
  ALTER COLUMN stock_after DROP NOT NULL;
