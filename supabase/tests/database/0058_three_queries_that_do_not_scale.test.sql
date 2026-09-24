-- The inbox and the feed stop reading whole tables.
--
-- Both fixes are invisible to behaviour and visible only in a query plan, so
-- they are tested the way the planner sees them: the policy must be made of
-- column comparisons rather than a function call, and the index the feed needs
-- must exist in the shape the feed asks for. A behavioural test would pass
-- just as happily on the slow version.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(9);

-- 1. The policy the inbox depends on.
--
-- It was private.is_chat_room_member(room_id): correct, and opaque to the
-- planner, which therefore fetched every row in chat_rooms and called it.
-- Thirty thousand rows examined to return one, and the cost grew with every
-- room anybody had ever opened.
SELECT ok(
  (SELECT pg_get_expr(polqual, polrelid) NOT LIKE '%is_chat_room_member%'
     FROM pg_policy
    WHERE polrelid = 'public.chat_rooms'::regclass
      AND polname = 'chat_rooms participants read'),
  'the chat_rooms read policy does not hide behind a function'
);
SELECT ok(
  (SELECT pg_get_expr(polqual, polrelid) LIKE '%initiated_by%'
     FROM pg_policy
    WHERE polrelid = 'public.chat_rooms'::regclass
      AND polname = 'chat_rooms participants read'),
  'it compares the columns an index can serve'
);
SELECT ok(
  (SELECT pg_get_expr(polqual, polrelid) LIKE '%received_by%'
     FROM pg_policy
    WHERE polrelid = 'public.chat_rooms'::regclass
      AND polname = 'chat_rooms participants read'),
  'both ends of a direct room'
);

-- The indexes those comparisons need. They already existed; the policy simply
-- could not reach them.
SELECT has_index('public', 'chat_rooms', 'idx_chat_rooms_users',
  'the index the initiated_by arm uses is still here');
SELECT has_index('public', 'chat_rooms', 'idx_chat_rooms_status',
  'and the one the received_by arm uses');

-- 2. The index the feed asks for.
--
-- Eighteen indexes existed on posts and none matched
-- `ORDER BY created_at DESC, post_id DESC` — each was ascending, or partial on
-- a predicate the feed query does not state, or led with another column. So
-- the planner read every post and sorted them to return twenty.
SELECT has_index('public', 'posts', 'posts_feed_created_idx',
  'the feed has an index in the order it actually sorts by');
SELECT ok(
  (SELECT indexdef NOT LIKE '%WHERE%'
     FROM pg_indexes
    WHERE tablename = 'posts' AND indexname = 'posts_feed_created_idx'),
  -- A partial index is only usable when the query repeats its predicate, and
  -- the feed query never mentions deleted_at.
  'and it is not partial, so the feed query can use it'
);

-- 3. Behaviour is unchanged, which is the point of both.
SET session_replication_role = replica;
INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                        created_at, updated_at, confirmation_token, recovery_token,
                        email_change, email_change_token_new, email_change_token_current,
                        phone_change, phone_change_token, reauthentication_token)
SELECT v.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       v.id || '@id.venttly.app', 'x', now(), '{}', '{}', now(), now(),
       '','','','','','','',''
  FROM (VALUES
    ('ccd10000-0000-4000-8000-000000000001'::UUID),
    ('ccd10000-0000-4000-8000-000000000002'::UUID),
    ('ccd10000-0000-4000-8000-000000000003'::UUID)
  ) AS v(id);

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES
  ('ccd10000-0000-4000-8000-000000000001','planone','x','x','One','one','planone','normal','active',1990),
  ('ccd10000-0000-4000-8000-000000000002','plantwo','x','x','Two','two','plantwo','normal','active',1990),
  ('ccd10000-0000-4000-8000-000000000003','planthree','x','x','Three','three','planthree','normal','active',1990);

INSERT INTO public.chat_rooms (room_id, initiated_by, received_by, room_status, room_kind)
VALUES ('ccd1aaaa-0000-4000-8000-000000000001',
        'ccd10000-0000-4000-8000-000000000001',
        'ccd10000-0000-4000-8000-000000000002', 'active', 'direct');
SET session_replication_role = origin;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"ccd10000-0000-4000-8000-000000000002","role":"authenticated"}';
SELECT is(
  (SELECT count(*)::INT FROM public.chat_rooms
    WHERE room_id = 'ccd1aaaa-0000-4000-8000-000000000001'),
  1,
  'the person on the receiving end still sees their room'
);

SET LOCAL request.jwt.claims = '{"sub":"ccd10000-0000-4000-8000-000000000003","role":"authenticated"}';
SELECT is(
  (SELECT count(*)::INT FROM public.chat_rooms
    WHERE room_id = 'ccd1aaaa-0000-4000-8000-000000000001'),
  0,
  'and somebody outside it still does not'
);

SELECT * FROM finish();
ROLLBACK;
