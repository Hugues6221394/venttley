BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(21);

SELECT has_table('public', 'tribe_rule_items', 'structured Tribe rules exist');
SELECT has_table('public', 'tribe_join_requests', 'join approvals exist');
SELECT has_table(
  'public',
  'tribe_ownership_transfers',
  'accepted ownership transfer workflow exists'
);
SELECT has_table('public', 'tribe_audit_log', 'immutable Tribe audit exists');
SELECT is(
  (
    SELECT c.relrowsecurity
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = 'tribe_audit_log'
  ),
  TRUE,
  'Tribe audit is protected by RLS'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'public.tribe_audit_log', 'INSERT'),
  'clients cannot forge Tribe audit records'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.create_managed_tribe(text,text,text,text,text[],text,jsonb,jsonb)',
    'EXECUTE'
  ),
  'approved Plugz can use atomic Tribe creation'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.tribe_management_overview(uuid)',
    'EXECUTE'
  ),
  'owners can request the management read model'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.initiate_tribe_transfer(uuid,uuid,boolean)',
    'EXECUTE'
  ),
  'owners can initiate accepted transfers'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.respond_tribe_transfer(uuid,boolean)',
    'EXECUTE'
  ),
  'recipients can answer transfers'
);
SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.set_tribe_lifecycle(uuid,text,text,text)',
    'EXECUTE'
  ),
  'anonymous callers cannot change Tribe lifecycle'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public.purge_due_tribes()',
    'EXECUTE'
  ),
  'clients cannot purge deletion-pending Tribes'
);
SELECT ok(
  has_function_privilege('service_role', 'public.purge_due_tribes()', 'EXECUTE'),
  'only the service role can run the permanent purge'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.admin_restore_tribe(uuid,text)',
    'EXECUTE'
  ),
  'staff recovery is exposed through a role-checked function'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.can_read_tribe_content(uuid,uuid)',
    'EXECUTE'
  ),
  'Tribe post visibility uses a protected lifecycle-aware predicate'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.managed_tribe_posts(uuid,integer)',
    'EXECUTE'
  ),
  'Tribe managers have an owner-only content queue'
);
SELECT has_trigger(
  'public',
  'tribes',
  'ensure_default_tribe_space',
  'every new Tribe receives a General Space'
);
SELECT has_trigger(
  'public',
  'posts',
  'guard_tribe_content_write',
  'Tribe settings govern new posts'
);
SELECT is(
  (
    SELECT 'security_invoker=true' = ANY (COALESCE(c.reloptions, ARRAY[]::TEXT[]))
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = 'tribe_directory'
  ),
  TRUE,
  'Tribe directory uses caller RLS'
);
SELECT is(
  (
    SELECT 'security_invoker=true' = ANY (COALESCE(c.reloptions, ARRAY[]::TEXT[]))
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = 'space_directory'
  ),
  TRUE,
  'Space directory uses caller RLS'
);
SELECT ok(
  EXISTS (
    SELECT 1
      FROM pg_catalog.pg_constraint c
      JOIN pg_catalog.pg_class t ON t.oid = c.conrelid
     WHERE t.relname = 'notifications'
       AND c.conname = 'notifications_kind_check'
       AND pg_get_constraintdef(c.oid) LIKE '%tribe_ownership_transfer%'
  ),
  'ownership transfers are valid notification events'
);

SELECT * FROM finish();
ROLLBACK;
