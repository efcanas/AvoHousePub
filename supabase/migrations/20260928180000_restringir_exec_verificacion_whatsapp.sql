revoke execute on function public.avopuntos_request_whatsapp_verification() from public;
revoke execute on function public.avopuntos_admin_verify_whatsapp(uuid) from public;

grant execute on function public.avopuntos_request_whatsapp_verification() to authenticated;
grant execute on function public.avopuntos_admin_verify_whatsapp(uuid) to authenticated;
