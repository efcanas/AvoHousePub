-- Collapse pairs of PERMISSIVE SELECT policies into one equivalent OR predicate.
-- Each consolidation preserves the previous rule: a user can read their own rows,
-- and an administrator can read all rows. No write policies are changed.

ALTER POLICY avopuntos_accounts_self_select
  ON public.avopuntos_accounts
  USING (
    profile_id = (SELECT auth.uid())
    OR EXISTS (
      SELECT 1 FROM public.admin_users au
      WHERE au.user_id = (SELECT auth.uid())
    )
  );
DROP POLICY avopuntos_accounts_admin_select ON public.avopuntos_accounts;
ALTER POLICY avopuntos_accounts_self_select
  ON public.avopuntos_accounts RENAME TO avopuntos_accounts_self_and_admin_select;

ALTER POLICY avopuntos_movements_self_select
  ON public.avopuntos_movements
  USING (
    profile_id = (SELECT auth.uid())
    OR EXISTS (
      SELECT 1 FROM public.admin_users au
      WHERE au.user_id = (SELECT auth.uid())
    )
  );
DROP POLICY avopuntos_movements_admin_select ON public.avopuntos_movements;
ALTER POLICY avopuntos_movements_self_select
  ON public.avopuntos_movements RENAME TO avopuntos_movements_self_and_admin_select;

ALTER POLICY "Clients can read own activity events"
  ON public.customer_activity_events
  USING (
    profile_id = (SELECT auth.uid())
    OR EXISTS (
      SELECT 1 FROM public.admin_users au
      WHERE au.user_id = (SELECT auth.uid())
    )
  );
DROP POLICY "Admins can read all activity events" ON public.customer_activity_events;
ALTER POLICY "Clients can read own activity events"
  ON public.customer_activity_events RENAME TO "Clients and admins can read activity events";

ALTER POLICY loyverse_receipts_self_select
  ON public.loyverse_receipts
  USING (
    profile_id = (SELECT auth.uid())
    OR EXISTS (
      SELECT 1 FROM public.admin_users au
      WHERE au.user_id = (SELECT auth.uid())
    )
  );
DROP POLICY loyverse_receipts_admin_select ON public.loyverse_receipts;
ALTER POLICY loyverse_receipts_self_select
  ON public.loyverse_receipts RENAME TO loyverse_receipts_self_and_admin_select;

ALTER POLICY "Users can read own profile"
  ON public.profiles
  USING (
    id = (SELECT auth.uid())
    OR EXISTS (
      SELECT 1 FROM public.admin_users au
      WHERE au.user_id = (SELECT auth.uid())
    )
  );
DROP POLICY profiles_admin_select ON public.profiles;
ALTER POLICY "Users can read own profile"
  ON public.profiles RENAME TO "Users and admins can read profiles";
