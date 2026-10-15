-- Restrict direct invocation of pg_net HTTP entry points to trusted backend roles.
-- Internal SECURITY DEFINER wrappers execute as postgres, and pg_cron jobs run as postgres.
REVOKE EXECUTE ON FUNCTION
  net.http_collect_response(bigint, boolean),
  net.http_delete(text, jsonb, jsonb, integer, jsonb),
  net.http_get(text, jsonb, jsonb, integer),
  net.http_post(text, jsonb, jsonb, jsonb, integer)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  net.http_collect_response(bigint, boolean),
  net.http_delete(text, jsonb, jsonb, integer, jsonb),
  net.http_get(text, jsonb, jsonb, integer),
  net.http_post(text, jsonb, jsonb, jsonb, integer)
TO postgres, service_role;
