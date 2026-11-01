-- Extiende únicamente la vigencia del beneficio Piloto hasta el 31/01/2027.
-- La adquisición continúa limitada a perfiles creados hasta el 31/12/2026.
-- Se preserva sin cambios la lógica vigente de prioridad y selección de multiplicadores.

DO $migration$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
BEGIN
  -- Retorno mostrado en la cuenta: ampliar únicamente la vigencia del Piloto.
  v_definition := pg_get_functiondef('public.avopuntos_get_my_current_return()'::regprocedure);

  v_old := $str$AND v_today <= DATE '2026-12-31' THEN$str$;
  v_new := $str$AND v_today <= DATE '2027-01-31' THEN$str$;
  IF strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'No se encontró la condición de vigencia del Piloto en avopuntos_get_my_current_return().';
  END IF;
  v_definition := replace(v_definition, v_old, v_new);

  v_old := $str$v_end_date:=DATE '2026-12-31';$str$;
  v_new := $str$v_end_date:=DATE '2027-01-31';$str$;
  IF strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'No se encontró la fecha final del Piloto en avopuntos_get_my_current_return().';
  END IF;
  v_definition := replace(v_definition, v_old, v_new);
  EXECUTE v_definition;

  -- Motor real de acreditación: las compras del 01 al 31/01/2027 siguen recibiendo AP×2.
  -- El requisito de creación del perfil hasta el 31/12/2026 queda intacto.
  v_definition := pg_get_functiondef('public.avopuntos_process_receipt(text)'::regprocedure);

  v_old := $str$AND v_business_date <= DATE '2026-12-31' THEN$str$;
  v_new := $str$AND v_business_date <= DATE '2027-01-31' THEN$str$;
  IF strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'No se encontró la fecha final del Piloto en avopuntos_process_receipt().';
  END IF;
  v_definition := replace(v_definition, v_old, v_new);

  v_old := $str$hasta el 31/12/2026 inclusive (hora Colombia).$str$;
  v_new := $str$hasta el 31/01/2027 inclusive (hora Colombia).$str$;
  IF strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'No se encontró el comentario de vigencia del Piloto en avopuntos_process_receipt().';
  END IF;
  v_definition := replace(v_definition, v_old, v_new);
  EXECUTE v_definition;

  -- CC: mantener la adquisición hasta 31/12/2026 y mostrar el beneficio activo hasta 31/01/2027.
  v_definition := pg_get_functiondef('public.avopuntos_admin_get_customer_rule(uuid)'::regprocedure);

  v_old := $str$AND v_today <= DATE '2026-12-31'$str$;
  v_new := $str$AND v_today <= DATE '2027-01-31'$str$;
  IF strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'No se encontró la vigencia del Piloto en avopuntos_admin_get_customer_rule().';
  END IF;
  v_definition := replace(v_definition, v_old, v_new);

  v_old := $str$'end_date', DATE '2026-12-31',$str$;
  v_new := $str$'end_date', DATE '2027-01-31',$str$;
  IF strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'No se encontró la fecha final del Piloto para CC.';
  END IF;
  v_definition := replace(v_definition, v_old, v_new);

  v_old := $str$WHEN v_today > DATE '2026-12-31' THEN 'Finalizado'$str$;
  v_new := $str$WHEN v_today > DATE '2027-01-31' THEN 'Finalizado'$str$;
  IF strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'No se encontró el estado final del Piloto para CC.';
  END IF;
  v_definition := replace(v_definition, v_old, v_new);
  EXECUTE v_definition;

  -- Correo del logro: solo cambia la fecha de vigencia comunicada.
  v_definition := pg_get_functiondef('public.avohouse_queue_pilot_achievement_email(uuid)'::regprocedure);

  v_old := $str$'VALID_UNTIL','31 de diciembre de 2026',$str$;
  v_new := $str$'VALID_UNTIL','31 de enero de 2027',$str$;
  IF strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'No se encontró VALID_UNTIL en el correo del logro Piloto.';
  END IF;
  v_definition := replace(v_definition, v_old, v_new);
  EXECUTE v_definition;
END;
$migration$;

UPDATE public.avopuntos_rewards
SET description = '¡Gracias por ser parte del plan piloto! Por acompañarnos en esta primera etapa de AvoHousePub.com, tus compras elegibles acumulan el doble de AvoPuntos (AP×2) hasta el 31 de enero de 2027. La adquisición del logro aplica únicamente a cuentas creadas hasta el 31 de diciembre de 2026.',
    updated_at = now()
WHERE code = 'pilot_launch_2026';
