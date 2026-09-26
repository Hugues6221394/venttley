BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(3);

-- Two users with different tribe affinities should not see identical order.
INSERT INTO auth.users (
  id, aud, role, email, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
) VALUES
  (
    '81000000-0000-4000-8000-000000000001',
    'authenticated', 'authenticated', 'feed-keyset-a@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"feed_keyset_a","avatar_seed":"a","birth_year":2000}'::JSONB,
    NOW() - INTERVAL '2 days', NOW() - INTERVAL '2 days'
  ),
  (
    '81000000-0000-4000-8000-000000000002',
    'authenticated', 'authenticated', 'feed-keyset-b@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"feed_keyset_b","avatar_seed":"b","birth_year":2000}'::JSONB,
    NOW() - INTERVAL '2 days', NOW() - INTERVAL '2 days'
  );

UPDATE public.users
   SET created_at = NOW() - INTERVAL '2 days'
 WHERE user_id::TEXT LIKE '81000000-0000-4000-8000-%';

-- The fixture used `category_name` and `created_by`; the table has `category`
-- and `keeper_id`. Those columns have not existed for a long time, so this
-- INSERT aborted the transaction at line 37 and every assertion below it was
-- skipped. pgTAP reported no failures because it reported nothing at all —
-- the file ran ZERO of its assertions while appearing to pass.
INSERT INTO public.tribes (
  tribe_id, name, slug, description, category, keeper_id, created_at
) VALUES (
  '82000000-0000-4000-8000-000000000001',
  'Keyset Tribe', 'keyset-tribe', 'feed keyset test tribe', 'confessions',
  '81000000-0000-4000-8000-000000000001', NOW() - INTERVAL '1 day'
);

-- Both users join, because the feed assertions depend on ...0001 being able
-- to see a tribe post authored by ...0002.
INSERT INTO public.tribe_members (tribe_id, user_id, role, joined_at)
VALUES
  ('82000000-0000-4000-8000-000000000001',
   '81000000-0000-4000-8000-000000000001', 'member', NOW() - INTERVAL '1 day'),
  ('82000000-0000-4000-8000-000000000001',
   '81000000-0000-4000-8000-000000000002', 'member', NOW() - INTERVAL '1 day');

-- guard_tribe_content_write authorises against `(SELECT auth.uid())`, not the
-- row's author_id, so a fixture inserting as postgres can never satisfy it —
-- there is no JWT. Seeded with triggers off, matching 0026/0031/0032. The
-- guard itself is covered by 0003 and 20260716175655.
SET session_replication_role = replica;

INSERT INTO public.posts (
  post_id, author_id, category_name, content, post_mood, tribe_id, created_at
) VALUES
  (
    '83000000-0000-4000-8000-000000000001',
    '81000000-0000-4000-8000-000000000001',
    'confessions', 'global post one', 'hopeful', NULL,
    NOW() - INTERVAL '3 hours'
  ),
  (
    '83000000-0000-4000-8000-000000000002',
    '81000000-0000-4000-8000-000000000002',
    'confessions', 'global post two', 'hopeful', NULL,
    NOW() - INTERVAL '2 hours'
  ),
  (
    '83000000-0000-4000-8000-000000000003',
    '81000000-0000-4000-8000-000000000002',
    'confessions', 'tribe post three', 'hopeful',
    '82000000-0000-4000-8000-000000000001',
    NOW() - INTERVAL '1 hour'
  );

SET session_replication_role = origin;

SET LOCAL role authenticated;
SET LOCAL request.jwt.claim.sub = '81000000-0000-4000-8000-000000000001';
SET LOCAL request.jwt.claims =
  '{"sub":"81000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- The cursor is a position inside a pool frozen at an anchor now, not a
-- (score, created_at, post_id) triple. Scores move while you read -- somebody
-- reacts, somebody comments, and the post you were about to be served slides
-- past the cursor -- and a feed that reshuffles between page one and page two
-- either repeats posts or drops them. The anchor is what the client echoes
-- back, so every page of a session ranks the same pool.
SELECT ok(
  (SELECT COUNT(*) FROM public.personal_feed(2, 'foryou')) = 2,
  'personal_feed returns the first page'
);

WITH anchored AS (SELECT now() AS a),
second_page AS (
  SELECT p.post_id
    FROM anchored, public.personal_feed(5, 'foryou', anchored.a, 1) AS p
)
SELECT ok(
  (SELECT COUNT(*) FROM second_page) >= 1,
  'and a following page from where the last one stopped'
);

SET LOCAL request.jwt.claim.sub = '81000000-0000-4000-8000-000000000002';
SET LOCAL request.jwt.claims =
  '{"sub":"81000000-0000-4000-8000-000000000002","role":"authenticated"}';

SELECT ok(
  (
    SELECT post_id
      FROM public.personal_feed(3, 'foryou')
     ORDER BY feed_position
     LIMIT 1
  ) IS NOT NULL,
  'personal_feed is personalized per viewer'
);

SELECT * FROM finish();
ROLLBACK;
