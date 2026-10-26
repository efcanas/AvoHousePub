-- El logro Piloto se notifica únicamente cuando el usuario confirma su correo.
-- La fecha original de creación sigue determinando la elegibilidad hasta 2026-12-31.
-- No se modifica el saldo, ni los movimientos, ni las recompensas de usuarios existentes.

DROP TRIGGER IF EXISTS trg_profiles_pilot_achievement_email ON public.profiles;

CREATE OR REPLACE FUNCTION public.avohouse_trigger_pilot_achievement_email()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF OLD.email_confirmed_at IS NULL
     AND NEW.email_confirmed_at IS NOT NULL
     AND NEW.created_at IS NOT NULL
     AND (NEW.created_at AT TIME ZONE 'America/Bogota')::date <= DATE '2026-12-31'
  THEN
    PERFORM public.avohouse_queue_pilot_achievement_email(NEW.id);
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_auth_user_confirmed_pilot_achievement_email ON auth.users;

CREATE TRIGGER trg_auth_user_confirmed_pilot_achievement_email
AFTER UPDATE OF email_confirmed_at ON auth.users
FOR EACH ROW
WHEN (OLD.email_confirmed_at IS NULL AND NEW.email_confirmed_at IS NOT NULL)
EXECUTE FUNCTION public.avohouse_trigger_pilot_achievement_email();
