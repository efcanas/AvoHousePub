CREATE OR REPLACE FUNCTION public.avopuntos_admin_list_customers(
  p_search text DEFAULT NULL,
  p_filter text DEFAULT 'all',
  p_sort text DEFAULT 'newest',
  p_page integer DEFAULT 1,
  p_page_size integer DEFAULT 25
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $function$
DECLARE
  v_admin_id uuid := auth.uid();
  v_search text;
  v_filter text;
  v_sort text;
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := least(greatest(coalesce(p_page_size, 25), 1), 50);
  v_total bigint := 0;
  v_recent_30 bigint := 0;
  v_confirmed bigint := 0;
  v_with_ap bigint := 0;
  v_total_filtered bigint := 0;
  v_monthly jsonb := '[]'::jsonb;
  v_customers jsonb := '[]'::jsonb;
BEGIN
  IF v_admin_id IS NULL OR NOT public.avopuntos_admin_is_admin() THEN
    RAISE EXCEPTION 'No tienes permisos para consultar el directorio de clientes.'
      USING ERRCODE = '42501';
  END IF;

  v_search := replace(
    replace(
      replace(lower(trim(coalesce(p_search, ''))), '!', '!!'),
      '%', '!%'
    ),
    '_', '!_'
  );
  v_filter := CASE
    WHEN p_filter IN ('all', 'recent', 'with_ap', 'without_ap', 'pending_email', 'marketing')
      THEN p_filter
    ELSE 'all'
  END;
  v_sort := CASE
    WHEN p_sort IN ('newest', 'oldest', 'name', 'balance') THEN p_sort
    ELSE 'newest'
  END;

  SELECT
    count(*)::bigint,
    count(*) FILTER (WHERE p.created_at >= now() - interval '30 days')::bigint,
    count(*) FILTER (WHERE au.email_confirmed_at IS NOT NULL)::bigint,
    count(*) FILTER (WHERE coalesce(aa.balance, 0) > 0)::bigint
  INTO v_total, v_recent_30, v_confirmed, v_with_ap
  FROM public.profiles p
  LEFT JOIN auth.users au ON au.id = p.id
  LEFT JOIN public.avopuntos_accounts aa ON aa.profile_id = p.id;

  WITH month_series AS (
    SELECT generate_series(
      date_trunc('month', now() AT TIME ZONE 'America/Bogota') - interval '11 months',
      date_trunc('month', now() AT TIME ZONE 'America/Bogota'),
      interval '1 month'
    ) AS month_start
  )
  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object('month', to_char(month_start, 'YYYY-MM'), 'count', customer_count)
      ORDER BY month_start
    ),
    '[]'::jsonb
  )
  INTO v_monthly
  FROM (
    SELECT m.month_start, count(p.id)::integer AS customer_count
    FROM month_series m
    LEFT JOIN public.profiles p
      ON p.created_at >= (m.month_start AT TIME ZONE 'America/Bogota')
     AND p.created_at < ((m.month_start + interval '1 month') AT TIME ZONE 'America/Bogota')
    GROUP BY m.month_start
  ) monthly_counts;

  WITH customer_base AS (
    SELECT
      p.id, p.username, p.full_name, p.email, p.phone, p.whatsapp, p.whatsapp_same,
      p.instagram, p.document_number, p.document_type, p.created_at, p.birth_date,
      coalesce(aa.balance, 0)::bigint AS balance,
      (au.email_confirmed_at IS NOT NULL) AS email_confirmed,
      legal.marketing_authorized
    FROM public.profiles p
    LEFT JOIN public.avopuntos_accounts aa ON aa.profile_id = p.id
    LEFT JOIN auth.users au ON au.id = p.id
    LEFT JOIN LATERAL (
      SELECT la.marketing_authorized
      FROM public.legal_acceptances la
      WHERE la.user_id = p.id
      ORDER BY la.accepted_at DESC, la.id DESC
      LIMIT 1
    ) legal ON true
  ),
  filtered AS (
    SELECT *
    FROM customer_base cb
    WHERE
      (
        v_search = ''
        OR coalesce(cb.username, '') ILIKE '%' || v_search || '%' ESCAPE '!'
        OR coalesce(cb.full_name, '') ILIKE '%' || v_search || '%' ESCAPE '!'
        OR coalesce(cb.email, '') ILIKE '%' || v_search || '%' ESCAPE '!'
        OR coalesce(cb.document_number, '') ILIKE '%' || v_search || '%' ESCAPE '!'
        OR coalesce(cb.phone, '') ILIKE '%' || v_search || '%' ESCAPE '!'
      )
      AND (
        v_filter = 'all'
        OR (v_filter = 'recent' AND cb.created_at >= now() - interval '30 days')
        OR (v_filter = 'with_ap' AND cb.balance > 0)
        OR (v_filter = 'without_ap' AND cb.balance <= 0)
        OR (v_filter = 'pending_email' AND NOT cb.email_confirmed)
        OR (v_filter = 'marketing' AND cb.marketing_authorized IS TRUE)
      )
  ),
  ranked AS (
    SELECT
      f.*,
      count(*) OVER () AS total_rows,
      row_number() OVER (
        ORDER BY
          CASE WHEN v_sort = 'newest' THEN f.created_at END DESC,
          CASE WHEN v_sort = 'oldest' THEN f.created_at END ASC,
          CASE WHEN v_sort = 'name' THEN lower(coalesce(f.full_name, f.username, '')) END ASC,
          CASE WHEN v_sort = 'balance' THEN f.balance END DESC,
          f.created_at DESC,
          f.id
      ) AS row_number
    FROM filtered f
  )
  SELECT
    coalesce(max(total_rows), 0)::bigint,
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', id,
          'username', username,
          'full_name', full_name,
          'email', email,
          'phone', phone,
          'whatsapp', whatsapp,
          'whatsapp_same', whatsapp_same,
          'instagram', instagram,
          'document_number', document_number,
          'document_type', document_type,
          'created_at', created_at,
          'birth_date', birth_date,
          'balance', balance,
          'email_confirmed', email_confirmed,
          'marketing_authorized', marketing_authorized
        )
        ORDER BY row_number
      ) FILTER (
        WHERE row_number > ((v_page - 1) * v_page_size)
          AND row_number <= (v_page * v_page_size)
      ),
      '[]'::jsonb
    )
  INTO v_total_filtered, v_customers
  FROM ranked;

  RETURN jsonb_build_object(
    'stats', jsonb_build_object(
      'total', v_total,
      'recent_30_days', v_recent_30,
      'confirmed_emails', v_confirmed,
      'with_ap', v_with_ap
    ),
    'monthly_registrations', v_monthly,
    'pagination', jsonb_build_object(
      'page', v_page,
      'page_size', v_page_size,
      'total_filtered', v_total_filtered,
      'total_pages', greatest(1, ceil(v_total_filtered::numeric / v_page_size)::integer),
      'from', CASE WHEN v_total_filtered = 0 THEN 0 ELSE ((v_page - 1) * v_page_size) + 1 END,
      'to', least(v_page * v_page_size, v_total_filtered)
    ),
    'customers', v_customers
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.avopuntos_admin_list_customers(text,text,text,integer,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.avopuntos_admin_list_customers(text,text,text,integer,integer) TO authenticated;
