-- Resumen histórico completo de AvoPuntos sin límite de filas en el cliente.
-- Calcula los indicadores directamente en la base de datos, sobre el libro de movimientos.
-- La RPC solo resume los movimientos del usuario autenticado y no modifica saldos ni historial.

CREATE OR REPLACE FUNCTION public.avopuntos_get_my_summary()
RETURNS TABLE (
  movement_count bigint,
  earned_net bigint,
  used_net bigint,
  ticket_count bigint
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $function$
  WITH my_movements AS MATERIALIZED (
    SELECT
      m.movement_type,
      m.points_delta,
      m.receipt_number,
      m.related_receipt_number
    FROM public.avopuntos_movements AS m
    WHERE m.profile_id = (SELECT auth.uid())
  ),
  totals AS (
    SELECT
      count(*)::bigint AS movement_count,
      greatest(
        0::numeric,
        round(coalesce(sum(
          CASE
            WHEN m.movement_type IN ('earn', 'earn_reversal')
              THEN m.points_delta::numeric
            ELSE 0::numeric
          END
        ), 0))
      )::bigint AS earned_net,
      greatest(
        0::numeric,
        round(coalesce(sum(
          CASE
            WHEN m.movement_type IN ('redeem', 'redeem_reversal')
              THEN -m.points_delta::numeric
            ELSE 0::numeric
          END
        ), 0))
      )::bigint AS used_net
    FROM my_movements AS m
  ),
  tickets AS (
    SELECT count(DISTINCT ticket_number)::bigint AS ticket_count
    FROM (
      SELECT nullif(m.receipt_number, '') AS ticket_number
      FROM my_movements AS m
      UNION ALL
      SELECT nullif(m.related_receipt_number, '') AS ticket_number
      FROM my_movements AS m
    ) AS ticket_refs
    WHERE ticket_number IS NOT NULL
  )
  SELECT
    totals.movement_count,
    totals.earned_net,
    totals.used_net,
    tickets.ticket_count
  FROM totals
  CROSS JOIN tickets;
$function$;

REVOKE ALL ON FUNCTION public.avopuntos_get_my_summary() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.avopuntos_get_my_summary() TO authenticated;
