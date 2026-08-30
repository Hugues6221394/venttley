BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(6);

SELECT ok(
  EXISTS (
    SELECT 1
      FROM storage.buckets
     WHERE id = 'media-quarantine'
       AND public IS FALSE
  ),
  'the quarantine bucket exists and is private'
);

SELECT is(
  (
    SELECT count(*)::INT
      FROM pg_catalog.pg_policy p
      JOIN pg_catalog.pg_class c ON c.oid = p.polrelid
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'storage'
       AND c.relname = 'objects'
       AND (
         pg_catalog.pg_get_expr(p.polqual, p.polrelid) ILIKE '%media-quarantine%'
         OR pg_catalog.pg_get_expr(p.polwithcheck, p.polrelid) ILIKE '%media-quarantine%'
       )
  ),
  0,
  'no client storage policy names the quarantine bucket'
);

SELECT has_function(
  'public',
  'my_password_changed_at',
  ARRAY[]::TEXT[],
  'the checkup reads the rotation stamp through a definer'
);

SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.my_password_changed_at()',
    'EXECUTE'
  ),
  'anon cannot read password rotation'
);

SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.my_password_changed_at()',
    'EXECUTE'
  ),
  'a signed-in user can read their own rotation stamp'
);

SELECT ok(
  NOT has_column_privilege(
    'authenticated',
    'public.users',
    'password_changed_at',
    'SELECT'
  ),
  'the rotation stamp is not a public users column'
);

SELECT * FROM finish();
ROLLBACK;
