-- The home rail must return the same shape as every other path to a Tribe.
--
-- recommended_tribes declares an explicit RETURNS TABLE. Every other source of
-- a Tribe reads tribe_directory — directly, or through user_public_tribes,
-- which is SETOF tribe_directory and so widens by itself whenever the view
-- does. This one has to be widened by hand, and when the view gained six
-- columns nobody did.
--
-- Nothing failed. PostgREST omits a column that was never selected, the client
-- reads null, and null is indistinguishable from a real null — so the home
-- rail quietly showed every tribe with no keeper photo, no lifecycle status
-- and no tags, while the same tribe on the directory screen showed all three.
--
-- This test is written against the column list rather than the values on
-- purpose: the failure mode is a column that is absent, and a value assertion
-- on an absent column reads as a null and passes.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(3);

-- The columns a RETURNS TABLE function hands back. information_schema is
-- awkward here; pg_proc says it plainly — proargmodes 't' marks a TABLE
-- column, as opposed to an ordinary IN parameter.
CREATE TEMP VIEW rt_columns AS
  SELECT col FROM (
    SELECT unnest(p.proargnames) AS col, unnest(p.proargmodes) AS mode
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'recommended_tribes'
  ) x WHERE mode = 't';

-- Every column the client's Tribe mapper reads from this function. Adding one
-- to tribe_directory and to the mapper without adding it here is the mistake
-- this catches.
SELECT is(
  (SELECT count(*)::int
     FROM unnest(ARRAY['lifecycle_status','lifecycle_reason','paused_at',
                       'deletion_purge_at','tags','keeper_profile_photo_url']) AS needed
    WHERE needed NOT IN (SELECT col FROM rt_columns)),
  0,
  'recommended_tribes returns every column the Tribe mapper reads'
);

-- The stronger property, and the one that keeps this from drifting again:
-- anything tribe_directory offers that the mapper uses must be reachable here.
SELECT ok(
  NOT EXISTS (
    SELECT 1
      FROM information_schema.columns c
     WHERE c.table_schema = 'public'
       AND c.table_name = 'tribe_directory'
       AND c.column_name IN ('lifecycle_status','lifecycle_reason','paused_at',
                             'deletion_purge_at','tags','keeper_profile_photo_url',
                             'theme_color','keeper_is_verified')
       AND c.column_name NOT IN (SELECT col FROM rt_columns)
  ),
  'and has not fallen behind tribe_directory again'
);

-- Widening a RETURNS TABLE means dropping and recreating it, which drops the
-- grants with it. A rail nobody can call is a worse outcome than a rail
-- missing a photo.
SELECT ok(
  has_function_privilege('authenticated', 'public.recommended_tribes(INT)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.recommended_tribes(INT)', 'EXECUTE'),
  'members can still call it and signed-out callers still cannot'
);

SELECT * FROM finish();
ROLLBACK;
