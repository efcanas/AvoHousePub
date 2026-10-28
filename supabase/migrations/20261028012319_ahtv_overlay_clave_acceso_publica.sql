create or replace function public.ahtv_overlay_obtener_clave_acceso()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_current public.ahtv_access_codes%rowtype;
begin
  select c.*
    into v_current
  from public.ahtv_access_codes c
  where c.id = 1;

  if not found or v_current.valid_until <= now() then
    perform public.ahtv_rotar_clave_acceso();

    select c.*
      into v_current
    from public.ahtv_access_codes c
    where c.id = 1;
  end if;

  if not found
     or v_current.current_code is null
     or v_current.valid_until is null then
    raise exception 'No fue posible obtener la clave vigente.';
  end if;

  return jsonb_build_object(
    'code', v_current.current_code,
    'valid_until', v_current.valid_until,
    'remaining_seconds', greatest(
      0, ceil(extract(epoch from (v_current.valid_until - now())))::integer
    )
  );
end;
$function$;

revoke all on function public.ahtv_overlay_obtener_clave_acceso() from public;
grant execute on function public.ahtv_overlay_obtener_clave_acceso() to anon, authenticated;

notify pgrst, 'reload schema';
