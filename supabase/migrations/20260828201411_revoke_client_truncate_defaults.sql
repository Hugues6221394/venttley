-- RLS is not evaluated for TRUNCATE. Supabase's baseline default privileges
-- grant it to API roles, so tables created after the earlier one-time cleanup
-- can accidentally become destructively callable through PostgREST. Remove
-- the privilege from every current public table and from future tables created
-- by the migration owner.

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE TRUNCATE ON TABLES FROM anon, authenticated;

DO $$
DECLARE
  relation RECORD;
BEGIN
  FOR relation IN
    SELECT namespace.nspname AS schema_name, class.relname AS table_name
      FROM pg_catalog.pg_class AS class
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = class.relnamespace
     WHERE namespace.nspname = 'public'
       AND class.relkind IN ('r', 'p')
  LOOP
    EXECUTE format(
      'REVOKE TRUNCATE ON TABLE %I.%I FROM anon, authenticated',
      relation.schema_name,
      relation.table_name
    );
  END LOOP;
END;
$$;

SELECT public.record_migration(
  '20260828201411',
  'revoke_client_truncate_defaults'
);

NOTIFY pgrst, 'reload schema';
