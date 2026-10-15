-- Cierre de ejecución directa para funciones internas invocadas solo por disparadores/event triggers.
REVOKE EXECUTE ON FUNCTION public.ahtv_asignar_posicion_cola() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.ahtv_enriquecer_historial_identidad() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.ahtv_historial_rechazo() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.ahtv_propagar_estado_solicitud() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.ahtv_unificar_solicitud() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.ahtv_validar_solicitud() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.avohouse_send_welcome_email_after_confirmation() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.enqueue_loyverse_customer_sync() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.prevent_username_change() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM PUBLIC, anon, authenticated;

-- Endurecer operaciones administrativas usadas por ahtv/admin/index.html.
-- Se conserva EXECUTE para authenticated porque el panel inicia sesión,
-- pero cada RPC verifica su autorización dentro de la propia función.
CREATE OR REPLACE FUNCTION public.ahtv_cancelar_solicitud(p_request_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_old_position integer;
    v_found boolean := false;
BEGIN
    IF auth.uid() IS NULL
       OR NOT EXISTS (
          SELECT 1
          FROM public.admin_users au
          WHERE au.user_id = auth.uid()
       ) THEN
        RAISE EXCEPTION 'No tienes permisos de administración.'
          USING ERRCODE = '42501';
    END IF;

    SELECT queue_position
      INTO v_old_position
      FROM public.requests
     WHERE id = p_request_id
       AND status = 'accepted'
     FOR UPDATE;

    IF FOUND THEN
        v_found := true;

        UPDATE public.requests
           SET status = 'rejected',
               rejected_at = pg_catalog.now(),
               rejection_reason = 'Rechazada por administración desde la cola',
               queue_position = NULL
         WHERE id = p_request_id;

        UPDATE public.requests
           SET queue_position = queue_position - 1
         WHERE status = 'accepted'
           AND queue_position IS NOT NULL
           AND queue_position > v_old_position;
    END IF;

    RETURN v_found;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.ahtv_cancelar_solicitud(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ahtv_cancelar_solicitud(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.ahtv_establecer_modo_solicitudes(p_modo text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_modo text := lower(trim(coalesce(p_modo, '')));
BEGIN
    IF auth.uid() IS NULL
       OR NOT EXISTS (
          SELECT 1
          FROM public.admin_users au
          WHERE au.user_id = auth.uid()
       ) THEN
        RAISE EXCEPTION 'No tienes permisos de administración.'
          USING ERRCODE = '42501';
    END IF;

    IF v_modo NOT IN ('automatico', 'manual') THEN
        RAISE EXCEPTION 'Modo no válido. Use automatico o manual.';
    END IF;

    UPDATE public.ahtv_settings
       SET request_mode = v_modo,
           updated_at = pg_catalog.now()
     WHERE id = 1;

    IF v_modo = 'automatico' THEN
        UPDATE public.requests
           SET status = 'accepted',
               accepted_at = COALESCE(accepted_at, pg_catalog.now()),
               merged_into = NULL
         WHERE status = 'pending';
    END IF;

    RETURN v_modo;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.ahtv_establecer_modo_solicitudes(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ahtv_establecer_modo_solicitudes(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.ahtv_reordenar_cola(p_ids uuid[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
    IF auth.uid() IS NULL
       OR NOT EXISTS (
          SELECT 1
          FROM public.admin_users au
          WHERE au.user_id = auth.uid()
       ) THEN
        RAISE EXCEPTION 'No tienes permisos de administración.'
          USING ERRCODE = '42501';
    END IF;

    PERFORM pg_catalog.pg_advisory_xact_lock(847261);

    UPDATE public.requests r
       SET queue_position = u.posicion::integer
      FROM pg_catalog.unnest(coalesce(p_ids, '{}'::uuid[]))
           WITH ORDINALITY AS u(id, posicion)
     WHERE r.id = u.id
       AND r.status = 'accepted';

    UPDATE public.requests
       SET queue_position = NULL
     WHERE status = 'accepted'
       AND (
          p_ids IS NULL
          OR NOT (id = ANY(p_ids))
       );
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.ahtv_reordenar_cola(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ahtv_reordenar_cola(uuid[]) TO authenticated;

-- Esta función pura utiliza únicamente built-ins; fija un search_path inmutable.
ALTER FUNCTION public.nickname_is_reserved(text) SET search_path = '';
