-- Unblocking somebody gives you your friend back, on both sides.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(12);

SET session_replication_role = replica;

INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                        created_at, updated_at, confirmation_token, recovery_token,
                        email_change, email_change_token_new, email_change_token_current,
                        phone_change, phone_change_token, reauthentication_token)
SELECT v.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       v.id || '@id.venttly.app', 'x', now(), '{}', '{}',
       now() - INTERVAL '2 years', now(), '','','','','','','',''
  FROM (VALUES
    ('bbc10000-0000-4000-8000-000000000001'::UUID),  -- blocks
    ('bbc10000-0000-4000-8000-000000000002'::UUID),  -- is blocked
    ('bbc10000-0000-4000-8000-000000000003'::UUID)   -- asked to be friends
  ) AS v(id);

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year, created_at)
VALUES
  ('bbc10000-0000-4000-8000-000000000001','blockerone','x','x','One','one','blockerone','normal','active',1990, now() - INTERVAL '2 years'),
  ('bbc10000-0000-4000-8000-000000000002','blockedtwo','x','x','Two','two','blockedtwo','normal','active',1990, now() - INTERVAL '2 years'),
  ('bbc10000-0000-4000-8000-000000000003','hopefulthree','x','x','Three','three','hopefulthree','normal','active',1990, now() - INTERVAL '2 years');

INSERT INTO public.friendships (user_a, user_b, status, requested_by, accepted_at)
SELECT p.user_a, p.user_b, 'accepted',
       'bbc10000-0000-4000-8000-000000000001', now()
  FROM public.friendship_pair('bbc10000-0000-4000-8000-000000000001',
                              'bbc10000-0000-4000-8000-000000000002') p;

-- Somebody with a request outstanding, to prove a block suspends it rather
-- than withdrawing it.
INSERT INTO public.friendships (user_a, user_b, status, requested_by)
SELECT p.user_a, p.user_b, 'pending',
       'bbc10000-0000-4000-8000-000000000003'
  FROM public.friendship_pair('bbc10000-0000-4000-8000-000000000001',
                              'bbc10000-0000-4000-8000-000000000003') p;

INSERT INTO public.policy_acceptances (user_id, kind, version)
SELECT u.user_id, c.kind, c.version
  FROM public.users u, public.current_policies() c
ON CONFLICT DO NOTHING;

SET session_replication_role = origin;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"bbc10000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT is(
  (SELECT count(*)::INT FROM public.my_friends
    WHERE friend_user_id = 'bbc10000-0000-4000-8000-000000000002'),
  1,
  'they are friends to start with'
);

SELECT lives_ok(
  $$ SELECT public.block_user('bbc10000-0000-4000-8000-000000000002', NULL) $$,
  'one of them blocks the other'
);

SELECT is(
  (SELECT count(*)::INT FROM public.my_friends
    WHERE friend_user_id = 'bbc10000-0000-4000-8000-000000000002'),
  0,
  'and they are gone from the blocker list'
);

-- The bug. block_user deleted the friendship row outright, so unblocking had
-- nothing to restore and both people lost the connection for good.
RESET ROLE;
SELECT is(
  (SELECT count(*)::INT FROM public.friendships f, public.friendship_pair(
      'bbc10000-0000-4000-8000-000000000001',
      'bbc10000-0000-4000-8000-000000000002') p
    WHERE f.user_a = p.user_a AND f.user_b = p.user_b),
  1,
  'but the friendship itself is only suspended, not destroyed'
);

-- Symmetric for free: has_block looks both ways, so the person who was
-- blocked also stops seeing the blocker.
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"bbc10000-0000-4000-8000-000000000002","role":"authenticated"}';
SELECT is(
  (SELECT count(*)::INT FROM public.my_friends
    WHERE friend_user_id = 'bbc10000-0000-4000-8000-000000000001'),
  0,
  'and gone from the blocked person list too, without them doing anything'
);

-- Unblocking.
SET LOCAL request.jwt.claims = '{"sub":"bbc10000-0000-4000-8000-000000000001","role":"authenticated"}';
SELECT lives_ok(
  $$ SELECT public.unblock_user('bbc10000-0000-4000-8000-000000000002') $$,
  'the block is lifted'
);
SELECT is(
  (SELECT count(*)::INT FROM public.my_friends
    WHERE friend_user_id = 'bbc10000-0000-4000-8000-000000000002'),
  1,
  'and the friend is back, immediately'
);

SET LOCAL request.jwt.claims = '{"sub":"bbc10000-0000-4000-8000-000000000002","role":"authenticated"}';
SELECT is(
  (SELECT count(*)::INT FROM public.my_friends
    WHERE friend_user_id = 'bbc10000-0000-4000-8000-000000000001'),
  1,
  'on both sides'
);

-- A pending request is suspended the same way, rather than withdrawn:
-- unblocking must not silently cancel something somebody asked for.
SET LOCAL request.jwt.claims = '{"sub":"bbc10000-0000-4000-8000-000000000001","role":"authenticated"}';
SELECT lives_ok(
  $$ SELECT public.block_user('bbc10000-0000-4000-8000-000000000003', NULL) $$,
  'blocking somebody who has a request outstanding'
);
SELECT is(
  (SELECT count(*)::INT FROM public.friend_requests_inbox
    WHERE from_user_id = 'bbc10000-0000-4000-8000-000000000003'),
  0,
  'takes their request out of sight'
);
SELECT lives_ok(
  $$ SELECT public.unblock_user('bbc10000-0000-4000-8000-000000000003') $$,
  'and lifting it'
);
SELECT is(
  (SELECT count(*)::INT FROM public.friend_requests_inbox
    WHERE from_user_id = 'bbc10000-0000-4000-8000-000000000003'),
  1,
  'puts it back rather than having thrown it away'
);

SELECT * FROM finish();
ROLLBACK;
