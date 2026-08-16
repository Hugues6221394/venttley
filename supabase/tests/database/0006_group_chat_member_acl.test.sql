BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(12);

SELECT ok(
  has_schema_privilege('authenticated', 'private', 'USAGE'),
  'authenticated can resolve the private membership helper schema'
);
SELECT ok(
  has_function_privilege(
    'authenticated', 'private.is_chat_room_member(uuid)', 'EXECUTE'
  ),
  'authenticated can execute the membership predicate used by RLS'
);
SELECT ok(
  NOT has_function_privilege(
    'anon', 'private.is_chat_room_member(uuid)', 'EXECUTE'
  ),
  'unauthenticated API callers cannot execute the membership helper'
);
SELECT ok(
  has_function_privilege(
    'authenticated', 'public.group_chat_members(uuid)', 'EXECUTE'
  ),
  'authenticated can invoke the public group member RPC'
);
SELECT ok(
  NOT has_function_privilege(
    'anon', 'public.group_chat_members(uuid)', 'EXECUTE'
  ),
  'unauthenticated API callers cannot invoke the group member RPC'
);
SELECT is(
  (
    SELECT procedure.prosecdef
      FROM pg_catalog.pg_proc AS procedure
     WHERE procedure.oid =
       'private.is_chat_room_member(uuid)'::REGPROCEDURE
  ),
  TRUE,
  'the private predicate bypasses recursive membership RLS'
);
SELECT is(
  (
    SELECT procedure.proconfig @> ARRAY['search_path=""']::TEXT[]
      FROM pg_catalog.pg_proc AS procedure
     WHERE procedure.oid =
       'private.is_chat_room_member(uuid)'::REGPROCEDURE
  ),
  TRUE,
  'the security-definer helper has an empty search path'
);
SELECT is(
  (
    SELECT procedure.prosecdef
      FROM pg_catalog.pg_proc AS procedure
     WHERE procedure.oid = 'public.group_chat_members(uuid)'::REGPROCEDURE
  ),
  FALSE,
  'the public RPC remains security invoker'
);

INSERT INTO auth.users (
  id, aud, role, email, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
) VALUES
  (
    '91000000-0000-4000-8000-000000000001',
    'authenticated', 'authenticated', 'group-acl-a@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"group_acl_a","avatar_seed":"group-acl-a","birth_year":2000}'::JSONB,
    now() - INTERVAL '2 hours', now() - INTERVAL '2 hours'
  ),
  (
    '91000000-0000-4000-8000-000000000002',
    'authenticated', 'authenticated', 'group-acl-b@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"group_acl_b","avatar_seed":"group-acl-b","birth_year":2000}'::JSONB,
    now() - INTERVAL '2 hours', now() - INTERVAL '2 hours'
  ),
  (
    '91000000-0000-4000-8000-000000000003',
    'authenticated', 'authenticated', 'group-acl-outsider@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"group_acl_outsider","avatar_seed":"group-acl-outsider","birth_year":2000}'::JSONB,
    now() - INTERVAL '2 hours', now() - INTERVAL '2 hours'
  );

UPDATE public.users
   SET created_at = now() - INTERVAL '2 hours'
 WHERE user_id::TEXT LIKE '91000000-0000-4000-8000-%';

INSERT INTO public.chat_rooms (
  room_id, initiated_by, received_by, request_preview, room_status,
  room_kind, title, created_by
) VALUES (
  '92000000-0000-4000-8000-000000000001',
  '91000000-0000-4000-8000-000000000001',
  '91000000-0000-4000-8000-000000000002',
  'group ACL fixture', 'active', 'group', 'ACL fixture',
  '91000000-0000-4000-8000-000000000001'
);

INSERT INTO public.chat_room_members (
  room_id, user_id, member_role, invited_by
) VALUES
  (
    '92000000-0000-4000-8000-000000000001',
    '91000000-0000-4000-8000-000000000001',
    'owner', '91000000-0000-4000-8000-000000000001'
  ),
  (
    '92000000-0000-4000-8000-000000000001',
    '91000000-0000-4000-8000-000000000002',
    'member', '91000000-0000-4000-8000-000000000001'
  );

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" =
  '91000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"91000000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT is(
  private.is_chat_room_member(
    '92000000-0000-4000-8000-000000000001'
  ),
  TRUE,
  'the active group member passes the canonical membership predicate'
);
SELECT is(
  (
    SELECT count(*)
      FROM public.group_chat_members(
        '92000000-0000-4000-8000-000000000001'
      )
  ),
  2::BIGINT,
  'the authenticated member can load the active group member list'
);

RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" =
  '91000000-0000-4000-8000-000000000003';
SET LOCAL "request.jwt.claims" =
  '{"sub":"91000000-0000-4000-8000-000000000003","role":"authenticated"}';

SELECT is(
  private.is_chat_room_member(
    '92000000-0000-4000-8000-000000000001'
  ),
  FALSE,
  'an authenticated non-member fails the canonical membership predicate'
);
SELECT is(
  (
    SELECT count(*)
      FROM public.group_chat_members(
        '92000000-0000-4000-8000-000000000001'
      )
  ),
  0::BIGINT,
  'the authenticated non-member cannot read any group member rows'
);

SELECT * FROM finish();
ROLLBACK;
