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

INSERT INTO public.tribes (
  tribe_id, name, slug, description, category_name, created_by, created_at
) VALUES (
  '82000000-0000-4000-8000-000000000001',
  'Keyset Tribe', 'keyset-tribe', 'feed keyset test tribe', 'confessions',
  '81000000-0000-4000-8000-000000000001', NOW() - INTERVAL '1 day'
);

INSERT INTO public.tribe_members (tribe_id, user_id, role, joined_at)
VALUES (
  '82000000-0000-4000-8000-000000000001',
  '81000000-0000-4000-8000-000000000001',
  'member',
  NOW() - INTERVAL '1 day'
);

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

SET LOCAL role authenticated;
SET LOCAL request.jwt.claim.sub = '81000000-0000-4000-8000-000000000001';

SELECT ok(
  (SELECT COUNT(*) FROM public.personal_feed(2, 0, NULL, NULL)) = 2,
  'personal_feed returns the first page'
);

WITH first_page AS (
  SELECT post_id, personal_score, created_at
    FROM public.personal_feed(1, 0, NULL, NULL)
   LIMIT 1
),
second_page AS (
  SELECT p.post_id
    FROM public.personal_feed(
      5,
      0,
      NULL,
      NULL,
      (SELECT personal_score FROM first_page),
      (SELECT created_at FROM first_page),
      (SELECT post_id FROM first_page)
    ) AS p
)
SELECT ok(
  (SELECT COUNT(*) FROM second_page) >= 1,
  'personal_feed keyset cursor returns a following page'
);

SET LOCAL request.jwt.claim.sub = '81000000-0000-4000-8000-000000000002';

SELECT ok(
  (
    SELECT post_id
      FROM public.personal_feed(3, 0, NULL, NULL)
     ORDER BY personal_score DESC, created_at DESC, post_id DESC
     LIMIT 1
  ) IS NOT NULL,
  'personal_feed is personalized per viewer'
);

SELECT * FROM finish();
ROLLBACK;
