-- Restringe la ejecución anónima de RPC administrativas de AvoPuntos.
-- Estas funciones requieren una sesión autenticada y validan el rol administrador internamente.

REVOKE EXECUTE ON FUNCTION public.avopuntos_admin_delete_customer(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.avopuntos_admin_delete_customer(uuid) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.avopuntos_admin_get_customer_rewards(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.avopuntos_admin_get_customer_rewards(uuid) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.avopuntos_admin_get_facebook_verification(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.avopuntos_admin_get_facebook_verification(uuid) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.avopuntos_admin_get_instagram_verification(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.avopuntos_admin_get_instagram_verification(uuid) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.avopuntos_admin_get_whatsapp_verification(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.avopuntos_admin_get_whatsapp_verification(uuid) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.avopuntos_admin_update_customer_profile(uuid, text, text, text, boolean, text, text, text, text, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.avopuntos_admin_update_customer_profile(uuid, text, text, text, boolean, text, text, text, text, date) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.avopuntos_admin_verify_facebook(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.avopuntos_admin_verify_facebook(uuid) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.avopuntos_admin_verify_instagram(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.avopuntos_admin_verify_instagram(uuid) TO authenticated;
