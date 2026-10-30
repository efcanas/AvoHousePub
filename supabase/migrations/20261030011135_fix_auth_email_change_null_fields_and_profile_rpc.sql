DO $repair$
DECLARE
  v_definition text;
  v_old text := 'email_change=null,email_change_token_new=null';
  v_new text := 'email_change='''' ,email_change_token_new=''''';
  v_repaired text;
BEGIN
  v_definition := pg_get_functiondef(
    'public.avopuntos_admin_update_customer_profile(uuid,text,text,text,boolean,text,text,text,text,date)'::regprocedure
  );

  IF strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'No se encontró la asignación NULL esperada en la función de edición de clientes. No se aplicó ningún cambio.';
  END IF;

  v_repaired := replace(v_definition, v_old, v_new);

  IF v_repaired = v_definition THEN
    RAISE EXCEPTION 'La definición de la función no cambió; se cancela la migración.';
  END IF;

  EXECUTE v_repaired;
END;
$repair$;

UPDATE auth.users
SET
  email_change = COALESCE(email_change, ''),
  email_change_token_new = COALESCE(email_change_token_new, '')
WHERE email_change IS NULL
   OR email_change_token_new IS NULL;
