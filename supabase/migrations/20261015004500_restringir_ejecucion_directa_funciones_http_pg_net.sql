-- Intended restriction for direct pg_net HTTP entry points.
-- IMPORTANT: In the AHtv production database, these pg_net functions are owned
-- by the provider role supabase_admin. The migration execution role postgres is
-- not a superuser and is not a member of supabase_admin, so this REVOKE/GRANT
-- did NOT change their effective ACL in production (verified after application).
-- Do not treat this file alone as proof that direct EXECUTE was restricted.
-- Completion requires the extension owner / Supabase Support to apply the ACL
-- change, then verify has_function_privilege() for anon and authenticated.
-- Internal wrappers and pg_cron jobs currently run as postgres and require
-- continued EXECUTE access to these routines.

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
