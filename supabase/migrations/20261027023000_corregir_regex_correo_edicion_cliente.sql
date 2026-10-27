DO $repair$
DECLARE
  v_definition text;
  v_old text := chr(92) || chr(92) || '.';
  v_new text := chr(92) || '.';
  v_repaired text;
BEGIN
  v_definition := pg_get_functiondef(
    'public.avopuntos_admin_update_customer_profile(uuid,text,text,text,boolean,text,text,text,text,date)'::regprocedure
  );

  IF strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'No se encontró la secuencia de escape duplicada en la validación del correo.';
  END IF;

  v_repaired := replace(v_definition, v_old, v_new);

  IF v_repaired = v_definition THEN
    RAISE EXCEPTION 'La definición de la función no cambió; se cancela la migración.';
  END IF;

  EXECUTE v_repaired;
END;
$repair$;