-- API sessions preload pg_safeupdate; functions reached through PostgREST must
-- not issue UPDATE or DELETE without a WHERE clause.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(1);

SELECT is(
  ARRAY(
    SELECT p.oid::regprocedure::TEXT FROM pg_proc p
    WHERE p.pronamespace::regnamespace::TEXT IN ('public','private') AND p.prolang=(SELECT oid FROM pg_language WHERE lanname='plpgsql')
      AND EXISTS (
        SELECT 1 FROM regexp_matches(regexp_replace(p.prosrc,'--[^\n]*','','g'),
          '\m(UPDATE\s+[a-z_.]+\s+(?:AS\s+\w+\s+)?SET|DELETE\s+FROM\s+[a-z_.]+)\M([^;]*);','gi') m
        WHERE m[2] !~* '\mWHERE\M')
    ORDER BY 1),
  ARRAY[]::TEXT[],
  'no plpgsql function updates or deletes without a WHERE clause');

SELECT * FROM finish();
ROLLBACK;
