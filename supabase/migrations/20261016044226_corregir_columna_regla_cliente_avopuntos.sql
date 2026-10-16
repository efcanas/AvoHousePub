-- Corrige la selección de la etiqueta de una regla individual de AvoPuntos.
-- avopuntos_customer_rules expone "reason", no "name". La regla de promoción
-- sí tiene "name", por lo que solo se cambia la referencia a la tabla de reglas.
DO $migration$
DECLARE
  v_definition text;
  v_old text := $old$select p.multiplier,p.name,p.id
      into v_multiplier,v_rule_name,v_rule_id
    from public.avopuntos_customer_rules p$old$;
  v_new text := $new$select p.multiplier,p.reason,p.id
      into v_multiplier,v_rule_name,v_rule_id
    from public.avopuntos_customer_rules p$new$;
BEGIN
  v_definition := pg_get_functiondef('public.avopuntos_process_receipt(text)'::regprocedure);

  IF position(v_old IN v_definition) = 0 THEN
    RAISE EXCEPTION 'No se encontró el fragmento esperado de avopuntos_customer_rules; no se modificó la función.';
  END IF;

  v_definition := replace(v_definition, v_old, v_new);
  EXECUTE v_definition;
END;
$migration$;
