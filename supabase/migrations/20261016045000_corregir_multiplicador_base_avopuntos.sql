-- Restablece el multiplicador base cuando no existe una promoción activa.
-- En PL/pgSQL, SELECT INTO sin filas deja los campos destino en NULL; por eso
-- el motor debe volver explícitamente a multiplicador 1 cuando no hay promoción.
DO $migration$
DECLARE
  v_definition text;
  v_old text := $old$      if v_rule_id is not null then
        v_rule_type:='promotion';
      else
        v_rule_type:='base';
      end if;$old$;
  v_new text := $new$      if v_rule_id is not null then
        v_rule_type:='promotion';
      else
        v_rule_type:='base';
        v_multiplier:=1;
        v_rule_name:=null;
        v_rule_id:=null;
      end if;$new$;
BEGIN
  v_definition := pg_get_functiondef('public.avopuntos_process_receipt(text)'::regprocedure);

  IF position(v_old IN v_definition) = 0 THEN
    RAISE EXCEPTION 'No se encontró el bloque esperado de multiplicador base; no se modificó la función.';
  END IF;

  v_definition := replace(v_definition, v_old, v_new);
  EXECUTE v_definition;
END;
$migration$;
