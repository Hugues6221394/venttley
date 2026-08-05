-- PostgreSQL can evaluate a bare auth.uid() once per candidate row in an RLS
-- policy. Wrapping it in a scalar SELECT turns it into an init plan that is
-- evaluated once per statement. Rewrite only the policy expressions; commands,
-- roles, policy names, and authorization predicates remain unchanged.
DO $$
DECLARE
  policy_record RECORD;
  optimized_qual TEXT;
  optimized_check TEXT;
  statement TEXT;
BEGIN
  FOR policy_record IN
    SELECT
      schemaname,
      tablename,
      policyname,
      qual,
      with_check
    FROM pg_policies
    WHERE schemaname IN ('public', 'storage')
      AND (
        replace(coalesce(qual, ''), '( SELECT auth.uid() AS uid)', '__cached_auth_uid__')
          LIKE '%auth.uid()%'
        OR replace(coalesce(with_check, ''), '( SELECT auth.uid() AS uid)', '__cached_auth_uid__')
          LIKE '%auth.uid()%'
      )
  LOOP
    optimized_qual := NULL;
    optimized_check := NULL;

    IF policy_record.qual IS NOT NULL THEN
      optimized_qual := replace(
        replace(
          policy_record.qual,
          '( SELECT auth.uid() AS uid)',
          '__cached_auth_uid__'
        ),
        'auth.uid()',
        '( SELECT auth.uid() AS uid)'
      );
      optimized_qual := replace(
        optimized_qual,
        '__cached_auth_uid__',
        '( SELECT auth.uid() AS uid)'
      );
    END IF;

    IF policy_record.with_check IS NOT NULL THEN
      optimized_check := replace(
        replace(
          policy_record.with_check,
          '( SELECT auth.uid() AS uid)',
          '__cached_auth_uid__'
        ),
        'auth.uid()',
        '( SELECT auth.uid() AS uid)'
      );
      optimized_check := replace(
        optimized_check,
        '__cached_auth_uid__',
        '( SELECT auth.uid() AS uid)'
      );
    END IF;

    statement := format(
      'ALTER POLICY %I ON %I.%I',
      policy_record.policyname,
      policy_record.schemaname,
      policy_record.tablename
    );

    IF optimized_qual IS NOT NULL THEN
      statement := statement || format(' USING (%s)', optimized_qual);
    END IF;
    IF optimized_check IS NOT NULL THEN
      statement := statement || format(' WITH CHECK (%s)', optimized_check);
    END IF;

    EXECUTE statement;
  END LOOP;
END
$$;
