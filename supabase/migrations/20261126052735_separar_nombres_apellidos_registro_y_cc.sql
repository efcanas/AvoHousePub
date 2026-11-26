-- Registra nombres y apellidos por separado sin cambiar el campo compuesto full_name.
-- Los perfiles históricos conservan sus datos y quedan con first_name/last_name en NULL.
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS first_name text,
  ADD COLUMN IF NOT EXISTS last_name text;

COMMENT ON COLUMN public.profiles.first_name IS 'Nombres capturados por separado en el registro; NULL para perfiles históricos o nombres editados como texto compuesto.';
COMMENT ON COLUMN public.profiles.last_name IS 'Apellidos capturados por separado en el registro; NULL para perfiles históricos o nombres editados como texto compuesto.';

CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  p_username text := trim(coalesce(meta->>'username', ''));
  p_first_name text := nullif(regexp_replace(trim(coalesce(meta->>'first_name','')), '\s+', ' ', 'g'), '');
  p_last_name text := nullif(regexp_replace(trim(coalesce(meta->>'last_name','')), '\s+', ' ', 'g'), '');
  p_full_name text;
  p_birth_date date;
  p_phone text := coalesce(meta->>'phone', '');
  p_whatsapp_same boolean := coalesce((meta->>'whatsapp_same')::boolean, true);
  p_whatsapp text := coalesce(meta->>'whatsapp', p_phone);
  p_age boolean := false;
  p_terms boolean := coalesce((meta->>'terms_accepted')::boolean, false);
  p_data boolean := coalesce((meta->>'data_authorized')::boolean, false);
  p_marketing boolean := coalesce((meta->>'marketing_authorized')::boolean, false);
begin
  if p_username = '' then
    raise exception 'El nickname es obligatorio.';
  end if;

  if p_username !~ '^[A-Za-z0-9_]{3,20}$' then
    raise exception 'El nickname debe tener entre 3 y 20 caracteres y usar solo letras, números o guion bajo.';
  end if;

  if public.nickname_is_reserved(p_username) then
    raise exception 'Ese nickname está reservado. Elige otro.';
  end if;

  if exists (
    select 1 from public.profiles
    where lower(username) = lower(p_username)
  ) then
    raise exception 'Ese nickname ya está en uso.';
  end if;

  if p_first_name is null and p_last_name is null then
    -- Compatibilidad con registros anteriores que solo enviaban full_name.
    p_full_name := trim(coalesce(meta->>'full_name',''));
  elsif p_first_name is null or p_last_name is null then
    raise exception 'Indica nombres y apellidos completos.';
  else
    if length(p_first_name) > 100 or length(p_last_name) > 100 then
      raise exception 'Los nombres y apellidos no pueden superar 100 caracteres cada uno.';
    end if;
    p_full_name := p_first_name || ' ' || p_last_name;
  end if;

  if p_full_name = '' then
    raise exception 'El nombre completo es obligatorio.';
  end if;

  begin
    p_birth_date := nullif(trim(coalesce(meta->>'birth_date', '')), '')::date;
  exception
    when others then
      raise exception 'La fecha de nacimiento no es válida.';
  end;

  if p_birth_date is null then
    raise exception 'La fecha de nacimiento es obligatoria.';
  end if;

  if p_birth_date > current_date then
    raise exception 'La fecha de nacimiento no puede ser futura.';
  end if;

  p_age := p_birth_date <= (current_date - interval '18 years')::date;

  if not p_age then
    raise exception 'Debes ser mayor de 18 años para registrarte.';
  end if;

  if not p_terms or not p_data then
    raise exception 'Required legal consent missing';
  end if;

  insert into public.profiles (
    id, full_name, first_name, last_name, document_type, document_number, email,
    phone, whatsapp, whatsapp_same, username, birth_date
  )
  values (
    new.id, p_full_name, p_first_name, p_last_name,
    coalesce(meta->>'document_type',''),
    coalesce(meta->>'document_number',''),
    coalesce(new.email,''),
    p_phone,
    p_whatsapp,
    p_whatsapp_same,
    p_username,
    p_birth_date
  );

  insert into public.legal_acceptances (
    user_id, terms_version, privacy_version, data_authorization_version,
    data_authorized, age_confirmed, marketing_authorized
  )
  values (
    new.id,
    coalesce(meta->>'terms_version','1.0'),
    coalesce(meta->>'privacy_version','1.0'),
    coalesce(meta->>'data_authorization_version','1.0'),
    p_data,
    p_age,
    p_marketing
  );

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.avopuntos_admin_list_customers(p_search text DEFAULT NULL::text, p_filter text DEFAULT 'all'::text, p_sort text DEFAULT 'newest'::text, p_page integer DEFAULT 1, p_page_size integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
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
    count(*) FILTER (
      WHERE p.created_at >= now() - interval '30 days'
    )::bigint,
    count(*) FILTER (
      WHERE au.email_confirmed_at IS NOT NULL
    )::bigint,
    count(*) FILTER (
      WHERE coalesce(aa.balance, 0) > 0
    )::bigint
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
      jsonb_build_object(
        'month', to_char(month_start, 'YYYY-MM'),
        'count', customer_count
      )
      ORDER BY month_start
    ),
    '[]'::jsonb
  )
  INTO v_monthly
  FROM (
    SELECT
      m.month_start,
      count(p.id)::integer AS customer_count
    FROM month_series m
    LEFT JOIN public.profiles p
      ON p.created_at >= (m.month_start AT TIME ZONE 'America/Bogota')
     AND p.created_at < ((m.month_start + interval '1 month') AT TIME ZONE 'America/Bogota')
    GROUP BY m.month_start
  ) monthly_counts;

  WITH customer_base AS (
    SELECT
      p.id,
      p.username,
      p.full_name,
      p.first_name,
      p.last_name,
      p.email,
      p.phone,
      p.whatsapp,
      p.whatsapp_same,
      p.instagram,
      p.document_number,
      p.document_type,
      p.created_at,
      p.birth_date,
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
          'first_name', first_name,
          'last_name', last_name,
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
      'from', CASE
        WHEN v_total_filtered = 0 THEN 0
        ELSE ((v_page - 1) * v_page_size) + 1
      END,
      'to', least(v_page * v_page_size, v_total_filtered)
    ),
    'customers', v_customers
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.avopuntos_admin_update_customer_profile(p_profile_id uuid, p_full_name text, p_email text, p_phone text, p_whatsapp_same boolean, p_whatsapp text, p_instagram text, p_document_type text, p_document_number text, p_birth_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
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
  if v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'El correo electrónico no tiene un formato válido.'; end if;
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
  set email=v_email,email_change='',email_change_token_new='',email_change_confirm_status=0,
      raw_user_meta_data=case
        when v_profile.full_name is distinct from v_full_name then
          (coalesce(raw_user_meta_data,'{}'::jsonb)-'first_name'-'last_name') || jsonb_build_object('full_name',v_full_name)
        else raw_user_meta_data
      end
  where id=p_profile_id;
  if not found then raise exception 'No se encontró la cuenta de acceso del cliente.'; end if;

  update public.profiles
  set full_name=v_full_name,
      first_name=case when v_profile.full_name is distinct from v_full_name then null else first_name end,
      last_name=case when v_profile.full_name is distinct from v_full_name then null else last_name end,
      email=v_email,phone=v_phone,
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
        'id',id,'username',username,'full_name',full_name,'first_name',first_name,'last_name',last_name,'email',email,'phone',phone,
        'whatsapp',whatsapp,'whatsapp_same',whatsapp_same,'instagram',instagram,
        'document_type',document_type,'document_number',document_number,
        'birth_date',birth_date,'created_at',created_at
      ) from public.profiles where id=p_profile_id
    )
  );
end;
$function$
;
