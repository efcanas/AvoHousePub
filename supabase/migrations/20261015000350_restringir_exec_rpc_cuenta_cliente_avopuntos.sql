-- Estas RPC atienden exclusivamente la cuenta del usuario autenticado.
-- El código de mi-cuenta.html las invoca con una sesión; no deben estar disponibles para PUBLIC/anon.

REVOKE EXECUTE ON FUNCTION public.avopuntos_get_my_rewards() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.avopuntos_get_my_rewards() TO authenticated;

REVOKE EXECUTE ON FUNCTION public.avopuntos_get_my_whatsapp_verification() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.avopuntos_get_my_whatsapp_verification() TO authenticated;

REVOKE EXECUTE ON FUNCTION public.avopuntos_request_facebook_verification(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.avopuntos_request_facebook_verification(text) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.avopuntos_request_instagram_verification(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.avopuntos_request_instagram_verification(text) TO authenticated;
