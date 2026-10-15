-- Los cuerpos de estas funciones usan nombres de tablas y funciones de aplicación cualificados.
-- Un search_path vacío evita resolver objetos arbitrarios dentro de funciones SECURITY DEFINER.
ALTER FUNCTION public.ahtv_enriquecer_historial_identidad() SET search_path TO '';
ALTER FUNCTION public.ahtv_historial_rechazo() SET search_path TO '';
ALTER FUNCTION public.ahtv_propagar_estado_solicitud() SET search_path TO '';
ALTER FUNCTION public.ahtv_unificar_solicitud() SET search_path TO '';
ALTER FUNCTION public.ahtv_validar_solicitud() SET search_path TO '';
ALTER FUNCTION public.avohouse_send_welcome_email_after_confirmation() SET search_path TO '';
ALTER FUNCTION public.enqueue_loyverse_customer_sync() SET search_path TO '';
ALTER FUNCTION public.prevent_username_change() SET search_path TO '';
ALTER FUNCTION public.ahtv_nickname_disponible(text) SET search_path TO '';
ALTER FUNCTION public.ahtv_solicitudes_habilitadas() SET search_path TO '';
ALTER FUNCTION public.nickname_is_reserved(text) SET search_path TO '';
