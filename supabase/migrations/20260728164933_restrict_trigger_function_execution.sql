BEGIN;

-- Trigger functions are invoked by their bound trigger, not as client RPCs.
-- Keep them available to their owner/service role while removing a privileged
-- direct-call surface from signed-in Data API clients.
DO $$
DECLARE
  fn RECORD;
BEGIN
  FOR fn IN
    SELECT
      n.nspname AS schema_name,
      p.proname AS function_name,
      pg_get_function_identity_arguments(p.oid) AS identity_arguments
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prokind = 'f'
      AND p.prosecdef
      AND p.prorettype IN (
        'pg_catalog.trigger'::pg_catalog.regtype,
        'pg_catalog.event_trigger'::pg_catalog.regtype
      )
  LOOP
    EXECUTE format(
      'REVOKE EXECUTE ON FUNCTION %I.%I(%s) FROM PUBLIC, anon, authenticated',
      fn.schema_name,
      fn.function_name,
      fn.identity_arguments
    );
    EXECUTE format(
      'GRANT EXECUTE ON FUNCTION %I.%I(%s) TO service_role',
      fn.schema_name,
      fn.function_name,
      fn.identity_arguments
    );
  END LOOP;
END
$$;

COMMIT;
