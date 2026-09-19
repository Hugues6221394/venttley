-- Reaction integrity — the server half of "instant likes".
--
-- The brief asked for optimistic UI on the client and listed what the backend
-- must guarantee underneath it: duplicate likes prevented, like/unlike
-- idempotent, a unique constraint per user and post, atomic counter updates,
-- rapid tapping survivable, and counters that cannot corrupt. The Flutter side
-- exists (reaction_controller.dart with reaction_overrides.dart); none of the
-- database guarantees it leans on were covered. This is that half.
--
-- Optimistic UI makes these guarantees load-bearing rather than academic. The
-- client shows the new state before the server has agreed, so every one of
-- these paths is one a user has already seen succeed. If the server then
-- disagrees, the count the user is looking at is wrong.
--
-- WHY likes_count INCREMENTS WHILE member_count RECOMPUTES
--
-- recompute_tribe_member_count recalculates from source on every change, so a
-- corrupted tribe count heals itself (see 0033). trg_inc_likes/trg_dec_likes
-- keep a running +1/-1 total instead, and that is correct here rather than
-- inconsistent: recomputing a viral post's likes on every tap is O(n) on the
-- hottest write path in the product. The safety comes from a different place —
-- the unique constraint makes double-insert impossible, and the inc/dec fire
-- only on INSERT and DELETE, so changing a reaction cannot move the number.
-- Both halves are pinned below.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(16);

SET session_replication_role = replica;

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES
  ('ccc30000-0000-4000-8000-000000000001','rxauthor','x','x','rxauthor','rxauthor','rxauthor','normal','active',1995),
  ('ccc30000-0000-4000-8000-000000000002','rxreactor','x','x','rxreactor','rxreactor','rxreactor','normal','active',1995),
  ('ccc30000-0000-4000-8000-000000000003','rxsecond','x','x','rxsecond','rxsecond','rxsecond','normal','active',1995);

-- The profiles above are written with session_replication_role = replica, which
-- skips the foreign key from public.users to auth.users. A row inserted that way
-- stays in violation of it, and the next ordinary UPDATE of that row -- a karma
-- increment, a status change, a counter -- fails the constraint even though the
-- UPDATE never touches user_id. So each fixture gets the auth row it is supposed
-- to have.
--
-- Written here, still inside the replica fence, rather than before it: an insert
-- into auth.users fires handle_new_user, which would build a second profile and
-- collide with the one above on users_pseudonym_lower_unique. Replica mode
-- suppresses that trigger along with the foreign key.
INSERT INTO auth.users (
  id, aud, role, email, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
) VALUES
  ('ccc30000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 't0034u1@id.venttly.app',
   '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
   now(), now()),
  ('ccc30000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 't0034u2@id.venttly.app',
   '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
   now(), now()),
  ('ccc30000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 't0034u3@id.venttly.app',
   '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
   now(), now())
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.posts (post_id, author_id, category_name, content, post_mood)
VALUES ('ddd30000-0000-4000-8000-000000000001',
        'ccc30000-0000-4000-8000-000000000001',
        'vent_zone','reaction integrity fixture','angry');

SET session_replication_role = origin;

UPDATE public.posts SET likes_count = 0
 WHERE post_id = 'ddd30000-0000-4000-8000-000000000001';

-- ---------------------------------------------------------------------------
-- The constraint that makes a double-tap harmless
-- ---------------------------------------------------------------------------

SELECT col_is_unique(
  'public', 'post_likes', ARRAY['post_id','user_id'],
  'one reaction per person per Vent is enforced by a unique constraint, not by the client remembering'
);

SELECT ok(
  NOT has_table_privilege('authenticated', 'public.post_likes', 'INSERT'),
  'reactions cannot be inserted directly: they must enter through the desired-state RPC'
);

-- ---------------------------------------------------------------------------
-- Reacting, as the reactor
-- ---------------------------------------------------------------------------

SELECT set_config('request.jwt.claims',
  '{"sub":"ccc30000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}', true);

SELECT is(
  public.set_post_reaction('ddd30000-0000-4000-8000-000000000001','love'),
  'love',
  'a reaction is accepted and echoed back'
);

SELECT is(
  (SELECT likes_count FROM public.posts WHERE post_id='ddd30000-0000-4000-8000-000000000001'),
  1,
  'the counter moves to 1'
);

-- The client has already drawn the filled heart. Sending the same state again —
-- a double tap, a retry after a dropped response, a replayed request — must not
-- produce a second row or a second increment.
SELECT lives_ok(
  $$ SELECT public.set_post_reaction('ddd30000-0000-4000-8000-000000000001','love') $$,
  'sending the same reaction again is accepted rather than erroring'
);

SELECT is(
  (SELECT count(*)::int FROM public.post_likes
    WHERE post_id='ddd30000-0000-4000-8000-000000000001'),
  1,
  'and still only one row exists'
);

SELECT is(
  (SELECT likes_count FROM public.posts WHERE post_id='ddd30000-0000-4000-8000-000000000001'),
  1,
  'and the counter did not double-count it'
);

-- ---------------------------------------------------------------------------
-- Changing a reaction is not a new reaction
-- ---------------------------------------------------------------------------

SELECT is(
  public.set_post_reaction('ddd30000-0000-4000-8000-000000000001','hug'),
  'hug',
  'switching from love to hug is accepted'
);

SELECT results_eq(
  $$ SELECT reaction_type::text,
            (SELECT likes_count FROM public.posts
              WHERE post_id='ddd30000-0000-4000-8000-000000000001')
       FROM public.post_likes
      WHERE post_id='ddd30000-0000-4000-8000-000000000001' $$,
  $$ VALUES ('hug', 1) $$,
  'the row is updated in place and the total is unchanged — changing your mind is not another like'
);

-- ---------------------------------------------------------------------------
-- Removing, and removing again
-- ---------------------------------------------------------------------------

SELECT is(
  public.set_post_reaction('ddd30000-0000-4000-8000-000000000001', NULL),
  NULL,
  'passing NULL clears the reaction'
);

SELECT is(
  (SELECT likes_count FROM public.posts WHERE post_id='ddd30000-0000-4000-8000-000000000001'),
  0,
  'the counter returns to 0'
);

-- An un-react that arrives twice, because the first response was lost.
SELECT lives_ok(
  $$ SELECT public.set_post_reaction('ddd30000-0000-4000-8000-000000000001', NULL) $$,
  'clearing an already-cleared reaction is a no-op, not an error'
);

SELECT is(
  (SELECT likes_count FROM public.posts WHERE post_id='ddd30000-0000-4000-8000-000000000001'),
  0,
  'and does not push the counter negative'
);

-- ---------------------------------------------------------------------------
-- Rapid tapping, and a second person
-- ---------------------------------------------------------------------------

-- like / unlike / like / unlike / like, the way a thumb actually behaves.
SELECT public.set_post_reaction('ddd30000-0000-4000-8000-000000000001','love');
SELECT public.set_post_reaction('ddd30000-0000-4000-8000-000000000001', NULL);
SELECT public.set_post_reaction('ddd30000-0000-4000-8000-000000000001','hope');
SELECT public.set_post_reaction('ddd30000-0000-4000-8000-000000000001', NULL);
SELECT public.set_post_reaction('ddd30000-0000-4000-8000-000000000001','felt');

SELECT set_config('request.jwt.claims',
  '{"sub":"ccc30000-0000-4000-8000-000000000003","role":"authenticated","aal":"aal1"}', true);
SELECT public.set_post_reaction('ddd30000-0000-4000-8000-000000000001','proud');

SELECT is(
  (SELECT likes_count FROM public.posts WHERE post_id='ddd30000-0000-4000-8000-000000000001'),
  (SELECT count(*)::int FROM public.post_likes
    WHERE post_id='ddd30000-0000-4000-8000-000000000001'),
  'after rapid toggling by one person and a reaction from another, the counter still equals the number of rows'
);

SELECT is(
  (SELECT likes_count FROM public.posts WHERE post_id='ddd30000-0000-4000-8000-000000000001'),
  2,
  'and that number is 2 — one each, not one per tap'
);

-- ---------------------------------------------------------------------------
-- You cannot react to yourself
-- ---------------------------------------------------------------------------

SELECT set_config('request.jwt.claims',
  '{"sub":"ccc30000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}', true);

SELECT throws_like(
  $$ SELECT public.set_post_reaction('ddd30000-0000-4000-8000-000000000001','love') $$,
  '%self_interaction%',
  'an author cannot react to their own Vent, so the count cannot be self-inflated'
);

SELECT * FROM finish();
ROLLBACK;
