BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(28);

SELECT has_schema('private', 'private schema exists');
SELECT has_table(
  'private',
  'client_mutation_receipts',
  'idempotency receipts are stored outside the Data API schema'
);
SELECT is(
  (
    SELECT c.relrowsecurity
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'private'
       AND c.relname = 'client_mutation_receipts'
  ),
  TRUE,
  'idempotency receipts have RLS enabled'
);
SELECT ok(
  NOT has_table_privilege(
    'anon',
    'private.client_mutation_receipts',
    'SELECT'
  ),
  'anon cannot read idempotency receipts'
);
SELECT ok(
  NOT has_table_privilege(
    'authenticated',
    'private.client_mutation_receipts',
    'SELECT'
  ),
  'authenticated clients cannot read idempotency receipts'
);
SELECT ok(
  has_table_privilege(
    'service_role',
    'private.client_mutation_receipts',
    'SELECT'
  ),
  'service role can inspect idempotency receipts operationally'
);
SELECT ok(
  has_schema_privilege('anon', 'private', 'USAGE'),
  'anon can resolve the internal visibility predicate used by feed RLS'
);
SELECT ok(
  has_schema_privilege('authenticated', 'private', 'USAGE'),
  'authenticated can resolve the internal visibility predicate used by feed RLS'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'private.existing_client_mutation(uuid,uuid,text)',
    'EXECUTE'
  ),
  'authenticated clients cannot execute the receipt lookup helper'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'private.complete_client_mutation(uuid,uuid,text,uuid)',
    'EXECUTE'
  ),
  'authenticated clients cannot execute the receipt completion helper'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'private.can_view_post_author(uuid)',
    'EXECUTE'
  ),
  'authenticated post reads can execute the private visibility predicate'
);
SELECT ok(
  NOT has_column_privilege(
    'authenticated',
    'public.users',
    'shadow_banned',
    'SELECT'
  ),
  'moderation-only shadow-ban state is not exposed to clients'
);

SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.create_post_idempotent(uuid,text,text,text,uuid,uuid,uuid,boolean,text,text,text,text,integer)',
    'EXECUTE'
  ),
  'authenticated clients can use the idempotent post RPC'
);
SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.create_post_idempotent(uuid,text,text,text,uuid,uuid,uuid,boolean,text,text,text,text,integer)',
    'EXECUTE'
  ),
  'anon cannot create posts through the idempotent RPC'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.create_threaded_comment_idempotent(uuid,uuid,text,uuid,uuid,text,text)',
    'EXECUTE'
  ),
  'authenticated clients can use the idempotent comment RPC'
);
SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.create_threaded_comment_idempotent(uuid,uuid,text,uuid,uuid,text,text)',
    'EXECUTE'
  ),
  'anon cannot create comments through the idempotent RPC'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.add_whisper_comment_idempotent(uuid,uuid,text,uuid,uuid)',
    'EXECUTE'
  ),
  'authenticated clients can use the idempotent whisper comment RPC'
);
SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.add_whisper_comment_idempotent(uuid,uuid,text,uuid,uuid)',
    'EXECUTE'
  ),
  'anon cannot create whisper comments through the idempotent RPC'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.send_tribe_message_idempotent(uuid,uuid,text,uuid,text,text,text,text,integer,uuid,jsonb)',
    'EXECUTE'
  ),
  'authenticated clients can use the idempotent tribe message RPC'
);
SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.send_tribe_message_idempotent(uuid,uuid,text,uuid,text,text,text,text,integer,uuid,jsonb)',
    'EXECUTE'
  ),
  'anon cannot send tribe messages through the idempotent RPC'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.send_chat_message_idempotent(uuid,uuid,text,uuid,text,text,uuid)',
    'EXECUTE'
  ),
  'authenticated clients can use the idempotent DM RPC'
);
SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.send_chat_message_idempotent(uuid,uuid,text,uuid,text,text,uuid)',
    'EXECUTE'
  ),
  'anon cannot send DMs through the idempotent RPC'
);

SELECT is(
  (
    SELECT 'security_invoker=true' = ANY (COALESCE(c.reloptions, ARRAY[]::TEXT[]))
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = 'feed_posts'
  ),
  TRUE,
  'feed view executes with the caller privileges'
);
SELECT is(
  (
    SELECT 'security_invoker=true' = ANY (COALESCE(c.reloptions, ARRAY[]::TEXT[]))
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = 'inbox_rooms'
  ),
  TRUE,
  'inbox view executes with the caller privileges'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'public.feature_flags', 'INSERT'),
  'authenticated clients cannot mutate feature flags directly'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.my_feature_flags()',
    'EXECUTE'
  ),
  'authenticated clients can evaluate feature flags'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public._guard_write(uuid,text,bigint,integer,text)',
    'EXECUTE'
  ),
  'write-rate helper is not a client-callable RPC'
);
SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.consume_moderation_quota(uuid)',
    'EXECUTE'
  ),
  'moderation quota accounting is not callable by anon'
);

SELECT * FROM finish();
ROLLBACK;
