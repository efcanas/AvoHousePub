-- La recompensa de creación de cuenta se ejecuta exclusivamente desde un trigger.
-- No debe exponerse como una RPC invocable por clientes autenticados o anónimos.
REVOKE EXECUTE ON FUNCTION public.avopuntos_grant_account_creation_reward() FROM PUBLIC, anon, authenticated;
