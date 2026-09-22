-- Deleting an account: what it demands, what it refuses, and what it hides.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(7);

-- Fixtures are built under replica so handle_new_user does not fire and
-- invent a pseudonym that collides with the one we want.
SET session_replication_role = replica;

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES ('ddd10000-0000-4000-8000-000000000001','delleaver','delleaver','x',
        'delleaver','delleaver','delleaver','normal','active',1990),
       ('ddd10000-0000-4000-8000-000000000002','delwatcher','delwatcher','x',
        'delwatcher','delwatcher','delwatcher','normal','active',1991);

INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                        created_at, updated_at, confirmation_token, recovery_token,
                        email_change, email_change_token_new, email_change_token_current,
                        phone_change, phone_change_token, reauthentication_token)
VALUES ('ddd10000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000',
        'authenticated','authenticated','delleaver@id.venttly.app',
        extensions.crypt('correct-horse', extensions.gen_salt('bf')), now(),
        '{}','{}', now(), now(), '','','','','','','',''),
       ('ddd10000-0000-4000-8000-000000000002','00000000-0000-0000-0000-000000000000',
        'authenticated','authenticated','delwatcher@id.venttly.app','x', now(),
        '{}','{}', now(), now(), '','','','','','','','');

INSERT INTO public.tribes (tribe_id, name, slug, category, keeper_id)
VALUES ('ddd20000-0000-4000-8000-000000000001','Stranded','del-stranded',
        'support','ddd10000-0000-4000-8000-000000000001');

INSERT INTO public.tribe_members (tribe_id, user_id, role) VALUES
  ('ddd20000-0000-4000-8000-000000000001','ddd10000-0000-4000-8000-000000000001','keeper'),
  ('ddd20000-0000-4000-8000-000000000001','ddd10000-0000-4000-8000-000000000002','member');

INSERT INTO public.posts (post_id, author_id, content, category_name, post_mood)
VALUES ('ddd30000-0000-4000-8000-000000000001',
        'ddd10000-0000-4000-8000-000000000001','still here','confessions','hopeful');

SET session_replication_role = origin;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims =
  '{"sub":"ddd10000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT throws_like(
  $$ SELECT public.request_account_deletion(NULL) $$,
  '%password_required%',
  'no password is refused'
);

SELECT throws_like(
  $$ SELECT public.request_account_deletion('not-my-password') $$,
  '%password_incorrect%',
  'the wrong password is refused'
);

SELECT throws_like(
  $$ SELECT public.request_account_deletion('correct-horse') $$,
  '%tribe_needs_a_keeper%',
  'a keeper cannot walk out on a tribe that still has members'
);

-- Somebody else can read their post while the account is live.
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims =
  '{"sub":"ddd10000-0000-4000-8000-000000000002","role":"authenticated"}';
SELECT results_eq(
  $$ SELECT count(*)::INT FROM public.posts
      WHERE author_id = 'ddd10000-0000-4000-8000-000000000001' $$,
  ARRAY[1],
  'before deletion, other people can read their post'
);

-- Empty the tribe of everyone but its keeper; now there is nobody to strand.
SET LOCAL ROLE postgres;
SET session_replication_role = replica;
DELETE FROM public.tribe_members
 WHERE tribe_id = 'ddd20000-0000-4000-8000-000000000001'
   AND user_id = 'ddd10000-0000-4000-8000-000000000002';
SET session_replication_role = origin;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims =
  '{"sub":"ddd10000-0000-4000-8000-000000000001","role":"authenticated"}';
SELECT lives_ok(
  $$ SELECT public.request_account_deletion('correct-horse') $$,
  'the right password on a keeper-only tribe is accepted'
);

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims =
  '{"sub":"ddd10000-0000-4000-8000-000000000002","role":"authenticated"}';
SELECT results_eq(
  $$ SELECT count(*)::INT FROM public.posts
      WHERE author_id = 'ddd10000-0000-4000-8000-000000000001' $$,
  ARRAY[0],
  'the moment they delete, their post is gone for everyone else'
);

-- ...but not for them, which is what makes the 30-day window a real offer
-- rather than a promise to rebuild from nothing.
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims =
  '{"sub":"ddd10000-0000-4000-8000-000000000001","role":"authenticated"}';
SELECT results_eq(
  $$ SELECT count(*)::INT FROM public.posts
      WHERE author_id = 'ddd10000-0000-4000-8000-000000000001' $$,
  ARRAY[1],
  'the author still sees it, so signing back in restores rather than resurrects'
);

SELECT * FROM finish();
ROLLBACK;
