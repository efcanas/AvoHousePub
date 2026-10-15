-- Optimize RLS predicates so auth.uid() is evaluated once per statement
-- rather than once per row. Only rewrites policy expressions that still contain
-- a direct auth.uid() call; existing SELECT-wrapped expressions are left intact.
DO $migration$
DECLARE
  p record;
  v_qual text;
  v_check text;
  v_stmt text;
  v_updated integer := 0;
BEGIN
  FOR p IN
    SELECT schemaname, tablename, policyname, qual, with_check
    FROM pg_policies
    WHERE schemaname = 'public'
      AND (
        (coalesce(qual, '') ~* 'auth[.]uid[[:space:]]*[(][[:space:]]*[)]'
         AND coalesce(qual, '') !~* 'SELECT[[:space:]]+auth[.]uid[[:space:]]*[(]')
        OR
        (coalesce(with_check, '') ~* 'auth[.]uid[[:space:]]*[(][[:space:]]*[)]'
         AND coalesce(with_check, '') !~* 'SELECT[[:space:]]+auth[.]uid[[:space:]]*[(]')
      )
    ORDER BY tablename, policyname
  LOOP
    v_qual := p.qual;
    v_check := p.with_check;

    IF v_qual IS NOT NULL
       AND v_qual ~* 'auth[.]uid[[:space:]]*[(][[:space:]]*[)]'
       AND v_qual !~* 'SELECT[[:space:]]+auth[.]uid[[:space:]]*[(]' THEN
      v_qual := regexp_replace(v_qual,
        'auth[.]uid[[:space:]]*[(][[:space:]]*[)]',
        '(SELECT auth.uid())', 'gi');
    END IF;

    IF v_check IS NOT NULL
       AND v_check ~* 'auth[.]uid[[:space:]]*[(][[:space:]]*[)]'
       AND v_check !~* 'SELECT[[:space:]]+auth[.]uid[[:space:]]*[(]' THEN
      v_check := regexp_replace(v_check,
        'auth[.]uid[[:space:]]*[(][[:space:]]*[)]',
        '(SELECT auth.uid())', 'gi');
    END IF;

    v_stmt := format('ALTER POLICY %I ON %I.%I',
                     p.policyname, p.schemaname, p.tablename);
    IF v_qual IS NOT NULL THEN
      v_stmt := v_stmt || format(' USING (%s)', v_qual);
    END IF;
    IF v_check IS NOT NULL THEN
      v_stmt := v_stmt || format(' WITH CHECK (%s)', v_check);
    END IF;

    EXECUTE v_stmt;
    v_updated := v_updated + 1;
  END LOOP;
  RAISE NOTICE 'RLS policies optimized: %', v_updated;
END
$migration$;
