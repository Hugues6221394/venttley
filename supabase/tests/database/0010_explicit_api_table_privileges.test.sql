BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(24);

SELECT ok(
  has_table_privilege('authenticated', 'public.chat_rooms', 'SELECT'),
  'authenticated members can read their RLS-visible chat rooms'
);
SELECT ok(
  has_table_privilege('authenticated', 'public.chat_messages', 'SELECT'),
  'authenticated members can read their RLS-visible chat messages'
);
SELECT ok(
  has_table_privilege('authenticated', 'public.posts', 'SELECT'),
  'authenticated members can read RLS-visible Vents'
);
SELECT ok(
  has_table_privilege('authenticated', 'public.personas', 'SELECT'),
  'authenticated members can resolve RLS-visible personas'
);
SELECT ok(
  has_table_privilege('authenticated', 'public.posts_comments', 'SELECT'),
  'authenticated members can read RLS-visible Vent comments'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'public.post_likes', 'INSERT'),
  'Vent reactions must enter through the desired-state RPC'
);
SELECT ok(
  has_table_privilege('authenticated', 'public.post_saves', 'INSERT'),
  'authenticated members can save Vents through the RLS-protected table'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'public.posts', 'INSERT'),
  'new Vents must enter through the moderated idempotent RPC'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'public.chat_messages', 'INSERT'),
  'new chat messages must enter through the moderated idempotent RPC'
);
SELECT is(
  (
    SELECT count(*)
      FROM pg_catalog.pg_class AS class
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = class.relnamespace
     WHERE namespace.nspname = 'public'
       AND class.relkind IN ('r', 'p')
       AND has_table_privilege('authenticated', class.oid, 'TRUNCATE')
  ),
  0::BIGINT,
  'authenticated clients cannot bypass RLS with TRUNCATE'
);
SELECT is(
  (
    SELECT count(*)
      FROM pg_catalog.pg_class AS class
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = class.relnamespace
     WHERE namespace.nspname = 'public'
       AND class.relkind IN ('r', 'p')
       AND has_table_privilege('anon', class.oid, 'TRUNCATE')
  ),
  0::BIGINT,
  'anonymous clients cannot bypass RLS with TRUNCATE'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'public.users', 'SELECT'),
  'the complete users row remains unavailable to clients'
);
SELECT ok(
  has_column_privilege(
    'authenticated', 'public.users', 'display_name', 'SELECT'
  ),
  'authenticated clients can render display names'
);
SELECT ok(
  NOT has_column_privilege(
    'authenticated', 'public.users', 'shadow_banned', 'SELECT'
  ),
  'moderation-only shadow-ban state remains hidden'
);
SELECT ok(
  has_table_privilege('service_role', 'public.posts', 'SELECT'),
  'trusted workers can read canonical public tables'
);
SELECT ok(
  has_table_privilege('service_role', 'public.posts', 'UPDATE'),
  'trusted workers can update canonical public tables'
);
SELECT ok(
  NOT has_table_privilege(
    'authenticated', 'public.posts_comments', 'INSERT'
  ),
  'new Vent comments must enter through the moderated idempotent RPC'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'public.whispers', 'INSERT'),
  'new Whispers must enter through the moderated idempotent RPC'
);
SELECT ok(
  NOT has_table_privilege(
    'authenticated', 'public.tribe_messages', 'INSERT'
  ),
  'new Tribe messages must enter through the moderated idempotent RPC'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'public.comment_likes', 'INSERT'),
  'comment likes must enter through the desired-state RPC'
);
SELECT ok(
  has_table_privilege('authenticated', 'public.notifications', 'UPDATE'),
  'authenticated users can update their RLS-visible notifications'
);
SELECT ok(
  has_column_privilege(
    'authenticated', 'public.users', 'recovery_blob', 'UPDATE'
  ) AND has_column_privilege(
    'authenticated', 'public.users', 'recovery_salt', 'UPDATE'
  ),
  'sign-up can seal recovery material only on the owner row'
);
SELECT ok(
  has_column_privilege(
    'authenticated', 'public.users', 'home_city', 'UPDATE'
  ) AND has_column_privilege(
    'authenticated', 'public.users', 'home_country', 'UPDATE'
  ) AND has_column_privilege(
    'authenticated', 'public.users', 'home_campus', 'UPDATE'
  ),
  'the location editor has only its required users-column updates'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'public.users', 'UPDATE'),
  'authenticated clients cannot update arbitrary users columns'
);

SELECT * FROM finish();
ROLLBACK;
