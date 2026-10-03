create or replace function public.avopuntos_admin_update_customer_profile(
  p_profile_id uuid,
  p_full_name text,
  p_email text,
  p_phone text,
  p_whatsapp_same boolean,
  p_whatsapp text,
  p_instagram text,
  p_document_type text,
  p_document_number text,
  p_birth_date date
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $function$
declare
  v_admin_id uuid := auth.uid();
  v_profile public.profiles%rowtype;
  v_email text := lower(trim(coalesce(p_email,'')));
  v_full_name text := trim(coalesce(p_full_name,''));
  v_phone text := trim(coalesce(p_phone,''));
  v_whatsapp text := trim(coalesce(p_whatsapp,''));  
  v_instagram text := nullif(trim(coalesce(p_instagram,'')),'');
  v_document_number text := trim(coalesce(p_document_number,''));
  v_effective_whatsapp text;
  v_changed_fields text;
  v_old_email text;
  v_event_key text;
begin
  if v_admin_id is null or not public.avopuntos_admin_is_admin() then
    raise exception 'No tienes permisos para editar clientes.';
  end if;

  select * into v_profile from public.profiles where id=p_profile_id for update;
  if not found then raise exception 'No se encontró el cliente.'; end if;

  if v_full_name='' then raise exception 'El nombre completo es obligatorio.'; end if;
  if v_email='' then raise exception 'El correo electrónico es obligatorio.'; end if;
  if v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\\.[^[:space:]@]+$' then raise exception 'El correo electrónico no tiene un formato válido.'; end if;
  if v_phone='' then raise exception 'El celular es obligatorio.'; end if;
  if p_whatsapp_same is distinct from true and v_whatsapp='' then raise exception 'El WhatsApp es obligatorio cuando no es igual al celular.'; end if;
  if p_document_type not in ('Cédula de ciudadanía','Cédula de extranjería','Pasaporte') then raise exception 'El tipo de documento no es válido.'; end if;
  if v_document_number='' then raise exception 'El número de documento es obligatorio.'; end if;

  if exists (select 1 from public.profiles where lower(email)=v_email and id<>p_profile_id) then
    raise exception 'Ese correo ya está asociado a otro cliente.';
  end if;
  if exists (select 1 from auth.users where lower(email)=v_email and id<>p_profile_id) then
    raise exception 'Ese correo ya está asociado a otra cuenta de acceso.';
  end if;

  v_effective_whatsapp:=case when p_whatsapp_same is true then v_phone else v_whatsapp end;

  v_changed_fields:=concat_ws(
    ' · ',
    case when v_profile.full_name is distinct from v_full_name then 'Nombre completo' end,
    case when lower(coalesce(v_profile.email,'')) is distinct from v_email then 'Correo electrónico' end,
    case when v_profile.phone is distinct from v_phone then 'Celular' end,
    case when v_profile.whatsapp_same is distinct from (p_whatsapp_same is true)
           or coalesce(v_profile.whatsapp,'') is distinct from coalesce(v_effective_whatsapp,'')
         then 'WhatsApp' end,
    case when coalesce(v_profile.instagram,'') is distinct from coalesce(v_instagram,'') then 'Instagram' end,
    case when v_profile.document_type is distinct from p_document_type
           or v_profile.document_number is distinct from v_document_number
         then 'Documento' end,
    case when v_profile.birth_date is distinct from p_birth_date then 'Fecha de nacimiento' end
  );

  v_old_email:=v_profile.email;

  update auth.users
  set email=v_email,email_change=null,email_change_token_new=null,email_change_confirm_status=0
  where id=p_profile_id;
  if not found then raise exception 'No se encontró la cuenta de acceso del cliente.'; end if;

  update public.profiles
  set full_name=v_full_name,email=v_email,phone=v_phone,
      whatsapp_same=(p_whatsapp_same is true),whatsapp=v_effective_whatsapp,
      instagram=v_instagram,document_type=p_document_type,
      document_number=v_document_number,birth_date=p_birth_date,updated_at=now()
  where id=p_profile_id;

  update public.loyverse_customers
  set sync_status='pending',next_attempt_at=now(),last_error=null,updated_at=now()
  where profile_id=p_profile_id;

  if nullif(trim(coalesce(v_changed_fields,'')),'') is not null then
    v_event_key:='profile-update:'||p_profile_id::text||':'||gen_random_uuid()::text;
    perform public.avohouse_queue_profile_email(
      v_event_key,p_profile_id,'profile_update','email',
      '91d77654-7f9e-4fe5-98dd-0a6ba5c01216',
      jsonb_build_object(
        'CUSTOMER_NAME',coalesce(nullif(trim(v_profile.username),''),nullif(trim(v_full_name),''),'Cliente AvoHouse'),
        'CHANGED_FIELDS',v_changed_fields,
        'EDITED_AT',to_char(now() at time zone 'America/Bogota','DD/MM/YYYY HH24:MI')
      )
    );
  end if;

  return jsonb_build_object(
    'updated',true,
    'email_changed',coalesce(v_old_email,'') is distinct from v_email,
    'notification_sent',nullif(trim(coalesce(v_changed_fields,'')),'') is not null,
    'changed_fields',v_changed_fields,
    'profile',(
      select jsonb_build_object(
        'id',id,'username',username,'full_name',full_name,'email',email,'phone',phone,
        'whatsapp',whatsapp,'whatsapp_same',whatsapp_same,'instagram',instagram,
        'document_type',document_type,'document_number',document_number,
        'birth_date',birth_date,'created_at',created_at
      ) from public.profiles where id=p_profile_id
    )
  );
end;
$function$;